import Foundation

// MARK: - AppHealth

/// The single global health state the menu bar icon renders
/// (`docs/ui-spec.md` §Menu bar). Deliberately UI-free: the SF Symbol
/// mapping lives in the App target, this is only the decision.
public enum AppHealth: String, Equatable, Sendable, CaseIterable {
    /// Nothing running, nothing wrong.
    case idle
    /// At least one run is in flight. Takes precedence over `.warning` —
    /// while restic is working, "working" is the more informative state.
    case running
    /// Last run of any set failed, OR any destination is stale, OR the Full
    /// Disk Access probe came back denied, OR the background agent is not
    /// enabled (so scheduled backups are not actually happening).
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
    /// a run is in flight for this set.
    public let currentRun: CurrentRunState?
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
        nextDue: Date
    ) {
        self.setId = setId
        self.name = name
        self.lastBackup = lastBackup
        self.lastRun = lastRun
        self.currentRun = currentRun
        self.staleDestinationIds = staleDestinationIds
        self.nextDue = nextDue
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

    /// This set contributes `.warning` to the global `AppHealth`.
    public var needsAttention: Bool { lastRunFailed || hasStaleDestination }

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
    ///   - currentRuns: live progress keyed by `BackupSet.id`.
    ///   - repoStatuses: destination status keyed by `Destination.id`.
    ///   - scheduleState: `state/schedule-state.json`, or `nil` if absent.
    public static func setHealths(
        config: AppConfig,
        recentRuns: [RunIndexEntry],
        currentRuns: [UUID: CurrentRunState],
        repoStatuses: [UUID: RepoStatus],
        scheduleState: ScheduleState?,
        now: Date,
        calendar: Calendar
    ) -> [SetHealth] {
        config.sets.map { set in
            setHealth(
                set: set,
                recentRuns: recentRuns,
                currentRun: currentRuns[set.id],
                repoStatuses: repoStatuses,
                setScheduleState: scheduleState?.sets[set.id],
                now: now,
                calendar: calendar
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
        calendar: Calendar
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

        return SetHealth(
            setId: set.id,
            name: set.name,
            lastBackup: lastBackup,
            lastRun: lastRun,
            currentRun: currentRun,
            staleDestinationIds: staleDestinationIds,
            nextDue: nextDue(
                schedule: set.schedule,
                lastBackupStart: setScheduleState?.lastBackupStart,
                now: now,
                calendar: calendar
            )
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
    /// - Parameters:
    ///   - anyRunInFlight: `true` when *any* `current-run-*.json` exists,
    ///     including one belonging to a set that is no longer in the config
    ///     (a run started before the set was deleted is still running).
    ///   - fullDiskAccessDenied: from `state/fda-check.json`, via
    ///     `fullDiskAccessDenied(from:)` — "not yet known" (or "not
    ///     applicable on this platform") must not paint the icon yellow,
    ///     only a definite `hasFullDiskAccess == false` does.
    ///   - backgroundAgentEnabled: `SMAppService.Status == .enabled`.
    ///     Anything else means scheduled backups are not running.
    public static func appHealth(
        setHealths: [SetHealth],
        anyRunInFlight: Bool,
        fullDiskAccessDenied: Bool,
        backgroundAgentEnabled: Bool
    ) -> AppHealth {
        if anyRunInFlight || setHealths.contains(where: \.isRunning) {
            return .running
        }
        if setHealths.contains(where: \.needsAttention)
            || fullDiskAccessDenied
            || !backgroundAgentEnabled {
            return .warning
        }
        return .idle
    }
}
