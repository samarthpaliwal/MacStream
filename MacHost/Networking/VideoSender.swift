import Foundation
import Network
import os
import StreamCore

/// UDP video channel, host side. Listens on a random port (announced in
/// `helloAck`), learns the client's address from its encrypted HELLO
/// datagrams, then fires encoded frames at it as encrypted packets.
final class VideoSender: @unchecked Sendable {
    private let listener: NWListener
    private let crypto: VideoCrypto
    private let queue = DispatchQueue(label: "macstream.video.send", qos: .userInteractive)
    private var client: NWConnection?
    private var sequence: UInt64 = 0
    private var frameID: UInt32 = 0
    /// Sealed packets of the most recent frames, for retransmission.
    private var history: [(frameID: UInt32, packets: [Data])] = []
    private let historyLength = 8
    private(set) var resentPackets = 0
    private let counters = OSAllocatedUnfairLock(initialState: (packets: 0, bytes: 0, frames: 0, droppedFrames: 0, windowBytes: 0))
    /// Packets handed to the network but not yet reported as processed.
    private let pending = OSAllocatedUnfairLock(initialState: 0)
    /// If the network is this far behind, skip non-keyframes instead of queueing.
    private let maxPendingPackets = 300
    /// `MACSTREAM_SIMULATE_LOSS=3` drops 3 % of packets at random, for testing recovery.
    private let simulatedLossPercent = Double(ProcessInfo.processInfo.environment["MACSTREAM_SIMULATE_LOSS"] ?? "") ?? 0

    var onLog: ((String) -> Void)?

    init(crypto: VideoCrypto) throws {
        self.crypto = crypto
        listener = try NWListener(using: .udp)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    var port: UInt16? { listener.port?.rawValue }

    var hasClient: Bool { queue.sync { client != nil } }

    func start() {
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            client?.cancel()
            client = nil
        }
        listener.cancel()
    }

    /// Totals so far, plus bytes since the last call (for a rate).
    func snapshot() -> (packets: Int, bytes: Int, frames: Int, droppedFrames: Int, windowBytes: Int, pending: Int) {
        let c = counters.withLock { c -> (Int, Int, Int, Int, Int) in
            let out = (c.packets, c.bytes, c.frames, c.droppedFrames, c.windowBytes)
            c.windowBytes = 0
            return out
        }
        return (c.0, c.1, c.2, c.3, c.4, pending.withLock { $0 })
    }

    /// Chunks, encrypts and sends. Called from the encoder's output thread.
    func send(_ frame: EncodedFrame) {
        queue.async { [self] in
            guard let client else { return }
            // Backpressure: a stale frame is worse than a missing one. Keyframes
            // always go because the client needs one to recover.
            if !frame.isKeyframe, pending.withLock({ $0 }) > maxPendingPackets {
                counters.withLock { $0.droppedFrames += 1 }
                return
            }
            frameID &+= 1
            let packets = FrameChunker.packets(for: frame, frameID: frameID)
            var sealedPackets: [Data] = []
            sealedPackets.reserveCapacity(packets.count)
            var bytes = 0
            client.batch {
                for packet in packets {
                    sequence &+= 1
                    guard let sealed = try? crypto.seal(packet, sequence: sequence, direction: .hostToClient) else { continue }
                    sealedPackets.append(sealed)
                    if simulatedLossPercent > 0, Double.random(in: 0..<100) < simulatedLossPercent { continue }
                    bytes += sealed.count
                    transmit(sealed, to: client)
                }
            }
            history.append((frameID, sealedPackets))
            if history.count > historyLength { history.removeFirst() }
            counters.withLock {
                $0.packets += packets.count
                $0.bytes += bytes
                $0.windowBytes += bytes
                $0.frames += 1
            }
        }
    }

    /// Audio rides the same encrypted channel as video, one packet per chunk,
    /// tagged with the PCM codec so the client routes it to the player.
    func sendAudio(_ pcm: Data) {
        queue.async { [self] in
            guard let client else { return }
            let payloadSize = FrameChunker.maxPayload
            var offset = 0
            client.batch {
                while offset < pcm.count {
                    let end = min(offset + payloadSize, pcm.count)
                    frameID &+= 1
                    sequence &+= 1
                    let header = VideoPacketHeader(frameID: frameID, captureNanos: StageClock.nowNanos(), chunkIndex: 0, chunkCount: 1, flags: [], codec: .pcmAudio)
                    var packet = header.serialized()
                    packet.append(pcm[offset..<end])
                    if let sealed = try? crypto.seal(packet, sequence: sequence, direction: .hostToClient) {
                        transmit(sealed, to: client)
                        counters.withLock { $0.bytes += sealed.count; $0.windowBytes += sealed.count; $0.packets += 1 }
                    }
                    offset = end
                }
            }
        }
    }

    /// Resends specific chunks of a recent frame (client NACK). Packets keep
    /// their original sequence numbers, so the client sees them as recovered
    /// rather than new.
    func resend(frameID: UInt32, chunks: [UInt16]) {
        queue.async { [self] in
            guard let client, let entry = history.first(where: { $0.frameID == frameID }) else { return }
            client.batch {
                for index in chunks where Int(index) < entry.packets.count {
                    resentPackets += 1
                    transmit(entry.packets[Int(index)], to: client)
                }
            }
        }
    }

    private func transmit(_ sealed: Data, to client: NWConnection) {
        pending.withLock { $0 += 1 }
        client.send(content: sealed, completion: .contentProcessed { [pending] _ in
            pending.withLock { $0 -= 1 }
        })
    }

    // MARK: Inbound

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(on: connection)
            case .failed, .cancelled:
                self?.queue.async {
                    if self?.client === connection { self?.client = nil }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let opened = try? crypto.open(data, direction: .clientToHost),
               opened.plaintext == Data("HELLO".utf8) {
                if client !== connection {
                    client?.cancel()
                    client = connection
                    onLog?("Video channel open to \(connection.endpoint)")
                }
            } else if data != nil, client !== connection {
                // Unauthenticated sender: drop the flow.
                connection.cancel()
                return
            }
            if error == nil { receive(on: connection) }
        }
    }
}
