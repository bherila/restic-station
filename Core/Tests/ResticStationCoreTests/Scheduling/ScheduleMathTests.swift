import Foundation
import Testing
@testable import ResticStationCore

// Table-driven coverage of every rule in `docs/scheduling.md` §Due
// computation, per `docs/tasks/T06-schedule-math.md`.
//
// Every date is built from explicit `DateComponents` against an explicitly
// constructed `Calendar` (never `Calendar.current`, never a locale-dependent
// string parse), and every schedule is exercised against a fixed
// `TimeZone(identifier: "America/New_York")` so DST behavior is
// reproducible regardless of the host machine's local timezone.
//
// DST portability note: since Swift 5.9-ish toolchains (including the 6.1
// Linux CI container and the 6.3 toolchain used locally here), `Calendar`'s
// `nextDate(after:matching:matchingPolicy:)` is backed by the same
// cross-platform Swift Foundation implementation (ICU-backed on both
// Darwin and Linux) rather than divergent per-platform NSCalendar code, so
// the hardcoded DST expectations below (verified against the local macOS
// toolchain) are expected to hold on Linux CI too. If Linux CI ever
// disagrees, that's a real divergence worth pinning explicitly per-OS
// rather than silently working around.

private func nyCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(
    _ calendar: Calendar,
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int, _ minute: Int, _ second: Int = 0
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    return calendar.date(from: components)!
}

// MARK: - Rule 1: never-run is immediately due

@Suite struct ScheduleMathNeverRunTests {
    @Test(arguments: [
        Schedule.everyMinutes(30),
        Schedule.hourly(minute: 15),
        Schedule.daily(hour: 2, minute: 30),
        Schedule.weekly(weekday: 1, hour: 3, minute: 0)
    ])
    func neverRunIsImmediatelyDue(schedule: Schedule) {
        let calendar = nyCalendar()
        let now = date(calendar, 2026, 6, 15, 12, 0)
        #expect(ScheduleMath.nextDue(after: nil, schedule: schedule, calendar: calendar) == .distantPast)
        #expect(ScheduleMath.isDue(schedule: schedule, lastRunStart: nil, now: now, calendar: calendar))
    }
}

// MARK: - hourly(minute:)

@Suite struct ScheduleMathHourlyTests {
    // last 09:20 (grid point 10:15): now 10:10 → not due; now 10:16 → due.
    @Test(arguments: [
        (10, 10, false),
        (10, 16, true)
    ])
    func hourlyBoundary(nowHour: Int, nowMinute: Int, expectedDue: Bool) {
        let calendar = nyCalendar()
        let schedule = Schedule.hourly(minute: 15)
        let last = date(calendar, 2026, 6, 15, 9, 20)
        let now = date(calendar, 2026, 6, 15, nowHour, nowMinute)
        #expect(ScheduleMath.isDue(schedule: schedule, lastRunStart: last, now: now, calendar: calendar) == expectedDue)
    }

    @Test func nextDueIsTheGridPointStrictlyAfterLastRunStart() {
        let calendar = nyCalendar()
        let last = date(calendar, 2026, 6, 15, 9, 20)
        let expected = date(calendar, 2026, 6, 15, 10, 15)
        #expect(ScheduleMath.nextDue(after: last, schedule: .hourly(minute: 15), calendar: calendar) == expected)
    }

    // Asleep for a week: exactly ONE catch-up run, not 168 back-filled ones.
    @Test func weekAsleepProducesExactlyOneCatchUp() {
        let calendar = nyCalendar()
        let now = date(calendar, 2026, 6, 20, 10, 15)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        let schedule = Schedule.hourly(minute: 15)

        // A week's worth of missed hourly slots collapses to "due now".
        #expect(ScheduleMath.isDue(schedule: schedule, lastRunStart: weekAgo, now: now, calendar: calendar))

        // Simulate the single catch-up run recording lastRunStart = now.
        // The next due point is the *next* grid slot — one hour out, not
        // still working through the backlog.
        let followUpDue = ScheduleMath.nextDue(after: now, schedule: schedule, calendar: calendar)
        #expect(followUpDue == date(calendar, 2026, 6, 20, 11, 15))
        #expect(followUpDue.timeIntervalSince(now) <= 3600)
        #expect(!ScheduleMath.isDue(schedule: schedule, lastRunStart: now, now: now, calendar: calendar))
    }
}

// MARK: - daily(hour:minute:)

@Suite struct ScheduleMathDailyTests {
    @Test func normalDayNextDue() {
        let calendar = nyCalendar()
        let last = date(calendar, 2026, 6, 14, 2, 30)
        let expected = date(calendar, 2026, 6, 15, 2, 30)
        #expect(ScheduleMath.nextDue(after: last, schedule: .daily(hour: 2, minute: 30), calendar: calendar) == expected)
    }

    @Test(arguments: [
        (-1, false),
        (0, true)
    ])
    func normalDayIsDueBoundary(offsetSeconds: Int, expectedDue: Bool) {
        let calendar = nyCalendar()
        let last = date(calendar, 2026, 6, 14, 2, 30)
        let gridPoint = date(calendar, 2026, 6, 15, 2, 30)
        let now = gridPoint.addingTimeInterval(TimeInterval(offsetSeconds))
        #expect(ScheduleMath.isDue(schedule: .daily(hour: 2, minute: 30), lastRunStart: last, now: now, calendar: calendar) == expectedDue)
    }

    // DST spring-forward: 2026-03-08, America/New_York clocks jump
    // 02:00 -> 03:00, so local 02:30 does not exist that day.
    // `.nextTime` resolves the nonexistent match forward to 03:00:00 EDT.
    @Test func springForwardNonexistentTimeResolvesToNextValidInstant() {
        let calendar = nyCalendar()
        let last = date(calendar, 2026, 3, 7, 2, 30)
        let expected = date(calendar, 2026, 3, 8, 3, 0, 0)
        #expect(ScheduleMath.nextDue(after: last, schedule: .daily(hour: 2, minute: 30), calendar: calendar) == expected)
    }

    @Test func springForwardFiresExactlyOnce() {
        let calendar = nyCalendar()
        let last = date(calendar, 2026, 3, 7, 2, 30)
        let schedule = Schedule.daily(hour: 2, minute: 30)
        let firstDue = ScheduleMath.nextDue(after: last, schedule: schedule, calendar: calendar)
        // The day after the anomaly, the grid is back to normal 02:30 —
        // confirming the spring-forward gap produced exactly one due
        // instant rather than repeating.
        let secondDue = ScheduleMath.nextDue(after: firstDue, schedule: schedule, calendar: calendar)
        #expect(secondDue == date(calendar, 2026, 3, 9, 2, 30))
    }

    @Test(arguments: [
        (-1, false), // one second before the resolved grid point
        (0, true)
    ])
    func springForwardIsDueBoundary(offsetSeconds: Int, expectedDue: Bool) {
        let calendar = nyCalendar()
        let last = date(calendar, 2026, 3, 7, 2, 30)
        let gridPoint = date(calendar, 2026, 3, 8, 3, 0, 0)
        let now = gridPoint.addingTimeInterval(TimeInterval(offsetSeconds))
        #expect(ScheduleMath.isDue(schedule: .daily(hour: 2, minute: 30), lastRunStart: last, now: now, calendar: calendar) == expectedDue)
    }

    // DST fall-back: 2026-11-01, America/New_York clocks fall back
    // 02:00 -> 01:00, so local 01:xx occurs twice; 02:30 is unambiguous
    // but happens only once per the wall clock, and the grid must fire
    // exactly once for it (not twice for the doubled hour).
    @Test func fallBackFiresExactlyOnce() {
        let calendar = nyCalendar()
        let last = date(calendar, 2026, 10, 31, 2, 30)
        let schedule = Schedule.daily(hour: 2, minute: 30)
        let firstDue = ScheduleMath.nextDue(after: last, schedule: schedule, calendar: calendar)
        #expect(firstDue == date(calendar, 2026, 11, 1, 2, 30))

        let secondDue = ScheduleMath.nextDue(after: firstDue, schedule: schedule, calendar: calendar)
        #expect(secondDue == date(calendar, 2026, 11, 2, 2, 30))
    }
}

// MARK: - weekly(weekday:hour:minute:)

@Suite struct ScheduleMathWeeklyTests {
    @Test func acrossMonthBoundary() {
        let calendar = nyCalendar()
        // 2026-01-25 is a Sunday (weekday 1).
        let last = date(calendar, 2026, 1, 25, 3, 0)
        let expected = date(calendar, 2026, 2, 1, 3, 0)
        let schedule = Schedule.weekly(weekday: 1, hour: 3, minute: 0)
        #expect(ScheduleMath.nextDue(after: last, schedule: schedule, calendar: calendar) == expected)
    }
}

// MARK: - everyMinutes(_:)

@Suite struct ScheduleMathEveryMinutesTests {
    @Test(arguments: [
        (29, false),
        (30, true)
    ])
    func boundary(elapsedMinutes: Int, expectedDue: Bool) {
        let calendar = nyCalendar()
        let last = date(calendar, 2026, 6, 15, 9, 0)
        let now = last.addingTimeInterval(TimeInterval(elapsedMinutes) * 60)
        #expect(ScheduleMath.isDue(schedule: .everyMinutes(30), lastRunStart: last, now: now, calendar: calendar) == expectedDue)
    }

    // Catch-up after a 3-hour gap (e.g. asleep): exactly one run, then
    // resumes normal cadence from the run's own start time (interval
    // schedules are interval-from-last-start by definition, not a
    // wall-clock grid, so there's no "backlog" to speak of).
    @Test func catchUpAfterGapProducesOneRun() {
        let calendar = nyCalendar()
        let schedule = Schedule.everyMinutes(30)
        let last = date(calendar, 2026, 6, 15, 9, 0)
        let now = last.addingTimeInterval(3 * 3600)

        #expect(ScheduleMath.isDue(schedule: schedule, lastRunStart: last, now: now, calendar: calendar))

        let followUpDue = ScheduleMath.nextDue(after: now, schedule: schedule, calendar: calendar)
        #expect(followUpDue == now.addingTimeInterval(30 * 60))
        #expect(!ScheduleMath.isDue(schedule: schedule, lastRunStart: now, now: now, calendar: calendar))
    }
}

// MARK: - Rule 5: clock moved backwards

@Suite struct ScheduleMathClockSkewTests {
    @Test func movedBackwardsDoesNotFireLoop() {
        let calendar = nyCalendar()
        let schedule = Schedule.hourly(minute: 15)
        // The clock was moved backwards a day: the recorded lastRunStart
        // is (nonsensically) "in the future" relative to `now`.
        let lastRunStart = date(calendar, 2026, 6, 16, 10, 0)

        // While real `now` is still behind the stale `lastRunStart`, the
        // clamp (effectiveLastRunStart = now) makes `nextDue` land strictly
        // after `now` every single time — so it is never due, no matter
        // how close `now` gets. This is what rules out a fire-loop: a
        // naive "lastRunStart > now → always due" reading would fire on
        // every tick until the clock caught up.
        let now1 = date(calendar, 2026, 6, 15, 10, 0)
        #expect(!ScheduleMath.isDue(schedule: schedule, lastRunStart: lastRunStart, now: now1, calendar: calendar))

        let now2 = date(calendar, 2026, 6, 16, 9, 59)
        #expect(!ScheduleMath.isDue(schedule: schedule, lastRunStart: lastRunStart, now: now2, calendar: calendar))

        // Once real time reaches/passes the stale `lastRunStart`, the
        // clamp no longer applies and normal grid computation resumes:
        // due exactly at the schedule's own next grid point relative to
        // `lastRunStart` (2026-06-16 10:15) — not immediately at 10:00,
        // and not a backlog of fires for the skipped day.
        let now3 = date(calendar, 2026, 6, 16, 10, 10)
        #expect(!ScheduleMath.isDue(schedule: schedule, lastRunStart: lastRunStart, now: now3, calendar: calendar))

        let now4 = date(calendar, 2026, 6, 16, 10, 15)
        #expect(ScheduleMath.isDue(schedule: schedule, lastRunStart: lastRunStart, now: now4, calendar: calendar))
    }
}

// MARK: - checkIsDue

@Suite struct ScheduleMathCheckIsDueTests {
    @Test func neverCheckedIsImmediatelyDue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ScheduleMath.checkIsDue(lastCheckStart: nil, now: now))
    }

    @Test(arguments: [
        (6 * 24 + 23, false), // 6d23h
        (7 * 24 + 1, true)    // 7d1h
    ])
    func threshold(elapsedHours: Int, expectedDue: Bool) {
        let calendar = nyCalendar()
        let last = date(calendar, 2026, 6, 1, 3, 0)
        let now = last.addingTimeInterval(TimeInterval(elapsedHours) * 3600)
        #expect(ScheduleMath.checkIsDue(lastCheckStart: last, now: now) == expectedDue)
    }
}

// MARK: - nextCheckSlice

@Suite struct ScheduleMathNextCheckSliceTests {
    // `cursor` is the last-used `n` (1-based; 0 == never checked). The
    // next slice wraps `cursor` forward by one, back to 1 after
    // `totalSlices` — e.g. with t=20, cursor 19 (last used slice 19)
    // gives n=20; cursor 20 (last used the final slice) wraps to n=1.
    @Test(arguments: [
        (0, 20, 1, 1),
        (1, 20, 2, 2),
        (19, 20, 20, 20),
        (20, 20, 1, 1),
        (7, 4, 4, 4)
    ])
    func wrapsPastLastUsedN(cursor: Int, totalSlices: Int, expectedN: Int, expectedNewCursor: Int) {
        let result = ScheduleMath.nextCheckSlice(cursor: cursor, totalSlices: totalSlices)
        #expect(result.n == expectedN)
        #expect(result.newCursor == expectedNewCursor)
    }
}
