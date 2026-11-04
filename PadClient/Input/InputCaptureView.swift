import StreamCore
import SwiftUI
import UIKit

/// Transparent view over the video that turns touches, Pencil, trackpad and
/// keyboard into `InputEvent`s in normalized stream coordinates.
///
/// Mapping: one finger tap = left click, one finger drag = click-and-drag,
/// two finger tap = right click, two finger pan = scroll, pinch = zoom
/// (sent as magnify; the Mac maps it to Command-plus/minus), Pencil = precise
/// pointer with hover, hardware keyboard = key events, on-screen keyboard =
/// typed text. A three finger tap toggles the floating controls.
final class InputCaptureUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    var onEvent: ((InputEvent) -> Void)?
    var onToggleControls: (() -> Void)?
    /// Letterboxed video rect in this view's coordinates.
    var videoRectProvider: (() -> CGRect)?

    /// When false, an empty input view suppresses the on-screen keyboard while
    /// the view stays first responder for hardware keys.
    var softwareKeyboardEnabled = false {
        didSet {
            guard softwareKeyboardEnabled != oldValue else { return }
            inputViewOverride = softwareKeyboardEnabled ? nil : UIView(frame: .zero)
            reloadInputViews()
        }
    }
    private var inputViewOverride: UIView? = UIView(frame: .zero)
    override var inputView: UIView? { inputViewOverride }

    // UITextInputTraits: no autocorrect bar getting in the way.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default

    private var primaryTouch: UITouch?
    private var startPoint = CGPoint.zero
    private var dragging = false
    private var multiTouch = false
    private var lastPinchScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        addGestureRecognizer(threeFingerTap)

        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondaryClick.buttonMaskRequired = .secondary
        secondaryClick.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        addGestureRecognizer(secondaryClick)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hover.delegate = self
        addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Coordinate mapping

    private func normalized(_ point: CGPoint) -> NormalizedPoint {
        let rect = videoRectProvider?() ?? bounds
        guard rect.width > 0, rect.height > 0 else { return NormalizedPoint(x: 0, y: 0) }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1)
        return NormalizedPoint(x: x, y: y)
    }

    // MARK: Single pointer (finger, Pencil, trackpad primary button)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? touches.count
        if primaryTouch == nil, !multiTouch, active == 1, let touch = touches.first {
            primaryTouch = touch
            startPoint = touch.location(in: self)
            dragging = false
            if touch.type == .pencil {
                onEvent?(.pointerMove(normalized(startPoint)))
            }
        } else {
            // A second finger: this is a gesture, not a click. Release any drag.
            if dragging, let touch = primaryTouch {
                onEvent?(.pointerUp(normalized(touch.location(in: self)), button: .left))
            }
            primaryTouch = nil
            dragging = false
            multiTouch = true
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = primaryTouch, touches.contains(touch), !multiTouch else { return }
        let location = touch.location(in: self)
        if !dragging {
            let threshold: CGFloat = touch.type == .pencil ? 2 : 8
            guard hypot(location.x - startPoint.x, location.y - startPoint.y) > threshold else { return }
            dragging = true
            onEvent?(.pointerMove(normalized(startPoint)))
            onEvent?(.pointerDown(normalized(startPoint), button: .left))
        }
        onEvent?(.pointerMove(normalized(location)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { resetMultiTouchIfIdle(event) }
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        primaryTouch = nil
        guard !multiTouch else { dragging = false; return }
        let point = normalized(touch.location(in: self))
        if dragging {
            onEvent?(.pointerMove(point))
            onEvent?(.pointerUp(point, button: .left))
        } else {
            onEvent?(.pointerMove(point))
            onEvent?(.pointerDown(point, button: .left))
            onEvent?(.pointerUp(point, button: .left))
        }
        dragging = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { resetMultiTouchIfIdle(event) }
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        if dragging {
            onEvent?(.pointerUp(normalized(touch.location(in: self)), button: .left))
        }
        primaryTouch = nil
        dragging = false
    }

    private func resetMultiTouchIfIdle(_ event: UIEvent?) {
        let active = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
        if active == 0 { multiTouch = false }
    }

    // MARK: Gestures

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        rightClick(at: gesture.location(in: self))
    }

    @objc private func handleSecondaryClick(_ gesture: UITapGestureRecognizer) {
        rightClick(at: gesture.location(in: self))
    }

    private func rightClick(at location: CGPoint) {
        let point = normalized(location)
        onEvent?(.pointerMove(point))
        onEvent?(.pointerDown(point, button: .right))
        onEvent?(.pointerUp(point, button: .right))
    }

    @objc private func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
        onToggleControls?()
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let delta = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard delta != .zero else { return }
        onEvent?(.scroll(at: normalized(gesture.location(in: self)), deltaX: delta.x, deltaY: delta.y, precise: true))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastPinchScale = 1
        case .changed:
            // Only report meaningful steps to keep the channel quiet.
            guard abs(gesture.scale / lastPinchScale - 1) > 0.03 else { return }
            lastPinchScale = gesture.scale
            onEvent?(.magnify(at: normalized(gesture.location(in: self)), scale: gesture.scale))
        default:
            break
        }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        onEvent?(.pointerMove(normalized(gesture.location(in: self))))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, let code = KeyCodeMap.macVirtualKey(forHIDUsage: key.keyCode.rawValue) {
                let characters = key.characters.isEmpty ? nil : key.characters
                onEvent?(.keyDown(keyCode: code, modifiers: Self.modifiers(key.modifierFlags), characters: characters))
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        keysReleased(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        keysReleased(presses, with: event)
    }

    private func keysReleased(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, let code = KeyCodeMap.macVirtualKey(forHIDUsage: key.keyCode.rawValue) {
                onEvent?(.keyUp(keyCode: code, modifiers: Self.modifiers(key.modifierFlags)))
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    private static func modifiers(_ flags: UIKeyModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.alphaShift) { result.insert(.capsLock) }
        return result
    }

    // MARK: On-screen keyboard (UIKeyInput)

    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" {
            tapKey(KeyCodeMap.returnKey)
        } else {
            onEvent?(.typeText(text))
        }
    }

    func deleteBackward() {
        tapKey(KeyCodeMap.delete)
    }

    private func tapKey(_ code: UInt16) {
        onEvent?(.keyDown(keyCode: code, modifiers: [], characters: nil))
        onEvent?(.keyUp(keyCode: code, modifiers: []))
    }
}

struct InputCaptureView: UIViewRepresentable {
    let videoRect: () -> CGRect
    let softwareKeyboard: Bool
    let onEvent: (InputEvent) -> Void
    let onToggleControls: () -> Void

    func makeUIView(context: Context) -> InputCaptureUIView {
        let view = InputCaptureUIView()
        view.onEvent = onEvent
        view.onToggleControls = onToggleControls
        view.videoRectProvider = videoRect
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: InputCaptureUIView, context: Context) {
        view.onEvent = onEvent
        view.onToggleControls = onToggleControls
        view.videoRectProvider = videoRect
        view.softwareKeyboardEnabled = softwareKeyboard
        if !view.isFirstResponder { view.becomeFirstResponder() }
    }
}
