# Agent guide

Canonical working guidance for coding agents — human or AI — in this repo.
`CLAUDE.md` is a one-line import of this file so Claude Code loads it
automatically; other tools should read this file directly. Edit here, never
in `CLAUDE.md`.

This file is a router plus the traps you must know *before* editing. The
normative detail lives in `CONTRIBUTING.md` and `docs/` — when this file and
those disagree, they win; fix the disagreement in the same PR.

## Read before editing

- **`CONTRIBUTING.md` is binding.** It is short and dense; read all of it.
- **`docs/` is normative.** The code implements the docs. A change that alters
  behavior updates the relevant doc in the same PR.
- **Invariants:** `docs/data-model.md` §Invariants (enforced by
  `AppConfig.validate()`), plus the invariants paragraph in `CONTRIBUTING.md`.
  Each has negative tests — keep them.

## Layout, build, test

- `Core/` (cross-platform library, all logic) · `Helper/` (root SwiftPM
  package, the `restic-station-helper` CLI, cross-platform) · `App/`
  (macOS-only). `ResticStation.xcodeproj` is **generated** — edit
  `project.yml` and run `./scripts/bootstrap.sh`, never the project file.
- Build/test: `swift build && swift test` (root = Helper),
  `swift test --package-path Core`, `./scripts/local-ci.sh` for the fuller
  sweep. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`),
  never XCTest.
- Before writing any test that touches `RESTIC_STATION_DATA_DIR` or shared
  test state, read `Helper/Tests/HelperTests/TestEnvironmentLock.swift` and
  `docs/testing.md` (including the flock-per-open-file-description caveat).

## What a green local run does NOT prove

- **Toolchain skew:** the local toolchain is newer than CI's `swift:6.1`
  Linux container. Code the local compiler accepts has been rejected by CI
  (a 6.3-vs-6.1 exhaustiveness difference shipped a red `linux` job once).
  Avoid newest-version-only syntax in `Core/` and `Helper/`.
- **Userland divergence:** macOS is BSD userland + bash 3.2; CI Linux is GNU.
  `stat -f` vs `stat -c` has shipped a bug. Shell changes need both in mind.
- **Signal semantics:** macOS resets child signal dispositions across exec;
  Linux does not. Only the Linux CI jobs can see this class of bug.
- `scripts/local-ci.sh` prints an honest classification of which CI steps it
  fully / partially / never covers — believe it. Linux runtime behavior
  (systemd timers, musl static binary, foreign userlands) is CI-only.

## Process contract

- Every change lands via a PR from a branch; never commit to `main`.
- Gate: CI green **and** an independent correctness review for behavior
  changes, anchored to the exact `(base SHA, head SHA)` pair recorded in the
  PR description (see `CONTRIBUTING.md` for anchoring and re-review rules).
  Address findings fix-forward on the same branch.
- Follow the behavior-change protocol in `CONTRIBUTING.md` (blast-radius
  sweep, red-checked assertions, self-review) before requesting review.

## Safety rules distilled from review history

These three rules account for the largest clusters of past review findings
(PRs #102–#130); they are stated normatively in `CONTRIBUTING.md`:

1. **Evidence binding.** A check that is not atomic with its use — anything
   validated on one side of a lock release, subprocess launch, or process
   boundary and consumed on the other — must bind its evidence (config
   fingerprint, binary identity, generation counter) into the token consumed
   at the point of use. Re-checking "recently" is not binding.
2. **Fail closed on destructive reads.** No `try?`, silent skip, or
   drop-on-decode-error on any read that feeds a destructive decision
   (`forget`, `prune`, `rewrite --forget`, audit gates). Unreadable or
   malformed state refuses with a reason; it never reads as "nothing there".
3. **Threat model first.** A PR that introduces or extends a safety invariant
   states its adversarial scenarios up front: two concurrent processes, a
   crash at every step boundary, legacy/markerless state from older
   versions, PID reuse, hostile scheduling. Writing this list before coding
   is cheaper than discovering it one review round at a time.

## Environment facts

- A config schema version bump affects every machine sharing a repo; hosts
  must upgrade in lockstep or backups stop on the laggard. Treat migrations
  as fleet events, not code details (`docs/data-model.md` §Versioning).
- `docs/tasks/` (T01–T20) is the historical build-out record; work after T20
  is tracked in GitHub issues, not task files. Don't infer current scope
  from the task series (`docs/tasks/README.md`).
