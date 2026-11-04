import CryptoKit
import Foundation

/// Six-digit code the Mac shows and the iPad enters once.
public struct PairingCode: Hashable, Sendable {
    public let digits: String

    public init?(digits: String) {
        guard digits.count == 6, digits.allSatisfy(\.isNumber) else { return nil }
        self.digits = digits
    }

    public static func random() -> PairingCode {
        var generator = SystemRandomNumberGenerator()
        let value = Int.random(in: 0...999_999, using: &generator)
        return PairingCode(digits: String(format: "%06d", value))!
    }

    /// "123 456" for display.
    public var formatted: String {
        let d = Array(digits)
        return "\(String(d[0..<3])) \(String(d[3..<6]))"
    }
}

/// Derives the pre-shared key both sides use for TLS-PSK and video encryption.
///
/// Key derivation for both phases of pairing.
///
/// Phase 1 (one-time): the six-digit code shown on the Mac, bound to the
/// host's ID, protects a short TLS session whose only job is to hand the iPad
/// a long-term key. A code is accepted only while the Mac is in pairing mode,
/// is replaced after one successful pairing, and is rotated after a handful
/// of failed handshakes, which bounds brute force to a few guesses.
///
/// Phase 2 (every reconnect): the long-term 256-bit key, derived from a secret
/// the Mac keeps in its Keychain and stored in the iPad's Keychain.
public enum PairingKeyDerivation {
    public static func sharedKey(code: PairingCode, hostID: UUID) -> SymmetricKey {
        let input = SymmetricKey(data: Data(code.digits.utf8))
        let salt = Data(hostID.uuidString.utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input,
            salt: salt,
            info: Data("macstream-psk-v1".utf8),
            outputByteCount: 32
        )
    }

    /// Long-term PSK used by every paired iPad of this Mac.
    public static func pairedKey(hostSecret: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: hostSecret, info: Data("macstream-paired-psk-v1".utf8), outputByteCount: 32)
    }
}

/// A device that completed pairing. The key itself lives in the Keychain;
/// this record is what the UI lists.
public struct PairedDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var platform: DeviceInfo.Platform
    public var pairedAt: Date

    public init(id: UUID, name: String, platform: DeviceInfo.Platform, pairedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.platform = platform
        self.pairedAt = pairedAt
    }
}
