import Foundation

/// Translates USB HID keyboard usages (what UIKit reports for hardware keys)
/// into macOS virtual key codes (what CGEvent needs). The iPad does this
/// before sending so the wire format is always Mac key codes.
public enum KeyCodeMap {
    // macOS virtual key codes (Carbon kVK_* values).
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let command: UInt16 = 55
    public static let shift: UInt16 = 56
    public static let capsLock: UInt16 = 57
    public static let option: UInt16 = 58
    public static let control: UInt16 = 59
    public static let rightCommand: UInt16 = 54
    public static let rightShift: UInt16 = 60
    public static let rightOption: UInt16 = 61
    public static let rightControl: UInt16 = 62
    public static let equal: UInt16 = 24
    public static let minus: UInt16 = 27

    private static let table: [Int: UInt16] = {
        var map: [Int: UInt16] = [:]
        // Letters: HID 4...29 = a...z
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (offset, code) in letters.enumerated() { map[4 + offset] = code }
        // Digits: HID 30...39 = 1...9, 0
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (offset, code) in digits.enumerated() { map[30 + offset] = code }

        map[40] = returnKey
        map[41] = escape
        map[42] = delete
        map[43] = tab
        map[44] = space
        map[45] = minus          // -
        map[46] = equal          // =
        map[47] = 33             // [
        map[48] = 30             // ]
        map[49] = 42             // backslash
        map[51] = 41             // ;
        map[52] = 39             // '
        map[53] = 50             // `
        map[54] = 43             // ,
        map[55] = 47             // .
        map[56] = 44             // /
        map[57] = capsLock
        // F1...F12: HID 58...69
        let fKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (offset, code) in fKeys.enumerated() { map[58 + offset] = code }
        map[74] = 115            // home
        map[75] = 116            // page up
        map[76] = 117            // forward delete
        map[77] = 119            // end
        map[78] = 121            // page down
        map[79] = 124            // right arrow
        map[80] = 123            // left arrow
        map[81] = 125            // down arrow
        map[82] = 126            // up arrow
        map[224] = control
        map[225] = shift
        map[226] = option
        map[227] = command
        map[228] = rightControl
        map[229] = rightShift
        map[230] = rightOption
        map[231] = rightCommand
        return map
    }()

    public static func macVirtualKey(forHIDUsage usage: Int) -> UInt16? {
        table[usage]
    }

    /// Modifier key codes, so the Mac side can treat them as flag changes.
    public static func isModifier(_ keyCode: UInt16) -> Bool {
        [command, shift, capsLock, option, control, rightCommand, rightShift, rightOption, rightControl].contains(keyCode)
    }
}
