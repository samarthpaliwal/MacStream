import AppKit
import Foundation

/// Text clipboard sharing, Mac side. NSPasteboard has no change notification,
/// so it is polled twice a second; only plain text is shared.
@MainActor
final class ClipboardSync {
    var onLocalChange: ((String) -> Void)?

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastText: String?

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Clipboard text received from the iPad.
    func apply(remote text: String) {
        guard text != lastText else { return }
        lastText = text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), text != lastText, text.utf8.count < 512_000 else { return }
        lastText = text
        onLocalChange?(text)
    }
}
