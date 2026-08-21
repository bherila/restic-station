import Foundation
import Testing
@testable import ResticStationCore

@Suite("StateStore: typed read/write for the four state/ files")
struct StateStoreTests {
    private func makeStore() -> (store: StateStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-statestore-test-\(UUID().uuidString)")
        return (StateStore(paths: AppPaths(root: root)), root)
    }

    // MARK: - Decoding the documented literal examples (docs/data-model.md)

    // The doc's `"sets"`/`"destId"` examples abbreviate UUIDs with "..." for
    // readability; these tests use the full UUID from the same running
    // example in §config.json (the "Projects" set) so the literal is valid
    // JSON while matching the documented shape/field names/value types
    // exactly.
    private static let exampleSetId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private static let exampleDestId = UUID(uuidString: "1B2C3D4E-8B86-D011-B42D-00C04FC964FF")!

    @Test("decodes the documented state/schedule-state.json literal")
    func decodesScheduleStateExample() throws {
        let json = """
        {
          "sets": {
            "\(Self.exampleSetId.uuidString)": {
              "lastBackupStart": "2026-07-26T20:57:04Z",
              "lastCheckStart": "2026-07-20T03:00:00Z",
              "checkSliceCursor": 7
            }
          }
        }
        """
        let decoded = try StateStore.makeDecoder().decode(ScheduleState.self, from: Data(json.utf8))
        let entry = try #require(decoded.sets[Self.exampleSetId])
        #expect(entry.checkSliceCursor == 7)
        #expect(entry.lastBackupStart == Self.date("2026-07-26T20:57:04Z"))
        #expect(entry.lastCheckStart == Self.date("2026-07-20T03:00:00Z"))

        // Round-trips through this store's own encoder/decoder.
        let reEncoded = try StateStore.makeEncoder().encode(decoded)
        let reDecoded = try StateStore.makeDecoder().decode(ScheduleState.self, from: reEncoded)
        #expect(reDecoded == decoded)
    }

    @Test("decodes the documented state/repo-status-<destId>.json literal")
    func decodesRepoStatusExample() throws {
        let json = """
        {
          "destId": "\(Self.exampleDestId.uuidString)",
          "reachable": false,
          "probedAt": "2026-07-26T20:57:10Z",
          "lastSyncedAt": "2026-07-12T02:31:00Z",
          "lastError": null
        }
        """
        let decoded = try StateStore.makeDecoder().decode(RepoStatus.self, from: Data(json.utf8))
        #expect(decoded.destId == Self.exampleDestId)
        #expect(decoded.reachable == false)
        #expect(decoded.probedAt == Self.date("2026-07-26T20:57:10Z"))
        #expect(decoded.lastSyncedAt == Self.date("2026-07-12T02:31:00Z"))
        #expect(decoded.lastError == nil)

        let reEncoded = try StateStore.makeEncoder().encode(decoded)
        let reDecoded = try StateStore.makeDecoder().decode(RepoStatus.self, from: reEncoded)
        #expect(reDecoded == decoded)
    }

    @Test("decodes the documented state/current-run-<setId>.json literal")
    func decodesCurrentRunExample() throws {
        let json = """
        {
          "runId": "20260726T205704Z-backup-6f9619ff",
          "kind": "backup",
          "phase": "backing-up-primary",
          "percentDone": 0.42,
          "bytesDone": 1234567,
          "totalBytes": 987654321,
          "filesDone": 120,
          "totalFiles": 4000,
          "currentFiles": ["/Users/user/proj/big.dat"],
          "heartbeatAt": "2026-07-26T20:57:31Z",
          "heartbeatUptime": 12345.5,
          "updatedAt": "2026-07-26T20:57:30Z"
        }
        """
        let decoded = try StateStore.makeDecoder().decode(CurrentRunState.self, from: Data(json.utf8))
        #expect(decoded.runId == "20260726T205704Z-backup-6f9619ff")
        #expect(decoded.kind == .backup)
        #expect(decoded.phase == "backing-up-primary")
        #expect(decoded.percentDone == 0.42)
        #expect(decoded.bytesDone == 1_234_567)
        #expect(decoded.totalBytes == 987_654_321)
        #expect(decoded.filesDone == 120)
        #expect(decoded.totalFiles == 4000)
        #expect(decoded.currentFiles == ["/Users/user/proj/big.dat"])
        #expect(decoded.heartbeatAt == Self.date("2026-07-26T20:57:31Z"))
        #expect(decoded.heartbeatUptime == 12_345.5)
        #expect(decoded.updatedAt == Self.date("2026-07-26T20:57:30Z"))

        let reEncoded = try StateStore.makeEncoder().encode(decoded)
        let reDecoded = try StateStore.makeDecoder().decode(CurrentRunState.self, from: reEncoded)
        #expect(reDecoded == decoded)
    }

    @Test("current-run files from before heartbeats remain decodable")
    func decodesLegacyCurrentRunWithoutHeartbeat() throws {
        let json = """
        {
          "runId": "legacy",
          "kind": "check",
          "phase": "checking",
          "percentDone": 0,
          "bytesDone": 0,
          "totalBytes": 0,
          "filesDone": 0,
          "totalFiles": 0,
          "currentFiles": [],
          "updatedAt": "2026-07-26T20:57:30Z"
        }
        """
        let decoded = try StateStore.makeDecoder().decode(CurrentRunState.self, from: Data(json.utf8))
        #expect(decoded.heartbeatAt == nil)
        #expect(decoded.heartbeatUptime == nil)
    }

    @Test("decodes the documented state/fda-check.json literal")
    func decodesFdaCheckExample() throws {
        let json = """
        { "checkedAt": "2026-07-26T20:57:00Z", "hasFullDiskAccess": true, "probedPath": "~/Library/Safari", "context": "launchd" }
        """
        let decoded = try StateStore.makeDecoder().decode(FdaCheckResult.self, from: Data(json.utf8))
        #expect(decoded.checkedAt == Self.date("2026-07-26T20:57:00Z"))
        #expect(decoded.hasFullDiskAccess == true)
        #expect(decoded.probedPath == "~/Library/Safari")
        #expect(decoded.context == "launchd")

        let reEncoded = try StateStore.makeEncoder().encode(decoded)
        let reDecoded = try StateStore.makeDecoder().decode(FdaCheckResult.self, from: reEncoded)
        #expect(reDecoded == decoded)
    }

    // MARK: - Missing / corrupt files never throw

    @Test("reads of missing files return nil, never throw")
    func missingFilesReturnNil() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.readScheduleState() == nil)
        #expect(store.readRepoStatus(destId: UUID()) == nil)
        #expect(store.readCurrentRun(setId: UUID()) == nil)
        #expect(store.readFdaCheck() == nil)
    }

    @Test("reads of corrupt files return nil, never throw")
    func corruptFilesReturnNil() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.paths.ensureDirectories()

        let destId = UUID()
        let setId = UUID()
        let garbage = Data("not valid json at all {{{".utf8)
        try garbage.write(to: store.paths.scheduleStateFile)
        try garbage.write(to: store.paths.repoStatusFile(destId: destId))
        try garbage.write(to: store.paths.currentRunFile(setId: setId))
        try garbage.write(to: store.paths.fdaCheckFile)

        #expect(store.readScheduleState() == nil)
        #expect(store.readRepoStatus(destId: destId) == nil)
        #expect(store.readCurrentRun(setId: setId) == nil)
        #expect(store.readFdaCheck() == nil)
    }

    // MARK: - Atomic writes leave no temp files

    @Test("writes leave no .tmp files behind, for all four state files")
    func writesLeaveNoTempFiles() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let destId = UUID()
        let setId = UUID()

        try store.updateScheduleState(setId: setId) { $0.checkSliceCursor = 3 }
        try store.updateRepoStatus(destId: destId) { $0.reachable = true }
        try store.writeCurrentRun(setId: setId, Self.sampleCurrentRun(setId: setId))
        try store.writeFdaCheck(FdaCheckResult(checkedAt: Date(), hasFullDiskAccess: true, probedPath: "~/Library/Safari", context: "app"))

        let contents = try FileManager.default.contentsOfDirectory(atPath: store.paths.stateDir.path)
        let tempFiles = contents.filter { $0.hasSuffix(".tmp") }
        #expect(tempFiles.isEmpty, "leftover temp files: \(tempFiles)")

        // And the real files are valid, complete JSON.
        for file in [
            store.paths.scheduleStateFile,
            store.paths.repoStatusFile(destId: destId),
            store.paths.currentRunFile(setId: setId),
            store.paths.fdaCheckFile,
        ] {
            let data = try Data(contentsOf: file)
            _ = try JSONSerialization.jsonObject(with: data) // must not throw
        }
    }

    @Test("save overwrites a pre-existing stale/corrupt temp file")
    func overwritesStaleTempFile() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.paths.ensureDirectories()

        let tempFile = store.paths.scheduleStateFile.deletingLastPathComponent()
            .appendingPathComponent(store.paths.scheduleStateFile.lastPathComponent + ".tmp", isDirectory: false)
        try Data("leftover garbage from a crashed write".utf8).write(to: tempFile)

        let setId = UUID()
        try store.updateScheduleState(setId: setId) { $0.checkSliceCursor = 1 }

        #expect(!FileManager.default.fileExists(atPath: tempFile.path))
        #expect(store.readScheduleState()?.sets[setId]?.checkSliceCursor == 1)
    }

    // MARK: - Mutate helpers create-or-update correctly

    @Test("updateScheduleState creates an entry when absent, then updates it in place")
    func updateScheduleStateCreatesThenUpdates() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let setId = UUID()
        let start = Self.date("2026-07-26T02:30:00Z")

        try store.updateScheduleState(setId: setId) { entry in
            #expect(entry == SetScheduleState()) // freshly created, all nil
            entry.lastBackupStart = start
            entry.checkSliceCursor = 1
        }
        var loaded = try #require(store.readScheduleState())
        #expect(loaded.sets[setId]?.lastBackupStart == start)
        #expect(loaded.sets[setId]?.checkSliceCursor == 1)
        #expect(loaded.sets.count == 1)

        // A second mutation updates the SAME entry rather than creating a
        // second one, and other fields already set survive untouched.
        try store.updateScheduleState(setId: setId) { entry in
            #expect(entry.lastBackupStart == start)
            entry.checkSliceCursor = 2
        }
        loaded = try #require(store.readScheduleState())
        #expect(loaded.sets.count == 1)
        #expect(loaded.sets[setId]?.lastBackupStart == start)
        #expect(loaded.sets[setId]?.checkSliceCursor == 2)

        // A different set gets its own independent entry.
        let otherSetId = UUID()
        try store.updateScheduleState(setId: otherSetId) { $0.checkSliceCursor = 9 }
        loaded = try #require(store.readScheduleState())
        #expect(loaded.sets.count == 2)
        #expect(loaded.sets[setId]?.checkSliceCursor == 2)
        #expect(loaded.sets[otherSetId]?.checkSliceCursor == 9)
    }

    @Test("updateRepoStatus creates a fresh unreachable record when absent, then updates it")
    func updateRepoStatusCreatesThenUpdates() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let destId = UUID()
        let probedAt = Self.date("2026-07-26T20:57:10Z")

        try store.updateRepoStatus(destId: destId) { status in
            #expect(status.destId == destId)
            #expect(status.reachable == false) // fresh default
            #expect(status.lastSyncedAt == nil)
            status.reachable = true
            status.probedAt = probedAt
            status.lastSyncedAt = probedAt
        }
        var loaded = try #require(store.readRepoStatus(destId: destId))
        #expect(loaded.reachable == true)
        #expect(loaded.probedAt == probedAt)
        #expect(loaded.lastSyncedAt == probedAt)

        // Going offline updates in place; lastSyncedAt (last SUCCESS) is
        // preserved by a caller that doesn't touch it.
        let laterProbe = Self.date("2026-07-26T21:00:00Z")
        try store.updateRepoStatus(destId: destId) { status in
            status.reachable = false
            status.probedAt = laterProbe
            status.lastError = "volume not mounted"
        }
        loaded = try #require(store.readRepoStatus(destId: destId))
        #expect(loaded.reachable == false)
        #expect(loaded.probedAt == laterProbe)
        #expect(loaded.lastSyncedAt == probedAt) // untouched
        #expect(loaded.lastError == "volume not mounted")
    }

    @Test("writeCurrentRun then clearCurrentRun round-trips and then reads nil")
    func writeThenClearCurrentRun() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let setId = UUID()
        let state = Self.sampleCurrentRun(setId: setId)
        try store.writeCurrentRun(setId: setId, state)
        #expect(store.readCurrentRun(setId: setId) == state)

        try store.clearCurrentRun(setId: setId)
        #expect(store.readCurrentRun(setId: setId) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.paths.currentRunFile(setId: setId).path))
    }

    @Test("clearCurrentRun on an already-absent file is a harmless no-op")
    func clearCurrentRunWhenAbsent() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // Must not throw even though nothing was ever written.
        try store.clearCurrentRun(setId: UUID())
    }

    // MARK: - currentRunSetIDs (T27 `status`)

    @Test("currentRunSetIDs finds every live current-run file, by filename, ignoring other state files")
    func currentRunSetIDsFindsLiveRuns() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let running1 = UUID()
        let running2 = UUID()
        let finished = UUID()
        try store.writeCurrentRun(setId: running1, Self.sampleCurrentRun(setId: running1))
        try store.writeCurrentRun(setId: running2, Self.sampleCurrentRun(setId: running2))
        // A repo-status file must not be mistaken for a current-run file.
        try store.updateRepoStatus(destId: UUID()) { $0.reachable = true }
        // A run that finished (file deleted) must not still count.
        try store.writeCurrentRun(setId: finished, Self.sampleCurrentRun(setId: finished))
        try store.clearCurrentRun(setId: finished)

        let ids = Set(store.currentRunSetIDs())
        #expect(ids == [running1, running2])
    }

    /// The documented contract this exists for: a set no longer in
    /// `config.json` but with a run still in flight must still be counted —
    /// discovery is by filename, never by cross-referencing the config.
    @Test("a run for a set no longer in config.json is still discovered")
    func currentRunSetIDsDoesNotConsultConfig() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let deletedSetId = UUID()
        try store.writeCurrentRun(setId: deletedSetId, Self.sampleCurrentRun(setId: deletedSetId))

        #expect(store.currentRunSetIDs() == [deletedSetId])
    }

    @Test("an absent state/ directory yields an empty list, not a throw")
    func currentRunSetIDsOnMissingStateDirectory() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // `makeStore()` never calls `ensureDirectories()`, so `state/` does
        // not exist yet.
        #expect(store.currentRunSetIDs().isEmpty)
    }

    @Test("writeFdaCheck round-trips")
    func writeFdaCheckRoundTrips() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = FdaCheckResult(
            checkedAt: Self.date("2026-07-26T20:57:00Z"),
            hasFullDiskAccess: false,
            probedPath: "~/Library/Mail",
            context: "app"
        )
        try store.writeFdaCheck(result)
        #expect(store.readFdaCheck() == result)
    }

    // MARK: - Encoding conventions

    @Test("encoded state file uses sortedKeys and prettyPrinted, like ConfigStore")
    func encodedFileUsesSortedKeysAndPrettyPrinted() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let destId = UUID()
        try store.updateRepoStatus(destId: destId) { $0.reachable = true }
        let contents = try String(contentsOf: store.paths.repoStatusFile(destId: destId), encoding: .utf8)
        #expect(contents.contains("\n")) // pretty-printed, not compact
        // .sortedKeys -> "destId" (d) before "lastError" (l) before "reachable" (r).
        let destIdRange = try #require(contents.range(of: "\"destId\""))
        let lastErrorRange = try #require(contents.range(of: "\"lastError\""))
        let reachableRange = try #require(contents.range(of: "\"reachable\""))
        #expect(destIdRange.lowerBound < lastErrorRange.lowerBound)
        #expect(lastErrorRange.lowerBound < reachableRange.lowerBound)
    }

    // MARK: - Helpers

    private static func sampleCurrentRun(setId: UUID) -> CurrentRunState {
        CurrentRunState(
            runId: "20260726T205704Z-backup-\(String(setId.uuidString.prefix(8)).lowercased())",
            kind: .backup,
            phase: "backing-up-primary",
            percentDone: 0.42,
            bytesDone: 1_234_567,
            totalBytes: 987_654_321,
            filesDone: 120,
            totalFiles: 4000,
            currentFiles: ["/Users/user/proj/big.dat"],
            updatedAt: Self.date("2026-07-26T20:57:30Z")
        )
    }

    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// `schedule-state.json` is one document shared by every set, while the
    /// only other lock is per-set — so two helper processes working on
    /// *different* sets take no common lock and each rewrite the whole file.
    /// Without the companion lock, one reads before the other's write and
    /// writes after it, silently discarding the other's entry. That entry now
    /// carries `appliedPurgeExcludes`, i.e. destructive bookkeeping.
    ///
    /// Interleaved deliberately: each mutation sleeps inside the critical
    /// section, so a read-modify-write that is not held under a lock will
    /// overlap and lose an entry essentially every run.
    @Test("concurrent updates for different sets do not lose one another")
    func concurrentScheduleStateUpdatesDoNotLoseEntries() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let setIds = (0..<8).map { _ in UUID() }
        await withTaskGroup(of: Void.self) { group in
            for (index, setId) in setIds.enumerated() {
                group.addTask {
                    try? store.updateScheduleState(setId: setId) { entry in
                        // Widen the window between read and write.
                        usleep(20_000)
                        entry.checkSliceCursor = index
                    }
                }
            }
        }

        let state = try #require(store.readScheduleState())
        for (index, setId) in setIds.enumerated() {
            #expect(state.sets[setId]?.checkSliceCursor == index, "lost the entry for set \(index)")
        }
    }
}
