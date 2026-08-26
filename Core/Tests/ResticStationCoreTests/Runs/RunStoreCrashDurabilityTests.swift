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

/// Crash-durability fault-injection tests for `RunStore` (and the
/// `StateStore` atomic-write convention), driven through
/// `FaultInjectingFileOperations` — see `docs/testing.md` §RunStore fault
/// injection.
///
/// The ordering contracts under test (docs/data-model.md §runs/index.jsonl,
/// §runs/<runId>/metadata.json):
///
/// 1. `begin`: newly created history ancestors and `runs/` are fsynced
///    bottom-up, then `metadata.json` is written via temp → fsync(file) →
///    `renameat` → fsync(run dir), and the new directory entry is made
///    durable in `runs/` before `begin` returns.
/// 2. `finish`: a durable two-phase transaction — terminal metadata with
///    `indexPublicationPending: true` commits first (same atomic cycle),
///    the index line is appended and fsynced (file, then directory) under
///    `index.jsonl.lock`, and only then is the marker cleared.
/// 3. `markDestructiveLaunchAuthorized`: the launch marker commits through
///    the same atomic cycle before any destructive argv may run.
/// 4. `recoverInterrupted`: repairs a torn index tail and fsyncs the
///    snapshot before decoding it, republishes with marker-before-append,
///    and is idempotent.
///
/// Each crash matrix simulates dying at EVERY seam-operation boundary of a
/// flow, then "remounts" (fresh live `RunStore` over the same directory,
/// with the dead process's pid marked unreachable where the on-disk record
/// still claims `.running`) and asserts the recovered view is consistent:
/// no acknowledged record lost, no phantom or divergent projection, no
/// stuck pending marker, recovery idempotent.
@Suite struct RunStoreCrashDurabilityTests {
    private static let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private static let destId = UUID(uuidString: "0B36BB67-4E34-4A34-9A9E-3B2C1D0E4F55")!
    private static let start = Date(timeIntervalSince1970: 1_755_000_000)

    private func makePaths() -> AppPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-crash-durability-\(UUID().uuidString)")
        return AppPaths(root: root)
    }

    private func cleanup(_ paths: AppPaths) {
        try? FileManager.default.removeItem(at: paths.root)
    }

    private func makeCrashStore(
        paths: AppPaths,
        crashAfter operations: Int
    ) -> (RunStore, FaultInjectingFileOperations) {
        let faults = FaultInjectingFileOperations()
        faults.crashAfter(operations: operations)
        let store = RunStore(
            paths: paths,
            now: { Self.start },
            initialPublicationHook: { _ in },
            fileOperations: faults.operations
        )
        return (store, faults)
    }

    /// The dead process's `.running` record still carries the test's own
    /// live pid. A remount happens after that process is gone; make the
    /// on-disk evidence agree before running recovery.
    private func markRecordedProcessDead(runId: String, paths: AppPaths) throws {
        let store = RunStore(paths: paths)
        guard var metadata = try? store.metadata(runId: runId), metadata.status == .running else {
            return
        }
        metadata.pid = 999_999
        try writeRaw(metadata, paths: paths)
    }

    /// Asserts the invariant shared by every crash point once recovery has
    /// run: a terminal canonical record, no pending marker, exactly one
    /// logical projection agreeing with it, and idempotent recovery.
    private func assertRecoveredHistoryIsConsistent(
        paths: AppPaths,
        runId: String,
        crashPoint: Int
    ) throws {
        let store = RunStore(paths: paths)
        let final = try store.metadata(runId: runId)
        #expect(
            final.status != .running,
            "metadata still .running after recovery at crash point \(crashPoint)"
        )
        #expect(
            final.indexPublicationPending == nil,
            "pending marker survived recovery at crash point \(crashPoint)"
        )
        let history = try store.recentRuns(limit: 10)
        #expect(
            history.map(\.runId) == [runId],
            "phantom or lost record at crash point \(crashPoint): \(history.map(\.runId))"
        )
        #expect(history.first?.status == final.status)

        let indexBytes = try Data(contentsOf: paths.runsIndexFile)
        let metadataBytes = try Data(contentsOf: paths.runMetadataFile(runId: runId))
        #expect(try store.recoverInterrupted().isEmpty)
        #expect(
            try Data(contentsOf: paths.runsIndexFile) == indexBytes,
            "second recovery rewrote the index at crash point \(crashPoint)"
        )
        #expect(try Data(contentsOf: paths.runMetadataFile(runId: runId)) == metadataBytes)
    }

    // MARK: - Contract 2: finish (non-destructive)

    /// The largest argument doubles as the coverage check: the flow must
    /// complete without reaching the crash point there, proving the range
    /// still spans every step boundary.
    @Test(
        "a backup finish crashed at every step boundary recovers to a consistent history",
        arguments: 0...24
    )
    func finishBackupCrashAtEveryStep(crashPoint: Int) throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let liveStore = RunStore(paths: paths, now: { Self.start })
        var run = try liveStore.begin(
            kind: .backup, setId: Self.setId, destId: Self.destId, trigger: .manual
        )
        run.argvRedacted = ["restic", "backup", "/src", "--json"]

        let (crashStore, faults) = makeCrashStore(paths: paths, crashAfter: crashPoint)
        try? crashStore.finish(run, status: .success, resticExitCode: 0)
        if crashPoint == 24 {
            #expect(!faults.didCrash, "raise the crash-point upper bound: finish grew past it")
        }
        let acknowledged = !faults.didCrash

        try markRecordedProcessDead(runId: run.runId, paths: paths)
        let recoveryStore = RunStore(paths: paths)
        _ = try recoveryStore.recoverInterrupted()

        let final = try recoveryStore.metadata(runId: run.runId)
        if acknowledged {
            #expect(final.status == .success, "acknowledged finish lost at crash point \(crashPoint)")
        } else {
            #expect(final.status == .success || final.status == .failed)
        }
        #expect(try recoveryStore.unresolvedAuditFailures().isEmpty)
        try assertRecoveredHistoryIsConsistent(paths: paths, runId: run.runId, crashPoint: crashPoint)
    }

    // MARK: - Contract 2 + destructive audit: finish (destructive)

    @Test(
        "a destructive finish crashed at every step boundary either publishes exactly once or fails closed",
        arguments: 0...24
    )
    func finishDestructiveCrashAtEveryStep(crashPoint: Int) throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let liveStore = RunStore(paths: paths, now: { Self.start })
        var run = try liveStore.begin(
            kind: .prune, setId: Self.setId, destId: Self.destId, trigger: .manual
        )
        run.argvRedacted = ["restic", "forget", "--keep-last", "3", "--prune"]
        try liveStore.markDestructiveLaunchAuthorized(run)

        let (crashStore, faults) = makeCrashStore(paths: paths, crashAfter: crashPoint)
        try? crashStore.finish(run, status: .success, resticExitCode: 0)
        if crashPoint == 24 {
            #expect(!faults.didCrash, "raise the crash-point upper bound: finish grew past it")
        }
        let terminalLanded = try liveStore.metadata(runId: run.runId).status == .success

        try markRecordedProcessDead(runId: run.runId, paths: paths)
        let recoveryStore = RunStore(paths: paths)
        _ = try recoveryStore.recoverInterrupted()

        let final = try recoveryStore.metadata(runId: run.runId)
        let failures = try recoveryStore.unresolvedAuditFailures()
        if terminalLanded {
            // The repository outcome was recorded before the crash; recovery
            // must complete the projection and verification must go green.
            #expect(final.status == .success)
            #expect(failures.isEmpty, "crash point \(crashPoint): \(failures)")
        } else {
            // The process died after launch authorization with no terminal
            // record: an unknown repository outcome must stay an explicit,
            // unresolved audit failure — never a quiet success.
            #expect(final.status == .failed)
            #expect(final.auditFailureReason == .launchedWithoutTerminalMetadata)
            #expect(final.errorSummary?.contains("operation_completed_audit_failed") == true)
            #expect(failures.map(\.reason) == [.launchedWithoutTerminalMetadata])
            #expect(failures.first?.runId == run.runId)
        }
        // Whatever else, the derived index must never diverge from or
        // duplicate the canonical destructive record.
        #expect(!failures.contains { $0.reason == .terminalMetadataIndexMismatch })
        #expect(!failures.contains { $0.reason == .canonicalMetadataMissing })
        try assertRecoveredHistoryIsConsistent(paths: paths, runId: run.runId, crashPoint: crashPoint)
    }

    // MARK: - Contract 1: begin

    @Test(
        "a begin crashed at every step boundary leaves no phantom history and recovers or fails closed",
        arguments: 0...16
    )
    func beginCrashAtEveryStep(crashPoint: Int) throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let (crashStore, faults) = makeCrashStore(paths: paths, crashAfter: crashPoint)
        _ = try? crashStore.begin(
            kind: .backup, setId: Self.setId, destId: Self.destId, trigger: .manual
        )
        if crashPoint == 16 {
            #expect(!faults.didCrash, "raise the crash-point upper bound: begin grew past it")
        }
        let runId = RunStore.formatRunId(kind: .backup, setId: Self.setId, date: Self.start)

        try markRecordedProcessDead(runId: runId, paths: paths)
        let recoveryStore = RunStore(paths: paths)
        _ = try recoveryStore.recoverInterrupted()

        if (try? recoveryStore.metadata(runId: runId)) != nil {
            // The initial commit reached the disk: the dead run must be
            // reported as failed/interrupted history, exactly once.
            let final = try recoveryStore.metadata(runId: runId)
            #expect(final.status == .failed)
            #expect(final.errorSummary == "interrupted")
            #expect(try recoveryStore.unresolvedAuditFailures().isEmpty)
            try assertRecoveredHistoryIsConsistent(paths: paths, runId: runId, crashPoint: crashPoint)
        } else {
            // The crash fell in the mkdir → first-metadata-commit window:
            // an orphan run directory with no readable canonical record.
            // History stays consistent (nothing was acknowledged, nothing
            // is projected), recovery skips it, and destructive audit
            // verification fails closed by refusing to read the unreadable
            // canonical evidence (docs/data-model.md; there is currently no
            // automated cleanup for this wreckage — deliberate posture).
            #expect(FileManager.default.fileExists(atPath: paths.runDir(runId: runId).path))
            #expect(try recoveryStore.recentRuns(limit: 10).isEmpty)
            #expect(try recoveryStore.recoverInterrupted().isEmpty)
            #expect(throws: (any Error).self) {
                try recoveryStore.unresolvedAuditFailures()
            }
        }
    }

    // MARK: - Contract 3: markDestructiveLaunchAuthorized

    @Test(
        "a launch-marker write crashed at every step boundary is either fully durable or provably unstarted",
        arguments: 0...10
    )
    func launchMarkerCrashAtEveryStep(crashPoint: Int) throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let liveStore = RunStore(paths: paths, now: { Self.start })
        var run = try liveStore.begin(
            kind: .prune, setId: Self.setId, destId: Self.destId, trigger: .manual
        )
        run.argvRedacted = ["restic", "forget", "--keep-last", "3"]

        let (crashStore, faults) = makeCrashStore(paths: paths, crashAfter: crashPoint)
        try? crashStore.markDestructiveLaunchAuthorized(run)
        if crashPoint == 10 {
            #expect(!faults.didCrash, "raise the crash-point upper bound: the marker write grew past it")
        }
        let markerLanded = try liveStore.metadata(runId: run.runId).destructiveLaunchAuthorizedAt != nil

        try markRecordedProcessDead(runId: run.runId, paths: paths)
        let recoveryStore = RunStore(paths: paths)
        _ = try recoveryStore.recoverInterrupted()

        let final = try recoveryStore.metadata(runId: run.runId)
        #expect(final.status == .failed)
        let failures = try recoveryStore.unresolvedAuditFailures()
        if markerLanded {
            // The marker may have preceded an actual launch: unknown
            // repository outcome, so recovery must fail closed.
            #expect(final.auditFailureReason == .launchedWithoutTerminalMetadata)
            #expect(failures.map(\.reason) == [.launchedWithoutTerminalMetadata])
        } else {
            // No durable marker under the current contract is affirmative
            // evidence the destructive argv never ran: plain interruption.
            #expect(final.errorSummary == "interrupted")
            #expect(failures.isEmpty)
        }
        try assertRecoveredHistoryIsConsistent(paths: paths, runId: run.runId, crashPoint: crashPoint)
    }

    // MARK: - Contract 4: recovery itself crashing

    @Test(
        "recovery of a dead running record crashed at every step boundary completes on the next attempt",
        arguments: 0...24
    )
    func recoveryOfDeadRunCrashAtEveryStep(crashPoint: Int) throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let liveStore = RunStore(paths: paths, now: { Self.start })
        let run = try liveStore.begin(
            kind: .backup, setId: Self.setId, destId: Self.destId, trigger: .manual
        )
        var stuck = try liveStore.metadata(runId: run.runId)
        stuck.pid = 999_999
        try writeRaw(stuck, paths: paths)

        let (crashStore, faults) = makeCrashStore(paths: paths, crashAfter: crashPoint)
        _ = try? crashStore.recoverInterrupted()
        if crashPoint == 24 {
            #expect(!faults.didCrash, "raise the crash-point upper bound: recovery grew past it")
        }

        let recoveryStore = RunStore(paths: paths)
        _ = try recoveryStore.recoverInterrupted()

        let final = try recoveryStore.metadata(runId: run.runId)
        #expect(final.status == .failed)
        #expect(final.errorSummary == "interrupted")
        #expect(try recoveryStore.unresolvedAuditFailures().isEmpty)
        try assertRecoveredHistoryIsConsistent(paths: paths, runId: run.runId, crashPoint: crashPoint)
    }

    @Test(
        "recovery of a pending destructive publication crashed at every step boundary still converges",
        arguments: 0...16
    )
    func recoveryOfPendingPublicationCrashAtEveryStep(crashPoint: Int) throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let run = try makePendingDestructivePublication(paths: paths)

        let (crashStore, faults) = makeCrashStore(paths: paths, crashAfter: crashPoint)
        _ = try? crashStore.recoverInterrupted()
        if crashPoint == 16 {
            #expect(!faults.didCrash, "raise the crash-point upper bound: recovery grew past it")
        }

        let recoveryStore = RunStore(paths: paths)
        _ = try recoveryStore.recoverInterrupted()

        let final = try recoveryStore.metadata(runId: run.runId)
        #expect(final.status == .success)
        #expect(try recoveryStore.unresolvedAuditFailures().isEmpty)
        try assertRecoveredHistoryIsConsistent(paths: paths, runId: run.runId, crashPoint: crashPoint)
    }

    // MARK: - Torn index appends

    /// Tears the physical index append of a second run at (nearly) every
    /// byte offset — including inside the multibyte UTF-8 scalars its
    /// `errorSummary` deliberately contains — then crashes and remounts.
    /// Recovery must truncate the torn fragment without harming the valid
    /// first record, republish the second run's projection, and leave a
    /// newline-terminated index.
    ///
    /// One internal loop rather than `@Test(arguments:)`: the line length
    /// (and so the offset range) is only known from the flow itself.
    @Test func tornIndexAppendIsRepairedAtEveryOffset() throws {
        let summary = "café 🚀 données — enregistrement déchiré"

        func runFlow(paths: AppPaths, tearAt offset: Int?) throws -> (first: String, second: String) {
            let tick = TickBox()
            let store = RunStore(paths: paths, now: {
                Self.start.addingTimeInterval(TimeInterval(tick.next()))
            })
            let first = try store.begin(
                kind: .backup, setId: Self.setId, destId: Self.destId, trigger: .manual
            )
            try store.finish(first, status: .success, resticExitCode: 0)
            let second = try store.begin(
                kind: .backup, setId: Self.setId, destId: Self.destId, trigger: .manual
            )
            if let offset {
                let faults = FaultInjectingFileOperations()
                faults.tearWrite(toFileNamed: "index.jsonl", keepingBytes: offset)
                let crashStore = RunStore(
                    paths: paths,
                    now: { Self.start.addingTimeInterval(TimeInterval(tick.next())) },
                    initialPublicationHook: { _ in },
                    fileOperations: faults.operations
                )
                try? crashStore.finish(
                    second, status: .failed, errorSummary: summary, resticExitCode: 1
                )
                #expect(faults.didCrash, "the tear at offset \(offset) never engaged")
            } else {
                try store.finish(second, status: .failed, errorSummary: summary, resticExitCode: 1)
            }
            return (first.runId, second.runId)
        }

        // Measure the exact appended line once, with no faults.
        let measured = makePaths()
        let lineLength: Int
        do {
            defer { cleanup(measured) }
            _ = try runFlow(paths: measured, tearAt: nil)
            let lines = try Data(contentsOf: measured.runsIndexFile)
                .split(separator: 0x0A, omittingEmptySubsequences: true)
            try #require(lines.count == 2)
            lineLength = lines[1].count + 1 // + trailing newline
        }

        // `lineLength - 1` keeps the whole JSON record and tears only the
        // newline — the complete-newline-less repair path also pinned by
        // `recoveryTerminatesNewlinelessTailAtTheEnd`. Every other offset
        // leaves a strict, undecodable prefix for truncation.
        var offsets = Array(stride(from: 1, to: lineLength, by: 3))
        if !offsets.contains(lineLength - 1) { offsets.append(lineLength - 1) }
        for offset in offsets {
            let paths = makePaths()
            defer { cleanup(paths) }
            let (firstRunId, secondRunId) = try runFlow(paths: paths, tearAt: offset)

            let recoveryStore = RunStore(paths: paths)
            _ = try recoveryStore.recoverInterrupted()

            let indexBytes = try Data(contentsOf: paths.runsIndexFile)
            #expect(indexBytes.last == 0x0A, "offset \(offset): index not newline-terminated")
            let lines = indexBytes.split(separator: 0x0A, omittingEmptySubsequences: true)
            #expect(lines.count == 2, "offset \(offset): expected 2 physical lines, got \(lines.count)")

            let history = try recoveryStore.recentRuns(limit: 10)
            #expect(
                history.map(\.runId) == [secondRunId, firstRunId],
                "offset \(offset): lost or phantom record: \(history.map(\.runId))"
            )
            #expect(history.first?.status == .failed)
            #expect(history.first?.errorSummary == summary, "offset \(offset): summary damaged")
            #expect(history.last?.status == .success)
            #expect(try recoveryStore.metadata(runId: secondRunId).indexPublicationPending == nil)
            #expect(try recoveryStore.unresolvedAuditFailures().isEmpty)
            #expect(try recoveryStore.recoverInterrupted().isEmpty, "offset \(offset): not idempotent")
        }
    }

    /// A write torn one byte short of the end leaves a complete JSON record
    /// with no trailing newline. Recovery must terminate that record *at
    /// the end of the file* — before the `O_APPEND` fix in
    /// `readIndexEntriesRepairingTail`, the terminating newline was written
    /// through a descriptor whose offset was still 0 (the repair reads only
    /// with `pread`), overwriting the first byte of `index.jsonl`:
    /// destroying the oldest record while leaving the tail unterminated.
    /// (The same repair through `appendIndexEntry` was safe all along: its
    /// descriptor carries `O_APPEND`.)
    @Test("recovery terminates a complete newline-less index tail at the end, not at byte 0")
    func recoveryTerminatesNewlinelessTailAtTheEnd() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let tick = TickBox()
        let store = RunStore(paths: paths, now: {
            Self.start.addingTimeInterval(TimeInterval(tick.next()))
        })
        let first = try store.begin(
            kind: .backup, setId: Self.setId, destId: Self.destId, trigger: .manual
        )
        try store.finish(first, status: .success, resticExitCode: 0)
        let second = try store.begin(
            kind: .backup, setId: Self.setId, destId: Self.destId, trigger: .manual
        )
        try store.finish(second, status: .success, resticExitCode: 0)

        var indexBytes = try Data(contentsOf: paths.runsIndexFile)
        try #require(indexBytes.last == 0x0A)
        indexBytes.removeLast()
        try indexBytes.write(to: paths.runsIndexFile)

        #expect(try store.recoverInterrupted().isEmpty)

        let repaired = try Data(contentsOf: paths.runsIndexFile)
        #expect(repaired.first == UInt8(ascii: "{"), "recovery overwrote the head of the index")
        #expect(repaired.last == 0x0A, "the newline-less tail was never terminated")
        #expect(repaired.split(separator: 0x0A, omittingEmptySubsequences: true).count == 2)
        let history = try store.recentRuns(limit: 10)
        #expect(history.map(\.runId) == [second.runId, first.runId])
        #expect(try store.unresolvedAuditFailures().isEmpty)
        #expect(try store.recoverInterrupted().isEmpty)
        #expect(try Data(contentsOf: paths.runsIndexFile) == repaired)
    }

    // MARK: - EINTR at every fsync site

    @Test func everyFsyncSiteInThePublicationFlowRetriesEINTR() throws {
        func runFlow(_ faults: FaultInjectingFileOperations, paths: AppPaths) throws {
            let store = RunStore(
                paths: paths,
                now: { Self.start },
                initialPublicationHook: { _ in },
                fileOperations: faults.operations
            )
            var run = try store.begin(
                kind: .prune, setId: Self.setId, destId: Self.destId, trigger: .manual
            )
            run.argvRedacted = ["restic", "forget", "--keep-last", "3"]
            try store.markDestructiveLaunchAuthorized(run)
            try store.finish(run, status: .success, resticExitCode: 0)
            #expect(try store.metadata(runId: run.runId).indexPublicationPending == nil)
            #expect(try store.recentRuns(limit: 5).map(\.runId) == [run.runId])
            #expect(try store.unresolvedAuditFailures().isEmpty)
        }

        let totalSyncCalls: Int
        do {
            let paths = makePaths()
            defer { cleanup(paths) }
            let counting = FaultInjectingFileOperations()
            try runFlow(counting, paths: paths)
            totalSyncCalls = counting.syncCallCount
        }
        try #require(totalSyncCalls >= 8, "expected the flow to fsync at several sites")

        for call in 1...totalSyncCalls {
            let paths = makePaths()
            defer { cleanup(paths) }
            let faults = FaultInjectingFileOperations()
            faults.failSync(atCall: call, errno: EINTR)
            do {
                try runFlow(faults, paths: paths)
            } catch {
                Issue.record("EINTR at fsync call \(call) was treated as fatal: \(error)")
            }
            #expect(faults.syncCallCount > call, "fsync call \(call) was not retried")
        }
    }

    @Test func everyFsyncSiteInRecoveryRetriesEINTR() throws {
        func recover(_ faults: FaultInjectingFileOperations, paths: AppPaths, runId: String) throws {
            let store = RunStore(
                paths: paths,
                now: { Self.start },
                initialPublicationHook: { _ in },
                fileOperations: faults.operations
            )
            _ = try store.recoverInterrupted()
            #expect(try store.metadata(runId: runId).indexPublicationPending == nil)
            #expect(try store.unresolvedAuditFailures().isEmpty)
        }

        let totalSyncCalls: Int
        do {
            let paths = makePaths()
            defer { cleanup(paths) }
            let run = try makePendingDestructivePublication(paths: paths)
            let counting = FaultInjectingFileOperations()
            try recover(counting, paths: paths, runId: run.runId)
            totalSyncCalls = counting.syncCallCount
        }
        try #require(totalSyncCalls >= 4, "expected recovery to fsync at several sites")

        for call in 1...totalSyncCalls {
            let paths = makePaths()
            defer { cleanup(paths) }
            let run = try makePendingDestructivePublication(paths: paths)
            let faults = FaultInjectingFileOperations()
            faults.failSync(atCall: call, errno: EINTR)
            do {
                try recover(faults, paths: paths, runId: run.runId)
            } catch {
                Issue.record("EINTR at recovery fsync call \(call) was treated as fatal: \(error)")
            }
            #expect(faults.syncCallCount > call, "recovery fsync call \(call) was not retried")
        }
    }

    // MARK: - Ordering traces

    @Test("finish orders marker, append, and clear per the two-phase contract")
    func finishTraceOrdersTwoPhasePublication() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let liveStore = RunStore(paths: paths, now: { Self.start })
        let run = try liveStore.begin(
            kind: .backup, setId: Self.setId, destId: Self.destId, trigger: .manual
        )

        let faults = FaultInjectingFileOperations()
        let store = RunStore(
            paths: paths,
            now: { Self.start },
            initialPublicationHook: { _ in },
            fileOperations: faults.operations
        )
        try store.finish(run, status: .success, resticExitCode: 0)

        let trace = faults.trace
        let tempWrites = indices(of: trace) { $0 == .write(.file("metadata.json.tmp")) }
        let tempSyncs = indices(of: trace) { $0 == .sync(.file("metadata.json.tmp")) }
        let metadataRenames = indices(of: trace) {
            if case .rename(_, let to) = $0 { return to == "metadata.json" }
            return false
        }
        let indexWrites = indices(of: trace) { $0 == .write(.file("index.jsonl")) }
        let indexSyncs = indices(of: trace) { $0 == .sync(.file("index.jsonl")) }
        let directorySyncs = indices(of: trace) { $0 == .sync(.directory) }

        try #require(tempWrites.count == 2, "expected exactly two metadata rewrites, got \(trace)")
        try #require(tempSyncs.count == 2)
        try #require(metadataRenames.count == 2)
        try #require(indexWrites.count == 1)
        try #require(indexSyncs.count >= 1)

        // Phase 1 — terminal metadata (pending marker set): fully written
        // and fsynced before the rename, directory entry fsynced after.
        #expect(tempWrites[0] < tempSyncs[0])
        #expect(tempSyncs[0] < metadataRenames[0])
        #expect(directorySyncs.contains { $0 > metadataRenames[0] && $0 < indexWrites[0] })

        // The marker commits strictly before the append it guards.
        #expect(metadataRenames[0] < indexWrites[0])

        // Phase 2 — the index line, then its file and directory fsyncs.
        #expect(indexWrites[0] < indexSyncs[0])
        #expect(directorySyncs.contains { $0 > indexSyncs[0] && $0 < tempWrites[1] })

        // Phase 3 — the marker is cleared only after the projection is
        // durable, through the same atomic cycle.
        #expect(indexSyncs[0] < tempWrites[1])
        #expect(tempWrites[1] < tempSyncs[1])
        #expect(tempSyncs[1] < metadataRenames[1])
        #expect(directorySyncs.contains { $0 > metadataRenames[1] })
    }

    @Test("begin syncs the history hierarchy before publication and the new entry after it")
    func beginTraceOrdersHierarchyDurability() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let faults = FaultInjectingFileOperations()
        let store = RunStore(
            paths: paths,
            now: { Self.start },
            initialPublicationHook: { _ in },
            fileOperations: faults.operations
        )
        _ = try store.begin(kind: .backup, setId: Self.setId, destId: Self.destId, trigger: .manual)

        let trace = faults.trace
        let firstTempOpen = try #require(
            indices(of: trace) { $0 == .openAt("metadata.json.tmp") }.first
        )
        let tempWrites = indices(of: trace) { $0 == .write(.file("metadata.json.tmp")) }
        let tempSyncs = indices(of: trace) { $0 == .sync(.file("metadata.json.tmp")) }
        let metadataRenames = indices(of: trace) {
            if case .rename(_, let to) = $0 { return to == "metadata.json" }
            return false
        }
        let directorySyncs = indices(of: trace) { $0 == .sync(.directory) }

        // runs/, the data root, and its first existing ancestor are all
        // confirmed durable before the initial record is even opened.
        #expect(directorySyncs.filter { $0 < firstTempOpen }.count >= 3)

        try #require(tempWrites.count == 1 && tempSyncs.count == 1 && metadataRenames.count == 1)
        #expect(tempWrites[0] < tempSyncs[0])
        #expect(tempSyncs[0] < metadataRenames[0])
        // After the rename: the run directory's own fsync, then the new
        // directory entry made durable in runs/ before begin returns.
        #expect(directorySyncs.filter { $0 > metadataRenames[0] }.count >= 2)
    }

    // MARK: - StateStore atomic-write convention

    /// `state/` files promise atomic replacement (temp + rename), not
    /// fsync durability — they are regenerable caches, with schedule
    /// state's corruption handling covered by its own fail-closed tests.
    /// A temp file abandoned by a crashed writer must neither block the
    /// next write nor ever be visible to readers.
    @Test func scheduleStateAtomicWriteSurvivesAStaleCrashTemp() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try paths.ensureDirectories()
        let temp = paths.scheduleStateFile.deletingLastPathComponent()
            .appendingPathComponent(
                paths.scheduleStateFile.lastPathComponent + ".tmp", isDirectory: false
            )
        try Data("{\"sets\":{\"torn".utf8).write(to: temp)

        let store = StateStore(paths: paths)
        let setId = UUID()
        try store.updateScheduleState(setId: setId) { $0.checkCount = 7 }
        #expect(store.readScheduleStateResult().state?.sets[setId]?.checkCount == 7)

        // A fresh torn temp (a writer dying right now) is invisible to the
        // read path, which only ever opens the canonical file.
        try Data("{\"sets\":{\"torn again".utf8).write(to: temp)
        #expect(store.readScheduleStateResult().state?.sets[setId]?.checkCount == 7)
    }

    // MARK: - Helpers

    /// A terminal destructive record whose index projection never happened:
    /// `metadata.json` says `.success` with `indexPublicationPending: true`
    /// and `index.jsonl` does not exist — exactly what a crash (or the
    /// surfaced lock failure used to produce it here) leaves behind between
    /// the two phases of `finish`.
    private func makePendingDestructivePublication(paths: AppPaths) throws -> ActiveRun {
        let store = RunStore(paths: paths, now: { Self.start })
        var run = try store.begin(
            kind: .prune, setId: Self.setId, destId: Self.destId, trigger: .manual
        )
        run.argvRedacted = ["restic", "forget", "--keep-last", "3"]
        try store.markDestructiveLaunchAuthorized(run)
        try FileManager.default.createDirectory(
            at: paths.runsIndexLockFile, withIntermediateDirectories: true
        )
        do {
            try store.finish(run, status: .success, resticExitCode: 0)
            Issue.record("finish unexpectedly succeeded with an unusable index lock")
        } catch {}
        try FileManager.default.removeItem(at: paths.runsIndexLockFile)

        let metadata = try store.metadata(runId: run.runId)
        try #require(metadata.status == .success && metadata.indexPublicationPending == true)
        return run
    }

    private func indices(
        of trace: [FaultInjectingFileOperations.Operation],
        where predicate: (FaultInjectingFileOperations.Operation) -> Bool
    ) -> [Int] {
        trace.enumerated().compactMap { predicate($0.element) ? $0.offset : nil }
    }

    /// Writes `metadata` directly, bypassing the store's atomic-write
    /// machinery, purely to adjust an existing on-disk record (same
    /// convention as `RunStoreTests.writeRawMetadata`).
    private func writeRaw(_ metadata: RunMetadata, paths: AppPaths) throws {
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

/// Single-threaded monotonic tick for deterministic, distinct run starts.
private final class TickBox: @unchecked Sendable {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
