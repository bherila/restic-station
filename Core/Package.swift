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
                // Works around a Homebrew-toolchain-only issue where the
                // prebuilt `_Testing_Foundation` cross-import overlay
                // (auto-loaded whenever a file imports both `Testing` and
                // `Foundation`) reports a minimum deployment target of
                // macOS 26 regardless of this package's platform setting,
                // failing every such file with "compiling for macOS 14.0,
                // but module '_Testing_Foundation' has a minimum
                // deployment target of macOS 26". Disabling cross-import
                // overlay loading avoids the mismatch; it only turns off an
                // optional convenience overlay (nicer #expect output for
                // Foundation types), not functionality this package needs.
                // Harmless on Linux/CI toolchains, where the flag is a
                // no-op since the overlay doesn't ship there.
                .unsafeFlags(
                    ["-Xfrontend", "-disable-cross-import-overlays"],
                    .when(platforms: [.macOS])
                )
            ]
        )
    ]
)
