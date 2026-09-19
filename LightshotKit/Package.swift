// swift-tools-version: 6.0
import PackageDescription

// The domain core. Pure Swift — no AppKit / ScreenCaptureKit imports live here.
// The absence of those framework imports in this package (and its test target) is
// the structural litmus test that the app/domain seam is placed correctly.
let package = Package(
    name: "LightshotKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LightshotKit", targets: ["LightshotKit"])
    ],
    targets: [
        .target(name: "LightshotKit"),
        .testTarget(
            name: "LightshotKitTests",
            dependencies: ["LightshotKit"]
        )
    ]
)
