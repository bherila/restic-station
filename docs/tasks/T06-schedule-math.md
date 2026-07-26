# T06 — ScheduleMath

**Size:** M · **Model:** Sonnet · **Depends on:** T02 (Schedule type) · **Milestone:** M1

## Goal
Pure due-computation functions implementing `docs/scheduling.md` §Due computation exactly — signatures, anacron semantics, DST rules, clock-backwards clamp.

## Create
- `Core/Sources/ResticStationCore/Scheduling/ScheduleMath.swift` — `nextDue(after:schedule:calendar:)` and `isDue(schedule:lastRunStart:now:calendar:)` with the exact signatures in scheduling.md. Grid schedules (`hourly`/`daily`/`weekly`) computed with `Calendar.nextDate(after:matching:matchingPolicy:.nextTime)`; `everyMinutes` is `lastRunStart + interval`. `lastRunStart > now` → clamp to `now` before computing. Also `checkIsDue(lastCheckStart:now:) -> Bool` (≥ 7 days rule) and `nextCheckSlice(cursor:totalSlices:) -> (n: Int, newCursor: Int)` (1-based `n`, wraps).

## Tests (table-driven; fixed `TimeZone(identifier: "America/New_York")` injected via `Calendar`)
Every rule in scheduling.md gets rows, minimum:
- never-run → due now (all four kinds).
- hourly(minute: 15): last 09:20 now 10:10 → not due; now 10:16 → due.
- daily(2,30): normal day; **DST spring-forward 2026-03-08** (02:30 nonexistent → resolves to next valid instant, due fires once); fall-back 2026-11-01 (fires once, not twice).
- weekly(1, 3, 0) Sunday 3am across a month boundary.
- Asleep a week with hourly → exactly ONE catch-up (isDue true; after simulated run at wake, next due is next grid point, not 168 back-fills).
- everyMinutes(30): 29 min → false, 30 min → true; catch-up after 3 h gap → one run.
- clock moved backwards 1 day → no fire-loop (nextDue > now until next grid point).
- checkIsDue at 6d23h → false, 7d1h → true; slice cursor wraps t=20: cursor 19 → n=20, newCursor 0? No: define cursor as last-used `n` (1-based); cursor 20, t 20 → n=1. Match data-model.md's `checkSliceCursor` meaning ("the n most recently used") and document in code.

## Acceptance criteria
- [ ] `swift test` green (macOS + Linux container; Linux `Calendar` semantics match — if a DST case behaves differently on Linux ICU, pin with explicit assertions and note it).
- [ ] No `Date()` / `Calendar.current` inside the functions — everything injected.
