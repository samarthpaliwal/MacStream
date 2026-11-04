import CoreMedia
import CoreVideo
import Foundation

/// A raw frame from the screen (or a test pattern) on its way to the encoder.
struct CapturedFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    /// When the frame was shown on the Mac display (monotonic nanoseconds).
    let captureNanos: UInt64
    /// When the source handed it to us.
    let deliveredNanos: UInt64
}

struct CaptureConfiguration {
    var displayID: CGDirectDisplayID
    /// Target output size in pixels. Must be even.
    var width: Int
    var height: Int
    var framesPerSecond: Int
    var showsCursor = true
    var capturesAudio = false
}

/// Anything that produces frames: ScreenCaptureKit for real use, a synthetic
/// generator for testing without Screen Recording permission.
protocol FrameSource: AnyObject {
    var onFrame: ((CapturedFrame) -> Void)? { get set }
    /// 48 kHz stereo 16-bit interleaved PCM, when audio capture is on.
    var onAudio: ((Data) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start(_ configuration: CaptureConfiguration) async throws
    func stop() async
}
