// swift-tools-version:6.0
import PackageDescription

// Root SwiftPM package for the headless side of Restic Station.
//
// It exists so `restic-station-helper` can be built and tested with plain
// `swift build` / `swift test` on Linux (M5). It deliberately does NOT
// absorb `Core/Package.swift`: `Core` stays its own package so the existing
// `swift test --package-path Core` invocation and the `project.yml`
// XcodeGen package reference (`ResticStationCore: path: Core`) keep working
// byte-for-byte. No source file moves for the same reason — the helper
// target points straight at `Helper/Sources`, the same directory the
// XcodeGen `restic-station-helper` tool target uses.
//
// `Restic Station.app` (`App/Sources`, SwiftUI) is macOS-only and is
// intentionally absent from this package.
let package = Package(
    name: "restic-station",
    // Apple-platform minimum deployment target only; SwiftPM ignores this
    // entirely on Linux. It must match `Core/Package.swift` (and
    // `project.yml`'s `deploymentTarget.macOS: "14.0"`), otherwise SwiftPM
    // refuses to link a macOS 10.13 executable against a macOS 14 library.
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "Core"),
        // Same lower bound as `project.yml` pins, so the Xcode build and the
        // SwiftPM build resolve to the same argument-parser version.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "restic-station-helper",
            dependencies: [
                .product(name: "ResticStationCore", package: "Core"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Helper/Sources"
        ),
        .testTarget(
            name: "HelperTests",
            dependencies: ["restic-station-helper"],
            path: "Helper/Tests/HelperTests"
        ),
    ]
)
