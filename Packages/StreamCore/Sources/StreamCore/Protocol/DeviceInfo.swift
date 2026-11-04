import Foundation

/// Identity a device presents during the handshake.
public struct DeviceInfo: Codable, Hashable, Sendable {
    public enum Platform: String, Codable, Sendable {
        case mac
        case iPad
    }

    /// Stable per-install identifier. Survives relaunches; regenerated on reinstall.
    public var id: UUID
    public var name: String
    public var platform: Platform

    public init(id: UUID, name: String, platform: Platform) {
        self.id = id
        self.name = name
        self.platform = platform
    }
}

/// Persists a per-install UUID so paired devices can be recognised later.
public enum DeviceIdentityStore {
    private static let key = "macstream.deviceID"

    public static func deviceID(defaults: UserDefaults = .standard) -> UUID {
        if let stored = defaults.string(forKey: key), let id = UUID(uuidString: stored) {
            return id
        }
        let fresh = UUID()
        defaults.set(fresh.uuidString, forKey: key)
        return fresh
    }
}

/// Geometry of the display being mirrored. Sent in `helloAck` so the client
/// can set up letterboxing and coordinate mapping before the first frame.
public struct DisplayInfo: Codable, Hashable, Sendable {
    /// Pixel dimensions of the captured stream (after any resolution scaling).
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Point dimensions of the logical display, used for input mapping.
    public var pointWidth: Double
    public var pointHeight: Double
    public var refreshRate: Double

    public init(pixelWidth: Int, pixelHeight: Int, pointWidth: Double, pointHeight: Double, refreshRate: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.refreshRate = refreshRate
    }
}
