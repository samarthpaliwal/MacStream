import CryptoKit
import Foundation

/// Per-datagram encryption for the UDP video channel.
///
/// Each packet is `sequence (8 bytes, big-endian) || ciphertext || tag (16)`.
/// The nonce is derived from the direction and sequence number rather than
/// sent, and the sequence number is authenticated as associated data, so a
/// replayed or reordered packet cannot be passed off as a different one.
public struct VideoCrypto: Sendable {
    public enum Direction: UInt8, Sendable {
        case hostToClient = 0
        case clientToHost = 1
    }

    public enum Error: Swift.Error {
        case malformed
    }

    /// Bytes added to every packet: sequence number plus authentication tag.
    public static let overhead = 8 + 16

    private let key: SymmetricKey

    /// Derives a video key from the pairing PSK so the TLS and UDP keys differ.
    public init(psk: SymmetricKey) {
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: psk, info: Data("macstream-video-v1".utf8), outputByteCount: 32)
    }

    public func seal(_ plaintext: Data, sequence: UInt64, direction: Direction) throws -> Data {
        let sequenceBytes = Self.bigEndian(sequence)
        let nonce = try ChaChaPoly.Nonce(data: Self.nonce(direction: direction, sequence: sequenceBytes))
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: sequenceBytes)
        var out = Data(capacity: Self.overhead + plaintext.count)
        out.append(sequenceBytes)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    public func open(_ packet: Data, direction: Direction) throws -> (sequence: UInt64, plaintext: Data) {
        let packet = Data(packet)   // rebase indices to zero
        guard packet.count >= Self.overhead else { throw Error.malformed }
        let sequenceBytes = packet[0..<8]
        let sequence = sequenceBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        let nonce = try ChaChaPoly.Nonce(data: Self.nonce(direction: direction, sequence: sequenceBytes))
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: packet[8..<(packet.count - 16)],
            tag: packet[(packet.count - 16)...]
        )
        let plaintext = try ChaChaPoly.open(box, using: key, authenticating: sequenceBytes)
        return (sequence, plaintext)
    }

    private static func nonce(direction: Direction, sequence: Data) -> Data {
        var data = Data([direction.rawValue, 0, 0, 0])
        data.append(sequence)
        return data
    }

    private static func bigEndian(_ value: UInt64) -> Data {
        var v = value.bigEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
