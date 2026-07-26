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
            swiftSettings: [
                // Local dev toolchain workaround: this machine's Homebrew Swift
                // 6.3.x xctoolchain ships an `_Testing_Foundation` cross-import
                // overlay module built with a macOS 26 minimum deployment
                // target, which fails to compile against this package's
                // macOS 14 target in any file that imports both `Foundation`
                // and `Testing` (required throughout these tests). Disabling
                // cross-import overlay loading avoids pulling that module in;
                // we don't rely on any Foundation/Testing overlay behavior.
                // Scoped to macOS only — not needed/relevant on Linux CI.
                .unsafeFlags(
                    ["-Xfrontend", "-disable-cross-import-overlays"],
                    .when(platforms: [.macOS])
                )
            ]
        )
    ]
)
