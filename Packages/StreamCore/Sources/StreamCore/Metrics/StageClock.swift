import Foundation

/// Monotonic clock used for every pipeline timestamp. Nanoseconds since boot,
/// never affected by wall-clock changes. Values are only comparable on the
/// same device; cross-device latency is measured with ping/pong RTT.
public enum StageClock {
    public static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public static func millis(from start: UInt64, to end: UInt64 = nowNanos()) -> Double {
        Double(end &- start) / 1_000_000
    }
}

/// Per-frame timestamps at each pipeline stage so latency claims are measured,
/// not guessed. Host fills the first three, client the last three.
public struct FrameTimeline: Hashable, Sendable {
    public var frameID: UInt32
    public var captured: UInt64 = 0
    public var encoded: UInt64 = 0
    public var sent: UInt64 = 0
    public var received: UInt64 = 0
    public var decoded: UInt64 = 0
    public var displayed: UInt64 = 0

    public init(frameID: UInt32) { self.frameID = frameID }
}
