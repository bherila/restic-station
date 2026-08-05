# T19 — Integration test script (real restic, end to end)

**Size:** M · **Model:** Sonnet · **Depends on:** T10 (runs in parallel with M3 UI tasks) · **Milestone:** M4

## Goal
`scripts/integration-test.sh` implementing the contract in `docs/testing.md` §Layer 2 step by step, wired into the CI macOS job.

## Create
- `scripts/integration-test.sh` — `#!/usr/bin/env bash` plus `set -euo pipefail` on its own line.
  (This originally specified `#!/bin/bash -euo pipefail`, which works only because Darwin splits a
  shebang's argument string on whitespace. Linux passes the remainder as a *single* argument, so bash
  consumes the script path as `-o`'s option name and exits with "invalid option name" before running
  anything. T29 hit this the first time the script ran on Linux — do not reintroduce it.) Structure:
  - Preflight: restic on PATH (else skip with exit 0 + notice when `CI` unset; hard fail in CI), `jq` available (brew or bundled fallback via `python3 -c`).
  - Workspace: `mktemp -d`; `RESTIC_STATION_DATA_DIR` exported; `trap` cleans workspace AND keychain items AND kills stray helpers.
  - Keychain seeding: two fixed test UUIDs; `security add-generic-password -s restic-station -a <uuid> -w test-password -T /usr/bin/security` (delete-first for idempotency). On CI, create/unlock a temporary keychain if `security show-keychain-info` fails (document the runner behavior encountered).
  - Build: `xcodegen generate` (if project absent) + `xcodebuild -scheme "Restic Station" build CODE_SIGNING_ALLOWED=NO -derivedDataPath "$WORK/dd"`; helper path from the built bundle.
  - Config: heredoc `config.json` matching data-model.md exactly — one set, tmp source dir (a few files), local primary + local secondary (paths in workspace), `everyMinutes: 5`, retention keep-last 2, the two test UUIDs as destination ids.
  - Init: helper has no init-primary subcommand — use restic directly for the primary (`RESTIC_PASSWORD_COMMAND` form, proving the keychain path works), then `helper init-secondary`.
  - Assertions (each a function with a clear failure message), per testing.md: run 1 → 1/1 snapshots + index records (backup ✓ + copy ✓ sharing groupId, via jq over index.jsonl) + repo-status lastSyncedAt; run 2 after source mutation → 2/2; unplug (mv secondary) → run 3 → backup ✓, no copy record for it, `reachable:false`; replug → run 4 → secondary catches up to 4 snapshots; retention applies keep-last 2 → primary and secondary both ≤ 2 snapshots (prune records present); `helper tick` immediately after → no new backup records (not due); `helper run-set` while another `run-set` holds the set lock → exit 2 + skipped record.
- `.github/workflows/ci.yml` — add the script step to the macOS job (after build; `brew install restic jq`).

## Acceptance criteria
- [ ] Script passes locally (macOS, restic installed) and in CI.
- [ ] Every assertion failure prints WHICH step failed and dumps `index.jsonl` + relevant state files.
- [ ] Trap-cleanup verified: after a forced mid-script failure, no keychain items named `restic-station`/test-UUIDs remain and workspace is gone.
- [ ] Wall time < 5 minutes.
