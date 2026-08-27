# restic CLI contract

Everything in this document was **verified against restic 0.18.1 on macOS (arm64)** — argv, exit codes, and every JSON sample below are captured real output (lightly sanitized paths/hostnames), stored verbatim in [`docs/fixtures/`](fixtures/). The rewrite transcripts were additionally captured against restic 0.19.1 because that command has no JSON mode. Parser implementations MUST be written against these fixtures (copied into `Core/Tests/ResticStationCoreTests/Fixtures/`) and MUST tolerate unknown extra fields (`init(from:)` via keyed containers or plain `Decodable` structs — never `assert` on shape).

## General invocation rules

- The restic binary path is resolved once, at load: `machine.json`'s `resticPath` → the deprecated `AppConfig.resticPath` → discovery (`data-model.md` §machine.json). Always absolute. Never rely on `PATH` — GUI/launchd processes get `/usr/bin:/bin:/usr/sbin:/sbin`.
- Repository selection: always explicit `-r <repoURL>` (equivalently `RESTIC_REPOSITORY`; we use `-r` so argv is self-describing in logs).
- Environment assembled per destination, replacing the inherited env with a minimal one:
  - `HOME`, `USER`, `TMPDIR` passed through (restic/keychain need them)
  - `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — fixed, not inherited; restic's `sftp:` backend locates `ssh` via PATH. Overridable per destination via `nonSecretEnv` (e.g. prepend `/opt/homebrew/bin` for an `rclone:` backend)
  - `RESTIC_PASSWORD_COMMAND` — produced by the active `SecretStore` (T23), **not** hard-coded:
    - keychain backend (macOS default): `/usr/bin/security find-generic-password -s restic-station -a <dest-uuid-lowercase> -w`
    - file backend (Linux default; opt-in on macOS via `RESTIC_STATION_SECRET_BACKEND=file`): `<absolute-helper-path> print-password --dest <dest-uuid-lowercase>`
  - the active `SecretStore`'s `passwordCommandEnvironment` — empty for the keychain backend, and `RESTIC_STATION_DATA_DIR` + `RESTIC_STATION_SECRET_BACKEND=file` for the file backend. **This is load-bearing:** we replace restic's environment, restic's password-command child inherits the replaced environment, and that child is another copy of our own helper which resolves its store from its own environment. Without these two variables it would read the *default* data directory with the *platform-default* backend and fail to find a password this process just read successfully.
  - `RESTIC_CACHE_DIR=~/Library/Caches/net.herila.ResticStation/restic` (expanded)
  - `Destination.nonSecretEnv` entries
  - secret env from the store's `<uuid>-env` item (a JSON dict, fetched by our code and injected as real env vars — restic's password-command mechanism only covers the repo password, not e.g. `AWS_SECRET_ACCESS_KEY`)
- `RESTIC_PASSWORD_COMMAND` is word-split by restic itself (not `sh -c`). Never build it from user input.

  **Splitting rules, verified empirically against restic 0.18.1 (T23)** — restic uses its own shell-like splitter, so the exact capabilities matter once a path can contain a space:

  | Form | Result |
  |---|---|
  | `/usr/bin/security find-generic-password …` (no metacharacters) | works — this is the keychain backend's fixed form |
  | `"/path/with spaces/helper" print-password --dest <uuid>` | **works**; a double-quoted argument may contain spaces, single quotes, `$` and `\` literally, and unquoted arguments may follow it |
  | `'/path/with spaces/helper'` | works — single quotes behave the same |
  | `/path/with spaces/helper` (unquoted) | fails: `fork/exec /path/with: no such file or directory` |
  | `'/path/it'\''s/helper'` (POSIX escape) | **fails** — restic's splitter has no backslash escape |
  | `"/path/with a \" quote/helper"` | fails: `double-quoted string not terminated` — a path containing `"` cannot be expressed at all |

  `FileSecretStore.quoteForRestic(_:)` therefore double-quotes the helper path only when it contains a character outside `[A-Za-z0-9/._+=:,@-]`, so the common case emits the same unquoted shape the keychain backend does. A helper path containing a literal `"` is unrepresentable and is documented as such rather than worked around.
- restic trims a trailing newline from the password command's output, but `print-password` deliberately emits none: a password that legitimately ends in a newline must round-trip through `secret set` → `print-password` unchanged.
- Add `--json` to every command that supports it. `check` and `unlock` have no JSON mode — capture text.
- Never pass `--no-lock`.

## Remote maintenance

For an `sftp:` destination whose `remoteMaintenance.enabled` is true,
standalone pack reclamation runs on the SSH host. The remote login shell
receives every operand single-quote escaped. The repository password is
written only to SSH stdin and remote restic reads it with `-p /dev/stdin`. If
SSH or remote restic is unavailable, prune fails; it never falls back to a
local network prune. Rewrite remains local.

SSH options, and why each is there:

| Option | Reason |
|---|---|
| `BatchMode=yes` | Never prompt. A scheduled helper has no one to answer. |
| `StrictHostKeyChecking=yes` | **Not `accept-new`.** This channel carries the repository password, so trust-on-first-use would hand it to whoever answers the first connection — and that MITM then satisfies the `restic version` preflight. The operator has already ssh'd to the host to configure the destination, so the key is normally pinned; when it is not, the preflight recognises the host-key failure and says to connect once with `ssh` to verify and record the key. |
| `ConnectTimeout=15` | Bounds the handshake. |
| `ServerAliveInterval=15`, `ServerAliveCountMax=3` | Bounds a session that is *established but dead*. `ConnectTimeout` does not cover this: a NAT or firewall dropping an idle flow mid-prune leaves ssh blocked forever, and the helper hangs **holding the set lock**, silently stopping every scheduled backup for that set. A wall-clock timeout is deliberately not used instead — a legitimate prune runs for hours, and only a keepalive distinguishes slow from gone. |

## Exit codes (verified)

| Code | Meaning | Category (see architecture.md) |
|---|---|---|
| 0 | success | success |
| 1 | fatal error (backup: no snapshot created) | terminal |
| 2 | Go runtime error | terminal |
| 3 | backup completed but some source files could not be read — snapshot WAS created | warning |
| 10 | repository does not exist | terminal (distinct message: suggest checking path / init) |
| 11 | repository already locked | retryable once via `unlock` (stale-lock removal), then terminal |
| 12 | wrong password | terminal (distinct message: "check the stored password") |

Verified samples: `exit-codes.txt`, `err-norepo.txt` (`Fatal: repository does not exist: …`), `err-wrongpw.txt` (`Fatal: wrong password or no key found`).

**JSON-mode errors:** with `--json`, fatal errors arrive as an NDJSON line on **stdout**:
```json
{"message_type":"exit_error","code":11,"message":"unable to create lock in backend: repository is already locked by PID 97063 on example-mac.local by user (UID 501, GID 20)\n…the `unlock` command can be used to remove stale locks"}
```
(fixture `locked-error.json` — captured live when a concurrent copy held the lock). Parsers must accept `exit_error` on any streamed command and surface `message`.

**Stale locks:** `restic unlock` (fixture `unlock.txt`: `successfully removed 1 locks`) removes only locks belonging to dead processes — safe to run automatically. On exit 11 during a scheduled operation: run `unlock`, retry once, then fail terminal.

## Commands

### init (primary)
```
restic -r <repo> init --json
```
Output (`init.json`): `{"message_type":"initialized","id":"4c743a24…","repository":"primary"}`. Repo-exists error → exit 1 with message containing `config file already exists`.

### init (secondary, shared chunker — REQUIRED for mirrors)
```
restic -r <secondaryRepo> init --json --from-repo <primaryRepo> --copy-chunker-params
```
plus env: destination's password/env as usual, **and** `RESTIC_FROM_PASSWORD_COMMAND=/usr/bin/security find-generic-password -s restic-station -a <primary-uuid> -w` (and primary's secret env merged in — note: if primary and secondary both need conflicting env like two different `AWS_SECRET_ACCESS_KEY`s, use `--from-password-command` CLI flag for the password; conflicting *other* secret env across two S3 accounts is a known v1 limitation — document in UI as "two S3 destinations in one set must use the same credentials" and revisit post-v1).
Output (`init-secondary.json`): same `initialized` message. Without `--copy-chunker-params` deduplication between primary and mirror is destroyed — the flag is non-negotiable.

### backup
```
restic -r <primaryRepo> backup --json [--exclude <pat>]... <source>...
```
Sources passed as **absolute paths**. NDJSON stream on stdout (`backup.ndjson`, `backup2.ndjson`):
```json
{"message_type":"status","percent_done":1,"total_files":3,"files_done":3,"total_bytes":65571,"bytes_done":65571}
{"message_type":"summary","files_new":3,"files_changed":0,"files_unmodified":0,"dirs_new":2,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":3,"tree_blobs":3,"data_added":67860,"data_added_packed":67085,"total_files_processed":3,"total_bytes_processed":65571,"total_duration":0.751785042,"backup_start":"2026-07-26T16:57:04.634751-04:00","backup_end":"2026-07-26T16:57:05.386964-04:00","snapshot_id":"e9ffc5cb64395ad443fd14f432751a9823181224978d6b25bf2af1a99ad367fd"}
```
`status` also optionally carries `seconds_remaining`, `current_files: [String]`, `error_count` (not in the small fixture; treat all fields except `message_type` as optional). Other message types that may appear: `error` (`{"message_type":"error","error":{…},"during":"…","item":"…"}`) and `verbose_status` — ignore unknown types gracefully. `percent_done` is 0…1.

Each backup passes `BackupSet.effectiveBackupExcludes`: `excludes` followed by `purgeExcludes`, deduplicated while preserving first-occurrence order. Both lists become individual `--exclude` arguments. `purgeExcludes` is the separate history-affecting list: it excludes matching files from new snapshots and is reserved for the workflow that removes matching paths from existing snapshots; removing repository space still requires a later `prune`.

### copy (mirror primary → secondary)
```
restic -r <secondaryRepo> copy --from-repo <primaryRepo> [<snapshotID>...]
```
Direction: **`-r` is the DESTINATION, `--from-repo` is the SOURCE.** Env: destination password via `RESTIC_PASSWORD_COMMAND`, source via `RESTIC_FROM_PASSWORD_COMMAND`. With active `purgeExcludes`, scheduled mirroring always supplies the exact resulting snapshot ids from the primary purge's complete launch-generation mapping. A snapshot created after that purge process starts is therefore not copied under stale purge authority. With no purge rules, no snapshot IDs means copy all snapshots not yet present (dedup via the `original` field restic stamps on copied snapshots). `copy` has **no `--json`** in 0.18 — output is human text (`copy.txt`):
```
snapshot e9ffc5cb of [/Users/user/example/src] at 2026-07-26 16:57:04…
  copy started, this may take a while...
[0:00] 100.00%  2 / 2 packs copied
snapshot a231ccb7 saved
```
A fully-caught-up copy prints nothing (`copy-noop.txt` is empty) and exits 0. Parse nothing — record the raw log; success = exit 0. Count copied snapshots by counting `snapshot .* saved` lines if wanted for stats.

Before a bounded copy, Restic Station pins one executable, resolves every
terminal purge-output prefix against `snapshots --json`, and supplies the
resulting full snapshot ids as operands. An absent or ambiguous resolution,
executable replacement, malformed reply, or failed query fails closed. Exit 0
then proves only that those exact operands arrived: another host can still add
a primary snapshot at any later instant, and the CLI exposes no transaction
that spans both repositories. A bounded copy therefore never advances the
mirror's `lastSyncedAt` and never runs mirror retention.

### snapshots
```
restic -r <repo> snapshots --json
```
Single JSON **array** (not NDJSON) — fixture `snapshots.json`. Key fields per element: `id`, `short_id`, `time`, `parent?`, `paths`, `hostname`, `username`, `program_version`, `summary{files_new,files_changed,data_added,total_bytes_processed,backup_start,backup_end,…}`. Copied snapshots additionally carry `original` (id in the source repo).

### rewrite
```
restic -r <repo> rewrite [--forget] [--dry-run] [--exclude <pat>]... <snapshotID>...
```
`rewrite` has no JSON mode. Snapshot ids are required and are passed explicitly;
omitting them rewrites every snapshot in the repository. `--exclude` may be
repeated. `--dry-run` reports the snapshots that would be replaced without
changing the repository (`rewrite-dry-run.txt`); `--forget` replaces the old
snapshots and forgets them (`rewrite-forget.txt`). `--forget` does not reclaim
pack space — only a later repository-wide `prune` does. Exit 0 means the
requested rewrite completed (including a no-op); nonzero is a restic failure.

### prune
```
restic -r <repo> prune [--dry-run]
```
Standalone repository-wide space reclamation. `--dry-run` reports the work
without changing the repository. Exit 0 means prune completed; nonzero is a
restic failure. Purge previews and purge applies never add `prune` implicitly.
Restic Station exposes it as `maintenance prune --set <uuid> [--dest <uuid>]
[--expected-destination-stdin] [--dry-run] [--json]`; omitting `--dest`
selects the primary. A confirmed app invocation writes its helper-issued
binding to stdin and passes only `--expected-destination-stdin`, so the
capability never appears in argv. The helper refuses a configuration or
stored-secret environment change that would redirect the destructive command.
`--dry-run` issues a new binding and cannot be combined with the selector.
Omitting the selector on a real prune remains the documented unbound
direct-operator path. The retired value-bearing selector is rejected with
exit 64; see `cli-json.md` §Confirmation capabilities for the bounded
43-character input and terminal flow.
It may run with
no retention policy, but refuses a mirror that is behind the primary.

### ls (lazy directory browsing)
```
restic -r <repo> ls --json <snapshotID> <dir>
```
NDJSON (`ls-src.ndjson`): first line `"message_type":"snapshot"` (full snapshot struct + `struct_type":"snapshot"`), then one `"message_type":"node"` line per entry:
```json
{"name":"binary.dat","type":"file","path":"/src/binary.dat","uid":501,"gid":0,"size":65536,"mode":420,"permissions":"-rw-r--r--","mtime":"2026-07-26T16:57:01.494355014-04:00","…":"…","message_type":"node","struct_type":"node"}
```
`type` is `"file"` | `"dir"` (symlinks: `"symlink"`). `size` absent for dirs. **Critical path semantics (verified):**
- The `<dir>` argument is an **in-snapshot path** — the paths restic prints (e.g. `/src/subdir`), NOT the original filesystem path. When a backup is invoked with absolute source paths (our case), in-snapshot paths mirror the absolute filesystem paths, but code must always navigate using `path` values returned by `ls`, never reconstruct them.
- Without `--recursive`, listing `<dir>` returns the dir's node itself plus its immediate children — exactly right for expand-on-click tree browsing. Start at `/`.
- Omitting `<dir>` entirely lists the whole snapshot **recursively** — never do this on big snapshots.
- A `<dir>` that matches nothing returns only the snapshot header line (`ls-subdir.ndjson` variant) — treat as empty, not error.

### find
```
restic -r <repo> find --json <pattern>
```
Single JSON array, one element **per snapshot with hits** (`find.json`): `{"matches":[{ "path":"/src/subdir/file2.txt","type":"file","size":23,"mtime":"…",…}],"hits":1,"snapshot":"<full id>"}`. Pattern is a shell glob matched against path components (`file2*` matches). Add `--snapshot <id>` to restrict; default searches all snapshots — UI should default to latest snapshot to keep it fast, with "search all snapshots" as an option.

### stats
```
restic -r <repo> stats --json --mode raw-data     # actual repo disk usage
restic -r <repo> stats --json                     # default mode: restore-size
```
Fixtures `stats-raw.json`: `{"total_size":67719,"total_uncompressed_size":69990,"compression_ratio":1.03…,"total_blob_count":9,"snapshots_count":2}`; `stats-restore.json`: `{"total_size":131147,"total_file_count":10,"snapshots_count":2}`. Show raw-data as "repository size on disk", restore-size as "logical data protected".

### forget / prune (DANGER: the only destructive command)
```
restic -r <repo> forget --json [--keep-last N] [--keep-hourly N] [--keep-daily N] [--keep-weekly N] [--keep-monthly N] [--keep-yearly N] [--prune] [--dry-run]
```
JSON output (`forget.json`, captured with `--dry-run`): array of group objects `{"tags":…,"host":…,"paths":…,"keep":[snapshot…],"remove":[snapshot…]|null,"reasons":[…]}`. With `--prune`, prune progress follows as **text** after the JSON — read the first line as JSON, treat the rest as log. Engine rules:
- Refuse to run with an empty policy (no --keep flags would delete NOTHING in restic ≥0.17 by default, but guard anyway).
- Always run with the exact per-set `RetentionPolicy`, mapped flag-per-field, skipping nil fields.
- Apply the same policy to secondaries after a successful copy (copy never propagates deletions; without this, mirrors grow forever).
- UI "preview" uses `--dry-run` and renders keep/remove lists.

### check (integrity)
```
restic -r <repo> check                              # structure + metadata
restic -r <repo> check --read-data-subset=<n>/<t>   # + read & verify slice n of t data packs
```
No JSON. Success: exit 0, output ends `no errors were found` (`check.txt`, `check-subset.txt`). Failure: nonzero exit; record full output. Slice rotation: persist cursor `n` per set (`schedule-state.json`), increment modulo `t` each scheduled check → deterministic full-data coverage every `t` checks. Note `check` takes an **exclusive** repo lock — never schedule concurrently with backup (per-set lock covers this).

### restore
```
restic -r <repo> restore --json "<snapshotID>:<in-snapshot-subpath>" --target <dir> [--include <pat>]... [--overwrite always|if-changed|if-newer|never] [--dry-run]
```
The `:<subpath>` is optional (whole snapshot) and is an **in-snapshot path** (same rule as `ls` — verified: using the filesystem path fails with `path <x>: not found` unless they coincide). NDJSON: `status` lines then summary (`restore.ndjson`): `{"message_type":"summary","total_files":4,"files_restored":4,"total_bytes":65576,"bytes_restored":65576}`. May emit per-file `error` messages; collect them → `.warning` status. Default `--overwrite` is `always`.

### mount (optional feature)
```
restic -r <repo> mount <emptyDir>
```
Requires macFUSE (`/Library/Filesystems/macfuse.fs` exists). Blocks while mounted; run as a managed child process. Unmount: send SIGINT; if the process doesn't exit in 5 s, run `/usr/sbin/diskutil unmount force <dir>` then SIGKILL. Mountpoint: `~/Library/Application Support/ResticStation/mounts/<destId>/`.

### version / cat config (probes)
```
restic version --json          → {"message_type":"version","version":"0.18.1","go_version":"go1.25.1","go_os":"darwin","go_arch":"arm64"}
restic -r <repo> cat config    → {"version":2,"id":"4c743a24…","chunker_polynomial":"3ec7451ee4546b"}
```
`cat config` (fixture `cat-config.json`) is the cheap remote-reachability probe (10 s timeout). `version --json` (fixture `version.json`) validates a discovered binary; require ≥ 0.17 (first version with the current exit-code contract), warn if < 0.18.

## S3-compatible destinations (first-class)

Repo URL forms:
- AWS: `s3:s3.amazonaws.com/<bucket>[/<prefix>]` or `s3:https://s3.<region>.amazonaws.com/<bucket>/<prefix>`
- Any S3-compatible endpoint (Cloudflare R2, MinIO, Backblaze S3 API…): `s3:https://<endpoint-host>/<bucket>[/<prefix>]` — e.g. `s3:https://<accountid>.r2.cloudflarestorage.com/<bucket>/<prefix>`
- Required env: `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (secret → keychain env blob). Optional non-secret: `AWS_DEFAULT_REGION` (R2: `auto`).

Local-path destinations include external volumes (`/Volumes/...`) and cloud-sync-mounted folders (iCloud Drive under `~/Library/Mobile Documents/...`). **iCloud caveat (surface in UI):** "Optimize Mac Storage" may evict repo pack files to dataless placeholders; restic reads then force slow re-downloads or fail. The destination editor shows a warning when a repo path is under `Mobile Documents`.
