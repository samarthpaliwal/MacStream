import AppKit
import SwiftUI

/// Hosts the first-run setup view in a regular window. A menu bar app has no
/// main window, so this is created on demand rather than via a SwiftUI scene.
@MainActor
final class SetupWindowController {
    static let shared = SetupWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SetupView().environmentObject(PermissionsMonitor.shared)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "Set up MacStream"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
