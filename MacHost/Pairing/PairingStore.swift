import CryptoKit
import Foundation
import StreamCore

/// The Mac's long-term pairing secret (Keychain) and the list of iPads
/// allowed to connect (UserDefaults; names and IDs only, nothing secret).
@MainActor
final class PairingStore: ObservableObject {
    static let shared = PairingStore()

    private static let service = "com.samarth.macstream.host"
    private static let secretAccount = "host-secret"
    private static let devicesKey = "macstream.pairedDevices"

    @Published private(set) var devices: [PairedDevice] = []
    private(set) var hostSecret: SymmetricKey

    /// PSK every paired iPad uses; derived, so the secret itself never leaves the Mac.
    var pairedKey: SymmetricKey { PairingKeyDerivation.pairedKey(hostSecret: hostSecret) }

    private init() {
        if let existing = try? KeychainStore.key(service: Self.service, account: Self.secretAccount) {
            hostSecret = existing
        } else {
            hostSecret = SymmetricKey(size: .bits256)
            try? KeychainStore.set(hostSecret, service: Self.service, account: Self.secretAccount)
        }
        if let data = UserDefaults.standard.data(forKey: Self.devicesKey),
           let saved = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            devices = saved
        }
        if ProcessInfo.processInfo.environment["MACSTREAM_RESET_PAIRING"] == "1" {
            resetAll()
        }
    }

    func isPaired(_ id: UUID) -> Bool {
        devices.contains { $0.id == id }
    }

    func add(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        save()
    }

    func remove(_ id: UUID) {
        devices.removeAll { $0.id == id }
        save()
    }

    /// New secret and empty list: every iPad must pair again.
    func resetAll() {
        hostSecret = SymmetricKey(size: .bits256)
        try? KeychainStore.set(hostSecret, service: Self.service, account: Self.secretAccount)
        devices = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.devicesKey)
        }
    }
}
