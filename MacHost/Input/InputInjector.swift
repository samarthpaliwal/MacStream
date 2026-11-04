import AppKit
import CoreGraphics
import Foundation
import StreamCore

/// Turns `InputEvent`s from the paired iPad into CGEvents on the chosen
/// display. Requires Accessibility permission; without it events are logged
/// and dropped. `MACSTREAM_INPUT_DRYRUN=1` logs instead of posting, which is
/// how the pipeline is tested without clicking around on a real desktop.
@MainActor
final class InputInjector {
    static let shared = InputInjector()

    private let dryRun = ProcessInfo.processInfo.environment["MACSTREAM_INPUT_DRYRUN"] == "1"
    private var warnedAboutPermission = false
    private var buttonsDown: Set<PointerButton> = []
    private var lastPosition = CGPoint.zero
    private var lastClickTime: TimeInterval = 0
    private var lastClickPosition = CGPoint.zero
    private var clickCount: Int64 = 1
    private var modifierFlags: CGEventFlags = []
    private var magnifyAccumulator: Double = 1

    var eventsInjected = 0

    private init() {}

    func inject(_ event: InputEvent, displayID: CGDirectDisplayID) {
        guard dryRun || AXIsProcessTrusted() else {
            if !warnedAboutPermission {
                warnedAboutPermission = true
                AppState.shared.log("Input ignored: Accessibility permission not granted")
            }
            return
        }
        let bounds = CGDisplayBounds(displayID)

        switch event {
        case .pointerMove(let p):
            move(to: point(p, in: bounds))

        case .pointerDown(let p, let button):
            let location = point(p, in: bounds)
            lastPosition = location
            updateClickCount(at: location)
            buttonsDown.insert(button)
            post(mouse: Self.downType(button), at: location, button: button)

        case .pointerUp(let p, let button):
            let location = point(p, in: bounds)
            lastPosition = location
            buttonsDown.remove(button)
            post(mouse: Self.upType(button), at: location, button: button)

        case .scroll(let p, let deltaX, let deltaY, _):
            move(to: point(p, in: bounds))
            // Finger moving down = content moving down (natural scrolling).
            if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY.rounded()), wheel2: Int32(deltaX.rounded()), wheel3: 0) {
                scroll.flags = modifierFlags
                post(scroll, describe: "scroll dx=\(Int(deltaX)) dy=\(Int(deltaY))")
            }

        case .magnify(_, let scale):
            // No public API posts pinch gestures, so step through Command-plus/minus.
            let ratio = scale / magnifyAccumulator
            if ratio > 1.25 {
                magnifyAccumulator = scale
                tap(KeyCodeMap.equal, flags: .maskCommand)
            } else if ratio < 0.8 {
                magnifyAccumulator = scale
                tap(KeyCodeMap.minus, flags: .maskCommand)
            }

        case .keyDown(let keyCode, let modifiers, _):
            modifierFlags = Self.flags(modifiers)
            if KeyCodeMap.isModifier(keyCode) { modifierFlags.insert(Self.flag(forModifierKey: keyCode)) }
            key(keyCode, down: true)

        case .keyUp(let keyCode, let modifiers):
            modifierFlags = Self.flags(modifiers)
            if KeyCodeMap.isModifier(keyCode) { modifierFlags.remove(Self.flag(forModifierKey: keyCode)) }
            key(keyCode, down: false)

        case .modifiersChanged(let modifiers):
            modifierFlags = Self.flags(modifiers)

        case .typeText(let text):
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
            let utf16 = Array(text.utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            post(down, describe: "type \"\(text)\"")
            post(up, describe: nil)
        }
    }

    // MARK: Pointer

    private func point(_ p: NormalizedPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + p.x * bounds.width, y: bounds.minY + p.y * bounds.height)
    }

    private func move(to location: CGPoint) {
        lastPosition = location
        if buttonsDown.contains(.left) {
            post(mouse: .leftMouseDragged, at: location, button: .left)
        } else if buttonsDown.contains(.right) {
            post(mouse: .rightMouseDragged, at: location, button: .right)
        } else {
            post(mouse: .mouseMoved, at: location, button: .left)
        }
    }

    private func updateClickCount(at location: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        let near = hypot(location.x - lastClickPosition.x, location.y - lastClickPosition.y) < 6
        clickCount = (now - lastClickTime < 0.4 && near) ? clickCount + 1 : 1
        lastClickTime = now
        lastClickPosition = location
    }

    private func post(mouse type: CGEventType, at location: CGPoint, button: PointerButton) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: Self.cgButton(button)) else { return }
        event.flags = modifierFlags
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        }
        let verbose = type != .mouseMoved && type != .leftMouseDragged
        post(event, describe: verbose ? "\(type) at (\(Int(location.x)), \(Int(location.y))) clicks=\(clickCount)" : nil)
    }

    private static func downType(_ button: PointerButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    private static func upType(_ button: PointerButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    private static func cgButton(_ button: PointerButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    // MARK: Keyboard

    private func key(_ keyCode: UInt16, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
        event.flags = modifierFlags
        post(event, describe: down ? "key \(keyCode) down flags=\(modifierFlags.rawValue)" : nil)
    }

    private func tap(_ keyCode: UInt16, flags: CGEventFlags) {
        let saved = modifierFlags
        modifierFlags = flags
        key(keyCode, down: true)
        key(keyCode, down: false)
        modifierFlags = saved
    }

    private static func flags(_ modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private static func flag(forModifierKey keyCode: UInt16) -> CGEventFlags {
        switch keyCode {
        case KeyCodeMap.shift, KeyCodeMap.rightShift: return .maskShift
        case KeyCodeMap.control, KeyCodeMap.rightControl: return .maskControl
        case KeyCodeMap.option, KeyCodeMap.rightOption: return .maskAlternate
        case KeyCodeMap.command, KeyCodeMap.rightCommand: return .maskCommand
        case KeyCodeMap.capsLock: return .maskAlphaShift
        default: return []
        }
    }

    // MARK: Posting

    private func post(_ event: CGEvent, describe: String?) {
        eventsInjected += 1
        if dryRun {
            if let describe { AppState.shared.log("DRYRUN \(describe)") }
            return
        }
        event.post(tap: .cghidEventTap)
    }
}
