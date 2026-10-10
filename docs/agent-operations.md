# Operating Restic Station from an agent

How a shell-capable agent — Codex, Claude Code, a script, or a person —
should drive Restic Station: what to call, in what order, and what never to
do. It applies to any agent. The Codex skill in
[`integrations/codex/`](../integrations/codex/README.md) sequences these same
steps; the rules live here so they do not drift.

The contracts this relies on are normative elsewhere and win on any
disagreement: [`cli-json.md`](cli-json.md) (the `--json` envelope, error
codes, `capabilities`), [`restic-cli.md`](restic-cli.md) (what each command
runs), and [`data-model.md`](data-model.md) (configuration and per-machine
scoping).

## Which binary, which version

Call `restic-station`, the link that `restic-station-helper cli install` puts
on `PATH`. On a host without the link, call `restic-station-helper` by its
installed path; the two are the same program.

These commands need a helper newer than v0.1.3: `capabilities`,
`backup dry-run`, `snapshots list`, `retention preview`. If `capabilities`
is an unknown command, the helper is older: use `status --json` and
`config validate --json`, and do not try the newer commands.

## Rules that always apply

- **Use Restic Station, not restic.** Never reconstruct a restic command line
  for a repository Restic Station manages, never set `RESTIC_PASSWORD` or
  `RESTIC_REPOSITORY` yourself, and never run `restic forget`, `prune`,
  `rewrite` or `unlock` directly. The helper applies machine overrides,
  exclusions, online-only-file protection, locks and secret handling that a
  reconstructed command would miss.
- **Never print or ask for a secret.** Report whether one is stored with
  `secret list --json` (presence only). Do not read the keychain or
  `secrets.json` yourself, and do not call the hidden `print-password`.
- **Prefer `--json`**, and branch on `ok`, `error.code` and `error.retryable`,
  never on `message` text. A nonzero exit is not always a failure:
  `status --json` exits 1 for a warning and still returns its report.
- **Use the UUIDs the CLI returns.** Set and destination names can change and
  repeat; every command takes `--set <uuid>` and `--dest <uuid>`.
- **Choose the lowest safety class that answers the question**
  (`capabilities --json` lists each command's class). Anything at
  `configurationWrite` or above needs the user's explicit go-ahead first.
- **Keep paths out unless they are needed.** `snapshots list` and
  `retention preview` leave source paths out by default; pass
  `--include-paths` only when the user asked about specific files.

## Bootstrap and inspect

1. `restic-station capabilities --json`: platform, restic, features, and every
   command with its safety class. Nothing else is read or written.
2. `restic-station config validate --json`: whether the configuration loads,
   its errors and warnings, and which sets run on this machine.
3. `restic-station status --json`: health, last runs, destinations, scheduler.

Before any write, resolve what these report: configuration errors, a missing
or unusable secret (`secret_not_configured`, `secret_store_unusable`), Full
Disk Access on macOS (`fda-check --json`), an unhealthy scheduler, an offline
destination (`repository_offline`, exit 3, which is expected for an
unplugged drive), or a cloud repository that is not downloaded
(`cloud_repository_not_hydrated`).

"What would run tonight?" is answered by `config validate --json` (what runs
on this machine) and `status --json` (when each set is next due), never by
running a backup.

## Back up

1. `restic-station backup dry-run --set <uuid> --json` before a first real
   backup and after any change to sources, exclusions or destinations. It
   saves no snapshot and writes no run history, and reports what restic
   would add.
2. Summarize the figures and any `warnings`, and get the user's go-ahead.
3. `restic-station run-set --set <uuid> --kind backup`. This is a real
   backup **and** the set's scheduled pipeline: it copies to mirrors and
   applies the retention policy, which can remove old snapshots. Say so
   before running it.

Backups, copies, restores, `init-secondary` and `unlock` are different
actions; authorize each one on its own.

## Online-only (cloud) files

On macOS, sources under iCloud Drive or a File Provider folder can hold
online-only files. Unless a set's `onlineOnlyFiles` is `"download"`, those
files are skipped with `--exclude-cloud-files` (restic 0.19+), or reported as
unreadable on an older restic. Either way they are **not** in the snapshot.
That is deliberate: reading them would download them. Explain this when a
user asks why such files are missing. Check
`capabilities.features.excludeCloudFiles` for this host; Linux has no
online-only files and never uses the flag.

A repository *inside* a cloud-synced folder is different. If any of its
files is online-only, every command refuses with
`cloud_repository_not_hydrated`. The fix is the user's: make the repository
folder available offline in the cloud provider. Never work around it by
reading the files yourself.

## Retention

1. `restic-station retention preview --set <uuid> [--dest <uuid>] --json`:
   what the configured policy would keep and remove, from
   `forget --dry-run`. Nothing is removed. Its `fingerprint` identifies the
   plan for comparison; it is not an authorization.
2. Summarize keep and remove counts per destination. For a mirror, report
   `mirror.behindPrimary` and the warning: a preview is not evidence that a
   mirror is safe to prune.
3. Check `capabilities.features.manualRetentionApply`. It is unavailable in
   current releases (`run-set --kind prune` always refuses). Tell the user
   the policy is applied by scheduled backups, which prune a mirror only
   after that run's copy to it succeeded. Do not try another route: no raw
   `restic forget`, no `--force`, no scripting around the refusal.

## Purge (removing files from existing snapshots)

`purge preview --set <uuid> --json` lists what a purge would rewrite and
returns a short-lived, single-use `previewToken`. Applying it is
destructive: show the user the plan, get explicit authorization, then pass
**that** token on standard input to
`purge apply --set <uuid> --preview-token-stdin --json`. Never put the token
in argv. Stop on `preview_expired`, or on `operation_not_allowed` (the plan
changed), and preview again rather than retrying.

## Restore

1. Find the snapshot: `restic-station snapshots list --set <uuid> [--dest <uuid>] --json`.
2. Confirm the set, destination, snapshot id, and which paths (`--sub`,
   `--include`) the user wants.
3. Restore into a **new, empty** directory with `--overwrite never`, unless
   the user explicitly asks to overwrite:

   ```console
   $ restic-station restore --set 00000000-0000-4000-8000-000000000001 \
       --dest 00000000-0000-4000-8000-000000000002 --snapshot 1a2b3c4d \
       --target /Users/example/Restored --overwrite never
   ```

   Without `--overwrite`, restic's own default (`always`) applies.
4. Report a partial restore (some files could not be restored; the exit is
   still 0 and the run record is a warning) separately from a full one.

## When something is unsupported

Read `capabilities --json` instead of guessing. A feature that is
`available: false` has a `reason`; tell the user and stop. Never invent a
flag, call a command the document lists as unavailable on this platform
(`timer …` on macOS), or fall back to raw restic.
