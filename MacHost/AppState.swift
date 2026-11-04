import CoreGraphics
import Foundation
import StreamCore

/// Single source of truth for the host UI. Networking, capture and encoding
/// (later milestones) publish into this object; views only read it.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum ConnectionState: Equatable {
        case idle
        case advertising
        case connected(clientName: String)

        var title: String {
            switch self {
            case .idle: return "Not advertising"
            case .advertising: return "Waiting for an iPad"
            case .connected(let name): return "Connected to \(name)"
            }
        }

        var symbolName: String {
            switch self {
            case .idle: return "display"
            case .advertising: return "display.and.arrow.down"
            case .connected: return "ipad.landscape.and.iphone"
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published var connection: ConnectionState = .idle
    /// Session quality; starts from Settings. `MACSTREAM_QUALITY=performance|balanced|quality` overrides for tests.
    @Published var quality: StreamQuality = ProcessInfo.processInfo.environment["MACSTREAM_QUALITY"].flatMap(StreamQuality.init(rawValue:)) ?? HostSettings.shared.defaultQuality
    var codec: VideoPacketHeader.Codec { HostSettings.shared.codec }
    /// Display being captured: the mirror choice from Settings, or the
    /// virtual display while an extended session is active.
    @Published var displayID: CGDirectDisplayID = HostSettings.shared.resolvedMirrorDisplayID
    /// Code the iPad must enter. Rotated after repeated failed handshakes.
    @Published var pairingCode: PairingCode?
    @Published var lastReceivedText: String?
    /// Latest report from the iPad while streaming.
    @Published var clientStats: ClientStats?
    var senderDroppedFrames = 0
    /// Recent events for the popover and for debugging. Newest last.
    @Published private(set) var logLines: [String] = []

    let identity: DeviceInfo

    private init() {
        identity = DeviceInfo(
            id: DeviceIdentityStore.deviceID(),
            name: Host.current().localizedName ?? "Mac",
            platform: .mac
        )
    }

    func disconnect() {
        HostController.shared.disconnectClient()
    }

    func log(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        print("[MacStream] \(line)")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
