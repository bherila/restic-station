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
            ]
        )
    ]
)
