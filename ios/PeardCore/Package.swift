// swift-tools-version: 5.9
import PackageDescription

// PeardCore is a local package linked by the Peard app and the widget and
// Messages extensions. macOS is listed as a platform so the test suite runs with
// a plain `swift test` (no simulator) — which is why nothing in this module may
// import UIKit unguarded.
//
// watchOS is declared ahead of any watch app existing, because that discipline
// is what makes one cheap: the module already compiles without UIKit, so the
// port should be target configuration rather than code. Unverified, though —
// the watchOS platform is not installed on the machine this was written on, so
// nothing here has ever been built for it.
let package = Package(
    name: "PeardCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "PeardCore", targets: ["PeardCore"]),
    ],
    targets: [
        .target(name: "PeardCore"),
        .testTarget(name: "PeardCoreTests", dependencies: ["PeardCore"]),
    ]
)
