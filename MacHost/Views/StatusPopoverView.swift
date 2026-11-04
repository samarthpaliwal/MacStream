import SwiftUI
import StreamCore

/// Menu bar popover. Top to bottom: status, pairing, quality and mode, link
/// numbers while connected, optional developer tools, actions.
struct StatusPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissions: PermissionsMonitor
    @ObservedObject private var settings = HostSettings.shared
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !permissions.allGranted {
                permissionsBanner
            }

            PairingSectionView()

            HStack {
                Picker("Quality", selection: $appState.quality) {
                    ForEach(StreamQuality.allCases) { preset in
                        Label(preset.title, systemImage: preset.systemImage).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer()
                Label(settings.displayMode == .extended ? "Extended" : "Mirror", systemImage: settings.displayMode == .extended ? "rectangle.on.rectangle" : "rectangle.on.rectangle.angled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.connection.isConnected, let stats = appState.clientStats {
                linkStats(stats)
            }

            if settings.showDeveloperTools {
                CaptureSectionView()
                if appState.connection.isConnected {
                    connectionTest
                }
                if showLog {
                    logView
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("Disconnect", role: .destructive) {
                    appState.disconnect()
                }
                .disabled(!appState.connection.isConnected)

                Spacer()

                if settings.showDeveloperTools {
                    Button {
                        showLog.toggle()
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel(showLog ? "Hide log" : "Show log")
                }

                if !permissions.allGranted {
                    Button("Setup…") { SetupWindowController.shared.show() }
                }

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .keyboardShortcut(",")

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: appState.connection.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: appState.connection == .advertising)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacStream").font(.headline)
                Text(appState.connection.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityLabel(appState.connection.title)
        }
    }

    private func linkStats(_ stats: ClientStats) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "End to end %@ · RTT %.1f ms", stats.endToEndMs.map { String(format: "%.0f ms", $0) } ?? "syncing", stats.roundTripMs))
                Text(String(format: "Encoder %.1f Mb/s · loss %.2f%% · %d dropped · %.0f fps on iPad", Double(CaptureController.shared.encoderBitrate) / 1e6, stats.lossPercent, stats.framesDropped, stats.framesPerSecond))
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Link")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionTest: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Button("Send test message to iPad") {
                    HostController.shared.send(.text("Hello from \(appState.identity.name)"))
                }
                .controlSize(.small)
                if let text = appState.lastReceivedText {
                    Text("Last from iPad: \(text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Connection test")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(appState.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .onChange(of: appState.logLines.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var permissionsBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("Permissions needed before streaming can start.")
                .font(.caption)
            Spacer()
            Button("Fix") { SetupWindowController.shared.show() }
                .controlSize(.mini)
        }
        .padding(8)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch appState.connection {
        case .idle: return .secondary
        case .advertising: return .orange
        case .connected: return .green
        }
    }
}
