# T10 — Helper CLI subcommands

**Size:** M · **Model:** Sonnet · **Depends on:** T09 · **Milestone:** M2

## Goal
`restic-station-helper` wires Core into the subcommands per `docs/architecture.md` and the tick algorithm in `docs/scheduling.md` §Tick — the single code path for launchd AND the app.

## Create (`Helper/Sources/Commands/`, ArgumentParser subcommands of the T01 root)
- `Tick.swift` — implements the 7-step tick algorithm from scheduling.md verbatim (tick.lock; config load; `runStore.recoverInterrupted()`; sequential due sets → `engine.runSet(trigger: .scheduled)`; due checks (backup-wins rule); 30-min reprobe of all destinations; exit 0 always except config-load hard errors → exit 1 with message on stderr).
- `RunSet.swift` — `run-set --set <uuid> [--kind backup|check|prune]` (default backup): loads config, finds set (unknown uuid → exit 1), calls the matching engine method with `.manual`. Set-lock busy → exit **2** (the app treats 2 as "already running").
- `InitSecondary.swift` — `init-secondary --set <uuid> --dest <uuid>`.
- `Restore.swift` — `restore --set <uuid> --dest <uuid> --snapshot <id> --target <path> [--sub <in-snapshot-path>] [--include <pat>]… [--overwrite always|if-changed|if-newer|never]` → engine `runRestore`.
- `ProbeRepo.swift` — `probe-repo --set <uuid> --dest <uuid>`: probe + print human result + write repo-status state; exit 0 reachable / 3 offline / 1 error.
- `FdaCheck.swift` — per `docs/keychain-and-fda.md` §2: probe `~/Library/Safari` (fallback `~/Library/Mail`), write `state/fda-check.json` with `context` = value of `--context` flag (default "launchd"), print result, exit 0 either way.
- `Version.swift` (exists from T01; keep).
Shared bootstrapping in `HelperContext.swift`: build AppPaths (env override respected), ConfigStore, KeychainClient, ResticRunner (resticPath from config; missing → exit 1 "restic not configured — open Restic Station"), engine. Human-readable stdout, one-line-per-event; details stay in run logs.

## Tests / verification
Core logic is already tested; helper tests are thin: an `#if os(macOS)` XCTest-free smoke via `swift build` isn't available for the app targets, so verification is command-level (document commands in PR):
- `RESTIC_STATION_DATA_DIR=$(mktemp -d) …/restic-station-helper tick` with no config → exit 0, prints "no backup sets".
- `helper run-set --set <unknown>` → exit 1.
- `helper fda-check --context manual` writes valid `state/fda-check.json` (validate against data-model.md schema with `plutil`/`jq`).
- Full end-to-end lives in T19.

## Acceptance criteria
- [ ] `xcodebuild` builds; all subcommands present in `helper --help`.
- [ ] Exit-code contract: 0 ok, 1 error, 2 busy, 3 offline (probe) — documented in `--help` abstracts.
- [ ] Tick never leaves `tick.lock` held on any exit path (RAII verified by re-running immediately).
