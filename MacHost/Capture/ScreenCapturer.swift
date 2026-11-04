import CoreMedia
import Foundation
import ScreenCaptureKit
import StreamCore

enum ScreenCaptureError: LocalizedError {
    case displayNotFound
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "The selected display was not found."
        case .permissionDenied: return "Screen Recording permission is required."
        }
    }
}

/// ScreenCaptureKit source tuned for latency: shallow queue, 60 fps cap,
/// 4:2:0 output the encoder can consume without conversion.
final class ScreenCapturer: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CapturedFrame) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "macstream.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "macstream.capture.audio", qos: .userInteractive)

    private static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func start(_ configuration: CaptureConfiguration) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // SCShareableContent fails with a TCC error when permission is missing.
            throw ScreenCaptureError.permissionDenied
        }
        guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) ?? content.displays.first else {
            throw ScreenCaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = configuration.width
        config.height = configuration.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        config.queueDepth = 3                       // small: stale frames are worse than dropped ones
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = configuration.showsCursor
        config.scalesToFit = true
        config.capturesAudio = configuration.capturesAudio
        if configuration.capturesAudio {
            config.sampleRate = Int(StreamService.audioSampleRate)
            config.channelCount = StreamService.audioChannels
            config.excludesCurrentProcessAudio = true
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if let pcm = Self.interleavedInt16(from: sampleBuffer) { onAudio?(pcm) }
            return
        }
        let deliveredNanos = StageClock.nowNanos()
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        // displayTime is a raw mach_absolute_time value (ticks, not seconds).
        // Convert with the timebase so it lines up with StageClock, and fall
        // back to the delivery time if the result looks implausible.
        var captureNanos = deliveredNanos
        if let displayTicks = info[.displayTime] as? Double {
            let nanos = displayTicks * Self.nanosPerTick
            if nanos.isFinite, nanos > 0, abs(nanos - Double(deliveredNanos)) < 10_000_000_000 {
                captureNanos = UInt64(nanos)
            }
        }

        onFrame?(CapturedFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            captureNanos: captureNanos,
            deliveredNanos: deliveredNanos
        ))
    }

    /// ScreenCaptureKit delivers Float32 audio, usually one buffer per
    /// channel. Interleave and quantise to Int16 for the wire.
    private static func interleavedInt16(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let listPointer = UnsafeMutableRawPointer.allocate(byteCount: max(listSize, MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPointer.deallocate() }
        let list = listPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)

        var out = Data(count: frameCount * 2 * 2)     // always emit stereo
        out.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            func quantise(_ value: Float) -> Int16 { Int16(max(-1, min(1, value)) * 32767) }
            if isInterleaved, let base = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frameCount {
                    let left = base[frame * channels]
                    let right = channels > 1 ? base[frame * channels + 1] : left
                    samples[frame * 2] = quantise(left)
                    samples[frame * 2 + 1] = quantise(right)
                }
            } else {
                let left = buffers[0].mData?.assumingMemoryBound(to: Float.self)
                let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : left
                for frame in 0..<frameCount {
                    samples[frame * 2] = quantise(left?[frame] ?? 0)
                    samples[frame * 2 + 1] = quantise(right?[frame] ?? 0)
                }
            }
        }
        return out
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    /// Lists displays for the picker. Throws if Screen Recording is denied.
    static func availableDisplays() async throws -> [(id: CGDirectDisplayID, name: String, width: Int, height: Int)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.enumerated().map { index, display in
            (display.displayID, "Display \(index + 1)", display.width, display.height)
        }
    }
}
