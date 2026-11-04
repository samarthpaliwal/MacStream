import CoreMedia
import CoreVideo
import Foundation
import StreamCore

/// Generates a moving test pattern at the requested frame rate. Used to
/// exercise the encoder and recorder without Screen Recording permission,
/// and later to measure pipeline latency with a known input.
final class SyntheticFrameSource: FrameSource {
    var onFrame: ((CapturedFrame) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onError: ((Error) -> Void)?

    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private let queue = DispatchQueue(label: "macstream.synthetic", qos: .userInteractive)
    private var frameIndex = 0
    private var width = 0
    private var height = 0
    private var chromaRow: [UInt8] = []

    func start(_ configuration: CaptureConfiguration) async throws {
        width = configuration.width
        height = configuration.height

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        self.pool = pool

        let interval = 1.0 / Double(configuration.framesPerSecond)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() async {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }

        draw(into: buffer, frame: frameIndex)
        frameIndex += 1
        // Stamp after drawing so synthetic rendering cost is not counted as encode time.
        let now = StageClock.nowNanos()

        onFrame?(CapturedFrame(
            pixelBuffer: buffer,
            presentationTime: CMTime(value: CMTimeValue(now / 1000), timescale: 1_000_000),
            captureNanos: now,
            deliveredNanos: now
        ))
    }

    /// Gradient background plus a bar that sweeps across every two seconds,
    /// so there is both static detail and motion for the encoder.
    private func draw(into buffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let barX = (frame * 8) % max(width, 1)
        let barWidth = max(width / 20, 8)

        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            let barEnd = min(barX + barWidth, width)
            for y in 0..<height {
                let row = luma + y * stride
                let rowShade = Int32(16 + (y * 200) / max(height, 1))
                memset(row, rowShade, width)
                memset(row + barX, 235, barEnd - barX)
            }
        }
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chroma = base.assumingMemoryBound(to: UInt8.self)
            // One chroma row (Cb ramp, neutral Cr), copied to every row.
            if chromaRow.count != width {
                chromaRow = (0..<(width / 2)).flatMap { x in
                    [UInt8(64 + (x * 128) / max(width / 2, 1)), 128]
                }
            }
            chromaRow.withUnsafeBytes { template in
                for y in 0..<(height / 2) {
                    memcpy(chroma + y * stride, template.baseAddress!, width)
                }
            }
        }
    }
}
