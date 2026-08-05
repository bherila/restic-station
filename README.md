# Restic Station

A native macOS menu bar app for scheduling and managing [restic](https://restic.net) backups.

**Status: feature-complete, pre-release.** All planned functionality is implemented and CI-tested (including an integration suite against real restic); signed releases are not yet published — install from a CI build or build from source (below).

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
- Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build from source

## Installing

Until signed releases exist, grab a CI build: open any green run on the [Actions page](../../actions), download the **Restic-Station-app** artifact, then:

```sh
unzip Restic-Station-app.zip
xattr -dr com.apple.quarantine "Restic Station.app"   # CI builds are ad-hoc signed
mv "Restic Station.app" /Applications/
```

Running from `/Applications` matters: the background agent (SMAppService) and Full Disk Access attribution bind to the app's path.

### First-run setup

1. Launch the app and follow onboarding: pick your restic binary (auto-discovered from `/opt/homebrew/bin/restic`), register the background agent (approve it under **System Settings → General → Login Items & Extensions** if asked).
2. Grant **Full Disk Access**: System Settings → Privacy & Security → Full Disk Access → add **Restic Station**. There is no prompt for this — macOS requires you to do it manually, and backups of Mail/Safari/Messages data silently fail without it. Onboarding shows two badges (**App** and **Background agent**) and both must go green; if the agent badge stays denied, see the [troubleshooting section](docs/keychain-and-fda.md#troubleshooting-from-t11t18-implementation-evidence).
3. Create a Backup Set: sources, a primary repository (with password — stored in your Keychain), optional mirrors, a schedule, and a retention policy.

## Command line

Restic Station is GUI **and** CLI. The tool itself ships embedded inside the app bundle at `Restic Station.app/Contents/MacOS/restic-station-helper` — install a friendly `restic-station` symlink on your `PATH` and use that instead of typing the bundle path:

```sh
restic-station-helper cli install --user   # ~/.local/bin, no sudo; drop --user for /usr/local/bin
restic-station status                      # or from Settings → General → Command line, Install button
```

`cli install` always creates a **symlink**, never a copy — the embedded binary's location matters (it's what `SMAppService` registration and Full Disk Access attribution bind to; see [`docs/keychain-and-fda.md`](docs/keychain-and-fda.md)), and a symlink is transparent to both because the kernel resolves it before anything runs. `cli status` reports whether it's installed and where it points; `cli uninstall` removes it. All three are idempotent and refuse to touch a file at the target path that isn't one of their own symlinks. The same install/uninstall is one click away in **Settings → General → Command line**.

A few representative commands once installed:

```sh
restic-station status --json          # headless equivalent of the menu bar; exit 1 if any set needs attention
restic-station sets list              # configured backup sets on this machine
restic-station runs list --limit 20   # recent run history
restic-station config show --json     # effective, per-machine-resolved configuration
```

Run `restic-station --help` for the full subcommand list (`config`, `status`, `sets`, `runs`, `secret`, `cli`, and the mutating commands `tick`/`run-set`/`restore`/… that the app and the background agent use themselves). Out of scope for now: a Homebrew formula, man pages, and shell completions (ArgumentParser can generate the last one cheaply — see the open follow-up issue if you want to pick it up).

## Building from source

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
| `restic-station-helper` (CLI, embedded in the app bundle) | The single code path for all mutating restic operations. Invoked by `launchd` every 2 minutes in `tick` mode, by the app for manual actions, and directly by users via the `restic-station` `PATH` symlink (see [Command line](#command-line) above). |
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

## FAQ

**Why does the app need Full Disk Access?**
Restic reads your files directly, and macOS blocks access to Mail, Safari, Messages, and similar data without FDA — with no prompt, just silent failures. The file-picker permission the app gets when you choose sources doesn't extend to the background helper that actually runs scheduled backups, so FDA is effectively required for real backups. Details: [docs/keychain-and-fda.md](docs/keychain-and-fda.md).

**Where are my repository passwords stored?**
In your login Keychain (service `restic-station`), never in config files. They're written and read via Apple's `/usr/bin/security` tool so that headless scheduled backups can read them without a GUI consent prompt. One accepted tradeoff: when saving a password, it is momentarily visible in the local process list.

**Why is my mirror marked stale?**
A mirror only advances when a `restic copy` from the primary succeeds. If the mirror's drive was unplugged (or a copy failed), it's skipped gracefully and its "last synced" age grows — that's the staleness badge. Plug the drive back in; the next run catches it up in full. Mirrors are add-only: damage or pruning on the primary is never propagated to them.

**What happens when my external drive is unplugged?**
Nothing bad. Backups to the primary continue; the offline mirror is skipped (no error spam), tracked for staleness, and fully caught up next time it's connected. Retention is never applied to a mirror that isn't caught up.

**Do backups run when the app is closed / the Mac was asleep?**
Yes. A `launchd` agent runs the helper every 2 minutes independent of the app; schedules missed during sleep run within ~2 minutes of wake (anacron-style).

## License

[MIT](LICENSE)
