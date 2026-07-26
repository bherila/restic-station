import Testing
import Foundation
@testable import ResticStationCore

@Suite("VersionInfo fixture decoding + meetsMinimum")
struct VersionInfoTests {
    @Test("version.json")
    func versionJson() throws {
        let data = try FixtureLoader.data("version.json")
        let info = try parseVersion(data)
        #expect(info.version == "0.18.1")
        #expect(info.goVersion == "go1.25.1")
        #expect(info.goOS == "darwin")
        #expect(info.goArch == "arm64")
    }

    @Test(
        "meetsMinimum numeric-triple comparisons",
        arguments: [
            ("0.18.1", "0.17.0", true),
            ("0.18.1", "0.18.1", true),
            ("0.18.1", "0.18.0", true),
            ("0.18.1", "0.19.0", false),
            ("0.18.1", "0.18.2", false),
            ("1.0.0", "0.99.99", true),
            ("0.9.0", "0.10.0", false),
        ] as [(String, String, Bool)]
    )
    func meetsMinimum(version: String, minimum: String, expected: Bool) {
        let info = VersionInfo(version: version, goVersion: nil, goOS: nil, goArch: nil)
        #expect(info.meetsMinimum(minimum) == expected)
    }
}
