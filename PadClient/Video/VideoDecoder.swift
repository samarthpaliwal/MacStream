import CoreMedia
import Foundation
import StreamCore
import VideoToolbox

enum VideoDecoderError: LocalizedError {
    case noFormat
    case formatCreation(OSStatus)
    case sessionCreation(OSStatus)
    case sampleCreation(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noFormat: return "No parameter sets received yet."
        case .formatCreation(let s): return "Could not build the video format (\(s))."
        case .sessionCreation(let s): return "Could not create the hardware decoder (\(s))."
        case .sampleCreation(let s): return "Could not wrap the frame for decoding (\(s))."
        }
    }
}

/// VideoToolbox hardware decoder. Takes Annex-B frames, rebuilds the format
/// description from in-band parameter sets, and decodes synchronously so a
/// frame is on screen as soon as it arrives.
final class VideoDecoder {
    /// Called on the decode thread with the decoded image and the time decode finished.
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var lastParameterSets: [Data] = []
    private var codec: VideoPacketHeader.Codec?

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Returns false (without throwing) when the frame is skipped because the
    /// decoder has no format yet, i.e. a keyframe has not arrived.
    @discardableResult
    func decode(_ frame: FrameAssembler.CompletedFrame) throws -> Bool {
        let units = AnnexBParser.nalUnits(in: frame.data)
        let parameterSets = units.filter { AnnexBParser.isParameterSet($0, codec: frame.codec) }
        let payload = units.filter { !AnnexBParser.isParameterSet($0, codec: frame.codec) }

        if !parameterSets.isEmpty, parameterSets != lastParameterSets || codec != frame.codec {
            try configure(parameterSets: parameterSets, codec: frame.codec)
        }
        guard let session, let format, !payload.isEmpty else { return false }

        let sampleBuffer = try Self.sampleBuffer(from: AnnexBParser.lengthPrefixed(payload), format: format)
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: &infoFlags) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            self?.onFrame?(imageBuffer, StageClock.nowNanos())
        }
        if status == kVTInvalidSessionErr {
            // Happens after backgrounding; rebuild on the next keyframe.
            self.session = nil
            lastParameterSets = []
            return false
        }
        return status == noErr
    }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        lastParameterSets = []
    }

    // MARK: Configuration

    private func configure(parameterSets: [Data], codec: VideoPacketHeader.Codec) throws {
        let newFormat = try Self.formatDescription(parameterSets: parameterSets, codec: codec)
        lastParameterSets = parameterSets
        self.codec = codec
        format = newFormat

        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
            return
        }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: newFormat,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else { throw VideoDecoderError.sessionCreation(status) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
    }

    private static func formatDescription(parameterSets: [Data], codec: VideoPacketHeader.Codec) throws -> CMVideoFormatDescription {
        // Copy into stable C buffers for the duration of the call.
        let buffers = parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = parameterSets.map(\.count)

        var format: CMVideoFormatDescription?
        let status: OSStatus
        switch codec {
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        case .pcmAudio:
            throw VideoDecoderError.noFormat
        }
        guard status == noErr, let format else { throw VideoDecoderError.formatCreation(status) }
        return format
    }

    private static func sampleBuffer(from data: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else { throw VideoDecoderError.sampleCreation(status) }
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw VideoDecoderError.sampleCreation(status) }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var size = data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { throw VideoDecoderError.sampleCreation(status) }
        return sampleBuffer
    }
}
