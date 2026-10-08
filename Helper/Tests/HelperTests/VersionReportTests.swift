import Foundation
import ResticStationCore
import Testing
@testable import restic_station_helper

@Suite("version --json payload")
struct VersionReportTests {
    /// The release appcast is stamped from this field, and Sparkle uses it
    /// to decide whether an update migrates the shared config — so it must
    /// be the schema this binary actually writes, not a copy of it.
    @Test("configSchemaVersion is the schema this binary writes")
    func reportsCurrentConfigSchema() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Version.report)) as? [String: Any]
        #expect(object?["configSchemaVersion"] as? Int == AppConfig.currentVersion)
        #expect(Set(object?.keys ?? [:].keys) == ["name", "version", "platform", "configSchemaVersion"])
    }

    /// The macOS app reports `MARKETING_VERSION`; the helper (including the
    /// Linux build, which has no bundle) reports its own constant. A release
    /// that bumps one and not the other ships a helper claiming the wrong
    /// version, so every `MARKETING_VERSION` in `project.yml` must match it.
    @Test("the helper's version is project.yml's MARKETING_VERSION")
    func versionMatchesProject() throws {
        let projectFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HelperTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Helper
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("project.yml")
        let lines = try String(contentsOf: projectFile, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("MARKETING_VERSION:") }
        let versions = lines.map {
            $0.dropFirst("MARKETING_VERSION:".count)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        }
        #expect(!versions.isEmpty)
        #expect(versions.allSatisfy { $0 == Version.version }, "project.yml has \(versions)")
    }
}
