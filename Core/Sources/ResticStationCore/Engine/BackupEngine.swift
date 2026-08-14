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
}

// MARK: - BackupEngine

/// The orchestration heart: scheduled/manual set runs (backup → mirror →
/// retention), checks, prune, restore and secondary initialization, plus all
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

    public init(
        config: AppConfig,
        paths: AppPaths,
        restic: ResticRunner,
        secrets: any SecretStore,
        runStore: RunStore,
        stateStore: StateStore,
        reachability: Reachability,
        now: @escaping @Sendable () -> Date = Date.init,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
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
    /// 6. every secondary in config order: probe, copy, then retention on
    ///    that secondary only if its copy succeeded;
    /// 7. retention on the primary if the policy is non-nil and non-empty;
    /// 8. clear `current-run`, release the lock (also on every failure path),
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
        let lock = makeSetLock(setId: set.id)
        guard lock.tryAcquire() else {
            recordSkipped(kind: .backup, setId: set.id, destId: primary.id, trigger: trigger)
            return .skipped
        }
        defer { lock.release() }
        // Declared after the lock defer, so it unwinds *first*: the live
        // progress record is removed while the lock is still held, on every
        // exit path (T09 step 8 — "clear current-run, release lock").
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        // ── Step 3: attempt-based lastBackupStart ───────────────────────
        updateScheduleState(setId: set.id) { $0.lastBackupStart = self.now() }

        var children: [SetRunChild] = []

        // ── Steps 4 + 5: probe primary, then back it up ─────────────────
        let backup = await performChild(
            kind: .backup,
            setId: set.id,
            destination: primary,
            trigger: trigger,
            groupId: nil, // this run *is* the group
            phase: "backing-up-primary",
            command: .backup(repo: primary.repoURL, sources: set.sources, excludes: set.excludes),
            invocation: ResticInvocation(destination: primary),
            streamProgress: true,
            preflightPhase: "probing",
            preflight: { [self] logWriter in
                let probe = await reachability.probe(primary)
                logWriter?.appendLine("probe primary \"\(primary.label)\": \(describe(probe))")
                record(probe: probe, for: primary)
                guard probe == .reachable else {
                    return "primary unreachable: \(describe(probe))"
                }
                return nil
            }
        )

        guard let backup else {
            // `RunStore.begin` failed (disk full, unwritable data dir): no
            // record exists, so this is retryable rather than a failed run.
            return .retryable(reason: "the run record could not be created")
        }
        children.append(backup.child)
        let groupId = backup.child.runId

        guard backup.child.status != .failed else {
            // Terminal: no copies, no retention (T09 step 5, scenario 5).
            return .completed(status: .failed, groupId: groupId, children: children)
        }

        // Success or warning (exit 3 — the snapshot exists): the primary is
        // in sync as of now.
        markSynced(primary)

        // ── Step 6: secondaries, in config order ────────────────────────
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

            let copy = await performChild(
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
            guard let copy else { continue }
            children.append(copy.child)

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

            if let prune = await forgetChild(
                destination: secondary,
                policy: set.retention,
                setId: set.id,
                trigger: trigger,
                groupId: groupId
            ) {
                children.append(prune.child)
            }
        }

        // ── Step 7: retention on the primary ────────────────────────────
        if let prune = await forgetChild(
            destination: primary,
            policy: set.retention,
            setId: set.id,
            trigger: trigger,
            groupId: groupId
        ) {
            children.append(prune.child)
        }

        // ── Step 8: current-run cleared and lock released by the defers ─
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
    /// - Parameter trigger: defaults to ``RunTrigger/scheduled`` — `tick`'s
    ///   call sites are unaffected. `run-set --kind check` passes
    ///   ``RunTrigger/manual`` so the run record reflects a manual trigger
    ///   (issue #9's close: this is the one permitted post-T09 Core change).
    public func runCheck(_ set: BackupSet, trigger: RunTrigger = .scheduled) async -> RunStatus {
        guard let primary = set.destinations.first(where: { $0.isPrimary }) else {
            logWarning("BackupEngine: backup set \"\(set.name)\" has no primary destination — cannot check")
            return .failed
        }
        guard await secretsAvailable(for: [primary]) else { return .skipped }

        let lock = makeSetLock(setId: set.id)
        guard lock.tryAcquire() else {
            recordSkipped(kind: .check, setId: set.id, destId: primary.id, trigger: trigger)
            return .skipped
        }
        defer { lock.release() }
        // Declared after the lock defer, so it unwinds *first*: the live
        // progress record is removed while the lock is still held, on every
        // exit path (T09 step 8 — "clear current-run, release lock").
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        // Attempt semantics, exactly like `lastBackupStart`.
        updateScheduleState(setId: set.id) { $0.lastCheckStart = self.now() }

        let totalSlices = set.checkPolicy?.readDataSubsetSlices ?? Self.defaultCheckSlices
        let previousState = stateStore.readScheduleState()?.sets[set.id]
        let slice = ScheduleMath.nextCheckSlice(
            cursor: previousState?.checkSliceCursor ?? 0,
            totalSlices: totalSlices
        )
        let checkCount = (previousState?.checkCount ?? 0) + 1

        let primaryCheck = await performChild(
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
        guard let primaryCheck else {
            return .skipped
        }
        var statuses = [primaryCheck.child.status]

        if primaryCheck.child.status == .success {
            // SAFETY: cursor advances only on success.
            updateScheduleState(setId: set.id) { state in
                state.checkSliceCursor = slice.newCursor
                state.checkCount = checkCount
            }

            if checkCount % Self.secondaryCheckEveryNChecks == 0 {
                for secondary in set.destinations where !secondary.isPrimary {
                    let probe = await reachability.probe(secondary)
                    record(probe: probe, for: secondary)
                    guard probe == .reachable else { continue }
                    let secondaryCheck = await performChild(
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
                    if let secondaryCheck {
                        statuses.append(secondaryCheck.child.status)
                    }
                }
            }
        }

        return Self.worstStatus(statuses)
    }

    // MARK: - runPrune

    /// The manual "apply retention now" action: `forget --prune` on the
    /// primary and on every secondary that is **not** a stale mirror.
    ///
    /// SAFETY: a secondary is pruned only when its `lastSyncedAt` is at least
    /// as recent as the primary's (the end of the primary's last successful
    /// backup). A mirror that has not received the newest snapshots must
    /// never have an aggressive policy applied to it — that is exactly the
    /// data-loss window invariant 2 describes. When the primary has never
    /// synced, no secondary is pruned.
    ///
    /// A dry run first is the UI's job (`ResticCommand.forget(dryRun:)`);
    /// this is the real one.
    public func runPrune(_ set: BackupSet) async -> RunStatus {
        guard let primary = set.destinations.first(where: { $0.isPrimary }) else {
            logWarning("BackupEngine: backup set \"\(set.name)\" has no primary destination — cannot prune")
            return .failed
        }
        guard let retention = set.retention, !retention.isEmpty else {
            // First half of the double guard: no policy, no forget, ever.
            logWarning(
                "BackupEngine: backup set \"\(set.name)\" has no retention policy — nothing to apply"
            )
            return .skipped
        }
        guard await secretsAvailable(for: [primary]) else { return .skipped }

        let lock = makeSetLock(setId: set.id)
        guard lock.tryAcquire() else {
            recordSkipped(kind: .prune, setId: set.id, destId: primary.id, trigger: .manual)
            return .skipped
        }
        defer { lock.release() }
        // Declared after the lock defer, so it unwinds *first*: the live
        // progress record is removed while the lock is still held, on every
        // exit path (T09 step 8 — "clear current-run, release lock").
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        guard let primaryPrune = await forgetChild(
            destination: primary,
            policy: retention,
            setId: set.id,
            trigger: .manual,
            groupId: nil
        ) else {
            return .skipped
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
            if let prune = await forgetChild(
                destination: secondary,
                policy: retention,
                setId: set.id,
                trigger: .manual,
                groupId: groupId
            ) {
                statuses.append(prune.child.status)
            }
        }

        return Self.worstStatus(statuses)
    }

    // MARK: - runRestore

    /// Restores from one destination under the **set** lock, so a restore
    /// can never run concurrently with a backup of the same set.
    ///
    /// Per-file `error` messages in the NDJSON stream downgrade an exit-0
    /// restore to `.warning` (`docs/restic-cli.md` §restore).
    public func runRestore(request: RestoreRequest) async -> RunStatus {
        guard let (set, destination) = locate(destId: request.destId) else {
            logWarning("BackupEngine: no configured destination with id \(request.destId) — cannot restore")
            return .failed
        }
        guard await secretsAvailable(for: [destination]) else { return .skipped }

        let lock = makeSetLock(setId: set.id)
        guard lock.tryAcquire() else {
            recordSkipped(kind: .restore, setId: set.id, destId: destination.id, trigger: .manual)
            return .skipped
        }
        defer { lock.release() }
        // Declared after the lock defer, so it unwinds *first*: the live
        // progress record is removed while the lock is still held, on every
        // exit path (T09 step 8 — "clear current-run, release lock").
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        let restore = await performChild(
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
        return restore?.child.status ?? .skipped
    }

    // MARK: - initSecondary

    /// `restic -r <secondary> init --json --from-repo <primary>
    /// --copy-chunker-params` — the chunker flag is non-negotiable
    /// (`docs/restic-cli.md` §init secondary): without it deduplication
    /// between primary and mirror is destroyed.
    public func initSecondary(_ set: BackupSet, dest: Destination) async -> RunStatus {
        guard let primary = set.destinations.first(where: { $0.isPrimary }) else {
            logWarning("BackupEngine: backup set \"\(set.name)\" has no primary destination")
            return .failed
        }
        guard !dest.isPrimary else {
            logWarning("BackupEngine: initSecondary refuses to run against the primary destination")
            return .failed
        }
        // Both repositories' passwords are needed (`RESTIC_PASSWORD_COMMAND`
        // and `RESTIC_FROM_PASSWORD_COMMAND`).
        guard await secretsAvailable(for: [dest, primary]) else { return .skipped }

        let lock = makeSetLock(setId: set.id)
        guard lock.tryAcquire() else {
            recordSkipped(kind: .`init`, setId: set.id, destId: dest.id, trigger: .manual)
            return .skipped
        }
        defer { lock.release() }
        // Declared after the lock defer, so it unwinds *first*: the live
        // progress record is removed while the lock is still held, on every
        // exit path (T09 step 8 — "clear current-run, release lock").
        defer { try? stateStore.clearCurrentRun(setId: set.id) }

        let initRun = await performChild(
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
        guard let initRun else { return .skipped }
        if initRun.child.status == .success {
            updateRepoStatus(destId: dest.id) { status in
                status.reachable = true
                status.probedAt = self.now()
                status.lastError = nil
            }
        }
        return initRun.child.status
    }

    // MARK: - forget (the only destructive command)

    /// The **single** place `forget` is ever invoked. Both guards live here:
    /// an absent or empty policy returns `nil` without spawning anything
    /// (and `ResticCommand.forget` would `precondition`-fail on an empty
    /// policy anyway — that is the second half of the double guard).
    ///
    /// Callers are responsible for the freshness half of the contract: never
    /// call this for a destination whose copy did not succeed in this run
    /// (`runSet`) or whose mirror is behind the primary (`runPrune`).
    private func forgetChild(
        destination: Destination,
        policy: RetentionPolicy?,
        setId: UUID,
        trigger: RunTrigger,
        groupId: String?
    ) async -> ChildRun? {
        guard let policy, !policy.isEmpty else {
            return nil
        }
        return await performChild(
            kind: .prune,
            setId: setId,
            destination: destination,
            trigger: trigger,
            groupId: groupId,
            phase: "retention",
            command: .forget(repo: destination.repoURL, policy: policy, prune: true),
            invocation: ResticInvocation(destination: destination),
            streamProgress: false
        )
    }

    // MARK: - Child runs

    /// A finished child run: its index projection plus the raw restic
    /// outcome (`nil` when restic never ran — e.g. an unreachable primary).
    private struct ChildRun {
        let child: SetRunChild
        let outcome: ResticOutcome?
    }

    /// Runs one restic command as one recorded run: `begin` → open the run
    /// log → optional pre-flight → execute (with the exit-11 unlock/retry
    /// protocol) → `finish` + index append.
    ///
    /// Returns `nil` only when the run record could not be created at all,
    /// in which case nothing was spawned.
    ///
    /// - Parameters:
    ///   - preflightPhase: written to `current-run` before `preflight` runs.
    ///   - preflight: returns a failure reason to abort the run *before*
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
        preflightPhase: String? = nil,
        preflight: (@Sendable (LogWriter?) async -> String?)? = nil,
        downgradeSuccessToWarning: (@Sendable (ResticOutcome) -> Bool)? = nil
    ) async -> ChildRun? {
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
            logWarning("BackupEngine: could not create a \(kind.rawValue) run record: \(error)")
            return nil
        }
        // Reproduces the exact spawned command line: `ResticRunner` prepends
        // the binary path from the same config value. Secrets never appear
        // in argv (`ResticCommand`'s invariant 1), so this is safe to persist.
        run.argvRedacted = [config.resticPath].compactMap { $0 } + command.argv

        let logWriter = try? LogWriter(url: paths.runLogFile(runId: run.runId), now: now)
        defer { logWriter?.close() }
        logWriter?.appendLine("$ \(run.argvRedacted.joined(separator: " "))")

        let reporter = progressReporter(setId: setId, run: run, phase: preflightPhase ?? phase)
        reporter.writePhaseMarker()
        reporter.startHeartbeat()
        defer { reporter.stopHeartbeat() }

        if let preflight, let reason = await preflight(logWriter) {
            logWriter?.appendLine("aborted: \(reason)")
            finish(run, status: .failed, errorSummary: reason)
            return ChildRun(
                child: SetRunChild(runId: run.runId, kind: kind, destId: destination.id, status: .failed),
                outcome: nil
            )
        }

        if preflightPhase != nil {
            reporter.beginPhase(phase)
        }

        let result = await execute(
            command,
            invocation: invocation,
            logWriter: logWriter,
            reporter: streamProgress ? reporter : nil
        )

        let status: RunStatus
        var errorSummary: String?
        var stats: BackupSummary?
        var exitCode: Int32?

        switch result {
        case .didNotRun(let reason):
            status = .failed
            errorSummary = reason
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
            default:
                status = .failed
                errorSummary = outcome.status.userFacingMessage
            }
        }

        finish(run, status: status, stats: stats, errorSummary: errorSummary, resticExitCode: exitCode)
        return ChildRun(
            child: SetRunChild(runId: run.runId, kind: kind, destId: destination.id, status: status),
            outcome: result.outcome
        )
    }

    /// The outcome of spawning (or failing to spawn) one restic child.
    private enum ExecuteResult {
        case ranToCompletion(ResticOutcome)
        /// restic produced no outcome at all (launch failure, timeout,
        /// secret read failure mid-run, cancellation).
        case didNotRun(reason: String)

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
        reporter: ProgressReporter?
    ) async -> ExecuteResult {
        let first = await spawn(command, invocation: invocation, logWriter: logWriter, reporter: reporter)
        guard case .ranToCompletion(let outcome) = first, outcome.status == .repoLocked else {
            return first
        }

        logWriter?.appendLine(
            "restic reported the repository as locked (exit 11); "
                + "running `unlock` to remove stale locks, then retrying once"
        )
        _ = await spawn(
            .unlock(repo: invocation.destination.repoURL),
            invocation: ResticInvocation(destination: invocation.destination),
            logWriter: logWriter,
            reporter: nil
        )
        logWriter?.appendLine("retrying after unlock (attempt 2 of 2)")
        return await spawn(command, invocation: invocation, logWriter: logWriter, reporter: reporter)
    }

    private func spawn(
        _ command: ResticCommand,
        invocation: ResticInvocation,
        logWriter: LogWriter?,
        reporter: ProgressReporter?
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
                }
            )
            return .ranToCompletion(outcome)
        } catch let error as ResticRunnerError {
            logWriter?.appendLine("restic did not run: \(error.description)")
            return .didNotRun(reason: error.userFacingMessage)
        } catch {
            logWriter?.appendLine("restic did not run: \(error)")
            return .didNotRun(reason: "The operation did not complete. Open the run log for details.")
        }
    }

    // MARK: - Run-record helpers

    private func finish(
        _ run: ActiveRun,
        status: RunStatus,
        stats: BackupSummary? = nil,
        errorSummary: String? = nil,
        resticExitCode: Int32? = nil
    ) {
        do {
            try runStore.finish(
                run,
                status: status,
                stats: stats,
                errorSummary: errorSummary,
                resticExitCode: resticExitCode
            )
        } catch {
            logWarning("BackupEngine: could not finish run \(run.runId): \(error)")
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

    /// `locks/set-<setId>.lock`. The lock directory is created first:
    /// `FileLock.tryAcquire()` reports `false` both for "held by someone
    /// else" and for "could not open the file", so on a fresh data directory
    /// a missing `locks/` would masquerade as a busy lock and every run
    /// would be skipped forever.
    private func makeSetLock(setId: UUID) -> FileLock {
        do {
            try paths.ensureDirectories()
        } catch {
            logWarning("BackupEngine: could not create the data directories: \(error)")
        }
        return FileLock(path: paths.setLockFile(setId: setId))
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

    private func updateScheduleState(setId: UUID, mutate: (inout SetScheduleState) -> Void) {
        do {
            try stateStore.updateScheduleState(setId: setId, mutate: mutate)
        } catch {
            logWarning("BackupEngine: could not update schedule state for set \(setId): \(error)")
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
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
