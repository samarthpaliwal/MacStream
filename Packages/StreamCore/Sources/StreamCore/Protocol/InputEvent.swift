import Foundation

/// A point in normalised stream coordinates: (0,0) is the top-left of the
/// mirrored Mac display, (1,1) the bottom-right. Using normalised values keeps
/// the protocol independent of either device's resolution.
public struct NormalizedPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum PointerButton: String, Codable, Sendable {
    case left
    case right
    case middle
}

/// Modifier keys, mirrored from the iPad's hardware keyboard state.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let function = KeyModifiers(rawValue: 1 << 5)
}

/// Input events travel iPad → Mac over the reliable control channel.
/// The Mac translates them into CGEvents (Milestone 5).
public enum InputEvent: Codable, Hashable, Sendable {
    case pointerMove(NormalizedPoint)
    case pointerDown(NormalizedPoint, button: PointerButton)
    case pointerUp(NormalizedPoint, button: PointerButton)
    /// Deltas are in points; `precise` is true for trackpad/finger scrolling.
    case scroll(at: NormalizedPoint, deltaX: Double, deltaY: Double, precise: Bool)
    /// `scale` is the cumulative pinch factor since the gesture began.
    case magnify(at: NormalizedPoint, scale: Double)
    /// `keyCode` is a macOS virtual key code; `characters` helps with layouts
    /// where the code alone is ambiguous.
    case keyDown(keyCode: UInt16, modifiers: KeyModifiers, characters: String?)
    case keyUp(keyCode: UInt16, modifiers: KeyModifiers)
    case modifiersChanged(KeyModifiers)
    /// Text from the iPad's on-screen keyboard, typed as Unicode on the Mac.
    case typeText(String)
}
