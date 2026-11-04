import Foundation

/// Constants shared by host and client for discovery and versioning.
public enum StreamService {
    /// Audio channel format, fixed for simplicity: PCM needs no codec and
    /// adds no latency; 1.5 Mb/s is nothing on a local network.
    public static let audioSampleRate: Double = 48_000
    public static let audioChannels = 2

    /// Bonjour service type the Mac advertises and the iPad browses for.
    /// The control channel is TCP; the video channel's UDP port is announced
    /// inside the `hello` handshake so only one service needs advertising.
    public static let bonjourType = "_macstream._tcp"
    public static let bonjourDomain = "local."
    /// TXT record keys.
    public static let txtHostID = "id"
    public static let txtVersion = "v"
    /// "1" while the Mac is showing a pairing code.
    public static let txtPairing = "pairing"

    /// Bumped whenever the wire format changes incompatibly. Both sides refuse
    /// to talk when versions differ, which is safer than guessing.
    public static let protocolVersion: UInt16 = 4
}

/// Quality presets exposed in both UIs. Values are starting points for the
/// adaptive bitrate controller, not hard limits.
public enum StreamQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case performance
    case balanced
    case quality

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .performance: return "Performance"
        case .balanced: return "Balanced"
        case .quality: return "Quality"
        }
    }

    public var systemImage: String {
        switch self {
        case .performance: return "hare"
        case .balanced: return "scale.3d"
        case .quality: return "sparkles"
        }
    }

    /// Fraction of the Mac display's native resolution to capture at.
    public var resolutionScale: Double {
        switch self {
        case .performance: return 0.5
        case .balanced: return 0.75
        case .quality: return 1.0
        }
    }

    /// Initial encoder target in megabits per second.
    public var targetBitrateMbps: Double {
        switch self {
        case .performance: return 8
        case .balanced: return 15
        case .quality: return 30
        }
    }
}
