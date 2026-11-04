import Foundation

/// First message each side sends after the TLS connection is up.
public struct HelloPayload: Codable, Hashable, Sendable {
    public var protocolVersion: UInt16
    public var device: DeviceInfo
    /// UDP port the host listens on for the video channel. Nil from the client.
    public var videoPort: UInt16?
    /// The client's screen, so the host can size an extended display to it.
    public var screen: ScreenInfo?

    public init(protocolVersion: UInt16 = StreamService.protocolVersion, device: DeviceInfo, videoPort: UInt16? = nil, screen: ScreenInfo? = nil) {
        self.protocolVersion = protocolVersion
        self.device = device
        self.videoPort = videoPort
        self.screen = screen
    }
}

/// A cursor bitmap with its hotspot, in the Mac's points.
public struct CursorImage: Codable, Hashable, Sendable {
    public var png: Data
    public var width: Double
    public var height: Double
    public var hotspotX: Double
    public var hotspotY: Double

    public init(png: Data, width: Double, height: Double, hotspotX: Double, hotspotY: Double) {
        self.png = png
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
    }
}

/// Physical screen of a client, in pixels and points.
public struct ScreenInfo: Codable, Hashable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double

    public init(pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    public var pointWidth: Int { Int(Double(pixelWidth) / scale) }
    public var pointHeight: Int { Int(Double(pixelHeight) / scale) }
}

/// Host-side pipeline numbers for the client's overlay.
public struct HostStats: Codable, Hashable, Sendable {
    public var framesPerSecond: Double
    public var captureDelayMs: Double
    public var encodeMs: Double
    public var sendMbps: Double
    public var encoderBitrateMbps: Double
    public var targetBitrateMbps: Double
    public var pendingPackets: Int

    public init(framesPerSecond: Double, captureDelayMs: Double, encodeMs: Double, sendMbps: Double, encoderBitrateMbps: Double, targetBitrateMbps: Double, pendingPackets: Int) {
        self.framesPerSecond = framesPerSecond
        self.captureDelayMs = captureDelayMs
        self.encodeMs = encodeMs
        self.sendMbps = sendMbps
        self.encoderBitrateMbps = encoderBitrateMbps
        self.targetBitrateMbps = targetBitrateMbps
        self.pendingPackets = pendingPackets
    }
}

/// Client-side numbers the host's bitrate controller reacts to.
public struct ClientStats: Codable, Hashable, Sendable {
    public var lossPercent: Double
    public var packetsLost: Int
    public var framesDropped: Int
    public var framesPerSecond: Double
    public var decodeMs: Double
    public var roundTripMs: Double
    /// Capture on the Mac to display on the iPad, via clock sync. Nil until synced.
    public var endToEndMs: Double?

    public init(lossPercent: Double, packetsLost: Int, framesDropped: Int, framesPerSecond: Double, decodeMs: Double, roundTripMs: Double, endToEndMs: Double?) {
        self.lossPercent = lossPercent
        self.packetsLost = packetsLost
        self.framesDropped = framesDropped
        self.framesPerSecond = framesPerSecond
        self.decodeMs = decodeMs
        self.roundTripMs = roundTripMs
        self.endToEndMs = endToEndMs
    }
}

/// Everything that travels on the reliable control channel, in both directions.
/// Encoded as JSON for now because the messages are small and infrequent;
/// video never goes through here.
public enum ControlMessage: Codable, Hashable, Sendable {
    case hello(HelloPayload)
    case helloAck(HelloPayload, display: DisplayInfo?)
    /// Sent by the host right after a code-based handshake: the long-term key
    /// the client must store and use for every later connection.
    case pairingComplete(key: Data)
    /// Round-trip measurement. `sentAtNanos` is the sender's monotonic clock and
    /// is echoed back unchanged so the sender can compute RTT without clock sync.
    case ping(id: UInt32, sentAtNanos: UInt64)
    /// `hostNanos` is the host's clock when the ping arrived, for clock sync.
    case pong(id: UInt32, sentAtNanos: UInt64, hostNanos: UInt64)
    /// Once a second each way while streaming.
    case hostStats(HostStats)
    case clientStats(ClientStats)
    /// Client asks the host for an IDR frame after unrecoverable loss.
    case requestKeyframe
    /// Client asks for specific chunks of a recent frame to be resent.
    case nack(frameID: UInt32, chunks: [UInt16])
    case setQuality(StreamQuality)
    case input(InputEvent)
    /// Text clipboard contents, either direction, when they change.
    case clipboard(text: String)
    /// The Mac's current cursor shape; the iPad draws the cursor itself so
    /// pointer movement has no video latency.
    case cursorImage(CursorImage)
    /// Host moved the cursor on its own (for example on connect).
    case cursorPosition(NormalizedPoint)
    /// Free-form text, used by the Milestone 2 connectivity test.
    case text(String)
    case disconnect(reason: String)

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> ControlMessage {
        try JSONDecoder().decode(ControlMessage.self, from: data)
    }
}
