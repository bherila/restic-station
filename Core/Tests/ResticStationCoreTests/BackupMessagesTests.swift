import Testing
import Foundation
@testable import ResticStationCore

@Suite("BackupMessages fixture decoding")
struct BackupMessagesTests {
    @Test("backup.ndjson: status + summary lines")
    func backupNdjson() throws {
        let lines = try FixtureLoader.lines("backup.ndjson")
        #expect(lines.count == 3)

        let decoder = makeResticJSONDecoder()
        let status = try decoder.decode(BackupStatus.self, from: Data(lines[0].utf8))
        #expect(status.percentDone == 1)
        #expect(status.totalFiles == 3)
        #expect(status.filesDone == 3)
        #expect(status.totalBytes == 65571)
        #expect(status.bytesDone == 65571)

        let summary = try decoder.decode(BackupSummary.self, from: Data(lines[2].utf8))
        #expect(summary.filesNew == 3)
        #expect(summary.filesChanged == 0)
        #expect(summary.dirsNew == 2)
        #expect(summary.dataAdded == 67860)
        #expect(summary.totalBytesProcessed == 65571)
        #expect(summary.snapshotId == "e9ffc5cb64395ad443fd14f432751a9823181224978d6b25bf2af1a99ad367fd")
        #expect(summary.backupStart != nil)
        #expect(summary.backupEnd != nil)
    }

    @Test("backup2.ndjson: incremental backup summary")
    func backup2Ndjson() throws {
        let lines = try FixtureLoader.lines("backup2.ndjson")
        let decoder = makeResticJSONDecoder()
        let summary = try decoder.decode(BackupSummary.self, from: Data(lines[2].utf8))
        #expect(summary.filesNew == 0)
        #expect(summary.filesChanged == 1)
        #expect(summary.filesUnmodified == 2)
        #expect(summary.dataAdded == 1842)
        #expect(summary.snapshotId == "f391ba97c0968db507509e12d467de87753929ae749cbc2b1cfd81743eb19f52")
    }

    @Test("restore.ndjson: restore summary")
    func restoreNdjson() throws {
        let lines = try FixtureLoader.lines("restore.ndjson")
        #expect(lines.count == 1)
        let decoder = makeResticJSONDecoder()
        let summary = try decoder.decode(RestoreSummary.self, from: Data(lines[0].utf8))
        #expect(summary.totalFiles == 4)
        #expect(summary.filesRestored == 4)
        #expect(summary.totalBytes == 65576)
        #expect(summary.bytesRestored == 65576)
    }

    @Test("locked-error.json: exit_error message")
    func lockedError() throws {
        let data = try FixtureLoader.data("locked-error.json")
        let decoder = makeResticJSONDecoder()
        let error = try decoder.decode(ExitErrorMessage.self, from: data)
        #expect(error.code == 11)
        #expect(error.message.contains("already locked"))
        #expect(error.message.contains("unlock"))
    }
}
