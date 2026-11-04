import AppKit
import CoreImage
import Foundation
import StreamCore

/// Runs the capture → encode pipeline and optionally records it to a file.
/// Milestone 4 adds a network sink next to the recorder.
@MainActor
final class CaptureController: ObservableObject {
    static let shared = CaptureController()

    enum SourceKind: String, CaseIterable, Identifiable {
        case screen, synthetic
        var id: String { rawValue }
        var title: String { self == .screen ? "Screen" : "Test pattern" }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var stats = PipelineStats()
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastError: String?
    @Published var sourceKind: SourceKind = .screen

    /// Receives every encoded frame while running. Set by the network sink.
    var onEncodedFrame: ((EncodedFrame) -> Void)?
    /// Receives PCM audio chunks while running with audio enabled.
    var onAudioChunk: ((Data) -> Void)?

    private var source: FrameSource?
    private var encoder: VideoEncoder?
    private var recorder: CaptureRecorder?
    private let accumulator = StatsAccumulator()
    private var statsTimer: Timer?
    private var stopTask: Task<Void, Never>?

    private init() {}

    // MARK: Public

    /// Records a short clip, then stops and reveals it in Finder.
    func recordTestClip(seconds: Int) {
        guard !isRunning else { return }
        let url = Self.recordingURL()
        Task {
            await start(recordingTo: url)
            guard isRunning else { return }
            stopTask = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await stop()
            }
        }
    }

    func start(recordingTo url: URL? = nil) async {
        guard !isRunning else { return }
        lastError = nil
        let appState = AppState.shared

        let (pixelWidth, pixelHeight) = Self.displayPixelSize(appState.displayID)
        let scale = appState.quality.resolutionScale
        let settings = HostSettings.shared
        let configuration = CaptureConfiguration(
            displayID: appState.displayID,
            width: Self.even(Int(Double(pixelWidth) * scale)),
            height: Self.even(Int(Double(pixelHeight) * scale)),
            framesPerSecond: settings.frameRate,
            showsCursor: settings.showCursor && url != nil,   // the iPad draws the cursor while streaming
            capturesAudio: settings.streamAudio && url == nil && sourceKind == .screen
        )

        do {
            let encoder = try VideoEncoder(configuration: .init(
                codec: appState.codec,
                width: configuration.width,
                height: configuration.height,
                framesPerSecond: configuration.framesPerSecond,
                bitrateBitsPerSecond: Int(appState.quality.targetBitrateMbps * 1_000_000)
            ))
            let recorder = try url.map { try CaptureRecorder(url: $0) }
            let source: FrameSource = sourceKind == .screen ? ScreenCapturer() : SyntheticFrameSource()

            encoder.onOutput = { [weak self, accumulator] sampleBuffer, frame in
                accumulator.record(frame)
                recorder?.append(sampleBuffer)
                self?.onEncodedFrame?(frame)
            }
            encoder.onDrop = { [accumulator] in accumulator.recordDrop() }
            source.onFrame = { [weak self, encoder] frame in
                if let self, self.dumpNextFrame { Task { @MainActor in self.dumpIfRequested(frame) } }
                encoder.encode(frame)
            }
            source.onAudio = { [weak self] pcm in self?.onAudioChunk?(pcm) }
            source.onError = { [weak self] error in
                Task { @MainActor in
                    self?.lastError = error.localizedDescription
                    await self?.stop()
                }
            }

            try await source.start(configuration)

            self.source = source
            self.encoder = encoder
            self.recorder = recorder
            encoderBitrate = encoder.configuration.bitrateBitsPerSecond
            isRunning = true
            isRecording = recorder != nil
            _ = accumulator.snapshot()
            statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshStats() }
            }
            appState.log("Capture started: \(configuration.width)×\(configuration.height) \(appState.codec == .hevc ? "HEVC" : "H.264") @ \(Int(appState.quality.targetBitrateMbps)) Mb/s, \(configuration.framesPerSecond) fps\(configuration.capturesAudio ? ", audio" : "") via \(sourceKind.title)")
        } catch {
            lastError = error.localizedDescription
            appState.log("Capture failed: \(error.localizedDescription)")
        }
    }

    func stop() async {
        stopTask?.cancel()
        stopTask = nil
        statsTimer?.invalidate()
        statsTimer = nil
        refreshStats()

        await source?.stop()
        source = nil
        encoder = nil

        if let recorder {
            if let error = await recorder.finish() {
                lastError = "Recording failed: \(error.localizedDescription)"
            } else {
                lastRecordingURL = recorder.url
                AppState.shared.log("Saved \(recorder.url.lastPathComponent) (\(stats.totalFrames) frames, \(recorder.droppedFrames) not written)")
            }
        }
        recorder = nil
        isRunning = false
        isRecording = false
    }

    private var lastKeyframeRequest: UInt64 = 0

    /// At most one forced keyframe per 100 ms, so a burst of loss reports
    /// does not turn into a keyframe storm that makes the loss worse.
    func requestKeyframe() {
        let now = StageClock.nowNanos()
        guard now &- lastKeyframeRequest > 100_000_000 else { return }
        lastKeyframeRequest = now
        encoder?.requestKeyframe()
    }

    /// Current encoder target in bits per second (adaptive while streaming).
    @Published private(set) var encoderBitrate = 0

    func setBitrate(_ bitsPerSecond: Int) {
        guard bitsPerSecond != encoderBitrate else { return }
        encoderBitrate = bitsPerSecond
        encoder?.setBitrate(bitsPerSecond)
    }

    func revealLastRecording() {
        guard let lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
    }

    // MARK: Helpers

    private func refreshStats() {
        stats = accumulator.snapshot()
        // Diagnostics: touching .build/dumpframe saves the next captured frame as PNG.
        let flag = URL(fileURLWithPath: Self.dumpFlagPath)
        if FileManager.default.fileExists(atPath: flag.path) {
            try? FileManager.default.removeItem(at: flag)
            dumpNextFrame = true
        }
    }

    private static let dumpFlagPath = "/Users/samarth.p/Developer/MacStream/.build/dumpframe"
    private var dumpNextFrame = false

    private func dumpIfRequested(_ frame: CapturedFrame) {
        guard dumpNextFrame else { return }
        dumpNextFrame = false
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let context = CIContext()
        let url = URL(fileURLWithPath: "/Users/samarth.p/Developer/MacStream/.build/frame.png")
        try? context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        AppState.shared.log("Frame dumped to \(url.path) (\(CVPixelBufferGetWidth(frame.pixelBuffer))×\(CVPixelBufferGetHeight(frame.pixelBuffer)))")
    }

    static func recordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return movies.appendingPathComponent("MacStream/MacStream-\(formatter.string(from: Date())).mov")
    }

    /// Native pixel size. `CGDisplayPixelsWide` returns points on Retina
    /// displays, so read the current display mode instead.
    static func displayPixelSize(_ displayID: CGDirectDisplayID) -> (Int, Int) {
        if let mode = CGDisplayCopyDisplayMode(displayID), mode.pixelWidth > 0 {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        return (1920, 1080)
    }

    /// Encoders want even dimensions; round down to a multiple of 2.
    static func even(_ value: Int) -> Int {
        max(value - value % 2, 2)
    }
}
