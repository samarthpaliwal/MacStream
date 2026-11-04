import CoreMedia
import Foundation
import os
import StreamCore
import VideoToolbox

enum VideoEncoderError: LocalizedError {
    case sessionCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status): return "Could not create the video encoder (\(status))."
        }
    }
}

/// Hardware HEVC/H.264 encoder configured for the lowest latency VideoToolbox
/// offers: real-time mode, no frame reordering (no B-frames), low-latency
/// rate control, and keyframes only when asked for.
final class VideoEncoder {
    struct Configuration {
        var codec: VideoPacketHeader.Codec
        var width: Int
        var height: Int
        var framesPerSecond: Int
        var bitrateBitsPerSecond: Int
    }

    /// Emits the raw sample buffer (for file writing) and the Annex-B frame
    /// (for the network). Called on VideoToolbox's output thread.
    var onOutput: ((CMSampleBuffer, EncodedFrame) -> Void)?
    var onDrop: (() -> Void)?

    let configuration: Configuration
    private var session: VTCompressionSession
    private let keyframeRequested = OSAllocatedUnfairLock(initialState: true)

    init(configuration: Configuration) throws {
        self.configuration = configuration

        let codecType: CMVideoCodecType = configuration.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: codecType,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }
        session = created
        applyProperties()
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    private func applyProperties() {
        let c = configuration
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_AllowTemporalCompression, true)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, c.framesPerSecond)
        // Long GOP: keyframes are expensive at this resolution, and the client
        // requests one explicitly whenever it loses data.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, c.framesPerSecond * 10)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10)
        setBitrate(c.bitrateBitsPerSecond)

        switch c.codec {
        case .hevc:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        case .h264:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        case .pcmAudio:
            break   // not a video codec
        }
    }

    func setBitrate(_ bitsPerSecond: Int) {
        set(kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond)
        // Hard cap per second so a busy frame cannot blow the budget and queue up.
        set(kVTCompressionPropertyKey_DataRateLimits, [bitsPerSecond / 8, 1] as CFArray)
    }

    /// Next encoded frame will be an IDR frame with parameter sets.
    func requestKeyframe() {
        keyframeRequested.withLock { $0 = true }
    }

    func encode(_ frame: CapturedFrame) {
        var properties: [CFString: Any] = [:]
        let forceKey = keyframeRequested.withLock { requested -> Bool in
            defer { requested = false }
            return requested
        }
        if forceKey {
            properties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.presentationTime,
            duration: .invalid,
            frameProperties: properties as CFDictionary,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            guard let self else { return }
            guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer else {
                self.onDrop?()
                return
            }
            self.emit(sampleBuffer, for: frame)
        }
        if status != noErr {
            onDrop?()
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer, for frame: CapturedFrame) {
        let isKeyframe = Self.isKeyframe(sampleBuffer)
        guard let data = AnnexB.data(from: sampleBuffer, codec: configuration.codec, includeParameterSets: isKeyframe) else {
            onDrop?()
            return
        }
        let encoded = EncodedFrame(
            data: data,
            isKeyframe: isKeyframe,
            codec: configuration.codec,
            width: configuration.width,
            height: configuration.height,
            captureNanos: frame.captureNanos,
            deliveredNanos: frame.deliveredNanos,
            encodedNanos: StageClock.nowNanos()
        )
        onOutput?(sampleBuffer, encoded)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    private func set(_ key: CFString, _ value: Any) {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        if status != noErr {
            // Some keys are unsupported in low-latency mode; that is fine.
            print("[MacStream] encoder property \(key) not applied (\(status))")
        }
    }
}

/// Converts VideoToolbox's length-prefixed NAL units (hvcC/avcC style) into
/// Annex-B with 4-byte start codes, optionally prefixed with parameter sets.
enum AnnexB {
    private static let startCode = Data([0, 0, 0, 1])

    static func data(from sampleBuffer: CMSampleBuffer, codec: VideoPacketHeader.Codec, includeParameterSets: Bool) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var out = Data()

        if includeParameterSets, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for set in parameterSets(from: format, codec: codec) {
                out.append(startCode)
                out.append(set)
            }
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var raw = Data(count: length)
        let copyStatus = raw.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == noErr else { return nil }

        var offset = 0
        while offset + 4 <= length {
            let nalLength = raw.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian) }
            let start = offset + 4
            guard nalLength > 0, start + nalLength <= length else { break }
            out.append(startCode)
            out.append(raw[start..<(start + nalLength)])
            offset = start + nalLength
        }
        return out
    }

    static func parameterSets(from format: CMFormatDescription, codec: VideoPacketHeader.Codec) -> [Data] {
        var count = 0
        let countStatus: OSStatus
        switch codec {
        case .hevc:
            countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        case .h264:
            countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        case .pcmAudio:
            return []
        }
        guard countStatus == noErr else { return [] }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            switch codec {
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            case .pcmAudio:
                return []
            }
            if status == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }
}
