// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiveCaptions",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored FluidAudio v0.15.7 (Apache 2.0). scripts/fetch-deps.sh fetches its xcframework.
        .package(path: "Vendor/FluidAudio"),
    ],
    targets: [
        .executableTarget(
            name: "LiveCaptions",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/LiveCaptions",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "Translation"]),
            ]
        ),
        .testTarget(name: "LiveCaptionsTests", dependencies: ["LiveCaptions"], path: "Tests/LiveCaptionsTests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
