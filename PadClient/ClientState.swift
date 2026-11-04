import Foundation
import StreamCore
import UIKit

/// Single source of truth for the client UI.
@MainActor
final class ClientState: ObservableObject {
    enum Phase: Equatable {
        case picking
        case streaming(ClientSession)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.picking, .picking): return true
            case (.streaming(let a), .streaming(let b)): return a === b
            default: return false
            }
        }
    }

    @Published var phase: Phase = .picking
    @Published var hosts: [DiscoveredHost] = []
    @Published var discoveryError: String?
    @Published var quality: StreamQuality = .balanced
    @Published var showDebugOverlay = ProcessInfo.processInfo.environment["MACSTREAM_DEBUG_OVERLAY"] == "1"

    /// `MACSTREAM_AUTOCONNECT=123456` connects to the first Mac found, for
    /// scripted testing on the simulator (pass via SIMCTL_CHILD_ env vars).
    private let autoConnectCode = ProcessInfo.processInfo.environment["MACSTREAM_AUTOCONNECT"].flatMap(PairingCode.init(digits:))
    private var didAutoConnect = false
    /// `MACSTREAM_RESET_PAIRING=1` forgets stored keys for every Mac found, for scripted tests.
    private let resetPairings = ProcessInfo.processInfo.environment["MACSTREAM_RESET_PAIRING"] == "1"

    let identity: DeviceInfo
    private let browser = HostBrowser()

    init() {
        identity = DeviceInfo(
            id: DeviceIdentityStore.deviceID(),
            name: UIDevice.current.name,
            platform: .iPad
        )
        browser.onUpdate = { [weak self] hosts in
            Task { @MainActor in
                guard let self else { return }
                self.hosts = hosts
                if self.resetPairings { hosts.forEach { self.forgetPairing($0) } }
                if let code = self.autoConnectCode, !self.didAutoConnect, let first = hosts.first, case .picking = self.phase {
                    self.didAutoConnect = true
                    if self.isPaired(first) { self.connectPaired(to: first) } else { self.connect(to: first, code: code) }
                }
            }
        }
        browser.onError = { [weak self] error in
            Task { @MainActor in self?.discoveryError = error.localizedDescription }
        }
    }

    func startBrowsing() {
        discoveryError = nil
        browser.start()
    }

    func stopBrowsing() {
        browser.stop()
    }

    func isPaired(_ host: DiscoveredHost) -> Bool {
        host.hostID.map { ClientPairingStore.key(for: $0) != nil } ?? false
    }

    /// First connection: the code protects the exchange of the long-term key.
    func connect(to host: DiscoveredHost, code: PairingCode) {
        guard let hostID = host.hostID else { return }
        let key = PairingKeyDerivation.sharedKey(code: code, hostID: hostID)
        start(ClientSession(host: host, key: key, usesStoredKey: false, identity: identity))
    }

    /// Every later connection: one tap with the stored key.
    func connectPaired(to host: DiscoveredHost) {
        guard let hostID = host.hostID, let key = ClientPairingStore.key(for: hostID) else { return }
        start(ClientSession(host: host, key: key, usesStoredKey: true, identity: identity))
    }

    func forgetPairing(_ host: DiscoveredHost) {
        if let id = host.hostID { ClientPairingStore.forget(id) }
        objectWillChange.send()
    }

    private func start(_ session: ClientSession) {
        phase = .streaming(session)
        session.start()
    }

    func disconnect() {
        if case .streaming(let session) = phase {
            session.close()
        }
        phase = .picking
    }
}
