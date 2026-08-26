import Foundation
import Dispatch

// MARK: - RestoreRequest

/// A single restore operation, as requested by the UI / helper CLI
/// (`docs/tasks/T09-backup-engine.md` §runRestore).
///
/// Only the destination id is carried: the engine resolves the owning
/// `BackupSet` from its `AppConfig` so the *set* lock (not a per-destination
/// one) is what serializes a restore against a backup of the same set —
/// safety invariant "restore never runs concurrently with a backup of the
/// same set".
public struct RestoreRequest: Equatable, Sendable {
    public let destId: UUID
    public let snapshotID: String
    /// **In-snapshot** path (`docs/restic-cli.md` §restore), not a filesystem
    /// path. `nil` restores the whole snapshot.
    public let subpath: String?
    public let targetPath: String
    public let includes: [String]
    /// `nil` = restic's default (`always`).
    public let overwriteMode: ResticCommand.OverwriteMode?

    public init(
        destId: UUID,
        snapshotID: String,
        subpath: String? = nil,
        targetPath: String,
        includes: [String] = [],
        overwriteMode: ResticCommand.OverwriteMode? = nil
    ) {
        self.destId = destId
        self.snapshotID = snapshotID
        self.subpath = subpath
        self.targetPath = targetPath
        self.includes = includes
        self.overwriteMode = overwriteMode
    }
}

// MARK: - SetRunOutcome

/// One run record produced by a set run — the projection of `RunIndexEntry`
/// the caller needs to report the group without re-reading `index.jsonl`.
public struct SetRunChild: Equatable, Sendable {
    public let runId: String
    public let kind: RunKind
    public let destId: UUID
    public let status: RunStatus

    public init(runId: String, kind: RunKind, destId: UUID, status: RunStatus) {
        self.runId = runId
        self.kind = kind
        self.destId = destId
        self.status = status
    }
}

/// The result of `BackupEngine.runSet(_:trigger:)`, shaped after the error
/// taxonomy in `docs/architecture.md`:
///
/// - ``completed(status:groupId:children:)`` — the sequence ran; `status` is
///   the worst child run status (success | warning | failed).
/// - ``skipped`` — the set lock was busy; exactly one `.skipped` index
///   record was written and nothing else happened (**retryable**).
/// - ``retryable(reason:)`` — an environmental failure *before* anything was
///   recorded (secret store unreadable): NO run record, NO `lastBackupStart` update,
///   NO lock taken, so the next tick simply tries again.
/// - ``misconfigured(reason:)`` — defensive only: the set has no primary
///   destination, which `AppConfig.validate()` rejects on load and save.
///   Nothing is written (there is no destination to attribute a record to).
public enum SetRunOutcome: Equatable, Sendable {
    case completed(status: RunStatus, groupId: String, children: [SetRunChild])
    case skipped
    case retryable(reason: String)
    case misconfigured(reason: String)
    /// The operation could not start because the *machine* is broken — the
    /// set lock is unopenable, wrong-owner, or its directory uncreatable.
    ///
    /// Deliberately not `.misconfigured`, which describes a configuration the
    /// operator can fix by editing it, and emphatically not `.retryable`,
    /// which the helper renders as a benign deferral. A scheduled tick must
    /// exit non-zero on this so launchd/systemd sees a failing unit rather
    /// than a clean pass (#110).
    case infrastructureFailure(reason: String)
}

/// The result of `BackupEngine.runCheck(_:trigger:)`, keeping lock and local
/// state failures distinct from a repository check that ran and failed.
public enum CheckRunOutcome: Equatable, Sendable {
    case completed(RunStatus)
    /// A peer holds the set lock. Expected and retryable.
    case skipped
    /// Secrets were unavailable before locking or durable state mutation, so
    /// a later tick can retry cleanly.
    case retryable(reason: String)
    case misconfigured(reason: String)
    /// The set lock, schedule state, or run history is unusable. Scheduled
    /// callers must exit non-zero rather than flattening this to an ordinary
    /// failed check.
    case infrastructureFailure(reason: String)
}

/// The result of a directly requested set operation. Manual callers need to
/// distinguish a command that ran and failed from local process-control or
/// durable-state infrastructure that prevented a trustworthy run.
public enum ManualRunOutcome: Equatable, Sendable {
    case completed(RunStatus)
    /// Expected deferral: another operation owns the set lock, or secrets
    /// were temporarily unavailable before a run could begin.
    case skipped
    /// The set lock, run store, or terminal persistence was unusable.
    /// `operationMayHaveRun` prevents a caller from encouraging a blind
    /// retry after restic completed but its terminal state was not durable.
    case infrastructureFailure(reason: String, operationMayHaveRun: Bool)
    /// The operation is not available in this build. Distinct from
    /// ``skipped`` (a retryable deferral) and ``infrastructureFailure``
    /// (this machine is broken): nothing is wrong, nothing will change on a
    /// retry, and no state was touched. See
    /// ``ManualRetentionApplyAvailability``.
    case operationNotAllowed(reason: String)
}

/// The standalone-prune result keeps non-destructive refusals distinct from
/// restic failures so the helper can preserve the published JSON taxonomy.
public enum PruneRepositoryResult: Equatable, Sendable {
    case completed(RunStatus)
    case skipped(PruneRepositorySkipReason)
    case failed(PruneRepositoryFailure)
}

public enum PruneRepositorySkipReason: Equatable, Sendable {
    case busy
    case secretUnavailable
    case staleMirror
    case previewChanged
    /// The reclaim binding outlived `PreviewTokenStore.defaultLifetime`.
    /// Distinct from `previewChanged` so the caller can say so: an expired
    /// binding is the one refusal that is *not* evidence the destination was
    /// tampered with, and `purge apply` already reports it as such.
    case previewExpired
    /// The preview token could not be read because another helper briefly
    /// owns the machine-global token-store lock.  It remains valid to retry.
    case previewUnavailable
}

public enum PruneRepositoryFailure: Equatable, Sendable {
    case offline(String)
    case restic(ResticExitClass)
    case didNotRun
    /// Local process-control or durable-state infrastructure was unusable.
    /// Restic may have completed, failed, or never launched; none may report
    /// success without the required locking and bookkeeping invariants.
    case infrastructure(String)
    /// Run-history infrastructure failed for a specific destructive run.
    /// The helper publishes `runId` as structured error data so an operator
    /// can inspect the canonical record without parsing prose.
    case auditInfrastructure(reason: String, runId: String)
}

// MARK: - BackupEngine

/// The orchestration heart: scheduled/manual set runs (backup → mirror →
/// retention), purge, checks, prune, restore and secondary initialization, plus all
/// run-record and state bookkeeping.
///
/// Implements `docs/tasks/T09-backup-engine.md` (the numbered `runSet`
/// sequence and the safety invariants), `docs/architecture.md` (error
/// taxonomy, `RunStatus`, `groupId`), `docs/scheduling.md` (locking,
/// attempt-based `lastBackupStart`, check-slice rotation) and
/// `docs/restic-cli.md` (command semantics, exit codes, unlock-retry).
///
/// **Safety invariants** (this is the one component that can destroy data —
/// every one of these has a dedicated negative test in `BackupEngineTests`):
///
/// 1. `forget` runs only through ``forgetChild(destination:policy:...)``,
///    which refuses an empty/absent `RetentionPolicy` — the engine half of
///    the double guard whose other half is `ResticCommand.forget`'s
///    precondition.
/// 2. `forget` never targets a destination whose `copy` did not succeed **in
///    this run** (`runSet`), and never targets a mirror whose `lastSyncedAt`
///    predates the primary's last successful backup (`runPrune`).
/// 3. Restore takes the same per-set lock as backup, so the two can never
///    overlap for one set.
/// 4. Every restic child the engine spawns streams its raw stdout *and*
///    stderr into that run's `log.txt` before any parsing decision is made.
/// 5. `checkSliceCursor` advances only after a check that succeeded.
/// 6. `rewrite --forget` is reached only by a valid, unexpired, single-use
///    preview capability whose attributed snapshot ids are revalidated while
///    the set lock is held. A stale secondary is purged before a copy, never
///    afterwards.
///
/// Nothing here reads the wall clock directly: `now` is injected (as are the
/// process runner, via `ResticRunner`, and every store), which is what makes
/// the throttling and attempt-semantics behavior unit-testable.
public final class BackupEngine: Sendable {

    /// Minimum wall-clock gap between two `current-run` progress writes
    /// (`docs/architecture.md` §Process model: "≤ 1 write per 1–2 s").
    static let progressWriteInterval: TimeInterval = 1.5

    /// Independent liveness write cadence. This is intentionally much slower
    /// than progress updates: its only job is to prove the helper can still
    /// execute, including during restic phases that emit no output for hours.
    static let currentRunHeartbeatInterval: TimeInterval = 30

    /// Structure-only checks of the secondaries run on every Nth successful
    /// check of the primary (`docs/scheduling.md` §Check scheduling).
    static let secondaryCheckEveryNChecks = 4

    /// Fallback for `CheckPolicy.readDataSubsetSlices` when a set has no
    /// `checkPolicy` (`docs/data-model.md`: default 20).
    static let defaultCheckSlices = 20

    private let config: AppConfig
    private let paths: AppPaths
    private let restic: ResticRunner
    private let secrets: any SecretStore
    private let runStore: RunStore
    private let stateStore: StateStore
    private let reachability: Reachability
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let machineId: String
    private let previewTokens: PreviewTokenStore
    /// Raw shared-config source/hostname knowledge used by purge attribution.
    /// Resolved configs deliberately strip machine overrides, so the helper
    /// supplies these unions when it constructs the engine.
    private let purgeSourcePaths: [UUID: Set<String>]
    private let purgeHostnames: [UUID: Set<String>]
    private let logWriterFactory: @Sendable (URL) throws -> LogWriter

    public init(
        config: AppConfig,
        paths: AppPaths,
        restic: ResticRunner,
        secrets: any SecretStore,
        runStore: RunStore,
        stateStore: StateStore,
        reachability: Reachability,
        now: @escaping @Sendable () -> Date = Date.init,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        purgeSourcePaths: [UUID: Set<String>] = [:],
        purgeHostnames: [UUID: Set<String>] = [:],
        machineId: String = MachineIdentity.generate(),
        previewTokens: PreviewTokenStore? = nil,
        logWriterFactory: (@Sendable (URL) throws -> LogWriter)? = nil
    ) {
        self.config = config
        self.paths = paths
        self.restic = restic
        self.secrets = secrets
        self.runStore = runStore
        self.stateStore = stateStore
        self.reachability = reachability
        self.now = now
        self.uptime = uptime
        self.machineId = machineId
        self.previewTokens = previewTokens ?? PreviewTokenStore(paths: paths, now: now)
        self.purgeSourcePaths = purgeSourcePaths
        self.purgeHostnames = purgeHostnames
        self.logWriterFactory = logWriterFactory ?? { url in
            try LogWriter(url: url, now: now)
        }
    }

    // MARK: - runSet

    /// The eight-step set-run sequence from `docs/tasks/T09-backup-engine.md`.
    ///
    /// 1. secret-store pre-flight for the primary — failure returns
    ///    ``SetRunOutcome/retryable(reason:)`` leaving *no* trace;
    /// 2. `locks/set-<id>.lock` — busy writes one `.skipped` record and stops;
    /// 3. `lastBackupStart = now()` (attempt semantics, scheduled *and*
    ///    manual, written before the backup so a crash still counts as an
    ///    attempt);
    /// 4. probe the primary — not reachable ⇒ `.failed` backup record, stop;
    /// 5. `backup` (exit 3 ⇒ `.warning` and continue; exit 11 ⇒ `unlock` +
    ///    exactly one retry; 1/2/10/12 ⇒ `.failed`, stop — no copies, no
    ///    retention);
    /// 6. purge the primary if it has newly added purge exclusions;
    /// 7. every secondary in config order: probe, purge it if needed, copy,
    ///    then retention only if that copy succeeded;
    /// 8. retention on the primary if the policy is non-nil and non-empty;
    /// 9. clear `current-run`, release the lock (also on every failure path),
    ///    group outcome = worst child status.
    public func runSet(_ set: BackupSet, trigger: RunTrigger) async -> SetRunOutcome {
        guard let primary = set.destinations.first(where: { $0.isPrimary }) else {
            let reason = "backup set \"\(set.name)\" has no primary destination"
            logWarning("BackupEngine: \(reason) — refusing to run")
            return .misconfigured(reason: reason)
        }

        // ── Step 1: secret-store pre-flight ─────────────────────────────
        // Deliberately the engine's own read, *before* the lock and before
        // any state mutation: `ResticRunner` performs the same pre-flight,
        // but only once a run record and `lastBackupStart` would already
        // have been written. An unreadable secret store must leave no trace
        // at all.
        do {
            _ = try await secrets.password(destId: primary.id)
        } catch {
            let reason = "\(secretStoreDescription) could not be read for destination \"\(primary.label)\""
            logWarning("BackupEngine: \(reason) — skipping this run (retryable, nothing recorded)")
            return .retryable(reason: reason)
        }

        // ── Step 2: per-set lock ────────────────────────────────────────
        let (lock, acquisition) = acquireSetLock(setId: set.id)
        switch acquisition {
        case .acquired:
            break
        case .busy:
            recordSkipped(kind: .backup, setId: set.id, destId: primary.id, trigger: trigger)
            return .skipped
        case .failed(let failure):
            recordLockFailure(
                kind: .backup, setId: set.id, destId: primary.id, trigger: trigger, failure: failure
            )
            return .infrastructureFailure(reason: "backup-set lock unusable — \(failure)")
        }
        defer { lock.release() }
        // Declared after the lock defer, so it unwinds *first*: the live
        // progress record is removed while the lock is still held, on every
        // exit path (T09 step 8 — "clear current-run, release lock").
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        // ── Step 3: attempt-based lastBackupStart ───────────────────────
        do {
            try updateScheduleState(setId: set.id) { $0.lastBackupStart = self.now() }
        } catch {
            let reason = "schedule state unusable — \(error)"
            recordInfrastructureFailure(
                kind: .backup,
                setId: set.id,
                destId: primary.id,
                trigger: trigger,
                reason: reason
            )
            return .infrastructureFailure(reason: reason)
        }

        var children: [SetRunChild] = []
        var infrastructureFailures: [String] = []

        // ── Steps 4 + 5: probe primary, then back it up ─────────────────
        let backupResult = await performChild(
            kind: .backup,
            setId: set.id,
            destination: primary,
            trigger: trigger,
            groupId: nil, // this run *is* the group
            phase: "backing-up-primary",
            // `effectiveBackupExcludes`, not `excludes`: purge patterns are
            // ordinary excludes as far as `backup` is concerned. Passing only
            // `excludes` here would have every run re-capture exactly what
            // the purge phase had just rewritten out of history.
            command: .backup(
                repo: primary.repoURL,
                sources: set.sources,
                excludes: set.effectiveBackupExcludes
            ),
            invocation: ResticInvocation(destination: primary),
            streamProgress: true,
            preflightPhase: "probing",
            preflight: { [self] logWriter in
                let probe = await reachability.probe(primary)
                logWriter?.appendLine("probe primary \"\(primary.label)\": \(describe(probe))")
                record(probe: probe, for: primary)
                guard probe == .reachable else {
                    return .reason("primary unreachable: \(describe(probe))")
                }
                return nil
            }
        )

        let backup: ChildRun
        switch backupResult {
        case .completed(let child):
            backup = child
        case .deferred(let reason):
            return .infrastructureFailure(reason: reason)
        case .infrastructureFailure(let failure):
            return .infrastructureFailure(reason: failure.reason)
        }
        children.append(backup.child)
        let groupId = backup.child.runId
        if let reason = backup.infrastructureFailureReason {
            infrastructureFailures.append("primary \"\(primary.label)\": \(reason)")
        }

        guard backup.child.status != .failed else {
            // Terminal: no copies, no retention (T09 step 5, scenario 5).
            if !infrastructureFailures.isEmpty {
                return .infrastructureFailure(reason: infrastructureFailures.joined(separator: "; "))
            }
            return .completed(status: .failed, groupId: groupId, children: children)
        }

        // Success or warning (exit 3 — the snapshot exists): the primary is
        // in sync as of now.
        markSynced(primary)

        // A changed purge rule must rewrite the primary before it can be
        // copied anywhere. A failed primary purge terminates the group: a
        // copy would otherwise propagate rewritten snapshots while leaving
        // their originals on an unpurged mirror.
        let primaryPurgePatterns: [String]
        do {
            primaryPurgePatterns = try pendingPurgePatterns(
                setId: set.id,
                set: set,
                destinationId: primary.id
            )
        } catch {
            let reason = "schedule state unusable before purge — \(error)"
            logWarning("BackupEngine: \(reason)")
            return .infrastructureFailure(reason: reason)
        }
        if !primaryPurgePatterns.isEmpty {
            do {
                let purge = try await runAutomaticPurge(
                    set: set,
                    destination: primary,
                    patterns: primaryPurgePatterns,
                    trigger: trigger,
                    groupId: groupId
                )
                children.append(contentsOf: purge.children)
                guard purge.status == .success else {
                    if !infrastructureFailures.isEmpty {
                        return .infrastructureFailure(
                            reason: infrastructureFailures.joined(separator: "; ")
                        )
                    }
                    return .completed(status: .failed, groupId: groupId, children: children)
                }
            } catch {
                logWarning(
                    "BackupEngine: could not purge primary \"\(primary.label)\" before mirroring: \(error)"
                )
                if let reason = Self.purgeInfrastructureFailureReason(error) {
                    infrastructureFailures.append("primary \"\(primary.label)\": \(reason)")
                }
                if !infrastructureFailures.isEmpty {
                    return .infrastructureFailure(
                        reason: infrastructureFailures.joined(separator: "; ")
                    )
                }
                return .completed(status: .failed, groupId: groupId, children: children)
            }
        }

        // ── Step 7: secondaries, in config order ────────────────────────
        for secondary in set.destinations where !secondary.isPrimary {
            let probe = await reachability.probe(secondary)
            record(probe: probe, for: secondary)
            guard probe == .reachable else {
                // Offline mirrors are *expected* (an external disk that is
                // not plugged in). No run record — the UI surfaces this as
                // staleness computed from `lastSyncedAt`
                // (`docs/scheduling.md` §Staleness).
                logWarning(
                    "BackupEngine: skipping secondary \"\(secondary.label)\": \(describe(probe))"
                )
                continue
            }

            // A mirror with stale purge state cannot receive a copy: restic
            // would retain its old snapshots alongside the primary's rewritten
            // replacements. A failed purge skips only this secondary; another
            // mirror can still make a safe copy.
            let secondaryPurgePatterns: [String]
            do {
                secondaryPurgePatterns = try pendingPurgePatterns(
                    setId: set.id,
                    set: set,
                    destinationId: secondary.id
                )
            } catch {
                let reason = "schedule state unusable before purge — \(error)"
                logWarning("BackupEngine: \(reason)")
                return .infrastructureFailure(reason: reason)
            }
            if !secondaryPurgePatterns.isEmpty {
                do {
                    let purge = try await runAutomaticPurge(
                        set: set,
                        destination: secondary,
                        patterns: secondaryPurgePatterns,
                        trigger: trigger,
                        groupId: groupId
                    )
                    children.append(contentsOf: purge.children)
                    guard purge.status == .success else {
                        logWarning(
                            "BackupEngine: purge of secondary \"\(secondary.label)\" did not succeed — skipping copy"
                        )
                        continue
                    }
                } catch {
                    logWarning(
                        "BackupEngine: could not purge secondary \"\(secondary.label)\" before copy: \(error)"
                    )
                    if let reason = Self.purgeInfrastructureFailureReason(error) {
                        infrastructureFailures.append(
                            "secondary \"\(secondary.label)\": \(reason)"
                        )
                    }
                    continue
                }
            }

            let copyResult = await performChild(
                kind: .copy,
                setId: set.id,
                destination: secondary,
                trigger: trigger,
                groupId: groupId,
                phase: "copying-\(secondary.id.uuidString)",
                // `-r` is the DESTINATION, `--from-repo` is the SOURCE.
                command: .copy(toRepo: secondary.repoURL, fromRepo: primary.repoURL),
                invocation: ResticInvocation(destination: secondary, fromDestination: primary),
                streamProgress: false
            )
            let copy: ChildRun
            switch copyResult {
            case .completed(let child):
                copy = child
            case .deferred(let reason):
                infrastructureFailures.append("secondary \"\(secondary.label)\": \(reason)")
                continue
            case .infrastructureFailure(let reason):
                infrastructureFailures.append("secondary \"\(secondary.label)\": \(reason)")
                continue
            }
            children.append(copy.child)
            if let reason = copy.infrastructureFailureReason {
                infrastructureFailures.append("secondary \"\(secondary.label)\": \(reason)")
            }

            // SAFETY: retention on a mirror runs *only* when this run's copy
            // succeeded. A stale mirror plus an aggressive policy is a data
            // loss window — see the invariants on this type.
            guard copy.child.status == .success else {
                logWarning(
                    "BackupEngine: copy to \"\(secondary.label)\" did not succeed — "
                        + "skipping retention on that destination"
                )
                continue
            }
            markSynced(secondary)

            switch await forgetChild(
                destination: secondary,
                policy: set.retention,
                setId: set.id,
                trigger: trigger,
                groupId: groupId
            ) {
            case .completed(let prune):
                children.append(prune.child)
                if let reason = prune.infrastructureFailureReason {
                    infrastructureFailures.append("secondary \"\(secondary.label)\": \(reason)")
                }
            case .infrastructureFailure(let reason):
                infrastructureFailures.append("secondary \"\(secondary.label)\": \(reason)")
            case .deferred:
                break
            case .notRequired:
                break
            }
        }

        // ── Step 8: retention on the primary ────────────────────────────
        switch await forgetChild(
            destination: primary,
            policy: set.retention,
            setId: set.id,
            trigger: trigger,
            groupId: groupId
        ) {
        case .completed(let prune):
            children.append(prune.child)
            if let reason = prune.infrastructureFailureReason {
                infrastructureFailures.append("primary \"\(primary.label)\": \(reason)")
            }
        case .infrastructureFailure(let reason):
            infrastructureFailures.append("primary \"\(primary.label)\": \(reason)")
        case .deferred:
            break
        case .notRequired:
            break
        }

        // ── Step 9: current-run cleared and lock released by the defers ─
        if !infrastructureFailures.isEmpty {
            return .infrastructureFailure(reason: infrastructureFailures.joined(separator: "; "))
        }
        return .completed(
            status: Self.worstStatus(children.map(\.status)),
            groupId: groupId,
            children: children
        )
    }

    // MARK: - runCheck

    /// One scheduled integrity check: `--read-data-subset=n/t` against the
    /// primary with `n` rotating through the slice cursor, plus a
    /// structure-only check of every reachable secondary on every
    /// ``secondaryCheckEveryNChecks``th successful check
    /// (`docs/scheduling.md` §Check scheduling).
    ///
    /// `checkSliceCursor` (and the secondary-rotation counter) are persisted
    /// **only** when the primary check succeeded — a failed check must
    /// re-verify the same slice next time rather than skip past it.
    ///
    /// Returns a ``CheckRunOutcome`` so callers cannot confuse a repository
    /// check that ran and failed with lock or schedule-state infrastructure
    /// that prevented a safe attempt. `run-set --kind check` passes
    /// ``RunTrigger/manual`` so the run record reflects a manual trigger.
    public func runCheck(_ set: BackupSet, trigger: RunTrigger = .scheduled) async -> CheckRunOutcome {
        guard let primary = set.destinations.first(where: { $0.isPrimary }) else {
            let reason = "backup set \"\(set.name)\" has no primary destination"
            logWarning("BackupEngine: \(reason) — cannot check")
            return .misconfigured(reason: reason)
        }
        guard await secretsAvailable(for: [primary]) else {
            return .retryable(reason: "the secret store is unavailable")
        }

        let (lock, acquisition) = acquireSetLock(setId: set.id)
        switch acquisition {
        case .acquired:
            break
        case .busy:
            recordSkipped(kind: .check, setId: set.id, destId: primary.id, trigger: trigger)
            return .skipped
        case .failed(let failure):
            recordLockFailure(
                kind: .check, setId: set.id, destId: primary.id, trigger: trigger, failure: failure
            )
            return .infrastructureFailure(reason: "backup-set lock unusable — \(failure)")
        }
        defer { lock.release() }
        // Declared after the lock defer, so it unwinds *first*: the live
        // progress record is removed while the lock is still held, on every
        // exit path (T09 step 8 — "clear current-run, release lock").
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        // Attempt semantics, exactly like `lastBackupStart`.
        let updatedScheduleState: ScheduleState
        do {
            updatedScheduleState = try updateScheduleState(setId: set.id) {
                $0.lastCheckStart = self.now()
            }
        } catch {
            let reason = "schedule state unusable — \(error)"
            recordInfrastructureFailure(
                kind: .check,
                setId: set.id,
                destId: primary.id,
                trigger: trigger,
                reason: reason
            )
            return .infrastructureFailure(reason: reason)
        }

        let totalSlices = set.checkPolicy?.readDataSubsetSlices ?? Self.defaultCheckSlices
        let previousState = updatedScheduleState.sets[set.id]
        let slice = ScheduleMath.nextCheckSlice(
            cursor: previousState?.checkSliceCursor ?? 0,
            totalSlices: totalSlices
        )
        let checkCount = (previousState?.checkCount ?? 0) + 1

        let primaryCheckResult = await performChild(
            kind: .check,
            setId: set.id,
            destination: primary,
            trigger: trigger,
            groupId: nil,
            phase: "checking",
            command: .check(repo: primary.repoURL, readDataSubset: "\(slice.n)/\(totalSlices)"),
            invocation: ResticInvocation(destination: primary),
            streamProgress: false
        )
        let primaryCheck: ChildRun
        switch primaryCheckResult {
        case .completed(let child):
            primaryCheck = child
        case .deferred(let reason):
            return .infrastructureFailure(reason: reason)
        case .infrastructureFailure(let failure):
            return .infrastructureFailure(reason: failure.reason)
        }
        var statuses = [primaryCheck.child.status]
        var infrastructureFailures: [String] = []
        if let reason = primaryCheck.infrastructureFailureReason {
            infrastructureFailures.append("primary \"\(primary.label)\": \(reason)")
        }

        if primaryCheck.child.status == .success {
            // SAFETY: cursor advances only on success.
            do {
                try updateScheduleState(setId: set.id) { state in
                    state.checkSliceCursor = slice.newCursor
                    state.checkCount = checkCount
                }
            } catch {
                let reason = "could not persist the successful check cursor — \(error)"
                logWarning("BackupEngine: \(reason)")
                return .infrastructureFailure(reason: reason)
            }

            if checkCount % Self.secondaryCheckEveryNChecks == 0 {
                for secondary in set.destinations where !secondary.isPrimary {
                    let probe = await reachability.probe(secondary)
                    record(probe: probe, for: secondary)
                    guard probe == .reachable else { continue }
                    let secondaryCheckResult = await performChild(
                        kind: .check,
                        setId: set.id,
                        destination: secondary,
                        trigger: trigger,
                        groupId: primaryCheck.child.runId,
                        phase: "checking",
                        // Structure-only: no `--read-data-subset`.
                        command: .check(repo: secondary.repoURL),
                        invocation: ResticInvocation(destination: secondary),
                        streamProgress: false
                    )
                    switch secondaryCheckResult {
                    case .completed(let secondaryCheck):
                        statuses.append(secondaryCheck.child.status)
                        if let reason = secondaryCheck.infrastructureFailureReason {
                            infrastructureFailures.append(
                                "secondary \"\(secondary.label)\": \(reason)"
                            )
                        }
                    case .infrastructureFailure(let reason):
                        infrastructureFailures.append(
                            "secondary \"\(secondary.label)\": \(reason)"
                        )
                    case .deferred(let reason):
                        infrastructureFailures.append(
                            "secondary \"\(secondary.label)\": \(reason)"
                        )
                    }
                }
            }
        }

        if !infrastructureFailures.isEmpty {
            return .infrastructureFailure(reason: infrastructureFailures.joined(separator: "; "))
        }
        return .completed(Self.worstStatus(statuses))
    }

    // MARK: - runPrune

    /// The manual "apply retention now" action — **contained**: refuses
    /// before touching anything. No secret read, no set lock, no executable
    /// resolution, no run record, no subprocess. See
    /// ``ManualRetentionApplyAvailability`` for why, and for what still
    /// applies retention while this is closed.
    ///
    /// The helper refuses earlier still — before it even builds a context —
    /// so this is defense in depth for a direct Core caller, not the only
    /// gate. The destructive contract lives on ``runPruneUnchecked``, the
    /// function that actually implements it.
    public func runPrune(
        _ set: BackupSet,
        expectedExecutableIdentity: String? = nil
    ) async -> ManualRunOutcome {
        guard ManualRetentionApplyAvailability.isEnabled else {
            return .operationNotAllowed(reason: ManualRetentionApplyAvailability.reason)
        }
        return await runPruneUnchecked(
            set,
            expectedExecutableIdentity: expectedExecutableIdentity
        )
    }

    /// The manual-retention mechanics, minus the containment gate:
    /// `forget --prune` on the primary and on every secondary that is
    /// **not** a stale mirror.
    ///
    /// SAFETY: a secondary is pruned only when its `lastSyncedAt` is at least
    /// as recent as the primary's (the end of the primary's last successful
    /// backup). A mirror that has not received the newest snapshots must
    /// never have an aggressive policy applied to it — that is exactly the
    /// data-loss window invariant 2 describes. When the primary has never
    /// synced, no secondary is pruned. Any new caller — including the
    /// #111/#82 re-enablement — inherits this obligation; skipping the
    /// freshness loop reintroduces the data-loss window.
    ///
    /// A dry run first is the UI's job (`ResticCommand.forget(dryRun:)`);
    /// this is the real one.
    /// `expectedExecutableIdentity` binds every `forget --prune` this call
    /// makes to one restic binary. It is what makes the caller's fingerprint
    /// check more than advisory: validating the executable and then launching
    /// unpinned leaves a window — across the lock acquisition and every
    /// earlier destination — in which a replacement receives the destructive
    /// command instead. `nil` means the caller made no such promise, which
    /// is the scheduled path; a *bound* caller must pass a real identity and
    /// refuse if it cannot read one — see `RunSet`.
    ///
    /// `internal` on purpose: reachable from the tests that cover mirror
    /// freshness, executable pinning and run recording, and from nothing
    /// that ships. Do not add a public caller — the gate above is the only
    /// supported entry point.
    func runPruneUnchecked(
        _ set: BackupSet,
        expectedExecutableIdentity: String? = nil
    ) async -> ManualRunOutcome {
        guard let primary = set.destinations.first(where: { $0.isPrimary }) else {
            logWarning("BackupEngine: backup set \"\(set.name)\" has no primary destination — cannot prune")
            return .completed(.failed)
        }
        guard let retention = set.retention, !retention.isEmpty else {
            // First half of the double guard: no policy, no forget, ever.
            logWarning(
                "BackupEngine: backup set \"\(set.name)\" has no retention policy — nothing to apply"
            )
            return .skipped
        }
        guard await secretsAvailable(for: [primary]) else { return .skipped }

        let (lock, acquisition) = acquireSetLock(setId: set.id)
        switch acquisition {
        case .acquired:
            break
        case .busy:
            recordSkipped(kind: .prune, setId: set.id, destId: primary.id, trigger: .manual)
            return .skipped
        case .failed(let failure):
            recordLockFailure(
                kind: .prune, setId: set.id, destId: primary.id, trigger: .manual, failure: failure
            )
            return .infrastructureFailure(reason: failure.description, operationMayHaveRun: false)
        }
        defer { lock.release() }
        // Declared after the lock defer, so it unwinds *first*: the live
        // progress record is removed while the lock is still held, on every
        // exit path (T09 step 8 — "clear current-run, release lock").
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        // One manual retention request is one destructive transaction across
        // the primary and every eligible mirror. Holding the machine-wide
        // gate for the full pass prevents another helper from entering after
        // the primary has already been pruned and turning a partial request
        // into an apparent success.
        do {
            try paths.ensureDirectories()
        } catch {
            return .infrastructureFailure(
                reason: "run history unusable — could not prepare the destructive audit gate: \(error)",
                operationMayHaveRun: false
            )
        }
        let destructiveAuditGate = FileLock(
            path: paths.destructiveAuditLockFile,
            trustedRoot: paths.root
        )
        switch destructiveAuditGate.acquire() {
        case .acquired:
            break
        case .busy:
            return .skipped
        case .failed(let failure):
            return .infrastructureFailure(reason: failure.description, operationMayHaveRun: false)
        }
        defer { destructiveAuditGate.release() }

        let primaryPruneResult = await forgetChild(
            destination: primary,
            policy: retention,
            setId: set.id,
            trigger: .manual,
            groupId: nil,
            expectedExecutableIdentity: expectedExecutableIdentity,
            callerHoldsDestructiveAuditGate: true
        )
        let primaryPrune: ChildRun
        switch primaryPruneResult {
        case .completed(let child):
            primaryPrune = child
        case .deferred:
            return .skipped
        case .infrastructureFailure(let failure):
            return .infrastructureFailure(
                reason: failure.reason,
                operationMayHaveRun: false
            )
        case .notRequired:
            // The public guard above already requires a non-empty policy.
            return .skipped
        }
        if let reason = primaryPrune.infrastructureFailureReason {
            return .infrastructureFailure(reason: reason, operationMayHaveRun: true)
        }
        var statuses = [primaryPrune.child.status]
        let groupId = primaryPrune.child.runId

        let primarySyncedAt = stateStore.readRepoStatus(destId: primary.id)?.lastSyncedAt
        for secondary in set.destinations where !secondary.isPrimary {
            guard let primarySyncedAt else {
                logWarning(
                    "BackupEngine: the primary has never completed a backup — "
                        + "refusing to apply retention to mirror \"\(secondary.label)\""
                )
                continue
            }
            guard let mirrorSyncedAt = stateStore.readRepoStatus(destId: secondary.id)?.lastSyncedAt,
                  mirrorSyncedAt >= primarySyncedAt else {
                logWarning(
                    "BackupEngine: mirror \"\(secondary.label)\" is behind the primary — "
                        + "refusing to apply retention to it"
                )
                continue
            }
            switch await forgetChild(
                destination: secondary,
                policy: retention,
                setId: set.id,
                trigger: .manual,
                groupId: groupId,
                expectedExecutableIdentity: expectedExecutableIdentity,
                callerHoldsDestructiveAuditGate: true
            ) {
            case .completed(let prune):
                if let reason = prune.infrastructureFailureReason {
                    return .infrastructureFailure(reason: reason, operationMayHaveRun: true)
                }
                statuses.append(prune.child.status)
            case .infrastructureFailure(let failure):
                return .infrastructureFailure(
                    reason: failure.reason,
                    // The primary prune, and possibly earlier mirrors, have
                    // already executed by the time this later record fails.
                    operationMayHaveRun: true
                )
            case .deferred:
                return .completed(Self.worstStatus(statuses))
            case .notRequired:
                // The public guard above already requires a non-empty policy.
                continue
            }
        }

        return .completed(Self.worstStatus(statuses))
    }

    /// Reclaims unreferenced repository data without changing snapshot
    /// retention. Unlike ``runPrune(_:)``, this is valid for a set with no
    /// retention policy: `rewrite --forget` can leave unused packs behind
    /// even when the set intentionally keeps every remaining snapshot.
    ///
    /// A secondary is still protected by the same freshness invariant as
    /// retention pruning. Never prune a mirror that predates the primary's
    /// last successful backup: it may be the only repository still holding
    /// snapshots the primary has already changed or forgotten.
    public func runPruneRepository(
        set: BackupSet,
        destination: Destination,
        destinationSecretEnv: [String: String]? = nil,
        authorization: MaintenancePruneAuthorization? = nil,
        resticExecutablePath: String? = nil,
        resticExecutableIdentity: String? = nil,
        dryRun: Bool = false
    ) async -> PruneRepositoryResult {
        guard set.destinations.contains(where: { $0.id == destination.id }) else {
            logWarning("BackupEngine: destination \(destination.id) is not in backup set \(set.id) — cannot prune")
            return .failed(.didNotRun)
        }
        guard await secretsAvailable(for: [destination]) else { return .skipped(.secretUnavailable) }
        let executablePath = authorization?.resticExecutablePath ?? resticExecutablePath
        let executableIdentity = authorization?.resticExecutableIdentity ?? resticExecutableIdentity

        let (lock, acquisition) = acquireSetLock(setId: set.id)
        switch acquisition {
        case .acquired:
            break
        case .busy:
            // A preview is an unrecorded read-only query, even when it is
            // refused because another set operation holds the lock. Recording
            // that refusal as a prune would replace the last real cleanup in
            // status/history despite no restic prune having run.
            if !dryRun {
                recordSkipped(kind: .prune, setId: set.id, destId: destination.id, trigger: .manual)
            }
            return .skipped(.busy)
        case .failed(let failure):
            // A dry run stays unrecorded for the reason above, but the
            // refusal itself is a fault rather than contention, so it is
            // reported as one either way.
            if !dryRun {
                recordLockFailure(
                    kind: .prune, setId: set.id, destId: destination.id, trigger: .manual, failure: failure
                )
            } else {
                logWarning("BackupEngine: cannot acquire the set lock: \(failure)")
            }
            return .failed(.infrastructure("backup-set lock unusable — \(failure)"))
        }
        defer { lock.release() }
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        // Read both timestamps only while the set lock is held. A backup can
        // advance the primary and leave a mirror behind, so checking before
        // lock acquisition would create a prune-after-stale race.
        if !destination.isPrimary {
            guard let primary = set.destinations.first(where: { $0.isPrimary }),
                  let primarySyncedAt = stateStore.readRepoStatus(destId: primary.id)?.lastSyncedAt,
                  let mirrorSyncedAt = stateStore.readRepoStatus(destId: destination.id)?.lastSyncedAt,
                  mirrorSyncedAt >= primarySyncedAt else {
                logWarning(
                    "BackupEngine: mirror \"\(destination.label)\" is behind the primary — refusing to prune it"
                )
                return .skipped(.staleMirror)
            }
        }

        let consumePreviewToken: (@Sendable () throws -> Void)?
        let restorePreviewToken: (@Sendable () -> Void)?
        if let authorization {
            let previewTokens = previewTokens
            let token = authorization.token
            let machineId = authorization.machineId
            let effectiveDestinationFingerprint = authorization.effectiveDestinationFingerprint
            let setId = set.id
            let destinationId = destination.id
            consumePreviewToken = {
                try previewTokens.consumeMaintenancePrune(
                    token,
                    machineId: machineId,
                    setId: setId,
                    destinationId: destinationId,
                    effectiveDestinationFingerprint: effectiveDestinationFingerprint
                )
            }
            restorePreviewToken = {
                // A restore failure intentionally leaves the token consumed:
                // retrying a destructive action is never safer than asking
                // for a fresh preview when capability storage is unavailable.
                try? previewTokens.restoreMaintenancePrune(
                    token,
                    machineId: machineId,
                    setId: setId,
                    destinationId: destinationId,
                    effectiveDestinationFingerprint: effectiveDestinationFingerprint
                )
            }
        } else {
            consumePreviewToken = nil
            restorePreviewToken = nil
        }

        if destination.remoteMaintenance?.enabled == true {
            guard let operands = destination.remoteMaintenanceOperands() else {
                return .failed(.didNotRun)
            }
            let remote = RemoteResticCommand(
                sshTarget: operands.sshTarget,
                resticPath: operands.resticPath,
                repoPath: operands.repoPath,
                dryRun: dryRun
            )
            do {
                _ = try await restic.verifyRemoteMaintenance(.version(sshTarget: operands.sshTarget, resticPath: operands.resticPath))
            } catch {
                return .failed(.didNotRun)
            }
            if dryRun {
                do {
                    let outcome = try await restic.runRemoteMaintenance(remote, destination: destination)
                    return outcome.status == .success ? .completed(.success) : .failed(.restic(outcome.status))
                } catch {
                    return .failed(.didNotRun)
                }
            }

            let pruneResult = await performChild(
                kind: .prune, setId: set.id, destination: destination, trigger: .manual, groupId: nil,
                phase: "remote pruning", command: .prune(repo: destination.repoURL),
                invocation: ResticInvocation(destination: destination), streamProgress: false,
                remoteCommand: remote,
                preflightPhase: authorization == nil ? nil : "validating preview",
                beforeLaunch: consumePreviewToken,
                afterLaunchFailure: restorePreviewToken
            )
            let prune: ChildRun
            switch pruneResult {
            case .completed(let child):
                prune = child
            case .deferred:
                return .skipped(.busy)
            case .infrastructureFailure(let failure):
                if let runId = failure.auditRunId {
                    return .failed(.auditInfrastructure(reason: failure.reason, runId: runId))
                }
                return .failed(.infrastructure(failure.reason))
            }
            if let failure = prune.infrastructureFailure {
                if let runId = failure.auditRunId {
                    return .failed(.auditInfrastructure(reason: failure.reason, runId: runId))
                }
                return .failed(.infrastructure(failure.reason))
            }
            switch prune.preflightFailure {
            case .previewChanged:
                return .skipped(.previewChanged)
            case .previewExpired:
                return .skipped(.previewExpired)
            case .previewUnavailable:
                return .skipped(.previewUnavailable)
            case .storeUnusable(let detail):
                return .failed(.infrastructure("preview-token store unusable — \(detail)"))
            case .reason, .none:
                break
            }
            guard prune.child.status == .failed else { return .completed(prune.child.status) }
            if let outcome = prune.outcome {
                return .failed(.restic(outcome.status))
            }
            return .failed(.didNotRun)
        }

        let probe = await reachability.probe(
            destination,
            destinationSecretEnv: destinationSecretEnv
        )
        record(probe: probe, for: destination)
        switch probe {
        case .reachable:
            break
        case .offline(let reason):
            return .failed(.offline(reason))
        case .error(let exitClass):
            return .failed(.restic(exitClass))
        }

        if dryRun {
            // A preview is a read-only query. Like the app-direct retention
            // preview, it must not replace the last real prune in history or
            // make the Runs screen claim that pack space was reclaimed.
            switch await execute(
                .prune(repo: destination.repoURL, dryRun: true),
                invocation: ResticInvocation(
                    destination: destination,
                    destinationSecretEnv: destinationSecretEnv,
                    resticPathOverride: executablePath,
                    expectedExecutableIdentity: executableIdentity
                ),
                logWriter: nil,
                reporter: nil
            ) {
            case .ranToCompletion(let outcome):
                switch outcome.status {
                case .success:
                    return .completed(.success)
                case .warningIncompleteRead:
                    return .completed(.warning)
                case .fatal, .repoDoesNotExist, .repoLocked, .wrongPassword, .other:
                    // Every failing exit class keeps its own identity in the
                    // typed result; enumerated (no `default`) so a new
                    // `ResticExitClass` case must choose a lane here.
                    return .failed(.restic(outcome.status))
                }
            case .didNotRun:
                return .failed(.didNotRun)
            }
        }

        let pruneResult = await performChild(
            kind: .prune,
            setId: set.id,
            destination: destination,
            trigger: .manual,
            groupId: nil,
            phase: "pruning",
            command: .prune(repo: destination.repoURL, dryRun: false),
            invocation: ResticInvocation(
                destination: destination,
                destinationSecretEnv: destinationSecretEnv,
                resticPathOverride: executablePath,
                expectedExecutableIdentity: executableIdentity
            ),
            streamProgress: false,
            preflightPhase: authorization == nil ? nil : "validating preview",
            beforeLaunch: consumePreviewToken,
            afterLaunchFailure: restorePreviewToken
        )
        let prune: ChildRun
        switch pruneResult {
        case .completed(let child):
            prune = child
        case .deferred:
            return .skipped(.busy)
        case .infrastructureFailure(let failure):
            if let runId = failure.auditRunId {
                return .failed(.auditInfrastructure(reason: failure.reason, runId: runId))
            }
            return .failed(.infrastructure(failure.reason))
        }
        if let failure = prune.infrastructureFailure {
            if let runId = failure.auditRunId {
                return .failed(.auditInfrastructure(reason: failure.reason, runId: runId))
            }
            return .failed(.infrastructure(failure.reason))
        }
        switch prune.preflightFailure {
        case .previewChanged:
            return .skipped(.previewChanged)
        case .previewExpired:
            return .skipped(.previewExpired)
        case .previewUnavailable:
            return .skipped(.previewUnavailable)
        case .storeUnusable(let detail):
            return .failed(.infrastructure("preview-token store unusable — \(detail)"))
        case .reason, .none:
            break
        }
        guard prune.child.status == .failed else { return .completed(prune.child.status) }
        if let outcome = prune.outcome {
            return .failed(.restic(outcome.status))
        }
        return .failed(.didNotRun)
    }

    // MARK: - purge preview

    /// Builds a read-only purge plan for one destination.
    ///
    /// The set lock prevents a preview from racing a backup or another
    /// repository operation.  The only restic commands are reachability's
    /// `cat config` where needed, `snapshots --json`, and `rewrite --dry-run`.
    /// In particular, this method cannot reach `rewrite --forget`, `prune`, or
    /// the run-record machinery.
    ///
    /// `executable` is the binary this preview is *attributed to*: both
    /// queries are pinned to it, so a transcript can only be produced by the
    /// program the resulting token will name.  Deliberately not resolved
    /// here — one preview pass over several destinations must be one binary,
    /// which only the caller above can guarantee, so
    /// ``previewPurgeSession(set:destinations:)`` is the entry point and
    /// this is internal (#118).
    func previewPurge(
        set: BackupSet,
        destination: Destination,
        executable: ResticRunner.MaintenanceExecutable
    ) async -> PurgePlanResult {
        let emptyPlan = PurgePlan(
            destinationId: destination.id,
            snapshots: [],
            sourcePaths: sourcePaths(for: set),
            hostnames: hostnames(for: set),
            patterns: set.purgeExcludes
        )

        guard !set.purgeExcludes.isEmpty else {
            return PurgePlanResult(
                plan: emptyPlan,
                status: .empty,
                message: "nothing to purge: purgeExcludes is empty"
            )
        }

        let (lock, acquisition) = acquireSetLock(setId: set.id)
        switch acquisition {
        case .acquired:
            break
        case .busy:
            return PurgePlanResult(plan: emptyPlan, status: .busy, message: "another operation is running")
        case .failed(let failure):
            logWarning("BackupEngine: cannot acquire the set lock: \(failure)")
            return PurgePlanResult(
                plan: emptyPlan,
                status: .infrastructureFailure,
                message: "backup-set lock unusable — \(failure)"
            )
        }
        defer { lock.release() }

        guard await secretsAvailable(for: [destination]) else {
            return PurgePlanResult(plan: emptyPlan, status: .failed, message: "secret store unavailable")
        }

        let probe = await reachability.probe(
            destination,
            expectedExecutableIdentity: executable.identity
        )
        switch probe {
        case .reachable:
            break
        case .offline(let reason):
            return PurgePlanResult(
                plan: emptyPlan,
                status: .offline,
                message: reason
            )
        case .error(let exitClass):
            return PurgePlanResult(
                plan: emptyPlan,
                status: .failed,
                message: exitClass.userFacingMessage
            )
        }

        let snapshotsOutcome: ResticOutcome
        do {
            snapshotsOutcome = try await restic.run(
                .snapshots(repo: destination.repoURL),
                for: ResticInvocation(
                    destination: destination,
                    expectedExecutableIdentity: executable.identity
                )
            )
        } catch {
            return PurgePlanResult(plan: emptyPlan, status: .failed, message: "could not list snapshots: \(error)")
        }
        guard snapshotsOutcome.status == .success else {
            return PurgePlanResult(
                plan: emptyPlan,
                status: .failed,
                message: snapshotsOutcome.status.userFacingMessage
            )
        }

        let snapshots: [Snapshot]
        do {
            snapshots = try parseSnapshots(Data(snapshotsOutcome.rawOutput.utf8))
        } catch {
            return PurgePlanResult(plan: emptyPlan, status: .failed, message: "could not parse snapshots: \(error)")
        }

        let plan = PurgePlan(
            destinationId: destination.id,
            snapshots: snapshots,
            sourcePaths: sourcePaths(for: set),
            hostnames: hostnames(for: set),
            patterns: set.purgeExcludes
        )
        guard !plan.matched.isEmpty else {
            return PurgePlanResult(
                plan: plan,
                status: .ready,
                message: "no snapshots are attributed to this backup set"
            )
        }

        let rewriteOutcome: ResticOutcome
        do {
            rewriteOutcome = try await restic.run(
                .rewrite(
                    repo: destination.repoURL,
                    snapshotIDs: plan.matched.map(\.id),
                    excludes: plan.patterns,
                    dryRun: true
                ),
                for: ResticInvocation(
                    destination: destination,
                    expectedExecutableIdentity: executable.identity
                )
            )
        } catch {
            return PurgePlanResult(plan: plan, status: .failed, message: "could not preview rewrite: \(error)")
        }
        guard rewriteOutcome.status == .success else {
            return PurgePlanResult(
                plan: plan,
                status: .failed,
                message: rewriteOutcome.status.userFacingMessage
            )
        }

        let rewrite = parseRewrite(rewriteOutcome.rawOutput)
        let changed = plan.matched.filter { rewrite.changedShortIDs.contains($0.shortId) }
        return PurgePlanResult(plan: plan, changed: changed, rewrite: rewrite, status: .ready)
    }

    /// Previews a purge across `destinations` and mints the capability for
    /// what it found — the only public way to obtain a purge token.
    ///
    /// The restic executable is resolved **once, before the first query**,
    /// and that one identity pins every preview command and binds the token.
    /// #109 bound the token to the executable observed *after* the previews
    /// had run, which left a real gap: a binary replaced between the last
    /// dry-run and issuance produced a transcript from one program and a
    /// capability naming another.  Multi-destination made that window wide
    /// rather than theoretical, because issuance waited for every
    /// destination's network round trips (#118).
    ///
    /// A destination that does not finish its preview ends the pass with no
    /// token: a capability must never describe a plan the operator could not
    /// be shown in full.  The caller still sees the partial results and
    /// reports the failure from them.
    public func previewPurgeSession(
        set: BackupSet,
        destinations: [Destination]
    ) async throws -> PurgePreviewSession {
        // Preserve the no-op contract without making restic itself a
        // prerequisite. There is no query to attribute and no destructive
        // capability to mint when the policy is empty.
        guard !set.purgeExcludes.isEmpty else {
            return PurgePreviewSession(
                previews: destinations.map { destination in
                    let plan = PurgePlan(
                        destinationId: destination.id,
                        snapshots: [],
                        sourcePaths: sourcePaths(for: set),
                        hostnames: hostnames(for: set),
                        patterns: []
                    )
                    return PurgePreviewSession.DestinationPreview(
                        destination: destination,
                        result: PurgePlanResult(
                            plan: plan,
                            status: .empty,
                            message: "nothing to purge: purgeExcludes is empty"
                        )
                    )
                },
                token: nil
            )
        }
        // Before any query, so there is no window in which a preview could
        // have been produced by a binary this pass never identified.
        guard let executable = restic.maintenanceExecutable() else {
            throw PurgeApplyError.resticUnavailable
        }
        var previews: [PurgePreviewSession.DestinationPreview] = []
        for destination in destinations {
            let result = await previewPurge(set: set, destination: destination, executable: executable)
            previews.append(PurgePreviewSession.DestinationPreview(destination: destination, result: result))
            switch result.status {
            case .empty, .ready:
                continue
            case .busy, .offline, .infrastructureFailure, .failed:
                return PurgePreviewSession(previews: previews, token: nil)
            }
        }
        return PurgePreviewSession(
            previews: previews,
            token: try issuePurgeToken(
                set: set,
                destinations: previews.map(\.destination),
                plans: previews.map(\.result.plan),
                executable: executable
            )
        )
    }

    /// Stores the approved result of one or more successful purge previews.
    /// An empty plan gets no capability: there is nothing destructive to do.
    ///
    /// `executable` is passed in rather than resolved, so this cannot bind a
    /// capability to a binary that did not produce `plans`.  Internal for the
    /// same reason ``previewPurge`` is: the pairing is the guarantee.
    func issuePurgeToken(
        set: BackupSet,
        destinations: [Destination],
        plans: [PurgePlan],
        executable: ResticRunner.MaintenanceExecutable
    ) throws -> PreviewToken? {
        guard !set.purgeExcludes.isEmpty, destinations.count == plans.count else { return nil }
        guard Set(plans.map(\.destinationId)).count == plans.count else { return nil }
        let plansByDestination = Dictionary(uniqueKeysWithValues: plans.map { ($0.destinationId, $0) })
        guard destinations.allSatisfy({ plansByDestination[$0.id]?.patterns == set.purgeExcludes }) else {
            return nil
        }
        let tokenDestinations = destinations.compactMap { destination -> PreviewTokenDestination? in
            guard let plan = plansByDestination[destination.id] else { return nil }
            return PreviewTokenDestination(
                destinationId: destination.id,
                snapshotIDs: plan.matched.map(\.id)
            )
        }
        guard tokenDestinations.contains(where: { !$0.snapshotIDs.isEmpty }) else { return nil }
        // Wrapped exactly as `runPurgeLocked` wraps its own token reads. A
        // bare `PreviewTokenError` means nothing to `classifyPurgeOperation`,
        // so an unusable confirmation store reached the operator as
        // `internal_error` — losing the specific "check the permissions on
        // the data directory" advice #117 added, on the one path where the
        // store is being *written* and is therefore likeliest to be broken.
        do {
            return try previewTokens.issue(
                machineId: machineId,
                setId: set.id,
                destinations: tokenDestinations,
                config: config,
                patterns: set.purgeExcludes,
                executableIdentity: executable.identity
            )
        } catch let error as PreviewTokenError {
            throw PurgeApplyError.token(error)
        }
    }

    /// Lets the helper choose exactly the destinations an opaque token bound.
    /// It does not consume the token; `runPurge` rechecks and consumes it
    /// under the set lock immediately before the first destructive command.
    public func purgeTokenDestinationIDs(_ token: String) throws -> [UUID] {
        do {
            return try previewTokens.token(token).destinations.map(\.destinationId)
        } catch let error as PreviewTokenError {
            throw PurgeApplyError.token(error)
        } catch {
            throw PurgeApplyError.unavailable
        }
    }

    /// Applies a previously reviewed purge preview.  The token is validated
    /// against this machine, resolved config, selected destinations, patterns
    /// and fresh repository snapshot attribution before it is consumed.
    public func runPurge(
        set: BackupSet,
        destinations: [Destination],
        token: String
    ) async throws -> PurgeRunResult {
        let (lock, acquisition) = acquireSetLock(setId: set.id)
        switch acquisition {
        case .acquired:
            break
        case .busy:
            throw PurgeApplyError.busy
        case .failed(let failure):
            // Not `.busy`: the caller retries a busy purge, and retrying a
            // broken lock directory forever is the silent-stop failure this
            // whole change is about.
            throw PurgeApplyError.lockUnusable(String(describing: failure))
        }
        defer { lock.release() }
        defer { try? stateStore.clearCurrentRun(setId: set.id) }
        return try await runPurgeLocked(
            set: set,
            destinations: destinations,
            token: token,
            trigger: .manual,
            groupId: nil
        )
    }

    /// `runSet` owns the set lock already, so automatic purge reaches this
    /// private path after minting an equally constrained local token.
    private func runPurgeLocked(
        set: BackupSet,
        destinations: [Destination],
        token: String,
        trigger: RunTrigger,
        groupId: String?
    ) async throws -> PurgeRunResult {
        // Bind the watermark evidence through repository validation, every
        // destructive launch, and the matching durable acknowledgement. The
        // schedule-state lock is process-wide (unlike the per-set lock), so a
        // different set cannot replace the shared document in that window.
        let scheduleStateLease: LockedScheduleState
        do {
            scheduleStateLease = try stateStore.lockScheduleState()
        } catch {
            throw PurgeApplyError.infrastructureFailure(
                reason: "schedule state unusable before purge — \(error)",
                operationMayHaveRun: false
            )
        }
        defer { scheduleStateLease.release() }

        let preview: PreviewToken
        do {
            preview = try previewTokens.token(token)
        } catch let error as PreviewTokenError {
            throw PurgeApplyError.token(error)
        } catch {
            throw PurgeApplyError.unavailable
        }

        let requestedIds = Set(destinations.map(\.id))
        let tokenIds = Set(preview.destinations.map(\.destinationId))
        // Resolved once and carried all the way to the launch, so the value
        // that is validated is the value that runs — and *required*, because
        // a nil on both sides used to compare equal while binding nothing.
        guard let executable = restic.maintenanceExecutable() else {
            throw PurgeApplyError.resticUnavailable
        }
        let fingerprint: String
        do {
            // Recomputed here, from the executable this process would
            // actually run: a token issued against a different restic binary
            // must not authorize a rewrite by this one.
            fingerprint = try PreviewTokenStore.purgeFingerprint(
                config,
                executableIdentity: executable.identity
            )
        } catch {
            throw PurgeApplyError.unavailable
        }
        guard preview.machineId == machineId,
              preview.setId == set.id,
              requestedIds == tokenIds,
              preview.configFingerprint == fingerprint,
              Set(preview.patterns).isSubset(of: Set(set.purgeExcludes)) else {
            throw PurgeApplyError.tokenDoesNotMatchCurrentPlan
        }

        // The automatic planner reads pending patterns before it can acquire
        // this process-wide lease. Recompute each destination's narrower
        // pending subset here, at the point of use: destinations legitimately
        // diverge when one was offline, and a peer may also have completed
        // one destination in the meantime. Already-applied pairs are skipped;
        // no preview pattern may be widened or repeated for that destination.
        var pendingPatternsByDestination: [UUID: [String]] = [:]
        for destination in destinations {
            let applied = Set(
                scheduleStateLease.state.sets[set.id]?
                    .appliedPurgeExcludes[destination.id] ?? []
            )
            pendingPatternsByDestination[destination.id] = preview.patterns.filter {
                !applied.contains($0)
            }
        }
        let pendingDestinations = destinations.filter {
            !(pendingPatternsByDestination[$0.id] ?? []).isEmpty
        }
        guard !pendingDestinations.isEmpty else {
            throw PurgeApplyError.tokenDoesNotMatchCurrentPlan
        }

        guard await secretsAvailable(for: pendingDestinations) else {
            throw PurgeApplyError.unavailable
        }

        // Acquire the machine-wide destructive gate before the final live
        // repository observations, not merely before spending the token.
        // Sets may share a repository; without this boundary another helper
        // could mutate it after validation but before this apply launches.
        // Holding it across the complete multi-destination apply also
        // prevents another destructive helper from entering between children.
        // Contention is retryable and leaves the reviewed token intact.
        do {
            try paths.ensureDirectories()
        } catch {
            throw PurgeApplyError.lockUnusable(String(describing: error))
        }
        let destructiveAuditGate = FileLock(
            path: paths.destructiveAuditLockFile,
            trustedRoot: paths.root
        )
        switch destructiveAuditGate.acquire() {
        case .acquired:
            break
        case .busy:
            throw PurgeApplyError.busy
        case .failed(let failure):
            throw PurgeApplyError.lockUnusable(String(describing: failure))
        }
        defer { destructiveAuditGate.release() }

        // A gate holder that has not launched anything must not make an
        // abandoned record with a recycled PID look active to health scans.
        // Verify immediately after acquisition, before potentially slow
        // repository revalidation queries, and keep the existing
        // performChild check as the final launch-boundary defense.
        do {
            if let unresolved = try runStore.unresolvedAuditFailures(
                callerHoldsDestructiveAuditGate: true
            ).first {
                let reason = "operation_completed_audit_failed — destructive run "
                    + "\(unresolved.runId) has unresolved \(unresolved.reason.rawValue) audit evidence; "
                    + "inspect and reconcile run history before retrying"
                throw PurgeApplyError.auditFailure(
                    reason: reason,
                    operationMayHaveRun: false,
                    runId: unresolved.runId
                )
            }
        } catch let error as PurgeApplyError {
            throw error
        } catch {
            throw PurgeApplyError.infrastructureFailure(
                reason: "run history unusable — could not verify destructive audit history: \(error)",
                operationMayHaveRun: false
            )
        }

        // Re-read each repository before history can satisfy a missing
        // watermark. The plan binds the current snapshot attribution to the
        // token; its restic config id binds any recovered terminal evidence
        // to the repository that was actually rewritten.
        var plans: [(
            destination: Destination,
            plan: PurgePlan,
            repositoryId: String,
            destinationSecretEnv: [String: String]
        )] = []
        for destination in pendingDestinations.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let destinationSecretEnv: [String: String]
            do {
                destinationSecretEnv = try await restic.maintenanceSecretEnvironment(for: destination)
            } catch {
                throw PurgeApplyError.unavailable
            }
            let current = try await currentPurgePlan(
                set: set,
                destination: destination,
                patterns: pendingPatternsByDestination[destination.id] ?? [],
                destinationSecretEnv: destinationSecretEnv,
                executable: executable
            )
            guard let tokenDestination = preview.destinations.first(where: {
                $0.destinationId == destination.id
            }), tokenDestination.snapshotIDs.sorted() == current.plan.matched.map(\.id).sorted() else {
                throw PurgeApplyError.tokenDoesNotMatchCurrentPlan
            }
            plans.append((destination, current.plan, current.repositoryId, destinationSecretEnv))
        }

        // `rewrite --forget` publishes terminal run metadata before the
        // schedule watermark. If the later directory fsync fails, a crash
        // may lose that rename even though the repository mutation and its
        // canonical audit record are durable. Reconcile that exact success
        // while both the destructive-audit gate and schedule-state lease are
        // held, then consume this now-stale token before returning/refusing.
        // The audit scan above makes malformed or incomplete destructive
        // history fail closed before it can feed this decision.
        let successfulPatterns: [UUID: Set<String>]
        do {
            successfulPatterns = try successfulPurgePatterns(
                setId: set.id,
                pendingPatternsByDestination: pendingPatternsByDestination,
                repositoryIdsByDestination: Dictionary(
                    uniqueKeysWithValues: plans.map { ($0.destination.id, $0.repositoryId) }
                ),
                liveSnapshotIdsByDestination: Dictionary(
                    uniqueKeysWithValues: plans.map {
                        (
                            $0.destination.id,
                            Set(($0.plan.matched + $0.plan.unattributed).map(\.id))
                        )
                    }
                )
            )
        } catch {
            throw PurgeApplyError.infrastructureFailure(
                reason: "run history unusable — could not reconcile purge watermark evidence: \(error)",
                operationMayHaveRun: false
            )
        }
        var reconciledAnyPattern = false
        for destination in pendingDestinations {
            guard let successful = successfulPatterns[destination.id] else { continue }
            let applied = Set(
                scheduleStateLease.state.sets[set.id]?
                    .appliedPurgeExcludes[destination.id] ?? []
            )
            let recovered = (pendingPatternsByDestination[destination.id] ?? []).filter {
                successful.contains($0) && !applied.contains($0)
            }
            guard !recovered.isEmpty else { continue }
            try markPurgePatternsApplied(
                setId: set.id,
                destinationId: destination.id,
                patterns: recovered,
                operationMayHaveRun: false,
                scheduleStateLease: scheduleStateLease
            )
            reconciledAnyPattern = true
        }
        if reconciledAnyPattern {
            do {
                _ = try previewTokens.consume(token)
            } catch let error as PreviewTokenError {
                throw PurgeApplyError.token(error)
            } catch {
                throw PurgeApplyError.unavailable
            }
            let fullyReconciled = pendingDestinations.allSatisfy { destination in
                let applied = Set(
                    scheduleStateLease.state.sets[set.id]?
                        .appliedPurgeExcludes[destination.id] ?? []
                )
                return (pendingPatternsByDestination[destination.id] ?? [])
                    .allSatisfy(applied.contains)
            }
            guard fullyReconciled else {
                throw PurgeApplyError.tokenDoesNotMatchCurrentPlan
            }
            return PurgeRunResult(status: .success, children: [])
        }

        do {
            _ = try previewTokens.consume(token)
        } catch let error as PreviewTokenError {
            throw PurgeApplyError.token(error)
        } catch {
            throw PurgeApplyError.unavailable
        }

        let restorePurgeToken: @Sendable () -> Void = { [previewTokens, preview] in
            // A failed restore intentionally leaves the token consumed. A
            // destructive retry is safe only when the store can prove it
            // restored this exact capability.
            try? previewTokens.restore(token, matching: preview)
        }

        var children: [SetRunChild] = []
        var resolvedGroupId = groupId
        var isFirstPurgeChild = true
        for (destination, plan, repositoryId, destinationSecretEnv) in plans {
            guard !plan.matched.isEmpty else {
                // Nothing to rewrite. Advancing the watermark is only correct
                // when the repository genuinely holds nothing this machine
                // may purge. If snapshots WERE declined, the empty match is
                // evidence attribution is wrong — and advancing here would
                // record the purge as applied, permanently, with no rewrite
                // ever run and no error shown. Leave it pending and say so.
                if plan.unattributed.isEmpty {
                    try markPurgePatternsApplied(
                        setId: set.id,
                        destinationId: destination.id,
                        patterns: plan.patterns,
                        operationMayHaveRun: !children.isEmpty,
                        scheduleStateLease: scheduleStateLease
                    )
                } else {
                    logWarning(
                        "BackupEngine: purge of \"\(destination.label)\" matched none of "
                            + "\(plan.unattributed.count) snapshot(s) in the repository — leaving the "
                            + "patterns pending rather than recording them as applied"
                    )
                }
                continue
            }
            let restoreAfterLaunchFailure = isFirstPurgeChild ? restorePurgeToken : nil
            let purgeResult = await purgeChild(
                destination: destination,
                snapshotIDs: plan.matched.map(\.id),
                patterns: plan.patterns,
                repositoryId: repositoryId,
                destinationSecretEnv: destinationSecretEnv,
                setId: set.id,
                trigger: trigger,
                groupId: resolvedGroupId,
                executable: executable,
                callerHoldsDestructiveAuditGate: true,
                afterLaunchFailure: restoreAfterLaunchFailure
            )
            let wasFirstPurgeChild = isFirstPurgeChild
            isFirstPurgeChild = false
            let purge: ChildRun
            switch purgeResult {
            case .completed(let child):
                purge = child
            case .deferred(let reason):
                if children.isEmpty {
                    restorePurgeToken()
                    throw PurgeApplyError.busy
                }
                throw PurgeApplyError.infrastructureFailure(
                    reason: reason,
                    operationMayHaveRun: true
                )
            case .infrastructureFailure(let failure):
                if wasFirstPurgeChild { restorePurgeToken() }
                if let runId = failure.auditRunId {
                    throw PurgeApplyError.auditFailure(
                        reason: failure.reason,
                        operationMayHaveRun: !children.isEmpty,
                        runId: runId
                    )
                }
                throw PurgeApplyError.infrastructureFailure(
                    reason: failure.reason,
                    operationMayHaveRun: !children.isEmpty
                )
            }
            if wasFirstPurgeChild,
               purge.outcome == nil,
               purge.infrastructureFailureReason == nil {
                // Secret/executable preflight and Process.run launch
                // failures are all before a child can mutate the repository.
                // The latter also invokes `afterLaunchFailure`; restoring
                // twice is harmless because the second exact-match attempt
                // fails closed once `usedAt` is already nil.
                restorePurgeToken()
                throw PurgeApplyError.infrastructureFailure(
                    reason: purge.preflightFailure?.message
                        ?? "the first purge process could not be launched",
                    operationMayHaveRun: false
                )
            }
            children.append(purge.child)
            if let failure = purge.infrastructureFailure {
                if let runId = failure.auditRunId {
                    throw PurgeApplyError.auditFailure(
                        reason: failure.reason,
                        operationMayHaveRun: true,
                        runId: runId
                    )
                }
                throw PurgeApplyError.infrastructureFailure(
                    reason: failure.reason,
                    operationMayHaveRun: true
                )
            }
            if resolvedGroupId == nil { resolvedGroupId = purge.child.runId }
            if purge.child.status == .success {
                try markPurgePatternsApplied(
                    setId: set.id,
                    destinationId: destination.id,
                    patterns: plan.patterns,
                    operationMayHaveRun: true,
                    scheduleStateLease: scheduleStateLease
                )
            }
        }
        return PurgeRunResult(status: Self.worstStatus(children.map(\.status)), children: children)
    }

    /// Obtains a fresh attributed plan for token validation.  It is purposely
    /// independent of the earlier dry-run transcript: a repository can
    /// change during the preview window, and the apply must fail closed.
    ///
    /// Pinned to the executable the apply captured, so the program that
    /// answers "is this token still valid?" is the program that will act on
    /// the answer.  Unpinned, a binary substituted during this query could
    /// return a listing matching the token while the repository had in fact
    /// changed — the staleness check would pass on a lie.  It could not
    /// widen the purge, because the ids must equal the token's exactly, and
    /// the launch itself already failed closed on the mismatch; this closes
    /// the validation half too (#118).
    private func currentPurgePlan(
        set: BackupSet,
        destination: Destination,
        patterns: [String],
        destinationSecretEnv: [String: String],
        executable: ResticRunner.MaintenanceExecutable
    ) async throws -> (plan: PurgePlan, repositoryId: String) {
        let probe = await reachability.probe(
            destination,
            expectedExecutableIdentity: executable.identity
        )
        guard probe == .reachable else {
            throw PurgeApplyError.destinationOffline(destinationId: destination.id)
        }
        let repositoryId = try await purgeRepositoryId(
            destination: destination,
            destinationSecretEnv: destinationSecretEnv,
            executable: executable
        )
        let outcome: ResticOutcome
        do {
            outcome = try await restic.run(
                .snapshots(repo: destination.repoURL),
                for: ResticInvocation(
                    destination: destination,
                    destinationSecretEnv: destinationSecretEnv,
                    expectedExecutableIdentity: executable.identity
                )
            )
        } catch {
            throw PurgeApplyError.unavailable
        }
        guard outcome.status == .success,
              let snapshots = try? parseSnapshots(Data(outcome.rawOutput.utf8)) else {
            throw PurgeApplyError.unavailable
        }
        return (
            plan: PurgePlan(
                destinationId: destination.id,
                snapshots: snapshots,
                sourcePaths: sourcePaths(for: set),
                hostnames: hostnames(for: set),
                patterns: patterns
            ),
            repositoryId: repositoryId
        )
    }

    private func purgeRepositoryId(
        destination: Destination,
        destinationSecretEnv: [String: String],
        executable: ResticRunner.MaintenanceExecutable
    ) async throws -> String {
        let outcome: ResticOutcome
        do {
            outcome = try await restic.run(
                .catConfig(repo: destination.repoURL),
                for: ResticInvocation(
                    destination: destination,
                    destinationSecretEnv: destinationSecretEnv,
                    expectedExecutableIdentity: executable.identity
                )
            )
        } catch {
            throw PurgeApplyError.unavailable
        }
        guard outcome.status == .success,
              let config = try? parseRepositoryConfig(Data(outcome.rawOutput.utf8)),
              !config.id.isEmpty else {
            throw PurgeApplyError.unavailable
        }
        return config.id
    }

    /// The only `rewrite --forget` call site.  It receives explicit ids from
    /// the just-revalidated token and records the old→new mapping in the
    /// purge run metadata; it never accepts a caller-supplied broad filter.
    private func purgeChild(
        destination: Destination,
        snapshotIDs: [String],
        patterns: [String],
        repositoryId: String,
        destinationSecretEnv: [String: String],
        setId: UUID,
        trigger: RunTrigger,
        groupId: String?,
        executable: ResticRunner.MaintenanceExecutable,
        callerHoldsDestructiveAuditGate: Bool = false,
        afterLaunchFailure: (@Sendable () -> Void)? = nil
    ) async -> RecordedChildResult {
        let fullIDByShortID = Dictionary(
            snapshotIDs.map { (String($0.prefix(8)), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return await performChild(
            kind: .purge,
            setId: setId,
            destination: destination,
            trigger: trigger,
            groupId: groupId,
            phase: "purging-\(destination.id.uuidString)",
            command: .rewrite(
                repo: destination.repoURL,
                snapshotIDs: snapshotIDs,
                excludes: patterns,
                forget: true
            ),
            // Pin the executable the token was validated against. Without
            // this the fingerprint check was advisory: restic could be
            // replaced between validation and launch — the window includes
            // `currentPurgePlan`'s repository queries, which are slow — and
            // the replacement would run `rewrite --forget` under an
            // already-consumed token. `ResticRunner` rechecks the identity
            // immediately before it spawns.
            //
            // Identity only, deliberately no `resticPathOverride`: the runner
            // resolves symlinks when it recomputes, so a retargeted link
            // still fails the check, while `argv[0]` stays the configured
            // path the golden argv tests and `docs/restic-cli.md` describe.
            invocation: ResticInvocation(
                destination: destination,
                destinationSecretEnv: destinationSecretEnv,
                expectedExecutableIdentity: executable.identity
            ),
            streamProgress: false,
            launchPreflight: { [weak self] in
                guard let self else {
                    throw ResticRunnerError.launchFailed(
                        "the repository could not be revalidated at purge launch"
                    )
                }
                let launchRepositoryId: String
                do {
                    launchRepositoryId = try await self.purgeRepositoryId(
                        destination: destination,
                        destinationSecretEnv: destinationSecretEnv,
                        executable: executable
                    )
                } catch {
                    throw ResticRunnerError.launchFailed(
                        "the repository could not be revalidated at purge launch"
                    )
                }
                guard launchRepositoryId == repositoryId else {
                    throw ResticRunnerError.launchFailed(
                        "the repository changed after purge validation"
                    )
                }
            },
            afterLaunchFailure: afterLaunchFailure,
            callerHoldsDestructiveAuditGate: callerHoldsDestructiveAuditGate,
            purgePatterns: patterns,
            purgeRepositoryId: repositoryId,
            purgeSnapshotRewrites: { outcome in
                var rewrites: [String: String] = [:]
                for rewrite in parseRewrite(outcome.rawOutput).snapshots {
                    guard let oldID = fullIDByShortID[rewrite.shortID],
                          let newID = rewrite.newSnapshotShortID else { return nil }
                    guard rewrites.updateValue(newID, forKey: oldID) == nil else { return nil }
                }
                return rewrites.count == snapshotIDs.count ? rewrites : nil
            }
        )
    }

    private func pendingPurgePatterns(
        setId: UUID,
        set: BackupSet,
        destinationId: UUID
    ) throws -> [String] {
        let applied = try trustedScheduleState()
            .sets[setId]?.appliedPurgeExcludes[destinationId] ?? []
        return set.purgeExcludes.filter { !applied.contains($0) }
    }

    /// Returns only patterns bound into durable, terminal successful purge
    /// records. The caller must first hold the destructive gate and pass
    /// `unresolvedAuditFailures`, which verifies canonical metadata against
    /// its index projection and refuses malformed or incomplete history.
    private func successfulPurgePatterns(
        setId: UUID,
        pendingPatternsByDestination: [UUID: [String]],
        repositoryIdsByDestination: [UUID: String],
        liveSnapshotIdsByDestination: [UUID: Set<String>]
    ) throws -> [UUID: Set<String>] {
        var result: [UUID: Set<String>] = [:]
        for entry in try runStore.recentRuns(setId: setId, limit: Int.max)
            where entry.kind == .purge
                && entry.status == .success
                && repositoryIdsByDestination[entry.destId] != nil {
            let metadata = try runStore.metadata(runId: entry.runId)
            guard metadata.runId == entry.runId,
                  metadata.kind == .purge,
                  metadata.setId == setId,
                  metadata.destId == entry.destId,
                  metadata.status == .success else {
                throw RunStoreError.discardUnsafe(
                    path: paths.runMetadataFile(runId: entry.runId).path
                )
            }
            guard let patterns = metadata.purgePatterns else { continue }
            let pending = Set(pendingPatternsByDestination[entry.destId] ?? [])
            guard !pending.isDisjoint(with: patterns) else { continue }
            guard let recordedRepositoryId = metadata.purgeRepositoryId else {
                throw RunStoreError.discardUnsafe(
                    path: paths.runMetadataFile(runId: entry.runId).path
                )
            }
            guard recordedRepositoryId == repositoryIdsByDestination[entry.destId] else {
                continue
            }
            guard let rewrites = metadata.purgeSnapshotRewrites,
                  !rewrites.isEmpty else {
                throw RunStoreError.discardUnsafe(
                    path: paths.runMetadataFile(runId: entry.runId).path
                )
            }
            let liveIds = liveSnapshotIdsByDestination[entry.destId] ?? []
            let oldIdsAreAbsent = rewrites.keys.allSatisfy { !liveIds.contains($0) }
            let everyNewIdIsPresentExactlyOnce = rewrites.values.allSatisfy { shortId in
                liveIds.lazy.filter { $0.hasPrefix(shortId) }.prefix(2).count == 1
            }
            guard oldIdsAreAbsent, everyNewIdIsPresentExactlyOnce else {
                // A repository restored to a pre-purge generation can keep
                // its config id. Its old snapshots are live work, not
                // authority to repair the missing schedule watermark.
                continue
            }
            result[entry.destId, default: []].formUnion(patterns)
        }
        return result
    }

    private func trustedScheduleState() throws -> ScheduleState {
        switch stateStore.readScheduleStateResult() {
        case .missing:
            return ScheduleState()
        case .valid(let state):
            return state
        case .corrupt(let failure):
            throw StateStoreError.scheduleStateCorrupt(failure)
        }
    }

    /// Mints a local token from a fresh plan and consumes it through the same
    /// `runPurgeLocked` path as manual apply.  Automatic purge therefore has
    /// no back door around the token validation or audit guarantees.
    private func runAutomaticPurge(
        set: BackupSet,
        destination: Destination,
        patterns: [String],
        trigger: RunTrigger,
        groupId: String
    ) async throws -> PurgeRunResult {
        guard await secretsAvailable(for: [destination]) else { throw PurgeApplyError.unavailable }
        // Captured before the plan query, not after it: the automatic path
        // mints and spends its own token, so the same "one binary for the
        // whole operation" rule applies here (#118).
        guard let executable = restic.maintenanceExecutable() else {
            throw PurgeApplyError.resticUnavailable
        }
        let destinationSecretEnv: [String: String]
        do {
            destinationSecretEnv = try await restic.maintenanceSecretEnvironment(for: destination)
        } catch {
            throw PurgeApplyError.unavailable
        }
        let current = try await currentPurgePlan(
            set: set,
            destination: destination,
            patterns: patterns,
            destinationSecretEnv: destinationSecretEnv,
            executable: executable
        )
        let token: PreviewToken
        do {
            token = try previewTokens.issue(
                machineId: machineId,
                setId: set.id,
                destinations: [PreviewTokenDestination(
                    destinationId: destination.id,
                    snapshotIDs: current.plan.matched.map(\.id)
                )],
                config: config,
                patterns: patterns,
                executableIdentity: executable.identity
            )
        } catch let error as PreviewTokenError {
            throw PurgeApplyError.token(error)
        } catch {
            throw PurgeApplyError.unavailable
        }
        return try await runPurgeLocked(
            set: set,
            destinations: [destination],
            token: token.value,
            trigger: trigger,
            groupId: groupId
        )
    }

    // MARK: - runRestore

    /// Restores from one destination under the **set** lock, so a restore
    /// can never run concurrently with a backup of the same set.
    ///
    /// Per-file `error` messages in the NDJSON stream downgrade an exit-0
    /// restore to `.warning` (`docs/restic-cli.md` §restore).
    public func runRestore(request: RestoreRequest) async -> ManualRunOutcome {
        guard let (set, destination) = locate(destId: request.destId) else {
            logWarning("BackupEngine: no configured destination with id \(request.destId) — cannot restore")
            return .completed(.failed)
        }
        guard await secretsAvailable(for: [destination]) else { return .skipped }

        let (lock, acquisition) = acquireSetLock(setId: set.id)
        switch acquisition {
        case .acquired:
            break
        case .busy:
            recordSkipped(kind: .restore, setId: set.id, destId: destination.id, trigger: .manual)
            return .skipped
        case .failed(let failure):
            recordLockFailure(
                kind: .restore, setId: set.id, destId: destination.id, trigger: .manual, failure: failure
            )
            return .infrastructureFailure(reason: failure.description, operationMayHaveRun: false)
        }
        defer { lock.release() }
        // Declared after the lock defer, so it unwinds *first*: the live
        // progress record is removed while the lock is still held, on every
        // exit path (T09 step 8 — "clear current-run, release lock").
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        let restoreResult = await performChild(
            kind: .restore,
            setId: set.id,
            destination: destination,
            trigger: .manual,
            groupId: nil,
            phase: "restoring",
            command: .restore(
                repo: destination.repoURL,
                snapshotID: request.snapshotID,
                subpath: request.subpath,
                target: request.targetPath,
                includes: request.includes,
                overwrite: request.overwriteMode
            ),
            invocation: ResticInvocation(destination: destination),
            streamProgress: false,
            downgradeSuccessToWarning: { outcome in Self.containsErrorMessage(outcome.messages) }
        )
        let restore: ChildRun
        switch restoreResult {
        case .completed(let child):
            restore = child
        case .deferred(let reason):
            return .infrastructureFailure(reason: reason, operationMayHaveRun: false)
        case .infrastructureFailure(let failure):
            return .infrastructureFailure(
                reason: failure.reason,
                operationMayHaveRun: false
            )
        }
        if let reason = restore.infrastructureFailureReason {
            return .infrastructureFailure(reason: reason, operationMayHaveRun: true)
        }
        return .completed(restore.child.status)
    }

    // MARK: - initSecondary

    /// `restic -r <secondary> init --json --from-repo <primary>
    /// --copy-chunker-params` — the chunker flag is non-negotiable
    /// (`docs/restic-cli.md` §init secondary): without it deduplication
    /// between primary and mirror is destroyed.
    public func initSecondary(_ set: BackupSet, dest: Destination) async -> ManualRunOutcome {
        guard let primary = set.destinations.first(where: { $0.isPrimary }) else {
            logWarning("BackupEngine: backup set \"\(set.name)\" has no primary destination")
            return .completed(.failed)
        }
        guard !dest.isPrimary else {
            logWarning("BackupEngine: initSecondary refuses to run against the primary destination")
            return .completed(.failed)
        }
        // Both repositories' passwords are needed (`RESTIC_PASSWORD_COMMAND`
        // and `RESTIC_FROM_PASSWORD_COMMAND`).
        guard await secretsAvailable(for: [dest, primary]) else { return .skipped }

        let (lock, acquisition) = acquireSetLock(setId: set.id)
        switch acquisition {
        case .acquired:
            break
        case .busy:
            recordSkipped(kind: .`init`, setId: set.id, destId: dest.id, trigger: .manual)
            return .skipped
        case .failed(let failure):
            recordLockFailure(
                kind: .`init`, setId: set.id, destId: dest.id, trigger: .manual, failure: failure
            )
            return .infrastructureFailure(reason: failure.description, operationMayHaveRun: false)
        }
        defer { lock.release() }
        // Declared after the lock defer, so it unwinds *first*: the live
        // progress record is removed while the lock is still held, on every
        // exit path (T09 step 8 — "clear current-run, release lock").
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        let initResult = await performChild(
            kind: .`init`,
            setId: set.id,
            destination: dest,
            trigger: .manual,
            groupId: nil,
            phase: "initializing",
            command: .initSecondary(repo: dest.repoURL, fromRepo: primary.repoURL),
            invocation: ResticInvocation(destination: dest, fromDestination: primary),
            streamProgress: false
        )
        let initRun: ChildRun
        switch initResult {
        case .completed(let child):
            initRun = child
        case .deferred(let reason):
            return .infrastructureFailure(reason: reason, operationMayHaveRun: false)
        case .infrastructureFailure(let failure):
            return .infrastructureFailure(
                reason: failure.reason,
                operationMayHaveRun: false
            )
        }
        if initRun.child.status == .success {
            updateRepoStatus(destId: dest.id) { status in
                status.reachable = true
                status.probedAt = self.now()
                status.lastError = nil
            }
        }
        if let reason = initRun.infrastructureFailureReason {
            return .infrastructureFailure(reason: reason, operationMayHaveRun: true)
        }
        return .completed(initRun.child.status)
    }

    // MARK: - forget (the only destructive command)

    /// The **single** place `forget` is ever invoked. Both guards live here:
    /// an absent or empty policy returns `nil` without spawning anything
    /// (and `ResticCommand.forget` would `precondition`-fail on an empty
    /// policy anyway — that is the second half of the double guard).
    ///
    /// Callers are responsible for the freshness half of the contract: never
    /// call this for a destination whose copy did not succeed in this run
    /// (`runSet`) or whose mirror is behind the primary (`runPruneUnchecked`
    /// — the public `runPrune` is contained and never reaches here).
    private func forgetChild(
        destination: Destination,
        policy: RetentionPolicy?,
        setId: UUID,
        trigger: RunTrigger,
        groupId: String?,
        /// Non-nil when the caller authorized this operation against a
        /// specific restic binary. `ResticRunner` rechecks it immediately
        /// before spawning, so a binary replaced after authorization — the
        /// window spans every earlier destination in a multi-destination
        /// prune — never receives `forget --prune`.
        expectedExecutableIdentity: String? = nil,
        callerHoldsDestructiveAuditGate: Bool = false
    ) async -> RetentionChildResult {
        guard let policy, !policy.isEmpty else {
            return .notRequired
        }
        switch await performChild(
            kind: .prune,
            setId: setId,
            destination: destination,
            trigger: trigger,
            groupId: groupId,
            phase: "retention",
            command: .forget(repo: destination.repoURL, policy: policy, prune: true),
            invocation: ResticInvocation(
                destination: destination,
                expectedExecutableIdentity: expectedExecutableIdentity
            ),
            streamProgress: false,
            callerHoldsDestructiveAuditGate: callerHoldsDestructiveAuditGate
        ) {
        case .completed(let child):
            return .completed(child)
        case .deferred(let reason):
            return .deferred(reason)
        case .infrastructureFailure(let reason):
            return .infrastructureFailure(reason)
        }
    }

    // MARK: - Child runs

    /// A finished child run: its index projection plus the raw restic
    /// outcome (`nil` when restic never ran — e.g. an unreachable primary).
    private struct ChildRun {
        let child: SetRunChild
        let outcome: ResticOutcome?
        let preflightFailure: PreflightFailure?
        /// The child may have completed and its terminal metadata may exist,
        /// while the append-only index write failed. Every caller must
        /// surface that as machine infrastructure failure, never success.
        let infrastructureFailure: ChildInfrastructureFailure?

        var infrastructureFailureReason: String? {
            infrastructureFailure?.reason
        }
    }

    private struct ChildInfrastructureFailure {
        let reason: String
        let auditRunId: String?

        init(_ reason: String, auditRunId: String? = nil) {
            self.reason = reason
            self.auditRunId = auditRunId
        }
    }

    /// A command either obtained a durable run record before launch or was
    /// stopped by run-history infrastructure. Keeping that failure typed
    /// prevents callers from treating an unwritable `runs/` directory as an
    /// ordinary skip or as an intentionally absent retention operation.
    private enum RecordedChildResult {
        case completed(ChildRun)
        /// Expected machine-wide destructive-gate contention. Nothing was
        /// recorded or launched, so callers may safely defer and retry.
        case deferred(String)
        case infrastructureFailure(ChildInfrastructureFailure)
    }

    private enum RetentionChildResult {
        case notRequired
        case completed(ChildRun)
        case deferred(String)
        case infrastructureFailure(ChildInfrastructureFailure)
    }

    private enum PreflightFailure: Sendable {
        case reason(String)
        case previewChanged
        case previewExpired
        case previewUnavailable
        case storeUnusable(String)

        var message: String {
            switch self {
            case .reason(let reason): return reason
            case .previewChanged:
                return "Destination configuration changed after the reclaim preview. Run a new dry run before pruning."
            case .previewExpired:
                return "The reclaim preview has expired. Run a new dry run before pruning."
            case .previewUnavailable:
                return "The reclaim confirmation is temporarily unavailable. Try confirming again."
            case .storeUnusable(let detail):
                return "The reclaim confirmation store is unusable: \(detail)"
            }
        }
    }

    /// Keeps the reclaim path's refusal wording honest. Only `.unavailable`
    /// is retryable, and only `.expired` may say *why* — `.unknown` and
    /// `.alreadyUsed` stay deliberately opaque so a caller cannot probe the
    /// token store for which of the two it hit.
    ///
    /// `.storeUnusable` stays distinct from transient contention so the
    /// caller can report the permanent data-directory fault as non-retryable.
    private static func preflightFailure(for error: PreviewTokenError) -> PreflightFailure {
        switch error {
        case .unavailable: return .previewUnavailable
        case .storeUnusable(let detail): return .storeUnusable(detail)
        case .expired: return .previewExpired
        case .unknown, .alreadyUsed: return .previewChanged
        }
    }

    /// Runs one restic command as one recorded run: `begin` → open the run
    /// log → optional pre-flight → execute (with the exit-11 unlock/retry
    /// protocol) → `finish` + index append.
    ///
    /// Returns a typed infrastructure failure when the run record could not
    /// be created at all; in that case nothing was spawned.
    ///
    /// - Parameters:
    ///   - preflightPhase: written to `current-run` before `preflight` runs.
    ///   - preflight: returns a failure classification to abort the run *before*
    ///     spawning restic (used for the primary reachability probe), or
    ///     `nil` to proceed.
    ///   - downgradeSuccessToWarning: inspected on an otherwise successful
    ///     outcome (restore's per-file `error` messages).
    private func performChild(
        kind: RunKind,
        setId: UUID,
        destination: Destination,
        trigger: RunTrigger,
        groupId: String?,
        phase: String,
        command: ResticCommand,
        invocation: ResticInvocation,
        streamProgress: Bool,
        remoteCommand: RemoteResticCommand? = nil,
        preflightPhase: String? = nil,
        preflight: (@Sendable (LogWriter?) async -> PreflightFailure?)? = nil,
        launchPreflight: (@Sendable () async throws -> Void)? = nil,
        beforeLaunch: (@Sendable () throws -> Void)? = nil,
        afterLaunchFailure: (@Sendable () -> Void)? = nil,
        downgradeSuccessToWarning: (@Sendable (ResticOutcome) -> Bool)? = nil,
        callerHoldsDestructiveAuditGate: Bool = false,
        purgePatterns: [String]? = nil,
        purgeRepositoryId: String? = nil,
        purgeSnapshotRewrites: (@Sendable (ResticOutcome) -> [String: String]?)? = nil
    ) async -> RecordedChildResult {
        let destructiveAuditGate: FileLock?
        if kind.isDestructive && !callerHoldsDestructiveAuditGate {
            do {
                try paths.ensureDirectories()
            } catch {
                let reason = "run history unusable — could not prepare the destructive audit gate: \(error)"
                logWarning("BackupEngine: \(reason)")
                return .infrastructureFailure(ChildInfrastructureFailure(reason))
            }
            let gate = FileLock(path: paths.destructiveAuditLockFile, trustedRoot: paths.root)
            switch gate.acquire() {
            case .acquired:
                destructiveAuditGate = gate
            case .busy:
                let reason = "destructive audit gate busy — another destructive operation is running"
                logWarning("BackupEngine: \(reason)")
                return .deferred(reason)
            case .failed(let failure):
                let reason = "run history unusable — destructive audit gate unusable: \(failure)"
                logWarning("BackupEngine: \(reason)")
                return .infrastructureFailure(ChildInfrastructureFailure(reason))
            }
        } else {
            destructiveAuditGate = nil
        }
        defer { destructiveAuditGate?.release() }

        if kind.isDestructive {
            do {
                if let unresolved = try runStore.unresolvedAuditFailures(
                    callerHoldsDestructiveAuditGate: true
                ).first {
                    let reason = "operation_completed_audit_failed — destructive run "
                        + "\(unresolved.runId) has unresolved \(unresolved.reason.rawValue) audit evidence; "
                        + "inspect and reconcile run history before retrying"
                    logWarning("BackupEngine: \(reason)")
                    return .infrastructureFailure(ChildInfrastructureFailure(
                        reason,
                        auditRunId: unresolved.runId
                    ))
                }
            } catch {
                let reason = "run history unusable — could not verify destructive audit history: \(error)"
                logWarning("BackupEngine: \(reason)")
                return .infrastructureFailure(ChildInfrastructureFailure(reason))
            }
        }

        var run: ActiveRun
        do {
            run = try runStore.begin(
                kind: kind,
                setId: setId,
                destId: destination.id,
                trigger: trigger,
                groupId: groupId
            )
        } catch {
            let reason = "run history unusable — could not create a \(kind.rawValue) run record: \(error)"
            logWarning("BackupEngine: \(reason)")
            return .infrastructureFailure(ChildInfrastructureFailure(reason))
        }
        // Reproduces the exact spawned command line, including an invocation
        // override selected by a validated maintenance request. Secrets never
        // appear in argv (`ResticCommand`'s invariant 1), so this is safe to
        // persist.
        run.argvRedacted = remoteCommand?.passwordStdinArgv
            ?? restic.redactedArgv(command, for: invocation)
        run.purgePatterns = purgePatterns
        run.purgeRepositoryId = purgeRepositoryId

        let logWriter: LogWriter?
        do {
            logWriter = try logWriterFactory(paths.runLogFile(runId: run.runId))
        } catch {
            if kind.isDestructive {
                let reason = "run history unusable — could not open the required destructive audit log "
                    + "for run \(run.runId): \(error)"
                let finishFailure = finish(run, status: .failed, errorSummary: reason)
                logWarning("BackupEngine: \(reason)")
                return .infrastructureFailure(ChildInfrastructureFailure(finishFailure ?? reason))
            }
            logWriter = nil
        }
        defer { logWriter?.close() }
        logWriter?.appendLine("$ \(run.argvRedacted.joined(separator: " "))")

        let reporter = progressReporter(setId: setId, run: run, phase: preflightPhase ?? phase)
        reporter.writePhaseMarker()
        reporter.startHeartbeat()
        defer { reporter.stopHeartbeat() }

        if let preflight, let failure = await preflight(logWriter) {
            logWriter?.appendLine("aborted: \(failure.message)")
            if case .previewUnavailable = failure {
                do {
                    try runStore.discardUnstarted(run)
                    return .completed(ChildRun(
                        child: SetRunChild(runId: run.runId, kind: kind, destId: destination.id, status: .skipped),
                        outcome: nil,
                        preflightFailure: failure,
                        infrastructureFailure: nil
                    ))
                } catch {
                    logWarning("BackupEngine: could not discard unavailable preflight run \(run.runId): \(error)")
                }
            }
            let infrastructureFailure = finish(run, status: .failed, errorSummary: failure.message)
            return .completed(ChildRun(
                child: SetRunChild(runId: run.runId, kind: kind, destId: destination.id, status: .failed),
                outcome: nil,
                preflightFailure: failure,
                infrastructureFailure: infrastructureFailure.map { ChildInfrastructureFailure($0) }
            ))
        }

        if preflightPhase != nil {
            reporter.beginPhase(phase)
        }

        let result: ExecuteResult
        let auditRun = run
        let destructiveLaunchState = DestructiveLaunchState()
        let auditBeforeLaunch: (@Sendable () throws -> Void)?
        if kind.isDestructive {
            auditBeforeLaunch = { [runStore, auditRun, destructiveLaunchState] in
                try runStore.markDestructiveLaunchAuthorized(auditRun)
                destructiveLaunchState.markAuthorized()
            }
        } else {
            auditBeforeLaunch = nil
        }
        if let remoteCommand {
            result = await spawnRemote(
                remoteCommand,
                destination: destination,
                logWriter: logWriter,
                beforeLaunch: beforeLaunch,
                auditBeforeLaunch: auditBeforeLaunch,
                afterLaunchFailure: afterLaunchFailure
            )
        } else {
            result = await execute(
                command,
                invocation: invocation,
                logWriter: logWriter,
                reporter: streamProgress ? reporter : nil,
                launchPreflight: launchPreflight,
                beforeLaunch: beforeLaunch,
                auditBeforeLaunch: auditBeforeLaunch,
                afterLaunchFailure: afterLaunchFailure
            )
        }

        if case .didNotRun(_, let launchPreflightFailure?, _) = result {
            if case .previewUnavailable = launchPreflightFailure {
                do {
                    try runStore.discardUnstarted(run)
                    return .completed(ChildRun(
                        child: SetRunChild(runId: run.runId, kind: kind, destId: destination.id, status: .skipped),
                        outcome: nil,
                        preflightFailure: launchPreflightFailure,
                        infrastructureFailure: nil
                    ))
                } catch {
                    logWarning("BackupEngine: could not discard unavailable launch preflight run \(run.runId): \(error)")
                }
            }
            let infrastructureFailure = finish(
                run,
                status: .failed,
                errorSummary: launchPreflightFailure.message
            )
            return .completed(ChildRun(
                child: SetRunChild(runId: run.runId, kind: kind, destId: destination.id, status: .failed),
                outcome: nil,
                preflightFailure: launchPreflightFailure,
                infrastructureFailure: infrastructureFailure.map { ChildInfrastructureFailure($0) }
            ))
        }

        var status: RunStatus
        var errorSummary: String?
        var stats: BackupSummary?
        var exitCode: Int32?

        var auditFailureReason: RunAuditFailureReason? = nil
        switch result {
        case .didNotRun(let reason, _, let operationMayHaveRun):
            status = .failed
            if operationMayHaveRun, destructiveLaunchState.wasAuthorized {
                auditFailureReason = .repositoryOutcomeUnknown
                errorSummary = "operation_completed_audit_failed — repository outcome unknown: \(reason)"
            } else {
                errorSummary = reason
            }
        case .ranToCompletion(let outcome):
            exitCode = outcome.exitCode
            stats = Self.summary(in: outcome.messages)
            switch outcome.status {
            case .success:
                if downgradeSuccessToWarning?(outcome) == true {
                    status = .warning
                    errorSummary = "Some items could not be restored; see the run log."
                } else {
                    status = .success
                }
            case .warningIncompleteRead:
                status = .warning
                errorSummary = outcome.status.userFacingMessage
            case .fatal, .repoDoesNotExist, .repoLocked, .wrongPassword, .other:
                // Enumerated (no `default`) so a new `ResticExitClass` case
                // must decide its run status here rather than silently
                // recording `.failed`.
                status = .failed
                errorSummary = outcome.status.userFacingMessage
            }
        }

        let rewrites: [String: String]?
        if status == .success, case .ranToCompletion(let outcome) = result {
            rewrites = purgeSnapshotRewrites?(outcome)
        } else {
            rewrites = nil
        }
        if kind == .purge, status == .success, rewrites == nil {
            // A successful exit with an incomplete rewrite transcript does
            // not prove which launch-authorized snapshots now exist. Keep a
            // durable indeterminate audit failure so neither watermark
            // recovery nor a second destructive launch can guess.
            status = .failed
            auditFailureReason = .repositoryOutcomeUnknown
            errorSummary = "operation_completed_audit_failed — purge rewrite mapping is incomplete"
        }
        let infrastructureFailure = finish(
            run,
            status: status,
            stats: stats,
            errorSummary: errorSummary,
            resticExitCode: exitCode,
            purgeSnapshotRewrites: rewrites,
            auditFailureReason: auditFailureReason,
            launchWasAuthorized: destructiveLaunchState.wasAuthorized
        )
        let auditCondition = auditFailureReason.map { reason in
            "operation_completed_audit_failed — destructive run \(run.runId) has unresolved \(reason.rawValue) audit evidence"
        }
        let childInfrastructureFailure = (infrastructureFailure ?? auditCondition).map {
            ChildInfrastructureFailure(
                $0,
                auditRunId: kind.isDestructive ? run.runId : nil
            )
        }
        return .completed(ChildRun(
            child: SetRunChild(runId: run.runId, kind: kind, destId: destination.id, status: status),
            outcome: result.outcome,
            preflightFailure: nil,
            infrastructureFailure: childInfrastructureFailure
        ))
    }

    /// The outcome of spawning (or failing to spawn) one restic child.
    private enum ExecuteResult {
        case ranToCompletion(ResticOutcome)
        /// restic produced no outcome at all (launch failure, timeout,
        /// secret read failure mid-run, cancellation).
        case didNotRun(
            reason: String,
            preflightFailure: PreflightFailure? = nil,
            operationMayHaveRun: Bool = false
        )

        var outcome: ResticOutcome? {
            if case .ranToCompletion(let outcome) = self { return outcome }
            return nil
        }
    }

    /// Spawns restic, streaming every raw stdout/stderr line into the run log
    /// **before** any parsing decision (safety invariant 4), and applies the
    /// exit-11 protocol from `docs/restic-cli.md` §Stale locks: run
    /// `restic unlock` (which removes only locks held by dead processes, so
    /// it is safe to run automatically), then retry the command exactly once.
    private func execute(
        _ command: ResticCommand,
        invocation: ResticInvocation,
        logWriter: LogWriter?,
        reporter: ProgressReporter?,
        launchPreflight: (@Sendable () async throws -> Void)? = nil,
        beforeLaunch: (@Sendable () throws -> Void)? = nil,
        auditBeforeLaunch: (@Sendable () throws -> Void)? = nil,
        afterLaunchFailure: (@Sendable () -> Void)? = nil
    ) async -> ExecuteResult {
        let first = await spawn(
            command,
            invocation: invocation,
            logWriter: logWriter,
            reporter: reporter,
            launchPreflight: launchPreflight,
            beforeLaunch: beforeLaunch,
            auditBeforeLaunch: auditBeforeLaunch,
            afterLaunchFailure: afterLaunchFailure
        )
        guard case .ranToCompletion(let outcome) = first, outcome.status == .repoLocked else {
            return first
        }

        logWriter?.appendLine(
            "restic reported the repository as locked (exit 11); "
                + "running `unlock` to remove stale locks, then retrying once"
        )
        _ = await spawn(
            .unlock(repo: invocation.destination.repoURL),
            invocation: ResticInvocation(
                destination: invocation.destination,
                destinationSecretEnv: invocation.destinationSecretEnv,
                resticPathOverride: invocation.resticPathOverride,
                expectedExecutableIdentity: invocation.expectedExecutableIdentity
            ),
            logWriter: logWriter,
            reporter: nil
        )
        logWriter?.appendLine("retrying after unlock (attempt 2 of 2)")
        return await spawn(
            command,
            invocation: invocation,
            logWriter: logWriter,
            reporter: reporter,
            launchPreflight: launchPreflight
        )
    }

    private func spawn(
        _ command: ResticCommand,
        invocation: ResticInvocation,
        logWriter: LogWriter?,
        reporter: ProgressReporter?,
        launchPreflight: (@Sendable () async throws -> Void)? = nil,
        beforeLaunch: (@Sendable () throws -> Void)? = nil,
        auditBeforeLaunch: (@Sendable () throws -> Void)? = nil,
        afterLaunchFailure: (@Sendable () -> Void)? = nil
    ) async -> ExecuteResult {
        do {
            let outcome = try await restic.run(
                command,
                for: invocation,
                onLine: { message in
                    guard let reporter, case .status(let status) = message else { return }
                    reporter.record(status)
                },
                onRawLine: { line in
                    logWriter?.appendLine(line)
                },
                launchPreflight: launchPreflight,
                beforeLaunch: beforeLaunch,
                auditBeforeLaunch: auditBeforeLaunch,
                afterLaunchFailure: afterLaunchFailure
            )
            return .ranToCompletion(outcome)
        } catch let error as PreviewTokenError {
            let failure = Self.preflightFailure(for: error)
            logWriter?.appendLine("restic did not run: \(failure.message)")
            return .didNotRun(reason: failure.message, preflightFailure: failure)
        } catch let error as ResticRunnerError {
            logWriter?.appendLine("restic did not run: \(error.description)")
            return .didNotRun(
                reason: error.userFacingMessage,
                operationMayHaveRun: error == .timedOut
            )
        } catch {
            logWriter?.appendLine("restic did not run: \(error)")
            return .didNotRun(
                reason: "The operation did not complete. Open the run log for details.",
                operationMayHaveRun: true
            )
        }
    }

    private func spawnRemote(
        _ command: RemoteResticCommand,
        destination: Destination,
        logWriter: LogWriter?,
        beforeLaunch: (@Sendable () throws -> Void)? = nil,
        auditBeforeLaunch: (@Sendable () throws -> Void)? = nil,
        afterLaunchFailure: (@Sendable () -> Void)? = nil
    ) async -> ExecuteResult {
        do {
            return .ranToCompletion(try await restic.runRemoteMaintenance(
                command,
                destination: destination,
                onRawLine: { logWriter?.appendLine($0) },
                beforeLaunch: beforeLaunch,
                auditBeforeLaunch: auditBeforeLaunch,
                afterLaunchFailure: afterLaunchFailure
            ))
        } catch let error as PreviewTokenError {
            let failure = Self.preflightFailure(for: error)
            logWriter?.appendLine("remote maintenance did not run: \(failure.message)")
            return .didNotRun(reason: failure.message, preflightFailure: failure)
        } catch let error as ResticRunnerError {
            logWriter?.appendLine("remote maintenance did not run: \(error.description)")
            return .didNotRun(
                reason: error.userFacingMessage,
                operationMayHaveRun: error == .timedOut
            )
        } catch {
            logWriter?.appendLine("remote maintenance did not run")
            return .didNotRun(
                reason: "Remote maintenance could not start. Check SSH and the remote restic installation.",
                operationMayHaveRun: true
            )
        }
    }

    // MARK: - Run-record helpers

    private func finish(
        _ run: ActiveRun,
        status: RunStatus,
        stats: BackupSummary? = nil,
        errorSummary: String? = nil,
        resticExitCode: Int32? = nil,
        purgeSnapshotRewrites: [String: String]? = nil,
        auditFailureReason: RunAuditFailureReason? = nil,
        launchWasAuthorized: Bool = false
    ) -> String? {
        do {
            try runStore.finish(
                run,
                status: status,
                stats: stats,
                errorSummary: errorSummary,
                resticExitCode: resticExitCode,
                purgeSnapshotRewrites: purgeSnapshotRewrites,
                auditFailureReason: auditFailureReason
            )
            return nil
        } catch {
            let prefix = run.kind.isDestructive && launchWasAuthorized
                ? "operation_completed_audit_failed — "
                : "run history unusable — "
            let reason = prefix + "could not commit terminal audit evidence for run \(run.runId): \(error)"
            logWarning("BackupEngine: \(reason)")
            return reason
        }
    }

    /// Writes exactly one `.skipped` index record — the "another run for
    /// this set is already in flight" case (`docs/scheduling.md` §Locking).
    private func recordSkipped(kind: RunKind, setId: UUID, destId: UUID, trigger: RunTrigger) {
        do {
            let run = try runStore.begin(kind: kind, setId: setId, destId: destId, trigger: trigger)
            try runStore.finish(
                run,
                status: .skipped,
                errorSummary: "another operation for this backup set is already running"
            )
        } catch {
            logWarning("BackupEngine: could not record the skipped run: \(error)")
        }
    }

    // MARK: - State helpers

    /// `locks/set-<setId>.lock`, plus the answer to whether we hold it.
    ///
    /// Directory creation is part of acquisition, not a best-effort
    /// preamble to it. It used to be logged and stepped over, which left the
    /// caller to interpret the `false` that followed — and every caller read
    /// that `false` as contention, so an uncreatable `locks/` skipped every
    /// run of every set forever while each process still exited 0. A
    /// directory that cannot be created is now a ``LockAcquireResult/failed``
    /// like any other, carrying the reason (#110).
    private func acquireSetLock(setId: UUID) -> (lock: FileLock, result: LockAcquireResult) {
        let lock = FileLock(path: paths.setLockFile(setId: setId), trustedRoot: paths.root)
        do {
            try paths.ensureDirectories()
        } catch {
            return (lock, .failed(LockFailure(
                path: paths.locksDir.path,
                operation: "create data directories",
                errnoValue: 0,
                underlying: "\(error)"
            )))
        }
        return (lock, lock.acquire())
    }

    /// Writes one `.failed` index record for an operation that could not
    /// even start because its lock was unusable.
    ///
    /// Deliberately `.failed`, not `.skipped`. `.skipped` is the benign
    /// "someone else is running" record, and `HealthDerivation` does not
    /// count it — recording an environment fault that way is how a machine
    /// that cannot back up at all goes on reporting healthy. `.failed` sets
    /// `SetHealth.lastRunFailed`, which is what turns the menu bar yellow
    /// and makes `status --json` exit 1.
    ///
    /// Best effort by necessity: the fault that broke the lock is quite
    /// likely to break this write too, which is why it is not the only
    /// mechanism — `status` probes the lock directory live, and `tick` exits
    /// non-zero (#110).
    private func recordLockFailure(
        kind: RunKind,
        setId: UUID,
        destId: UUID,
        trigger: RunTrigger,
        failure: LockFailure
    ) {
        recordInfrastructureFailure(
            kind: kind,
            setId: setId,
            destId: destId,
            trigger: trigger,
            reason: "could not acquire the backup-set lock — \(failure)"
        )
    }

    private func recordInfrastructureFailure(
        kind: RunKind,
        setId: UUID,
        destId: UUID,
        trigger: RunTrigger,
        reason: String
    ) {
        logWarning("BackupEngine: \(reason)")
        do {
            let run = try runStore.begin(kind: kind, setId: setId, destId: destId, trigger: trigger)
            try runStore.finish(
                run,
                status: .failed,
                errorSummary: reason
            )
        } catch {
            logWarning("BackupEngine: could not record the infrastructure failure: \(error)")
        }
    }

    private func progressReporter(setId: UUID, run: ActiveRun, phase: String) -> ProgressReporter {
        ProgressReporter(
            stateStore: stateStore,
            setId: setId,
            runId: run.runId,
            kind: run.kind,
            phase: phase,
            now: now,
            uptime: uptime,
            heartbeatInterval: Self.currentRunHeartbeatInterval
        )
    }

    @discardableResult
    private func updateScheduleState(
        setId: UUID,
        mutate: (inout SetScheduleState) -> Void
    ) throws -> ScheduleState {
        try stateStore.updateScheduleState(setId: setId, mutate: mutate)
    }

    /// Advances the purge-exclusion watermark only after the matching
    /// repository rewrite succeeded. Existing snapshots are never inferred
    /// from this state; it merely prevents a newly added exclusion from
    /// running again on every scheduled backup.
    private func markPurgePatternsApplied(
        setId: UUID,
        destinationId: UUID,
        patterns: [String],
        operationMayHaveRun: Bool,
        scheduleStateLease: LockedScheduleState
    ) throws {
        do {
            _ = try scheduleStateLease.update(setId: setId) { state in
                var applied = state.appliedPurgeExcludes[destinationId] ?? []
                for pattern in patterns where !applied.contains(pattern) {
                    applied.append(pattern)
                }
                state.appliedPurgeExcludes[destinationId] = applied
            }
        } catch {
            throw PurgeApplyError.infrastructureFailure(
                reason: "could not persist the purge watermark — \(error)",
                operationMayHaveRun: operationMayHaveRun
            )
        }
    }

    private static func purgeInfrastructureFailureReason(_ error: Error) -> String? {
        guard let error = error as? PurgeApplyError else { return nil }
        switch error {
        case .lockUnusable(let detail):
            return detail
        case .infrastructureFailure(let reason, _):
            return reason
        case .auditFailure(let reason, _, _):
            return reason
        case .token(.storeUnusable(let detail)):
            return "preview-token store unusable — \(detail)"
        case .token(.unavailable), .token(.unknown), .token(.expired),
             .token(.alreadyUsed), .tokenDoesNotMatchCurrentPlan, .busy,
             .destinationOffline, .unavailable, .resticUnavailable:
            // Refusals and transient conditions, not broken infrastructure.
            // Enumerated (no `default`) so a new `PurgeApplyError` or
            // `PreviewTokenError` case must decide whether it is an
            // infrastructure fault instead of silently reading as "not one".
            return nil
        }
    }

    private func updateRepoStatus(destId: UUID, mutate: (inout RepoStatus) -> Void) {
        do {
            try stateStore.updateRepoStatus(destId: destId, mutate: mutate)
        } catch {
            logWarning("BackupEngine: could not update repo status for destination \(destId): \(error)")
        }
    }

    /// Records a probe result. Reachability is written for every destination
    /// we probe — including the primary — so the UI's badges reflect the
    /// most recent evidence rather than only the 30-minute tick re-probe.
    private func record(probe: RepoProbeResult, for destination: Destination) {
        updateRepoStatus(destId: destination.id) { status in
            status.probedAt = self.now()
            switch probe {
            case .reachable:
                status.reachable = true
                status.lastError = nil
            case .offline, .error:
                status.reachable = false
                status.lastError = self.describe(probe)
            }
        }
    }

    /// `lastSyncedAt` = end of the last successful `backup` (primary) or
    /// `copy` (secondary), per `docs/data-model.md` §repo-status.
    private func markSynced(_ destination: Destination) {
        updateRepoStatus(destId: destination.id) { status in
            status.reachable = true
            status.probedAt = self.now()
            status.lastSyncedAt = self.now()
            status.lastError = nil
        }
    }

    // MARK: - Small pure helpers

    /// Group outcome = worst child status (`failed` > `warning` > `success` >
    /// `skipped`). An empty list is `.success` (nothing failed).
    static func worstStatus(_ statuses: [RunStatus]) -> RunStatus {
        func rank(_ status: RunStatus) -> Int {
            switch status {
            case .failed: return 4
            case .running: return 3
            case .warning: return 2
            case .success: return 1
            case .skipped: return 0
            }
        }
        return statuses.max(by: { rank($0) < rank($1) }) ?? .success
    }

    /// Throttle predicate for `current-run` progress writes: at most one
    /// write per ``progressWriteInterval``. A clock that moved backwards
    /// (negative elapsed) writes immediately rather than stalling progress
    /// until the clock catches up.
    static func shouldWriteProgress(
        lastWriteAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = progressWriteInterval
    ) -> Bool {
        guard let lastWriteAt else { return true }
        let elapsed = now.timeIntervalSince(lastWriteAt)
        return elapsed >= minimumInterval || elapsed < 0
    }

    /// The last `summary` message in a stream, if any (only `backup` emits
    /// one; `RunStore` persists it as `RunMetadata.stats`).
    static func summary(in messages: [ResticMessage]) -> BackupSummary? {
        for message in messages.reversed() {
            if case .summary(let summary) = message { return summary }
        }
        return nil
    }

    /// restic's per-item `{"message_type":"error", …}` lines decode to
    /// `.unparsed` (the decoder tolerates unknown types by design), so they
    /// are detected on the raw line — used to downgrade a successful restore
    /// to `.warning` per `docs/restic-cli.md` §restore.
    static func containsErrorMessage(_ messages: [ResticMessage]) -> Bool {
        for message in messages {
            guard case .unparsed(let line) = message else { continue }
            if line.replacingOccurrences(of: " ", with: "").contains("\"message_type\":\"error\"") {
                return true
            }
        }
        return false
    }

    private func describe(_ probe: RepoProbeResult) -> String {
        switch probe {
        case .reachable:
            return "reachable"
        case .offline(let reason):
            return reason
        case .error(let exitClass):
            return exitClass.userFacingMessage
        }
    }

    private func sourcePaths(for set: BackupSet) -> Set<String> {
        if let known = purgeSourcePaths[set.id] {
            return known
        }
        var paths = Set(set.sources)
        if let machines = set.machines {
            for override in machines.values {
                paths.formUnion(override.sources ?? [])
            }
        }
        return paths
    }

    private func hostnames(for set: BackupSet) -> Set<String> {
        if let known = purgeHostnames[set.id], !known.isEmpty {
            return known
        }
        var names = Set<String>()
        if let machines = set.machines {
            names.formUnion(machines.keys)
        }
        // The engine's own `machineId` — which honours machine.json and
        // `RESTIC_STATION_MACHINE_ID` — plus the kernel hostname restic
        // actually records. `MachineIdentity.generate()` was neither: it
        // re-derived a slug from `ProcessInfo.hostName`, ignoring the
        // override and missing the name in the snapshots.
        names.formUnion(MachineIdentity.localHostnameSlugs(machineId: machineId))
        return names
    }

    /// How the engine names the secret store in its user-visible log lines
    /// and in `.retryable` reasons.
    ///
    /// Taken from the store actually in use, not from the host OS: a macOS
    /// host running `RESTIC_STATION_SECRET_BACKEND=file` must not be told its
    /// login keychain is the problem. The keychain wording is byte-for-byte
    /// what it was before the `SecretStore` abstraction landed.
    private var secretStoreDescription: String {
        secrets.backend.displayName
    }

    /// The engine's own pre-flight for the non-`runSet` entry points: an
    /// unreadable secret store is retryable, so those methods return
    /// `.skipped` without writing a run record (`docs/architecture.md`
    /// §Error taxonomy).
    private func secretsAvailable(for destinations: [Destination]) async -> Bool {
        for destination in destinations {
            do {
                _ = try await secrets.password(destId: destination.id)
            } catch {
                logWarning(
                    "BackupEngine: \(secretStoreDescription) could not be read for destination "
                        + "\"\(destination.label)\" — skipping (retryable, nothing recorded)"
                )
                return false
            }
        }
        return true
    }

    /// Finds the set that owns `destId` (a destination id is unique across
    /// the whole config — `docs/data-model.md` §Invariants).
    private func locate(destId: UUID) -> (BackupSet, Destination)? {
        for set in config.sets {
            if let destination = set.destinations.first(where: { $0.id == destId }) {
                return (set, destination)
            }
        }
        return nil
    }
}

// MARK: - ProgressReporter

/// Throttled writer for `state/current-run-<setId>.json`.
///
/// In-memory evidence that the pre-spawn audit commit succeeded. Canonical
/// metadata remains authoritative after the process exits; this state exists
/// only so losing that metadata during terminal commit cannot make the same
/// invocation forget that repository mutation may already have occurred.
private final class DestructiveLaunchState: @unchecked Sendable {
    private let lock = NSLock()
    private var authorized = false

    var wasAuthorized: Bool {
        lock.withLock { authorized }
    }

    func markAuthorized() {
        lock.withLock { authorized = true }
    }
}

/// One instance per child run: the throttle window is per phase, so the
/// first `status` line of every phase lands immediately and the UI never
/// waits for progress to appear. An independent timer refreshes only the
/// heartbeat fields. `@unchecked Sendable` because the restic stdout callback
/// and timer run on different queues; all mutable state is guarded by `lock`.
///
/// Internal rather than private so the throttle can be exercised directly by
/// `BackupEngineTests` (a set run deletes `current-run` when it ends, so the
/// throttle is not observable from outside once `runSet` has returned).
final class ProgressReporter: @unchecked Sendable {
    private let stateStore: StateStore
    private let setId: UUID
    private let runId: String
    private let kind: RunKind
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let heartbeatInterval: TimeInterval
    private let heartbeatQueue: DispatchQueue

    private let lock = NSLock()
    private var phase: String
    private var lastProgressWriteAt: Date?
    private var latestState: CurrentRunState?
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatActive = false

    init(
        stateStore: StateStore,
        setId: UUID,
        runId: String,
        kind: RunKind,
        phase: String,
        now: @escaping @Sendable () -> Date,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        heartbeatInterval: TimeInterval = BackupEngine.currentRunHeartbeatInterval
    ) {
        self.stateStore = stateStore
        self.setId = setId
        self.runId = runId
        self.kind = kind
        self.phase = phase
        self.now = now
        self.uptime = uptime
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatQueue = DispatchQueue(label: "net.herila.ResticStation.current-run-heartbeat.\(setId)")
    }

    deinit {
        heartbeatTimer?.cancel()
    }

    /// One unthrottled write announcing the phase, with zeroed counters.
    /// Deliberately does not arm the throttle.
    func writePhaseMarker() {
        beginPhase(phase)
    }

    /// Announces a new child phase immediately and resets its progress. The
    /// same reporter (and heartbeat) spans preflight and the restic command,
    /// so a wedged probe is detectable too.
    func beginPhase(_ newPhase: String) {
        let at = now()
        let heartbeatUptime = uptime()
        lock.lock()
        phase = newPhase
        write(
            percentDone: 0,
            bytesDone: 0,
            totalBytes: 0,
            filesDone: 0,
            totalFiles: 0,
            currentFiles: [],
            at: at,
            heartbeatUptime: heartbeatUptime
        )
        lock.unlock()
    }

    /// Starts a dedicated dispatch timer rather than a child Swift task. A
    /// restic await or a wedged cooperative task must not stop the evidence
    /// that tells health checks whether this helper can still execute.
    func startHeartbeat() {
        lock.lock()
        guard !heartbeatActive else {
            lock.unlock()
            return
        }
        heartbeatActive = true
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        heartbeatTimer = timer
        lock.unlock()

        timer.schedule(
            deadline: .now() + heartbeatInterval,
            repeating: heartbeatInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.writeHeartbeat()
        }
        timer.resume()
    }

    /// Cancels future writes and waits for any write already in flight to
    /// leave the lock. The set-level cleanup can then delete current-run
    /// without a late heartbeat recreating it.
    func stopHeartbeat() {
        lock.lock()
        heartbeatActive = false
        let timer = heartbeatTimer
        heartbeatTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    /// Internal for deterministic tests; the production timer calls the same
    /// path. A heartbeat changes only its own timestamps, never the visible
    /// progress fields or `updatedAt`.
    func writeHeartbeat() {
        let at = now()
        let heartbeatUptime = uptime()
        lock.lock()
        defer { lock.unlock() }
        guard heartbeatActive, var state = latestState else { return }
        state.heartbeatAt = at
        state.heartbeatUptime = heartbeatUptime
        latestState = state
        persist(state)
    }

    /// Writes one streamed `status` line, at most once per
    /// `BackupEngine.progressWriteInterval`.
    func record(_ status: BackupStatus) {
        let at = now()
        let heartbeatUptime = uptime()
        lock.lock()
        let shouldWrite = BackupEngine.shouldWriteProgress(lastWriteAt: lastProgressWriteAt, now: at)
        if shouldWrite {
            lastProgressWriteAt = at
        }
        guard shouldWrite else {
            lock.unlock()
            return
        }

        write(
            percentDone: status.percentDone,
            bytesDone: status.bytesDone ?? 0,
            totalBytes: status.totalBytes ?? 0,
            filesDone: status.filesDone ?? 0,
            totalFiles: status.totalFiles ?? 0,
            currentFiles: status.currentFiles ?? [],
            at: at,
            heartbeatUptime: heartbeatUptime
        )
        lock.unlock()
    }

    private func write(
        percentDone: Double,
        bytesDone: Int,
        totalBytes: Int,
        filesDone: Int,
        totalFiles: Int,
        currentFiles: [String],
        at: Date,
        heartbeatUptime: TimeInterval
    ) {
        let state = CurrentRunState(
            runId: runId,
            kind: kind,
            phase: phase,
            percentDone: percentDone,
            bytesDone: bytesDone,
            totalBytes: totalBytes,
            filesDone: filesDone,
            totalFiles: totalFiles,
            currentFiles: currentFiles,
            heartbeatAt: at,
            heartbeatUptime: heartbeatUptime,
            updatedAt: at
        )
        latestState = state
        persist(state)
    }

    /// Caller holds `lock`, serializing progress and heartbeat writes so an
    /// older heartbeat snapshot can never overwrite newer progress.
    private func persist(_ state: CurrentRunState) {
        do {
            try stateStore.writeCurrentRun(setId: setId, state)
        } catch {
            logWarning("BackupEngine: could not write live progress for set \(setId): \(error)")
        }
    }
}

// MARK: - Logging

private func logWarning(_ message: String) {
    StandardStream.write(Data((message + "\n").utf8), to: .standardError)
}
