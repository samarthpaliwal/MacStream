import Foundation

/// Adaptive bitrate: back off quickly when the client reports loss or dropped
/// frames, recover slowly while things stay clean. Pure logic, no timers, so
/// it is unit tested; the host calls `update` once per client report.
public struct BitrateController: Sendable {
    public struct Decision: Equatable, Sendable {
        public let bitrate: Int
        public let reason: String
    }

    public private(set) var current: Int
    public let maximum: Int
    public let minimum: Int

    private var lastChangeNanos: UInt64 = 0
    private var cleanSince: UInt64?

    /// Unrecovered loss above this (percent, over the report period) triggers a cut.
    public var lossThresholdPercent = 1.0
    /// A single dropped frame per report is noise once retransmission exists;
    /// two or more means the link is genuinely struggling.
    public var droppedFramesThreshold = 2
    /// How long the link must stay clean before stepping back up.
    public var recoveryDelayNanos: UInt64 = 4_000_000_000
    /// Minimum spacing between consecutive changes.
    public var holdNanos: UInt64 = 1_000_000_000

    public init(maximum: Int, minimum: Int, start: Int? = nil) {
        self.maximum = maximum
        self.minimum = min(minimum, maximum)
        self.current = min(max(start ?? maximum, self.minimum), maximum)
    }

    /// Returns a decision only when the bitrate should change.
    public mutating func update(lossPercent: Double, framesDropped: Int, now: UInt64) -> Decision? {
        let troubled = lossPercent > lossThresholdPercent || framesDropped >= droppedFramesThreshold
        if troubled {
            cleanSince = nil
            guard now &- lastChangeNanos >= holdNanos, current > minimum else { return nil }
            let next = max(minimum, Self.kilobits(Double(current) * 0.8))
            lastChangeNanos = now
            current = next
            return Decision(bitrate: next, reason: String(format: "loss %.1f%%, %d dropped", lossPercent, framesDropped))
        }

        if cleanSince == nil { cleanSince = now }
        guard let cleanSince, now &- cleanSince >= recoveryDelayNanos, current < maximum,
              now &- lastChangeNanos >= holdNanos else { return nil }
        let next = min(maximum, Self.kilobits(Double(current) * 1.15))
        lastChangeNanos = now
        self.cleanSince = now
        current = next
        return Decision(bitrate: next, reason: "link clean")
    }

    private static func kilobits(_ bitsPerSecond: Double) -> Int {
        Int((bitsPerSecond / 1000).rounded()) * 1000
    }

    /// New ceiling (quality preset changed). Current is clamped, not reset.
    public mutating func resetToMaximum() {
        current = maximum
        cleanSince = nil
        lastChangeNanos = 0
    }
}
