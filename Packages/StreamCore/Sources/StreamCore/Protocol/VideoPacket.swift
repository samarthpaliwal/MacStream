import Foundation

/// One UDP datagram of encoded video. Large frames are split into chunks that
/// all carry the same `frameID`; the client reassembles them and drops the
/// whole frame if any chunk is missing, then asks for a keyframe.
///
/// Wire layout (big-endian), 20 bytes:
///   0  frameID       UInt32
///   4  captureNanos  UInt64   host monotonic clock at capture
///  12  chunkIndex    UInt16
///  14  chunkCount    UInt16
///  16  flags         UInt8    bit0 = keyframe
///  17  codec         UInt8    0 = HEVC, 1 = H.264, 2 = PCM audio
///  18  reserved      UInt16
///  20  payload
public struct VideoPacketHeader: Hashable, Sendable {
    public static let size = 20

    public struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let keyframe = Flags(rawValue: 1 << 0)
    }

    public enum Codec: UInt8, Hashable, Sendable {
        case hevc = 0
        case h264 = 1
        /// Not video: 48 kHz stereo 16-bit interleaved PCM, one packet per
        /// chunk, played as it arrives. Lost packets are a short gap.
        case pcmAudio = 2
    }

    public var frameID: UInt32
    public var captureNanos: UInt64
    public var chunkIndex: UInt16
    public var chunkCount: UInt16
    public var flags: Flags
    public var codec: Codec

    public init(frameID: UInt32, captureNanos: UInt64, chunkIndex: UInt16, chunkCount: UInt16, flags: Flags, codec: Codec) {
        self.frameID = frameID
        self.captureNanos = captureNanos
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.flags = flags
        self.codec = codec
    }

    public func serialized() -> Data {
        var data = Data(capacity: Self.size)
        data.appendBigEndian(frameID)
        data.appendBigEndian(captureNanos)
        data.appendBigEndian(chunkIndex)
        data.appendBigEndian(chunkCount)
        data.append(flags.rawValue)
        data.append(codec.rawValue)
        data.appendBigEndian(UInt16(0))
        return data
    }

    /// Returns nil for malformed or truncated headers.
    public init?(parsing data: Data) {
        guard data.count >= Self.size else { return nil }
        let base = data.startIndex
        func load<T: FixedWidthInteger>(_ offset: Int, as _: T.Type) -> T {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }.bigEndian
        }
        frameID = load(0, as: UInt32.self)
        captureNanos = load(4, as: UInt64.self)
        chunkIndex = load(12, as: UInt16.self)
        chunkCount = load(14, as: UInt16.self)
        flags = Flags(rawValue: data[base + 16])
        guard let codec = Codec(rawValue: data[base + 17]) else { return nil }
        self.codec = codec
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
