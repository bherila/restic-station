# Testing strategy

Three layers: unit tests (portable Core plus macOS app wiring), an integration script (real restic, macOS **and** Linux CI — see §Layer 2), and manual hardware/OS checklists (see §Layer 3; they cannot be automated).

## Layer 1 — unit tests (`swift test --package-path Core`; app tests through `xcodebuild test`)

### Framework: Swift Testing (not XCTest)
Core and app unit tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`/`#require`, parameterized `@Test(arguments:)` for the table-driven suites) — never XCTest. Core tests run through SwiftPM on macOS and Linux; app tests run through the Xcode-generated `Restic StationTests` target on macOS. Keep portable business logic in Core, but cover app-owned state transitions and wiring in the app target instead of relying on compilation alone.

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

Conventions: every ResticRunner/SecretStore/Engine test asserts BOTH the argv/env sent AND the behavior given the scripted reply. Env assertions always check: `RESTIC_PASSWORD_COMMAND` exact string, secret-env injection, `RESTIC_CACHE_DIR` presence, and that the inherited environment was NOT passed through.

Secrets are injected as a `FakeSecretStore`, not scripted as `/usr/bin/security` subprocesses: since T23 the store is behind the `SecretStore` protocol, so a runner/engine test's process script contains restic calls and nothing else. The keychain backend's own argv is asserted in `KeychainSecretStoreTests` (macOS only); the shared semantics both backends must honour are in `SecretStoreConformanceTests`, which runs `FileSecretStore` on **every** platform — that is how the Linux secrets path gets real coverage from a macOS run. `FileSecretStoreTests` additionally exercises the file backend's POSIX boundary: root-vs-user owner trust for the secret file and data directory, mode checks on the opened descriptor, sticky-directory replacement behavior, and ownership-aware diagnostics for an unremovable fixed temp entry.

`scripts/secret-cli-test.sh` is the Layer-2 test for secrets: it drives the real helper binary with `RESTIC_STATION_SECRET_BACKEND=file`, asserts `secrets.json` is `0600`, asserts `print-password` returns the exact bytes with `cmp`/`od`, and (when restic is on PATH) runs a real backup and then greps the whole data directory to prove the password reached no log, run record or state file.

### Fixture conventions
`Core/Tests/ResticStationCoreTests/Fixtures/` — restic output fixtures are copied verbatim from `docs/fixtures/` (captured from restic 0.18.1; see restic-cli.md). Load via `Bundle.module` (declare `resources: [.copy("Fixtures")]` in Package.swift). Every parser has a test decoding its fixture; NDJSON parsers additionally get a partial-line-buffering test (feed the fixture in random-sized chunks, expect identical parse) and an unknown-`message_type` tolerance test.

The same directory also holds **our own** persisted-file fixtures, which have no `docs/fixtures/` counterpart because they are not restic output: `config-v1.json` (a realistic pre-schema-v2 `config.json`, the input to the migration tests) and `config-v2.json` (the same fleet with per-machine overrides, the input to the resolution tests).

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

Real restic (from PATH; CI: `brew install restic` on macOS, and the **official 0.18.1 release binary** on Linux — deliberately *not* `apt-get install restic`, because Ubuntu 24.04 ships 0.16.4, below the 0.17.0 minimum `ResticDiscovery` enforces, so any scenario that relies on discovery rather than a pinned `resticPath` fails — since issue #50 with an explicit "restic 0.16.4 … is too old", previously with a flatly misleading "restic not found"). Runs on **both platforms** (extended for Linux by T29 / issue #31 — one script, so the two platforms cannot silently drift in what they cover). Contract:
- Env: `RESTIC_STATION_DATA_DIR=<tmp>` (AppPaths override), all repos/sources under `mktemp -d`.
- Secret backend, by platform: macOS seeds real **keychain** items via `security add-generic-password … -T /usr/bin/security` with test UUIDs, `trap`-cleaned via `delete-generic-password` (CI keychain is unlocked on macos runners; create/default a temporary keychain if not). Linux — no keychain — forces `RESTIC_STATION_SECRET_BACKEND=file` and seeds via `secret set` (stdin) against the real built binary.
- Build: macOS builds via `xcodebuild`; Linux has no app to build, so CI always sets `RESTIC_STATION_HELPER_OVERRIDE` to the path of an already-built helper — in CI, T29's **static** release binary (see below), never a debug build, so this test exercises what actually ships. (Local dev escape hatch on both platforms: set the same variable yourself to skip the build step entirely.)
- Main scenario (both platforms): write config.json (1 set: tmp source dir, local primary + local secondary, everyMinutes 5, retention keep-last 2) → `helper run-set` → assert: primary snapshots length 1 AND secondary snapshots length 1 (`restic snapshots --json | jq length`), index.jsonl has backup ✓ + copy ✓, repo-status lastSyncedAt set → mutate source, run again, assert 2/2 → "unplug" secondary (`mv` the repo dir) → run → assert backup ✓, no copy record, reachable=false → "replug" → run → assert secondary catches up to 3 snapshots (add a third change) → assert `run-set --kind prune` **refuses** (manual retention apply is contained for #111/#82: nonzero exit, the posture explained, no prune record of any status, no snapshots removed) → make the set due and run `helper tick`, asserting a *scheduled* backup plus the copy and prune records, and snapshot counts dropping per keep-last 2 — the scheduled entry point rather than `run-set`, which dispatches with a manual trigger → `helper tick` with nothing due → assert no new records.
- **M5 story (`assert_fixture_flow`, both platforms)** — the Mac-authored-config-on-Linux story end to end, not just a repeat of the scenario above: `config import` of `scripts/fixtures/mac-exported-config.json` (a **checked-in** fixture — placeholder tokens `__SOURCE_DIR__`/`__PRIMARY_REPO__`/`__MIRROR_REPO__`/`__MACHINE_ID__` are `sed`-substituted per run, so the test never depends on a live Mac) → `secret set` via stdin for both destinations → a real `backup` against a local repo → the second destination as a mirror, asserting its snapshot count and its `copy` index record (`restic copy` actually ran) → `config validate`, asserting on real stdout that the enabled set says `RUNS HERE`, the fixture's Mac-only set (disabled via a `machines` override keyed on the test's `RESTIC_STATION_MACHINE_ID`) says `does not run here` / `disabled on this machine`, and — because only one of the two sets is disabled — that "nothing will run on this machine" does **not** appear → `status --json` piped through `jq`, asserting exactly one set (the disabled one must not appear) with `lastBackup.status == "success"`, and exactly one `excludedHere` entry with `reason == "disabledForMachine"`. This is the anti-silent-failure guarantee of the whole per-machine design, asserted on actual output, not inferred.
- Exit nonzero on any assertion failure; print the failing section (`fail()` dumps `runs/index.jsonl` + relevant `state/*.json` + `config.json`).

### Static Linux binary + packaging (T29 / issue #31)

`scripts/setup-static-linux-sdk.sh` installs — idempotently, without sudo — a pinned swift.org open-source macOS toolchain (extracted via `pkgutil --expand-full`, never installed system-wide) plus Apple's Static Linux SDK (musl) artifact bundle of the *same* version, both checksum-verified against values pinned in the script. A same-numbered Xcode toolchain is **not** interchangeable with the SDK — this project's own dev machine (Xcode/Apple Swift 6.3.3) failed to link against the SDK's precompiled `Foundation.swiftmodule` with "compiled module was created by an older version of the compiler" until the matching open-source toolchain was used instead; that mismatch, and downloading a version-matched toolchain to sidestep it, is the whole reason this script exists rather than just running `swift build --swift-sdk … -c release` directly against whatever `swift` is on PATH.

Exact reproducible build (also what `scripts/package-linux.sh` runs):
```sh
SWIFT="$(scripts/setup-static-linux-sdk.sh)"
"$SWIFT" build --swift-sdk x86_64-swift-linux-musl -c release --product restic-station-helper
"$SWIFT" build --swift-sdk aarch64-swift-linux-musl -c release --product restic-station-helper
```
`scripts/package-linux.sh [x86_64] [aarch64]` runs the above, strips debug symbols (`llvm-objcopy --strip-debug --strip-unneeded`, from the same downloaded toolchain), verifies the result is statically linked by ELF header (`file` reports "statically linked" — a real `ldd` run happens in CI, see below, since this build host is macOS and cannot execute the binary it just produced), and packages `dist/restic-station-linux-<arch>.tar.gz` (binary + `install.sh` + `LICENSE` + `README.md` + the T26 systemd units) plus `dist/SHA256SUMS`. See `packaging/linux/README.md` for the shipped tarball's own copy of this.

Two Core source-level changes were needed for the musl SDK specifically: every `#if canImport(Darwin) / #elseif canImport(Glibc)` conditional-import needed an `#elseif canImport(Musl)` branch too — the Static Linux SDK exposes libc as the `Musl` module, not `Glibc` — in `ConfigStore.swift`, `FileLock.swift`, `LogWriter.swift`, `RunStore.swift`, `FileSecretStore.swift`, `ProcessRunning.swift`, `StateStore.swift` and `Helper/Sources/Commands/Secret.swift`. No other source changes were required — no libc-specific behavioral differences surfaced (Foundation-on-musl's historically rough edges did not reproduce here; the code path exercised is limited to `Process`, `FileManager`, `flock` and basic file I/O, none of which hit the known trouble spots like `Calendar`/`TimeZone` data or `NSRegularExpression`).

**Verification, per issue #31's own list** — see `.github/workflows/ci.yml`'s `release-linux`, `linux-runtime-verify` and `linux-integration` jobs:
- Both architectures build; `SHA256SUMS` verifies (`release-linux`).
- `ldd` reports "not a dynamic executable", on both architectures (`linux-runtime-verify`, native runner per arch — no QEMU).
- Runs unmodified in a `scratch` container (no libc, no userland at all) and on Alpine (musl) — both architectures.
- Runs unmodified on Debian 12 (glibc) — both architectures — and on a deliberately old-glibc distro, CentOS 7 (glibc 2.17, 2012) — **x86_64 only**: CentOS 7 predates official arm64 image builds, so that one specific cell is genuinely not exercisable in Actions and is left that way rather than faked or silently dropped.
- `install.sh` is idempotent, installs unprivileged to a custom `--prefix`, and warns when that prefix is not on `PATH` (`linux-integration`, and covered again by the shell-level assertions in that job).
- The Linux integration test (this section, `assert_fixture_flow` included) runs green against the **static** binary on a real (non-container) Ubuntu aarch64 VM with real restic installed — which is also what finally proves T23's "restic authenticates via `RESTIC_PASSWORD_COMMAND` against `FileSecretStore` on Linux" acceptance criterion: the `linux` job's `swift:6.1` container has no restic, so that step was previously only exercised on macOS with the backend forced to `file`.

**Still deferred** — the timer surviving an actual logout/reboot and repeated firing over a
long-duration soak. `scripts/linux-docs-transcript.sh` (§next section) now installs a timer for a
dedicated, never-yet-run backup set and waits up to 250 seconds. On the 2026-08-15 hosted aarch64
run it observed the first activation at +110 seconds (one real scheduled backup) and the
`OnUnitActiveSec=` repeat at +230 seconds (still exactly one backup because the set is due every
five minutes). That closes both the unattended-initial-firing and single-repeat gaps. The runner
also has a real logind session with lingering enabled, but its session and VM never end mid-job;
logout/reboot survival therefore remains genuinely open in issue #45 and needs a persistent Linux
host or suitable self-hosted runner.

### `docs/linux.md` transcripts (T30 / issue #32)

`scripts/linux-docs-transcript.sh` exists so that every command `docs/linux.md` quotes was actually run on Linux rather than paraphrased from a macOS terminal or invented. It is mostly a transcript producer, but it is no longer assertion-free: the claims that are load-bearing for the health-check story — that `timer install` pins the resolved data directory into the unit (#48), that `status --json` reports `scheduler.healthy == false` and exits 1 on a host whose timer is gone (#46), and that an abandoned `current-run` file reports `warning`/`isRunning: false` rather than `running` — each fail the job with an explicit `REGRESSION:` message rather than merely being printed. It runs against the `linux-integration` job's static binary and real restic: config import of the checked-in mac-exported-config.json fixture, secrets via stdin, repo init, a real backup + mirror copy, `status`/`runs`/`restore`, the per-machine override worked examples from `docs/data-model.md` re-validated against `Core/Tests/ResticStationCoreTests/Fixtures/config-v2.json`, `timer install`/`timer status` on this same bare-VM host (including an asserted demonstration that a custom `XDG_STATE_HOME` reaches the unit as a pinned absolute `RESTIC_STATION_DATA_DIR`), a live scheduler-visibility check (`status --json` reporting `scheduler.healthy == false` and exiting 1 after the timer is uninstalled, agreeing with `timer status`), a forged abandoned `current-run` file proving one killed run no longer pins the host green — and a dedicated never-run set whose installed timer is polled for up to 250 seconds. The job now asserts both an unattended initial activation that creates exactly one scheduled backup and an `OnUnitActiveSec=` repeat that does not create an early backup. Its job log is the source text for `docs/linux.md`'s transcripts — copied in by hand, not auto-inserted, but regression-*visible*: if a command's output changes, this step's log changes with it, and a docs update is due. What it still does not attempt is anything needing the real logind session or VM to end mid-job (logout/reboot survival), nor a long-duration soak; that narrower remaining gap is tracked as issue #45, and `docs/linux.md` says so explicitly rather than showing invented output.

## Layer 3 — manual checklists (docs/tasks reference these; run before tagging a release)

**Evidence rule for every row:** record the build SHA and artifact identity
(for example, the signed app's version/build and checksum) with the evidence.
The checklist is a release gate, not a statement that a similarly named build
was tested earlier.

**SMAppService** (app copied to /Applications): register → status Enabled (or approval flow via System Settings) → `launchctl print gui/$UID/net.herila.ResticStation.helper` shows agent and `restic-station-helper status --json` reports `scheduler.kind == "launchd-agent"`, `healthy == true` → wait ≤2 min → tick ran (state files touched) → quit app → tick still runs → unregister → agent gone and CLI scheduler health becomes `false`/`agentNotLoaded`.
**Stall detection**: start a backup against disposable data, wait for `heartbeatUptime` to appear in its current-run file, `kill -STOP <metadata pid>`, and confirm the app and `status --json` change from running/live to warning/stalled after five minutes of awake time; `kill -CONT`, then terminate or let the run finish. Confirm sleep time did not consume the threshold.
**FDA**: revoke in System Settings → both badges show denied → app probe correct; grant to app → app badge granted; Re-check → agent badge granted (if not: fallback path per keychain-and-fda.md verifies).
**Keychain evidence matrix**: record the following fields for every scenario below: the process context (`app`, manual helper, or launchd); the exact OSStatus or typed error (never a prose paraphrase); whether it clears without configuration changes; whether retry after login succeeds; whether the current UI and `status --json` expose it; whether any run record or scheduling state was written; and whether a prompt, delay, or hang occurred.

| Scenario | Required observation |
|---|---|
| Launchd with an unlocked keychain | Run a scheduled backup with the app closed. |
| Pre-login / pre-unlock tick | Let the scheduled tick run before the login keychain is unlocked. |
| App closed | Compare the scheduler-context result with the app's last known state. |
| FDA split | Exercise both directions: FDA granted to the app but not the helper, and to the helper but not the app. |
| Never-configured password | Attempt the scheduled path without a stored destination password. |
| Revoked or moved keychain item | Remove or make the stored item unavailable after configuration. |
| Retry after login | Repeat the pre-login/pre-unlock failure after login without changing configuration. |

**Sleep/catch-up**: schedule daily at a time while Mac will be asleep; wake after → backup runs within ~2 min of wake.
**Physical mirror disconnect/reconnect**: use disposable data and a physical mirror volume; disconnect it before a run, verify the primary can complete without treating the mirror as current, reconnect it, then verify the next eligible backup copies to the mirror before that mirror receives retention.
**Retention preview (read-only)**: inspect the retention preview for a disposable set and verify that previewing alone neither changes snapshots nor creates a run record.
**Manual retention-apply containment refusal**: verify the UI shows the exact "unavailable in this build" posture and the helper's successfully parsed `run-set --kind prune` refuses; verify it creates no run record and removes no snapshots. Do not substitute a manual `forget` command for this check.
**Scheduled retention via a due tick**: make a disposable, policy-configured set due and run `tick`; verify the scheduled backup completes, a caught-up mirror is copied before it is pruned, the primary is pruned last, and the observed retained snapshots match that set's configured `--keep-*` policy.
**Reclaim space with token confirmation**: in the app's confirmation flow, preview reclaim space for a disposable destination, then confirm with the currently displayed confirmation binding; verify a stale, altered, or already-consumed binding is refused before `restic prune` runs. This does not change the documented direct human-CLI path, where omitting `--expected-destination` is deliberate.
**Restore** (from every supported destination class): restore a known fixture from a local destination, an external-volume destination, and SFTP to fresh targets; compare bytes or cryptographic hashes to the source for each. Also confirm original-location restore shows its warning.

## CI (`.github/workflows/ci.yml`)

| Job | Runner | Steps |
|---|---|---|
| `linux` | `ubuntu-24.04-arm`, container `swift:6.1` | `swift build`/`swift test` (root package) → `swift test --package-path Core` → `scripts/secret-cli-test.sh` + `scripts/headless-cli-test.sh` (restic absent in this container, so their real-backup halves skip) → T25/T26 platform-conditional checks (no systemd in this container — see `linux-integration` below for the systemd VM) |
| `macos` | `macos-15` | `brew install xcodegen restic jq` → `xcodegen generate` → `xcodebuild -scheme "Restic Station" build CODE_SIGNING_ALLOWED=NO` → `swift test --package-path Core` → `scripts/integration-test.sh` → `scripts/secret-cli-test.sh` + `scripts/headless-cli-test.sh` (real backup halves run here) → ad-hoc sign + upload `Restic-Station-app` artifact |
| `release-linux` | `macos-15` | `scripts/package-linux.sh x86_64 aarch64` (self-contained: installs its own pinned toolchain/SDK) → verify `SHA256SUMS` → verify tarball layout → upload `restic-station-linux` artifact (both tarballs + checksums) |
| `linux-integration` | `ubuntu-24.04-arm` (bare VM, no container) | downloads `restic-station-linux`'s aarch64 tarball → installs real restic + jq → `ldd` + `install.sh` checks → `scripts/integration-test.sh` against the **static** binary (`RESTIC_STATION_HELPER_OVERRIDE`) → non-blocking T26 systemd diagnostic → `scripts/linux-docs-transcript.sh` (T30 / issue #32: real command transcripts for `docs/linux.md`, against this same static binary and real restic) |
| `linux-runtime-verify` | `ubuntu-latest` (x86_64) and `ubuntu-24.04-arm` (aarch64), matrix | `ldd` → builds+runs a `scratch` container → runs on Alpine → runs on Debian 12 → (x86_64 only) runs on CentOS 7, the deliberately old-glibc distro |

The manually triggered `macOS Release Verification` workflow is the clean,
hosted-Mac release evidence path. Unlike the ordinary `macos` job, it builds a
Release app, installs and launch-smokes that exact bundle, exercises the CLI
symlink and direct-versus-symlink FDA probes, runs the real backup/restore and
secret integration suites against the installed Release helper, runs the
exhaustive headless fixture matrix against the Debug helper from the same
commit, and uploads detailed evidence.
See [macOS release verification](macos-release-verification.md) for its scope
and the user-approval/reboot checks that an ephemeral runner cannot prove.

All jobs on push + PR; the four Linux-release jobs depend only on `release-linux`, not on `linux`/`macos`, so a static-build regression is visible even if the debug-build jobs are still running. Keep total macOS time reasonable (public-repo runners are free but slow) — `release-linux` is the long pole (~1-2 min per architecture once its toolchain cache is warm, longer cold).
