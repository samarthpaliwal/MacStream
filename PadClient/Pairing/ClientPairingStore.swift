import CryptoKit
import Foundation
import StreamCore

/// Long-term keys for each paired Mac, in the iPad's Keychain keyed by host ID.
enum ClientPairingStore {
    private static let service = "com.samarth.macstream.client"

    static func key(for hostID: UUID) -> SymmetricKey? {
        try? KeychainStore.key(service: service, account: hostID.uuidString)
    }

    /// Returns false when the Keychain refuses the write (for example an
    /// unsigned build with no application identifier).
    @discardableResult
    static func save(_ key: SymmetricKey, for hostID: UUID) -> Bool {
        do {
            try KeychainStore.set(key, service: service, account: hostID.uuidString)
            return true
        } catch {
            return false
        }
    }

    static func forget(_ hostID: UUID) {
        try? KeychainStore.delete(service: service, account: hostID.uuidString)
    }
}
