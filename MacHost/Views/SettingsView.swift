import StreamCore
import SwiftUI

/// The Settings window (⌘, from the popover). Changes apply live.
struct SettingsView: View {
    @ObservedObject private var settings = HostSettings.shared
    @State private var displays = HostSettings.attachedDisplays()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open MacStream at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show developer tools in the menu", isOn: $settings.showDeveloperTools)
            }

            Section("Display") {
                Picker("Mode", selection: $settings.displayMode) {
                    ForEach(HostSettings.DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if settings.displayMode == .mirror {
                    Picker("Display", selection: $settings.mirrorDisplayID) {
                        Text("Main display").tag(UInt32(0))
                        ForEach(displays, id: \.id) { display in
                            Text(display.label).tag(display.id)
                        }
                    }
                } else {
                    Text("Creates a second display sized to the iPad while it is connected, using a private macOS interface. If macOS refuses, MacStream falls back to mirroring.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Streaming") {
                Picker("Default quality", selection: $settings.defaultQuality) {
                    ForEach(StreamQuality.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Picker("Codec", selection: $settings.codec) {
                    Text("HEVC (recommended)").tag(VideoPacketHeader.Codec.hevc)
                    Text("H.264").tag(VideoPacketHeader.Codec.h264)
                }
                Picker("Frame rate", selection: $settings.frameRate) {
                    Text("60 fps").tag(60)
                    Text("30 fps (saves battery)").tag(30)
                }
                Toggle("Show the Mac's cursor", isOn: $settings.showCursor)
            }

            Section("Extras") {
                Toggle("Stream system audio", isOn: $settings.streamAudio)
                Toggle("Share text clipboard both ways", isOn: $settings.shareClipboard)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { displays = HostSettings.attachedDisplays() }
        .onChange(of: settings.displayMode) { _, _ in HostController.shared.settingsChanged() }
        .onChange(of: settings.mirrorDisplayID) { _, _ in HostController.shared.settingsChanged() }
        .onChange(of: settings.codec) { _, _ in HostController.shared.settingsChanged() }
        .onChange(of: settings.frameRate) { _, _ in HostController.shared.settingsChanged() }
        .onChange(of: settings.showCursor) { _, _ in HostController.shared.settingsChanged() }
        .onChange(of: settings.streamAudio) { _, _ in HostController.shared.settingsChanged() }
        .onChange(of: settings.defaultQuality) { _, new in AppState.shared.quality = new }
    }
}
