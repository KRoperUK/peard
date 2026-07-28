// swift-tools-version: 5.9
import PackageDescription

// PeardCore is a local package linked by both the Peard app target and the
// PearWidgetExtension target. macOS is listed as a platform so the test suite
// runs with a plain `swift test` (no simulator) — which is why nothing in this
// module may import UIKit.
let package = Package(
    name: "PeardCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PeardCore", targets: ["PeardCore"]),
    ],
    targets: [
        .target(name: "PeardCore"),
        .testTarget(name: "PeardCoreTests", dependencies: ["PeardCore"]),
    ]
)
