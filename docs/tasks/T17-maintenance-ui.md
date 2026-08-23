# T17 — Maintenance UI

**Size:** M · **Model:** Opus (layout latitude) · **Depends on:** T13, T10 · **Milestone:** M3

## Goal
The Maintenance screen per `docs/ui-spec.md` §Maintenance: sizes, retention preview/apply, integrity checks, staleness, unlock utility.

## Create (`App/Sources/Views/Maintenance/`)
- `MaintenanceView.swift` — set picker; per-destination size cards (app-direct read-only `stats --json --mode raw-data` + default mode, per architecture.md's read-only exception; session cache + Refresh; `ByteCountFormatter`).
- `RetentionSection.swift` — shows policy (link to set editor); **Preview cleanup**: app-direct `forget --dry-run --json` → keep/remove table (T05 `ForgetResult`); **Apply retention now**: **currently contained** — the control is disabled and the section states the posture (`ManualRetentionApplyAvailability`), because the helper refuses `run-set --kind prune` outright (#111/#82). Preview stays available; retention is applied by backup runs (scheduled ticks and Back Up Now alike — `runSet` applies it regardless of trigger). When re-enabled: confirmation quoting real dry-run counts per ui-spec copy ("This will permanently delete N snapshots from <dest>.") → `HelperInvoker.prune` → surfaces resulting run.
- `IntegritySection.swift` — last check per destination (from run history, kind == check), "verified slices n/t" from `checkSliceCursor`, **Check now** (structure-only vs with-data-slice toggle) → `HelperInvoker.check`.
- `StalenessSection.swift` — per-destination last-synced with stale highlighting per scheduling.md definition.
- Footer: "Repository reports locked? Remove stale locks" → helper unlock (add `unlock` plumbing: reuse `run-set --kind` — no; add a tiny helper subcommand `unlock --set --dest` in this task, mirroring T10 patterns, engine method `runUnlock` calling `.unlock` command with a run record kind reuse `prune`? No — use RunKind extension: record as kind `check` is wrong too. Simplest correct: no run record for unlock; direct ResticRunner call from helper, log to stdout only. Document this exception in the subcommand's abstract.)

## Acceptance criteria
- [ ] Against a fixture repo with 3 snapshots and keep-last 1: Preview shows 1 keep / 2 remove. **Apply is contained** — the control is disabled, the section states the posture, and the helper refuses; assert the refusal instead of a snapshot drop. Retention through a scheduled `tick` is asserted by `scripts/integration-test.sh` §retention.
- [ ] *Deferred until re-enablement (#111/#82):* Apply → snapshot count drops to 1 (verified via UI refresh AND `restic snapshots`); confirmation numbers always come from a fresh dry-run, never from the stale preview.
- [ ] Size cards distinguish "on disk" vs "protected data" with the ui-spec labels.
- [ ] Check now produces a check run record; slice indicator advances on scheduled-style slice checks.
- [ ] Stale destination (hand-edit repo-status lastSyncedAt back 30 days) highlights correctly.
