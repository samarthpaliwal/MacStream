import AVFoundation
import Foundation

/// Writes already-encoded sample buffers straight into a .mov (no re-encode),
/// so the file shows exactly what the network would carry.
final class CaptureRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "macstream.recorder")
    private(set) var droppedFrames = 0

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [self] in
            if input == nil {
                guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { return }
                writer.add(input)
                self.input = input
                writer.startWriting()
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
            guard let input, input.isReadyForMoreMediaData, writer.status == .writing else {
                droppedFrames += 1
                return
            }
            if !input.append(sampleBuffer) {
                droppedFrames += 1
            }
        }
    }

    func finish() async -> Error? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard writer.status == .writing else {
                    continuation.resume(returning: writer.error)
                    return
                }
                input?.markAsFinished()
                writer.finishWriting {
                    continuation.resume(returning: self.writer.error)
                }
            }
        }
    }
}
