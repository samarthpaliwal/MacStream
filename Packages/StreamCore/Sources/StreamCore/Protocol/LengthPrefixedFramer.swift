import Foundation

public enum FramingError: Error, Equatable {
    case frameTooLarge(Int)
}

/// Splits a TCP byte stream into discrete messages using a 4-byte big-endian
/// length prefix. Feed it whatever the socket delivers; it returns whole
/// messages and keeps any partial tail for the next call.
public struct LengthPrefixedFramer {
    public static let headerSize = 4
    public static let maxFrameSize = 16 * 1024 * 1024

    private var buffer = Data()

    public init() {}

    /// Wraps one message for sending.
    public static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Appends received bytes and returns every complete message now available.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []

        while buffer.count >= Self.headerSize {
            let length = Int(buffer.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
            })
            guard length <= Self.maxFrameSize else {
                buffer.removeAll()
                throw FramingError.frameTooLarge(length)
            }
            let total = Self.headerSize + length
            guard buffer.count >= total else { break }

            let start = buffer.startIndex
            messages.append(buffer.subdata(in: (start + Self.headerSize)..<(start + total)))
            buffer = buffer.subdata(in: (start + total)..<buffer.endIndex)
        }
        return messages
    }
}
