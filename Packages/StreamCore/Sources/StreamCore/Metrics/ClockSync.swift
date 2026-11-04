import Foundation

/// Estimates the offset between the host's and the client's monotonic clocks
/// from ping/pong round trips, NTP style: the sample with the smallest round
/// trip is the most trustworthy, so only it is kept.
///
/// With the offset known, a host timestamp inside a video packet can be
/// compared with a client timestamp, which is how end-to-end latency is
/// measured without any wall-clock agreement between devices.
public struct ClockSync: Sendable {
    /// host clock minus client clock, in nanoseconds.
    public private(set) var offsetNanos: Int64?
    public private(set) var bestRoundTripNanos: UInt64 = .max
    public private(set) var sampleCount = 0

    public init() {}

    /// - Parameters:
    ///   - clientSent: client clock when the ping left.
    ///   - hostReceived: host clock when the ping arrived (echoed in the pong).
    ///   - clientReceived: client clock when the pong arrived.
    public mutating func addSample(clientSent: UInt64, hostReceived: UInt64, clientReceived: UInt64) {
        guard clientReceived >= clientSent else { return }
        let roundTrip = clientReceived - clientSent
        sampleCount += 1
        // Assume symmetric paths: the host saw the ping halfway through the round trip.
        let midpoint = Int64(clientSent) + Int64(roundTrip / 2)
        let offset = Int64(hostReceived) - midpoint
        if roundTrip <= bestRoundTripNanos {
            bestRoundTripNanos = roundTrip
            offsetNanos = offset
        }
    }

    /// Converts a host timestamp to the client's clock. Nil until a sample exists.
    public func clientNanos(fromHost hostNanos: UInt64) -> UInt64? {
        guard let offsetNanos else { return nil }
        let value = Int64(hostNanos) - offsetNanos
        return value > 0 ? UInt64(value) : 0
    }

    /// Forget the best sample so a route change does not pin a stale offset.
    public mutating func decay() {
        bestRoundTripNanos = .max
    }
}
