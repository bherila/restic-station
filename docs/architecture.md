# Architecture

## Components

```
┌─────────────────────────┐         ┌──────────────────────────────┐
│  Restic Station.app     │ invokes │  restic-station-helper (CLI) │
│  (SwiftUI)              ├────────▶│  embedded in app bundle      │
│  - MenuBarExtra         │         │  Contents/MacOS/             │
│  - Management window    │         └──────┬───────────────────────┘
│  - StateWatcher (reads) │                │ spawns          ▲
└───────────┬─────────────┘         ┌──────▼──────┐         │ StartInterval 120
            │ read-only queries     │   restic    │      ┌──┴──────┐
            └──────────────────────▶│  (system)   │      │ launchd │
                                    └─────────────┘      └─────────┘
Shared state on disk: ~/Library/Application Support/ResticStation/
Secrets: macOS login Keychain (service "restic-station")
```

1. **`ResticStationCore`** — local Swift package at `Core/`. Contains **all** logic: config model + store, keychain client, restic runner + command builders + parsers, restic discovery, schedule math, run store, file locking, backup engine, reachability, state store. No UI. Depends only on Foundation (+ swift-argument-parser is *not* here; it's a Helper dependency). `Package.swift` declares `platforms: [.macOS(.v14)]` so `swift test --package-path Core` works standalone.
2. **`restic-station-helper`** — command-line executable target, embedded in the app bundle at `Contents/MacOS/restic-station-helper`. Uses swift-argument-parser. Subcommands: `tick`, `run-set`, `init-secondary`, `probe-repo`, `restore`, `fda-check`, `version`. Each invocation does its work and **exits** — it never daemonizes. launchd re-fires it via `StartInterval`.
3. **`Restic Station.app`** — SwiftUI app. Regular app (Dock icon + windows) plus a `MenuBarExtra`. Registers the helper's LaunchAgent via `SMAppService`.

## The single-code-path rule

**Every restic operation that mutates a repository goes through the helper binary.** The app never runs `restic backup`, `copy`, `forget`, `restore`, `init`, or `unlock` itself — for manual actions ("Back Up Now", restore, prune-now, init-secondary) it spawns the embedded helper with the corresponding subcommand. This guarantees identical behavior for scheduled and manual runs: same locking, same run recording, same state updates.

**The one sanctioned exception:** the app MAY execute **read-only** restic queries directly (`snapshots`, `ls`, `find`, `stats`, `cat config`, `version`) for interactive browsing in the Restore and Maintenance screens, using the same `ResticRunner` from Core. Read-only queries take no repository lock that matters and produce no run records.

## Process & threading model

- The helper is short-lived per invocation, except while a backup/copy/check runs (the process lives until the work finishes — this may exceed the 120 s `StartInterval`; overlapping ticks are prevented by locks, see `scheduling.md`).
- Long restic operations stream NDJSON progress; the helper writes throttled progress snapshots to `state/` (≤ 1 write per 1–2 s) and appends every line to the run log.
- The app is purely reactive: it reads `state/` and `runs/`, watching for changes via a `DispatchSource` directory watcher plus a best-effort `DistributedNotificationCenter` nudge posted by the helper after each state write. Notifications are lossy by design; the directory watcher is the source of truth.

## Dependency injection rule (testability)

**No code in Core calls `Process` directly.** All subprocess execution goes through the `ProcessRunning` protocol (`Core/Sources/ResticStationCore/Support/ProcessRunning.swift`):

```swift
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
}

public protocol ProcessRunning: Sendable {
    /// Runs argv[0] with argv[1...], replacing (not inheriting) the environment
    /// when `env` is non-nil. `onStdoutLine` receives each complete
    /// newline-terminated line as it arrives (for NDJSON streaming).
    /// Throws ProcessRunnerError.timeout after sending SIGINT (then SIGKILL
    /// after a 10 s grace period) if `timeout` elapses.
    func run(
        _ argv: [String],
        env: [String: String]?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?
    ) async throws -> ProcessResult
}
```

The production implementation (`DefaultProcessRunner`) wraps `Process` + pipes. Tests inject `FakeProcessRunner` (see `testing.md`). `KeychainSecretStore`, `ResticRunner`, and `Reachability` all take a `ProcessRunning` in their initializers. Secret storage itself is behind the `SecretStore` protocol (`KeychainSecretStore` on macOS, `FileSecretStore` elsewhere — see `keychain-and-fda.md`); `ResticRunner` and `BackupEngine` take `any SecretStore`, not a concrete backend.

## restic discovery

`ResticDiscovery` (`Core/Sources/ResticStationCore/Restic/ResticDiscovery.swift`) finds a usable restic binary. It lives in **Core**, not `App/`: the helper needs it too, and `App/` is macOS-only.

Search order: the platform's well-known package-manager locations first, then one `<dir>/restic` per `PATH` entry.

| Platform | Well-known locations (in order) |
| --- | --- |
| macOS | `/opt/homebrew/bin/restic`, `/usr/local/bin/restic`, `/opt/local/bin/restic` |
| Linux | `/usr/bin/restic`, `/usr/local/bin/restic`, `/opt/restic/bin/restic` |

Three rules, all load-bearing:

1. **A candidate is "found" only if it *ran*.** Existence plus the `+x` bit is a filter, never the answer — a Homebrew shim for an uninstalled formula, an x86 binary with no Rosetta, a distro wrapper for an uninstalled package, and a dangling symlink all pass `isExecutableFile` and fail to execute. Every reported version comes from a real `restic version --json` round trip, compared against the documented minimum (0.17.0, `restic-cli.md` §version).
2. **Per-candidate timeout** (5 s) so a binary on an unresponsive network mount cannot stall onboarding, and a **cap of 24 candidates executed per search** so a pathological `PATH` cannot either.
3. **Only absolute paths.** Relative `PATH` entries (including the empty entry POSIX shells read as the current directory) are dropped: the resolved path is consumed by a helper running headless with an unrelated working directory.

**Who resolves what.** The app persists a user-chosen or discovered path into `config.json`'s `resticPath` and shows the rejected candidates in Settings. The helper resolves independently, in this order:

1. `machine.json` `resticPath` — the per-machine override (T24; not implemented yet, see the `TODO(#26)` in `Helper/Sources/ResticPathResolution.swift`).
2. `config.json` `resticPath` — deprecated. `config.json` is shared across machines, so a path correct on one host is wrong on the next.
3. Discovery.

A discovered path is logged once at info level and deliberately **not** written back into `config.json`. When nothing resolves, macOS prints the T10 wording ("restic not configured — open Restic Station"); Linux, where there is no app to open, prints what was searched and how to fix it.

## Error taxonomy

Every failure is classified into one of three categories, which drive both `RunStatus` and retry behavior:

| Category | Meaning | Examples | Effect |
|---|---|---|---|
| **Terminal** | The operation failed; a run record with `.failed` is written; no retry until next scheduled slot or manual trigger | restic exit 1 (fatal), exit 12 (wrong password), exit 10 (repo missing), primary unreachable | run `.failed`, menubar warning state |
| **Warning** | The operation completed with caveats; run record `.warning` | restic exit 3 (some source files unreadable), a secondary offline (skip + staleness), check found no errors but a slice was skipped | run `.warning` |
| **Retryable** | Environmental/transient; do NOT write a `.failed` run — leave schedule state untouched so the next tick retries | keychain locked (password command fails at pre-login tick), set lock busy (another run in flight), tick lock busy | run `.skipped` (busy) or no record (keychain locked) |

restic exit code mapping (verified against restic 0.18.1 — see `restic-cli.md`): `0` success, `1` fatal, `2` Go runtime error, `3` backup incomplete-read warning, `10` repository does not exist, `11` repository locked, `12` wrong password. Exit 11 on a *scheduled* run: attempt `restic unlock` once (removes only stale locks of dead processes), retry the operation once, then fail terminal if still locked.

## RunStatus

`success` | `warning` | `failed` | `skipped` | `running`. `skipped` records exist so the UI can show "was due but another run was in flight". A crash mid-run leaves a `running` metadata record with no end time; the next helper invocation that finds a `running` record whose PID is dead rewrites it as `failed` with message "interrupted".

## AppPaths

All runtime paths come from one type, `AppPaths` (in `Config/`), never hard-coded elsewhere. `root` is overridable via init parameter and via the environment variable `RESTIC_STATION_DATA_DIR` (used by tests and the integration script), which takes precedence on every platform. Otherwise it resolves per-platform:

| | macOS | Linux |
|---|---|---|
| `root` | `~/Library/Application Support/ResticStation` | `$XDG_STATE_HOME/restic-station`, else `~/.local/state/restic-station` |
| restic cache | `~/Library/Caches/net.herila.ResticStation/restic` | `$XDG_CACHE_HOME/restic-station/restic`, else `~/.cache/restic-station/restic` |

State — not config — is the right XDG base dir for `root`: `config.json` is the smallest part of it, and the directory is dominated by `runs/`, `state/`, and `locks/`. Per the XDG Base Directory Specification an `XDG_*` value that is not an absolute path is ignored and the fallback applies as if it were unset.

**`root` and the restic cache are the only platform-dependent members.** Everything below `root` is byte-identical across platforms — `config export`/`import` and rsync-ing a data directory between hosts depend on this, and a test asserts it.

| Path (relative to `root`) | Contents |
|---|---|
| `config.json` | `AppConfig` (see `data-model.md`) |
| `runs/<runId>/metadata.json` | one `RunMetadata` per run |
| `runs/<runId>/log.txt` | full streamed log of the run |
| `runs/index.jsonl` | append-only, one summary JSON line per finished run |
| `state/schedule-state.json` | last-start times + check-slice cursors per set |
| `state/current-run-<setId>.json` | live progress of an in-flight run (deleted on completion) |
| `state/repo-status-<destId>.json` | reachability + last-synced info per destination |
| `state/fda-check.json` | result of the helper's Full Disk Access probe |
| `locks/tick.lock`, `locks/set-<setId>.lock` | flock files (see `scheduling.md`) |
| `mounts/<destId>/` | `restic mount` mountpoint (see `restic-cli.md` §mount) |

restic's cache is redirected via `RESTIC_CACHE_DIR` to the location in the table above. It is deliberately independent of `root` — it is a regenerable cache, not app state.

`mounts/<destId>/` is defined on both platforms but is macOS-only in practice: `restic mount` requires macFUSE on macOS and FUSE on Linux, which a headless Linux host generally does not have.

`runId` format: `<ISO8601 basic UTC>-<kind>-<first 8 chars of set UUID>`, e.g. `20260726T205704Z-backup-a1b2c3d4`.

## Identifiers

- Bundle id: `net.herila.ResticStation`; helper LaunchAgent label: `net.herila.ResticStation.helper`.
- `BackupSet.id` and `Destination.id` are UUIDs assigned at creation and **never change** — the destination UUID is the keychain account key; changing it orphans the stored password.

## Build system

XcodeGen (`project.yml`) generates `ResticStation.xcodeproj` (git-ignored). Two targets (`Restic Station` app, `restic-station-helper` tool) both depend on the local package `ResticStationCore`. The helper is embedded via a Copy Files phase (destination: executables); the LaunchAgent plist is copied to `Contents/Library/LaunchAgents/` via a Copy Files phase (destination: wrapper). CI builds with `CODE_SIGNING_ALLOWED=NO`; the app is **not sandboxed** (required for spawning restic/security, PATH-external binaries, and flock in Application Support) and is therefore not App Store eligible — accepted.
