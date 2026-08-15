#!/bin/bash
# Verify the exact macOS app bundle that would be handed to a user.
#
# Usage:
#   scripts/macos-release-verification.sh <app-path> <evidence-directory> [--exercise-user-cli]
#
# `--exercise-user-cli` is intentionally restricted to GitHub Actions. It
# installs and removes ~/.local/bin/restic-station, which is appropriate on
# an ephemeral hosted runner but should not silently alter a developer's
# workstation. All app data and FDA probe state live under a throwaway root.

set -euo pipefail

APP_PATH="${1:-}"
EVIDENCE_DIR="${2:-}"
EXERCISE_USER_CLI="${3:-}"

if [[ -z "$APP_PATH" || -z "$EVIDENCE_DIR" ]]; then
    echo "usage: $0 <app-path> <evidence-directory> [--exercise-user-cli]" >&2
    exit 2
fi
if [[ "$EXERCISE_USER_CLI" != "" && "$EXERCISE_USER_CLI" != "--exercise-user-cli" ]]; then
    echo "unknown option: $EXERCISE_USER_CLI" >&2
    exit 2
fi
if [[ "$EXERCISE_USER_CLI" == "--exercise-user-cli" && "${GITHUB_ACTIONS:-}" != "true" ]]; then
    echo "--exercise-user-cli is restricted to an ephemeral GitHub Actions runner" >&2
    exit 2
fi

HELPER="$APP_PATH/Contents/MacOS/restic-station-helper"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Restic Station"
AGENT_PLIST="$APP_PATH/Contents/Library/LaunchAgents/net.herila.ResticStation.helper.plist"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
CLI_LINK="$HOME/.local/bin/restic-station"

mkdir -p "$EVIDENCE_DIR"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/restic-station-release-verify.XXXXXX")"
CLI_WAS_CREATED=0
APP_PID=""

cleanup() {
    local code=$?
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    if [[ "$CLI_WAS_CREATED" == "1" && -x "$HELPER" ]]; then
        "$HELPER" cli uninstall --user >/dev/null 2>&1 || true
    fi
    [[ -d "$WORK" ]] && rm -rf "$WORK"
    exit "$code"
}
trap cleanup EXIT

pass() { printf 'PASS  %s\n' "$*" | tee -a "$EVIDENCE_DIR/checks.txt"; }
fail() { printf 'FAIL  %s\n' "$*" | tee -a "$EVIDENCE_DIR/checks.txt" >&2; exit 1; }
assert_equal() {
    local name="$1" expected="$2" actual="$3"
    [[ "$actual" == "$expected" ]] || fail "$name (expected '$expected', got '$actual')"
    pass "$name = $actual"
}

: > "$EVIDENCE_DIR/checks.txt"

[[ -d "$APP_PATH" ]] || fail "app bundle exists at $APP_PATH"
[[ -x "$APP_EXECUTABLE" ]] || fail "app executable is present"
[[ -x "$HELPER" ]] || fail "embedded helper is executable"
[[ -f "$AGENT_PLIST" ]] || fail "embedded LaunchAgent plist is present"
pass "release bundle layout is complete"

plutil -lint "$INFO_PLIST" "$AGENT_PLIST" | tee "$EVIDENCE_DIR/plist-lint.txt"
assert_equal "bundle version" "0.1.0" "$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
assert_equal "agent label" "net.herila.ResticStation.helper" "$(plutil -extract Label raw -o - "$AGENT_PLIST")"
assert_equal "agent BundleProgram" "Contents/MacOS/restic-station-helper" "$(plutil -extract BundleProgram raw -o - "$AGENT_PLIST")"
assert_equal "agent command" "tick" "$(plutil -extract ProgramArguments.1 raw -o - "$AGENT_PLIST")"
assert_equal "agent interval" "120" "$(plutil -extract StartInterval raw -o - "$AGENT_PLIST")"

codesign --verify --deep --strict --verbose=4 "$APP_PATH" 2>&1 | tee "$EVIDENCE_DIR/codesign-verify.txt"
codesign -d --verbose=4 "$APP_PATH" > "$EVIDENCE_DIR/app-codesign.txt" 2>&1
codesign -d --verbose=4 "$HELPER" > "$EVIDENCE_DIR/helper-codesign-direct.txt" 2>&1
pass "app and nested helper pass strict code-signature verification"

"$HELPER" version | tee "$EVIDENCE_DIR/helper-version.txt"
grep -q '^restic-station-helper 0\.1\.0$' "$EVIDENCE_DIR/helper-version.txt" \
    || fail "embedded helper reports version 0.1.0"
pass "embedded helper reports version 0.1.0"

# Launch the shipped executable against isolated data and require it to stay
# alive long enough to prove the SwiftUI app did not crash during startup.
mkdir -p "$WORK/app-data"
RESTIC_STATION_DATA_DIR="$WORK/app-data" "$APP_EXECUTABLE" \
    > "$EVIDENCE_DIR/app-launch.log" 2>&1 &
APP_PID=$!
sleep 8
kill -0 "$APP_PID" 2>/dev/null || fail "app survives an 8-second launch smoke test"
pass "app survives an 8-second launch smoke test"
kill -TERM "$APP_PID"
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

# The FDA result itself is informational on a hosted runner: nobody has
# granted that ephemeral VM Full Disk Access. What is verifiable is that the
# exact helper probes and records its process context without touching user
# data from the repository checkout.
mkdir -p "$WORK/fda-direct"
RESTIC_STATION_DATA_DIR="$WORK/fda-direct" \
    "$HELPER" fda-check --context github-actions-direct \
    | tee "$EVIDENCE_DIR/fda-direct.txt"
jq -e '.context == "github-actions-direct" and (.hasFullDiskAccess | type == "boolean")' \
    "$WORK/fda-direct/state/fda-check.json" > /dev/null
cp "$WORK/fda-direct/state/fda-check.json" "$EVIDENCE_DIR/fda-direct.json"
pass "direct helper FDA probe records honest, isolated process-context evidence"

if [[ "$EXERCISE_USER_CLI" == "--exercise-user-cli" ]]; then
    [[ ! -e "$CLI_LINK" && ! -L "$CLI_LINK" ]] \
        || fail "ephemeral runner unexpectedly already has $CLI_LINK"

    "$HELPER" cli install --user 2>&1 | tee "$EVIDENCE_DIR/cli-install.txt"
    CLI_WAS_CREATED=1
    [[ -L "$CLI_LINK" ]] || fail "cli install created a symlink"
    assert_equal "CLI symlink target" "$HELPER" "$(readlink "$CLI_LINK")"

    PATH="$HOME/.local/bin:$PATH" "$CLI_LINK" cli status --user \
        2>&1 | tee "$EVIDENCE_DIR/cli-status.txt"
    grep -q '^installed: ' "$EVIDENCE_DIR/cli-status.txt" \
        || fail "CLI status reports the installed symlink"
    if grep -q 'stale' "$EVIDENCE_DIR/cli-status.txt"; then
        fail "CLI status reports a stale symlink"
    fi
    pass "CLI symlink is installed, current, and runnable from PATH"

    "$CLI_LINK" version | tee "$EVIDENCE_DIR/helper-version-via-symlink.txt"
    cmp "$EVIDENCE_DIR/helper-version.txt" "$EVIDENCE_DIR/helper-version-via-symlink.txt" \
        || fail "direct and symlink helper versions differ"
    codesign -d --verbose=4 "$CLI_LINK" > "$EVIDENCE_DIR/helper-codesign-via-symlink.txt" 2>&1
    direct_id="$(sed -n 's/^Identifier=//p' "$EVIDENCE_DIR/helper-codesign-direct.txt")"
    symlink_id="$(sed -n 's/^Identifier=//p' "$EVIDENCE_DIR/helper-codesign-via-symlink.txt")"
    [[ -n "$direct_id" ]] || fail "direct helper has no signing identifier"
    assert_equal "direct/symlink signing identifier" "$direct_id" "$symlink_id"

    mkdir -p "$WORK/fda-symlink"
    RESTIC_STATION_DATA_DIR="$WORK/fda-symlink" \
        "$CLI_LINK" fda-check --context github-actions-symlink \
        | tee "$EVIDENCE_DIR/fda-symlink.txt"
    jq -e '.context == "github-actions-symlink" and (.hasFullDiskAccess | type == "boolean")' \
        "$WORK/fda-symlink/state/fda-check.json" > /dev/null
    cp "$WORK/fda-symlink/state/fda-check.json" "$EVIDENCE_DIR/fda-symlink.json"
    direct_fda="$(jq -r '.hasFullDiskAccess' "$EVIDENCE_DIR/fda-direct.json")"
    symlink_fda="$(jq -r '.hasFullDiskAccess' "$EVIDENCE_DIR/fda-symlink.json")"
    assert_equal "direct/symlink FDA outcome on the same runner" "$direct_fda" "$symlink_fda"
fi

pass "bundle-level macOS release verification complete"
