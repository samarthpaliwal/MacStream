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
final class InputCaptureUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    var onEvent: ((InputEvent) -> Void)?
    var onToggleControls: (() -> Void)?
    /// Where the pointer last was, in view coordinates, for the drawn cursor.
    var onPointerLocation: ((CGPoint) -> Void)?
    /// Modifiers latched from the on-screen strip; merged into every key and
    /// click until `onModifiersConsumed` releases the one-shot ones.
    var latchedModifiers: KeyModifiers = []
    var onModifiersConsumed: (() -> Void)?
    /// Flip two-finger scroll direction (macOS "natural scrolling" preference
    /// also applies to injected events, so this lets either feel right).
    var invertScroll = false
    /// iPadOS keeps ⌘Tab, ⌘Space and ⌘H for itself. With this on, ⌥Tab and
    /// ⌥Space from a hardware keyboard are sent to the Mac as ⌘Tab and ⌘Space.
    var remapOptionShortcuts = true

    private var lastPointerPoint = CGPoint(x: -1, y: -1)
    /// Fingers currently on the glass, so a third finger suppresses scrolling.
    private var activeTouches = 0
    /// Modifier keys currently held on a hardware keyboard.
    private var hardwareModifiers: KeyModifiers = []
    private var navSwipeFired = false
    private var repeatTimers: [UInt16: Timer] = [:]
    private var heldKeys: [UInt16: (modifiers: KeyModifiers, characters: String?)] = [:]
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
    private var scrollStart = CGPoint.zero
    private var edgeSwipeFired = false
    private let edgeWidth: CGFloat = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        // Trackpad: hide the iPad's own pointer over the stream so only the
        // Mac's cursor shows, and drop the hardware-keyboard shortcut bar.
        addInteraction(UIPointerInteraction(delegate: self))
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []

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
        scroll.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        scroll.delegate = self
        addGestureRecognizer(scroll)

        // Trackpad two-finger scrolling arrives as scroll events (no touches),
        // which only a recognizer with allowedScrollTypesMask receives. It
        // must not swallow one-finger press-drags, which stay with touches.
        let trackpadScroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        trackpadScroll.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        trackpadScroll.allowedScrollTypesMask = .all
        trackpadScroll.cancelsTouchesInView = false
        trackpadScroll.delegate = self
        addGestureRecognizer(trackpadScroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hover.delegate = self
        addGestureRecognizer(hover)

        // Three-finger swipes mirror the Mac trackpad: left/right switch
        // Spaces, up is Mission Control, down is App Exposé.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 3
            swipe.delegate = self
            addGestureRecognizer(swipe)
        }
    }

    // MARK: Key helpers

    /// Key down + up with the latched modifiers merged in, then release one-shots.
    func sendKey(_ code: UInt16, extra: KeyModifiers = [], characters: String? = nil) {
        let modifiers = latchedModifiers.union(extra)
        onEvent?(.keyDown(keyCode: code, modifiers: modifiers, characters: characters))
        onEvent?(.keyUp(keyCode: code, modifiers: modifiers))
        onModifiersConsumed?()
    }

    private func click(_ button: PointerButton, at point: NormalizedPoint) {
        onEvent?(.pointerMove(point))
        onEvent?(.pointerDown(point, button: button))
        onEvent?(.pointerUp(point, button: button))
        onModifiersConsumed?()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeFirstResponder: Bool { true }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    /// Called for every pointer move over the view, hidden pointer or not,
    /// so trackpad movement reaches the Mac even where hover is not delivered.
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        pointerMoved(to: request.location)
        return defaultRegion
    }

    private func pointerMoved(to location: CGPoint) {
        guard abs(location.x - lastPointerPoint.x) > 0.25 || abs(location.y - lastPointerPoint.y) > 0.25 else { return }
        lastPointerPoint = location
        onEvent?(.pointerMove(normalized(location)))
    }

    // MARK: Coordinate mapping

    private func normalized(_ point: CGPoint) -> NormalizedPoint {
        onPointerLocation?(point)
        let rect = videoRectProvider?() ?? bounds
        guard rect.width > 0, rect.height > 0 else { return NormalizedPoint(x: 0, y: 0) }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1)
        return NormalizedPoint(x: x, y: y)
    }

    // MARK: Single pointer (finger, Pencil, trackpad primary button)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? touches.count
        activeTouches = active
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
            // Fingers wobble, pointers and Pencils do not.
            let threshold: CGFloat
            switch touch.type {
            case .pencil: threshold = 2
            case .indirectPointer: threshold = 1
            default: threshold = 8
            }
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
            onModifiersConsumed?()
        } else {
            click(.left, at: point)
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
        activeTouches = active
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
        click(.right, at: normalized(location))
    }

    @objc private func handleThreeFingerSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .left: sendKey(KeyCodeMap.rightArrow, extra: [.control])   // next Space
        case .right: sendKey(KeyCodeMap.leftArrow, extra: [.control])   // previous Space
        case .up: sendKey(KeyCodeMap.upArrow, extra: [.control])        // Mission Control
        case .down: sendKey(KeyCodeMap.downArrow, extra: [.control])    // App Exposé
        default: break
        }
    }

    @objc private func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
        onToggleControls?()
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        // The trackpad recognizer also sees press-drags (touches > 0); those
        // are handled by the touch path as click-and-drag, not as scrolling.
        if gesture.allowedScrollTypesMask == .all, gesture.numberOfTouches > 0 { return }
        // Three fingers down is a swipe gesture, never a scroll.
        if activeTouches >= 3 { return }
        switch gesture.state {
        case .began:
            scrollStart = gesture.location(in: self)
            edgeSwipeFired = false
            navSwipeFired = false
        case .changed:
            // iPadOS keeps three-finger trackpad swipes for itself, so the Mac
            // trackpad gestures get a stand-in: hold ⌃ (or latch it) and swipe
            // with two fingers: left/right = Spaces, up = Mission Control,
            // down = App Exposé. No scroll is sent while ⌃ is held.
            if hardwareModifiers.union(latchedModifiers).contains(.control) {
                let total = gesture.translation(in: self)
                guard !navSwipeFired, max(abs(total.x), abs(total.y)) > 50 else { return }
                navSwipeFired = true
                let horizontal = abs(total.x) > abs(total.y)
                let code: UInt16 = horizontal ? (total.x < 0 ? KeyCodeMap.rightArrow : KeyCodeMap.leftArrow)
                                              : (total.y < 0 ? KeyCodeMap.upArrow : KeyCodeMap.downArrow)
                let saved = latchedModifiers
                latchedModifiers.remove(.control)   // ⌃ is added explicitly below
                sendKey(code, extra: [.control])
                latchedModifiers = saved
                return
            }
            // A two-finger swipe that starts at the screen edge is Back / Forward
            // (⌘[ / ⌘]), like Safari's edge swipe; macOS has no public way to
            // post the real trackpad swipe gesture.
            let total = gesture.translation(in: self)
            let nearLeft = scrollStart.x < edgeWidth
            let nearRight = scrollStart.x > bounds.width - edgeWidth
            if !edgeSwipeFired, nearLeft || nearRight, abs(total.x) > 60, abs(total.x) > abs(total.y) * 2 {
                edgeSwipeFired = true
                sendKey(nearLeft ? KeyCodeMap.leftBracket : KeyCodeMap.rightBracket, extra: [.command])
                return
            }
            if nearLeft || nearRight { return }
            let delta = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            guard delta != .zero else { return }
            let sign: CGFloat = invertScroll ? -1 : 1
            onEvent?(.scroll(at: normalized(gesture.location(in: self)), deltaX: delta.x * sign, deltaY: delta.y * sign, precise: true))
        default:
            break
        }
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
        pointerMoved(to: gesture.location(in: self))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Hover never blocks anything, and three-finger swipes must be able to
        // recognise even if two fingers already started the scroll recognizer.
        gestureRecognizer is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer
            || gestureRecognizer is UISwipeGestureRecognizer || other is UISwipeGestureRecognizer
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, let mapped = KeyCodeMap.macVirtualKey(forHIDUsage: key.keyCode.rawValue) {
                let code = mapped
                var modifiers = Self.modifiers(key.modifierFlags).union(latchedModifiers)
                if remapOptionShortcuts, modifiers == [.option], code == KeyCodeMap.tab || code == KeyCodeMap.space {
                    modifiers = [.command]
                }
                let characters = key.characters.isEmpty ? nil : key.characters
                onEvent?(.keyDown(keyCode: code, modifiers: modifiers, characters: characters))
                if KeyCodeMap.isModifier(code) {
                    hardwareModifiers.formUnion(Self.modifier(forKey: code))
                } else {
                    startRepeat(code: code, modifiers: modifiers, characters: characters)
                }
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    // MARK: Key repeat

    /// iPadOS does not deliver auto-repeat for hardware keys to pressesBegan,
    /// so holding a key would send one event. Repeat it like the Mac would:
    /// first after 400 ms, then every 50 ms until the key is released.
    private func startRepeat(code: UInt16, modifiers: KeyModifiers, characters: String?) {
        repeatTimers[code]?.invalidate()
        heldKeys[code] = (modifiers, characters)
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self, let held = self.heldKeys[code] else { return }
            let repeating = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let held = self.heldKeys[code] else { return }
                self.onEvent?(.keyDown(keyCode: code, modifiers: held.modifiers, characters: held.characters))
            }
            RunLoop.main.add(repeating, forMode: .common)
            self.repeatTimers[code] = repeating
            self.onEvent?(.keyDown(keyCode: code, modifiers: held.modifiers, characters: held.characters))
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimers[code] = timer
    }

    private func stopRepeat(code: UInt16) {
        repeatTimers[code]?.invalidate()
        repeatTimers[code] = nil
        heldKeys[code] = nil
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
                stopRepeat(code: code)
                hardwareModifiers.subtract(Self.modifier(forKey: code))
                var modifiers = Self.modifiers(key.modifierFlags).union(latchedModifiers)
                if remapOptionShortcuts, modifiers == [.option], code == KeyCodeMap.tab || code == KeyCodeMap.space {
                    modifiers = [.command]
                }
                onEvent?(.keyUp(keyCode: code, modifiers: modifiers))
                if !KeyCodeMap.isModifier(code) { onModifiersConsumed?() }
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    private static func modifier(forKey code: UInt16) -> KeyModifiers {
        switch code {
        case KeyCodeMap.command, KeyCodeMap.rightCommand: return .command
        case KeyCodeMap.option, KeyCodeMap.rightOption: return .option
        case KeyCodeMap.control, KeyCodeMap.rightControl: return .control
        case KeyCodeMap.shift, KeyCodeMap.rightShift: return .shift
        default: return []
        }
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
            sendKey(KeyCodeMap.returnKey)
        } else if !latchedModifiers.isEmpty {
            // With a modifier latched, type as key presses so ⌘C is a real shortcut.
            for character in text {
                if let mapped = KeyCodeMap.macVirtualKey(forCharacter: character) {
                    sendKey(mapped.code, extra: mapped.shift ? [.shift] : [], characters: String(character))
                }
            }
        } else {
            onEvent?(.typeText(text))
        }
    }

    func deleteBackward() {
        sendKey(KeyCodeMap.delete)
    }
}

/// iPadOS attaches three-finger undo/redo and edit-menu gestures to any text
/// input that is first responder. Opting out here lets our own three-finger
/// recognizers see those touches.
final class InputCaptureViewController: UIViewController {
    let captureView = InputCaptureUIView()
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override func loadView() { view = captureView }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

struct InputCaptureView: UIViewControllerRepresentable {
    let videoRect: () -> CGRect
    let softwareKeyboard: Bool
    let latchedModifiers: KeyModifiers
    let invertScroll: Bool
    let remapOptionShortcuts: Bool
    let onEvent: (InputEvent) -> Void
    let onToggleControls: () -> Void
    let onModifiersConsumed: () -> Void
    let onPointerLocation: (CGPoint) -> Void
    /// Lets the SwiftUI strip send keys through the same path (Esc, arrows…).
    let register: (InputCaptureUIView) -> Void

    func makeUIViewController(context: Context) -> InputCaptureViewController {
        let controller = InputCaptureViewController()
        let view = controller.captureView
        apply(to: view)
        register(view)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return controller
    }

    func updateUIViewController(_ controller: InputCaptureViewController, context: Context) {
        let view = controller.captureView
        apply(to: view)
        if !view.isFirstResponder { view.becomeFirstResponder() }
    }

    private func apply(to view: InputCaptureUIView) {
        view.onEvent = onEvent
        view.onToggleControls = onToggleControls
        view.onModifiersConsumed = onModifiersConsumed
        view.onPointerLocation = onPointerLocation
        view.videoRectProvider = videoRect
        view.softwareKeyboardEnabled = softwareKeyboard
        view.latchedModifiers = latchedModifiers
        view.invertScroll = invertScroll
        view.remapOptionShortcuts = remapOptionShortcuts
    }
}
