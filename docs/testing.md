# Testing strategy

Three layers: unit tests (Core, run everywhere including Linux CI), an integration script (real restic, macOS CI), and manual checklists (SMAppService/FDA — cannot be automated).

## Layer 1 — unit tests (`swift test --package-path Core`)

### Linux compatibility requirement
Core MUST compile and its tests pass on Linux (CI runs them on an `ubuntu-24.04-arm` runner in a `swift:6.1` container — cheap and fast for public repos). Practical rules:
- Darwin-only API (`DistributedNotificationCenter`, anything from AppKit/ServiceManagement) is wrapped in `#if os(macOS)` or lives in the App target, not Core.
- Use `FoundationEssentials`-safe APIs where possible; `Process`, `FileManager`, `flock` (via `Glibc`/`Darwin` import switch) all work on Linux.
- If a test is inherently Darwin-only, gate it `#if os(macOS)` — but prefer designing Core so nothing is.

### FakeProcessRunner (the load-bearing test double)

```swift
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Expectation {
        let argvPrefix: [String]          // match: recorded argv starts with this
        let stdoutLines: [String]         // streamed to onStdoutLine, then included in stdout
        let stderr: String
        let exitCode: Int32
        let delay: TimeInterval?          // optional, for timeout tests
    }
    var script: [Expectation]             // consumed in order
    private(set) var invocations: [(argv: [String], env: [String: String]?)]
    // run(...) pops the next expectation, asserts argv matches, replays it.
}
```

Conventions: every ResticRunner/KeychainClient/Engine test asserts BOTH the argv/env sent AND the behavior given the scripted reply. Env assertions always check: `RESTIC_PASSWORD_COMMAND` exact string, secret-env injection, `RESTIC_CACHE_DIR` presence, and that the inherited environment was NOT passed through.

### Fixture conventions
`Core/Tests/ResticStationCoreTests/Fixtures/` — copied verbatim from `docs/fixtures/` (captured from restic 0.18.1; see restic-cli.md). Load via `Bundle.module` (declare `resources: [.copy("Fixtures")]` in Package.swift). Every parser has a test decoding its fixture; NDJSON parsers additionally get a partial-line-buffering test (feed the fixture in random-sized chunks, expect identical parse) and an unknown-`message_type` tolerance test.

### BackupEngine scenario table (implemented as one parameterized test per row)

| # | Scenario | Scripted replies | Expected |
|---|---|---|---|
| 1 | Happy path: primary + 2 reachable secondaries, retention set | backup exit 0 (fixture stream) → copy exit 0 ×2 → forget exit 0 ×3 | index: backup ✓, copy ✓×2, prune ✓×3, same groupId; lastSyncedAt updated ×3; current-run deleted |
| 2 | Primary unreachable (local path missing) | (no restic calls after probe) | backup `.failed` "primary unreachable"; NO copy attempted; lastBackupStart updated (attempt) |
| 3 | Secondary offline | backup 0 → probe secondary fails → (no copy for it) → copy other secondary 0 | backup ✓; offline secondary: no run record, repo-status reachable=false, staleness from old lastSyncedAt; other copy ✓ |
| 4 | Backup exit 3 (partial read) | backup exit 3 with summary | backup `.warning`; copies still run (snapshot exists) |
| 5 | Backup exit 1 | backup exit 1 | `.failed`; no copies, no retention |
| 6 | Copy fails on one secondary | backup 0 → copy A exit 1 → copy B exit 0 | copy A `.failed`, copy B ✓, backup ✓; group status shown as warning; A's lastSyncedAt NOT updated |
| 7 | Repo locked, stale | backup exit 11 → unlock 0 → backup 0 | one retry; final ✓; log contains both attempts |
| 8 | Repo locked, live | backup exit 11 → unlock 0 → backup exit 11 | `.failed` "repository locked" |
| 9 | Keychain locked pre-flight | find-generic-password exit 1 | NO run record, NO lastBackupStart change (retryable) |
| 10 | Set lock busy | (lock pre-acquired by test) | `.skipped` record, nothing else |
| 11 | Empty retention policy | backup 0, retention isEmpty | forget NOT invoked |
| 12 | Retention mirrored only after successful copy | backup 0 → copy A 1 → forget on A must NOT run | assert forget argv never targets A |

ScheduleMath: table-driven tests per rule in scheduling.md — incl. DST spring-forward (`America/New_York`, 2026-03-08, daily 02:30), fall-back, week-asleep hourly → exactly one catch-up, everyMinutes interval semantics, clock-backwards clamp.

RunStore: temp-dir AppPaths; crash-recovery test (write `running` metadata with dead pid → recover marks `failed`); index append under contention (two FileLocks, in-process; flock is per-open-file-description — take care to open separately).

## Layer 2 — integration script (`scripts/integration-test.sh`)

Real restic (from PATH; CI: `brew install restic`), macOS only. Contract:
- Env: `RESTIC_STATION_DATA_DIR=<tmp>` (AppPaths override), all repos/sources under `mktemp -d`; **keychain**: seeds real items via `security add-generic-password … -T /usr/bin/security` with test UUIDs, `trap`-cleaned via `delete-generic-password` (CI keychain is unlocked on macos runners; create/default a temporary keychain if not).
- Steps: build helper (xcodebuild) → write config.json (1 set: tmp source dir, local primary + local secondary, everyMinutes 5, retention keep-last 2) → `helper run-set` → assert: primary snapshots length 1 AND secondary snapshots length 1 (`restic snapshots --json | jq length`), index.jsonl has backup ✓ + copy ✓, repo-status lastSyncedAt set → mutate source, run again, assert 2/2 → "unplug" secondary (`mv` the repo dir) → run → assert backup ✓, no copy record, reachable=false → "replug" → run → assert secondary catches up to 3 snapshots (add a third change) → apply retention → assert snapshot counts drop per keep-last 2 → `helper tick` with nothing due → assert no new records. Exit nonzero on any assertion failure; print the failing section.

## Layer 3 — manual checklists (docs/tasks reference these; run before tagging a release)

**SMAppService** (app copied to /Applications): register → status Enabled (or approval flow via System Settings) → `launchctl print gui/$UID/net.herila.ResticStation.helper` shows agent → wait ≤2 min → tick ran (state files touched) → quit app → tick still runs → unregister → agent gone.
**FDA**: revoke in System Settings → both badges show denied → app probe correct; grant to app → app badge granted; Re-check → agent badge granted (if not: fallback path per keychain-and-fda.md verifies).
**Keychain**: create destination with password → run scheduled backup with app closed → no GUI prompt appears, backup succeeds.
**Sleep/catch-up**: schedule daily at a time while Mac will be asleep; wake after → backup runs within ~2 min of wake.
**Restore**: real restore of a folder to a temp target; diff -r matches; original-location restore shows the warning.

## CI (`.github/workflows/ci.yml`)

| Job | Runner | Steps |
|---|---|---|
| `core-linux` | `ubuntu-24.04-arm`, container `swift:6.1` | `swift test --package-path Core` |
| `macos` | `macos-15` | `brew install xcodegen restic` → `xcodegen generate` → `xcodebuild -scheme "Restic Station" build CODE_SIGNING_ALLOWED=NO` → `swift test --package-path Core` → `scripts/integration-test.sh` |

Both jobs on push + PR. Keep total macOS time < 15 min (public-repo runners are free but slow).
