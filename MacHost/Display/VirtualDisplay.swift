import CoreGraphics
import Foundation

/// A virtual display sized to the iPad, so the iPad can act as a second
/// screen instead of a mirror. Built on a private CoreGraphics interface:
/// `isSupported` checks the classes exist before anything is attempted, and
/// releasing the object removes the display again.
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let pointWidth: Int
    let pointHeight: Int
    private let display: CGVirtualDisplay

    static var isSupported: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
    }

    /// - Parameters:
    ///   - pointWidth/pointHeight: logical size (the iPad's screen in points).
    ///   - hiDPI: render at 2× like a Retina display. Costs encode time but
    ///     text on the iPad is crisp.
    init?(name: String, pointWidth: Int, pointHeight: Int, hiDPI: Bool) {
        guard Self.isSupported, pointWidth > 0, pointHeight > 0 else { return nil }
        let scale = hiDPI ? 2 : 1

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = UInt(pointWidth * scale)
        descriptor.maxPixelsHigh = UInt(pointHeight * scale)
        // Roughly a 13-inch panel; only affects the reported physical size.
        descriptor.sizeInMillimeters = CGSize(width: 280, height: 280 * Double(pointHeight) / Double(pointWidth))
        descriptor.productID = 0x4D53          // "MS"
        descriptor.vendorID = 0x5354           // "ST"
        descriptor.serialNum = 1
        descriptor.queue = DispatchQueue.main
        descriptor.terminationHandler = { _, _ in }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(pointWidth), height: UInt(pointHeight), refreshRate: 60)]
        guard display.apply(settings) else { return nil }

        self.display = display
        self.displayID = display.displayID
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
    }
}
