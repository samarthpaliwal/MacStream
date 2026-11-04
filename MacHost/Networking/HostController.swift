import AppKit
import CryptoKit
import Foundation
import Network
import StreamCore

/// Owns the Bonjour listener and the single active session.
///
/// Two listener modes:
/// - paired: the PSK is the long-term key; only iPads in `PairingStore` may
///   complete the handshake.
/// - pairing: the PSK comes from a one-time six-digit code. The first iPad
///   to complete the handshake is added to the store and handed the
///   long-term key, then the listener returns to paired mode.
@MainActor
final class HostController {
    static let shared = HostController()

    enum Mode: Equatable {
        case paired
        case pairing(code: PairingCode)
    }

    /// One client's connection, control channel and video channel.
    private final class Session {
        let channel: ControlChannel
        let videoSender: VideoSender
        var handshakeComplete = false
        var device: DeviceInfo?
        var clientScreen: ScreenInfo?
        init(channel: ControlChannel, videoSender: VideoSender) {
            self.channel = channel
            self.videoSender = videoSender
        }
    }

    private let state = AppState.shared
    private let store = PairingStore.shared
    private(set) var mode: Mode = .paired
    private var listener: NWListener?
    private var listenerKey: SymmetricKey?
    private var session: Session?
    private var isStreaming = false
    private var handshakeFailures = 0
    private var pairingTimeout: Task<Void, Never>?
    private var statsTimer: Timer?
    private var bitrateController: BitrateController?
    private var lastClientStats: ClientStats?
    private let clipboard = ClipboardSync()
    private let cursorTracker = CursorTracker()
    private var virtualDisplay: VirtualDisplay?

    /// Code rotates after this many failed handshakes in pairing mode. One
    /// client attempt typically shows up as ~3 failures (one per address).
    private let maxHandshakeFailures = 15
    private let pairingWindow: Duration = .seconds(120)

    private init() {}

    // MARK: Lifecycle

    func start() {
        if let override = ProcessInfo.processInfo.environment["MACSTREAM_PAIRING_CODE"],
           let code = PairingCode(digits: override) {
            enterPairingMode(code: code)         // automated testing only
        } else if store.devices.isEmpty {
            enterPairingMode()
        } else {
            enterPairedMode()
        }
    }

    func stop() {
        endSession(reason: nil)
        listener?.cancel()
        listener = nil
        pairingTimeout?.cancel()
        state.connection = .idle
    }

    /// Shows a fresh one-time code for two minutes.
    func enterPairingMode(code: PairingCode = .random()) {
        mode = .pairing(code: code)
        state.pairingCode = code
        handshakeFailures = 0
        startListener(key: PairingKeyDerivation.sharedKey(code: code, hostID: state.identity.id))
        state.log("Pairing mode: code \(code.formatted) valid for 2 minutes")

        pairingTimeout?.cancel()
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(for: self?.pairingWindow ?? .seconds(120))
            guard let self, !Task.isCancelled, case .pairing = mode else { return }
            if store.devices.isEmpty {
                enterPairingMode()               // nothing paired yet: keep offering a code
            } else {
                state.log("Pairing window closed")
                enterPairedMode()
            }
        }
    }

    func enterPairedMode() {
        pairingTimeout?.cancel()
        mode = .paired
        state.pairingCode = nil
        handshakeFailures = 0
        startListener(key: store.pairedKey)
    }

    func cancelPairing() {
        if store.devices.isEmpty {
            enterPairingMode()
        } else {
            enterPairedMode()
        }
    }

    func forgetDevice(_ id: UUID) {
        store.remove(id)
        if session?.device?.id == id {
            endSession(reason: "This iPad was removed from the Mac")
        }
        if store.devices.isEmpty { enterPairingMode() }
    }

    func resetAllPairings() {
        endSession(reason: "The Mac reset its pairings")
        store.resetAll()
        enterPairingMode()
    }

    func disconnectClient() {
        endSession(reason: "Disconnected from the Mac")
    }

    func send(_ message: ControlMessage) {
        session?.channel.send(message)
    }

    // MARK: Listener

    private func startListener(key: SymmetricKey) {
        listener?.cancel()
        listenerKey = key
        do {
            let listener = try NWListener(using: ControlTransport.tlsParameters(psk: key))
            var pairing = false
            if case .pairing = mode { pairing = true }
            listener.service = NWListener.Service(
                name: state.identity.name,
                type: StreamService.bonjourType,
                domain: nil,
                txtRecord: NWTXTRecord([
                    StreamService.txtHostID: state.identity.id.uuidString,
                    StreamService.txtVersion: "\(StreamService.protocolVersion)",
                    StreamService.txtPairing: pairing ? "1" : "0",
                ])
            )
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in self?.listenerStateChanged(newState, listener: listener) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, key: key) }
            }
            listener.start(queue: DispatchQueue(label: "macstream.listener"))
            self.listener = listener
        } catch {
            state.log("Listener failed to start: \(error.localizedDescription)")
            state.connection = .idle
        }
    }

    private func listenerStateChanged(_ newState: NWListener.State, listener: NWListener) {
        guard listener === self.listener else { return }
        switch newState {
        case .ready:
            if !state.connection.isConnected { state.connection = .advertising }
            if let port = listener.port { state.log("Listening on TCP port \(port)") }
        case .failed(let error):
            state.log("Listener failed: \(error.localizedDescription)")
            state.connection = .idle
        default:
            break
        }
    }

    // MARK: Sessions

    private func accept(_ connection: NWConnection, key: SymmetricKey) {
        guard session == nil else {
            connection.cancel()                  // one client at a time
            return
        }
        guard let videoSender = try? VideoSender(crypto: VideoCrypto(psk: key)) else {
            connection.cancel()
            return
        }
        videoSender.onLog = { [weak self] line in Task { @MainActor in self?.state.log(line) } }
        videoSender.start()

        let channel = ControlChannel(connection: connection)
        let session = Session(channel: channel, videoSender: videoSender)
        channel.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event, session: session) }
        }
        channel.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message, session: session) }
        }
        self.session = session
        channel.start()
    }

    private func endSession(reason: String?) {
        guard let session else { return }
        if let reason {
            session.channel.sendAndClose(.disconnect(reason: reason))
        } else {
            session.channel.cancel()
        }
        cleanUp(session)
    }

    private func cleanUp(_ session: Session) {
        guard session === self.session else { return }
        session.videoSender.stop()
        stopStreaming()
        self.session = nil
        state.connection = listener == nil ? .idle : .advertising
    }

    private func handle(_ event: ControlChannel.Event, session: Session) {
        guard session === self.session else { return }
        switch event {
        case .ready:
            state.log("TLS established with \(session.channel.remoteDescription)")
        case .closed(let error):
            let detail = error.map { ": \($0.localizedDescription)" } ?? ""
            if session.handshakeComplete {
                state.log("Client disconnected\(detail)")
            } else {
                handshakeFailures += 1
                state.log("Connection ended before handshake (\(handshakeFailures))\(detail)")
            }
            cleanUp(session)
            if case .pairing = mode, handshakeFailures >= maxHandshakeFailures {
                state.log("Too many failed attempts, rotating pairing code")
                enterPairingMode()
            }
        }
    }

    private func handle(_ message: ControlMessage, session: Session) {
        guard session === self.session else { return }
        switch message {
        case .hello(let hello):
            completeHandshake(hello, session: session)

        case .ping(let id, let sentAtNanos):
            session.channel.send(.pong(id: id, sentAtNanos: sentAtNanos, hostNanos: StageClock.nowNanos()))

        case .clientStats(let stats):
            lastClientStats = stats
            state.clientStats = stats
            adaptBitrate(to: stats)

        case .text(let text):
            state.lastReceivedText = text
            state.log("iPad says: \(text)")
            session.channel.send(.text("Mac received: \(text)"))

        case .setQuality(let quality):
            guard quality != state.quality else { break }
            state.quality = quality
            state.log("Quality → \(quality.title)")
            if isStreaming { Task { await restartCapture() } }

        case .requestKeyframe:
            CaptureController.shared.requestKeyframe()

        case .nack(let frameID, let chunks):
            session.videoSender.resend(frameID: frameID, chunks: chunks)

        case .input(let event):
            // Only reachable on an authenticated, paired session.
            guard session.handshakeComplete else { return }
            InputInjector.shared.inject(event, displayID: state.displayID)

        case .clipboard(let text):
            guard session.handshakeComplete, HostSettings.shared.shareClipboard else { return }
            clipboard.apply(remote: text)
            state.log("Clipboard ← iPad (\(text.count) chars)")

        case .disconnect(let reason):
            state.log("iPad disconnected: \(reason)")
            session.channel.cancel()

        case .helloAck, .pong, .pairingComplete, .hostStats, .cursorImage, .cursorPosition:
            break
        }
    }

    private func completeHandshake(_ hello: HelloPayload, session: Session) {
        guard hello.protocolVersion == StreamService.protocolVersion else {
            session.channel.sendAndClose(.disconnect(reason: "Protocol version mismatch: Mac \(StreamService.protocolVersion), iPad \(hello.protocolVersion)"))
            return
        }

        switch mode {
        case .pairing:
            // Whoever knows the code gets paired, then the code is retired.
            store.add(PairedDevice(id: hello.device.id, name: hello.device.name, platform: hello.device.platform))
            let key = store.pairedKey.withUnsafeBytes { Data($0) }
            session.channel.send(.pairingComplete(key: key))
            state.log("Paired \(hello.device.name)")
            enterPairedMode()                    // new listener; this session keeps its TLS connection
        case .paired:
            guard store.isPaired(hello.device.id) else {
                state.log("Rejected \(hello.device.name): not paired")
                session.channel.sendAndClose(.disconnect(reason: "This iPad is not paired with this Mac. Pair it from the Mac's menu bar."))
                return
            }
        }

        session.handshakeComplete = true
        session.device = hello.device
        session.clientScreen = hello.screen
        handshakeFailures = 0
        chooseDisplay(for: hello.screen)
        session.channel.send(.helloAck(HelloPayload(device: state.identity, videoPort: session.videoSender.port), display: Self.displayInfo(for: state.displayID)))
        state.connection = .connected(clientName: hello.device.name)
        state.log("Handshake complete with \(hello.device.name)")
        startStreaming(session)
    }

    // MARK: Streaming

    /// Settings changed while streaming: restart capture with the new ones.
    func settingsChanged() {
        if isStreaming {
            Task { await restartCapture() }
        } else {
            state.displayID = HostSettings.shared.resolvedMirrorDisplayID
        }
    }

    /// Mirror the chosen display, or create a virtual one sized to the iPad.
    private func chooseDisplay(for screen: ScreenInfo?) {
        virtualDisplay = nil
        let settings = HostSettings.shared
        if settings.displayMode == .extended, let screen {
            if let display = VirtualDisplay(name: "MacStream iPad", pointWidth: screen.pointWidth, pointHeight: screen.pointHeight, hiDPI: screen.scale >= 2) {
                virtualDisplay = display
                state.displayID = display.displayID
                state.log("Extended display created: \(screen.pointWidth)×\(screen.pointHeight) pt @\(screen.scale >= 2 ? "2x" : "1x")")
                return
            }
            state.log("Extended display unavailable on this macOS; mirroring instead")
        }
        state.displayID = settings.resolvedMirrorDisplayID
    }

    private func startStreaming(_ session: Session) {
        guard !isStreaming else { return }
        isStreaming = true
        let capture = CaptureController.shared
        let sender = session.videoSender
        capture.onEncodedFrame = { frame in sender.send(frame) }
        capture.onAudioChunk = { pcm in sender.sendAudio(pcm) }
        InputInjector.shared.moveCursorToCenter(of: state.displayID)
        session.channel.send(.cursorPosition(NormalizedPoint(x: 0.5, y: 0.5)))
        cursorTracker.onChange = { [weak session] image in session?.channel.send(.cursorImage(image)) }
        cursorTracker.start()
        if HostSettings.shared.shareClipboard {
            clipboard.onLocalChange = { [weak self, weak session] text in
                session?.channel.send(.clipboard(text: text))
                self?.state.log("Clipboard → iPad (\(text.count) chars)")
            }
            clipboard.start()
        }
        resetBitrateController()
        Task {
            if capture.isRunning { await capture.stop() }   // a test recording was in progress
            await capture.start()
            capture.requestKeyframe()
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendHostStats() }
        }
    }

    private func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
        statsTimer?.invalidate()
        statsTimer = nil
        state.clientStats = nil
        clipboard.stop()
        cursorTracker.stop()
        let capture = CaptureController.shared
        capture.onEncodedFrame = nil
        capture.onAudioChunk = nil
        Task {
            await capture.stop()
            // Tear the virtual display down only after capture has let go of it.
            virtualDisplay = nil
            state.displayID = HostSettings.shared.resolvedMirrorDisplayID
        }
    }

    private func restartCapture() async {
        let capture = CaptureController.shared
        await capture.stop()
        guard isStreaming else { return }
        chooseDisplay(for: session?.clientScreen)
        resetBitrateController()
        await capture.start()
        capture.requestKeyframe()
    }

    // MARK: Stats and adaptive bitrate

    private func resetBitrateController() {
        let maximum = Int(state.quality.targetBitrateMbps * 1_000_000)
        bitrateController = BitrateController(maximum: maximum, minimum: min(maximum, 3_000_000))
    }

    private func adaptBitrate(to stats: ClientStats) {
        guard isStreaming, var controller = bitrateController else { return }
        if let decision = controller.update(lossPercent: stats.lossPercent, framesDropped: stats.framesDropped, now: StageClock.nowNanos()) {
            CaptureController.shared.setBitrate(decision.bitrate)
            state.log(String(format: "Bitrate → %.1f Mb/s (%@)", Double(decision.bitrate) / 1e6, decision.reason))
        }
        bitrateController = controller
    }

    private func sendHostStats() {
        guard let session, session.handshakeComplete else { return }
        let capture = CaptureController.shared
        let sent = session.videoSender.snapshot()
        let stats = HostStats(
            framesPerSecond: capture.stats.framesPerSecond,
            captureDelayMs: capture.stats.captureDelayMs,
            encodeMs: capture.stats.encodeMs,
            sendMbps: Double(sent.windowBytes * 8) / 1e6,
            encoderBitrateMbps: Double(capture.encoderBitrate) / 1e6,
            targetBitrateMbps: state.quality.targetBitrateMbps,
            pendingPackets: sent.pending
        )
        session.channel.send(.hostStats(stats))
        if sent.droppedFrames > state.senderDroppedFrames {
            state.log("Sender dropped \(sent.droppedFrames - state.senderDroppedFrames) stale frame(s) (network behind)")
        }
        state.senderDroppedFrames = sent.droppedFrames
    }

    /// Geometry of the display being captured (not necessarily the focused one).
    private static func displayInfo(for displayID: CGDirectDisplayID) -> DisplayInfo? {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 else { return nil }
        let (pixelWidth, pixelHeight) = CaptureController.displayPixelSize(displayID)
        let refresh = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 60
        return DisplayInfo(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pointWidth: bounds.width,
            pointHeight: bounds.height,
            refreshRate: refresh > 0 ? refresh : 60
        )
    }
}
