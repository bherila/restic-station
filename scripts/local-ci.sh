#!/usr/bin/env bash
# scripts/local-ci.sh — run, on a macOS development machine, as much of
# `.github/workflows/ci.yml` as can honestly be run there, and say plainly
# what is left over.
#
# Written during the GitHub Actions outage of 2026-08-06, when both open PRs
# sat unverifiable for hours. It is not a replacement for CI and must never
# be described as one: read §COVERAGE below before quoting a green run of
# this script as evidence for anything.
#
# Usage:
#   scripts/local-ci.sh              # everything available
#   scripts/local-ci.sh --fast       # skip the integration script (~60s) and
#                                    # the Linux cross-compile
#
# ── COVERAGE ────────────────────────────────────────────────────────────
#
# FULLY equivalent to CI (same command, same inputs):
#   - scripts/shell-lint.sh                            [macos job]
#   - `swift test` (root package)                       [linux + macos jobs]
#   - `swift test --package-path Core`                  [linux + macos jobs]
#   - `xcodebuild -scheme "Restic Station"`             [macos job]
#   - scripts/integration-test.sh                       [macos job]
#   - scripts/secret-cli-test.sh                        [macos job]
#   - scripts/headless-cli-test.sh                      [macos job]
#   - scripts/cli-contract-test.sh                      [linux + macos jobs]
#     (FULL for the doc↔table drift check and every `live` contract row —
#     the fake restic makes those platform-independent; the `env` rows it
#     skips here are the same ones CI's linux job skips, e.g. systemd
#     timer refusals, so a green local run of this script means what a
#     green CI run of it means, minus nothing.)
#
# PARTIAL — real compilation, no execution:
#   - Linux cross-compile via the Static Linux SDK. This genuinely type-checks
#     every `#if os(Linux)` path (SystemdTimerManager, TimerCommand, Status's
#     scheduler probe, SchedulerCommand's systemd half) against real
#     `os(Linux)`, and produces the same static musl binary `release-linux`
#     ships. It cannot RUN any of it.
#     Note the static SDK ships no swift-testing module, so Linux-only *test*
#     code is not type-checked here at all — only sources are.
#
#     THE TOOLCHAIN VERSIONS DIFFER FROM CI, and it has already bitten:
#     this cross-compile uses the pinned swift.org 6.3.3, while the `linux`
#     job builds in a `swift:6.1` container and macos-15's Xcode is older
#     than a current local one. A `switch` over a `Bool?` with
#     `case true/false/nil` compiles clean on 6.3 and is rejected as
#     non-exhaustive by 6.1 — it passed everything below and failed both CI
#     build steps. A green run here does not mean the oldest supported
#     toolchain accepts the code.
#
# NOT COVERED — shell portability. Every Layer-2 script runs on both
# platforms in CI but only ever the macOS branch here, so a BSD-vs-GNU
# divergence passes silently. This has also already bitten: `stat -f '%Lp'
# … || stat -c '%a' …` looks like a portable idiom and is not — on GNU
# coreutils `-f` means "file system status", so it *succeeds* on Linux and
# the fallback never runs.
#
# NOT COVERED — needs a Linux host, and nothing here substitutes for it:
#   - every runtime assertion in the `linux` job (discovery messages, timer
#     install/status behaviour, fda-check no-op, rendered units parsing)
#   - the whole `linux-integration` job: systemd --user timers actually
#     firing, lingering, the docs transcripts, the XDG/scheduler regression
#     assertions in scripts/linux-docs-transcript.sh
#   - `linux-runtime-verify` (scratch/Alpine/Debian/CentOS execution)
#   - `release-linux` packaging and checksums
#
# So: a green run here means "nothing macOS-visible is broken and the Linux
# code still compiles". It does not mean the Linux behaviour is verified.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

PASSED=(); FAILED=(); SKIPPED=()

step() {
    local name="$1"; shift
    printf '\n\033[1m━━ %s\033[0m\n' "$name"
    if "$@"; then
        PASSED+=("$name")
    else
        FAILED+=("$name")
        printf '\033[31mFAILED: %s\033[0m\n' "$name"
    fi
}

skip() {
    SKIPPED+=("$1 — $2")
    printf '\n\033[2m━━ %s (skipped: %s)\033[0m\n' "$1" "$2"
}

# ── Shell portability ───────────────────────────────────────────────────
if command -v shellcheck >/dev/null 2>&1; then
    step "shellcheck + Bash 3.2 syntax" scripts/shell-lint.sh
else
    skip "shellcheck + Bash 3.2 syntax" "shellcheck not on PATH"
fi

# ── Unit tests, both packages ───────────────────────────────────────────
# SwiftPM does not run a path dependency's tests, so Core needs its own
# invocation — the same reason ci.yml has two steps.
step "root package tests"  swift test
step "Core package tests"  swift test --package-path Core

# ── The macOS app + its bundled helper ──────────────────────────────────
if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
    step "xcodegen" xcodegen generate
    step "app builds" xcodebuild -scheme "Restic Station" build \
        CODE_SIGNING_ALLOWED=NO -derivedDataPath "$REPO_ROOT/.build/local-ci-dd"
else
    skip "app builds" "no usable Xcode on this machine"
fi

# ── Layer-2 scripts (the macos job runs all three) ──────────────────────
if [[ "$FAST" == "1" ]]; then
    skip "integration test" "--fast"
else
    if command -v restic >/dev/null 2>&1; then
        step "integration test" scripts/integration-test.sh
    else
        skip "integration test" "restic not on PATH"
    fi
fi
step "secret CLI end to end"   scripts/secret-cli-test.sh
step "headless CLI end to end" scripts/headless-cli-test.sh
step "CLI JSON contract"       scripts/cli-contract-test.sh

# ── Linux cross-compile ─────────────────────────────────────────────────
# The only way to type-check `#if os(Linux)` code on this machine without
# editing the conditionals — which is guesswork, and drifts. Needs the
# *swift.org* toolchain: an Xcode toolchain of the same version cannot read
# the SDK's precompiled Foundation.swiftmodule ("compiled module was created
# by an older version of the compiler"), which is what
# scripts/setup-static-linux-sdk.sh exists to install.
LINUX_SWIFT="$REPO_ROOT/.build/static-linux-sdk-cache/swift-6.3.3-toolchain/usr/bin/swift"
cross_compile_linux() {
    "$LINUX_SWIFT" build --swift-sdk aarch64-swift-linux-musl \
        --scratch-path "$REPO_ROOT/.build/linux-x" || return 1
    local binary="$REPO_ROOT/.build/linux-x/aarch64-swift-linux-musl/debug/restic-station-helper"
    file "$binary" | grep -q "ELF 64-bit LSB executable, ARM aarch64" || {
        echo "cross-compiled artifact is not an aarch64 ELF"
        return 1
    }
    file "$binary" | grep -q "statically linked" || {
        echo "cross-compiled artifact is not statically linked"
        return 1
    }
    echo "ok: $(file "$binary" | cut -d: -f2-)"
}
if [[ "$FAST" == "1" ]]; then
    skip "Linux cross-compile" "--fast"
elif [[ -x "$LINUX_SWIFT" ]]; then
    step "Linux cross-compile (aarch64 musl)" cross_compile_linux
else
    skip "Linux cross-compile" "run scripts/setup-static-linux-sdk.sh first"
fi

# ── Report ──────────────────────────────────────────────────────────────
printf '\n\033[1m━━ summary ━━\033[0m\n'
for s in "${PASSED[@]:-}";  do [[ -n "$s" ]] && printf '  \033[32mPASS\033[0m  %s\n' "$s"; done
for s in "${SKIPPED[@]:-}"; do [[ -n "$s" ]] && printf '  \033[2mSKIP\033[0m  %s\n' "$s"; done
for s in "${FAILED[@]:-}";  do [[ -n "$s" ]] && printf '  \033[31mFAIL\033[0m  %s\n' "$s"; done

cat <<'NOTE'

Not covered by this script, and not covered by anything else on this machine:
every Linux RUNTIME assertion — the systemd timer actually firing, lingering,
the `linux` job's discovery/timer message checks, the docs transcripts and
their regression assertions, the multi-distro static-binary verification, and
release packaging. Those need CI. A green run here is "nothing macOS-visible
is broken and the Linux code compiles", nothing more.
NOTE

[[ ${#FAILED[@]} -eq 0 ]] || exit 1
