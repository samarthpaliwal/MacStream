import AppKit
import ApplicationServices
import CoreGraphics

/// Tracks the two macOS permissions the host needs and knows how to request
/// each one or deep-link to its System Settings pane.
///
/// Screen Recording: required by ScreenCaptureKit. Without it capture returns
/// an empty stream rather than failing loudly.
/// Accessibility: required to post CGEvents for mouse and keyboard injection.
@MainActor
final class PermissionsMonitor: ObservableObject {
    static let shared = PermissionsMonitor()

    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false

    var allGranted: Bool { screenRecordingGranted && accessibilityGranted }

    private var timer: Timer?

    private init() {
        refresh()
        // TCC changes are not observable, so poll while the app runs.
        // Two seconds is responsive enough for a setup screen and negligible in cost.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Shows the system prompt (first time) and adds the app to the Screen
    /// Recording list so the user can toggle it.
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Shows the system prompt and adds the app to the Accessibility list.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
