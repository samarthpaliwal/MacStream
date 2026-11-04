import AppKit
import Foundation
import StreamCore

/// Watches the system cursor shape and reports changes, so the iPad can draw
/// the cursor locally. ScreenCaptureKit does not reliably composite the
/// cursor into captured frames, and a locally drawn cursor moves with no
/// video latency anyway.
@MainActor
final class CursorTracker {
    var onChange: ((CursorImage) -> Void)?

    private var timer: Timer?
    private var lastSignature: Int?

    func start() {
        lastSignature = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return }
        var hasher = Hasher()
        hasher.combine(tiff.count)
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        hasher.combine(image.size.width)
        // Sample a few bytes so same-size cursors (arrow vs I-beam) differ.
        for index in stride(from: 0, to: tiff.count, by: max(tiff.count / 64, 1)) { hasher.combine(tiff[index]) }
        let signature = hasher.finalize()
        guard signature != lastSignature else { return }
        lastSignature = signature

        guard let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        onChange?(CursorImage(png: png, width: image.size.width, height: image.size.height, hotspotX: cursor.hotSpot.x, hotspotY: cursor.hotSpot.y))
    }
}
