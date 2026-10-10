import Foundation
import ResticStationCore
import Testing

@testable import restic_station_helper

/// `backup dry-run`'s two renderings (#78). The engine half is pinned by
/// `BackupDryRunTests`; this is what each output mode makes of a report.
@Suite("backup dry-run output")
struct BackupDryRunOutputTests {
    static let snapshotId = "e9ffc5cb64395ad443fd14f432751a9823181224978d6b25bf2af1a99ad367fd"

    /// `data_added_packed` deliberately absent, as an older restic leaves it.
    static func report(warnings: [String] = []) throws -> BackupDryRunReport {
        let summary = try JSONDecoder().decode(BackupSummary.self, from: Data("""
            {"files_new":2,"files_changed":1,"files_unmodified":5,"dirs_new":1,"dirs_changed":0,
             "dirs_unmodified":3,"data_added":1536,"total_files_processed":8,
             "total_bytes_processed":3145728,"snapshot_id":"\(snapshotId)"}
            """.utf8))
        return BackupDryRunReport(
            setId: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
            setName: "Projects",
            primary: Destination(id: UUID(), label: "Primary", repoURL: "/Volumes/Backup/repo", isPrimary: true),
            outcome: warnings.isEmpty ? .success : .warning,
            summary: summary,
            cloudFilesExcluded: false,
            excludeCaches: true,
            excludePatternCount: 12,
            resticExitCode: warnings.isEmpty ? 0 : 3,
            warnings: warnings,
            logNotes: ["global excludes: 12 pattern(s) from this machine's global exclusion list"]
        )
    }

    @Test("JSON: explicit nulls for figures restic left out, and no snapshot id or repository path")
    func jsonShape() throws {
        let data = try JSONEncoder().encode(BackupDryRunCommand.Report(try Self.report()))
        let text = String(decoding: data, as: UTF8.self)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let summary = try #require(object["summary"] as? [String: Any])

        #expect(summary.keys.contains("dataAddedPacked"))
        #expect(summary["dataAddedPacked"] is NSNull)
        #expect(summary["dataAdded"] as? Int == 1536)
        #expect(object["operation"] as? String == "backup-dry-run")
        #expect(object["outcome"] as? String == "success")
        #expect(!text.contains(Self.snapshotId))
        #expect(!text.contains("snapshotId"))
        #expect(!text.contains("/Volumes/Backup/repo"))
        #expect(!text.contains("global excludes"), "log notes are for humans only")
    }

    @Test("human: says no snapshot was saved, prints the figures, the notes and each warning")
    func humanLines() throws {
        let lines = BackupDryRunCommand.humanLines(try Self.report(warnings: ["some files were unreadable"]))

        #expect(lines.first == "dry run of \"Projects\" to \"Primary\" — no snapshot was saved")
        #expect(lines.contains("  files: 2 new, 1 changed, 5 unmodified"))
        #expect(lines.contains("  processed: 8 files, 3.0 MiB"))
        #expect(lines.contains("  would add: 1.5 KiB (? packed)"))
        #expect(lines.contains("  global excludes: 12 pattern(s) from this machine's global exclusion list"))
        #expect(lines.last == "  warning: some files were unreadable")
        #expect(!lines.joined().contains(Self.snapshotId))
    }

    @Test("byte counts use restic's binary units")
    func byteCounts() {
        #expect(BackupDryRunCommand.byteCount(0) == "0 B")
        #expect(BackupDryRunCommand.byteCount(1023) == "1023 B")
        #expect(BackupDryRunCommand.byteCount(1024) == "1.0 KiB")
        #expect(BackupDryRunCommand.byteCount(5 * 1024 * 1024 * 1024) == "5.0 GiB")
    }
}
