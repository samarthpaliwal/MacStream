import CryptoKit
import Foundation
import Network
import os
import StreamCore
import UIKit

/// One connection attempt to one Mac: TLS, handshake, pings, test messages.
/// Created fresh for every connect so there is no stale state to reset.
@MainActor
final class ClientSession: ObservableObject, Identifiable {
    enum Status: Equatable {
        case connecting
        case handshaking
        case connected
        case failed(String)
        case closed

        var title: String {
            switch self {
            case .connecting: return "Connecting…"
            case .handshaking: return "Securing connection…"
            case .connected: return "Connected"
            case .failed(let reason): return "Failed: \(reason)"
            case .closed: return "Disconnected"
            }
        }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    let host: DiscoveredHost
    /// True when connecting with a stored key rather than a fresh code.
    let usesStoredKey: Bool
    @Published private(set) var status: Status = .connecting
    @Published private(set) var justPaired = false
    @Published private(set) var rttMillis: Double?
    @Published private(set) var display: DisplayInfo?
    @Published private(set) var hostDevice: DeviceInfo?
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var videoStats = VideoStats()
    @Published private(set) var hostStats: HostStats?
    private let clockSync = OSAllocatedUnfairLock(initialState: ClockSync())
    private var lastReportedStats = VideoStats()
    @Published private(set) var hasVideo = false
    @Published var softwareKeyboardVisible = false
    @Published private(set) var inputEventsSent = 0

    let renderer = VideoRenderer()
    private let decoder = VideoDecoder()
    private var videoReceiver: VideoReceiver?
    private let audioPlayer = AudioPlayer()
    private let clipboard = ClientClipboard()
    @Published var audioMuted = false {
        didSet { audioPlayer.isMuted = audioMuted }
    }

    // On-screen modifier strip. One-shot modifiers clear after the next key
    // or click; locked ones stay until tapped again.
    @Published private(set) var latchedModifiers: KeyModifiers = []
    @Published private(set) var lockedModifiers: KeyModifiers = []
    @Published var showKeyStrip = false
    @Published var invertScroll = UserDefaults.standard.bool(forKey: "invertScroll") {
        didSet { UserDefaults.standard.set(invertScroll, forKey: "invertScroll") }
    }
    /// The UIKit input view, so strip buttons send keys through the same path.
    weak var inputView: InputCaptureUIView?

    func toggleModifier(_ modifier: KeyModifiers) {
        if lockedModifiers.contains(modifier) {
            lockedModifiers.remove(modifier)
            latchedModifiers.remove(modifier)
        } else if latchedModifiers.contains(modifier) {
            latchedModifiers.remove(modifier)
        } else {
            latchedModifiers.insert(modifier)
        }
        send(.input(.modifiersChanged(latchedModifiers)))
    }

    func lockModifier(_ modifier: KeyModifiers) {
        lockedModifiers.insert(modifier)
        latchedModifiers.insert(modifier)
        send(.input(.modifiersChanged(latchedModifiers)))
    }

    /// Called after a key or click went out: drop the one-shot modifiers.
    func modifiersConsumed() {
        let remaining = latchedModifiers.intersection(lockedModifiers)
        guard remaining != latchedModifiers else { return }
        latchedModifiers = remaining
        send(.input(.modifiersChanged(latchedModifiers)))
    }

    private let identity: DeviceInfo
    private let key: SymmetricKey
    private var channel: ControlChannel?
    private var pingTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var nextPingID: UInt32 = 0

    /// A wrong PSK makes the Mac drop the TLS handshake, but Network framework
    /// keeps retrying other resolved addresses instead of failing. Bound it.
    private let handshakeTimeout: Duration = .seconds(6)

    init(host: DiscoveredHost, key: SymmetricKey, usesStoredKey: Bool, identity: DeviceInfo) {
        self.host = host
        self.key = key
        self.usesStoredKey = usesStoredKey
        self.identity = identity
    }

    func start() {
        guard host.hostID != nil else {
            status = .failed("This Mac did not announce an identity")
            return
        }
        let connection = NWConnection(to: host.endpoint, using: ControlTransport.tlsParameters(psk: key))
        let channel = ControlChannel(connection: connection)
        channel.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        channel.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        self.channel = channel
        append("Connecting to \(host.name)")
        channel.start()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: self?.handshakeTimeout ?? .seconds(6))
            guard let self, !Task.isCancelled else { return }
            if self.status == .connecting || self.status == .handshaking {
                self.status = .failed(self.usesStoredKey ? "The Mac did not accept the stored pairing, or did not respond" : "Wrong pairing code, or the Mac did not respond")
                self.append(self.status.title)
                self.channel?.cancel()
            }
        }
    }

    func sendTestMessage() {
        send(.text("Hello from \(identity.name)"))
        append("Sent test message")
    }

    func send(_ message: ControlMessage) {
        channel?.send(message)
    }

    func sendInput(_ event: InputEvent) {
        guard status == .connected else { return }
        inputEventsSent += 1
        channel?.send(.input(event))
    }

    func close() {
        pingTask?.cancel()
        timeoutTask?.cancel()
        videoReceiver?.stop()
        videoReceiver = nil
        audioPlayer.stop()
        clipboard.stop()
        channel?.sendAndClose(.disconnect(reason: "User disconnected"))
        if status == .connected || status == .handshaking || status == .connecting {
            status = .closed
        }
    }

    // MARK: Handlers

    private func handle(_ event: ControlChannel.Event) {
        switch event {
        case .ready:
            status = .handshaking
            append("TLS established, sending hello")
            send(.hello(HelloPayload(device: identity, screen: Self.screenInfo())))

        case .closed(let error):
            pingTask?.cancel()
            switch status {
            case .connecting:
                status = .failed(error.map(Self.describe) ?? "Connection refused")
            case .handshaking:
                status = .failed(usesStoredKey ? "The Mac rejected the stored pairing" : "Wrong pairing code or the Mac rejected the connection")
            case .connected:
                status = .closed
            default:
                return  // already reported (timeout or explicit close)
            }
            append(status.title)
        }
    }

    private func handle(_ message: ControlMessage) {
        switch message {
        case .helloAck(let hello, let display):
            hostDevice = hello.device
            self.display = display
            timeoutTask?.cancel()
            status = .connected
            append("Handshake complete with \(hello.device.name)")
            if let display {
                append("Display \(display.pixelWidth)×\(display.pixelHeight) @ \(Int(display.refreshRate)) Hz")
            }
            startPinging()
            startVideo(port: hello.videoPort)

        case .pong(_, let sentAtNanos, let hostNanos):
            let now = StageClock.nowNanos()
            rttMillis = StageClock.millis(from: sentAtNanos, to: now)
            clockSync.withLock { $0.addSample(clientSent: sentAtNanos, hostReceived: hostNanos, clientReceived: now) }

        case .hostStats(let stats):
            hostStats = stats

        case .pairingComplete(let keyData):
            guard let hostID = host.hostID, keyData.count == 32 else { break }
            if ClientPairingStore.save(SymmetricKey(data: keyData), for: hostID) {
                justPaired = true
                append("Paired with \(host.name); key stored in Keychain")
            } else {
                append("Paired, but the Keychain refused to store the key (unsigned build?)")
            }

        case .text(let text):
            append("Mac says: \(text)")

        case .clipboard(let text):
            clipboard.apply(remote: text)

        case .disconnect(let reason):
            append("Mac disconnected: \(reason)")
            status = .failed(reason)
            channel?.cancel()

        case .hello, .ping, .requestKeyframe, .nack, .setQuality, .input, .clientStats:
            break
        }
    }

    private func startVideo(port: UInt16?) {
        guard let port, let nwPort = NWEndpoint.Port(rawValue: port) else {
            append("Mac did not announce a video port")
            return
        }
        guard case .hostPort(let host, _)? = channel?.connection.currentPath?.remoteEndpoint else {
            append("Could not determine the Mac's address for video")
            return
        }
        let receiver = VideoReceiver(host: host, port: nwPort, crypto: VideoCrypto(psk: key), decoder: decoder, renderer: renderer)
        let sync = clockSync
        receiver.hostToClientNanos = { hostNanos in
            sync.withLock { $0.clientNanos(fromHost: hostNanos) }
        }
        receiver.onStats = { [weak self] stats in
            Task { @MainActor in
                guard let self else { return }
                self.videoStats = stats
                self.reportStats(stats)
            }
        }
        receiver.onKeyframeNeeded = { [weak self] in
            Task { @MainActor in self?.send(.requestKeyframe) }
        }
        receiver.onNack = { [weak self] frameID, chunks in
            Task { @MainActor in self?.send(.nack(frameID: frameID, chunks: chunks)) }
        }
        let audio = audioPlayer
        receiver.onAudio = { pcm in audio.play(pcm) }
        audio.start()
        clipboard.onLocalChange = { [weak self] text in self?.send(.clipboard(text: text)) }
        clipboard.start()
        receiver.onFirstFrame = { [weak self] in
            Task { @MainActor in
                self?.hasVideo = true
                self?.append("First frame decoded")
            }
        }
        receiver.onError = { [weak self] message in
            Task { @MainActor in self?.append(message) }
        }
        videoReceiver = receiver
        receiver.start()
        append("Video channel → \(host):\(port)")
    }

    /// Once a second: the numbers the Mac's bitrate controller reacts to.
    /// Loss and drops are deltas since the previous report.
    private func reportStats(_ stats: VideoStats) {
        guard status == .connected else { return }
        // Only loss that retransmission did not repair counts against the bitrate.
        let lostNow = max((stats.packetsLost - lastReportedStats.packetsLost) - (stats.packetsRecovered - lastReportedStats.packetsRecovered), 0)
        let receivedNow = stats.packetsReceived - lastReportedStats.packetsReceived
        let droppedNow = stats.framesDropped - lastReportedStats.framesDropped
        lastReportedStats = stats
        let total = lostNow + receivedNow
        send(.clientStats(ClientStats(
            lossPercent: total > 0 ? Double(lostNow) * 100 / Double(total) : 0,
            packetsLost: lostNow,
            framesDropped: droppedNow,
            framesPerSecond: stats.framesPerSecond,
            decodeMs: stats.decodeMs,
            roundTripMs: rttMillis ?? 0,
            endToEndMs: stats.endToEndMs
        )))
    }

    /// Orientation-aware: `bounds` follows the interface orientation, so an
    /// extended display is landscape when the iPad is held that way.
    @MainActor
    private static func screenInfo() -> ScreenInfo {
        let screen = UIScreen.main
        let points = screen.bounds.size
        return ScreenInfo(
            pixelWidth: Int(points.width * screen.scale),
            pixelHeight: Int(points.height * screen.scale),
            scale: Double(screen.scale)
        )
    }

    private func startPinging() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.status == .connected else { return }
                self.nextPingID &+= 1
                self.send(.ping(id: self.nextPingID, sentAtNanos: StageClock.nowNanos()))
            }
        }
    }

    private func append(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }

    private static func describe(_ error: Error) -> String {
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code): return "Network error (\(code.rawValue))"
            case .dns(let code): return "Name lookup failed (\(code))"
            case .tls(let status): return "TLS failed (\(status))"
            @unknown default: return nw.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
