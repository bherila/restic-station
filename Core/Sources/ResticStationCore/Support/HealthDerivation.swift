import Foundation

// MARK: - AppHealth

/// The single global health state the menu bar icon renders
/// (`docs/ui-spec.md` §Menu bar). Deliberately UI-free: the SF Symbol
/// mapping lives in the App target, this is only the decision.
public enum AppHealth: String, Equatable, Sendable, CaseIterable {
    /// Nothing running, nothing wrong.
    case idle
    /// At least one run is in flight — and in flight means a process is
    /// still alive to run it (`RunStore.liveness(ofCurrentRun:)`), not
    /// merely that a `current-run-*.json` exists. Takes precedence over
    /// `.warning`: while restic is working, "working" is the more
    /// informative state.
    case running
    /// Last run of any set failed, OR any destination is stale, OR a run was
    /// killed and left its `current-run-*.json` behind, OR the Full Disk
    /// Access probe came back denied, OR a first backup is overdue, OR the
    /// scheduler is known not to be registered (so scheduled backups are not
    /// actually happening).
    case warning
}

// MARK: - SetHealth

/// Everything the UI needs to say about one backup set's health, derived
/// from the on-disk state (`runs/index.jsonl`, `state/*.json`) plus the
/// set's own configuration. Pure data — no formatting, no localization: the
/// menu bar's "2 hours ago" and the badge glyphs are the view's job.
public struct SetHealth: Identifiable, Equatable, Sendable {
    public var id: UUID { setId }

    public let setId: UUID
    public let name: String
    /// Newest **finished** `backup` run for this set (`nil` = never backed
    /// up). This is what "last backup" means in the menu bar.
    public let lastBackup: RunIndexEntry?
    /// Newest **finished** run of any kind for this set — a failed `copy` to
    /// a secondary or a failed `prune` is a problem worth warning about even
    /// when the primary backup itself succeeded.
    public let lastRun: RunIndexEntry?
    /// Live progress, from `state/current-run-<setId>.json`. Non-`nil` ⟺
    /// a run is in flight for this set **and the process running it is still
    /// alive** — see `abandonedRun` for the other case.
    public let currentRun: CurrentRunState?
    /// A `state/current-run-<setId>.json` whose process is gone
    /// (`RunStore.liveness(ofCurrentRun:) == .abandoned`): a run that was
    /// `SIGKILL`ed, OOM-killed or cut off by a power failure and never got to
    /// clean up after itself.
    ///
    /// Kept as data rather than silently discarded for two reasons. It is not
    /// running, so it must not pin `AppHealth` to `.running` — that is the
    /// bug this field exists to fix, where one killed run made every
    /// subsequent health check report green forever. And it is not *nothing*
    /// either: a killed backup is worth a warning badge and a message naming
    /// the file, which is what `needsAttention` and `status`'s output do with
    /// it. The tick clears it on its next pass (`RunStore.recoverInterrupted`
    /// + `Tick` step 3), so on a healthy host this is transient.
    public let abandonedRun: CurrentRunState?
    /// This set has no run history, no recorded backup attempt and no run in
    /// flight, and has remained visible on this machine beyond the larger of
    /// one schedule period and 24 hours. It closes the fresh-install hole
    /// where an absent scheduler or unusable restic could otherwise leave a
    /// never-run set healthy forever.
    public let firstBackupOverdue: Bool
    /// Destinations of this set that are stale per `docs/scheduling.md`
    /// §Staleness, in the set's configured destination order.
    public let staleDestinationIds: [UUID]
    /// Display-only next fire time from `ScheduleMath.nextDue` — the app
    /// never decides when backups run (`docs/scheduling.md` §What the app
    /// does). `.distantPast` for a never-run set (i.e. due now).
    public let nextDue: Date

    public init(
        setId: UUID,
        name: String,
        lastBackup: RunIndexEntry?,
        lastRun: RunIndexEntry?,
        currentRun: CurrentRunState?,
        staleDestinationIds: [UUID],
        nextDue: Date,
        abandonedRun: CurrentRunState? = nil,
        firstBackupOverdue: Bool = false
    ) {
        self.setId = setId
        self.name = name
        self.lastBackup = lastBackup
        self.lastRun = lastRun
        self.currentRun = currentRun
        self.staleDestinationIds = staleDestinationIds
        self.nextDue = nextDue
        self.abandonedRun = abandonedRun
        self.firstBackupOverdue = firstBackupOverdue
    }

    public var isRunning: Bool { currentRun != nil }

    public var hasEverBackedUp: Bool { lastBackup != nil }

    /// End time of the last backup, falling back to its start (an index
    /// entry only lacks `end` while it is still running, which
    /// `lastBackup` excludes — the fallback is belt-and-braces).
    public var lastBackupAt: Date? {
        guard let lastBackup else { return nil }
        return lastBackup.end ?? lastBackup.start
    }

    public var lastBackupStatus: RunStatus? { lastBackup?.status }

    public var lastRunFailed: Bool { lastRun?.status == .failed }

    public var hasStaleDestination: Bool { !staleDestinationIds.isEmpty }

    public var hasAbandonedRun: Bool { abandonedRun != nil }

    /// This set contributes `.warning` to the global `AppHealth`.
    public var needsAttention: Bool {
        lastRunFailed || hasStaleDestination || hasAbandonedRun || firstBackupOverdue
    }

    /// 0...100, rounded, clamped — restic reports `percent_done` as a 0...1
    /// fraction (`docs/data-model.md` §current-run). `nil` when not running.
    public var progressPercent: Int? {
        guard let currentRun else { return nil }
        let clamped = min(max(currentRun.percentDone, 0), 1)
        return Int((clamped * 100).rounded())
    }

    public func isOverdue(now: Date) -> Bool { nextDue <= now }
}

// MARK: - HealthDerivation

/// Pure derivation of `SetHealth`/`AppHealth` from config + on-disk state.
///
/// Extracted into Core (rather than living in the view model) because it is
/// the only part of the app shell with real decision logic: which run counts
/// as "the last one", when a destination is stale, and what makes the menu
/// bar icon turn yellow. All inputs are parameters — no clock, no calendar,
/// no filesystem — so every rule is unit-testable.
public enum HealthDerivation {

    // MARK: All sets

    /// `SetHealth` for every set in `config`, in config order.
    ///
    /// - Parameters:
    ///   - recentRuns: `RunStore.recentRuns` output, **newest first**
    ///     (as published by the app's `StateWatcher`).
    ///   - currentRuns: every `state/current-run-<setId>.json` that exists,
    ///     keyed by `BackupSet.id` — live *and* abandoned; `isRunAbandoned`
    ///     is what tells the two apart.
    ///   - repoStatuses: destination status keyed by `Destination.id`.
    ///   - scheduleState: `state/schedule-state.json`, or `nil` if absent.
    ///   - visibleSince: later mtime of `config.json` and `machine.json`, or
    ///     `nil` when unavailable. Injected to keep this derivation pure.
    ///   - isRunAbandoned: `RunStore.liveness(ofCurrentRun:) == .abandoned`
    ///     in production. Injected rather than called directly because this
    ///     type is pure by contract (no clock, no filesystem) and the answer
    ///     needs to read `runs/<runId>/metadata.json`.
    public static func setHealths(
        config: AppConfig,
        recentRuns: [RunIndexEntry],
        currentRuns: [UUID: CurrentRunState],
        repoStatuses: [UUID: RepoStatus],
        scheduleState: ScheduleState?,
        now: Date,
        calendar: Calendar,
        visibleSince: Date? = nil,
        isRunAbandoned: (CurrentRunState) -> Bool = { _ in false }
    ) -> [SetHealth] {
        config.sets.map { set in
            setHealth(
                set: set,
                recentRuns: recentRuns,
                currentRun: currentRuns[set.id],
                repoStatuses: repoStatuses,
                setScheduleState: scheduleState?.sets[set.id],
                now: now,
                calendar: calendar,
                visibleSince: visibleSince,
                isRunAbandoned: isRunAbandoned
            )
        }
    }

    // MARK: One set

    public static func setHealth(
        set: BackupSet,
        recentRuns: [RunIndexEntry],
        currentRun: CurrentRunState?,
        repoStatuses: [UUID: RepoStatus],
        setScheduleState: SetScheduleState?,
        now: Date,
        calendar: Calendar,
        visibleSince: Date? = nil,
        isRunAbandoned: (CurrentRunState) -> Bool = { _ in false }
    ) -> SetHealth {
        // `recentRuns` is newest-first, so the first match in each filter is
        // the most recent one. `.running` entries are skipped: an in-flight
        // run is reported by `currentRun`, and treating it as "the last
        // result" would make every backup look like it had no outcome.
        let runsForSet = recentRuns.filter { $0.setId == set.id && $0.status != .running }
        let lastBackup = runsForSet.first { $0.kind == .backup }
        let lastRun = runsForSet.first

        // "A destination with no successful sync ever counts as stale once
        // its set has >= 1 successful backup" (docs/scheduling.md
        // §Staleness) — a warning badge before the first backup has ever
        // succeeded would just be noise.
        let hasSuccessfulBackup = runsForSet.contains {
            $0.kind == .backup && ($0.status == .success || $0.status == .warning)
        }

        let staleDestinationIds = set.destinations
            .filter { destination in
                isDestinationStale(
                    status: repoStatuses[destination.id],
                    stalenessWarningDays: set.stalenessWarningDays,
                    setHasSuccessfulBackup: hasSuccessfulBackup,
                    now: now
                )
            }
            .map(\.id)

        // One progress file, two possible meanings. Splitting it here — the
        // single place that reads it — is what keeps every consumer honest:
        // `isRunning`, `progressPercent` and `AppHealth.running` all follow
        // `currentRun`, and none of them can be fooled by wreckage again.
        let abandonedRun = currentRun.flatMap { isRunAbandoned($0) ? $0 : nil }

        let neverAttempted = setScheduleState?.lastBackupStart == nil
            && runsForSet.isEmpty
            && currentRun == nil
        let firstBackupOverdue: Bool
        if neverAttempted, let visibleSince {
            // A future mtime is clock skew, not evidence that the set has
            // been visible for a negative or wraparound duration.
            let boundedVisibleSince = min(visibleSince, now)
            let minimumGrace: TimeInterval = 24 * 60 * 60
            let grace = max(ScheduleMath.approximatePeriod(of: set.schedule), minimumGrace)
            firstBackupOverdue = now.timeIntervalSince(boundedVisibleSince) > grace
        } else {
            firstBackupOverdue = false
        }

        return SetHealth(
            setId: set.id,
            name: set.name,
            lastBackup: lastBackup,
            lastRun: lastRun,
            currentRun: abandonedRun == nil ? currentRun : nil,
            staleDestinationIds: staleDestinationIds,
            nextDue: nextDue(
                schedule: set.schedule,
                lastBackupStart: setScheduleState?.lastBackupStart,
                now: now,
                calendar: calendar
            ),
            abandonedRun: abandonedRun,
            firstBackupOverdue: firstBackupOverdue
        )
    }

    // MARK: Staleness

    /// `stale ⟺ now − lastSyncedAt > stalenessWarningDays`
    /// (`docs/scheduling.md` §Staleness). A destination that has never
    /// synced (no status file, or `lastSyncedAt == nil`) is stale exactly
    /// when its set has already backed up successfully at least once.
    public static func isDestinationStale(
        status: RepoStatus?,
        stalenessWarningDays: Int,
        setHasSuccessfulBackup: Bool,
        now: Date
    ) -> Bool {
        guard let lastSyncedAt = status?.lastSyncedAt else {
            return setHasSuccessfulBackup
        }
        return now.timeIntervalSince(lastSyncedAt) > Double(stalenessWarningDays) * 24 * 60 * 60
    }

    // MARK: Next due (display only)

    /// `ScheduleMath.nextDue` with the same clock-skew clamp `isDue`
    /// applies (rule 5): a `lastBackupStart` in the future means the clock
    /// moved backwards, and displaying a next-due time derived from it
    /// would be nonsense.
    public static func nextDue(
        schedule: Schedule,
        lastBackupStart: Date?,
        now: Date,
        calendar: Calendar
    ) -> Date {
        let effectiveLastStart: Date?
        if let lastBackupStart, lastBackupStart > now {
            effectiveLastStart = now
        } else {
            effectiveLastStart = lastBackupStart
        }
        return ScheduleMath.nextDue(after: effectiveLastStart, schedule: schedule, calendar: calendar)
    }

    // MARK: Global

    /// Interprets `state/fda-check.json` for `appHealth(…)`'s
    /// `fullDiskAccessDenied` parameter — the one place the absent-file
    /// semantics are defined.
    ///
    /// **Absent means "not applicable", never "denied".** The file is absent
    /// in two situations and neither is a problem:
    ///
    /// - macOS, before the first `fda-check` has run (fresh install).
    /// - Linux, always: there is no TCC, so `fda-check` deliberately writes
    ///   nothing (T25). A fake "granted" record would make the file's
    ///   meaning platform-dependent, so the helper writes no record at all
    ///   and readers must not infer a denial from its absence.
    ///
    /// Only a record that explicitly says `hasFullDiskAccess == false` is a
    /// denial.
    public static func fullDiskAccessDenied(from record: FdaCheckResult?) -> Bool {
        guard let record else { return false }
        return !record.hasFullDiskAccess
    }

    /// The menu bar icon's state.
    ///
    /// `.running` still outranks `.warning` — while restic is working,
    /// "working" is the more informative state — but only a *live* run
    /// counts. Before `isRunAbandoned` existed, one `SIGKILL`ed run left a
    /// `current-run-*.json` that nothing ever deleted, and this function
    /// returned `.running` from then until the end of time: green menu bar,
    /// `status` exit 0, no backups. The precedence is unchanged; what
    /// changed is that "in flight" now has to be true.
    ///
    /// - Parameters:
    ///   - runsInFlight: *every* `current-run-*.json` on disk, including one
    ///     belonging to a set that is no longer in the config (a run started
    ///     before the set was deleted is still running, and its wreckage is
    ///     still wreckage). `setHealths` only covers configured sets, which
    ///     is why this is a separate parameter rather than derived from it.
    ///   - isRunAbandoned: see `setHealths(…)`. Must be the same predicate
    ///     passed there, or the two halves of this decision disagree.
    ///   - fullDiskAccessDenied: from `state/fda-check.json`, via
    ///     `fullDiskAccessDenied(from:)` — "not yet known" (or "not
    ///     applicable on this platform") must not paint the icon yellow,
    ///     only a definite `hasFullDiskAccess == false` does.
    ///   - backgroundAgentEnabled: is the scheduler actually registered —
    ///     `SMAppService.Status == .enabled` on macOS, the systemd `--user`
    ///     timer's health on Linux. **`nil` means "could not tell"** and
    ///     contributes nothing, the same rule `fullDiskAccessDenied(from:)`
    ///     applies to an absent probe: only a definite `false` is a warning.
    ///     A caller that passes `nil` is stating it has no view of the
    ///     scheduler, which is a real answer; passing `true` to mean that
    ///     would be a lie, and was one.
    public static func appHealth(
        setHealths: [SetHealth],
        runsInFlight: [CurrentRunState],
        fullDiskAccessDenied: Bool,
        backgroundAgentEnabled: Bool?,
        isRunAbandoned: (CurrentRunState) -> Bool = { _ in false }
    ) -> AppHealth {
        let liveRuns = runsInFlight.filter { !isRunAbandoned($0) }
        if !liveRuns.isEmpty || setHealths.contains(where: \.isRunning) {
            return .running
        }
        if hasWarningConditions(
            setHealths: setHealths,
            runsInFlight: runsInFlight,
            fullDiskAccessDenied: fullDiskAccessDenied,
            backgroundAgentEnabled: backgroundAgentEnabled,
            isRunAbandoned: isRunAbandoned
        ) {
            return .warning
        }
        return .idle
    }

    /// The warning conditions **on their own**, with the `.running`
    /// precedence removed.
    ///
    /// `appHealth` is a single glyph for a menu bar, so one state has to win
    /// and `.running` reasonably does: while restic is working, "working" is
    /// the more informative thing to show. An exit code is not a glyph. A
    /// monitoring script asking "is anything wrong here?" during a
    /// three-hour backup must still be told that the timer is disabled, and
    /// `health == .warning` cannot tell it — `.running` got there first.
    ///
    /// So `status` exits on this, and the menu bar renders `appHealth`. Same
    /// inputs, same rules, different question. Keeping them as two functions
    /// over one shared predicate is what stops them drifting: there is no
    /// second copy of "what counts as a problem".
    public static func hasWarningConditions(
        setHealths: [SetHealth],
        runsInFlight: [CurrentRunState],
        fullDiskAccessDenied: Bool,
        backgroundAgentEnabled: Bool?,
        isRunAbandoned: (CurrentRunState) -> Bool = { _ in false }
    ) -> Bool {
        // An abandoned run for a set that is no longer configured has no
        // `SetHealth` to carry it, so it is counted here directly — otherwise
        // deleting a set would be a way to silence the warning about the run
        // it was killed in the middle of.
        let abandonedRuns = runsInFlight.filter(isRunAbandoned).count
        return setHealths.contains(where: \.needsAttention)
            || abandonedRuns > 0
            || fullDiskAccessDenied
            || backgroundAgentEnabled == false
    }
}
