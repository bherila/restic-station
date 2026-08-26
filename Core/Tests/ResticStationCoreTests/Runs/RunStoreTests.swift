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

private func setRunStoreTestErrno(_ value: Int32) {
    #if canImport(Darwin)
    __error().pointee = value
    #elseif canImport(Glibc)
    __errno_location().pointee = value
    #elseif canImport(Musl)
    __errno_location().pointee = value
    #endif
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

    @Test("a failed initial metadata publication removes its unpublished run directory")
    func failedInitialPublicationRemovesRunDirectory() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let setId = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let runId = RunStore.formatRunId(kind: .prune, setId: setId, date: start)
        let store = RunStore(
            paths: paths,
            now: { start },
            initialPublicationHook: { directory in
                throw RunStoreError.discardUnsafe(path: directory.path)
            }
        )

        #expect(throws: RunStoreError.self) {
            try store.begin(kind: .prune, setId: setId, destId: UUID(), trigger: .manual)
        }
        #expect(!FileManager.default.fileExists(atPath: paths.runDir(runId: runId).path))
        #expect(try store.unresolvedAuditFailures().isEmpty)
    }

    @Test("a failed initial-publication rollback reports an indeterminate directory sync")
    func failedInitialPublicationSurfacesCleanupSyncFailure() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let live = RunStoreFileOperations.live
        let failCleanupSync = Box(false)
        let cleanupSyncCalls = Box(0)
        let operations = RunStoreFileOperations(
            openAt: live.openAt,
            write: live.write,
            sync: { fd in
                guard failCleanupSync.value else { return live.sync(fd) }
                cleanupSyncCalls.value += 1
                setRunStoreTestErrno(EIO)
                return -1
            },
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt
        )
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        let setId = UUID()
        let runId = RunStore.formatRunId(kind: .prune, setId: setId, date: start)
        let store = RunStore(
            paths: paths,
            now: { start },
            initialPublicationHook: { directory in
                failCleanupSync.value = true
                throw RunStoreError.discardUnsafe(path: directory.path)
            },
            fileOperations: operations
        )

        var capturedError: RunStoreError?
        do {
            _ = try store.begin(kind: .prune, setId: setId, destId: UUID(), trigger: .manual)
        } catch let error as RunStoreError {
            capturedError = error
        }
        switch capturedError {
        case .initialPublicationCleanupFailed(_, _, let cleanupError):
            #expect(cleanupError.contains("fsync directory failed"))
        default:
            Issue.record("expected initialPublicationCleanupFailed, got \(String(describing: capturedError))")
        }
        #expect(cleanupSyncCalls.value > 0)
        #expect(!FileManager.default.fileExists(atPath: paths.runDir(runId: runId).path))
    }

    @Test("discarding an unstarted run durably removes its directory")
    func discardUnstartedSyncsRunsDirectory() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let live = RunStoreFileOperations.live
        let syncCalls = Box(0)
        let operations = RunStoreFileOperations(
            openAt: live.openAt,
            write: live.write,
            sync: { fd in
                syncCalls.value += 1
                return live.sync(fd)
            },
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt
        )
        let store = RunStore(
            paths: paths,
            now: { Date() },
            initialPublicationHook: { _ in },
            fileOperations: operations
        )
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        let callsBeforeDiscard = syncCalls.value

        try store.discardUnstarted(run)

        #expect(syncCalls.value > callsBeforeDiscard)
        #expect(!FileManager.default.fileExists(atPath: paths.runDir(runId: run.runId).path))
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

    @Test("begin persists every newly created history-directory ancestor before publication")
    func beginSyncsNewHistoryAncestors() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let live = RunStoreFileOperations.live
        let syncCalls = Box(0)
        let callsBeforePublication = Box(0)
        let operations = RunStoreFileOperations(
            openAt: live.openAt,
            write: live.write,
            sync: { fd in
                syncCalls.value += 1
                return live.sync(fd)
            },
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt
        )
        let store = RunStore(
            paths: paths,
            now: { Date() },
            initialPublicationHook: { _ in
                callsBeforePublication.value = syncCalls.value
            },
            fileOperations: operations
        )

        _ = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .manual)

        // runs/, the data root, and the pre-existing temporary parent are
        // synced bottom-up before the initial metadata hook can run.
        #expect(callsBeforePublication.value >= 3)
    }

    @Test("durable writes retry EINTR and complete every short write")
    func durableWritesCompleteShortWritesAndRetryEINTR() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let live = RunStoreFileOperations.live
        let writeCalls = Box(0)
        let syncCalls = Box(0)
        let operations = RunStoreFileOperations(
            openAt: live.openAt,
            write: { fd, buffer, count in
                writeCalls.value += 1
                if writeCalls.value == 1 {
                    setRunStoreTestErrno(EINTR)
                    return -1
                }
                return live.write(fd, buffer, min(count, 7))
            },
            sync: { fd in
                syncCalls.value += 1
                if syncCalls.value == 1 {
                    setRunStoreTestErrno(EINTR)
                    return -1
                }
                return live.sync(fd)
            },
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt
        )
        let store = RunStore(
            paths: paths,
            now: { Date() },
            initialPublicationHook: { _ in },
            fileOperations: operations
        )

        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)
        try store.finish(run, status: .success, resticExitCode: 0)

        #expect(writeCalls.value > 3)
        #expect(syncCalls.value > 1)
        #expect(try store.metadata(runId: run.runId).status == .success)
        #expect(try store.recentRuns(limit: 10).map(\.runId) == [run.runId])
        #expect(try store.unresolvedAuditFailures().isEmpty)
    }

    @Test("ENOSPC during terminal metadata leaves explicit launched-without-terminal evidence")
    func terminalMetadataENOSPCFailsClosed() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let live = RunStoreFileOperations.live
        let failWrites = Box(false)
        let operations = RunStoreFileOperations(
            openAt: live.openAt,
            write: { fd, buffer, count in
                guard failWrites.value else { return live.write(fd, buffer, count) }
                setRunStoreTestErrno(ENOSPC)
                return -1
            },
            sync: live.sync,
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt
        )
        let store = RunStore(
            paths: paths,
            now: { Date() },
            initialPublicationHook: { _ in },
            fileOperations: operations
        )
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)
        failWrites.value = true

        #expect(throws: RunStoreError.self) {
            try store.finish(run, status: .success, resticExitCode: 0)
        }

        #expect(try store.metadata(runId: run.runId).status == .running)
        #expect(try store.unresolvedAuditFailures().first?.reason == .launchedWithoutTerminalMetadata)
        #expect(!FileManager.default.fileExists(
            atPath: paths.runMetadataFile(runId: run.runId).path + ".tmp"
        ))
    }

    @Test("a read-only metadata directory fault cannot publish terminal success")
    func readOnlyRunDirectoryFailsClosed() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let live = RunStoreFileOperations.live
        let denyMetadataTemp = Box(false)
        let operations = RunStoreFileOperations(
            openAt: { directory, name, flags, mode in
                if denyMetadataTemp.value, name == "metadata.json.tmp" {
                    setRunStoreTestErrno(EACCES)
                    return -1
                }
                return live.openAt(directory, name, flags, mode)
            },
            write: live.write,
            sync: live.sync,
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt
        )
        let store = RunStore(
            paths: paths,
            now: { Date() },
            initialPublicationHook: { _ in },
            fileOperations: operations
        )
        let run = try store.begin(kind: .purge, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)
        denyMetadataTemp.value = true

        #expect(throws: RunStoreError.self) {
            try store.finish(run, status: .success, resticExitCode: 0)
        }
        #expect(try store.unresolvedAuditFailures().first?.reason == .launchedWithoutTerminalMetadata)
        #expect(try store.recentRuns(limit: 10).isEmpty)
    }

    @Test("an interrupted atomic rename preserves the prior canonical launch record")
    func interruptedAtomicMetadataRenameFailsClosed() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let live = RunStoreFileOperations.live
        let interruptRename = Box(false)
        let operations = RunStoreFileOperations(
            openAt: live.openAt,
            write: live.write,
            sync: live.sync,
            renameAt: { oldDirectory, oldName, newDirectory, newName in
                guard interruptRename.value else {
                    return live.renameAt(oldDirectory, oldName, newDirectory, newName)
                }
                setRunStoreTestErrno(EIO)
                return -1
            },
            unlinkAt: live.unlinkAt
        )
        let store = RunStore(
            paths: paths,
            now: { Date() },
            initialPublicationHook: { _ in },
            fileOperations: operations
        )
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)
        interruptRename.value = true

        #expect(throws: RunStoreError.self) {
            try store.finish(run, status: .success, resticExitCode: 0)
        }
        let canonical = try store.metadata(runId: run.runId)
        #expect(canonical.status == .running)
        #expect(canonical.destructiveLaunchAuthorizedAt != nil)
        #expect(try store.unresolvedAuditFailures().first?.reason == .launchedWithoutTerminalMetadata)
    }

    @Test("a failed index fsync leaves a pending marker until recovery confirms the projection")
    func indexSyncFailureLeavesPendingPublication() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let live = RunStoreFileOperations.live
        let failDuringFinish = Box(false)
        let finishSyncCalls = Box(0)
        let operations = RunStoreFileOperations(
            openAt: live.openAt,
            write: live.write,
            sync: { fd in
                guard failDuringFinish.value else { return live.sync(fd) }
                finishSyncCalls.value += 1
                // terminal temp, metadata directory, then index file
                if finishSyncCalls.value == 3 {
                    setRunStoreTestErrno(EIO)
                    return -1
                }
                return live.sync(fd)
            },
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt
        )
        let store = RunStore(
            paths: paths,
            now: { Date() },
            initialPublicationHook: { _ in },
            fileOperations: operations
        )
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)
        failDuringFinish.value = true

        #expect(throws: RunStoreError.self) {
            try store.finish(run, status: .success, resticExitCode: 0)
        }
        let pending = try store.metadata(runId: run.runId)
        #expect(pending.status == .success)
        #expect(pending.indexPublicationPending == true)
        #expect(try store.recentRuns(limit: 10).map(\.runId) == [run.runId])
        #expect(try store.unresolvedAuditFailures().first?.reason == .terminalMetadataMissingIndex)

        #expect(try store.recoverInterrupted().isEmpty)
        #expect(try store.metadata(runId: run.runId).indexPublicationPending == nil)
        #expect(try store.recentRuns(limit: 10).map(\.runId) == [run.runId])
        #expect(try store.unresolvedAuditFailures().isEmpty)
    }

    @Test("recovery appends a missing terminal projection exactly once")
    func recoveryReconcilesTerminalMetadataIdempotently() throws {
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
        try FileManager.default.removeItem(at: paths.runsIndexLockFile)

        #expect(try store.unresolvedAuditFailures().first?.reason == .terminalMetadataMissingIndex)
        #expect(try store.recoverInterrupted().isEmpty)
        #expect(try store.recoverInterrupted().isEmpty)

        let history = try store.recentRuns(limit: 10)
        #expect(history.count == 1)
        #expect(history.first?.runId == run.runId)
        #expect(try store.unresolvedAuditFailures().isEmpty)
    }

    @Test("recovery removes an incomplete index tail before publishing its replacement")
    func recoveryRepairsPartialIndexTail() throws {
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
        try FileManager.default.removeItem(at: paths.runsIndexLockFile)
        try Data("{\"runId\":\"unterminated".utf8).write(to: paths.runsIndexFile)

        #expect(try store.recoverInterrupted().isEmpty)
        #expect(try store.metadata(runId: run.runId).indexPublicationPending == nil)
        #expect(try store.recentRuns(limit: 10).map(\.runId) == [run.runId])
        #expect(try store.unresolvedAuditFailures().isEmpty)
        #expect(try Data(contentsOf: paths.runsIndexFile).last == 0x0A)
    }

    @Test("recovery preserves valid index entries before a torn UTF-8 tail")
    func recoveryPreservesIndexPrefixBeforeTornUTF8() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)
        try store.finish(run, status: .success, resticExitCode: 0)

        var indexBytes = try Data(contentsOf: paths.runsIndexFile)
        indexBytes.append(contentsOf: [0x7B, 0x22, 0x78, 0x22, 0x3A, 0xF0, 0x9F])
        try indexBytes.write(to: paths.runsIndexFile)

        #expect(try store.recoverInterrupted().isEmpty)
        #expect(try store.recentRuns(limit: 10).map(\.runId) == [run.runId])
        #expect(try store.unresolvedAuditFailures().isEmpty)
        let repairedLines = try String(contentsOf: paths.runsIndexFile, encoding: .utf8)
            .split(separator: "\n")
        #expect(repairedLines.count == 1)
    }

    @Test("legacy recovery commits a pending marker before attempting its missing index append")
    func legacyRecoveryMarksPendingBeforeAppend() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let liveStore = RunStore(paths: paths, now: { Date() })
        let run = try liveStore.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .manual)
        try liveStore.finish(run, status: .success, resticExitCode: 0)
        try FileManager.default.removeItem(at: paths.runsIndexFile)

        let live = RunStoreFileOperations.live
        let indexFD = Box<Int32?>(nil)
        let operations = RunStoreFileOperations(
            openAt: { directory, name, flags, mode in
                let fd = live.openAt(directory, name, flags, mode)
                if name == paths.runsIndexFile.lastPathComponent {
                    indexFD.value = fd
                }
                return fd
            },
            write: { fd, buffer, count in
                if fd == indexFD.value {
                    setRunStoreTestErrno(ENOSPC)
                    return -1
                }
                return live.write(fd, buffer, count)
            },
            sync: live.sync,
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt
        )
        let recoveringStore = RunStore(
            paths: paths,
            now: { Date() },
            initialPublicationHook: { _ in },
            fileOperations: operations
        )

        #expect(throws: RunStoreError.self) {
            try recoveringStore.recoverInterrupted()
        }
        #expect(try recoveringStore.metadata(runId: run.runId).indexPublicationPending == true)
    }

    @Test("recovery fsyncs an exact legacy projection before accepting it")
    func legacyMatchingProjectionIsConfirmedDurable() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let liveStore = RunStore(paths: paths, now: { Date() })
        let run = try liveStore.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try liveStore.markDestructiveLaunchAuthorized(run)
        try liveStore.finish(run, status: .success, resticExitCode: 0)
        #expect(try liveStore.metadata(runId: run.runId).indexPublicationPending == nil)

        let live = RunStoreFileOperations.live
        let indexFD = Box<Int32?>(nil)
        let indexSyncCalls = Box(0)
        let operations = RunStoreFileOperations(
            openAt: { directory, name, flags, mode in
                let fd = live.openAt(directory, name, flags, mode)
                if name == paths.runsIndexFile.lastPathComponent {
                    indexFD.value = fd
                }
                return fd
            },
            write: live.write,
            sync: { fd in
                if fd == indexFD.value {
                    indexSyncCalls.value += 1
                }
                return live.sync(fd)
            },
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt
        )
        let recoveringStore = RunStore(
            paths: paths,
            now: { Date() },
            initialPublicationHook: { _ in },
            fileOperations: operations
        )

        #expect(try recoveringStore.recoverInterrupted().isEmpty)
        #expect(indexSyncCalls.value > 0)
        #expect(try recoveringStore.unresolvedAuditFailures().isEmpty)
    }

    @Test("repairing an older projection cannot replace the latest run")
    func repairedHistoryRemainsChronological() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let clock = Box(Date(timeIntervalSince1970: 2_000_000_000))
        let store = RunStore(paths: paths, now: { clock.value })
        let setId = UUID()
        let destId = UUID()

        let older = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .manual)
        try store.finish(older, status: .success, resticExitCode: 0)
        clock.value = clock.value.addingTimeInterval(60)
        let newer = try store.begin(kind: .backup, setId: setId, destId: destId, trigger: .manual)
        try store.finish(newer, status: .failed, resticExitCode: 1)

        let physicalLines = try String(contentsOf: paths.runsIndexFile, encoding: .utf8)
            .split(separator: "\n")
        #expect(physicalLines.count == 2)
        try Data((String(physicalLines[1]) + "\n").utf8).write(to: paths.runsIndexFile)

        #expect(try store.recoverInterrupted().isEmpty)
        let history = try store.recentRuns(setId: setId, limit: 10)
        #expect(history.map(\.runId) == [newer.runId, older.runId])
        #expect(try store.lastRun(setId: setId, kind: .backup)?.runId == newer.runId)
        #expect(try store.lastRun(setId: setId, kind: .backup)?.status == .failed)
    }

    @Test("recovery publishes one corrective projection for stale non-destructive history")
    func recoveryCorrectsNonDestructiveProjection() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.finish(run, status: .success, resticExitCode: 0)

        var rolledBack = try store.metadata(runId: run.runId)
        rolledBack.status = .running
        rolledBack.end = nil
        rolledBack.resticExitCode = nil
        rolledBack.pid = 999_999
        try writeRawMetadata(rolledBack, paths: paths)

        #expect(try store.recoverInterrupted().map(\.runId) == [run.runId])
        #expect(try store.recoverInterrupted().isEmpty)
        let history = try store.recentRuns(limit: 10)
        #expect(history.count == 1)
        #expect(history.first?.runId == run.runId)
        #expect(history.first?.status == .failed)
        #expect(history.first?.errorSummary == "interrupted")
        #expect(try store.lastRun(setId: run.setId, kind: .backup)?.status == .failed)
    }

    @Test("recovery rejects a misplaced embedded run id before rewriting either record")
    func recoveryRejectsRunDirectoryIDMismatch() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let first = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.finish(first, status: .success, resticExitCode: 0)
        let second = try store.begin(kind: .backup, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.finish(second, status: .success, resticExitCode: 0)

        let secondURL = paths.runMetadataFile(runId: second.runId)
        let secondBytes = try Data(contentsOf: secondURL)
        try secondBytes.write(to: paths.runMetadataFile(runId: first.runId))

        #expect(throws: RunStoreError.self) {
            try store.recoverInterrupted()
        }
        #expect(try Data(contentsOf: secondURL) == secondBytes)
        #expect(try store.metadata(runId: second.runId).runId == second.runId)
    }

    @Test("terminal destructive metadata missing from the index is an audit failure")
    func terminalDestructiveMetadataMissingIndex() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        var run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        run.argvRedacted = ["/usr/bin/restic", "forget", "--keep-last", "3"]
        try store.markDestructiveLaunchAuthorized(run)
        #expect(try store.metadata(runId: run.runId).argvRedacted == run.argvRedacted)

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

    @Test("legacy terminal destructive metadata still requires an exact index projection")
    func legacyTerminalDestructiveMetadataMissingIndex() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .purge, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.finish(run, status: .success, resticExitCode: 0)

        var legacy = try store.metadata(runId: run.runId)
        legacy.destructiveAuditContractVersion = nil
        legacy.destructiveLaunchAuthorizedAt = nil
        try writeRawMetadata(legacy, paths: paths)
        try FileManager.default.removeItem(at: paths.runsIndexFile)

        let failure = try #require(store.unresolvedAuditFailures().first)
        #expect(failure.runId == run.runId)
        #expect(failure.reason == .terminalMetadataMissingIndex)
    }

    @Test("a duplicate or divergent index projection remains an audit failure")
    func terminalDestructiveMetadataRequiresExactlyOneMatchingIndex() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)
        try store.finish(run, status: .success, resticExitCode: 0)
        let line = try Data(contentsOf: paths.runsIndexFile)
        let handle = try FileHandle(forWritingTo: paths.runsIndexFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)

        let failure = try #require(store.unresolvedAuditFailures().first)
        #expect(failure.runId == run.runId)
        #expect(failure.reason == .terminalMetadataIndexMismatch)
    }

    @Test("a destructive index projection without canonical metadata is an audit failure")
    func destructiveIndexWithoutCanonicalMetadata() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)
        try store.finish(run, status: .success, resticExitCode: 0)

        try FileManager.default.removeItem(at: paths.runDir(runId: run.runId))

        let failure = try #require(store.unresolvedAuditFailures().first)
        #expect(failure.runId == run.runId)
        #expect(failure.kind == .prune)
        #expect(failure.setId == run.setId)
        #expect(failure.destId == run.destId)
        #expect(failure.reason == .canonicalMetadataMissing)
    }

    @Test("terminal metadata and index publication are atomic to audit verification")
    func terminalPublicationWaitsForAuditPublicationLock() async throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        // One attempt makes a reader time out immediately. Terminal writers
        // deliberately ignore that bounded reader policy and must wait for
        // the finite snapshot instead of losing post-operation evidence.
        let store = RunStore(
            paths: paths,
            now: { Date() },
            initialPublicationHook: { _ in },
            publicationLockMaxAttempts: 1
        )
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)
        let held = FileLock(path: paths.runPublicationLockFile, trustedRoot: paths.root)
        #expect(held.acquire() == .acquired)

        let finishing = Task.detached {
            try store.finish(run, status: .success, resticExitCode: 0)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(try store.metadata(runId: run.runId).status == .running)
        held.release()
        try await finishing.value

        #expect(try store.metadata(runId: run.runId).status == .success)
        #expect(try store.unresolvedAuditFailures().isEmpty)
    }

    @Test("unreadable canonical run metadata makes audit verification fail closed")
    func unreadableCanonicalMetadataFailsAuditVerification() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try paths.ensureDirectories()
        let corruptRun = paths.runsDir.appendingPathComponent("corrupt-run", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptRun, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: corruptRun.appendingPathComponent("metadata.json"))

        #expect(throws: (any Error).self) {
            try RunStore(paths: paths).unresolvedAuditFailures()
        }
    }

    @Test("malformed fields in a known non-destructive run do not block destructive audit verification")
    func malformedNonDestructiveMetadataIsOutsideAuditContract() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try paths.ensureDirectories()
        let legacyRun = paths.runsDir.appendingPathComponent(
            "20260101T000000Z-backup-deadbeef",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacyRun, withIntermediateDirectories: true)
        try Data(#"{"kind":"backup","start":"legacy-date-that-current-code-does-not-decode"}"#.utf8)
            .write(to: legacyRun.appendingPathComponent("metadata.json"))

        #expect(try RunStore(paths: paths).unresolvedAuditFailures().isEmpty)
    }

    @Test("metadata kind must match the kind independently encoded in its run directory")
    func metadataKindMismatchFailsAuditVerification() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        try paths.ensureDirectories()
        let corruptedPrune = paths.runsDir.appendingPathComponent(
            "20260101T000000Z-prune-deadbeef",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: corruptedPrune, withIntermediateDirectories: true)
        try Data(#"{"kind":"backup"}"#.utf8)
            .write(to: corruptedPrune.appendingPathComponent("metadata.json"))

        #expect(throws: RunStoreError.self) {
            try RunStore(paths: paths).unresolvedAuditFailures()
        }
    }

    @Test("destructive metadata is canonical only in its matching run directory")
    func metadataRunIDMismatchFailsAuditVerification() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)
        try store.finish(run, status: .success, resticExitCode: 0)

        let misplaced = paths.runsDir.appendingPathComponent(
            "\(run.runId)-misplaced",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: paths.runDir(runId: run.runId), to: misplaced)

        #expect(throws: RunStoreError.self) {
            try store.unresolvedAuditFailures()
        }
    }

    @Test("the global audit gate, not a reusable PID, proves a destructive run is active")
    func destructiveGateDistinguishesActiveRunFromRecycledPID() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try store.markDestructiveLaunchAuthorized(run)

        let gate = FileLock(path: paths.destructiveAuditLockFile, trustedRoot: paths.root)
        #expect(gate.acquire() == .acquired)
        #expect(try store.unresolvedAuditFailures().isEmpty)
        gate.release()

        let failure = try #require(store.unresolvedAuditFailures().first)
        #expect(failure.runId == run.runId)
        #expect(failure.reason == .launchedWithoutTerminalMetadata)
    }

    @Test("current markerless destructive metadata is affirmative pre-launch evidence")
    func currentMarkerlessDestructiveRunIsSafelyUnstarted() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)

        let metadata = try store.metadata(runId: run.runId)
        #expect(metadata.destructiveAuditContractVersion == RunStore.destructiveAuditContractVersion)
        #expect(metadata.destructiveLaunchAuthorizedAt == nil)
        #expect(try store.unresolvedAuditFailures().isEmpty)
    }

    @Test("markerless pre-contract destructive runs fail closed even while a gate is busy")
    func legacyMarkerlessDestructiveRunFailsClosed() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)

        var legacy = try store.metadata(runId: run.runId)
        legacy.destructiveAuditContractVersion = nil
        #expect(legacy.destructiveLaunchAuthorizedAt == nil)
        try writeRawMetadata(legacy, paths: paths)

        let gate = FileLock(path: paths.destructiveAuditLockFile, trustedRoot: paths.root)
        #expect(gate.acquire() == .acquired)
        defer { gate.release() }

        let failure = try #require(store.unresolvedAuditFailures().first)
        #expect(failure.runId == run.runId)
        #expect(failure.reason == .launchedWithoutTerminalMetadata)
    }

    @Test("recovery preserves a dead markerless pre-contract destructive run as critical")
    func recoverInterruptedLegacyMarkerlessDestructiveRunFailsClosed() throws {
        let paths = makePaths()
        defer { cleanup(paths) }
        let store = RunStore(paths: paths, now: { Date() })
        let run = try store.begin(kind: .purge, setId: UUID(), destId: UUID(), trigger: .manual)

        var legacy = try store.metadata(runId: run.runId)
        legacy.destructiveAuditContractVersion = nil
        legacy.pid = 999_999
        try writeRawMetadata(legacy, paths: paths)

        _ = try store.recoverInterrupted()
        let recovered = try store.metadata(runId: run.runId)
        #expect(recovered.status == .failed)
        #expect(recovered.auditFailureReason == .launchedWithoutTerminalMetadata)
        #expect(recovered.errorSummary?.contains("operation_completed_audit_failed") == true)
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
