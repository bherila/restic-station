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
AccuracySec=1s
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
- **`AccuracySec=1s` keeps the two-minute contract honest.** systemd otherwise
  defaults to a one-minute coalescing window, so a nominal two-minute tick can
  arrive almost three minutes later. A one-second window retains light
  coalescing without adding a full minute to wake/catch-up latency.
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

An existing but unreadable or checksum-invalid `schedule-state.json` is never
reported as "never run". It is preserved, copied byte-for-byte to the
content-addressed recovery path named in the error when readable, and makes
`timer status`/`status --json` unhealthy until an operator replaces the
canonical file. This prevents lost purge watermarks from silently authorizing
a second rewrite.

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
| `scheduleStateUnreadable` | schedule/check/purge bookkeeping failed integrity or safe-file validation, so every tick exits 1 until explicit recovery |
| `dataDirectoryMismatch` | the unit pins a *different* data directory than this command reads — the timer is fine, and ticks somewhere else |
| `dataDirectoryUnpinned` | the unit pins none, so the tick re-derives it from the user manager's environment (a unit written before #48) |

One deliberate exception: a linger state of **`unknown`** — neither
`loginctl` nor `/var/lib/systemd/linger` could be consulted, as inside a
container with no logind — does **not** fail. Nothing logs out of such a
host, so failing would make this check permanently red with no reachable fix.
Only a confirmed `Linger=no` counts.

### `status` and the scheduler

`restic-station-helper status [--json]` reports the same verdict under a
`scheduler` key. Linux uses the same code path as `timer status`; macOS asks
launchd directly whether the SMAppService agent is loaded. A definite `false`
is a finding, while an unavailable probe remains unknown:

| `scheduler` | meaning |
|---|---|
| `{"kind": "unknown", "healthy": null, …}` | no systemd here; the documented fallback is a cron line, which nothing can inspect |
| `{"kind": "systemd-timer", "healthy": false, "problems": [...], …}` | a real finding — `status` exits 1 |
| `{"kind": "launchd-agent", "healthy": true, …}` | macOS launchd reports the SMAppService agent loaded |
| `{"kind": "launchd-agent", "healthy": false, "problems": ["agentNotLoaded"], …}` | macOS launchd cannot find the agent — `status` exits 1 |
| `{"kind": "launchd-agent", "healthy": null, "problems": ["launchctlProbeFailed"], …}` | the launchctl probe failed; state is unknown and does not fail status |

`status`'s **exit code is not `health == "warning"`.** `AppHealth` is a single
glyph for a menu bar, so `running` outranks `warning` there — correctly: while
restic is working, "working" is the more informative thing to show. An exit
code is not a glyph, and a three-hour backup must not be able to hide a
disabled timer from a monitoring script for three hours. `status` therefore
exits on `HealthDerivation.hasWarningConditions`, which is the same rules
without that precedence. Both read one shared predicate, so "what counts as a
problem" has exactly one definition.

An unresolved destructive audit failure is the exception: `critical`
outranks `running`, exits 1, and blocks further destructive launches until
the canonical run evidence is reconciled.

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
2. recover: for any runs/<id>/metadata.json with status "running" whose pid is dead → rewrite as "failed" (message "interrupted")
3. validate schedule-state.json; any unsafe or corrupt existing state → exit 1
4. load config; if no config or no sets → exit 0; if no usable restic → explain and exit 0
5. now = Date()
6. for each set (sequentially, config order):
     if isDue(schedule, lastBackupStart, now) → BackupEngine.runSet(set, trigger: .scheduled)
     if checkPolicy.enabled && checkIsDue(lastCheckStart, now) → BackupEngine.runCheck(set)
7. for each destination of each set: if last probe older than 30 min → Reachability.probe → write repo-status state
8. release tick.lock; exit 0
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

    /// Stable elapsed duration used by the first-backup health grace only.
    public static func approximatePeriod(of schedule: Schedule) -> TimeInterval
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

**A first backup cannot remain silently overdue forever.** A resolved set with no run history, no `lastBackupStart`, and no current run becomes a health warning after `max(approximatePeriod(schedule), 24 hours)`: 24 hours for every-minutes/hourly/daily schedules and seven days for weekly. The grace is measured from the later mtime of `config.json` and host-local `machine.json`, clamped to `now` for clock skew. If neither mtime can be read, the condition stays off rather than manufacturing a warning. Any attempted or in-flight run disables this first-run condition; ordinary run outcome and destination-staleness rules take over from there.

**Check scheduling:** fixed weekly cadence. `checkIsDue` = `lastCheckStart == nil || now − lastCheckStart ≥ 7 days`, evaluated only when no backup for the same set is due in the same tick (backup wins; check runs on a later tick). Each scheduled check uses `--read-data-subset=<cursor+1 mod t>/<t>` against the **primary**, advancing `checkSliceCursor` on success only. Secondaries are checked structure-only (no `--read-data-subset`) every 4th check *if reachable*.

## Purge-exclusion ordering

When a set has a `purgeExcludes` pattern absent from a destination's
`appliedPurgeExcludes` state, the next successful backup run adds a purge
phase. The fixed order is:

1. back up the primary with the effective forward excludes;
2. purge the primary with `rewrite --forget` over newly attributed snapshot
   ids;
3. for each reachable secondary, purge it first when stale, then copy from
   the primary;
4. run ordinary retention only where its existing freshness rules permit it.

**Attribution** decides which snapshots a purge is allowed to touch, and is
therefore normative. A repository-wide `snapshots --json` listing is filtered
in Swift; a snapshot is attributed to the set when **both** hold:

- every path in the snapshot is a member of the set's source union — the
  shared `sources` plus every machine override's `sources`, since an override
  replaces rather than merges; and
- the snapshot's hostname matches the local machine identity or one of the
  set's `machines` keys, compared after `MachineIdentity.slugify`.

Everything else is *unattributed* and is listed as such in the preview rather
than silently skipped. Two consequences are deliberate:

- The machine running the purge is **always** in the hostname set, whether or
  not the set has a `machines` entry for it (`HelperContext` inserts its own
  `machineId`). Its own snapshots are therefore attributable. What no
  `machines` entry protects is a snapshot written by some *other* host: that
  host's name is not in the set, so this machine never purges it.
  Under-purging is recoverable; over-purging is not.
- Membership is by subset, not equality, because a set's `sources` change over
  time and historical snapshots carry the older list. Where several sets share
  one `repoURL` on one machine, a snapshot of set A whose paths all fall inside
  set B's source union is attributable to **both**. The preview lists the exact
  snapshot ids and the confirmation token is bound to that list, so the
  operator sees them — but sets that share a repository should not overlap in
  sources if only one of them is meant to be purged.

The primary purge failure stops mirroring. A secondary purge failure skips
that secondary's copy but allows another mirror to proceed. Copying into an
unpurged secondary would leave its old snapshots alongside the primary's
rewritten replacements, so it is never allowed. The per-destination pattern
watermark advances only after that destination's purge child succeeds, or
when the plan matched nothing **and** nothing was declined — an empty
repository has nothing to rewrite. It deliberately does not advance when the
plan matched nothing while snapshots *were* declined: that combination is
evidence attribution is wrong, and recording the patterns as applied would
skip the rewrite permanently, silently, and with a success-shaped outcome.
The engine logs the decline instead. A removed pattern stays recorded and is
never used to trigger a rewrite.

The pending-pattern observation is revalidated after acquiring the shared
schedule-state lease. Each destination is narrowed to the preview patterns it
still needs: a primary and an offline mirror may legitimately have different
watermarks, while a destination/pattern pair applied by another helper during
the earlier planning window must not be rewritten. A token with no pending
pair is stale and is refused. Terminal successful purge metadata is durably
committed before the watermark. If the watermark's directory fsync then fails
and a crash loses its visible rename, the next apply holds both the
destructive-audit gate and the schedule-state lease, revalidates the token's
snapshot attribution, reads the live restic repository config id, verifies the
complete run history, and restores only the exact `purgePatterns` whose
launch-bound `purgeRepositoryId` matches that live repository **and** whose
recorded old-to-new snapshot mapping matches the live post-rewrite generation
(every old id absent, every new id present exactly once). The repository id is
queried again inside the runner immediately before the synchronous
executable/token/audit/spawn boundary, and the complete repository snapshot-id
set is re-listed there and compared with the generation observed during token
revalidation. A replacement or stale-host backup in the earlier planning
window refuses launch and restores a first-child token. Watermark recovery
likewise rechecks that canonical purge metadata still reproduces the exact
verified index projection, including its purge-evidence digest, at the point
that evidence is consumed. The full snapshot ids selected for every destination
must also have unique eight-character prefixes,
because those prefixes are the only old-id keys in restic's rewrite transcript;
ambiguity refuses before token consumption or destructive launch. Recovery
consumes the stale token and does not rewrite the repository again. Evidence
from a replaced repository or a same-id repository restored to a pre-purge
generation is ignored so the live history receives its own rewrite; malformed,
incomplete, identity-less legacy, or only partially matching history cannot
authorize the recovery shortcut.

## Locking

The operation-exclusion locks use `flock(2)` `LOCK_EX | LOCK_NB` on files under `locks/` (advisory; auto-released by the kernel on process death — no stale-lock cleanup needed; the files themselves persist, their existence means nothing). `AppPaths` creates every fresh internal lock-owning directory (`locks/`, `state/`, and `runs/`) through verified descriptors and pins it to `0700` after umask, so setup cannot create a tree the lock verifier then refuses. Each created or opened lock inode is likewise descriptor-pinned and verified at exact `0600`, including when a restrictive umask stripped owner bits at creation. Existing unsafe `locks/` or `runs/` directory modes are not silently repaired: live health still reports them; `state/` retains its stricter capability-store re-tightening rule. Companion locks use the same primitive to serialize shared local files:

| Lock | Held by | Purpose |
|---|---|---|
| `config.lock` | a `config.json` write | serialize Restic Station writers; app saves additionally compare the edit-start fingerprint immediately before atomic replacement |
| `tick.lock` | the whole tick | prevent overlapping scheduled evaluations when a backup outlives StartInterval |
| `destructive-audit.lock` | destructive audit verification through terminal commit | serialize the fail-closed audit gate across every set; kernel release distinguishes a live helper from a recycled PID |
| `run-publication.lock` | run-directory publication and destructive-audit verification | prevent a verifier from observing a run directory before its initial metadata; separately serialize verifiers so their contention is never mistaken for a live destructive operation |
| `set-<setId>.lock` | any run touching that set (scheduled or manual, incl. restore & prune) | one operation per set at a time |
| `health.lock` | a live health probe | exercise the backing filesystem's actual `flock(2)` support without contending with production work |
| `state/health.lock`, `runs/health.lock` | a live health probe | exercise `flock(2)` on state/run filesystems when they are separate mounts |
| `secrets.lock` | any secret-store mutation | serialize file-backend read-modify-write and keychain capture/update/conditional rollback across app and helper CLI |
| `state/schedule-state.lock` | a schedule-state mutation; for purge, the trusted read through rewrite completion and watermark commit | serialize schedule timestamps, check cursors, and purge watermarks across sets; bind destructive state evidence through use |
| `state/preview-tokens.lock` | a preview-token mutation | preserve single-use destructive capabilities across sets |
| `runs/index.jsonl.lock` | a run-index append | keep append ordering and records intact across sets |

`FileLock` API: `init(path:trustedRoot:)`, `acquire() -> LockAcquireResult`, `probe() -> LockFailure?`, `release()`, RAII deinit-release. Production callers supply the data root as an owner-controlled boundary. Setup first rejects an immediate root parent that gives another uid unprotected write-and-search replacement access. The root is then resolved with `openat(2)` through that verified parent descriptor; the root and the lock's direct parent are opened without following symlinks and verified as directories owned by the effective uid. The direct lock parent must not be group/world-writable, while the root and its parent may use normal sticky-directory protection. This immediate-parent boundary deliberately does not claim to audit every ancestor or filesystem ACL. The lock filename is finally resolved with `openat(2)`. Together these checks prevent another local user from renaming the data root, or unlinking a flocked inode within it, and making another helper acquire a distinct lock tree at the same pathname. Lock files are opened `O_NOFOLLOW | O_CLOEXEC` at `0600`, and an `fstat` on the descriptor requires a regular file owned by the effective uid. A pre-existing broader mode is tightened through the open descriptor; failure to tighten or verify the resulting owner-only mode is a lock failure. `O_CLOEXEC` is descriptor hygiene, not orphan-process supervision: `Foundation.Process` closes unknown descriptors independently, so lock continuity must not depend on accidental inheritance.

**`busy` and `failed` are different answers, and callers must treat them differently** (#110). `acquire()` returns `busy` only for `EWOULDBLOCK`/`EAGAIN` — a peer genuinely holding the lock. Everything else — an uncreatable `locks/`, `EACCES`, a symlink at the path, a lock file belonging to another user — is `failed`, and:

- `tick` exits **non-zero** rather than returning quietly, so launchd/systemd sees a failing unit instead of a clean pass;
- `BackupEngine` records a **`.failed`** index entry, not the benign `.skipped` one, so `HealthDerivation` counts it and the menu bar and `status` both show a warning;
- the polling lock users (`schedule-state`, `runs/index.jsonl`, the secret store) throw **immediately** instead of spending their whole timeout and then blaming contention;
- `status --json` and the app probe independently and live (`LockingHealth`), because the fault usually prevents writing the very record that would report it. The probe takes `flock(2)` on dedicated stable health inodes in `locks/`, `state/`, and `runs/` (contention there also proves locking works), probes every known companion lock without creating it, refuses dangling and live symlinks through descriptor-relative `openat(..., O_NOFOLLOW)`, reports inability to enumerate `locks/`, and uses both a non-mutating `faccessat(..., AT_EACCESS)` check and an actual create/remove on each lock-owning filesystem. Each actual allocation happens inside an owner-only nested `.health/` directory, so it catches full-filesystem and quota failures without triggering the app's parent directory watchers. Health creates and validates those scratch directories; normal operation setup never depends on them. Intrinsic damage confined to a health-only inode or scratch path therefore makes the probe inconclusive (`usable: null`, scope `diagnostic`) without claiming backup, check, restore, or maintenance locks are unusable. A failed `flock(2)` capability check or inability to allocate the fresh scratch inode remains a machine-wide production outage even when the failure is reported at a health-only path, because production lock acquisition needs that same capability. Diagnostic failures still warn and exit non-zero so monitoring never turns falsely green. Only configured set ids are probed; persistent orphaned or malformed set-lock names cannot block work and are ignored. The app keeps direct vnode watches on every existing lock inspected by health because child metadata changes do not reliably surface as parent-directory `.attrib` events; parent watches on `locks/`, `state/`, and `runs/` discover creation and replacement and recover after delete/rename/recreate. A damaged configured `set-<setId>.lock` is scoped to that set; damage confined to mutation-only `secrets.lock` is scoped `administrative`; shared operation-lock and directory failures are probed first and remain machine-wide so a simultaneous broader outage cannot be understated.

Schedule state and run history are part of operation correctness, not logging hygiene. A backup or check does not launch restic unless its attempt timestamp and initial running record can be stored; every later copy, check, retention, purge, restore, and initialization likewise fails as infrastructure if its own initial record cannot be created. A successful purge does not report success unless its watermark can be stored, and a terminal child that cannot be appended to the run index propagates a typed infrastructure failure so `tick` exits non-zero. A manual purge distinguishes failures known to precede the first rewrite from failures after destructive work may have run; the latter require repository inspection rather than encouraging a blind retry. Independent later mirrors and primary retention still run after a secondary-only infrastructure failure, but the aggregate tick remains failed. Otherwise a broken local store could suppress work or repeat backups, checks, or destructive rewrites while both the command and health record looked successful.

These were one `false` until #110, which is how an unusable data directory became a silent, permanent, exit-0 stoppage of every scheduled backup.

A contended `tick.lock` is **not** a failure and still exits 0: `tick` holds it for the whole of any backup it starts, so on a host with a backup longer than `StartInterval` every intervening tick finds it busy. A manual `run-set` finding the set lock busy exits code 2 and writes a `.skipped` index record; the app surfaces "already running".

restic's own repo lock is the last line of defense (exit 11 → auto-`unlock` of stale locks + one retry, see restic-cli.md); ours prevent the normal cases.

## Staleness

For every destination: `stale ⟺ now − lastSyncedAt > stalenessWarningDays` (per-set setting, default 14). Offline secondaries are *expected* to go stale — that is exactly what the warning is for ("your external drive hasn't been plugged in for N days"). Staleness drives: yellow badge in destination lists, menubar warning state, and (T18+) an optional user notification. A destination with no successful sync ever counts as stale once its set has ≥ 1 successful backup.

## What the app does (and doesn't)

The app is macOS-only; on Linux the helper is the whole product.

The app never computes schedules. It renders `schedule-state.json` + `repo-status-*.json` + `nextDue()` (calling ScheduleMath for display only), registers/unregisters the LaunchAgent, and invokes the helper for manual actions. A schedule-state integrity failure makes the menu-bar glyph critical, names the recovery requirement in both menu and window, and disables **every** Back Up Now entry point until the canonical file is explicitly repaired. `AppModel.backUpNow` repeats that guard so a missed or future view cannot spawn the helper:
- `Back Up Now` → `restic-station-helper run-set --set <uuid>`
- kick a tick early (after config edits) → `launchctl kickstart gui/<uid>/net.herila.ResticStation.helper`

The Linux equivalent of that last line is `systemctl --user start
restic-station.service`, but nothing in the project runs it: there is no UI to
edit config from, so there is no moment at which a tick needs forcing.
