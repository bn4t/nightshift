// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nightshift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nightshift", targets: ["Nightshift"]),
    ],
    targets: [
        // Pure logic (no AppKit/CoreGraphics), fully unit-tested.
        .target(name: "NightshiftCore"),
        // The menu bar app.
        .executableTarget(name: "Nightshift", dependencies: ["NightshiftCore"]),
        .testTarget(name: "NightshiftCoreTests", dependencies: ["NightshiftCore"]),
    ]
)
