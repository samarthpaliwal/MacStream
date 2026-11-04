import CryptoKit
import Foundation
import Security

/// Minimal generic-password Keychain wrapper used for pairing secrets on
/// both platforms. Never logs values.
public enum KeychainStore {
    public enum Error: Swift.Error {
        case unexpectedStatus(OSStatus)
    }

    public static func data(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Error.unexpectedStatus(status)
        }
    }

    public static func set(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Error.unexpectedStatus(update) }

        var insert = query
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(insert as CFDictionary, nil)
        guard add == errSecSuccess else { throw Error.unexpectedStatus(add) }
    }

    public static func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error.unexpectedStatus(status) }
    }

    public static func key(service: String, account: String) throws -> SymmetricKey? {
        try data(service: service, account: account).map(SymmetricKey.init(data:))
    }

    public static func set(_ key: SymmetricKey, service: String, account: String) throws {
        try set(key.withUnsafeBytes { Data($0) }, service: service, account: account)
    }

    private static func baseQuery(service: String, account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}
