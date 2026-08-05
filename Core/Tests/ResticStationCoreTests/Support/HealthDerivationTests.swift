import Foundation
import Testing
@testable import ResticStationCore

// Rules under test: `docs/scheduling.md` §Staleness, `docs/ui-spec.md`
// §Menu bar (icon states), and the T13 spec for `SetHealth`/`AppHealth`.
// Every date is explicit; no `Date()`, no `Calendar.current`.

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func date(_ calendar: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var components = DateComponents()
    components.year = y
    components.month = mo
    components.day = d
    components.hour = h
    components.minute = mi
    return calendar.date(from: components)!
}

private let setId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let primaryId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let secondaryId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

private func makeSet(
    schedule: Schedule = .daily(hour: 2, minute: 30),
    stalenessWarningDays: Int = 14,
    withSecondary: Bool = true
) -> BackupSet {
    var destinations = [
        Destination(id: primaryId, label: "Primary", repoURL: "/tmp/primary", isPrimary: true)
    ]
    if withSecondary {
        destinations.append(
            Destination(id: secondaryId, label: "External", repoURL: "/Volumes/Backup/repo", isPrimary: false)
        )
    }
    return BackupSet(
        id: setId,
        name: "Projects",
        sources: ["/Users/someone/Projects"],
        schedule: schedule,
        stalenessWarningDays: stalenessWarningDays,
        destinations: destinations
    )
}

private func run(
    kind: RunKind = .backup,
    status: RunStatus = .success,
    destId: UUID = primaryId,
    start: Date,
    end: Date?
) -> RunIndexEntry {
    RunIndexEntry(
        runId: "\(start.timeIntervalSince1970)-\(kind.rawValue)",
        kind: kind,
        setId: setId,
        destId: destId,
        groupId: "group",
        status: status,
        start: start,
        end: end,
        trigger: .scheduled,
        snapshotId: nil,
        filesNew: nil,
        filesChanged: nil,
        dataAdded: nil,
        errorSummary: nil
    )
}

private func currentRun(percentDone: Double, phase: String = "backing-up-primary") -> CurrentRunState {
    CurrentRunState(
        runId: "run",
        kind: .backup,
        phase: phase,
        percentDone: percentDone,
        bytesDone: 1,
        totalBytes: 2,
        filesDone: 1,
        totalFiles: 2,
        currentFiles: [],
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Last run selection

@Suite struct SetHealthLastRunTests {
    @Test func neverRunSetHasNoLastBackup() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let health = HealthDerivation.setHealth(
            set: makeSet(),
            recentRuns: [],
            currentRun: nil,
            repoStatuses: [:],
            setScheduleState: nil,
            now: now,
            calendar: calendar
        )
        #expect(health.lastBackup == nil)
        #expect(!health.hasEverBackedUp)
        #expect(health.lastBackupAt == nil)
        #expect(health.nextDue == .distantPast)
        #expect(health.isOverdue(now: now))
    }

    @Test func newestFinishedBackupWins() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let older = run(start: date(calendar, 2026, 7, 24, 2, 30), end: date(calendar, 2026, 7, 24, 2, 40))
        let newer = run(start: date(calendar, 2026, 7, 25, 2, 30), end: date(calendar, 2026, 7, 25, 2, 41))
        // Newest-first, as published by StateWatcher.
        let health = HealthDerivation.setHealth(
            set: makeSet(),
            recentRuns: [newer, older],
            currentRun: nil,
            repoStatuses: [:],
            setScheduleState: nil,
            now: now,
            calendar: calendar
        )
        #expect(health.lastBackup == newer)
        #expect(health.lastBackupAt == newer.end)
    }

    @Test func inFlightRunIsNotTreatedAsTheLastResult() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let running = run(status: .running, start: date(calendar, 2026, 7, 26, 2, 30), end: nil)
        let finished = run(start: date(calendar, 2026, 7, 25, 2, 30), end: date(calendar, 2026, 7, 25, 2, 40))
        let health = HealthDerivation.setHealth(
            set: makeSet(),
            recentRuns: [running, finished],
            currentRun: currentRun(percentDone: 0.42),
            repoStatuses: [:],
            setScheduleState: nil,
            now: now,
            calendar: calendar
        )
        #expect(health.lastBackup == finished)
        #expect(health.isRunning)
        #expect(health.progressPercent == 42)
    }

    @Test func runsForOtherSetsAreIgnored() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        var otherSetRun = run(start: date(calendar, 2026, 7, 26, 2, 30), end: date(calendar, 2026, 7, 26, 2, 40))
        otherSetRun.setId = UUID()
        let mine = run(start: date(calendar, 2026, 7, 25, 2, 30), end: date(calendar, 2026, 7, 25, 2, 40))
        let health = HealthDerivation.setHealth(
            set: makeSet(),
            recentRuns: [otherSetRun, mine],
            currentRun: nil,
            repoStatuses: [:],
            setScheduleState: nil,
            now: now,
            calendar: calendar
        )
        #expect(health.lastBackup == mine)
        #expect(health.lastRun == mine)
    }

    @Test func failedCopyCountsAsTheLastRunEvenWhenTheBackupSucceeded() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let failedCopy = run(
            kind: .copy,
            status: .failed,
            destId: secondaryId,
            start: date(calendar, 2026, 7, 26, 2, 45),
            end: date(calendar, 2026, 7, 26, 2, 46)
        )
        let backup = run(start: date(calendar, 2026, 7, 26, 2, 30), end: date(calendar, 2026, 7, 26, 2, 40))
        let health = HealthDerivation.setHealth(
            set: makeSet(),
            recentRuns: [failedCopy, backup],
            currentRun: nil,
            repoStatuses: [:],
            setScheduleState: nil,
            now: now,
            calendar: calendar
        )
        #expect(health.lastBackupStatus == .success)
        #expect(health.lastRunFailed)
        #expect(health.needsAttention)
    }

    @Test func progressPercentIsClampedAndRounded() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        func percent(_ fraction: Double) -> Int? {
            HealthDerivation.setHealth(
                set: makeSet(),
                recentRuns: [],
                currentRun: currentRun(percentDone: fraction),
                repoStatuses: [:],
                setScheduleState: nil,
                now: now,
                calendar: calendar
            ).progressPercent
        }
        #expect(percent(0) == 0)
        #expect(percent(0.005) == 1)
        #expect(percent(0.666) == 67)
        #expect(percent(1) == 100)
        #expect(percent(1.5) == 100)
        #expect(percent(-0.2) == 0)
    }
}

// MARK: - Staleness

@Suite struct StalenessTests {
    @Test func syncedWithinThresholdIsNotStale() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let status = RepoStatus(
            destId: secondaryId,
            reachable: true,
            probedAt: now,
            lastSyncedAt: date(calendar, 2026, 7, 20, 12, 0)
        )
        #expect(!HealthDerivation.isDestinationStale(
            status: status,
            stalenessWarningDays: 14,
            setHasSuccessfulBackup: true,
            now: now
        ))
    }

    @Test func syncedLongerAgoThanThresholdIsStale() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let status = RepoStatus(
            destId: secondaryId,
            reachable: false,
            probedAt: now,
            lastSyncedAt: date(calendar, 2026, 7, 1, 12, 0)
        )
        #expect(HealthDerivation.isDestinationStale(
            status: status,
            stalenessWarningDays: 14,
            setHasSuccessfulBackup: true,
            now: now
        ))
    }

    @Test func thresholdIsStrictlyGreaterThan() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let exactly14Days = now.addingTimeInterval(-14 * 24 * 60 * 60)
        let status = RepoStatus(destId: secondaryId, reachable: true, probedAt: now, lastSyncedAt: exactly14Days)
        #expect(!HealthDerivation.isDestinationStale(
            status: status,
            stalenessWarningDays: 14,
            setHasSuccessfulBackup: true,
            now: now
        ))
        let justOver = now.addingTimeInterval(-14 * 24 * 60 * 60 - 1)
        let overStatus = RepoStatus(destId: secondaryId, reachable: true, probedAt: now, lastSyncedAt: justOver)
        #expect(HealthDerivation.isDestinationStale(
            status: overStatus,
            stalenessWarningDays: 14,
            setHasSuccessfulBackup: true,
            now: now
        ))
    }

    @Test func neverSyncedIsStaleOnlyAfterASuccessfulBackup() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let neverSynced = RepoStatus(destId: secondaryId, reachable: false, probedAt: now, lastSyncedAt: nil)
        #expect(HealthDerivation.isDestinationStale(
            status: neverSynced,
            stalenessWarningDays: 14,
            setHasSuccessfulBackup: true,
            now: now
        ))
        #expect(!HealthDerivation.isDestinationStale(
            status: neverSynced,
            stalenessWarningDays: 14,
            setHasSuccessfulBackup: false,
            now: now
        ))
        // No status file at all behaves the same way.
        #expect(HealthDerivation.isDestinationStale(
            status: nil,
            stalenessWarningDays: 14,
            setHasSuccessfulBackup: true,
            now: now
        ))
        #expect(!HealthDerivation.isDestinationStale(
            status: nil,
            stalenessWarningDays: 14,
            setHasSuccessfulBackup: false,
            now: now
        ))
    }

    @Test func perSetThresholdIsHonored() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let lastSynced = date(calendar, 2026, 7, 23, 12, 0) // 3 days ago
        let status = RepoStatus(destId: secondaryId, reachable: true, probedAt: now, lastSyncedAt: lastSynced)
        #expect(!HealthDerivation.isDestinationStale(
            status: status,
            stalenessWarningDays: 14,
            setHasSuccessfulBackup: true,
            now: now
        ))
        #expect(HealthDerivation.isDestinationStale(
            status: status,
            stalenessWarningDays: 2,
            setHasSuccessfulBackup: true,
            now: now
        ))
    }

    @Test func staleDestinationsAreListedInConfigOrder() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let backup = run(start: date(calendar, 2026, 7, 26, 2, 30), end: date(calendar, 2026, 7, 26, 2, 40))
        let statuses: [UUID: RepoStatus] = [
            primaryId: RepoStatus(
                destId: primaryId,
                reachable: true,
                probedAt: now,
                lastSyncedAt: date(calendar, 2026, 7, 26, 2, 40)
            ),
            secondaryId: RepoStatus(
                destId: secondaryId,
                reachable: false,
                probedAt: now,
                lastSyncedAt: date(calendar, 2026, 5, 1, 0, 0)
            )
        ]
        let health = HealthDerivation.setHealth(
            set: makeSet(),
            recentRuns: [backup],
            currentRun: nil,
            repoStatuses: statuses,
            setScheduleState: nil,
            now: now,
            calendar: calendar
        )
        #expect(health.staleDestinationIds == [secondaryId])
        #expect(health.hasStaleDestination)
        #expect(health.needsAttention)
    }

    @Test func aSkippedBackupDoesNotCountAsASuccessfulSync() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let skipped = run(
            status: .skipped,
            start: date(calendar, 2026, 7, 26, 2, 30),
            end: date(calendar, 2026, 7, 26, 2, 30)
        )
        let health = HealthDerivation.setHealth(
            set: makeSet(),
            recentRuns: [skipped],
            currentRun: nil,
            repoStatuses: [:],
            setScheduleState: nil,
            now: now,
            calendar: calendar
        )
        #expect(health.staleDestinationIds.isEmpty)
    }
}

// MARK: - Next due

@Suite struct SetHealthNextDueTests {
    @Test func nextDueMatchesScheduleMath() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let lastStart = date(calendar, 2026, 7, 26, 2, 30)
        let schedule = Schedule.daily(hour: 2, minute: 30)
        let health = HealthDerivation.setHealth(
            set: makeSet(schedule: schedule),
            recentRuns: [],
            currentRun: nil,
            repoStatuses: [:],
            setScheduleState: SetScheduleState(lastBackupStart: lastStart),
            now: now,
            calendar: calendar
        )
        #expect(health.nextDue == ScheduleMath.nextDue(after: lastStart, schedule: schedule, calendar: calendar))
        #expect(health.nextDue == date(calendar, 2026, 7, 27, 2, 30))
        #expect(!health.isOverdue(now: now))
    }

    @Test func futureLastStartIsClampedToNow() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        // Clock moved backwards: recorded start is "tomorrow".
        let skewed = date(calendar, 2026, 7, 27, 2, 30)
        let schedule = Schedule.daily(hour: 2, minute: 30)
        let nextDue = HealthDerivation.nextDue(
            schedule: schedule,
            lastBackupStart: skewed,
            now: now,
            calendar: calendar
        )
        #expect(nextDue == date(calendar, 2026, 7, 27, 2, 30))
        #expect(nextDue > now)
    }
}

// MARK: - AppHealth

@Suite struct AppHealthTests {
    private func health(
        running: Bool = false,
        failed: Bool = false,
        stale: Bool = false
    ) -> SetHealth {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return SetHealth(
            setId: setId,
            name: "Projects",
            lastBackup: nil,
            lastRun: failed
                ? run(status: .failed, start: now, end: now)
                : nil,
            currentRun: running ? currentRun(percentDone: 0.5) : nil,
            staleDestinationIds: stale ? [secondaryId] : [],
            nextDue: .distantPast
        )
    }

    @Test func everythingHealthyIsIdle() {
        #expect(HealthDerivation.appHealth(
            setHealths: [health()],
            anyRunInFlight: false,
            fullDiskAccessDenied: false,
            backgroundAgentEnabled: true
        ) == .idle)
    }

    @Test func noSetsAtAllWithAWorkingAgentIsIdle() {
        #expect(HealthDerivation.appHealth(
            setHealths: [],
            anyRunInFlight: false,
            fullDiskAccessDenied: false,
            backgroundAgentEnabled: true
        ) == .idle)
    }

    @Test func runningBeatsEveryWarning() {
        #expect(HealthDerivation.appHealth(
            setHealths: [health(running: true, failed: true, stale: true)],
            anyRunInFlight: true,
            fullDiskAccessDenied: true,
            backgroundAgentEnabled: false
        ) == .running)
    }

    @Test func runInFlightForADeletedSetStillCountsAsRunning() {
        #expect(HealthDerivation.appHealth(
            setHealths: [],
            anyRunInFlight: true,
            fullDiskAccessDenied: false,
            backgroundAgentEnabled: true
        ) == .running)
    }

    @Test func failedLastRunIsAWarning() {
        #expect(HealthDerivation.appHealth(
            setHealths: [health(), health(failed: true)],
            anyRunInFlight: false,
            fullDiskAccessDenied: false,
            backgroundAgentEnabled: true
        ) == .warning)
    }

    @Test func staleDestinationIsAWarning() {
        #expect(HealthDerivation.appHealth(
            setHealths: [health(stale: true)],
            anyRunInFlight: false,
            fullDiskAccessDenied: false,
            backgroundAgentEnabled: true
        ) == .warning)
    }

    @Test func deniedFullDiskAccessIsAWarning() {
        #expect(HealthDerivation.appHealth(
            setHealths: [health()],
            anyRunInFlight: false,
            fullDiskAccessDenied: true,
            backgroundAgentEnabled: true
        ) == .warning)
    }

    // MARK: fda-check.json absent-file semantics (T25)

    @Test("an absent fda-check.json is 'not applicable', never 'denied'")
    func absentFdaCheckIsNotADenial() {
        // Absent on Linux always (no TCC, so `fda-check` writes nothing) and
        // on macOS until the first probe runs.
        #expect(HealthDerivation.fullDiskAccessDenied(from: nil) == false)
        #expect(HealthDerivation.appHealth(
            setHealths: [health()],
            anyRunInFlight: false,
            fullDiskAccessDenied: HealthDerivation.fullDiskAccessDenied(from: nil),
            backgroundAgentEnabled: true
        ) == .idle)
    }

    @Test("only an explicit hasFullDiskAccess == false is a denial")
    func onlyAnExplicitDenialCounts() {
        let granted = FdaCheckResult(
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
            hasFullDiskAccess: true,
            probedPath: "~/Library/Safari",
            context: "launchd"
        )
        let denied = FdaCheckResult(
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
            hasFullDiskAccess: false,
            probedPath: "~/Library/Safari",
            context: "launchd"
        )
        #expect(HealthDerivation.fullDiskAccessDenied(from: granted) == false)
        #expect(HealthDerivation.fullDiskAccessDenied(from: denied) == true)
    }

    @Test func disabledBackgroundAgentIsAWarning() {
        #expect(HealthDerivation.appHealth(
            setHealths: [health()],
            anyRunInFlight: false,
            fullDiskAccessDenied: false,
            backgroundAgentEnabled: false
        ) == .warning)
    }
}

// MARK: - setHealths(config:)

@Suite struct SetHealthsForConfigTests {
    @Test func oneHealthPerSetInConfigOrder() {
        let calendar = utcCalendar()
        let now = date(calendar, 2026, 7, 26, 12, 0)
        let second = BackupSet(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "Photos",
            sources: ["/Users/someone/Photos"],
            schedule: .hourly(minute: 15),
            destinations: [
                Destination(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    label: "Cloud",
                    repoURL: "s3:https://example.com/bucket",
                    isPrimary: true
                )
            ]
        )
        let config = AppConfig(sets: [makeSet(), second])
        let healths = HealthDerivation.setHealths(
            config: config,
            recentRuns: [],
            currentRuns: [setId: currentRun(percentDone: 0.1)],
            repoStatuses: [:],
            scheduleState: ScheduleState(sets: [setId: SetScheduleState(lastBackupStart: date(calendar, 2026, 7, 26, 2, 30))]),
            now: now,
            calendar: calendar
        )
        #expect(healths.map(\.name) == ["Projects", "Photos"])
        #expect(healths[0].isRunning)
        #expect(healths[0].nextDue == date(calendar, 2026, 7, 27, 2, 30))
        #expect(!healths[1].isRunning)
        #expect(healths[1].nextDue == .distantPast)
    }
}
