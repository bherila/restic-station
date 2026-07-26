# Scheduling

## Model: launchd tick + anacron-style due computation

One **static** LaunchAgent, registered by the app via `SMAppService.agent(plistName:)`, plist embedded in the bundle at `Contents/Library/LaunchAgents/net.herila.ResticStation.helper.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>net.herila.ResticStation.helper</string>
    <key>BundleProgram</key><string>Contents/MacOS/restic-station-helper</string>
    <key>ProgramArguments</key>
    <array><string>restic-station-helper</string><string>tick</string></array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>120</integer>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
```

Notes: `Label` MUST equal the plist filename minus `.plist`. `BundleProgram` (bundle-relative path) — not `Program` — is what gives the helper the app's identity for Login Items display and TCC attribution. When both `BundleProgram` and `ProgramArguments` are present, `ProgramArguments[0]` is conventional argv0 and the remaining entries are the arguments.

launchd behavior we rely on (no code needed): `StartInterval` fires are **skipped during sleep and coalesced into a single fire on wake** — combined with due-computation below this yields anacron semantics. `RunAtLoad` gives a tick at login/registration.

## Tick algorithm (`restic-station-helper tick`)

```
1. acquire locks/tick.lock (flock LOCK_EX|LOCK_NB); busy → exit 0 silently (previous tick still evaluating/running)
2. load config; if no config or no sets → exit 0
3. recover: for any runs/<id>/metadata.json with status "running" whose pid is dead → rewrite as "failed" (message "interrupted")
4. now = Date()
5. for each set (sequentially, config order):
     if isDue(schedule, lastBackupStart, now) → BackupEngine.runSet(set, trigger: .scheduled)
     if checkPolicy.enabled && checkIsDue(lastCheckStart, now) → BackupEngine.runCheck(set)
6. for each destination of each set: if last probe older than 30 min → Reachability.probe → write repo-status state
7. release tick.lock; exit 0
```

Sets run **sequentially** within a tick (restic saturates I/O; parallel sets thrash). The tick holds `tick.lock` for the whole duration including long backups; that is intentional — the per-set lock (below) exists so `Back Up Now` from the app still works for *other* sets while a scheduled run is in flight.

## Due computation (`ScheduleMath` — pure functions, fully unit-tested)

```swift
public enum ScheduleMath {
    /// The first instant strictly after `lastRunStart` at which `schedule` fires.
    /// lastRunStart == nil → .distantPast semantics (immediately due).
    public static func nextDue(after lastRunStart: Date?, schedule: Schedule,
                               calendar: Calendar) -> Date

    public static func isDue(schedule: Schedule, lastRunStart: Date?,
                             now: Date, calendar: Calendar) -> Bool
    // isDue ⟺ nextDue(after: lastRunStart) <= now
}
```

Rules (anacron semantics):

1. **Never-run set is immediately due** (`lastRunStart == nil` → due at first tick).
2. **At most one catch-up run.** Missing N slots (Mac asleep for a week with hourly schedule) produces ONE run when next awake, not N. This falls out naturally: after the catch-up run, `lastRunStart` = now, and `nextDue` is computed from the *schedule grid*, not from `lastRunStart + interval` — except `everyMinutes`, which is interval-from-last-start by definition.
3. **Grid definitions:**
   - `everyMinutes(m)`: due when `now ≥ lastRunStart + m minutes`.
   - `hourly(minute)`: fires at `minute` past each hour. Due when the most recent grid point ≤ now is > lastRunStart.
   - `daily(hour, minute)`: grid point once per day at hour:minute (in the user's current calendar/timezone).
   - `weekly(weekday, hour, minute)`: once per week; weekday 1 = Sunday … 7 = Saturday (Calendar convention).
4. **DST:** compute grid points with `Calendar.nextDate(after:matching:matchingPolicy:.nextTime)`. A nonexistent 02:30 on spring-forward day resolves to the next valid time; an ambiguous fall-back time fires once. Tests must cover both (fixed `TimeZone(identifier: "America/New_York")`, injected calendar).
5. **Clock skew:** if `lastRunStart > now` (clock moved backwards), treat as due at the next grid point after `now` (i.e. clamp lastRunStart to now); never go into a fire-loop.

`lastBackupStart` records **attempt** starts (success or failure) — a failing backup retries at the next grid slot, not every 2 minutes. Manual runs also set it.

**Check scheduling:** fixed weekly cadence. `checkIsDue` = `lastCheckStart == nil || now − lastCheckStart ≥ 7 days`, evaluated only when no backup for the same set is due in the same tick (backup wins; check runs on a later tick). Each scheduled check uses `--read-data-subset=<cursor+1 mod t>/<t>` against the **primary**, advancing `checkSliceCursor` on success only. Secondaries are checked structure-only (no `--read-data-subset`) every 4th check *if reachable*.

## Locking

Two levels, both `flock(2)` `LOCK_EX | LOCK_NB` on files under `locks/` (advisory; auto-released by the kernel on process death — no stale-lock cleanup needed; the files themselves persist, their existence means nothing):

| Lock | Held by | Purpose |
|---|---|---|
| `tick.lock` | the whole tick | prevent overlapping scheduled evaluations when a backup outlives StartInterval |
| `set-<setId>.lock` | any run touching that set (scheduled or manual, incl. restore & prune) | one operation per set at a time |

`FileLock` API: `init(path:)`, `tryAcquire() -> Bool`, `release()`, RAII deinit-release. A manual `run-set` finding the set lock busy exits code 2 and writes a `.skipped` index record; the app surfaces "already running".

restic's own repo lock is the last line of defense (exit 11 → auto-`unlock` of stale locks + one retry, see restic-cli.md); ours prevent the normal cases.

## Staleness

For every destination: `stale ⟺ now − lastSyncedAt > stalenessWarningDays` (per-set setting, default 14). Offline secondaries are *expected* to go stale — that is exactly what the warning is for ("your external drive hasn't been plugged in for N days"). Staleness drives: yellow badge in destination lists, menubar warning state, and (T18+) an optional user notification. A destination with no successful sync ever counts as stale once its set has ≥ 1 successful backup.

## What the app does (and doesn't)

The app never computes schedules. It renders `schedule-state.json` + `repo-status-*.json` + `nextDue()` (calling ScheduleMath for display only), registers/unregisters the LaunchAgent, and invokes the helper for manual actions:
- `Back Up Now` → `restic-station-helper run-set --set <uuid>`
- kick a tick early (after config edits) → `launchctl kickstart gui/<uid>/net.herila.ResticStation.helper`
