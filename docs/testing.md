# Testing strategy

Three layers: unit tests (portable Core plus macOS app wiring), an integration script (real restic, macOS **and** Linux CI — see §Layer 2), and manual hardware/OS checklists (see §Layer 3; they cannot be automated).

## Layer 1 — unit tests (`swift test --package-path Core`; app tests through `xcodebuild test`)

App tests include focused projection contracts for non-UI state machines:
restic discovery-to-badge mapping, Full Disk Access evidence provenance and
staleness, destination-status priority, onboarding, run-history naming, and
the user-visible copy derived from those states. Retention affordance tests
also bind its cleanup promises to the engine gate, policy, per-machine set
scope, and background-agent state. These complement the
generation/race coverage in `StateWatcherTests` and
`AppModelMachineOverrideTests`; they do not require a SwiftUI rendering
harness.

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

### Real-subprocess exceptions to FakeProcessRunner

Two suites deliberately spawn real processes, because what they assert *is* the
POSIX behaviour a double would have to invent: `DefaultProcessRunnerTests`
(stdin/EOF handling, SIGPIPE disposition inheritance) and `ProcessLifetimeTests`
(#114 — the deadline must race process termination rather than pipe EOF, and a
descendant holding the inherited pipe ends must not outlast it). Between them they use only `/bin/sh`,
`/bin/echo` and `/bin/sleep`, all present on macOS and in the `swift:6.1`
Linux container.

`ProcessLifetimeTests` asserts that a run with a deadline always returns
within a bound. It does **not** assert which signal ended the child, because
that is not portable — see below — and a test that pins the mechanism pins a
platform. The engine's actual requirement is that a deadline cannot be
outlasted while the set lock is held.

The stop sequence is up to four waits deep in the worst case (deadline →
SIGINT grace → termination bound → drain grace), so at the production 10 s
graces one assertion costs 30 s+, and a bound loose enough to survive that
stops distinguishing "the deadline was enforced" from "the child was waited
out". `DefaultProcessRunner` therefore takes its two graces as an internal
initializer parameter; these tests pass 1 s and finish in ~3 s with bounds
that are tight enough to mean something. `stopSequenceGracesAreTenSecondsInProduction`
guards the seam, so shrinking graces for tests cannot quietly become the
shipped values. The children sleep 60 s, far longer than any bound, so
"waited the child out" can never pass.

**An elapsed bound is not optional on a timeout test.** `#expect(throws:)`
alone passes identically whether the deadline stopped the child or was merely
*reported* on schedule while the child ran to completion — and the second is
the #114 defect itself. `timeoutStopsTheProcess` (formerly
`timeoutSendsSIGINT`) asserted only the throw and so could not distinguish
them; it is plausible it had been passing vacuously on Linux for some time.

**The suite's own speed changed a flake rate (#116).** `posix_spawn`
intermittently fails with `EFAULT` under concurrent spawn load. Shrinking the
stop-sequence graces took the Core suite from ~24 s to ~5 s, which packed the
same 936 tests into a fifth of the wall clock and took that flake from roughly
1 run in 25 to **4 in 20** — measured, not estimated. The trigger is density,
not the new tests: skipping `ProcessLifetimeTests` entirely left the rate
unchanged at 4/20. `DefaultProcessRunner` now retries a spawn up to three
times when it fails with `EFAULT` or `EAGAIN`, which took it to **0 failures
in 45 runs**. Retrying is safe specifically because POSIX guarantees no child
exists when `posix_spawn` reports an error, so it cannot double-spawn a
destructive command; `onlyTransientSpawnFailuresAreRetried` pins the boundary
so a real `ENOENT` or `EACCES` still fails on the first attempt.

**Signal delivery to children is not portable, and CI is the only place that
shows it.** On the `linux` job, a child does not stop on SIGINT and is ended
by the SIGKILL escalation behind it — an ignored disposition is inherited
across `exec` there, while macOS's Foundation resets child dispositions (cf.
the same divergence behind `SIGPIPEGuard`'s no-op handler). One further
Linux-only observation came out of #114 and is recorded in #149 alongside it: a
`/bin/sh -c` child's termination is not observed after SIGKILL the way a
direct `/bin/sleep` child's is. None of it is visible from a green macOS run.

**An elapsed bound is necessary and not sufficient.** Two independent reviews
of #147 built the same counterexample: delete the runner's entire kill path,
and every elapsed-bound test still passed, because the bounded give-up
satisfies the bounds on its own — leaving eight children running. A timeout
test must therefore assert *liveness* too. `deadlineEndsTheChild` does it
portably, by having the child append to a file on a loop and requiring that
file to stop growing; a pid probe would not work, since `kill(pid, 0)`
succeeds against a zombie and a child ended on Linux may not be reaped
promptly (#149). `descendantCannotExtendARunWhoseChildExited` covers the
interleaving every other test structurally cannot reach — the child exits
*before* the deadline, so no stop sequence runs, and an unbounded drain then
returns **success** a descendant's lifetime late. It is macOS-gated because
its *precondition* is unreachable on Linux, not merely its mechanism: there
a `/bin/sh -c` child's termination is not observed while a descendant lives
(#149), so the deadline fires and the run ends as a bounded `.timeout`
instead. A bound loose enough to pass on Linux would also pass with the fix
reverted, which is worse than not running the test there.

One thing the Linux runs did settle: `deadlineEndsTheChild` passes there. So
SIGKILL genuinely reaches and ends the child on Linux — it is only the
*observation* of that death that does not arrive, which narrows #149 from
"the signal may not be landing" to "the signal lands and corelibs does not
report it".

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

### RunStore fault injection (crash-durability harness)

`RunStoreFileOperations` is `RunStore`'s narrow POSIX seam — `openat`/`write`/`fsync`/`renameat`/`unlinkat`; directory fsyncs go through the same `sync` closure against descriptors RunStore opens with `O_DIRECTORY`. Production always uses `.live`; the internal `RunStore` initializer accepts a replacement, and behavior with `.live` is byte-identical to having no seam. `FaultInjectingFileOperations` (Core test support) is the programmable double on top of it:

- `crashAfter(operations:)` — every seam call past the given 1-based ordinal silently no-ops while *reporting success*: the in-process analog of dying at that step boundary (nothing later reaches the disk, and no error path runs, because a dead process has no error path). The test then "remounts" — a fresh live `RunStore` over the same directory, the dead process's recorded pid rewritten to an unreachable one where the on-disk record still claims `.running` — and asserts the recovered view is consistent.
- `failSync(atCall:errno:)` — one-shot fsync failures (`EINTR`, `EIO`, `ENOSPC`, …) at an exact fsync ordinal, counted across all descriptors.
- `tearWrite(toFileNamed:keepingBytes:)` — the first write to the named file persists only a prefix, then the process "crashes".
- an operation **trace**, each write/fsync labeled with the file name it was opened under through the seam or `.directory` (detected by `fstat`), used to assert the documented ordering contracts (write → fsync file → rename → fsync directory; pending marker before the index append it guards; marker cleared only after the projection's fsyncs) directly rather than inferring them from end states.

`RunStoreCrashDurabilityTests` runs the crash matrix: every step boundary of `begin`, `markDestructiveLaunchAuthorized`, `finish` (destructive and not), and `recoverInterrupted` itself (each matrix's largest crash point asserts the flow completed, so a flow that grows new steps fails the coverage check loudly rather than silently shrinking the matrix); torn index appends at byte offsets including mid-UTF-8-scalar; and `EINTR` injected at every fsync site of both the publication and recovery flows.

Model limits, deliberately: crashes replay at seam-call boundaries against the real filesystem — losing un-fsynced page cache is not simulated, and `FileManager` calls (mkdir/remove) are outside the seam, so a crash "between" one of those and a seam call is not representable. `ConfigStore`/`AppPaths` durability is tested separately (their own seams). Regenerable `StateStore` files promise atomic replacement; safety-authoritative `schedule-state.json` has its own narrow `StateStoreFileOperations` seam and tests injected failures at temp-file fsync, rename, and directory fsync, plus checksum tampering, stripped-envelope downgrade detection, nonblocking FIFO rejection, exact-byte quarantine, failed-quarantine fingerprint suppression with explicit-reload retry after external repair, descriptor-pinned owner permissions under a simulated fully masking umask, prospective encoded-size refusal before migration-marker publication, and a paused first-migration writer that proves readers bind marker and canonical bytes beneath the writer lock. That blocking generation test uses dedicated threads rather than Swift's shared executor so it cannot starve unrelated timeout/cancellation tests on a low-width hosted runner. A group- or world-writable `state/` red-checks the read path's directory policy, while `0700` and a legacy `0755` still read; a permission refusal red-checks that recovery guidance names the offending path and its shell-quoted `chmod`, and that it splits by subject: the canonical document and `state/` are still told to inspect and replace, because the unkeyed checksum means a forged watermark would verify, while a widened marker — writable or merely readable — is repaired alone and never sends the operator at the document. A `0333` `state/`, unreadable but world-writable, red-checks that the refusal survives the `EACCES` open that precedes the mode check, and a `0300` one red-checks that a genuinely unreadable directory keeps its I/O diagnosis instead of borrowing the mode refusal. Both are `canInjectPermissionFaults`-gated: the Linux jobs run as root, which opens either directory happily, so the `EACCES` branch would never run there — the `0333` case would even pass through the ordinary mode guard and read as covered. The unprivileged macOS job is what actually exercises them, along with a `0066` marker — owner-unreadable but group/world-exposed — which red-checks that it keeps the marker-only recovery instead of the two-file branch. `FileLock.ensureDirectory` has its own pair: `unsafeExistingGuidance` refuses the mode of the inode in hand, leaves it intact and appends the caller's guidance, while the same call without it still tightens, so the `runs/`/`locks/` behaviour cannot drift. On the `AppPaths` side a benign `0755` `state/` red-checks that it is neither refused nor repaired — repair is what would reopen the erase window — a mode that is both restrictive and exposed (`0333`, `0533`, `0133`, all keeping owner execute so the ordering rather than Darwin's `O_SEARCH` is what the assertion exercises) red-checks that the exposure diagnosis wins, since only it carries the trusted-copy warning, while a `0500` one red-checks the restrictive-mode refusal and its `chmod 700` guidance (`0600`/`0400` assert only that they refuse, since which layer catches a directory without owner search is platform-dependent), a freshly created one red-checks that it is still pinned to `0700`, and the refusal itself red-checks that it carries the trusted-copy guidance, since a scheduled tick exits there and never reaches the reader's message. macOS watcher regressions corrupt the existing schedule-state and migration-marker inodes and prove both direct vnode sources publish recovery state without an unrelated directory event. Purge tests also prove the schedule-state lock remains held at the restic launch boundary and through the watermark commit, repository identity is revalidated immediately at spawn, a watermark that already covers every configured pattern skips the rewrite and lets mirror sync and both retentions resume, and mirror copy names only the exact terminal purge generation. A peer snapshot injected after rewrite is absent from that bounded copy; the copy uses resolved full ids and deliberately earns neither a mirror sync marker nor mirror retention. A collision between a selected and an unattributed snapshot's transcript prefixes refuses before token consumption or destructive launch, proving the ambiguity check covers the complete generation rather than only rewrite operands. Manual destination watermarks still narrow one shared preview to destination-specific pattern subsets, and a lost post-success watermark is repaired by re-running the rewrite as a no-op — whose real-restic transcript the parser recognizes — rather than by inferring the watermark from run history. Replacement repositories, same-id pre-purge restores, records missing an attributed snapshot, and duplicate-prefix history each red-check that no run record suppresses that rewrite; independently changing the recorded patterns, repository id, or snapshot mapping red-checks the index evidence digest. The headless CLI suite proves `tick` rejects corrupt schedule state before its empty-set success return.

Those regressions include duplicate result-prefix history where one
colliding result was deleted and replaced by an unrelated snapshot; that
history cannot repair the watermark or suppress the required rewrite.
Directory-level symlink coverage proves schedule-state reads refuse before
following `state/`, complementing the existing canonical-file symlink test.

## Layer 2 — integration script (`scripts/integration-test.sh`)

Real restic (from PATH; CI: `brew install restic` on macOS, and the **official 0.18.1 release binary** on Linux — deliberately *not* `apt-get install restic`, because Ubuntu 24.04 ships 0.16.4, below the 0.17.0 minimum `ResticDiscovery` enforces, so any scenario that relies on discovery rather than a pinned `resticPath` fails — since issue #50 with an explicit "restic 0.16.4 … is too old", previously with a flatly misleading "restic not found"). Runs on **both platforms** (extended for Linux by T29 / issue #31 — one script, so the two platforms cannot silently drift in what they cover). Contract:
- Env: `RESTIC_STATION_DATA_DIR=<tmp>` (AppPaths override), all repos/sources under `mktemp -d`.
- Secret backend, by platform: macOS seeds real **keychain** items via `security add-generic-password … -T /usr/bin/security` with test UUIDs, `trap`-cleaned via `delete-generic-password` (CI keychain is unlocked on macos runners; create/default a temporary keychain if not). Linux — no keychain — forces `RESTIC_STATION_SECRET_BACKEND=file` and seeds via `secret set` (stdin) against the real built binary.
- Build: macOS builds via `xcodebuild`; Linux has no app to build, so CI always sets `RESTIC_STATION_HELPER_OVERRIDE` to the path of an already-built helper — in CI, T29's **static** release binary (see below), never a debug build, so this test exercises what actually ships. (Local dev escape hatch on both platforms: set the same variable yourself to skip the build step entirely.)
- Main scenario (both platforms): write config.json (1 set: tmp source dir, local primary + local secondary, everyMinutes 5, retention keep-last 2) → `helper run-set` → assert: primary snapshots length 1 AND secondary snapshots length 1 (`restic snapshots --json | jq length`), index.jsonl has backup ✓ + copy ✓, repo-status lastSyncedAt set → mutate source, run again, assert 2/2 → "unplug" secondary (`mv` the repo dir) → run → assert backup ✓, no copy record, reachable=false → "replug" → run → assert secondary catches up to 3 snapshots (add a third change) → assert `run-set --kind prune` **refuses** (manual retention apply is contained for #111/#82: nonzero exit, the posture explained, no prune record of any status, no snapshots removed) → make the set due and run `helper tick`, asserting a *scheduled* backup plus the copy and prune records, and snapshot counts dropping per keep-last 2 — the scheduled entry point rather than `run-set`, which dispatches with a manual trigger → `helper tick` with nothing due → assert no new records.
- **M5 story (`assert_fixture_flow`, both platforms)** — the Mac-authored-config-on-Linux story end to end, not just a repeat of the scenario above: `config import` of `scripts/fixtures/mac-exported-config.json` (a **checked-in** fixture — placeholder tokens `__SOURCE_DIR__`/`__PRIMARY_REPO__`/`__MIRROR_REPO__`/`__MACHINE_ID__` are `sed`-substituted per run, so the test never depends on a live Mac) → `secret set` via stdin for both destinations → a real `backup` against a local repo → the second destination as a mirror, asserting its snapshot count and its `copy` index record (`restic copy` actually ran) → `config validate`, asserting on real stdout that the enabled set says `RUNS HERE`, the fixture's Mac-only set (disabled via a `machines` override keyed on the test's `RESTIC_STATION_MACHINE_ID`) says `does not run here` / `disabled on this machine`, and — because only one of the two sets is disabled — that "nothing will run on this machine" does **not** appear → `status --json` piped through `jq`, asserting exactly one set (the disabled one must not appear) with `lastBackup.status == "success"`, and exactly one `excludedHere` entry with `reason == "disabledForMachine"`. This is the anti-silent-failure guarantee of the whole per-machine design, asserted on actual output, not inferred.
- Exit nonzero on any assertion failure; print the failing section (`fail()` dumps `runs/index.jsonl` + relevant `state/*.json` + `config.json`).

### CLI JSON contract (`scripts/cli-contract-test.sh`)

`docs/cli-json.md` is normative for automated callers, so it is executable: the contract script extracts the doc's §Command matrix and §Codes tables and reconciles them — both directions — against its own contract tables and the built helper's `--help` output *before* running a single assertion, so editing the doc without the script (or the reverse, or adding a subcommand without a matrix row) fails CI as **drift**, not as a later review finding (the motivating failure: #122 shipped an integration test still asserting the old documented behavior of a changed command). Every `live` row is then asserted against the real binary — envelope shape, `error.code`, `retryable`, exit code, refusal behavior — using a mode-file-driven fake restic so every restic exit class is reachable deterministically on hosts with no restic at all; a final reconciliation pass fails if any table row went unasserted or any assertion has no row. Codes with no shell-reachable producer are classed `unit:<why>` and pinned by the Layer-1 envelope tests instead. Runs on both platforms (file secret backend, like the other Layer-2 scripts) and ends with a secret-leak sweep over every byte the helper produced. Takes the helper path as its optional argument, like `headless-cli-test.sh`.

### Negative assertions

A "nothing happened" claim is proved with a filter-free check — a run count that must not change at all, a directory listing that must gain no entry of any kind, an index grep for records of **any** status — never with a success-only filter. A `status == "success"`-shaped filter passes even when a differently-shaped record was written, which is exactly the forbidden outcome (#122, #124 review findings). Layer-2 scripts state the convention in their headers; new assertions follow it.

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
**Scheduled retention via a due tick**: seed a disposable, policy-configured set with identifiable snapshots in excess of what that set's configured `--keep-*` policy retains, make it due, and run `tick`; verify the scheduled backup completes, a caught-up mirror is copied before it is pruned, the primary is pruned last, and the policy's surplus snapshot IDs are removed.
**Reclaim space with token confirmation**: in the app's confirmation flow, preview reclaim space for a disposable destination, then confirm with the currently displayed confirmation binding carried through `--expected-destination-stdin`; verify a stale, altered, or already-consumed binding is refused before `restic prune` runs. This does not change the documented direct human-CLI path, where omitting that selector is deliberate.
**Restore** (Layer-3 destination scope: local, external-volume, and SFTP): restore a known fixture from each of those destinations to fresh targets; compare bytes or cryptographic hashes to the source for each. Also confirm original-location restore shows its warning.

## CI (`.github/workflows/ci.yml`)

| Job | Runner | Steps |
|---|---|---|
| `linux` | `ubuntu-24.04-arm`, container `swift:6.1` | `swift build`/`swift test` (root package) → `swift test --package-path Core` → `scripts/secret-cli-test.sh` + `scripts/headless-cli-test.sh` (restic absent in this container, so their real-backup halves skip) → T25/T26 platform-conditional checks (no systemd in this container — see `linux-integration` below for the systemd VM) |
| `macos` | `macos-15` | `brew install xcodegen restic jq shellcheck` → `scripts/shell-lint.sh` (all `scripts/*.sh` through ShellCheck and the runner's Bash 3.2 parser) → `xcodegen generate` → `xcodebuild -scheme "Restic Station" build CODE_SIGNING_ALLOWED=NO` → `swift test --package-path Core` → `scripts/integration-test.sh` → `scripts/secret-cli-test.sh` + `scripts/headless-cli-test.sh` (real backup halves run here) → ad-hoc sign + upload `Restic-Station-app` artifact |
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
