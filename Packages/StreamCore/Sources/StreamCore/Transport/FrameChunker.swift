import Foundation

/// Splits encoded frames into datagram-sized packets (host side).
public enum FrameChunker {
    /// Stay under the usual 1500-byte Ethernet/Wi-Fi MTU with room for IP/UDP.
    public static let maxDatagramSize = 1400
    public static let maxPayload = maxDatagramSize - VideoPacketHeader.size - VideoCrypto.overhead

    /// Unencrypted packets (header + payload) for one frame.
    public static func packets(for frame: EncodedFrame, frameID: UInt32) -> [Data] {
        let data = frame.data
        let chunkCount = max(1, (data.count + maxPayload - 1) / maxPayload)
        precondition(chunkCount <= Int(UInt16.max), "frame too large to chunk")

        var packets: [Data] = []
        packets.reserveCapacity(chunkCount)
        for index in 0..<chunkCount {
            let start = index * maxPayload
            let end = min(start + maxPayload, data.count)
            let header = VideoPacketHeader(
                frameID: frameID,
                captureNanos: frame.captureNanos,
                chunkIndex: UInt16(index),
                chunkCount: UInt16(chunkCount),
                flags: frame.isKeyframe ? [.keyframe] : [],
                codec: frame.codec
            )
            var packet = header.serialized()
            packet.append(data[(data.startIndex + start)..<(data.startIndex + end)])
            packets.append(packet)
        }
        return packets
    }
}

/// Reassembles frames from packets that may arrive out of order or not at
/// all (client side). Never waits for a late packet once a newer frame has
/// completed: stale frames are dropped and the caller requests a keyframe.
public final class FrameAssembler {
    public struct CompletedFrame: Sendable {
        public let frameID: UInt32
        public let isKeyframe: Bool
        public let codec: VideoPacketHeader.Codec
        public let captureNanos: UInt64
        public let data: Data
    }

    public enum Result {
        case completed(CompletedFrame)
        case waiting
        case stale
        case invalid
    }

    private struct Pending {
        var header: VideoPacketHeader
        var chunks: [Data?]
        var received = 0
        var bytes = 0
    }

    /// Frames given up on because a newer frame completed first.
    public private(set) var droppedFrames = 0
    private var pending: [UInt32: Pending] = [:]
    private var lastCompleted: UInt32?
    private let maxPending = 8

    public init() {}

    public func add(_ packet: Data) -> Result {
        guard let header = VideoPacketHeader(parsing: packet),
              header.chunkCount > 0, header.chunkIndex < header.chunkCount else {
            return .invalid
        }
        if let last = lastCompleted, header.frameID <= last {
            return .stale
        }

        var entry = pending[header.frameID] ?? Pending(header: header, chunks: Array(repeating: nil, count: Int(header.chunkCount)))
        guard entry.chunks.count == Int(header.chunkCount) else { return .invalid }
        if entry.chunks[Int(header.chunkIndex)] == nil {
            let payload = Data(packet.dropFirst(VideoPacketHeader.size))
            entry.chunks[Int(header.chunkIndex)] = payload
            entry.received += 1
            entry.bytes += payload.count
        }

        if entry.received == entry.chunks.count {
            pending[header.frameID] = nil
            discardOlder(than: header.frameID)
            lastCompleted = header.frameID
            var data = Data(capacity: entry.bytes)
            for chunk in entry.chunks { data.append(chunk!) }
            return .completed(CompletedFrame(
                frameID: header.frameID,
                isKeyframe: header.flags.contains(.keyframe),
                codec: header.codec,
                captureNanos: header.captureNanos,
                data: data
            ))
        }

        pending[header.frameID] = entry
        if pending.count > maxPending, let oldest = pending.keys.min() {
            pending[oldest] = nil
            droppedFrames += 1
        }
        return .waiting
    }

    public func reset() {
        pending.removeAll()
        lastCompleted = nil
    }

    /// Frames with at least one chunk received but not yet complete, oldest first.
    public var pendingFrameIDs: [UInt32] { pending.keys.sorted() }

    /// Chunk indices still missing for a pending frame; nil if it is not pending.
    public func missingChunks(frameID: UInt32) -> [UInt16]? {
        guard let entry = pending[frameID] else { return nil }
        return entry.chunks.enumerated().compactMap { $0.element == nil ? UInt16($0.offset) : nil }
    }

    private func discardOlder(than frameID: UInt32) {
        let stale = pending.keys.filter { $0 < frameID }
        for id in stale { pending[id] = nil }
        droppedFrames += stale.count
    }
}
