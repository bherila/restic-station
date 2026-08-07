# Scheduling

## Model: a host-scheduled tick + anacron-style due computation

Restic Station schedules nothing itself. The host's own scheduler fires
`restic-station-helper tick` every 2 minutes, and **the tick is the entire
scheduling contract** — due-ness, catch-up after downtime, and "backup wins
over check" are all decided inside it from `state/schedule-state.json`, never
from the scheduler's own notion of time. The scheduler only has to fire often
enough.

That is what makes the two supported platforms behaviourally equivalent
despite using completely different mechanisms:

| platform | scheduler | registered by | see |
|---|---|---|---|
| macOS | launchd LaunchAgent, `StartInterval` 120 | the app, via `SMAppService` | §launchd below |
| Linux | systemd `--user` timer | the helper, via `timer install` | §Linux below |

The pure vocabulary of both — argv and unit text — lives in
`Core/Sources/ResticStationCore/Support/SchedulerCommand.swift`, conditionally
compiled per platform.

## launchd (macOS)

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

## Linux: systemd user timer

There is no app on Linux, so scheduling is installed from the helper itself:

```
restic-station-helper timer install [--interval <minutes>]   # default 2
restic-station-helper timer uninstall
restic-station-helper timer status
```

`timer` is compiled `#if os(Linux)` and does not appear in `--help` on macOS.
Both subcommands are idempotent: `install` overwrites the units in place (so
re-running with a different `--interval` just changes the interval), and
`uninstall` exits 0 with nothing installed.

### The two units

Shipped as templates in `packaging/linux/systemd/` for hand-installation and
distro packaging; `timer install` renders exactly the same text with
`<HELPER_PATH>` replaced. A unit test asserts the two cannot drift apart.

```ini
# restic-station.service
[Service]
Type=oneshot
ExecStart=<HELPER_PATH> tick
```

```ini
# restic-station.timer
[Timer]
Unit=restic-station.service
OnBootSec=2min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
```

- **`Type=oneshot`, no `Restart=`.** The tick is a batch job that exits, not a
  daemon. A `Restart=` on a timer-driven oneshot would retry a failing backup
  in a tight loop; a genuinely failing set is retried at its next scheduled
  slot instead (§Due computation).
- **No `[Install]` on the service.** It is activated by the timer. Enabling it
  directly would tick once per boot and never again.
- **`OnBootSec=` + `OnUnitActiveSec=` are what give Linux macOS's catch-up.**
  A machine that was off for a week ticks 2 minutes after it comes back, and
  that tick finds every set overdue from `schedule-state.json` — the same
  single catch-up run macOS gets from launchd coalescing missed
  `StartInterval` fires on wake.
- **`Persistent=true` is kept deliberately, and is not what does that.**
  `systemd.timer(5)` scopes `Persistent=` to `OnCalendar=` timers, so with the
  monotonic pair above it has no effect of its own. It stays because it states
  the intent (*missed runs are caught up, never skipped*) and is the switch
  that carries that intent unchanged the moment the interval is expressed as a
  calendar expression. **Do not delete it as dead configuration** — deleting
  it would silently change behaviour for anyone who does make that switch.

### User units, never system units

Units go in `~/.config/systemd/user/` (or `$XDG_CONFIG_HOME/systemd/user/`).
The helper's state is `$HOME`-scoped — `AppPaths.default()` resolves under
`$XDG_STATE_HOME` — and its secrets are `0600` and owned by one user. A
root-run system unit would resolve a *different* data directory and then be
unable to read the secrets it found. Nothing the tick does needs privilege.

**No secrets in a unit or an `EnvironmentFile`.** Unit files are
world-readable; restic credentials come from the secret store at run time. The
only environment variable a unit ever carries is `RESTIC_STATION_DATA_DIR`,
and only when the user had it set in the shell they ran `timer install` from.

### Lingering — the failure mode that generates the bug reports

Without `loginctl enable-linger <user>`, systemd stops a user's units when
that user logs out. On a headless box everything reports healthy right up
until the ssh session ends, and then backups silently stop. `timer install`
checks `loginctl show-user <user> --property=Linger` (falling back to reading
`/var/lib/systemd/linger/<user>`, since `show-user` fails for a user with no
session) and prints a prominent warning with the exact fix:

```
sudo loginctl enable-linger <user>
```

It is **never run automatically**: it needs root, and a backup tool that
escalates privilege behind the user's back is a worse bug than the warning.

### No systemd: the cron fallback

`timer install` detects the absence of systemd — no `systemctl` binary, or
`/run/systemd/system` missing, i.e. `sd_booted(3)`'s own test, because a
container image can ship `systemctl` while PID 1 is something else — and fails
with the fallback rather than a confusing `systemctl: command not found`.
Nothing is written on such a host. The fallback is one crontab line and no
tooling:

```cron
*/2 * * * * /path/to/restic-station-helper tick
```

The one behavioural difference: cron has no equivalent of `OnBootSec=`, so a
tick missed while the machine was off is not replayed at boot — the next
scheduled tick picks it up instead. That delays catch-up by up to one interval
and **loses nothing**, because due-ness comes from `schedule-state.json`, not
from cron slots.

### `timer status`

The headless equivalent of glancing at the menu bar icon: whether both units
exist, whether the timer is enabled and active, the interval actually
installed (read back from the unit, not assumed), the linger state, the next
firing from `systemctl --user list-timers`, and what the tick has been doing
from `state/schedule-state.json` and `runs/index.jsonl`. Exits 0 when
scheduled backups really will happen and 1 otherwise, so it works as a health
check.

The last thing it prints is the verdict it exits on, so the exit code never
has to be inferred from the evidence above it:

```
  VERDICT     scheduled backups will NOT happen on this host (exit 1)
                - lingering is disabled — the timer stops at logout (`sudo loginctl enable-linger <user>`)
```

Every one of these is exit 1 — the question is "will this host keep backing
up", not "does a unit file exist":

| reason | why it stops backups |
|---|---|
| `systemdUnavailable` | nothing is scheduling the tick at all |
| `unitsMissing` | never installed, or `timer uninstall`ed and not reinstalled |
| `unitsIncomplete` | one unit deleted by hand; systemd refuses to start the timer |
| `notEnabled` | will not come back after a reboot |
| `notActive` | not firing now |
| `lingerDisabled` | systemd kills this user's units at logout — the single most common silent stop on a headless box |
| `configUnreadable` | `config.json` will not parse, so every tick exits 1 |
| `dataDirectoryMismatch` | the unit pins a *different* data directory than this command reads — the timer is fine, and ticks somewhere else |
| `dataDirectoryUnpinned` | the unit pins none, so the tick re-derives it from the user manager's environment (a unit written before #48) |

One deliberate exception: a linger state of **`unknown`** — neither
`loginctl` nor `/var/lib/systemd/linger` could be consulted, as inside a
container with no logind — does **not** fail. Nothing logs out of such a
host, so failing would make this check permanently red with no reachable fix.
Only a confirmed `Linger=no` counts.

### `status` and the scheduler

`restic-station-helper status [--json]` reports the same verdict under a
`scheduler` key, from the same code path, so the two commands cannot
disagree. Three distinct answers, and only one of them is a finding:

| `scheduler` | meaning |
|---|---|
| `null` | this platform has no CLI-readable scheduler (macOS: `SMAppService` state is app-only) |
| `{"kind": "unknown", "healthy": null, …}` | no systemd here; the documented fallback is a cron line, which nothing can inspect |
| `{"kind": "systemd-timer", "healthy": false, "problems": [...], …}` | a real finding — `status` exits 1 |

`status`'s **exit code is not `health == "warning"`.** `AppHealth` is a single
glyph for a menu bar, so `running` outranks `warning` there — correctly: while
restic is working, "working" is the more informative thing to show. An exit
code is not a glyph, and a three-hour backup must not be able to hide a
disabled timer from a monitoring script for three hours. `status` therefore
exits on `HealthDerivation.hasWarningConditions`, which is the same rules
without that precedence. Both read one shared predicate, so "what counts as a
problem" has exactly one definition.

The `null`/`unknown` cases contribute nothing to health, exactly as an absent
`fda-check.json` does. `status` used to assert `backgroundAgentEnabled: true`
on every platform, which read as "the scheduler is fine" and meant a Linux
host whose timer had been uninstalled went on reporting healthy for as long
as its last run stayed inside the staleness window.

## Tick algorithm (`restic-station-helper tick`)

Identical on every platform — this is the code path launchd's `StartInterval`
and systemd's `restic-station.timer` both invoke, and neither passes it any
scheduling information.

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

The app is macOS-only; on Linux the helper is the whole product.

The app never computes schedules. It renders `schedule-state.json` + `repo-status-*.json` + `nextDue()` (calling ScheduleMath for display only), registers/unregisters the LaunchAgent, and invokes the helper for manual actions:
- `Back Up Now` → `restic-station-helper run-set --set <uuid>`
- kick a tick early (after config edits) → `launchctl kickstart gui/<uid>/net.herila.ResticStation.helper`

The Linux equivalent of that last line is `systemctl --user start
restic-station.service`, but nothing in the project runs it: there is no UI to
edit config from, so there is no moment at which a tick needs forcing.
