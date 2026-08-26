import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A run that has been started (`RunStore.begin(...)`) but not yet finished.
/// Value type — the caller holds it, optionally fills in `argvRedacted`
/// once the restic command line is known, and passes it back to
/// `RunStore.finish(_:...)`.
public struct ActiveRun: Equatable, Sendable {
    public let runId: String
    public let kind: RunKind
    public let setId: UUID
    public let destId: UUID
    public let trigger: RunTrigger
    public let groupId: String
    public let start: Date
    public let pid: Int32
    /// argv actually executed (no env, no secrets). Empty until the caller
    /// sets it — `RunStore.begin(...)` doesn't know the restic command
    /// line yet, only `finish(_:...)` needs the final value.
    public var argvRedacted: [String]
}

/// The one field audit verification may inspect without trusting the rest of
/// a metadata record. Historical non-destructive fixtures and records are not
/// part of the destructive contract; once their kind is known, malformed
/// unrelated fields must not prevent status from verifying destructive runs.
private struct RunAuditDiscriminator: Decodable {
    let kind: RunKind
}

/// Narrow POSIX seam for deterministic durability fault injection. Production
/// uses the real syscalls; tests can force short writes, `EINTR`, `ENOSPC`,
/// permission failures, or an interrupted rename without changing paths or
/// relying on the uid running the test suite.
struct RunStoreFileOperations: @unchecked Sendable {
    let openAt: @Sendable (Int32, String, Int32, mode_t) -> Int32
    let write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    let sync: @Sendable (Int32) -> Int32
    let renameAt: @Sendable (Int32, String, Int32, String) -> Int32
    let unlinkAt: @Sendable (Int32, String) -> Int32

    static let live = RunStoreFileOperations(
        openAt: { directory, name, flags, mode in
            name.withCString { openat(directory, $0, flags, mode) }
        },
        write: { fd, buffer, count in
            #if canImport(Darwin)
            Darwin.write(fd, buffer, count)
            #elseif canImport(Glibc)
            Glibc.write(fd, buffer, count)
            #elseif canImport(Musl)
            Musl.write(fd, buffer, count)
            #endif
        },
        sync: { fd in
            #if canImport(Darwin)
            Darwin.fsync(fd)
            #elseif canImport(Glibc)
            Glibc.fsync(fd)
            #elseif canImport(Musl)
            Musl.fsync(fd)
            #endif
        },
        renameAt: { oldDirectory, oldName, newDirectory, newName in
            oldName.withCString { oldNamePointer in
                newName.withCString { newNamePointer in
                    renameat(oldDirectory, oldNamePointer, newDirectory, newNamePointer)
                }
            }
        },
        unlinkAt: { directory, name in
            name.withCString { unlinkat(directory, $0, 0) }
        }
    )
}

/// One run `recoverInterrupted()` rewrote from `.running` to `.failed`.
///
/// Carries the `setId` as well as the `runId` because the caller has a second
/// piece of wreckage to clear: `state/current-run-<setId>.json`, which the
/// dead process never got to delete. See `Tick`'s step 3.
public struct RecoveredRun: Equatable, Sendable {
    public let runId: String
    public let setId: UUID

    public init(runId: String, setId: UUID) {
        self.runId = runId
        self.setId = setId
    }
}

/// Whether a `state/current-run-<setId>.json` still describes something that
/// is actually happening.
///
/// The file is deleted by the `defer` at the end of every run, so its mere
/// presence normally means "a run is in flight" — and that is what the menu
/// bar and `status` report. A `SIGKILL`, an OOM kill or a power cut skips
/// that `defer` and leaves the file behind forever, at which point
/// `AppHealth` pins to `.running` (which outranks `.warning`) and every
/// health check reports green for a machine that has stopped backing up.
/// That is the exact failure this type exists to make impossible.
public enum CurrentRunLiveness: String, Equatable, Sendable {
    /// The recorded `pid` answers `kill(pid, 0)` and, when written by a new
    /// helper, its independent awake-time heartbeat is still fresh.
    case live
    /// The process still exists, but its independent heartbeat has not
    /// advanced for the bounded awake-time threshold. It may be stopped or
    /// deadlocked and must not be presented as useful progress.
    case stalled
    /// The process that wrote it is gone. Nothing will ever update or delete
    /// this file: it is wreckage, not progress.
    case abandoned
}

/// Errors surfaced by `RunStore`'s own I/O beyond ordinary `Data`/`JSONDecoder`
/// throws (which propagate as-is from `metadata(runId:)`).
public enum RunStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case durableWriteFailed(operation: String, errno: Int32, path: String)
    case renameFailed(errno: Int32, from: String, to: String)
    case indexAppendFailed(errno: Int32, path: String)
    /// A caller tried to discard something other than its own fresh,
    /// still-running run directory.
    case discardUnsafe(path: String)
    /// The `index.jsonl` companion lock could not be acquired within the
    /// bounded retry window — see `RunStore.indexLockTimeout`.
    case indexLockTimeout(path: String)
    /// A run publisher or audit verifier could not enter their short shared
    /// critical section within the bounded retry window.
    case publicationLockTimeout(path: String)
    /// The independently encoded kind in a current-format run directory name
    /// disagrees with metadata.
    case runDirectoryKindMismatch(path: String, encodedKind: RunKind)
    /// Destructive metadata is canonical only at `runs/<metadata.runId>`.
    /// Accepting it under another directory could hide the disappearance of
    /// the real canonical record from the orphan-index audit.
    case runDirectoryIDMismatch(path: String, encodedRunId: String)
    /// Initial metadata publication failed after its fresh run directory was
    /// created, and removing that unpublished directory failed too.
    case initialPublicationCleanupFailed(path: String, publicationError: String, cleanupError: String)
    /// The `index.jsonl` companion lock could not be used at all — wrong
    /// owner, unopenable, or an uncreatable `runs/` (#110).
    case lockUnusable(LockFailure)

    public var description: String {
        switch self {
        case .durableWriteFailed(let operation, let errno, let path):
            return "\(operation) failed for \(path): errno \(errno)"
        case .renameFailed(let errno, let from, let to):
            return "rename(\(from), \(to)) failed: errno \(errno)"
        case .indexAppendFailed(let errno, let path):
            return "append to \(path) failed: errno \(errno)"
        case .discardUnsafe(let path):
            return "refusing to discard non-fresh run metadata at \(path)"
        case .indexLockTimeout(let path):
            return "timed out waiting for index lock \(path)"
        case .publicationLockTimeout(let path):
            return "timed out waiting for run-publication lock \(path)"
        case .runDirectoryKindMismatch(let path, let encodedKind):
            return "run directory kind does not match metadata kind \(encodedKind.rawValue): \(path)"
        case .runDirectoryIDMismatch(let path, let encodedRunId):
            return "run directory name does not match metadata run ID \(encodedRunId): \(path)"
        case .initialPublicationCleanupFailed(let path, let publicationError, let cleanupError):
            return "initial run publication failed at \(path): \(publicationError); cleanup also failed: \(cleanupError)"
        case .lockUnusable(let failure):
            return "run-store lock unusable: \(failure)"
        }
    }
}

/// Run recording per `docs/data-model.md` (§runs/index.jsonl,
/// §runs/<runId>/metadata.json) and `docs/architecture.md` (§RunStatus,
/// §AppPaths `runId` format).
///
/// Run records are crash-durable per docs/data-model.md: `metadata.json` is
/// fully written and synced before a descriptor-relative rename and parent
/// directory sync; `index.jsonl` is fully appended and synced while its
/// companion `FileLock` (`runs/index.jsonl.lock`) remains held.
public struct RunStore: Sendable {
    public let paths: AppPaths
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let initialPublicationHook: @Sendable (URL) throws -> Void
    private let publicationLockMaxAttempts: Int
    private let fileOperations: RunStoreFileOperations

    /// Five minutes is ten missed 30-second heartbeats: long enough to absorb
    /// scheduling pressure, short enough for a monitoring check to catch a
    /// wedged helper before another two-minute scheduler tick is mistaken for
    /// useful work. The uptime clock excludes system sleep.
    public static let currentRunHeartbeatStaleAfter: TimeInterval = 5 * 60

    /// How long `finish`/`recoverInterrupted` will retry for the index
    /// companion lock before giving up with `RunStoreError.indexLockTimeout`.
    /// The critical section it guards is a single tiny append, so contention
    /// should never last anywhere near this long in practice.
    private static let indexLockTimeout: TimeInterval = 5
    private static let indexLockPollInterval: UInt32 = 5_000 // microseconds
    private static let publicationLockMaxAttempts = 1_000
    /// Markerless destructive runs created under this contract are known to
    /// be pre-launch. Missing or unknown versions predate that guarantee and
    /// are treated as an unknown repository outcome while still running.
    public static let destructiveAuditContractVersion = 1

    public init(paths: AppPaths) {
        self.init(
            paths: paths,
            now: { Date() },
            uptime: { ProcessInfo.processInfo.systemUptime }
        )
    }

    /// Clock-injecting initializer, so `runId` generation (which embeds a
    /// UTC timestamp) is deterministic in tests. `init(paths:)` is the
    /// production entry point and simply forwards to this with `Date()`.
    public init(
        paths: AppPaths,
        now: @escaping @Sendable () -> Date,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.paths = paths
        self.now = now
        self.uptime = uptime
        self.initialPublicationHook = { _ in }
        self.publicationLockMaxAttempts = Self.publicationLockMaxAttempts
        self.fileOperations = .live
    }

    /// Fault-injection seam for the publication rollback regression test.
    /// Kept internal so production callers cannot insert work between the
    /// directory creation and first canonical metadata commit.
    init(
        paths: AppPaths,
        now: @escaping @Sendable () -> Date,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        initialPublicationHook: @escaping @Sendable (URL) throws -> Void,
        publicationLockMaxAttempts: Int = 1_000,
        fileOperations: RunStoreFileOperations = .live
    ) {
        precondition(publicationLockMaxAttempts > 0)
        self.paths = paths
        self.now = now
        self.uptime = uptime
        self.initialPublicationHook = initialPublicationHook
        self.publicationLockMaxAttempts = publicationLockMaxAttempts
        self.fileOperations = fileOperations
    }

    // MARK: - begin / finish

    /// Allocates a `runId` (per `docs/architecture.md` §AppPaths format),
    /// creates `runs/<runId>/`, and writes the initial `metadata.json`
    /// (`status: .running`, `pid: getpid()`, no `end`).
    ///
    /// - Parameter groupId: shared id linking a scheduled set run's backup,
    ///   copy(s), and prune(s) so the UI can nest them. `nil` (the default
    ///   for a standalone run) makes the new run its own group, i.e.
    ///   `groupId == runId`.
    public func begin(
        kind: RunKind,
        setId: UUID,
        destId: UUID,
        trigger: RunTrigger,
        groupId: String? = nil
    ) throws -> ActiveRun {
        let directorySyncChain = missingDirectorySyncChain(to: paths.runsDir)
        try paths.ensureDirectories()
        // `ensureDirectories()` may have created several ancestors at once.
        // Persist every new directory entry, bottom-up, before any operation
        // can reach its launch boundary. Syncing only `runs/` would still let
        // a crash lose `runs/`, the data root, or another newly-created
        // ancestor from its parent directory.
        for directory in directorySyncChain {
            try syncDirectory(directory)
        }

        // A verifier must never observe the directory between mkdir and its
        // first metadata commit. The separate publication lock also lets two
        // read-only verifiers serialize without pretending one is a running
        // destructive helper.
        let publicationLock = try acquireRunPublicationLock(waitIndefinitely: true)
        defer { publicationLock.release() }

        let start = now()
        let runId = try allocateRunId(kind: kind, setId: setId, start: start)
        let pid = getpid()
        let resolvedGroupId = groupId ?? runId

        let metadata = RunMetadata(
            runId: runId,
            kind: kind,
            setId: setId,
            destId: destId,
            groupId: resolvedGroupId,
            status: .running,
            trigger: trigger,
            start: start,
            end: nil,
            pid: pid,
            resticExitCode: nil,
            argvRedacted: [],
            snapshotId: nil,
            filesNew: nil,
            filesChanged: nil,
            dataAdded: nil,
            errorSummary: nil,
            stats: nil,
            purgeSnapshotRewrites: nil,
            destructiveAuditContractVersion: kind.isDestructive
                ? Self.destructiveAuditContractVersion
                : nil
        )
        let runDirectory = paths.runDir(runId: runId)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        do {
            try initialPublicationHook(runDirectory)
            try writeMetadataAtomic(metadata)
            // `metadata.json` is durable inside the new run directory; now
            // make the directory entry itself durable in `runs/`.
            try syncDirectory(paths.runsDir)
        } catch {
            let publicationError = String(describing: error)
            do {
                try FileManager.default.removeItem(at: runDirectory)
                // The removal is part of rolling back publication. Persist it
                // before reporting the failed begin as safely unpublished;
                // otherwise a crash can resurrect the canonical directory.
                try syncDirectory(paths.runsDir)
            } catch let cleanupError {
                throw RunStoreError.initialPublicationCleanupFailed(
                    path: runDirectory.path,
                    publicationError: publicationError,
                    cleanupError: String(describing: cleanupError)
                )
            }
            throw error
        }

        return ActiveRun(
            runId: runId,
            kind: kind,
            setId: setId,
            destId: destId,
            trigger: trigger,
            groupId: resolvedGroupId,
            start: start,
            pid: pid,
            argvRedacted: []
        )
    }

    /// Atomically rewrites `metadata.json` with the final outcome and
    /// appends the corresponding compact line to `runs/index.jsonl`.
    public func finish(
        _ run: ActiveRun,
        status: RunStatus,
        stats: BackupSummary? = nil,
        errorSummary: String? = nil,
        resticExitCode: Int32? = nil,
        purgeSnapshotRewrites: [String: String]? = nil,
        auditFailureReason: RunAuditFailureReason? = nil
    ) throws {
        // Publish the canonical terminal rewrite and its derived index line
        // as one verifier-visible transaction. Without this lock a scan can
        // observe new terminal metadata against the old index snapshot and
        // permanently misdiagnose an ordinary in-flight finish.
        let publicationLock = try acquireRunPublicationLock(waitIndefinitely: true)
        defer { publicationLock.release() }

        // The launch marker is committed separately, immediately before
        // process creation. Preserve that canonical evidence in the terminal
        // rewrite. Failing to re-read it is itself an audit failure; do not
        // replace the record with one that falsely claims no launch occurred.
        let destructiveLaunchAuthorizedAt: Date?
        let destructiveAuditContractVersion: Int?
        if run.kind.isDestructive {
            let canonical = try metadata(runId: run.runId)
            destructiveLaunchAuthorizedAt = canonical.destructiveLaunchAuthorizedAt
            destructiveAuditContractVersion = canonical.destructiveAuditContractVersion
        } else {
            destructiveLaunchAuthorizedAt = nil
            destructiveAuditContractVersion = nil
        }
        var metadata = RunMetadata(
            runId: run.runId,
            kind: run.kind,
            setId: run.setId,
            destId: run.destId,
            groupId: run.groupId,
            status: status,
            trigger: run.trigger,
            start: run.start,
            end: now(),
            pid: run.pid,
            resticExitCode: resticExitCode,
            argvRedacted: run.argvRedacted,
            snapshotId: stats?.snapshotId,
            filesNew: stats?.filesNew,
            filesChanged: stats?.filesChanged,
            dataAdded: stats?.dataAdded,
            errorSummary: errorSummary,
            stats: stats,
            purgeSnapshotRewrites: purgeSnapshotRewrites,
            destructiveAuditContractVersion: destructiveAuditContractVersion,
            destructiveLaunchAuthorizedAt: destructiveLaunchAuthorizedAt,
            auditFailureReason: auditFailureReason,
            indexPublicationPending: true
        )
        try writeMetadataAtomic(metadata)
        try appendIndexEntry(metadata.indexEntry)
        metadata.indexPublicationPending = nil
        try writeMetadataAtomic(metadata)
    }

    /// Commits the destructive launch boundary immediately before the argv
    /// is handed to the process runner. The caller must refuse launch if this
    /// write fails. It is intentionally separate from `begin`: secret,
    /// executable and confirmation-token preflights can still fail safely
    /// before this point.
    public func markDestructiveLaunchAuthorized(_ run: ActiveRun) throws {
        precondition(run.kind.isDestructive)
        var existing = try metadata(runId: run.runId)
        guard existing.status == .running,
              existing.runId == run.runId,
              existing.pid == run.pid else {
            throw RunStoreError.discardUnsafe(path: paths.runMetadataFile(runId: run.runId).path)
        }
        existing.destructiveLaunchAuthorizedAt = now()
        existing.argvRedacted = run.argvRedacted
        try writeMetadataAtomic(existing)
    }

    /// Removes a just-created run before it reaches the index. This is only
    /// for a preflight that was retryably unavailable before restic started;
    /// presenting such contention as a failed maintenance run would replace
    /// the last real cleanup despite modifying no repository data.
    public func discardUnstarted(_ run: ActiveRun) throws {
        let publicationLock = try acquireRunPublicationLock(waitIndefinitely: true)
        defer { publicationLock.release() }

        let directory = paths.runDir(runId: run.runId)
        let metadataURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
        let data = try Data(contentsOf: metadataURL)
        let metadata = try ConfigStore.makeDecoder().decode(RunMetadata.self, from: data)
        guard metadata.runId == run.runId,
              metadata.status == .running,
              metadata.pid == run.pid else {
            throw RunStoreError.discardUnsafe(path: metadataURL.path)
        }
        try FileManager.default.removeItem(at: directory)
        try syncDirectory(paths.runsDir)
    }

    // MARK: - Crash recovery

    /// Scans `runs/*/metadata.json` for records left `status == .running`
    /// whose `pid` is no longer alive (`kill(pid, 0)` fails with `ESRCH`),
    /// rewrites each as `.failed` with `errorSummary: "interrupted"`,
    /// appends the index line, and returns what it recovered. Records
    /// whose `pid` is alive (including "alive but owned by someone else",
    /// i.e. `kill` fails with `EPERM`) are left untouched. Unreadable /
    /// corrupt metadata files are skipped, never thrown.
    ///
    /// Returns `RecoveredRun` (runId **and** setId) rather than bare runIds:
    /// the caller must also clear the `state/current-run-<setId>.json` the
    /// dead process left behind, and it cannot work out which one from a
    /// runId alone. See `liveness(ofCurrentRun:)` for what that stale file
    /// does to health reporting if it is left in place.
    @discardableResult
    public func recoverInterrupted() throws -> [RecoveredRun] {
        try paths.ensureDirectories()

        // Recovery performs the same terminal metadata + index publication
        // as finish(), so it must obey the same verifier-visible boundary.
        let publicationLock = try acquireRunPublicationLock(waitIndefinitely: true)
        defer { publicationLock.release() }

        let fileManager = FileManager.default
        guard let runDirs = try? fileManager.contentsOfDirectory(
            at: paths.runsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        let decoder = ConfigStore.makeDecoder()
        var recovered: [RecoveredRun] = []
        // Repair a torn final record before taking the recovery snapshot. In
        // particular, a split UTF-8 scalar must not make the valid prefix look
        // empty and cause duplicate projections to be appended below.
        var indexedByRunId = Dictionary(
            grouping: try readIndexEntriesRepairingTail(),
            by: \.runId
        )

        for dir in runDirs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let metadataFile = dir.appendingPathComponent("metadata.json", isDirectory: false)
            guard let data = try? Data(contentsOf: metadataFile) else { continue }
            guard let metadata = try? decoder.decode(RunMetadata.self, from: data) else { continue }
            guard dir.lastPathComponent == metadata.runId else {
                throw RunStoreError.runDirectoryIDMismatch(
                    path: metadataFile.path,
                    encodedRunId: metadata.runId
                )
            }
            if metadata.status != .running {
                // Canonical metadata wins. Repair only a wholly absent
                // destructive projection; duplicates or divergence remain an
                // explicit destructive audit failure. Non-destructive history
                // can publish a corrective last projection safely.
                let projections = indexedByRunId[metadata.runId, default: []]
                var projectionIsDurable = false
                if projections.isEmpty {
                    var pending = metadata
                    if pending.indexPublicationPending != true {
                        pending.indexPublicationPending = true
                        try writeMetadataAtomic(pending)
                    }
                    let projection = pending.indexEntry
                    try appendIndexEntry(projection)
                    indexedByRunId[metadata.runId] = [projection]
                    projectionIsDurable = true
                } else if projections == [metadata.indexEntry] {
                    // The recovery snapshot was fsynced before it was decoded,
                    // so this exact projection is now durably confirmed even
                    // for legacy metadata that predates the pending marker.
                    projectionIsDurable = true
                } else if !metadata.kind.isDestructive {
                    if projections.last == metadata.indexEntry {
                        // The initial recovery snapshot confirmed this final
                        // physical projection durably as well.
                        projectionIsDurable = true
                    } else {
                        var pending = metadata
                        if pending.indexPublicationPending != true {
                            pending.indexPublicationPending = true
                            try writeMetadataAtomic(pending)
                        }
                        let projection = pending.indexEntry
                        try appendIndexEntry(projection)
                        indexedByRunId[metadata.runId, default: []].append(projection)
                        projectionIsDurable = true
                    }
                }
                if projectionIsDurable,
                   (metadata.indexPublicationPending == true || projections.isEmpty
                       || (!metadata.kind.isDestructive && projections.last != metadata.indexEntry)) {
                    var reconciled = metadata
                    reconciled.indexPublicationPending = nil
                    try writeMetadataAtomic(reconciled)
                }
                continue
            }
            if Self.isProcessAlive(pid: metadata.pid) { continue }

            var updated = metadata
            updated.status = .failed
            updated.end = now()
            if updated.kind.isDestructive,
               (updated.destructiveLaunchAuthorizedAt != nil
                   || updated.destructiveAuditContractVersion != Self.destructiveAuditContractVersion) {
                updated.auditFailureReason = .launchedWithoutTerminalMetadata
                updated.errorSummary = "operation_completed_audit_failed — destructive operation may have run; repository outcome was not recorded"
            } else {
                updated.errorSummary = "interrupted"
            }
            updated.indexPublicationPending = true
            try writeMetadataAtomic(updated)
            let projections = indexedByRunId[updated.runId, default: []]
            var projectionIsDurable = false
            if projections.isEmpty {
                let projection = updated.indexEntry
                try appendIndexEntry(projection)
                indexedByRunId[updated.runId] = [projection]
                projectionIsDurable = true
            } else if projections == [updated.indexEntry] {
                // The recovery snapshot was fsynced before decoding.
                projectionIsDurable = true
            } else if !updated.kind.isDestructive {
                if projections.last == updated.indexEntry {
                    // The recovery snapshot was fsynced before decoding.
                } else {
                    let projection = updated.indexEntry
                    try appendIndexEntry(projection)
                    indexedByRunId[updated.runId, default: []].append(projection)
                }
                projectionIsDurable = true
            }
            if projectionIsDurable {
                updated.indexPublicationPending = nil
                try writeMetadataAtomic(updated)
            }
            recovered.append(RecoveredRun(runId: metadata.runId, setId: metadata.setId))
        }

        return recovered
    }

    /// Is this `state/current-run-<setId>.json` live, stalled, or abandoned?
    /// (`docs/data-model.md` §current-run.json)
    ///
    /// Decided from the run's own `runs/<runId>/metadata.json` — the same
    /// `pid` + `kill(pid, 0)` evidence `recoverInterrupted()` uses, so the
    /// two can never disagree about whether a run died.
    ///
    /// Deliberately **not** a timestamp heuristic on `updatedAt`. Progress is
    /// only written when restic emits a `status` line (throttled), and some
    /// phases legitimately emit nothing for hours. New helpers write a
    /// separate, unconditional heartbeat; its uptime value is the only age
    /// considered here. Uptime pauses during sleep, so a laptop wake is not a
    /// false stall. Older current-run files have no heartbeat and retain the
    /// previous process-only behavior until their run finishes.
    ///
    /// Missing or undecodable metadata counts as `.abandoned`: `begin(...)`
    /// writes `metadata.json` *before* the first progress write, so a
    /// current-run file pointing at a run directory that is not there
    /// describes a run this data directory has no record of.
    ///
    /// A pre-heartbeat legacy file inherits one known limitation from
    /// `recoverInterrupted()`: a recycled pid can make a dead run look live.
    /// Heartbeat-bearing files detect the usual reboot/pid-reuse case because
    /// their recorded uptime is greater than the new boot's uptime.
    public func liveness(ofCurrentRun state: CurrentRunState) -> CurrentRunLiveness {
        guard let metadata = try? metadata(runId: state.runId) else { return .abandoned }
        // The pid alone, deliberately — **not** `metadata.status == .running`
        // as well.
        //
        // A set run is several child runs under one `current-run` file:
        // `performChild` calls `RunStore.finish` (which moves that child's
        // metadata off `.running`) while the file is only cleared by the
        // *set*-level `defer`, and the next child's phase marker rewrites it
        // moments later. Between those two points — extendable by up to
        // `indexLockTimeout` seconds waiting on the index lock — the run is
        // completing perfectly normally and the metadata says "not running".
        // Requiring `.running` here reported that as abandoned wreckage and
        // exited 1 on a healthy host mid-backup, which is crying wolf: the
        // precise failure that teaches people to ignore a health check.
        //
        // Process liveness has no such window. The process is either there
        // to finish the job and clean up, or it is not.
        guard Self.isProcessAlive(pid: metadata.pid) else { return .abandoned }
        guard let heartbeatUptime = state.heartbeatUptime else { return .live }

        let heartbeatAge = uptime() - heartbeatUptime
        // A negative age means the uptime clock reset, normally because this
        // current-run file survived a reboot and its pid was recycled. The
        // recorded process cannot be the process that wrote this heartbeat.
        if heartbeatAge < 0 { return .abandoned }
        return heartbeatAge > Self.currentRunHeartbeatStaleAfter ? .stalled : .live
    }

    static func isProcessAlive(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        // EPERM: process exists but we can't signal it (still alive).
        // ESRCH (or anything else): no such process.
        return errno == EPERM
    }

    // MARK: - Reads

    /// Reads `runs/index.jsonl` tail, newest first, optionally restricted to
    /// one backup set. Tolerates a truncated or corrupt line (e.g. from a
    /// crash mid-append): such lines are skipped with a warning to stderr;
    /// this method never throws because of malformed index content.
    ///
    /// When `setId` is given, the filter is applied **before** `limit`
    /// truncates the result. `readIndexEntries()` decodes the entire file
    /// regardless of `limit` (there is no way to stop early on a `.jsonl`
    /// tail without an index), so there is no cost saved by truncating
    /// first — and truncating first is actively wrong: a quiet set's whole
    /// history can be newer than nothing and still get crowded out of a
    /// shared, unfiltered window by busier sets' more numerous newer runs.
    /// `runs list --set` (T27, issue #29 finding 3) depends on this order.
    public func recentRuns(setId: UUID? = nil, limit: Int) throws -> [RunIndexEntry] {
        let entries = try logicalIndexEntries()
        let scoped = setId.map { id in entries.filter { $0.setId == id } } ?? entries
        return Array(scoped.reversed().prefix(max(limit, 0)))
    }

    /// Most recent index entry for `setId`/`kind`, or `nil` if none.
    public func lastRun(setId: UUID, kind: RunKind) throws -> RunIndexEntry? {
        let entries = try logicalIndexEntries()
        for entry in entries.reversed() where entry.setId == setId && entry.kind == kind {
            return entry
        }
        return nil
    }

    /// Decodes `runs/<runId>/metadata.json`. Unlike `recentRuns`/`lastRun`,
    /// this is a single explicit lookup — it throws normally (missing file,
    /// decode failure) rather than swallowing errors.
    public func metadata(runId: String) throws -> RunMetadata {
        let data = try Data(contentsOf: paths.runMetadataFile(runId: runId))
        return try ConfigStore.makeDecoder().decode(RunMetadata.self, from: data)
    }

    /// Reconstructs unresolved destructive audit failures from the canonical
    /// per-run metadata and the derived index. It never mutates either one;
    /// `recoverInterrupted()` owns idempotent reconciliation toward metadata.
    public func unresolvedAuditFailures(
        callerHoldsDestructiveAuditGate: Bool = false
    ) throws -> [RunAuditFailure] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.runsDir.path) else { return [] }

        let publicationLock = try acquireRunPublicationLock()
        var publicationLockHeld = true
        defer {
            if publicationLockHeld { publicationLock.release() }
        }

        var gateProbe: FileLock?
        let destructiveOperationIsActive: Bool
        if callerHoldsDestructiveAuditGate {
            // BackupEngine owns the gate before it scans and has not launched
            // its new operation yet. Any older running marker is therefore
            // unresolved, even if its PID has since been recycled.
            gateProbe = nil
            destructiveOperationIsActive = false
        } else {
            let probe = FileLock(path: paths.destructiveAuditLockFile, trustedRoot: paths.root)
            switch probe.acquire() {
            case .acquired:
                // Keep the probe lock through the scan. This makes the
                // no-active-operation observation atomic with a new helper's
                // verify-and-launch sequence.
                gateProbe = probe
                destructiveOperationIsActive = false
            case .busy:
                gateProbe = nil
                destructiveOperationIsActive = true
            case .failed(let failure):
                throw RunStoreError.lockUnusable(failure)
            }
        }
        defer { gateProbe?.release() }

        // Snapshot only bytes and structural names while publishers are
        // excluded. JSON decoding, grouping and comparison happen after the
        // lock is released so a large history cannot hold terminal writers
        // behind avoidable CPU work. Publishers themselves wait without a
        // timeout: after restic may have changed a repository, losing the
        // terminal audit commit is less safe than waiting for a reader.
        let indexData: Data?
        if fileManager.fileExists(atPath: paths.runsIndexFile.path) {
            indexData = try Data(contentsOf: paths.runsIndexFile)
        } else {
            indexData = nil
        }
        let runDirectories = try fileManager.contentsOfDirectory(
            at: paths.runsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var metadataSnapshots: [(directory: URL, data: Data)] = []
        for directory in runDirectories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            if directory.lastPathComponent == paths.runsIndexLockFile.lastPathComponent
                || directory.lastPathComponent == paths.runsHealthProbeDir.lastPathComponent {
                continue
            }
            let metadataURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
            metadataSnapshots.append((directory, try Data(contentsOf: metadataURL)))
        }
        publicationLock.release()
        publicationLockHeld = false
        // The liveness observation is now captured in
        // `destructiveOperationIsActive`; decoding cannot change it. Release
        // the machine-wide gate before CPU-only history work so a large
        // health scan cannot spuriously defer a real destructive helper.
        gateProbe?.release()
        gateProbe = nil

        let indexedEntries = decodeIndexEntries(indexData)
        let indexedByRunId = Dictionary(grouping: indexedEntries, by: \.runId)
        let decoder = ConfigStore.makeDecoder()
        var failures: [RunAuditFailure] = []
        var canonicalDestructiveRunIds: Set<String> = []

        for snapshot in metadataSnapshots {
            let directory = snapshot.directory
            let metadataURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
            // Canonical evidence that cannot be read must make verification
            // fail closed. Silently skipping it could hide the very marker
            // this scan exists to enforce.
            let data = snapshot.data
            let discriminator = try decoder.decode(RunAuditDiscriminator.self, from: data)
            if let directoryKind = Self.runKind(fromRunDirectoryName: directory.lastPathComponent),
               directoryKind != discriminator.kind {
                throw RunStoreError.runDirectoryKindMismatch(
                    path: metadataURL.path,
                    encodedKind: discriminator.kind
                )
            }
            guard discriminator.kind.isDestructive else { continue }
            let metadata = try decoder.decode(RunMetadata.self, from: data)
            guard directory.lastPathComponent == metadata.runId else {
                throw RunStoreError.runDirectoryIDMismatch(
                    path: metadataURL.path,
                    encodedRunId: metadata.runId
                )
            }
            canonicalDestructiveRunIds.insert(metadata.runId)
            let reason: RunAuditFailureReason?
            if let recorded = metadata.auditFailureReason {
                reason = recorded
            } else if metadata.status == .running {
                if metadata.destructiveLaunchAuthorizedAt == nil {
                    // Current running records explicitly identify the
                    // contract under which a missing marker means safely
                    // unstarted. Historical running records have no such
                    // discriminator and therefore fail closed.
                    reason = metadata.destructiveAuditContractVersion
                        == Self.destructiveAuditContractVersion
                        ? nil
                        : .launchedWithoutTerminalMetadata
                } else {
                    reason = destructiveOperationIsActive && Self.isProcessAlive(pid: metadata.pid)
                        ? nil
                        : .launchedWithoutTerminalMetadata
                }
            } else if metadata.indexPublicationPending == true {
                // The index line may be absent, partial, or fully visible but
                // not durably confirmed. Treat all three as one incomplete
                // derived publication until recovery finishes the transaction.
                reason = .terminalMetadataMissingIndex
            } else {
                // Terminal projection integrity applies to every destructive
                // record, including pre-contract records with no launch
                // marker. A legacy marker says nothing about whether its
                // canonical terminal metadata reached the derived index.
                let projections = indexedByRunId[metadata.runId] ?? []
                if projections.isEmpty {
                    reason = .terminalMetadataMissingIndex
                } else if projections.count == 1,
                          projections[0] == metadata.indexEntry {
                    reason = nil
                } else {
                    reason = .terminalMetadataIndexMismatch
                }
            }
            if let reason {
                failures.append(RunAuditFailure(
                    runId: metadata.runId,
                    kind: metadata.kind,
                    setId: metadata.setId,
                    destId: metadata.destId,
                    start: metadata.start,
                    reason: reason
                ))
            }
        }

        // The index is derived, but a destructive projection with no
        // canonical record is still evidence of an operation whose durable
        // audit source disappeared. Directory-driven scans alone would
        // silently miss exactly that loss.
        for (runId, projections) in indexedByRunId
            where projections.contains(where: { $0.kind.isDestructive })
                && !canonicalDestructiveRunIds.contains(runId) {
            guard let projection = projections
                .filter({ $0.kind.isDestructive })
                .sorted(by: { $0.start < $1.start })
                .first else { continue }
            failures.append(RunAuditFailure(
                runId: runId,
                kind: projection.kind,
                setId: projection.setId,
                destId: projection.destId,
                start: projection.start,
                reason: .canonicalMetadataMissing
            ))
        }

        return failures.sorted {
            $0.start == $1.start ? $0.runId < $1.runId : $0.start < $1.start
        }
    }

    /// `runs/<runId>/log.txt` — see `AppPaths.runLogFile(runId:)`.
    public func logURL(runId: String) -> URL {
        paths.runLogFile(runId: runId)
    }

    private func readIndexEntries() throws -> [RunIndexEntry] {
        let indexFile = paths.runsIndexFile
        guard FileManager.default.fileExists(atPath: indexFile.path) else { return [] }

        let data = try Data(contentsOf: indexFile)
        return decodeIndexEntries(data)
    }

    /// Recovery is allowed to repair only an incomplete physical tail. It
    /// does so under the index lock and durably commits that repair before
    /// deciding which canonical records still need a projection.
    private func readIndexEntriesRepairingTail() throws -> [RunIndexEntry] {
        try paths.ensureDirectories()
        let lock = try acquireIndexLock()
        defer { lock.release() }

        let indexPath = paths.runsIndexFile.path
        guard FileManager.default.fileExists(atPath: indexPath) else { return [] }

        let runsDirectoryFD = try openDirectory(paths.runsDir)
        defer { closeFileDescriptor(runsDirectoryFD) }
        let fd = fileOperations.openAt(
            runsDirectoryFD,
            paths.runsIndexFile.lastPathComponent,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0
        )
        guard fd >= 0 else {
            throw RunStoreError.indexAppendFailed(errno: errno, path: indexPath)
        }
        defer { closeFileDescriptor(fd) }

        _ = try repairIncompleteIndexTail(fd: fd, path: indexPath)
        // One recovery-wide durability confirmation covers both a repaired
        // tail and matching legacy projections that have no pending marker.
        try syncFileDescriptor(fd, operation: "fsync recovery index", path: indexPath, indexWrite: true)
        try syncFileDescriptor(
            runsDirectoryFD,
            operation: "fsync index directory",
            path: indexPath,
            indexWrite: true
        )
        return decodeIndexEntries(try Data(contentsOf: paths.runsIndexFile))
    }

    /// Returns one logical projection per run, ordered by canonical start
    /// time. A corrective recovery projection is physically appended after
    /// the stale line it supersedes; taking the last projection per run keeps
    /// history truthful without hiding duplicate destructive projections from
    /// `unresolvedAuditFailures()`, which reads the raw entries independently.
    private func logicalIndexEntries() throws -> [RunIndexEntry] {
        let physical = try readIndexEntries()
        var latestByRunId: [String: (offset: Int, entry: RunIndexEntry)] = [:]
        for (offset, entry) in physical.enumerated() {
            latestByRunId[entry.runId] = (offset, entry)
        }
        return latestByRunId.values.sorted {
            if $0.entry.start != $1.entry.start {
                return $0.entry.start < $1.entry.start
            }
            return $0.offset < $1.offset
        }.map(\.entry)
    }

    private func decodeIndexEntries(_ data: Data?) -> [RunIndexEntry] {
        guard let data else { return [] }
        let indexFile = paths.runsIndexFile
        guard let text = String(data: data, encoding: .utf8) else {
            warn("RunStore: \(indexFile.path) is not valid UTF-8; treating as empty")
            return []
        }

        let decoder = ConfigStore.makeDecoder()
        var results: [RunIndexEntry] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let lineNumber = offset + 1
            let lineData = Data(rawLine.utf8)
            do {
                results.append(try decoder.decode(RunIndexEntry.self, from: lineData))
            } catch {
                warn("RunStore: skipping corrupt index line \(lineNumber) in \(indexFile.path): \(error)")
                continue
            }
        }
        return results
    }

    /// The kind is a structural part of every run directory name:
    /// `<timestamp>-<kind>-<set-prefix>[-collision]`. Audit verification
    /// cross-checks this independent copy before allowing a valid but
    /// corrupted metadata discriminator to skip the destructive contract.
    private static func runKind(fromRunDirectoryName name: String) -> RunKind? {
        let fields = name.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        return RunKind(rawValue: String(fields[1]))
    }

    /// Coordinates the mkdir + initial metadata publication with audit
    /// scans. The lock is deliberately separate from the destructive gate:
    /// contention here can only mean another publisher/verifier, never proof
    /// that a recorded destructive PID owns the operation gate.
    private func acquireRunPublicationLock(waitIndefinitely: Bool = false) throws -> FileLock {
        let lock = FileLock(path: paths.runPublicationLockFile, trustedRoot: paths.root)
        var attempt = 0
        while true {
            switch lock.acquire() {
            case .acquired:
                return lock
            case .busy:
                attempt += 1
                if !waitIndefinitely && attempt >= publicationLockMaxAttempts {
                    throw RunStoreError.publicationLockTimeout(path: paths.runPublicationLockFile.path)
                }
                usleep(Self.indexLockPollInterval)
            case .failed(let failure):
                throw RunStoreError.lockUnusable(failure)
            }
        }
    }

    // MARK: - runId allocation

    /// `<ISO8601 basic UTC>-<kind>-<first 8 lowercased hex chars of setId>`,
    /// e.g. `20260726T205704Z-backup-6f9619ff` — see `docs/architecture.md`
    /// §AppPaths.
    ///
    /// Collisions within the same second (two runs of the same kind for the
    /// same set starting in the same wall-clock second) are handled by
    /// appending a numeric `-2`, `-3`, ... suffix, checked against existing
    /// `runs/` directories. This is a deliberate, documented deviation from
    /// the literal format — it only ever triggers in the collision case.
    private func allocateRunId(kind: RunKind, setId: UUID, start: Date) throws -> String {
        let base = Self.formatRunId(kind: kind, setId: setId, date: start)
        var candidate = base
        var suffix = 2
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: paths.runDir(runId: candidate).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func formatRunId(kind: RunKind, setId: UUID, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let shortSetId = String(setId.uuidString.prefix(8)).lowercased()
        return "\(timestamp)-\(kind.rawValue)-\(shortSetId)"
    }

    // MARK: - Atomic metadata write

    private func writeMetadataAtomic(_ metadata: RunMetadata) throws {
        let dir = paths.runDir(runId: metadata.runId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let target = paths.runMetadataFile(runId: metadata.runId)
        let data = try ConfigStore.makeEncoder().encode(metadata)
        let directoryFD = try openDirectory(dir)
        defer { closeFileDescriptor(directoryFD) }

        let targetName = target.lastPathComponent
        let tempName = targetName + ".tmp"
        // A crash may leave the old temp inode behind. Remove it relative to
        // the already-open directory and then require creation of a fresh,
        // non-symlink file.
        if fileOperations.unlinkAt(directoryFD, tempName) != 0 {
            let code = errno
            if code != ENOENT {
                throw RunStoreError.durableWriteFailed(
                    operation: "unlinkat stale metadata temp",
                    errno: code,
                    path: dir.appendingPathComponent(tempName).path
                )
            }
        }
        let tempFD = fileOperations.openAt(
            directoryFD,
            tempName,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            0o644
        )
        guard tempFD >= 0 else {
            let code = errno
            throw RunStoreError.durableWriteFailed(
                operation: "openat metadata temp",
                errno: code,
                path: dir.appendingPathComponent(tempName).path
            )
        }

        do {
            try writeAll(data, to: tempFD, path: dir.appendingPathComponent(tempName).path)
            try syncFileDescriptor(
                tempFD,
                operation: "fsync metadata temp",
                path: dir.appendingPathComponent(tempName).path
            )
        } catch {
            closeFileDescriptor(tempFD)
            _ = fileOperations.unlinkAt(directoryFD, tempName)
            throw error
        }
        closeFileDescriptor(tempFD)

        guard fileOperations.renameAt(directoryFD, tempName, directoryFD, targetName) == 0 else {
            let renameErrno = errno
            _ = fileOperations.unlinkAt(directoryFD, tempName)
            throw RunStoreError.renameFailed(
                errno: renameErrno,
                from: dir.appendingPathComponent(tempName).path,
                to: target.path
            )
        }
        try syncFileDescriptor(
            directoryFD,
            operation: "fsync metadata directory",
            path: dir.path
        )
    }

    // MARK: - Index append

    private var indexLockFile: URL {
        paths.runsIndexLockFile
    }

    /// Appends one compact JSON line under `FileLock` on the `index.jsonl`
    /// companion lock file. The complete-write loop and `fsync` finish before
    /// the companion lock is released.
    private func appendIndexEntry(_ entry: RunIndexEntry) throws {
        try paths.ensureDirectories()

        let lock = try acquireIndexLock()
        defer { lock.release() }

        var line = try Self.makeIndexLineEncoder().encode(entry)
        line.append(0x0A) // "\n"

        let indexPath = paths.runsIndexFile.path
        let runsDirectoryFD = try openDirectory(paths.runsDir)
        defer { closeFileDescriptor(runsDirectoryFD) }
        let fd = fileOperations.openAt(
            runsDirectoryFD,
            paths.runsIndexFile.lastPathComponent,
            O_CREAT | O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            0o644
        )
        guard fd >= 0 else {
            let code = errno
            throw RunStoreError.indexAppendFailed(errno: code, path: indexPath)
        }
        defer { closeFileDescriptor(fd) }

        try repairIncompleteIndexTail(fd: fd, path: indexPath)
        try writeAll(line, to: fd, path: indexPath, indexWrite: true)
        try syncFileDescriptor(fd, operation: "fsync index", path: indexPath, indexWrite: true)
        // This is needed when the first append also creates index.jsonl;
        // harmlessly syncing the directory on later appends keeps the
        // durability boundary simple and reviewable.
        try syncFileDescriptor(
            runsDirectoryFD,
            operation: "fsync index directory",
            path: indexPath,
            indexWrite: true
        )
    }

    private func acquireIndexLock() throws -> FileLock {
        let lock = FileLock(path: indexLockFile, trustedRoot: paths.root)
        let deadline = now().addingTimeInterval(Self.indexLockTimeout)
        // Contention is waited out; a lock that cannot be opened is not
        // (#110) — see the same reasoning in `StateStore`.
        while true {
            switch lock.acquire() {
            case .acquired:
                return lock
            case .busy:
                if now() > deadline {
                    throw RunStoreError.indexLockTimeout(path: indexLockFile.path)
                }
                usleep(Self.indexLockPollInterval)
            case .failed(let failure):
                throw RunStoreError.lockUnusable(failure)
            }
        }
    }

    private func openDirectory(_ directory: URL) throws -> Int32 {
        let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard fd >= 0 else {
            let code = errno
            throw RunStoreError.durableWriteFailed(
                operation: "open directory",
                errno: code,
                path: directory.path
            )
        }
        return fd
    }

    /// Captures the directories whose entries will be created by
    /// `ensureDirectories()`, followed by the first existing ancestor. After
    /// creation, syncing this chain in returned order persists every path
    /// component from the new leaf back into stable storage.
    private func missingDirectorySyncChain(to leaf: URL) -> [URL] {
        var missing: [URL] = []
        var cursor = leaf.standardizedFileURL
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { break }
            cursor = parent
        }
        if !missing.isEmpty, missing.last?.path != cursor.path {
            missing.append(cursor)
        }
        return missing
    }

    /// An interrupted append can leave an unterminated fragment. Appending
    /// directly after it would concatenate the repair line onto corrupt JSON.
    /// Preserve a complete newline-less final record by terminating it;
    /// otherwise truncate only the invalid tail back to the last newline.
    @discardableResult
    private func repairIncompleteIndexTail(fd: Int32, path: String) throws -> Bool {
        var info = stat()
        #if canImport(Darwin)
        let statResult = Darwin.fstat(fd, &info)
        #elseif canImport(Glibc)
        let statResult = Glibc.fstat(fd, &info)
        #elseif canImport(Musl)
        let statResult = Musl.fstat(fd, &info)
        #endif
        guard statResult == 0 else {
            throw RunStoreError.indexAppendFailed(errno: errno, path: path)
        }
        let fileSize = Int(info.st_size)
        guard fileSize > 0 else { return false }
        let finalByte = try readIndexBytes(fd: fd, offset: fileSize - 1, count: 1, path: path)
        guard finalByte.first != 0x0A else { return false }

        // The common case above reads one byte. Only an actually incomplete
        // tail scans backward, in bounded chunks, until its preceding newline.
        var cursor = fileSize
        var reverseSuffixChunks: [Data] = []
        var validLength = 0
        while cursor > 0 {
            let start = max(0, cursor - 4_096)
            let chunk = try readIndexBytes(fd: fd, offset: start, count: cursor - start, path: path)
            if let newline = chunk.lastIndex(of: 0x0A) {
                let newlineOffset = chunk.distance(from: chunk.startIndex, to: newline)
                validLength = start + newlineOffset + 1
                let suffixStart = chunk.index(after: newline)
                reverseSuffixChunks.append(Data(chunk[suffixStart...]))
                break
            }
            reverseSuffixChunks.append(chunk)
            cursor = start
        }
        var suffix = Data()
        for chunk in reverseSuffixChunks.reversed() {
            suffix.append(chunk)
        }
        if (try? ConfigStore.makeDecoder().decode(RunIndexEntry.self, from: suffix)) != nil {
            try writeAll(Data([0x0A]), to: fd, path: path, indexWrite: true)
            return true
        }

        #if canImport(Darwin)
        let result = Darwin.ftruncate(fd, off_t(validLength))
        #elseif canImport(Glibc)
        let result = Glibc.ftruncate(fd, off_t(validLength))
        #elseif canImport(Musl)
        let result = Musl.ftruncate(fd, off_t(validLength))
        #endif
        if result != 0 {
            throw RunStoreError.indexAppendFailed(errno: errno, path: path)
        }
        return true
    }

    private func syncDirectory(_ directory: URL) throws {
        let fd = try openDirectory(directory)
        defer { closeFileDescriptor(fd) }
        try syncFileDescriptor(fd, operation: "fsync directory", path: directory.path)
    }

    private func syncFileDescriptor(
        _ fd: Int32,
        operation: String,
        path: String,
        indexWrite: Bool = false
    ) throws {
        while fileOperations.sync(fd) != 0 {
            let code = errno
            if code == EINTR { continue }
            if indexWrite {
                throw RunStoreError.indexAppendFailed(errno: code, path: path)
            }
            throw RunStoreError.durableWriteFailed(
                operation: operation,
                errno: code,
                path: path
            )
        }
    }

    private func readIndexBytes(fd: Int32, offset: Int, count: Int, path: String) throws -> Data {
        var data = Data(count: count)
        var total = 0
        while total < count {
            let readCount = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                #if canImport(Darwin)
                return Darwin.pread(fd, base.advanced(by: total), count - total, off_t(offset + total))
                #elseif canImport(Glibc)
                return Glibc.pread(fd, base.advanced(by: total), count - total, off_t(offset + total))
                #elseif canImport(Musl)
                return Musl.pread(fd, base.advanced(by: total), count - total, off_t(offset + total))
                #endif
            }
            if readCount < 0 {
                let code = errno
                if code == EINTR { continue }
                throw RunStoreError.indexAppendFailed(errno: code, path: path)
            }
            if readCount == 0 {
                throw RunStoreError.indexAppendFailed(errno: EIO, path: path)
            }
            total += readCount
        }
        return data
    }

    private func writeAll(
        _ data: Data,
        to fd: Int32,
        path: String,
        indexWrite: Bool = false
    ) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = fileOperations.write(
                    fd,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if indexWrite {
                        throw RunStoreError.indexAppendFailed(errno: code, path: path)
                    }
                    throw RunStoreError.durableWriteFailed(
                        operation: "write",
                        errno: code,
                        path: path
                    )
                }
                if written == 0 {
                    if indexWrite {
                        throw RunStoreError.indexAppendFailed(errno: EIO, path: path)
                    }
                    throw RunStoreError.durableWriteFailed(operation: "write", errno: EIO, path: path)
                }
                offset += written
            }
        }
    }

    private func closeFileDescriptor(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #elseif canImport(Glibc)
        _ = Glibc.close(fd)
        #elseif canImport(Musl)
        _ = Musl.close(fd)
        #endif
    }

    /// Compact (no pretty-printing) single-line JSON encoder for
    /// `index.jsonl`, sharing `ConfigStore`'s ISO 8601 + fractional-seconds
    /// date convention.
    private static func makeIndexLineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ConfigStore.makeISO8601Formatter().string(from: date))
        }
        return encoder
    }
}

private func warn(_ message: String) {
    StandardStream.write(Data((message + "\n").utf8), to: .standardError)
}
