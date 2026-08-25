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
    case renameFailed(errno: Int32, from: String, to: String)
    case indexAppendFailed(errno: Int32, path: String)
    /// A caller tried to discard something other than its own fresh,
    /// still-running run directory.
    case discardUnsafe(path: String)
    /// The `index.jsonl` companion lock could not be acquired within the
    /// bounded retry window — see `RunStore.indexLockTimeout`.
    case indexLockTimeout(path: String)
    /// The `index.jsonl` companion lock could not be used at all — wrong
    /// owner, unopenable, or an uncreatable `runs/` (#110).
    case lockUnusable(LockFailure)

    public var description: String {
        switch self {
        case .renameFailed(let errno, let from, let to):
            return "rename(\(from), \(to)) failed: errno \(errno)"
        case .indexAppendFailed(let errno, let path):
            return "append to \(path) failed: errno \(errno)"
        case .discardUnsafe(let path):
            return "refusing to discard non-fresh run metadata at \(path)"
        case .indexLockTimeout(let path):
            return "timed out waiting for index lock \(path)"
        case .lockUnusable(let failure):
            return "run-index lock unusable: \(failure)"
        }
    }
}

/// Run recording per `docs/data-model.md` (§runs/index.jsonl,
/// §runs/<runId>/metadata.json) and `docs/architecture.md` (§RunStatus,
/// §AppPaths `runId` format).
///
/// All writes are atomic per the data-model.md preamble: `metadata.json` is
/// written to a temp file in the same directory then `rename(2)`d over the
/// target; the `index.jsonl` append is a single `O_APPEND` `write(2)` under
/// a companion `FileLock` (`runs/index.jsonl.lock`).
public struct RunStore: Sendable {
    public let paths: AppPaths
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval

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
        try paths.ensureDirectories()

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
            purgeSnapshotRewrites: nil
        )
        try FileManager.default.createDirectory(at: paths.runDir(runId: runId), withIntermediateDirectories: true)
        try writeMetadataAtomic(metadata)

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
        // The launch marker is committed separately, immediately before
        // process creation. Preserve that canonical evidence in the terminal
        // rewrite. Failing to re-read it is itself an audit failure; do not
        // replace the record with one that falsely claims no launch occurred.
        let destructiveLaunchAuthorizedAt: Date?
        if run.kind.isDestructive {
            destructiveLaunchAuthorizedAt = try metadata(runId: run.runId).destructiveLaunchAuthorizedAt
        } else {
            destructiveLaunchAuthorizedAt = nil
        }
        let metadata = RunMetadata(
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
            destructiveLaunchAuthorizedAt: destructiveLaunchAuthorizedAt,
            auditFailureReason: auditFailureReason
        )
        try writeMetadataAtomic(metadata)
        try appendIndexEntry(metadata.indexEntry)
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

        let fileManager = FileManager.default
        guard let runDirs = try? fileManager.contentsOfDirectory(
            at: paths.runsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        let decoder = ConfigStore.makeDecoder()
        var recovered: [RecoveredRun] = []

        for dir in runDirs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let metadataFile = dir.appendingPathComponent("metadata.json", isDirectory: false)
            guard let data = try? Data(contentsOf: metadataFile) else { continue }
            guard let metadata = try? decoder.decode(RunMetadata.self, from: data) else { continue }
            guard metadata.status == .running else { continue }
            if Self.isProcessAlive(pid: metadata.pid) { continue }

            var updated = metadata
            updated.status = .failed
            updated.end = now()
            if updated.kind.isDestructive,
               updated.destructiveLaunchAuthorizedAt != nil {
                updated.auditFailureReason = .launchedWithoutTerminalMetadata
                updated.errorSummary = "operation_completed_audit_failed — destructive operation may have run; repository outcome was not recorded"
            } else {
                updated.errorSummary = "interrupted"
            }
            try writeMetadataAtomic(updated)
            try appendIndexEntry(updated.indexEntry)
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
        let entries = try readIndexEntries()
        let scoped = setId.map { id in entries.filter { $0.setId == id } } ?? entries
        return Array(scoped.reversed().prefix(max(limit, 0)))
    }

    /// Most recent index entry for `setId`/`kind`, or `nil` if none.
    public func lastRun(setId: UUID, kind: RunKind) throws -> RunIndexEntry? {
        let entries = try readIndexEntries()
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
    /// #120 owns idempotent reconciliation toward metadata.
    public func unresolvedAuditFailures(
        callerHoldsDestructiveAuditGate: Bool = false
    ) throws -> [RunAuditFailure] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.runsDir.path) else { return [] }

        let gateProbe: FileLock?
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

        let indexedEntries = try readIndexEntries()
        let indexedByRunId = Dictionary(grouping: indexedEntries, by: \.runId)
        let runDirectories = try fileManager.contentsOfDirectory(
            at: paths.runsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let decoder = ConfigStore.makeDecoder()
        var failures: [RunAuditFailure] = []

        for directory in runDirectories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            // These are known control paths, not run directories. If the
            // index lock is a directory because it is damaged, lock health
            // reports it; do not misdiagnose it as missing run metadata too.
            if directory.lastPathComponent == paths.runsIndexLockFile.lastPathComponent
                || directory.lastPathComponent == paths.runsHealthProbeDir.lastPathComponent {
                continue
            }
            let metadataURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
            // Canonical evidence that cannot be read must make verification
            // fail closed. Silently skipping it could hide the very marker
            // this scan exists to enforce.
            let data = try Data(contentsOf: metadataURL)
            let discriminator = try decoder.decode(RunAuditDiscriminator.self, from: data)
            guard discriminator.kind.isDestructive else { continue }
            let metadata = try decoder.decode(RunMetadata.self, from: data)
            guard metadata.destructiveLaunchAuthorizedAt != nil else {
                continue
            }

            let reason: RunAuditFailureReason?
            if let recorded = metadata.auditFailureReason {
                reason = recorded
            } else if metadata.status == .running {
                reason = destructiveOperationIsActive && Self.isProcessAlive(pid: metadata.pid)
                    ? nil
                    : .launchedWithoutTerminalMetadata
            } else {
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
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(target.lastPathComponent + ".tmp", isDirectory: false)

        let data = try ConfigStore.makeEncoder().encode(metadata)
        try data.write(to: temp)

        let fromPath = temp.path
        let toPath = target.path
        let renameResult = fromPath.withCString { fromC in
            toPath.withCString { toC in
                rename(fromC, toC)
            }
        }
        if renameResult != 0 {
            let renameErrno = errno
            try? FileManager.default.removeItem(at: temp)
            throw RunStoreError.renameFailed(errno: renameErrno, from: fromPath, to: toPath)
        }
    }

    // MARK: - Index append

    private var indexLockFile: URL {
        paths.runsIndexLockFile
    }

    /// Appends one compact JSON line under `FileLock` on the `index.jsonl`
    /// companion lock file. The write itself is a single `O_APPEND`
    /// `write(2)` call, per the data-model.md atomic-write preamble.
    private func appendIndexEntry(_ entry: RunIndexEntry) throws {
        try paths.ensureDirectories()

        let lock = FileLock(path: indexLockFile, trustedRoot: paths.root)
        let deadline = now().addingTimeInterval(Self.indexLockTimeout)
        // Contention is waited out; a lock that cannot be opened is not
        // (#110) — see the same reasoning in `StateStore`.
        while true {
            switch lock.acquire() {
            case .acquired:
                break
            case .busy:
                if now() > deadline {
                    throw RunStoreError.indexLockTimeout(path: indexLockFile.path)
                }
                usleep(Self.indexLockPollInterval)
                continue
            case .failed(let failure):
                throw RunStoreError.lockUnusable(failure)
            }
            break
        }
        defer { lock.release() }

        var line = try Self.makeIndexLineEncoder().encode(entry)
        line.append(0x0A) // "\n"

        let indexPath = paths.runsIndexFile.path
        let fd = indexPath.withCString { open($0, O_CREAT | O_WRONLY | O_APPEND, 0o644) }
        guard fd >= 0 else {
            throw RunStoreError.indexAppendFailed(errno: errno, path: indexPath)
        }
        defer { close(fd) }

        let written = line.withUnsafeBytes { buffer -> Int in
            write(fd, buffer.baseAddress, buffer.count)
        }
        if written != line.count {
            throw RunStoreError.indexAppendFailed(errno: errno, path: indexPath)
        }
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
