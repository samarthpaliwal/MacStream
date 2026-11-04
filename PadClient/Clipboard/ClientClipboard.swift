import Foundation
import UIKit

/// Text clipboard sharing, iPad side. UIPasteboard notifies while the app
/// is active; on return to the foreground the change count is compared.
@MainActor
final class ClientClipboard {
    var onLocalChange: ((String) -> Void)?

    private var lastChangeCount = UIPasteboard.general.changeCount
    private var lastText: String?
    private var observers: [NSObjectProtocol] = []

    func start() {
        lastChangeCount = UIPasteboard.general.changeCount
        observers = [
            NotificationCenter.default.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.check() }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.check() }
            },
        ]
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    func apply(remote text: String) {
        guard text != lastText else { return }
        lastText = text
        UIPasteboard.general.string = text
        lastChangeCount = UIPasteboard.general.changeCount
    }

    private func check() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard pasteboard.hasStrings, let text = pasteboard.string, text != lastText, text.utf8.count < 512_000 else { return }
        lastText = text
        onLocalChange?(text)
    }
}
