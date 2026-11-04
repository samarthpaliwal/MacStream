import CoreVideo
import Foundation
import Network
import os
import StreamCore

/// Live numbers for the debug overlay, refreshed once a second.
struct VideoStats: Equatable {
    var framesPerSecond: Double = 0
    var megabitsPerSecond: Double = 0
    var packetsReceived = 0
    var packetsLost = 0
    /// Packets that arrived after being counted lost (retransmissions).
    var packetsRecovered = 0
    var framesDecoded = 0
    var framesDropped = 0
    var decodeMs: Double = 0
    /// Mac capture → iPad display, via clock sync. Nil until synced.
    var endToEndMs: Double?
    /// Mac capture → packet arrival on the iPad (host pipeline + network).
    var captureToArrivalMs: Double?
    var width = 0
    var height = 0

    var lossPercent: Double {
        let total = packetsReceived + packetsLost
        return total == 0 ? 0 : Double(packetsLost) * 100 / Double(total)
    }
}

/// UDP video channel, client side: encrypted datagrams in, reassembled
/// frames to the decoder, decoded images to the renderer. Detects loss and
/// asks for a keyframe instead of waiting.
final class VideoReceiver: @unchecked Sendable {
    var onStats: (@Sendable (VideoStats) -> Void)?
    var onKeyframeNeeded: (@Sendable () -> Void)?
    /// Ask the host to resend chunks of a frame.
    var onNack: (@Sendable (UInt32, [UInt16]) -> Void)?
    /// PCM audio chunk (48 kHz stereo Int16 interleaved).
    var onAudio: (@Sendable (Data) -> Void)?
    var onFirstFrame: (@Sendable () -> Void)?
    var onError: (@Sendable (String) -> Void)?
    /// Converts a host timestamp to this device's clock; nil until clock sync has a sample.
    var hostToClientNanos: (@Sendable (UInt64) -> UInt64?)?

    private let connection: NWConnection
    private let crypto: VideoCrypto
    private let decoder: VideoDecoder
    private let renderer: VideoRenderer
    private let queue = DispatchQueue(label: "macstream.video.receive", qos: .userInteractive)
    private let assembler = FrameAssembler()

    private var helloSequence: UInt64 = 0
    private var expectedSequence: UInt64?
    private var needsKeyframe = true
    private var lastKeyframeRequest: UInt64 = 0
    private var nacked: [UInt32: Set<UInt16>] = [:]
    private var hasRenderedFrame = false
    private var helloTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?

    private var stats = VideoStats()
    private var window = (frames: 0, bytes: 0, decodeNanos: UInt64(0), started: StageClock.nowNanos())
    private var latencyWindow = (e2eNanos: UInt64(0), e2eCount: 0, arrivalNanos: UInt64(0), arrivalCount: 0)
    /// Capture time (host clock) of the frame currently being decoded.
    private var decodingCaptureNanos: UInt64 = 0

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, crypto: VideoCrypto, decoder: VideoDecoder, renderer: VideoRenderer) {
        self.crypto = crypto
        self.decoder = decoder
        self.renderer = renderer
        connection = NWConnection(host: host, port: port, using: .udp)

        decoder.onFrame = { [weak self] pixelBuffer, decodedNanos in
            self?.rendered(pixelBuffer, decodedNanos: decodedNanos)
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                sendHello()
                receiveNext()
                startTimers()
            case .failed(let error), .waiting(let error):
                onError?("Video channel: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        helloTimer?.cancel()
        statsTimer?.cancel()
        connection.cancel()
    }

    // MARK: Outbound

    /// Encrypted HELLO tells the host where to send and doubles as keepalive.
    private func sendHello() {
        helloSequence &+= 1
        guard let packet = try? crypto.seal(Data("HELLO".utf8), sequence: helloSequence, direction: .clientToHost) else { return }
        connection.send(content: packet, completion: .idempotent)
    }

    private func requestKeyframeIfDue() {
        let now = StageClock.nowNanos()
        guard now &- lastKeyframeRequest > 250_000_000 else { return }   // at most 4 per second
        lastKeyframeRequest = now
        onKeyframeNeeded?()
    }

    // MARK: Inbound

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { handle(data) }
            if error == nil { receiveNext() }
        }
    }

    private func handle(_ datagram: Data) {
        guard let opened = try? crypto.open(datagram, direction: .hostToClient) else { return }
        stats.packetsReceived += 1
        window.bytes += datagram.count

        var isRetransmission = false
        if let expected = expectedSequence {
            if opened.sequence > expected {
                stats.packetsLost += Int(opened.sequence - expected)
            }
            if opened.sequence >= expected { expectedSequence = opened.sequence + 1 } else { isRetransmission = true }
        } else {
            expectedSequence = opened.sequence + 1
        }

        if let header = VideoPacketHeader(parsing: opened.plaintext), header.codec == .pcmAudio {
            onAudio?(Data(opened.plaintext.dropFirst(VideoPacketHeader.size)))
            return
        }

        let droppedBefore = assembler.droppedFrames
        let result = assembler.add(opened.plaintext)
        if assembler.droppedFrames > droppedBefore {
            stats.framesDropped += assembler.droppedFrames - droppedBefore
            needsKeyframe = true
            requestKeyframeIfDue()
        }
        if isRetransmission, case .stale = result {} else if isRetransmission {
            stats.packetsRecovered += 1
        }
        requestMissingChunks(after: opened.plaintext, result: result)

        guard case .completed(let frame) = result else { return }
        nacked = nacked.filter { $0.key > frame.frameID }
        if needsKeyframe && !frame.isKeyframe {
            requestKeyframeIfDue()
            return
        }
        needsKeyframe = false

        let started = StageClock.nowNanos()
        if let arrival = hostToClientNanos?(frame.captureNanos), started > arrival {
            latencyWindow.arrivalNanos += started - arrival
            latencyWindow.arrivalCount += 1
        }
        decodingCaptureNanos = frame.captureNanos
        do {
            if try decoder.decode(frame) {
                window.decodeNanos += StageClock.nowNanos() &- started
            } else {
                needsKeyframe = true
                requestKeyframeIfDue()
            }
        } catch {
            onError?(error.localizedDescription)
            needsKeyframe = true
            requestKeyframeIfDue()
        }
    }

    /// Selective retransmission. On a LAN, packets almost never reorder, so a
    /// gap below the chunk that just arrived means a loss; and any older frame
    /// still pending when a newer frame's packet shows up is missing its tail.
    /// Each chunk is requested once; if the resend is lost too, the frame is
    /// dropped and the keyframe path takes over.
    private func requestMissingChunks(after packet: Data, result: FrameAssembler.Result) {
        guard let header = VideoPacketHeader(parsing: packet) else { return }
        for frameID in assembler.pendingFrameIDs where frameID < header.frameID {
            nack(frameID, assembler.missingChunks(frameID: frameID) ?? [])
        }
        if case .waiting = result, let missing = assembler.missingChunks(frameID: header.frameID) {
            nack(header.frameID, missing.filter { $0 < header.chunkIndex })
        }
    }

    private func nack(_ frameID: UInt32, _ chunks: [UInt16]) {
        var already = nacked[frameID] ?? []
        let fresh = chunks.filter { !already.contains($0) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { already.insert($0) }
        nacked[frameID] = already
        onNack?(frameID, fresh)
    }

    private func rendered(_ pixelBuffer: CVPixelBuffer, decodedNanos: UInt64) {
        renderer.display(pixelBuffer)
        let displayed = StageClock.nowNanos()
        if let captured = hostToClientNanos?(decodingCaptureNanos), displayed > captured {
            latencyWindow.e2eNanos += displayed - captured
            latencyWindow.e2eCount += 1
        }
        stats.framesDecoded += 1
        stats.width = CVPixelBufferGetWidth(pixelBuffer)
        stats.height = CVPixelBufferGetHeight(pixelBuffer)
        window.frames += 1
        if !hasRenderedFrame {
            hasRenderedFrame = true
            onFirstFrame?()
        }
    }

    // MARK: Timers

    private func startTimers() {
        let hello = DispatchSource.makeTimerSource(queue: queue)
        hello.schedule(deadline: .now() + 1, repeating: 1)
        hello.setEventHandler { [weak self] in self?.sendHello() }
        hello.resume()
        helloTimer = hello

        let statsTimer = DispatchSource.makeTimerSource(queue: queue)
        statsTimer.schedule(deadline: .now() + 1, repeating: 1)
        statsTimer.setEventHandler { [weak self] in self?.publishStats() }
        statsTimer.resume()
        self.statsTimer = statsTimer
    }

    private func publishStats() {
        let now = StageClock.nowNanos()
        let seconds = max(Double(now &- window.started) / 1e9, 0.001)
        stats.framesPerSecond = Double(window.frames) / seconds
        stats.megabitsPerSecond = Double(window.bytes * 8) / seconds / 1e6
        stats.decodeMs = window.frames > 0 ? Double(window.decodeNanos) / Double(window.frames) / 1e6 : 0
        stats.endToEndMs = latencyWindow.e2eCount > 0 ? Double(latencyWindow.e2eNanos) / Double(latencyWindow.e2eCount) / 1e6 : nil
        stats.captureToArrivalMs = latencyWindow.arrivalCount > 0 ? Double(latencyWindow.arrivalNanos) / Double(latencyWindow.arrivalCount) / 1e6 : nil
        window = (0, 0, 0, now)
        latencyWindow = (0, 0, 0, 0)
        onStats?(stats)
    }
}
