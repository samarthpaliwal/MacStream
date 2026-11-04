import Foundation
import os
import StreamCore

/// Snapshot shown in the UI, refreshed once a second.
struct PipelineStats: Equatable {
    var framesPerSecond: Double = 0
    var megabitsPerSecond: Double = 0
    /// Display → delivered to us, averaged over the last second.
    var captureDelayMs: Double = 0
    /// Delivered → encoder output, averaged over the last second.
    var encodeMs: Double = 0
    var totalFrames = 0
    var totalBytes = 0
    var elapsedSeconds: Double = 0
    var keyframes = 0
    var dropped = 0
    var width = 0
    var height = 0

    var summary: String {
        String(format: "%.0f fps · %.1f Mb/s · capture %.1f ms · encode %.1f ms", framesPerSecond, megabitsPerSecond, captureDelayMs, encodeMs)
    }

    /// Averages over the whole run, for the end-of-test report.
    var runSummary: String {
        let seconds = max(elapsedSeconds, 0.001)
        return String(format: "avg %.1f fps · avg %.1f Mb/s over %.1f s", Double(totalFrames) / seconds, Double(totalBytes * 8) / seconds / 1e6, elapsedSeconds)
    }
}

/// Thread-safe accumulator fed from the encoder's output thread.
final class StatsAccumulator {
    private struct Window {
        var frames = 0
        var bytes = 0
        var captureDelayNanos: UInt64 = 0
        var encodeNanos: UInt64 = 0
        var started = StageClock.nowNanos()
    }

    private let state = OSAllocatedUnfairLock(initialState: (window: Window(), totals: PipelineStats()))
    private let runStarted = StageClock.nowNanos()

    func record(_ frame: EncodedFrame) {
        state.withLock { s in
            s.window.frames += 1
            s.window.bytes += frame.data.count
            // Display time can be marginally later than delivery (it is the
            // scheduled display time), so clamp instead of wrapping.
            s.window.captureDelayNanos += frame.deliveredNanos > frame.captureNanos ? frame.deliveredNanos - frame.captureNanos : 0
            s.window.encodeNanos += frame.encodedNanos > frame.deliveredNanos ? frame.encodedNanos - frame.deliveredNanos : 0
            s.totals.totalFrames += 1
            s.totals.totalBytes += frame.data.count
            if frame.isKeyframe { s.totals.keyframes += 1 }
            s.totals.width = frame.width
            s.totals.height = frame.height
        }
    }

    func recordDrop() {
        state.withLock { $0.totals.dropped += 1 }
    }

    /// Returns rates for the window since the last call and resets it.
    func snapshot() -> PipelineStats {
        state.withLock { s in
            var stats = s.totals
            let now = StageClock.nowNanos()
            stats.elapsedSeconds = Double(now &- runStarted) / 1e9
            let seconds = max(Double(now &- s.window.started) / 1e9, 0.001)
            let frames = max(s.window.frames, 1)
            stats.framesPerSecond = Double(s.window.frames) / seconds
            stats.megabitsPerSecond = Double(s.window.bytes * 8) / seconds / 1e6
            stats.captureDelayMs = Double(s.window.captureDelayNanos) / Double(frames) / 1e6
            stats.encodeMs = Double(s.window.encodeNanos) / Double(frames) / 1e6
            s.window = Window(started: now)
            return stats
        }
    }
}
