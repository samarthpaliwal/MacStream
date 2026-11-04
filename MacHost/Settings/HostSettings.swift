import CoreGraphics
import Foundation
import ServiceManagement
import StreamCore

/// Persistent preferences. Values are read once at launch into live state
/// and applied immediately when changed in the Settings window.
@MainActor
final class HostSettings: ObservableObject {
    static let shared = HostSettings()

    enum DisplayMode: String, CaseIterable, Identifiable {
        case mirror
        case extended
        var id: String { rawValue }
        var title: String { self == .mirror ? "Mirror a display" : "Extend with the iPad (experimental)" }
    }

    private let defaults = UserDefaults.standard

    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") } }
    /// 0 means the main display.
    @Published var mirrorDisplayID: UInt32 { didSet { defaults.set(Int(mirrorDisplayID), forKey: "mirrorDisplayID") } }
    @Published var defaultQuality: StreamQuality { didSet { defaults.set(defaultQuality.rawValue, forKey: "defaultQuality") } }
    @Published var codec: VideoPacketHeader.Codec { didSet { defaults.set(Int(codec.rawValue), forKey: "codec") } }
    @Published var frameRate: Int { didSet { defaults.set(frameRate, forKey: "frameRate") } }
    @Published var showCursor: Bool { didSet { defaults.set(showCursor, forKey: "showCursor") } }
    @Published var streamAudio: Bool { didSet { defaults.set(streamAudio, forKey: "streamAudio") } }
    @Published var shareClipboard: Bool { didSet { defaults.set(shareClipboard, forKey: "shareClipboard") } }
    @Published var showDeveloperTools: Bool { didSet { defaults.set(showDeveloperTools, forKey: "showDeveloperTools") } }
    @Published private(set) var launchAtLogin: Bool
    @Published var launchAtLoginError: String?

    private init() {
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .mirror
        mirrorDisplayID = UInt32(defaults.integer(forKey: "mirrorDisplayID"))
        defaultQuality = StreamQuality(rawValue: defaults.string(forKey: "defaultQuality") ?? "") ?? .balanced
        codec = VideoPacketHeader.Codec(rawValue: UInt8(clamping: defaults.integer(forKey: "codec"))) ?? .hevc
        frameRate = [30, 60].contains(defaults.integer(forKey: "frameRate")) ? defaults.integer(forKey: "frameRate") : 60
        showCursor = defaults.object(forKey: "showCursor") as? Bool ?? true
        streamAudio = defaults.object(forKey: "streamAudio") as? Bool ?? true
        shareClipboard = defaults.object(forKey: "shareClipboard") as? Bool ?? true
        showDeveloperTools = defaults.bool(forKey: "showDeveloperTools")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Display to mirror: the chosen one if it is still attached, else main.
    var resolvedMirrorDisplayID: CGDirectDisplayID {
        if mirrorDisplayID != 0, CGDisplayIsActive(mirrorDisplayID) != 0 { return mirrorDisplayID }
        return CGMainDisplayID()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Attached displays for the picker: (id, label).
    static func attachedDisplays() -> [(id: UInt32, label: String)] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.enumerated().map { index, id in
            let size = CGDisplayBounds(id).size
            let main = id == CGMainDisplayID() ? " (main)" : ""
            return (id, "Display \(index + 1)\(main) · \(Int(size.width))×\(Int(size.height)) pt")
        }
    }
}
