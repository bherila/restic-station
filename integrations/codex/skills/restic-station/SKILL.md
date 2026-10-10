---
name: restic-station
description: Operate Restic Station backups safely from the shell — check health, preview a backup, list snapshots, preview retention, restore — through the restic-station CLI and never through raw restic. Use when the user asks about their Restic Station backups, repositories, snapshots, retention or restores.
---

# Restic Station

Drive Restic Station through its own CLI. The full policy, with the reasoning,
is the agent guide: `docs/agent-operations.md` in the Restic Station
repository (https://github.com/bherila/restic-station/blob/main/docs/agent-operations.md).
This skill is the sequence; the guide wins on any disagreement.

Call `restic-station` (or `restic-station-helper` where the link is not
installed). If `capabilities` is an unknown command, the helper is too old for
this skill: use only `status --json` and `config validate --json`. Add `--json` wherever it is offered, and branch on `ok`,
`error.code` and `error.retryable`, never on message text.

## Always

- Start with `restic-station capabilities --json`, then
  `restic-station config validate --json`, then `restic-station status --json`.
- Every command except `version` and `capabilities` loads `config.json`, and
  loading an older schema migrates the file in place. If the config is shared
  with other machines, they then need an upgraded helper or they stop backing
  up. Straight after a helper upgrade on such a host, ask before the first
  config-loading command, even `config validate`.
- Use only the set and destination UUIDs these return.
- Pick the lowest safety class that answers the question. `capabilities`
  lists each command's class. Get the user's explicit go-ahead before anything
  at `configurationWrite`, `repositoryWrite` or `destructive`.
- Read `capabilities.features` before relying on a feature. If it says
  `available: false`, tell the user its `reason` and stop. The one exception
  is restic itself: `capabilities` never reads configuration, so it searches
  only the standard locations and `PATH` and cannot see a `resticPath`
  configured on this host. When it reports restic (or `backupDryRun`,
  `excludeCloudFiles`) unavailable, let the real command decide. Report a
  `restic_not_found` or `restic_unsupported` error if one comes back.

## Never

- Never run restic yourself against a Restic Station repository: no
  reconstructed `restic backup`, `forget`, `prune`, `rewrite` or `unlock`, and
  no `RESTIC_PASSWORD` or `RESTIC_REPOSITORY` of your own. Refuse and explain
  that it would bypass Restic Station's exclusions, locks and safety checks.
- Never print, ask for, or read a password or secret environment value. Report
  presence with `restic-station secret list --json`. Never call `print-password`.
- Never invent a flag, or call a command `capabilities` marks unavailable.
- Never force past a refusal: an expired or mismatched preview, a contained
  command, a cloud repository that is not downloaded.

## Sequences

**Is it healthy? What runs tonight?** The three bootstrap commands, and
nothing else. No backup.

**Back up.** `restic-station backup dry-run --set <uuid> --json`, then
summarize the figures and warnings and ask. Only then
`restic-station run-set --set <uuid> --kind backup`. Say beforehand that it
also copies to mirrors and applies retention. The dry run does not bind
`run-set`: if the configuration may have changed since, dry-run and ask again.

**Clean up old backups.** `restic-station retention preview --set <uuid> --json`
for each destination. Summarize keep and remove counts. For a mirror, include
the "not evidence it is safe to prune" warning. Manual retention apply is
unavailable (`capabilities.features.manualRetentionApply`): scheduled backups
apply the policy. Do not prune by any other route.

**Remove files from old snapshots.** Purge applies only the set's configured
`purgeExcludes`. Check them with `restic-station config show --json`. If the
requested pattern is missing, say that adding it is a configuration change
needing its own authorization, and show every configured pattern the purge
would apply. Then `restic-station purge preview --set <uuid> --json`,
show the plan, get explicit authorization, then pipe that exact `previewToken`
to `restic-station purge apply --set <uuid> --preview-token-stdin --json`.
Never put the token in argv. On `preview_expired` or `operation_not_allowed`,
preview again, show the new plan, and ask again before applying it.

**Restore.** `restic-station snapshots list --set <uuid> --json` to find the
snapshot, confirm what to restore, then restore into a new, empty directory
with `--overwrite never` unless the user explicitly asks to overwrite.
Report a partial restore separately from a complete one.

**Online-only files.** If files are missing from a snapshot of an iCloud or
File Provider folder, one *possible* reason is that they were online-only and
were deliberately not downloaded (macOS, `features.excludeCloudFiles`).
Present it as a possibility, alongside the others: the set's exclusions, the
global exclusion list, a `CACHEDIR.TAG`, an unreadable-file warning, or a
change since that snapshot. The dry run reports totals, not which file
matched what. `cloud_repository_not_hydrated` means the
repository folder itself must be made available offline in the cloud
provider; the user does that, not you.

**Offline destination.** `repository_offline` (exit 3) is a drive that is
unplugged or a NAS that is asleep. Report it, and do not retry in a loop.
