import SwiftUI

/// Friendly first-run screen explaining each permission and offering both the
/// system prompt and a direct link to the right System Settings pane.
struct SetupView: View {
    @EnvironmentObject private var permissions: PermissionsMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "display.and.arrow.down")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to MacStream")
                        .font(.title2.weight(.semibold))
                    Text("Two permissions let your iPad see and control this Mac. Nothing leaves your local network.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PermissionRow(
                title: "Screen Recording",
                symbol: "rectangle.dashed.badge.record",
                explanation: "Lets MacStream capture the display to send to your iPad. macOS may ask you to quit and reopen the app after granting it.",
                granted: permissions.screenRecordingGranted,
                request: permissions.requestScreenRecording,
                openSettings: permissions.openScreenRecordingSettings
            )

            PermissionRow(
                title: "Accessibility",
                symbol: "hand.point.up.left",
                explanation: "Lets taps, Pencil strokes and keystrokes from the iPad act as mouse and keyboard input on this Mac. Only a paired iPad can send input.",
                granted: permissions.accessibilityGranted,
                request: permissions.requestAccessibility,
                openSettings: permissions.openAccessibilitySettings
            )

            HStack {
                Text(permissions.allGranted
                     ? "All set. MacStream lives in the menu bar."
                     : "MacStream checks these automatically every few seconds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(permissions.allGranted ? "Done" : "Continue Anyway") {
                    SetupWindowController.shared.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct PermissionRow: View {
    let title: String
    let symbol: String
    let explanation: String
    let granted: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(granted ? Color.green : Color.secondary)
                        .accessibilityLabel(granted ? "Granted" : "Not granted")
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    HStack {
                        Button("Grant…", action: request)
                        Button("Open System Settings", action: openSettings)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    SetupView().environmentObject(PermissionsMonitor.shared)
}
