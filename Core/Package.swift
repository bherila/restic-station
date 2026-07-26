// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ResticStationCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ResticStationCore",
            targets: ["ResticStationCore"]
        )
    ],
    targets: [
        .target(
            name: "ResticStationCore"
        ),
        .testTarget(
            name: "ResticStationCoreTests",
            dependencies: ["ResticStationCore"],
            resources: [
                .copy("Fixtures")
            ],
            // Local dev toolchain workaround: this Homebrew Swift 6.3.3
            // snapshot ships a Testing+Foundation cross-import overlay
            // module (`_Testing_Foundation`) built with a macOS 26 minimum
            // deployment target, which conflicts with this package's
            // macOS 14 target the moment a test file imports both
            // `Testing` and `Foundation` (needed throughout — fixtures are
            // `Data`, timestamps are `Date`). Disabling cross-import
            // overlay loading for the test target only sidesteps it
            // without touching the package's real deployment target.
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-disable-cross-import-overlays"])
            ]
        )
    ]
)
