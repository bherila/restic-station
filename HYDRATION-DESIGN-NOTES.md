# Pre-backup hydration — design notes

Scratch briefing so a fresh Claude session can resume this discussion with context.
Delete when the decision is made. Nothing here has been implemented.

## The question

Should restic-menubar's "backup sets" grow the ability to pull/sync remote state —
production MySQL, file-upload directories, R2/S3 buckets — so the various `~/proj`
roots are fully hydrated *before* a scheduled backup runs? An "rsync before backup"
option, or rclone.

## Recommendation

**Yes to hydration, no to a shell hook.** Give restic-station a typed, direction-locked
`hydrate` concept rather than a `preBackupCommand: String`.

```json
"hydrate": [
  { "kind": "rsyncPull", "host": "ssh-bwh-php",
    "remotePath": "bwh-php/storage/app/private",
    "localPath": "/Users/bwh/proj/x-data/bwh-php" },
  { "kind": "sshCommandToFile", "host": "ssh-bwh-php",
    "command": "db:export-sqlite" }
]
```

`rsyncPull` has no push variant. The engine builds argv the way `ResticCommand` already
does (`ResticCommand.swift:88`) — config supplies operands, never verbs or flags.

**Why this matters:** `~/proj/bwh/bwh-php/scripts/blobs.sh` is trustworthy precisely
because *direction is not expressible*. It's baked into the subcommand name; `--delete`
exists only under `pull`; `push --prune` requires an interactive typed confirmation plus
a non-empty-mirror guard (`blobs.sh:64`). A free-text command field edited through a UI
and run unattended under launchd throws that away, and the failure mode is the local
mirror overwriting production.

## Key design points

**Hydration failure → Warning, never Terminal.** If web1 is unreachable at 02:30, back up
anyway. `x-data` mirrors a host with its own hourly backups; the restic repo is the second
copy, and the rest of `~/proj` has nothing to do with web1 and still needs its snapshot.
Backups should have the fewest possible preconditions. Specifically **not** Retryable —
`BackupEngine.swift:144-150` returns `.retryable` and leaves no trace, which is right for a
locked keychain but would silently skip backups whenever the network hiccups.

**Record staleness inside the snapshot, not in a restic tag.** The hazard is a silently
stale hydration recorded as fresh. Have the hydrate step write `~/proj/x-data/.hydrated.json`
(`{host, startedAt, finishedAt, status, files, bytes}`) as its last act; the next backup
sweeps it up. Every snapshot then self-describes its mirror's freshness — restorable,
greppable, tool-independent, no schema change. (`ResticCommand.backup` has no `--tag`
support today, and `forget` policies are tag-aware, so tags would introduce retention
interactions you don't want.)

**Order: blobs first, then the DB.** A torn rsync is a non-issue — restic is content-addressed
and the next run captures complete state. The tear that matters is cross-artifact: a DB
snapshot referencing rows whose blobs arrive in the *next* sync. Dumping the DB last means
every row has its blob present.

**Store the DB dump uncompressed.** Restic 0.14+ compresses natively. A ~500 MB uncompressed
dump changing ~1%/day dedupes to nearly nothing; a 100 MB gzip changes entirely every day.
The iCloud repo is already ~49 GB. If gzip is unavoidable, use `--rsyncable`.

**Run the DB export on web1, don't mysqldump over the wire.** Use the existing
`db:export-sqlite` (`app/Console/Commands/Database/ExportSqliteSnapshot.php`) over SSH and
rsync the file back. The DB password already lives in web1's `.env`; the only local
credential is the SSH key, which is how `blobs.sh` already works. A local mysqldump
reintroduces exactly the "prod DB credentials in a laptop dotfile" problem that
bherila/2025-website#1906 Phase 1 exists to eliminate. If a true DR artifact is ever needed:
`mysqldump --single-transaction --quick --no-tablespaces` (`--no-tablespaces` because shared
cPanel accounts lack `PROCESS`). Be clear these are two different artifacts — the SQLite
snapshot is lossy (type coercion, no views/triggers/grants) and is not restore-to-production.

**rsync only; skip rclone.** Every real case is SSH-reachable. Per `~/proj/x-data/README.md`
the blobs *moved off* R2 onto web1 precisely because R2 had no point-in-time recovery — there
is no live bucket left to pull. (Unrelated: restic-station's *destination* model already
handles `s3:`/R2 as a mirror repo — that's restic writing, not rclone.)

**Overlap with #1906:** share the artifact, not the orchestration. `scripts/db-snapshot.sh`
(pull-only, direction baked in) is already that issue's Phase 1 deliverable; build it there
and have hydrate invoke it. Don't build a second DB-pull path inside a Swift app.

## Suggested sequencing

Practical state: restic-menubar isn't installed (no `~/Library/Application Support/ResticStation/`,
no launchd agent, nothing in `/Applications`), and `~/proj/backup.sh` isn't scheduled either —
it's run by hand. So the real question is "before I migrate `~/proj` onto my own app, should
the app grow this?"

- **Step 0 (~half a day, mostly reuse):** `scripts/db-snapshot.sh` in bwh-php (#1906 Phase 1,
  worth doing regardless) plus `~/proj/hydrate.sh` calling `blobs.sh pull --apply` for each
  project then the DB snapshot — blobs before DB — writing `.hydrated.json` at the end. Use
  `set -uo pipefail` but **not** `-e`: a failing step must still write the manifest recording
  its failure and must not block later steps. Schedule at 01:30, backup at 02:30.
- **Step 1 (~a day), only if it earns its place:** the typed `hydrate` array above — Models.swift
  field, a `validate()` rule, a `runSet` phase before step 4, tests, and the `data-model.md` /
  `ui-spec.md` updates CONTRIBUTING.md requires in the same PR.
- **Not worth building:** a general shell-hook subsystem. Week-plus and a permanent tax — env
  assembly (`ResticRunner.baseEnvironment()` deliberately doesn't inherit the environment and
  pins `PATH`), timeouts, secret injection — and it breaks the documented guarantee at
  `ResticRunner.swift:31` that run logs contain restic's own output only, never env values.

## One-sentence version

The ordering and the staleness-visibility are the valuable parts and cost almost nothing;
arbitrary command execution is the expensive part and buys nothing a launchd plist doesn't
already give you — so if hydration goes in the app at all, make it a typed pull that the
config cannot reverse.
