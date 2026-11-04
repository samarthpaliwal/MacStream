import XCTest
@testable import StreamCore

final class FramingTests: XCTestCase {
    func testRoundTripAcrossSplitBoundaries() throws {
        let a = Data("hello".utf8)
        let b = Data("world!".utf8)
        let stream = LengthPrefixedFramer.frame(a) + LengthPrefixedFramer.frame(b)

        var framer = LengthPrefixedFramer()
        var out: [Data] = []
        // Feed one byte at a time to exercise partial-header and partial-body paths.
        for byte in stream {
            out += try framer.append(Data([byte]))
        }
        XCTAssertEqual(out, [a, b])
    }

    func testRejectsOversizedFrame() {
        var framer = LengthPrefixedFramer()
        var header = Data()
        header.appendBigEndian(UInt32(LengthPrefixedFramer.maxFrameSize + 1))
        XCTAssertThrowsError(try framer.append(header))
    }
}

final class ControlMessageTests: XCTestCase {
    func testHelloRoundTrip() throws {
        let device = DeviceInfo(id: UUID(), name: "Test iPad", platform: .iPad)
        let message = ControlMessage.hello(HelloPayload(device: device))
        let decoded = try ControlMessage.decode(try message.encoded())
        XCTAssertEqual(decoded, message)
    }

    func testInputRoundTrip() throws {
        let event = InputEvent.keyDown(keyCode: 0, modifiers: [.command, .shift], characters: "A")
        let decoded = try ControlMessage.decode(try ControlMessage.input(event).encoded())
        XCTAssertEqual(decoded, .input(event))
    }
}

final class VideoPacketTests: XCTestCase {
    func testHeaderRoundTrip() {
        let header = VideoPacketHeader(frameID: 42, captureNanos: 123_456_789_000, chunkIndex: 3, chunkCount: 9, flags: [.keyframe], codec: .hevc)
        let data = header.serialized() + Data([0xAB, 0xCD])
        XCTAssertEqual(data.count, VideoPacketHeader.size + 2)
        XCTAssertEqual(VideoPacketHeader(parsing: data), header)
    }

    func testTruncatedHeaderFails() {
        XCTAssertNil(VideoPacketHeader(parsing: Data(repeating: 0, count: 5)))
    }
}

final class PairingTests: XCTestCase {
    func testCodeValidation() {
        XCTAssertNotNil(PairingCode(digits: "123456"))
        XCTAssertNil(PairingCode(digits: "12345"))
        XCTAssertNil(PairingCode(digits: "12345a"))
        XCTAssertEqual(PairingCode(digits: "123456")?.formatted, "123 456")
    }

    func testDerivationIsDeterministicAndBoundToDevices() {
        let code = PairingCode(digits: "246810")!
        let host = UUID()
        let k1 = PairingKeyDerivation.sharedKey(code: code, hostID: host)
        let k2 = PairingKeyDerivation.sharedKey(code: code, hostID: host)
        let k3 = PairingKeyDerivation.sharedKey(code: code, hostID: UUID())
        XCTAssertEqual(k1, k2)
        XCTAssertNotEqual(k1, k3)
    }
}

final class VideoCryptoTests: XCTestCase {
    func testRoundTripAndTamperDetection() throws {
        let crypto = VideoCrypto(psk: SymmetricKey(size: .bits256))
        let plain = Data((0..<1000).map { UInt8($0 & 0xff) })
        let packet = try crypto.seal(plain, sequence: 42, direction: .hostToClient)
        XCTAssertEqual(packet.count, plain.count + VideoCrypto.overhead)

        let opened = try crypto.open(packet, direction: .hostToClient)
        XCTAssertEqual(opened.sequence, 42)
        XCTAssertEqual(opened.plaintext, plain)

        // Wrong direction means a different nonce: must fail.
        XCTAssertThrowsError(try crypto.open(packet, direction: .clientToHost))

        var tampered = packet
        tampered[20] ^= 0x01
        XCTAssertThrowsError(try crypto.open(tampered, direction: .hostToClient))
    }
}

final class FrameChunkerTests: XCTestCase {
    private func frame(size: Int, key: Bool) -> EncodedFrame {
        EncodedFrame(data: Data((0..<size).map { UInt8($0 % 251) }), isKeyframe: key, codec: .hevc, width: 16, height: 16, captureNanos: 7, deliveredNanos: 8, encodedNanos: 9)
    }

    func testReassemblesOutOfOrder() {
        let original = frame(size: 5000, key: true)
        let packets = FrameChunker.packets(for: original, frameID: 1)
        XCTAssertEqual(packets.count, 4)

        let assembler = FrameAssembler()
        var completed: FrameAssembler.CompletedFrame?
        for packet in packets.reversed() {
            if case .completed(let f) = assembler.add(packet) { completed = f }
        }
        XCTAssertEqual(completed?.data, original.data)
        XCTAssertEqual(completed?.isKeyframe, true)
        XCTAssertEqual(completed?.captureNanos, 7)
        XCTAssertEqual(assembler.droppedFrames, 0)
    }

    func testDropsIncompleteOlderFrame() {
        let assembler = FrameAssembler()
        let lossy = FrameChunker.packets(for: frame(size: 3000, key: false), frameID: 1)
        _ = assembler.add(lossy[0])            // second packet never arrives
        let next = FrameChunker.packets(for: frame(size: 100, key: false), frameID: 2)
        guard case .completed = assembler.add(next[0]) else { return XCTFail("frame 2 should complete") }
        XCTAssertEqual(assembler.droppedFrames, 1)
        XCTAssertEqual(assembler.add(lossy[1]), .stale)
    }
}

extension FrameAssembler.Result: Equatable {
    public static func == (lhs: FrameAssembler.Result, rhs: FrameAssembler.Result) -> Bool {
        switch (lhs, rhs) {
        case (.waiting, .waiting), (.stale, .stale), (.invalid, .invalid): return true
        case (.completed(let a), .completed(let b)): return a.frameID == b.frameID
        default: return false
        }
    }
}

final class AnnexBParserTests: XCTestCase {
    func testSplitsStartCodesAndClassifies() {
        let vps = Data([0x40, 0x01, 0xAA])          // HEVC type 32
        let sps = Data([0x42, 0x01, 0xBB])          // type 33
        let idr = Data([0x26, 0x01, 0xCC, 0xDD])    // type 19
        var stream = Data()
        for unit in [vps, sps] { stream += Data([0, 0, 0, 1]) + unit }
        stream += Data([0, 0, 1]) + idr

        let units = AnnexBParser.nalUnits(in: stream)
        XCTAssertEqual(units, [vps, sps, idr])
        XCTAssertTrue(AnnexBParser.isParameterSet(vps, codec: .hevc))
        XCTAssertFalse(AnnexBParser.isParameterSet(idr, codec: .hevc))
        XCTAssertEqual(AnnexBParser.lengthPrefixed([idr]), Data([0, 0, 0, 4]) + idr)
    }
}

import CryptoKit

final class KeyCodeMapTests: XCTestCase {
    func testCommonKeys() {
        XCTAssertEqual(KeyCodeMap.macVirtualKey(forHIDUsage: 4), 0)      // a
        XCTAssertEqual(KeyCodeMap.macVirtualKey(forHIDUsage: 29), 6)     // z
        XCTAssertEqual(KeyCodeMap.macVirtualKey(forHIDUsage: 30), 18)    // 1
        XCTAssertEqual(KeyCodeMap.macVirtualKey(forHIDUsage: 39), 29)    // 0
        XCTAssertEqual(KeyCodeMap.macVirtualKey(forHIDUsage: 40), 36)    // return
        XCTAssertEqual(KeyCodeMap.macVirtualKey(forHIDUsage: 227), 55)   // left command
        XCTAssertEqual(KeyCodeMap.macVirtualKey(forHIDUsage: 82), 126)   // up arrow
        XCTAssertNil(KeyCodeMap.macVirtualKey(forHIDUsage: 999))
        XCTAssertTrue(KeyCodeMap.isModifier(55))
        XCTAssertFalse(KeyCodeMap.isModifier(0))
    }
}

final class ClockSyncTests: XCTestCase {
    func testKeepsLowestRoundTripSample() {
        var sync = ClockSync()
        // Host clock runs 1 s ahead of the client's.
        let offset: UInt64 = 1_000_000_000
        sync.addSample(clientSent: 100, hostReceived: 100 + offset + 50_000, clientReceived: 100 + 100_000)   // 100 µs RTT
        XCTAssertEqual(sync.offsetNanos, Int64(offset))
        sync.addSample(clientSent: 200, hostReceived: 200 + offset + 900_000, clientReceived: 200 + 2_000_000) // worse: 2 ms RTT, asymmetric
        XCTAssertEqual(sync.offsetNanos, Int64(offset), "noisier sample must not replace the best one")
        XCTAssertEqual(sync.clientNanos(fromHost: 5_000_000_000), 4_000_000_000)
    }
}

final class BitrateControllerTests: XCTestCase {
    func testCutsOnLossAndRecoversWhenClean() {
        var controller = BitrateController(maximum: 15_000_000, minimum: 3_000_000)
        var now: UInt64 = 10_000_000_000

        XCTAssertNil(controller.update(lossPercent: 0, framesDropped: 0, now: now))
        XCTAssertNil(controller.update(lossPercent: 0, framesDropped: 1, now: now), "one dropped frame is noise")
        let cut = controller.update(lossPercent: 5, framesDropped: 2, now: now)
        XCTAssertEqual(cut?.bitrate, 12_000_000)
        // Within the hold period: no second cut even with more loss.
        now += 500_000_000
        XCTAssertNil(controller.update(lossPercent: 5, framesDropped: 0, now: now))
        now += 600_000_000
        XCTAssertEqual(controller.update(lossPercent: 5, framesDropped: 0, now: now)?.bitrate, 9_600_000)

        // Clean for less than the recovery delay: hold.
        now += 2_000_000_000
        XCTAssertNil(controller.update(lossPercent: 0, framesDropped: 0, now: now))
        now += 4_000_000_000
        let up = controller.update(lossPercent: 0, framesDropped: 0, now: now)
        XCTAssertEqual(up?.bitrate, 11_040_000)
        XCTAssertEqual(up?.reason, "link clean")
    }

    func testNeverBelowMinimum() {
        var controller = BitrateController(maximum: 3_500_000, minimum: 3_000_000)
        var now: UInt64 = 5_000_000_000
        XCTAssertEqual(controller.update(lossPercent: 10, framesDropped: 0, now: now)?.bitrate, 3_000_000)
        now += 2_000_000_000
        XCTAssertNil(controller.update(lossPercent: 10, framesDropped: 0, now: now))
    }
}
