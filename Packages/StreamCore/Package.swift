// swift-tools-version: 5.9
import PackageDescription

/// StreamCore holds everything both apps must agree on: the wire protocol,
/// pairing key derivation, quality presets, and timing helpers.
/// It has no UI and no platform-specific capture or injection code.
let package = Package(
    name: "StreamCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "StreamCore", targets: ["StreamCore"]),
    ],
    targets: [
        .target(name: "StreamCore"),
        .testTarget(name: "StreamCoreTests", dependencies: ["StreamCore"]),
    ]
)
