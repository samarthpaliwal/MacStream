import SwiftUI
import StreamCore

/// Menu bar host. There is no Dock icon (LSUIElement); all UI lives in the
/// status item popover and the first-run setup window.
@main
struct MacHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var permissions = PermissionsMonitor.shared

    var body: some Scene {
        MenuBarExtra("MacStream", systemImage: appState.connection.symbolName) {
            StatusPopoverView()
                .environmentObject(appState)
                .environmentObject(permissions)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Line-buffer stdout so `print` logs show up promptly when run from a terminal.
        setvbuf(stdout, nil, _IOLBF, 0)
        PermissionsMonitor.shared.refresh()
        // Show the setup window on launch until both permissions are granted.
        if !PermissionsMonitor.shared.allGranted {
            SetupWindowController.shared.show()
        }
        HostController.shared.start()
        runAutomatedTestIfRequested()
    }

    /// `MACSTREAM_AUTOTEST=synthetic:5` or `screen:5[:h264]` records a clip on
    /// launch and quits, so the pipeline can be exercised from a script.
    private func runAutomatedTestIfRequested() {
        guard let spec = ProcessInfo.processInfo.environment["MACSTREAM_AUTOTEST"] else { return }
        let parts = spec.split(separator: ":")
        let seconds = parts.count > 1 ? Int(parts[1]) ?? 5 : 5
        let capture = CaptureController.shared
        capture.sourceKind = parts.first == "screen" ? .screen : .synthetic
        if parts.count > 2 { HostSettings.shared.codec = parts[2] == "h264" ? .h264 : .hevc }
        Task { @MainActor in
            await capture.start(recordingTo: CaptureController.recordingURL())
            if capture.isRunning {
                try? await Task.sleep(for: .seconds(seconds))
                await capture.stop()
            }
            print("[MacStream] AUTOTEST result: \(capture.stats.runSummary) · last second: \(capture.stats.summary) frames=\(capture.stats.totalFrames) keyframes=\(capture.stats.keyframes) dropped=\(capture.stats.dropped) file=\(capture.lastRecordingURL?.path ?? "none") error=\(capture.lastError ?? "none")")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HostController.shared.stop()
    }
}
