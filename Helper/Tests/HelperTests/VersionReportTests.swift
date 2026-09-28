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
}
