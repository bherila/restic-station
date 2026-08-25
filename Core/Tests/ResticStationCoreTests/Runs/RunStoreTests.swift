import Foundation
import Testing
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Tiny mutable counter usable from a `@Sendable` closure. `RunStore`'s
/// `now` closure is `@Sendable` (the store itself is `Sendable`), so a
/// plain captured `var` doesn't compile — tests that need a monotonically
/// increasing clock use this instead. Not thread-safe, but these tests
/// call the store synchronously from a single thread.
private final class TickCounter: @unchecked Sendable {
    private(set) var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

@Suite struct RunStoreTests {
    private func makePaths() -> AppPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-runstore-test-\(UUID().uuidString)")
        return AppPaths(root: root)
    }

    private func cleanup(_ paths: AppPaths) {
        try? FileManager.default.removeItem(at: paths.root)
    }

    // MARK: - runId format

    @Test func runIdFormatMatchesArchitectureSpec() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2026
        components.month = 7
        components.day = 26
        components.hour = 20
        components.minute = 57
        components.second = 4
        let knownDate = calendar.date(from: components)!

        let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let destId = UUID()
        let store = RunStore(paths: paths, now: { knownDate })

        let run = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .scheduled)

        #expect(run.runId == "20260726T205704Z-backup-6f9619ff")
    }

    @Test func runIdCollisionWithinSameSecondGetsNumericSuffix() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2026
        components.month = 1
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        let knownDate = calendar.date(from: components)!

        let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let destId = UUID()
        let store = RunStore(paths: paths, now: { knownDate })

        let first = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .manual)
        let second = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .manual)
        let third = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .manual)

        #expect(first.runId == "20260101T000000Z-backup-6f9619ff")
        #expect(second.runId == "20260101T000000Z-backup-6f9619ff-2")
        #expect(third.runId == "20260101T000000Z-backup-6f9619ff-3")
    }

    // MARK: - begin/finish round trip

    @Test func beginFinishRoundTripsMetadataAndIndex() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let tick = TickCounter()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let store = RunStore(paths: paths, now: {
            start.addingTimeInterval(TimeInterval(tick.next()))
        })

        let setId = UUID()
        let destId = UUID()

        var run = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .scheduled)
        run.argvRedacted = ["restic", "backup", "/src", "--json"]

        // Initial metadata: running, no end, pid = our own pid.
        let running = try store.metadata(runId: run.runId)
        #expect(running.status == .running)
        #expect(running.end == nil)
        #expect(running.pid == getpid())
        #expect(running.groupId == run.runId)
        #expect(running.setId == setId)
        #expect(running.destId == destId)

        let stats = BackupSummary(
            filesNew: 3,
            filesChanged: 1,
            filesUnmodified: 10,
            dirsNew: 1,
            dirsChanged: 0,
            dirsUnmodified: 5,
            dataBlobs: 2,
            treeBlobs: 1,
            dataAdded: 67_860,
            dataAddedPacked: 50_000,
            totalFilesProcessed: 14,
            totalBytesProcessed: 100_000,
            totalDuration: 1.5,
            backupStart: start,
            backupEnd: start.addingTimeInterval(1),
            snapshotId: "f391ba97c096"
        )

        try store.finish(run, status: .success, stats: stats, errorSummary: nil, resticExitCode: 0)

        let finished = try store.metadata(runId: run.runId)
        #expect(finished.status == .success)
        #expect(finished.end != nil)
        #expect(finished.resticExitCode == 0)
        #expect(finished.argvRedacted == ["restic", "backup", "/src", "--json"])
        #expect(finished.snapshotId == "f391ba97c096")
        #expect(finished.filesNew == 3)
        #expect(finished.filesChanged == 1)
        #expect(finished.dataAdded == 67_860)
        #expect(finished.stats == stats)
        #expect(finished.groupId == run.runId)

        let index = try store.recentRuns(limit: 10)
        #expect(index.count == 1)
        let entry = try #require(index.first)
        #expect(entry.runId == run.runId)
        #expect(entry.kind == .backup)
        #expect(entry.setId == setId)
        #expect(entry.destId == destId)
        #expect(entry.status == .success)
        #expect(entry.trigger == .scheduled)
        #expect(entry.snapshotId == "f391ba97c096")
        #expect(entry.filesNew == 3)
        #expect(entry.filesChanged == 1)
        #expect(entry.dataAdded == 67_860)
        #expect(entry.errorSummary == nil)
        #expect(entry.groupId == run.runId)
    }

    @Test func groupIdPropagatesAcrossRunsInAGroup() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() })
        let setId = UUID()
        let primaryDest = UUID()
        let secondaryDest = UUID()

        let backupRun = try store.begin(kind: .backup, setId: setId, destId: primaryDest, trigger: .scheduled)
        try store.finish(backupRun, status: .success)

        // The copy run's groupId is explicitly the backup's runId.
        let copyRun = try store.begin(
            kind: .copy,
            setId: setId,
            destId: secondaryDest,
            trigger: .scheduled,
            groupId: backupRun.groupId
        )
        try store.finish(copyRun, status: .success)

        #expect(backupRun.groupId == backupRun.runId)
        #expect(copyRun.groupId == backupRun.runId)

        let index = try store.recentRuns(limit: 10)
        #expect(index.count == 2)
        #expect(Set(index.map(\.groupId)) == [backupRun.runId])
    }

    // MARK: - Crash recovery

    @Test func recoverInterruptedRewritesDeadPidRunsAsFailed() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() })
        let setId = UUID()
        let destId = UUID()

        let run = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .scheduled)

        // Overwrite the metadata's pid with a pid that (almost certainly)
        // does not exist, simulating a crashed process.
        var stuck = try store.metadata(runId: run.runId)
        stuck.pid = 999_999
        try writeRawMetadata(stuck, paths: paths)

        let recovered = try store.recoverInterrupted()

        // The setId travels with the runId so the caller can also clear the
        // `state/current-run-<setId>.json` the dead process left behind —
        // `Tick.clearAbandonedProgress(for:…)`.
        #expect(recovered == [RecoveredRun(runId: run.runId, setId: setId)])

        let after = try store.metadata(runId: run.runId)
        #expect(after.status == .failed)
        #expect(after.errorSummary == "interrupted")
        #expect(after.end != nil)

        let index = try store.recentRuns(limit: 10)
        #expect(index.count == 1)
        #expect(index[0].status == .failed)
        #expect(index[0].errorSummary == "interrupted")
    }

    @Test func recoverInterruptedLeavesLivePidRunsUntouched() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() })
        let setId = UUID()
        let destId = UUID()

        // begin() stamps pid = getpid() (our own, very much alive) and
        // leaves status running (never finished).
        let run = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .scheduled)

        let recovered = try store.recoverInterrupted()

        #expect(recovered.isEmpty)

        let after = try store.metadata(runId: run.runId)
        #expect(after.status == .running)
        #expect(after.end == nil)

        // No index line should have been written for an untouched run.
        let index = try store.recentRuns(limit: 10)
        #expect(index.isEmpty)
    }

    @Test("terminal destructive metadata missing from the index is an audit failure")
    func terminalDestructiveMetadataMissingIndex() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)

        try FileManager.default.createDirectory(
            at: paths.runsIndexLockFile,
            withIntermediateDirectories: true
        )
        #expect(throws: (any Error).self) {
            try store.finish(run, status: .success, resticExitCode: 0)
        }

        let failure = try #require(store.unresolvedAuditFailures().first)
        #expect(failure.runId == run.runId)
        #expect(failure.reason == .terminalMetadataMissingIndex)
        #expect(try store.metadata(runId: run.runId).status == .success)
    }

    @Test("recovery preserves an unknown destructive repository outcome as critical")
    func recoverInterruptedDestructiveRunPreservesAuditFailure() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .purge, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)

        var stuck = try store.metadata(runId: run.runId)
        stuck.pid = 999_999
        try writeRawMetadata(stuck, paths: paths)

        _ = try store.recoverInterrupted()
        let recovered = try store.metadata(runId: run.runId)
        #expect(recovered.status == .failed)
        #expect(recovered.auditFailureReason == .launchedWithoutTerminalMetadata)
        #expect(recovered.errorSummary?.contains("operation_completed_audit_failed") == true)
        #expect(try store.recentRuns(limit: 10).count == 1)

        let failures = try store.unresolvedAuditFailures()
        let failure = try #require(failures.first)
        #expect(failures.count == 1)
        #expect(failure.runId == run.runId)
        #expect(failure.kind == .purge)
        #expect(failure.setId == run.setId)
        #expect(failure.destId == run.destId)
        #expect(abs(failure.start.timeIntervalSince(run.start)) < 0.001)
        #expect(failure.reason == .launchedWithoutTerminalMetadata)

        _ = try store.recoverInterrupted()
        #expect(try store.recentRuns(limit: 10).count == 1, "recovery is idempotent")
        #expect(try store.unresolvedAuditFailures() == failures)
    }

    // MARK: - Current-run liveness

    /// A `state/current-run-<setId>.json` for `runId`. Only `runId` matters
    /// to `liveness(ofCurrentRun:)`; the rest is filler.
    private func progress(runId: String, heartbeatUptime: TimeInterval? = nil) -> CurrentRunState {
        CurrentRunState(
            runId: runId,
            kind: .backup,
            phase: "backing-up-primary",
            percentDone: 0.5,
            bytesDone: 1,
            totalBytes: 2,
            filesDone: 1,
            totalFiles: 2,
            currentFiles: [],
            heartbeatAt: heartbeatUptime.map { _ in Date(timeIntervalSince1970: 100) },
            heartbeatUptime: heartbeatUptime,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("a run whose process is still alive is live")
    func livenessOfARunningProcess() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() })
        // begin() stamps pid = getpid() — this test's own process.
        let run = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .scheduled)

        #expect(store.liveness(ofCurrentRun: progress(runId: run.runId)) == .live)
    }

    @Test("a live process with a fresh heartbeat is live")
    func livenessOfAHeartbeatingProcess() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() }, uptime: { 1_000 })
        let run = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .scheduled)

        #expect(store.liveness(ofCurrentRun: progress(runId: run.runId, heartbeatUptime: 999)) == .live)
    }

    @Test("a live process with a stale heartbeat is stalled")
    func livenessOfAStalledProcess() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let nowUptime = 1_000.0
        let store = RunStore(paths: paths, now: { Date() }, uptime: { nowUptime })
        let run = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .scheduled)
        let stale = nowUptime - RunStore.currentRunHeartbeatStaleAfter - 1

        #expect(store.liveness(ofCurrentRun: progress(runId: run.runId, heartbeatUptime: stale)) == .stalled)
    }

    @Test("exactly five minutes without a heartbeat is still inside the grace bound")
    func heartbeatThresholdIsStrict() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let nowUptime = 1_000.0
        let store = RunStore(paths: paths, now: { Date() }, uptime: { nowUptime })
        let run = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .scheduled)
        let boundary = nowUptime - RunStore.currentRunHeartbeatStaleAfter

        #expect(store.liveness(ofCurrentRun: progress(runId: run.runId, heartbeatUptime: boundary)) == .live)
    }

    @Test("an uptime reset proves a recycled pid did not write this heartbeat")
    func heartbeatFromAPriorBootIsAbandoned() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() }, uptime: { 100 })
        let run = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .scheduled)

        #expect(store.liveness(ofCurrentRun: progress(runId: run.runId, heartbeatUptime: 200)) == .abandoned)
    }

    @Test("a run whose process is gone is abandoned, however recent its progress")
    func livenessOfADeadProcess() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .scheduled)

        var stuck = try store.metadata(runId: run.runId)
        stuck.pid = 999_999
        try writeRawMetadata(stuck, paths: paths)

        // `updatedAt` is deliberately *now* — the whole point of using pid
        // liveness rather than a timestamp heuristic is that a fresh-looking
        // progress file from a dead process is still wreckage, and a very
        // stale one from a live `check --read-data` is still a live run.
        var fresh = progress(runId: run.runId)
        fresh.updatedAt = Date()
        #expect(store.liveness(ofCurrentRun: fresh) == .abandoned)
    }

    /// The counterpart to `livenessOfADeadProcess`, and the reason liveness
    /// is pid-only rather than pid-plus-`metadata.status`.
    ///
    /// A set run finishes each child (moving that child's metadata off
    /// `.running`) long before the set-level `defer` clears `current-run` —
    /// the next child's phase marker rewrites it in between. Treating "the
    /// metadata is finished" as abandonment reported wreckage during a
    /// perfectly normal multi-destination backup, and `status` exited 1 on a
    /// healthy host. Found by `@codex review` on #51.
    @Test("a still-running process's finished child run is live, not wreckage")
    func livenessDuringNormalCompletion() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .scheduled)
        try store.finish(run, status: .success)

        // Metadata is no longer `.running`, but this process — the one that
        // owns the run and will clear the file — is very much alive.
        #expect(store.liveness(ofCurrentRun: progress(runId: run.runId)) == .live)
    }

    @Test("a finished run whose process is gone is still abandoned")
    func livenessOfAFinishedRunWithADeadProcess() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .scheduled)
        try store.finish(run, status: .success)

        var stuck = try store.metadata(runId: run.runId)
        stuck.pid = 999_999
        try writeRawMetadata(stuck, paths: paths)

        #expect(store.liveness(ofCurrentRun: progress(runId: run.runId)) == .abandoned)
    }

    @Test("progress pointing at a run this data directory has no record of is abandoned")
    func livenessOfAnUnknownRun() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() })
        #expect(store.liveness(ofCurrentRun: progress(runId: "20260806T000000Z-backup-deadbeef")) == .abandoned)
    }

    // MARK: - Index corruption tolerance

    @Test func recentRunsSkipsCorruptLinesButReadsOthers() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let store = RunStore(paths: paths, now: { Date() })
        let setId = UUID()
        let destId = UUID()

        let run1 = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .manual)
        try store.finish(run1, status: .success)

        // Simulate a crash mid-append: a garbage / truncated line appended
        // after the good one.
        let handle = try FileHandle(forWritingTo: paths.runsIndexFile)
        try handle.seekToEnd()
        handle.write(Data("{\"runId\":\"garbage\", this is not valid json\n".utf8))
        try handle.close()

        let run2 = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .manual)
        try store.finish(run2, status: .warning)

        let entries = try store.recentRuns(limit: 10)
        #expect(entries.count == 2)
        #expect(entries.map(\.runId).sorted() == [run1.runId, run2.runId].sorted())
    }

    // MARK: - lastRun filtering

    @Test func lastRunFiltersBySetIdAndKindAndReturnsMostRecent() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let tick = TickCounter()
        let store = RunStore(paths: paths, now: {
            Date(timeIntervalSince1970: 3_000_000_000 + Double(tick.next()))
        })

        let setA = UUID()
        let setB = UUID()
        let destId = UUID()

        let a1 = try store.begin(kind: .backup, setId: setA, destId: destId, trigger: .manual)
        try store.finish(a1, status: .success)

        let bBackup = try store.begin(kind: .backup, setId: setB, destId: destId, trigger: .manual)
        try store.finish(bBackup, status: .success)

        let aCheck = try store.begin(kind: .check, setId: setA, destId: destId, trigger: .manual)
        try store.finish(aCheck, status: .success)

        let a2 = try store.begin(kind: .backup, setId: setA, destId: destId, trigger: .manual)
        try store.finish(a2, status: .warning)

        let lastABackup = try store.lastRun(setId: setA, kind: .backup)
        #expect(lastABackup?.runId == a2.runId)
        #expect(lastABackup?.status == .warning)

        let lastACheck = try store.lastRun(setId: setA, kind: .check)
        #expect(lastACheck?.runId == aCheck.runId)

        let lastBCopy = try store.lastRun(setId: setB, kind: .copy)
        #expect(lastBCopy == nil)
    }

    // MARK: - recentRuns(setId:) filters before truncating (T27 issue #29 finding 3)

    /// `runs list --set` must not lose a quiet set's history to a shared,
    /// pre-filter cap — its own history is always in `index.jsonl`
    /// regardless of how many *other* sets' runs are newer.
    /// `RunStore.recentRuns(setId:limit:)` applies the `setId` filter
    /// before `limit` truncates the result; this test would fail under the
    /// old shape (read `limit`-ish raw entries, filter after) because the
    /// quiet set's one run is older than every one of the busy set's.
    @Test func recentRunsFiltersBySetBeforeApplyingTheLimit() throws {
        let paths = makePaths()
        defer { cleanup(paths) }

        let tick = TickCounter()
        let store = RunStore(paths: paths, now: {
            Date(timeIntervalSince1970: 4_000_000_000 + Double(tick.next()))
        })

        let quietSet = UUID()
        let busySet = UUID()
        let destId = UUID()

        // The quiet set's one run happens first — it is the OLDEST entry in
        // the whole index.
        let quiet = try store.begin(kind: .backup, setId: quietSet, destId: destId, trigger: .manual)
        try store.finish(quiet, status: .success)

        // Every run after it, from a different set, is newer.
        for _ in 0..<5 {
            let busy = try store.begin(kind: .backup, setId: busySet, destId: destId, trigger: .manual)
            try store.finish(busy, status: .success)
        }

        // A limit smaller than the busy set's run count: a "truncate first"
        // implementation would read only the newest `limit` raw entries —
        // all from the busy set — and find nothing for the quiet set.
        let quietHistory = try store.recentRuns(setId: quietSet, limit: 2)
        #expect(quietHistory.map(\.runId) == [quiet.runId])

        let busyHistory = try store.recentRuns(setId: busySet, limit: 2)
        #expect(busyHistory.count == 2)
        #expect(busyHistory.allSatisfy { $0.setId == busySet })

        // `setId: nil` (the default) is unaffected — still every kind,
        // every set, newest first, truncated to `limit`.
        let everything = try store.recentRuns(limit: 3)
        #expect(everything.count == 3)
    }

    // MARK: - logURL

    @Test func logURLMatchesAppPaths() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths)
        #expect(store.logURL(runId: "abc") == paths.runLogFile(runId: "abc"))
    }

    // MARK: - helpers

    /// Writes `metadata` directly to its `metadata.json` path, bypassing
    /// `RunStore`'s own atomic-write machinery, purely to simulate an
    /// existing on-disk record (e.g. one left by a process that crashed
    /// with a stale pid) for the crash-recovery test above.
    private func writeRawMetadata(_ metadata: RunMetadata, paths: AppPaths) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        let data = try encoder.encode(metadata)
        try data.write(to: paths.runMetadataFile(runId: metadata.runId))
    }
}
