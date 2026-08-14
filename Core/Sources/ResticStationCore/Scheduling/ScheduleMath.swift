import Foundation

// MARK: - ScheduleMath

/// Pure, fully-injected due-computation for backup and check scheduling.
///
/// See `docs/scheduling.md` §Due computation for the anacron-style rules
/// this implements. Nothing here reads the wall clock or the system
/// calendar/timezone — every `Date` and `Calendar` is a parameter, which is
/// what makes these functions unit-testable (including DST edge cases) and
/// Linux-safe.
public enum ScheduleMath {

    /// Approximate elapsed period used only for the first-backup grace
    /// window. Wall-clock schedules still use `Calendar` for their actual
    /// due instants; here a stable duration is deliberately sufficient.
    public static func approximatePeriod(of schedule: Schedule) -> TimeInterval {
        switch schedule {
        case .everyMinutes(let minutes):
            return TimeInterval(minutes) * 60
        case .hourly:
            return 60 * 60
        case .daily:
            return 24 * 60 * 60
        case .weekly:
            return 7 * 24 * 60 * 60
        }
    }

    // MARK: nextDue

    /// The first instant strictly after `lastRunStart` at which `schedule`
    /// fires.
    ///
    /// `lastRunStart == nil` → `.distantPast` (rule 1: a never-run set is
    /// immediately due — any `now` is `>= .distantPast`).
    ///
    /// - `everyMinutes(m)`: interval-from-last-start by definition — the
    ///   grid point is exactly `lastRunStart + m minutes`, not a wall-clock
    ///   grid. This is the one case where anacron catch-up doesn't apply in
    ///   the usual sense; see the doc comment on `isDue`.
    /// - `hourly`/`daily`/`weekly`: wall-clock grid points computed with
    ///   `Calendar.nextDate(after:matching:matchingPolicy:.nextTime)`,
    ///   which is what gives us the documented DST behavior for free — a
    ///   nonexistent local time (spring-forward gap) resolves forward to
    ///   the next valid instant, and an ambiguous local time (fall-back)
    ///   is only matched once per call, so the grid fires once, not twice.
    public static func nextDue(after lastRunStart: Date?, schedule: Schedule, calendar: Calendar) -> Date {
        guard let lastRunStart else {
            return .distantPast
        }

        switch schedule {
        case .everyMinutes(let minutes):
            return lastRunStart.addingTimeInterval(TimeInterval(minutes) * 60)

        case .hourly(let minute):
            let components = DateComponents(minute: minute)
            return calendar.nextDate(after: lastRunStart, matching: components, matchingPolicy: .nextTime)
                // `nextDate` only returns nil for malformed components; minute
                // is validated to 0...59 by `AppConfig.validate()`. Fall back
                // to a plain hour-add so we never crash on a bad input.
                ?? lastRunStart.addingTimeInterval(3600)

        case .daily(let hour, let minute):
            let components = DateComponents(hour: hour, minute: minute)
            return calendar.nextDate(after: lastRunStart, matching: components, matchingPolicy: .nextTime)
                ?? lastRunStart.addingTimeInterval(24 * 3600)

        case .weekly(let weekday, let hour, let minute):
            let components = DateComponents(hour: hour, minute: minute, weekday: weekday)
            return calendar.nextDate(after: lastRunStart, matching: components, matchingPolicy: .nextTime)
                ?? lastRunStart.addingTimeInterval(7 * 24 * 3600)
        }
    }

    // MARK: isDue

    /// `isDue ⟺ nextDue(after: lastRunStart) <= now`, with one addition:
    /// rule 5 (clock skew) — if `lastRunStart > now` (the system clock was
    /// moved backwards), `lastRunStart` is clamped to `now` before computing
    /// `nextDue`, so the next fire is the next grid point after `now`
    /// rather than a stale point that could otherwise be perpetually in the
    /// "past" relative to a since-corrected clock. This is also what
    /// prevents a fire-loop: once clamped, `nextDue(after: now) > now`
    /// always (every grid rule advances strictly forward), so `isDue` is
    /// `false` immediately after the clamp and stays `false` until the next
    /// real grid point.
    ///
    /// Rule 2 (at most one catch-up run) isn't special-cased here — it
    /// falls out of how callers use this function: after a catch-up run,
    /// the caller records `lastRunStart = now`, so the *next* call computes
    /// `nextDue` from `now`, not from however many grid points were missed
    /// while asleep.
    public static func isDue(schedule: Schedule, lastRunStart: Date?, now: Date, calendar: Calendar) -> Bool {
        let effectiveLastRunStart: Date?
        if let lastRunStart, lastRunStart > now {
            effectiveLastRunStart = now
        } else {
            effectiveLastRunStart = lastRunStart
        }
        return nextDue(after: effectiveLastRunStart, schedule: schedule, calendar: calendar) <= now
    }

    // MARK: Check scheduling

    /// Fixed weekly check cadence: `lastCheckStart == nil` (never checked)
    /// or `now - lastCheckStart >= 7 days`.
    ///
    /// This is plain elapsed-time arithmetic, not a calendar grid — no
    /// `Calendar` is needed (or accepted) here.
    public static func checkIsDue(lastCheckStart: Date?, now: Date) -> Bool {
        guard let lastCheckStart else {
            return true
        }
        return now.timeIntervalSince(lastCheckStart) >= 7 * 24 * 60 * 60
    }

    /// The next `--read-data-subset=n/t` slice to check against the
    /// primary, and the `checkSliceCursor` value to persist if that check
    /// succeeds.
    ///
    /// Per `docs/data-model.md`, `checkSliceCursor` stores **the `n` most
    /// recently used** (1-based, `1...totalSlices`) — not a raw "next"
    /// pointer. `cursor == 0` means "never checked". `nextCheckSlice`
    /// computes the next slice by wrapping the *last-used* `n` forward by
    /// one, back to `1` after `totalSlices`:
    ///
    ///     nextCheckSlice(cursor: 0,  totalSlices: 20) == (n: 1,  newCursor: 1)
    ///     nextCheckSlice(cursor: 19, totalSlices: 20) == (n: 20, newCursor: 20)
    ///     nextCheckSlice(cursor: 20, totalSlices: 20) == (n: 1,  newCursor: 1)  // wraps
    ///
    /// `n` and `newCursor` are always equal — they're returned separately
    /// because they answer different questions for the caller: `n` is the
    /// slice to pass to restic for *this* check; `newCursor` is the value
    /// to write back to `checkSliceCursor`, and only on success (a failed
    /// check must retry the same slice next time, not advance past it).
    public static func nextCheckSlice(cursor: Int, totalSlices: Int) -> (n: Int, newCursor: Int) {
        precondition(totalSlices > 0, "totalSlices must be positive")
        let n = (cursor % totalSlices) + 1
        return (n: n, newCursor: n)
    }
}
