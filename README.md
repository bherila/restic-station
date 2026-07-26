# Restic Station

A native macOS menu bar app for scheduling and managing [restic](https://restic.net) backups.

**Status: specification phase.** The design and task breakdown are complete (see [`docs/`](docs/)); implementation is tracked in [GitHub issues](../../issues).

## What it does

- **Backup Sets** — a named set of local source directories backed up to one **primary** restic repository, mirrored to any number of **secondary** repositories via `restic copy` (content-verified, add-only: a prune, deletion, or corruption of the primary is never propagated to a mirror). Secondaries may be offline (e.g. an unplugged external drive) — they are skipped gracefully, tracked for staleness, and caught up in full the next time they appear.
- **Schedules** — hourly / daily / weekly / every-N-minutes per set, executed by a headless helper under `launchd`. Backups run even when the app is closed, and runs missed while the Mac slept happen on wake (anacron-style).
- **Runs** — full history of every backup / copy / check / prune with live progress, stats, and logs; "Back Up Now" manual trigger.
- **Restore** — browse or search snapshots of any destination, restore selected paths with overwrite warnings, or mount a snapshot read-only (optional, requires [macFUSE](https://macfuse.github.io)).
- **Maintenance** — retention policies (`restic forget --prune`), repository statistics, and scheduled integrity checks (`restic check --read-data-subset` slice rotation).

Restic Station wraps an off-the-shelf restic binary already installed on the system (e.g. `brew install restic`) — it never bundles or manages restic itself.

## Requirements

- macOS 14 (Sonoma) or later
- restic ≥ 0.18 on the system (`brew install restic`)
- Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build

## Building

```sh
brew install xcodegen restic
./scripts/bootstrap.sh        # runs xcodegen generate
open ResticStation.xcodeproj  # or: xcodebuild -scheme "Restic Station" build
swift test --package-path Core
```

> **Note:** background-agent (SMAppService) and Full Disk Access behavior can only be tested with the app copied to `/Applications` — see [`docs/keychain-and-fda.md`](docs/keychain-and-fda.md).

## Architecture

Three components (full detail in [`docs/architecture.md`](docs/architecture.md)):

| Component | Role |
|---|---|
| `ResticStationCore` (Swift package) | All logic: config, restic process runner + JSON parsers, schedule math, run store, backup engine. Fully unit-testable. |
| `restic-station-helper` (CLI, embedded in the app bundle) | The single code path for all mutating restic operations. Invoked by `launchd` every 2 minutes in `tick` mode and by the app for manual actions. |
| `Restic Station.app` (SwiftUI) | Menu bar status + management window (sets, runs, restore, maintenance, settings). |

Repository passwords and secret environment variables (e.g. S3 keys) live in the macOS Keychain, never in config files. See [`docs/keychain-and-fda.md`](docs/keychain-and-fda.md) for how headless keychain access works.

## Documentation

| Doc | Contents |
|---|---|
| [architecture.md](docs/architecture.md) | Components, process model, invariants, error taxonomy |
| [data-model.md](docs/data-model.md) | Config / state / run-record schemas with examples |
| [restic-cli.md](docs/restic-cli.md) | Exact restic invocations, exit codes, captured `--json` output fixtures |
| [scheduling.md](docs/scheduling.md) | Tick model, due-computation rules, locking, staleness |
| [keychain-and-fda.md](docs/keychain-and-fda.md) | Keychain ACL strategy, Full Disk Access / TCC, SMAppService gotchas |
| [ui-spec.md](docs/ui-spec.md) | Screen-by-screen UI specification |
| [testing.md](docs/testing.md) | Test strategy, fakes, fixtures, integration script contract |
| [tasks/](docs/tasks/) | The implementation task breakdown (mirrored as GitHub issues) |

## License

[MIT](LICENSE)
