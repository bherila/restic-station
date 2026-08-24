#!/usr/bin/env bash
# Deliberately NOT `#!/bin/bash -euo pipefail`, which this script used until
# it first ran on Linux. Darwin splits a shebang's argument string on
# whitespace, so bash there receives `-e -u -o pipefail` and it works; the
# Linux kernel passes the whole remainder as a *single* argument, so bash
# gets one `-euo pipefail` token, consumes the script path as `-o`'s option
# name, and dies with "invalid option name" — at the shebang, before a line
# of this script runs. The `set -euo pipefail` below is the portable way to
# get the same flags, and is now the only thing setting them.
# scripts/integration-test.sh — Layer 2 integration test (docs/testing.md
# §Layer 2, docs/tasks/T19-integration-test.md): builds the real app/helper
# (macOS) or uses an already-built one (Linux — see the override below),
# seeds a real secret (login keychain on macOS, FileSecretStore on Linux),
# and drives `restic-station-helper` against real local restic repositories
# end to end.
#
# Runs on both macOS and Linux (T29 / issue #31 extended this from a
# macOS-only script — see `assert_fixture_flow` for the Linux/M5-specific
# half: importing a config exported from macOS, `secret set` via stdin,
# backup + mirror via `restic copy`, `config validate` correctly excluding a
# set disabled for this machine, and `status --json`).
#
# Local dev escape hatch: on macOS, this machine may have no Xcode.app, in
# which case `xcodebuild` cannot run. On Linux there is no app to build at
# all. Either way, set RESTIC_STATION_HELPER_OVERRIDE to the path of an
# already-built helper binary (e.g. from a throwaway SwiftPM harness, or —
# per issue #31 — the packaged **static** release binary, so this test
# exercises what actually ships rather than a debug build) to skip the
# xcodebuild step entirely. macOS CI never sets this — it always builds the
# real app bundle. Linux CI always sets it, to the static binary.
set -euo pipefail

# ── Fixed test identifiers ──────────────────────────────────────────────
# Fixed (not randomly generated) so failures are reproducible and the
# keychain items this script creates/deletes are always identifiable.
SET_ID="00000000-0000-4000-8000-000000000AAA"
PRIMARY_DEST_ID="00000000-0000-4000-8000-0000000000AA"
SECONDARY_DEST_ID="00000000-0000-4000-8000-0000000000BB"
KEYCHAIN_SERVICE="restic-station"
TEST_PASSWORD="restic-station-integration-test-password"

PRIMARY_DEST_ID_LOWER="$(printf '%s' "$PRIMARY_DEST_ID" | tr '[:upper:]' '[:lower:]')"
SECONDARY_DEST_ID_LOWER="$(printf '%s' "$SECONDARY_DEST_ID" | tr '[:upper:]' '[:lower:]')"

# `uname -s` — "Darwin" or "Linux". Selects the secret backend (keychain vs
# FileSecretStore) for both scenario blocks below: the first (runs 1-4 +
# migration + retention + lock-busy) uses whichever is native to the host it
# runs on (macOS CI: keychain; Linux CI: file, since there is no keychain);
# the M5 fixture-import scenario (§Fixture) always forces the file backend
# regardless of host, matching `scripts/headless-cli-test.sh`'s convention of
# exercising the Linux-default secret path on every platform.
OS_NAME="$(uname -s)"

# ── M5 story: import a config exported from macOS (checked-in fixture) ──
# (docs/tasks/T29 / issue #31 "Linux integration test"). Own IDs, own repos,
# own data directory — kept entirely separate from the SET_ID/PRIMARY_DEST_ID
# scenario above so the two cannot interfere with each other's state or
# machine identity.
FIXTURE_MACHINE_ID="ci-fixture-host"
# Uppercase (matching SET_ID/PRIMARY_DEST_ID's own convention above): Swift's
# `UUID.uuidString` always serializes canonical-uppercase, and idx_select /
# idx_count below do an exact string match against runs/index.jsonl's
# `setId`/`destId` fields — a lowercase constant here would silently never
# match a single record. UUID parsing itself is case-insensitive (these
# still refer to the same ids the lowercase JSON fixture below declares).
FIXTURE_SET_ID="F1000000-0000-4000-8000-000000000001"
FIXTURE_PRIMARY_ID="F1000000-0000-4000-8000-000000000002"
FIXTURE_MIRROR_ID="F1000000-0000-4000-8000-000000000003"
FIXTURE_DISABLED_SET_ID="F1000000-0000-4000-8000-000000000004"
FIXTURE_PASSWORD="fixture-import-integration-test-password"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_FILE="$SCRIPT_DIR/fixtures/mac-exported-config.json"

SECONDS=0

# ── Globals populated as the script runs (referenced by cleanup()) ─────
WORK=""
DATA_DIR=""
INDEX_FILE=""
HELPER=""
LOCK_HOLDER_PID=""
TEMP_KEYCHAIN=""
ORIGINAL_DEFAULT_KEYCHAIN=""
ORIGINAL_KEYCHAINS=()
HAVE_JQ=0

# =========================================================================
# Cleanup (trap): workspace + keychain items + temp keychain + stray procs.
# =========================================================================
cleanup() {
    local exit_code=$?
    set +e

    if [[ -n "$LOCK_HOLDER_PID" ]]; then
        kill "$LOCK_HOLDER_PID" >/dev/null 2>&1
        wait "$LOCK_HOLDER_PID" 2>/dev/null
    fi
    if [[ -n "$HELPER" ]]; then
        pkill -f "$HELPER" >/dev/null 2>&1
    fi

    if [[ "$OS_NAME" == "Darwin" ]]; then
    /usr/bin/security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$PRIMARY_DEST_ID_LOWER" >/dev/null 2>&1
    /usr/bin/security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$SECONDARY_DEST_ID_LOWER" >/dev/null 2>&1
    fi

    if [[ -n "$TEMP_KEYCHAIN" ]]; then
        if [[ ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]]; then
            security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1
        fi
        if [[ -n "$ORIGINAL_DEFAULT_KEYCHAIN" ]]; then
            security default-keychain -d user -s "$ORIGINAL_DEFAULT_KEYCHAIN" >/dev/null 2>&1
        fi
        security delete-keychain "$TEMP_KEYCHAIN" >/dev/null 2>&1
    fi

    if [[ -n "$WORK" && -d "$WORK" ]]; then
        rm -rf "$WORK"
    fi

    exit "$exit_code"
}
# RESTIC_STATION_IT_NO_CLEANUP=1: local debugging escape hatch that skips
# the workspace teardown below, so $WORK (printed by setup_workspace's log
# line) survives a failure for inspection. Never set in CI.
[[ -n "${RESTIC_STATION_IT_NO_CLEANUP:-}" ]] || trap cleanup EXIT

log() { printf '\n=== %s ===\n' "$*"; }

# Dumps index.jsonl + the state files an assertion is most likely to need,
# then exits 1. Every assertion function calls this on failure.
fail() {
    local step="$1"
    shift
    {
        echo
        echo "==============================================================="
        echo "ASSERTION FAILED at step: $step"
        echo "Reason: $*"
        echo "==============================================================="
        echo "--- runs/index.jsonl ---"
        if [[ -f "$INDEX_FILE" ]]; then cat "$INDEX_FILE"; else echo "(missing)"; fi
        echo "--- state/repo-status-${PRIMARY_DEST_ID}.json ---"
        cat "$DATA_DIR/state/repo-status-${PRIMARY_DEST_ID}.json" 2>/dev/null || echo "(missing)"
        echo "--- state/repo-status-${SECONDARY_DEST_ID}.json ---"
        cat "$DATA_DIR/state/repo-status-${SECONDARY_DEST_ID}.json" 2>/dev/null || echo "(missing)"
        echo "--- state/schedule-state.json ---"
        cat "$DATA_DIR/state/schedule-state.json" 2>/dev/null || echo "(missing)"
        echo "--- config.json ---"
        cat "$DATA_DIR/config.json" 2>/dev/null || echo "(missing)"
        echo "==============================================================="
    } >&2
    exit 1
}

# =========================================================================
# JSON helpers: jq if available, else a python3 fallback for the exact
# query shapes this script needs (jq preferred; CI installs it via brew).
# =========================================================================

jlen() { # stdin: a JSON array -> its length
    if [[ $HAVE_JQ -eq 1 ]]; then
        jq 'length'
    else
        python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'
    fi
}

json_field() { # json_field <file> <field> -> raw value, "" if missing/null
    local file="$1" field="$2"
    [[ -f "$file" ]] || { echo ""; return 0; }
    if [[ $HAVE_JQ -eq 1 ]]; then
        # NOT `.[$f] // empty` — jq's `//` treats JSON `false` (and 0, "") as
        # falsy too, which would silently swallow `"reachable": false`.
        jq -r --arg f "$field" 'if .[$f] == null then "" else .[$f] end' "$file"
    else
        python3 -c "
import json, sys
try:
    with open('$file') as fh:
        d = json.load(fh)
except Exception:
    d = {}
v = d.get('$field')
print('' if v is None else v)
"
    fi
}

field_of() { # field_of <json-line> <field> -> raw value, "" if missing/null
    local line="$1" field="$2"
    [[ -n "$line" ]] || { echo ""; return 0; }
    if [[ $HAVE_JQ -eq 1 ]]; then
        # See json_field's comment above re: `//` and JSON `false`.
        printf '%s' "$line" | jq -r --arg f "$field" 'if .[$f] == null then "" else .[$f] end'
    else
        printf '%s' "$line" | python3 -c "
import json, sys
d = json.load(sys.stdin)
v = d.get('$field')
print('' if v is None else v)
"
    fi
}

# idx_select KIND STATUS SETID DESTID GROUPID
# Prints matching runs/index.jsonl lines (compact JSON, one per line, file
# order — oldest first). STATUS/DESTID/GROUPID may be "" for "any".
idx_select() {
    local kind="$1" status="$2" setId="$3" destId="$4" groupId="$5"
    [[ -f "$INDEX_FILE" ]] || return 0
    if [[ $HAVE_JQ -eq 1 ]]; then
        jq -c \
            --arg k "$kind" --arg st "$status" --arg s "$setId" --arg d "$destId" --arg g "$groupId" '
            select(.kind == $k and .setId == $s)
            | select($st == "" or .status == $st)
            | select($d == "" or .destId == $d)
            | select($g == "" or .groupId == $g)
        ' "$INDEX_FILE" 2>/dev/null || true
    else
        python3 - "$INDEX_FILE" "$kind" "$status" "$setId" "$destId" "$groupId" <<'PY'
import json, sys
path, kind, status, setId, destId, groupId = sys.argv[1:7]
try:
    with open(path) as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []
for line in lines:
    line = line.strip()
    if not line:
        continue
    rec = json.loads(line)
    if rec.get("kind") != kind or rec.get("setId") != setId:
        continue
    if status and rec.get("status") != status:
        continue
    if destId and rec.get("destId") != destId:
        continue
    if groupId and rec.get("groupId") != groupId:
        continue
    print(json.dumps(rec))
PY
    fi
}

idx_count() { # same args as idx_select -> match count
    idx_select "$@" | grep -c . || true
}

# =========================================================================
# Preflight
# =========================================================================

preflight_restic() {
    if command -v restic >/dev/null 2>&1; then
        return 0
    fi
    if [[ -z "${CI:-}" ]]; then
        echo "restic not found on PATH — skipping integration test (not running in CI)."
        exit 0
    fi
    echo "FATAL: restic not found on PATH in CI." >&2
    exit 1
}

preflight_jq() {
    if command -v jq >/dev/null 2>&1; then
        HAVE_JQ=1
        return 0
    fi
    if command -v brew >/dev/null 2>&1; then
        log "jq not found — installing via Homebrew"
        brew install jq >/dev/null 2>&1 || true
    fi
    if command -v jq >/dev/null 2>&1; then
        HAVE_JQ=1
    else
        HAVE_JQ=0
        echo "jq not available — falling back to python3 for JSON queries."
    fi
}

# =========================================================================
# Workspace + keychain setup
# =========================================================================

setup_workspace() {
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/restic-station-it.XXXXXX")"
    DATA_DIR="$WORK/data"
    INDEX_FILE="$DATA_DIR/runs/index.jsonl"
    SOURCE_DIR="$WORK/source"
    PRIMARY_REPO="$WORK/repo-primary"
    SECONDARY_REPO="$WORK/repo-secondary"
    SECONDARY_REPO_PARKED="$WORK/repo-secondary.unplugged"

    mkdir -p "$DATA_DIR" "$SOURCE_DIR/subdir"
    echo "file one"   > "$SOURCE_DIR/a.txt"
    echo "file two"   > "$SOURCE_DIR/b.txt"
    echo "file three" > "$SOURCE_DIR/subdir/c.txt"

    export RESTIC_STATION_DATA_DIR="$DATA_DIR"
    log "Workspace: $WORK"
}

mutate_source() {
    echo "mutation at $(date -u +%Y%m%dT%H%M%SZ) ($RANDOM)" >> "$SOURCE_DIR/a.txt"
}

# On CI the login keychain is normally unlocked already (macos-15 runners);
# if the default keychain is unavailable/locked, fall back to a temporary
# keychain, made default + first in the search list for the run, restored
# in cleanup().
setup_keychain_access() {
    if security show-keychain-info >/dev/null 2>&1; then
        log "Default keychain is accessible — using it directly."
        return 0
    fi

    log "Default keychain unavailable/locked — creating a temporary test keychain."
    ORIGINAL_DEFAULT_KEYCHAIN="$(security default-keychain -d user 2>/dev/null | tr -d ' \t' | sed -e 's/^"//' -e 's/"$//')"

    ORIGINAL_KEYCHAINS=()
    while IFS= read -r line; do
        local clean
        clean="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
        [[ -n "$clean" ]] && ORIGINAL_KEYCHAINS+=("$clean")
    done < <(security list-keychains -d user)

    TEMP_KEYCHAIN="$WORK/integration-test.keychain-db"
    security create-keychain -p "" "$TEMP_KEYCHAIN"
    security set-keychain-settings "$TEMP_KEYCHAIN"
    security unlock-keychain -p "" "$TEMP_KEYCHAIN"
    security list-keychains -d user -s "$TEMP_KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
    security default-keychain -d user -s "$TEMP_KEYCHAIN"
}

seed_keychain() {
    log "Seeding keychain items for the two test destinations"
    local acct
    for acct in "$PRIMARY_DEST_ID_LOWER" "$SECONDARY_DEST_ID_LOWER"; do
        # Delete-first for idempotency (docs/keychain-and-fda.md §1): a
        # leftover item from a previous crashed run must not carry stale
        # ACLs or a different password.
        /usr/bin/security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$acct" >/dev/null 2>&1 || true
        /usr/bin/security add-generic-password \
            -s "$KEYCHAIN_SERVICE" -a "$acct" -w "$TEST_PASSWORD" -T /usr/bin/security
    done
}

# Seeds the two test destinations' passwords via FileSecretStore, through
# `secret set` reading a pipe — never argv (T23's own rule, asserted again
# here against the real built binary). Requires $HELPER to already be built.
seed_file_secrets() {
    log "Seeding FileSecretStore passwords for the two test destinations (secret set, via stdin)"
    printf '%s' "$TEST_PASSWORD" | "$HELPER" secret set --dest "$PRIMARY_DEST_ID"
    printf '%s' "$TEST_PASSWORD" | "$HELPER" secret set --dest "$SECONDARY_DEST_ID"
}

# Picks the secret backend for the runs-1-4 scenario: keychain on macOS
# (the platform it actually ships on), FileSecretStore on Linux (there is no
# keychain). Must run AFTER build_helper AND after write_config — the Linux
# path needs $HELPER to seed via `secret set`, which in turn refuses a --dest
# that is not already a configured destination.
setup_secret_backend() {
    if [[ "$OS_NAME" == "Darwin" ]]; then
        setup_keychain_access
        seed_keychain
    else
        export RESTIC_STATION_SECRET_BACKEND=file
        seed_file_secrets
    fi
}

# The exact `RESTIC_PASSWORD_COMMAND` restic authenticates with for a given
# lowercased destination id, matching whichever backend `setup_secret_backend`
# chose. Quoting rule (needed because $HELPER can contain a space, e.g. the
# app bundle's "Restic Station.app"): double-quote only when the path has a
# character outside [A-Za-z0-9/._+=:,@-] — same rule
# `scripts/secret-cli-test.sh` step 7 documents and applies.
password_command_for() { # password_command_for <lowercased-dest-id>
    local dest_lower="$1"
    if [[ "$OS_NAME" == "Darwin" ]]; then
        echo "/usr/bin/security find-generic-password -s $KEYCHAIN_SERVICE -a $dest_lower -w"
    elif [[ "$HELPER" =~ ^[A-Za-z0-9/._+=:,@-]+$ ]]; then
        echo "$HELPER print-password --dest $dest_lower"
    else
        echo "\"$HELPER\" print-password --dest $dest_lower"
    fi
}

# =========================================================================
# Build
# =========================================================================

build_helper() {
    if [[ -n "${RESTIC_STATION_HELPER_OVERRIDE:-}" ]]; then
        HELPER="$RESTIC_STATION_HELPER_OVERRIDE"
        log "Using RESTIC_STATION_HELPER_OVERRIDE: $HELPER"
        [[ -x "$HELPER" ]] || { echo "FATAL: override helper is not executable: $HELPER" >&2; exit 1; }
        return 0
    fi

    if [[ "$OS_NAME" == "Linux" ]]; then
        # There is no app bundle on Linux — plain SwiftPM. CI always sets
        # RESTIC_STATION_HELPER_OVERRIDE to the packaged **static** release
        # binary instead (issue #31: test what ships, not a debug build);
        # this path is the local-dev fallback for running this script
        # directly on a Linux box.
        log "Building via swift build (Linux, no override given)"
        (cd "$REPO_ROOT" && swift build --product restic-station-helper)
        HELPER="$REPO_ROOT/.build/debug/restic-station-helper"
        [[ -x "$HELPER" ]] || { echo "FATAL: helper not found at $HELPER after build." >&2; exit 1; }
        return 0
    fi

    if [[ ! -d "$REPO_ROOT/ResticStation.xcodeproj" ]]; then
        command -v xcodegen >/dev/null 2>&1 || { echo "FATAL: xcodegen not found and no project present." >&2; exit 1; }
        log "Generating Xcode project (xcodegen generate)"
        (cd "$REPO_ROOT" && xcodegen generate)
    fi

    command -v xcodebuild >/dev/null 2>&1 || { echo "FATAL: xcodebuild not found." >&2; exit 1; }
    log "Building via xcodebuild -derivedDataPath \"$WORK/dd\""
    (cd "$REPO_ROOT" && xcodebuild -scheme "Restic Station" build CODE_SIGNING_ALLOWED=NO -derivedDataPath "$WORK/dd")

    local app="$WORK/dd/Build/Products/Debug/Restic Station.app"
    HELPER="$app/Contents/MacOS/restic-station-helper"
    [[ -x "$HELPER" ]] || { echo "FATAL: helper not found at $HELPER after build." >&2; exit 1; }
}

# =========================================================================
# Config
# =========================================================================

# write_config <retention-json-or-null>
#
# Deliberately written at schema **version 1**, with `resticPath` in
# config.json: every helper invocation below therefore runs the real v1 → v3
# migration (docs/data-model.md §Versioning & migration) against a real
# restic, which `assert_migration` checks once up front. Rewriting the file
# at v1 again between scenarios is fine — migration is idempotent and never
# overwrites the backup it already took.
write_config() {
    local retention_json="$1"
    local restic_bin
    restic_bin="$(command -v restic)"
    cat > "$DATA_DIR/config.json" <<EOF
{
  "version": 1,
  "resticPath": "$restic_bin",
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$SET_ID",
      "name": "Integration Test Set",
      "sources": ["$SOURCE_DIR"],
      "excludes": [],
      "schedule": {"kind": "everyMinutes", "minutes": 5},
      "retention": $retention_json,
      "checkPolicy": null,
      "stalenessWarningDays": 14,
      "destinations": [
        {
          "id": "$PRIMARY_DEST_ID",
          "label": "Primary",
          "repoURL": "$PRIMARY_REPO",
          "isPrimary": true,
          "nonSecretEnv": {}
        },
        {
          "id": "$SECONDARY_DEST_ID",
          "label": "Secondary",
          "repoURL": "$SECONDARY_REPO",
          "isPrimary": false,
          "nonSecretEnv": {}
        }
      ]
    }
  ]
}
EOF
}

# =========================================================================
# Direct restic helpers (primary init + read-only snapshot checks; the
# helper CLI owns every other restic invocation)
# =========================================================================

restic_primary() {
    RESTIC_PASSWORD_COMMAND="$(password_command_for "$PRIMARY_DEST_ID_LOWER")" \
        restic -r "$PRIMARY_REPO" "$@"
}

restic_secondary_at() { # restic_secondary_at <repo-path> <args...>
    local repo="$1"
    shift
    RESTIC_PASSWORD_COMMAND="$(password_command_for "$SECONDARY_DEST_ID_LOWER")" \
        restic -r "$repo" "$@"
}

primary_snapshot_count() { restic_primary snapshots --json | jlen; }
secondary_snapshot_count_at() { restic_secondary_at "$1" snapshots --json | jlen; }

init_primary() {
    log "Initializing the primary repository directly via restic (proves the $([[ "$OS_NAME" == "Darwin" ]] && echo keychain || echo FileSecretStore) path)"
    restic_primary init --json >/dev/null
}

init_secondary() {
    log "Initializing the secondary repository via helper init-secondary"
    local out rc
    set +e
    out="$("$HELPER" init-secondary --set "$SET_ID" --dest "$SECONDARY_DEST_ID" 2>&1)"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "init-secondary" "exit $rc: $out"
}

# =========================================================================
# Helper invocation
# =========================================================================

run_backup() { # sets BACKUP_OUT / BACKUP_RC
    set +e
    BACKUP_OUT="$("$HELPER" run-set --set "$SET_ID" --kind backup 2>&1)"
    BACKUP_RC=$?
    set -e
}

# =========================================================================
# Assertions — one function per Layer-2 step, each with its own clear
# failure message (testing.md §Layer 2 / T19 acceptance criteria).
# =========================================================================

assert_run1() {
    local step="run1 (first backup)"
    log "$step"
    run_backup
    [[ $BACKUP_RC -eq 0 ]] || fail "$step" "run-set exited $BACKUP_RC: $BACKUP_OUT"

    local pcount scount
    pcount="$(primary_snapshot_count)"
    scount="$(secondary_snapshot_count_at "$SECONDARY_REPO")"
    [[ "$pcount" -eq 1 ]] || fail "$step" "expected 1 primary snapshot, got $pcount"
    [[ "$scount" -eq 1 ]] || fail "$step" "expected 1 secondary snapshot, got $scount"

    local backup_line group_id copy_line
    backup_line="$(idx_select backup success "$SET_ID" "$PRIMARY_DEST_ID" "" | tail -n1)"
    [[ -n "$backup_line" ]] || fail "$step" "no successful backup index record found"
    group_id="$(field_of "$backup_line" groupId)"
    [[ -n "$group_id" ]] || fail "$step" "backup record has no groupId"

    copy_line="$(idx_select copy success "$SET_ID" "$SECONDARY_DEST_ID" "$group_id" | tail -n1)"
    [[ -n "$copy_line" ]] || fail "$step" "no successful copy record sharing groupId $group_id"

    local primary_synced secondary_synced
    primary_synced="$(json_field "$DATA_DIR/state/repo-status-${PRIMARY_DEST_ID}.json" lastSyncedAt)"
    secondary_synced="$(json_field "$DATA_DIR/state/repo-status-${SECONDARY_DEST_ID}.json" lastSyncedAt)"
    [[ -n "$primary_synced" ]] || fail "$step" "primary repo-status lastSyncedAt not set"
    [[ -n "$secondary_synced" ]] || fail "$step" "secondary repo-status lastSyncedAt not set"

    RUN1_GROUP_ID="$group_id"
    log "$step OK (groupId=$group_id)"
}

assert_run2() {
    local step="run2 (mutate source, run again)"
    log "$step"
    mutate_source
    run_backup
    [[ $BACKUP_RC -eq 0 ]] || fail "$step" "run-set exited $BACKUP_RC: $BACKUP_OUT"

    local pcount scount
    pcount="$(primary_snapshot_count)"
    scount="$(secondary_snapshot_count_at "$SECONDARY_REPO")"
    [[ "$pcount" -eq 2 ]] || fail "$step" "expected 2 primary snapshots, got $pcount"
    [[ "$scount" -eq 2 ]] || fail "$step" "expected 2 secondary snapshots, got $scount"

    local backup_line group_id copy_line
    backup_line="$(idx_select backup success "$SET_ID" "$PRIMARY_DEST_ID" "" | tail -n1)"
    group_id="$(field_of "$backup_line" groupId)"
    [[ -n "$group_id" && "$group_id" != "$RUN1_GROUP_ID" ]] || fail "$step" "expected a new groupId, got '$group_id' (run1 was '$RUN1_GROUP_ID')"
    copy_line="$(idx_select copy success "$SET_ID" "$SECONDARY_DEST_ID" "$group_id" | tail -n1)"
    [[ -n "$copy_line" ]] || fail "$step" "no successful copy record sharing groupId $group_id"

    RUN2_GROUP_ID="$group_id"
    SECONDARY_SYNCED_AFTER_RUN2="$(json_field "$DATA_DIR/state/repo-status-${SECONDARY_DEST_ID}.json" lastSyncedAt)"
    log "$step OK (groupId=$group_id)"
}

assert_run3() {
    local step="run3 (unplug secondary)"
    log "$step"
    mv "$SECONDARY_REPO" "$SECONDARY_REPO_PARKED"
    run_backup
    [[ $BACKUP_RC -eq 0 ]] || fail "$step" "run-set exited $BACKUP_RC: $BACKUP_OUT"

    local pcount scount
    pcount="$(primary_snapshot_count)"
    scount="$(secondary_snapshot_count_at "$SECONDARY_REPO_PARKED")"
    [[ "$pcount" -eq 3 ]] || fail "$step" "expected 3 primary snapshots, got $pcount"
    [[ "$scount" -eq 2 ]] || fail "$step" "expected secondary to stay at 2 snapshots (offline), got $scount"

    local backup_line group_id copy_count
    backup_line="$(idx_select backup success "$SET_ID" "$PRIMARY_DEST_ID" "" | tail -n1)"
    group_id="$(field_of "$backup_line" groupId)"
    [[ -n "$group_id" && "$group_id" != "$RUN2_GROUP_ID" ]] || fail "$step" "expected a new groupId, got '$group_id'"

    copy_count="$(idx_count copy "" "$SET_ID" "$SECONDARY_DEST_ID" "$group_id")"
    [[ "$copy_count" -eq 0 ]] || fail "$step" "expected no copy record for the offline secondary, found $copy_count"

    local reachable secondary_synced
    reachable="$(json_field "$DATA_DIR/state/repo-status-${SECONDARY_DEST_ID}.json" reachable)"
    [[ "$reachable" == "false" ]] || fail "$step" "expected secondary reachable:false, got '$reachable'"
    secondary_synced="$(json_field "$DATA_DIR/state/repo-status-${SECONDARY_DEST_ID}.json" lastSyncedAt)"
    [[ "$secondary_synced" == "$SECONDARY_SYNCED_AFTER_RUN2" ]] \
        || fail "$step" "secondary lastSyncedAt changed while offline (was '$SECONDARY_SYNCED_AFTER_RUN2', now '$secondary_synced')"

    RUN3_GROUP_ID="$group_id"
    log "$step OK (groupId=$group_id, secondary correctly offline)"
}

assert_run4() {
    local step="run4 (replug secondary, catch up)"
    log "$step"
    mv "$SECONDARY_REPO_PARKED" "$SECONDARY_REPO"
    mutate_source
    run_backup
    [[ $BACKUP_RC -eq 0 ]] || fail "$step" "run-set exited $BACKUP_RC: $BACKUP_OUT"

    local pcount scount
    pcount="$(primary_snapshot_count)"
    scount="$(secondary_snapshot_count_at "$SECONDARY_REPO")"
    [[ "$pcount" -eq 4 ]] || fail "$step" "expected 4 primary snapshots, got $pcount"
    [[ "$scount" -eq 4 ]] || fail "$step" "expected secondary to catch up to 4 snapshots, got $scount"

    local backup_line group_id copy_line
    backup_line="$(idx_select backup success "$SET_ID" "$PRIMARY_DEST_ID" "" | tail -n1)"
    group_id="$(field_of "$backup_line" groupId)"
    [[ -n "$group_id" && "$group_id" != "$RUN3_GROUP_ID" ]] || fail "$step" "expected a new groupId, got '$group_id'"
    copy_line="$(idx_select copy success "$SET_ID" "$SECONDARY_DEST_ID" "$group_id" | tail -n1)"
    [[ -n "$copy_line" ]] || fail "$step" "no successful copy record for the catch-up run"

    log "$step OK (groupId=$group_id)"
}

# T24: end-to-end proof that a real v1 config, loaded by the real helper,
# migrates non-destructively and keeps backing up exactly what it did before.
# Runs after the first backup, so migration has definitely happened.
assert_migration() {
    local step="migration (v1 -> v3, resticPath relocated, v1 backed up)"
    log "$step"

    local version restic_in_config machine_id machine_restic
    version="$(jq -r '.version' "$DATA_DIR/config.json")"
    restic_in_config="$(jq -r '.resticPath' "$DATA_DIR/config.json")"
    [[ "$version" == "3" ]] || fail "$step" "expected config.json at version 3, got '$version'"
    [[ "$restic_in_config" == "null" ]] || fail "$step" "expected resticPath cleared, got '$restic_in_config'"

    # No `machines` keys invented: absence already means "runs everywhere".
    local machines_count
    machines_count="$(jq '[.sets[] | select(has("machines"))] | length' "$DATA_DIR/config.json")"
    [[ "$machines_count" -eq 0 ]] || fail "$step" "migration invented $machines_count machines keys"

    [[ -f "$DATA_DIR/machine.json" ]] || fail "$step" "machine.json was not created"
    machine_id="$(jq -r '.machineId' "$DATA_DIR/machine.json")"
    machine_restic="$(jq -r '.resticPath' "$DATA_DIR/machine.json")"
    [[ "$machine_id" =~ ^[a-z0-9-]+$ ]] || fail "$step" "invalid generated machineId '$machine_id'"
    [[ "$machine_restic" == "$(command -v restic)" ]] \
        || fail "$step" "expected machine.json resticPath '$(command -v restic)', got '$machine_restic'"

    [[ -f "$DATA_DIR/config.v1.backup.json" ]] || fail "$step" "config.v1.backup.json was not written"
    local backup_version
    backup_version="$(jq -r '.version' "$DATA_DIR/config.v1.backup.json")"
    [[ "$backup_version" == "1" ]] || fail "$step" "backup should hold the untouched v1 file, got version '$backup_version'"

    # RESTIC_STATION_MACHINE_ID is documented as non-persistent. Run the real
    # helper under it against a v1 config, so the migration's write path to
    # machine.json fires while the override is in effect: the host's identity
    # on disk must not change. Baking a temporary profile id in here would
    # outlive the variable and silently rebind which `machines` overrides this
    # host applies.
    write_config "null"
    RESTIC_STATION_MACHINE_ID=second-profile "$HELPER" tick >/dev/null 2>&1 || true
    local machine_id_after
    machine_id_after="$(jq -r '.machineId' "$DATA_DIR/machine.json")"
    [[ "$machine_id_after" == "$machine_id" ]] \
        || fail "$step" "RESTIC_STATION_MACHINE_ID was persisted: machineId became '$machine_id_after'"

    log "$step OK (machineId=$machine_id)"
}

# Winds a set's recorded last-backup timestamps back far enough that the next
# `tick` finds it due. Used to drive the real scheduled entry point rather
# than a manual `run-set`, which dispatches with a different trigger.
wind_schedule_back() {
    local set_id="$1" step="$2" file="$DATA_DIR/state/schedule-state.json"
    # Fails loudly THROUGH fail() on every path, labelled with the caller's
    # step. A missing file, a missing set entry, or a renamed field must not
    # quietly wind nothing back — and must not abort as a bare nonzero under
    # `set -e` either, which would skip fail()'s index/state dump and let the
    # EXIT trap delete the evidence before anyone can look at it.
    [[ -f "$file" ]] || fail "$step" "wind_schedule_back: no schedule-state.json at $file"
    local wind_out
    if ! wind_out="$(python3 - "$file" "$set_id" 2>&1 <<'WIND'
import json, sys
path, set_id = sys.argv[1], sys.argv[2]
with open(path) as handle:
    state = json.load(handle)
sets = state.get("sets") or {}
if set_id not in sets:
    sys.exit(f"schedule-state.json has no entry for set {set_id}: {sorted(sets)}")
entry = sets[set_id]
# `lastBackupStart` is the only backup timestamp SetScheduleState encodes.
# Asserted rather than assumed: if it is renamed, this must fail here and
# not silently leave the set not-due.
if "lastBackupStart" not in entry:
    sys.exit(f"no lastBackupStart in schedule-state entry: {sorted(entry)}")
entry["lastBackupStart"] = "2020-01-01T00:00:00Z"
with open(path, "w") as handle:
    json.dump(state, handle)
WIND
    )"; then
        fail "$step" "wind_schedule_back: ${wind_out:-python3 failed with no output}"
    fi
}

assert_retention() {
    # Manual retention apply is contained (Option A, issues #111/#82): the
    # helper refuses `run-set --kind prune` outright. Retention itself is not
    # gone, so this step proves both halves — the refusal costs nothing, and
    # the scheduled path still applies the policy to the primary and to a
    # caught-up mirror. Dropping the second half would let containment turn
    # into "no retention at all" without any test noticing.
    local step="retention (contained manual apply; scheduled path still prunes)"
    log "$step"

    local prune_primary_before prune_secondary_before
    prune_primary_before="$(idx_count prune success "$SET_ID" "$PRIMARY_DEST_ID" "")"
    prune_secondary_before="$(idx_count prune success "$SET_ID" "$SECONDARY_DEST_ID" "")"
    # Any status, any destination: the contract is "no run record at all", so
    # filtering to success would let a regression that moved bookkeeping ahead
    # of the refusal write a failed or skipped record and still pass.
    local prune_any_before
    prune_any_before="$(idx_count prune "" "$SET_ID" "" "")"
    [[ "$prune_primary_before" -eq 0 ]] || fail "$step" "unexpected prune records before this step (retention was null throughout runs 1-4)"

    local pcount_before scount_before
    pcount_before="$(primary_snapshot_count)"
    scount_before="$(secondary_snapshot_count_at "$SECONDARY_REPO")"

    write_config '{"keepLast": 2, "keepHourly": null, "keepDaily": null, "keepWeekly": null, "keepMonthly": null, "keepYearly": null}'

    # ── half 1: manual apply refuses, and changes nothing ────────────────
    local out rc
    set +e
    out="$("$HELPER" run-set --set "$SET_ID" --kind prune 2>&1)"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] || fail "$step" "run-set --kind prune succeeded; manual retention apply must be refused"
    grep -qi "unavailable in this build" <<<"$out" \
        || fail "$step" "prune refusal did not explain the posture: $out"

    local prune_any_refused
    prune_any_refused="$(idx_count prune "" "$SET_ID" "" "")"
    [[ "$prune_any_refused" -eq "$prune_any_before" ]] \
        || fail "$step" "the refusal manufactured a prune record (any status, any destination): before=$prune_any_before after=$prune_any_refused"
    [[ "$(primary_snapshot_count)" -eq "$pcount_before" ]] \
        || fail "$step" "the refusal removed primary snapshots"
    [[ "$(secondary_snapshot_count_at "$SECONDARY_REPO")" -eq "$scount_before" ]] \
        || fail "$step" "the refusal removed secondary snapshots"

    # ── half 2: the scheduled path still applies the same policy ─────────
    # Through `tick`, not `run-set --kind backup`: only `tick` runs the due
    # check and dispatches with trigger `.scheduled`. Driving `run-set` here
    # would exercise `runSet` under a *manual* trigger and prove nothing about
    # whether the scheduler still reaches retention at all.
    #
    # Wind the set's last backup back so it is due.
    local scheduled_before
    scheduled_before="$(idx_select backup success "$SET_ID" "" "" \
        | grep -cE '"trigger":[[:space:]]*"scheduled"' || true)"
    wind_schedule_back "$SET_ID" "$step"

    set +e
    out="$("$HELPER" tick 2>&1)"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$step" "tick exited $rc: $out"

    local scheduled_after
    # Whitespace-tolerant: `jq -c` emits `"trigger":"scheduled"` while the
    # no-jq `json.dumps` fallback emits `"trigger": "scheduled"`.
    scheduled_after="$(idx_select backup success "$SET_ID" "" "" \
        | grep -cE '"trigger":[[:space:]]*"scheduled"' || true)"
    # A delta, not a total: an earlier step already runs a `tick` against this
    # same set and discards the result, so a lifetime count >= 1 could be
    # satisfied by that one and assert nothing about *this* dispatch.
    [[ "$scheduled_after" -eq $((scheduled_before + 1)) ]] \
        || fail "$step" "this tick produced no new scheduled backup (before=$scheduled_before after=$scheduled_after) — the set was not due, or the scheduler no longer dispatches: $out"

    local pcount scount
    pcount="$(primary_snapshot_count)"
    scount="$(secondary_snapshot_count_at "$SECONDARY_REPO")"
    [[ "$pcount" -le 2 ]] || fail "$step" "expected primary snapshots <= 2 after retention, got $pcount"
    [[ "$scount" -le 2 ]] || fail "$step" "expected secondary snapshots <= 2 after retention, got $scount"

    local prune_primary_after prune_secondary_after
    prune_primary_after="$(idx_count prune success "$SET_ID" "$PRIMARY_DEST_ID" "")"
    prune_secondary_after="$(idx_count prune success "$SET_ID" "$SECONDARY_DEST_ID" "")"
    [[ "$prune_primary_after" -eq $((prune_primary_before + 1)) ]] \
        || fail "$step" "expected exactly one new successful prune record for the primary, before=$prune_primary_before after=$prune_primary_after"
    # The mirror's copy in this very run succeeded, which is the scheduled
    # path's own gate for pruning a secondary — a live proof, not the stored
    # timestamp the contained manual path relied on.
    [[ "$prune_secondary_after" -eq $((prune_secondary_before + 1)) ]] \
        || fail "$step" "expected the freshly-synced secondary to also be pruned, before=$prune_secondary_before after=$prune_secondary_after"

    log "$step OK (manual apply refused; scheduled path pruned primary=$pcount, secondary=$scount snapshots)"
}

assert_tick_noop() {
    local step="tick (nothing due)"
    log "$step"

    local before after
    before="$(idx_count backup "" "$SET_ID" "" "")"

    local out rc
    set +e
    out="$("$HELPER" tick 2>&1)"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$step" "tick exited $rc: $out"

    after="$(idx_count backup "" "$SET_ID" "" "")"
    [[ "$after" -eq "$before" ]] || fail "$step" "expected no new backup records (everyMinutes 5 not due), before=$before after=$after"

    log "$step OK (backup record count unchanged at $after)"
}

assert_abandoned_run_is_not_healthy() {
    local step="abandoned run (killed process leaves current-run behind)"
    log "$step"

    # A SIGKILL/OOM/power-cut skips the `defer` that deletes
    # state/current-run-<setId>.json. That file is what "a run is in flight"
    # means to every reader, and `.running` outranks `.warning` — so one dead
    # run used to make this host report healthy forever, with `status`
    # exiting 0 and the menu bar staying blue.
    #
    # `updatedAt` is deliberately *now*: the point of deciding liveness from
    # the run's recorded pid rather than from a timestamp is that neither a
    # fresh-looking file from a dead process nor a very stale one from a live
    # `check --read-data` can fool it.
    mkdir -p "$DATA_DIR/state"
    local wreckage="$DATA_DIR/state/current-run-${SET_ID}.json"
    cat >"$wreckage" <<JSON
{
  "runId" : "20260101T000000Z-backup-deadbeef",
  "kind" : "backup",
  "phase" : "backing-up-primary",
  "percentDone" : 0.5,
  "bytesDone" : 1,
  "totalBytes" : 2,
  "filesDone" : 1,
  "totalFiles" : 2,
  "currentFiles" : [],
  "updatedAt" : "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

    local out rc
    set +e
    out="$("$HELPER" status --json 2>&1)"
    rc=$?
    set -e

    [[ $rc -eq 1 ]] || fail "$step" "expected status --json to exit 1 with an abandoned run, got $rc: $out"
    local health is_running abandoned
    health="$(printf '%s' "$out" | jq -r '.data | .health')"
    is_running="$(printf '%s' "$out" | jq -r --arg id "$SET_ID" '.data | .sets[] | select(.id == $id) | .isRunning')"
    abandoned="$(printf '%s' "$out" | jq -r --arg id "$SET_ID" '.data | .sets[] | select(.id == $id) | .abandonedRun.runId')"
    [[ "$health" == "warning" ]] || fail "$step" "expected health=warning, got '$health'"
    [[ "$is_running" == "false" ]] || fail "$step" "expected isRunning=false, got '$is_running'"
    [[ "$abandoned" == "20260101T000000Z-backup-deadbeef" ]] \
        || fail "$step" "expected the abandoned run to be named, got '$abandoned'"

    rm -f "$wreckage"
    log "$step OK (warning, not running; the abandoned run is named)"
}

assert_tick_clears_wreckage_whose_metadata_is_already_terminal() {
    local step="tick clears abandoned progress whose run is already marked failed"
    log "$step"

    # The case `recoverInterrupted()` cannot see. It only returns runs *it*
    # transitioned from `running` to `failed`, so a current-run file whose
    # metadata is already terminal was returned by nothing and cleared by
    # nothing — leaving `status` to exit 1 until the set next runs, and
    # forever if the set is deleted from the config first.
    #
    # This is not a contrived state: it is what every host upgrading from the
    # previous release looks like. There, the first post-kill tick already
    # rewrote metadata to `failed` while nothing deleted the current-run file.
    local run_id="20260101T000000Z-backup-cafebabe"
    local run_dir="$DATA_DIR/runs/$run_id"
    mkdir -p "$run_dir" "$DATA_DIR/state"

    # pid 999999 is above the default pid_max on both platforms, so
    # `kill(pid, 0)` reports ESRCH — dead, without depending on what happens
    # to be running on the test host.
    cat >"$run_dir/metadata.json" <<JSON
{
  "runId" : "$run_id",
  "kind" : "backup",
  "setId" : "$SET_ID",
  "destId" : "$PRIMARY_DEST_ID",
  "groupId" : "$run_id",
  "status" : "failed",
  "trigger" : "scheduled",
  "start" : "2026-01-01T00:00:00Z",
  "end" : "2026-01-01T00:05:00Z",
  "pid" : 999999,
  "argvRedacted" : [],
  "errorSummary" : "interrupted"
}
JSON

    local wreckage="$DATA_DIR/state/current-run-${SET_ID}.json"
    cat >"$wreckage" <<JSON
{
  "runId" : "$run_id",
  "kind" : "backup",
  "phase" : "backing-up-primary",
  "percentDone" : 0.5,
  "bytesDone" : 1,
  "totalBytes" : 2,
  "filesDone" : 1,
  "totalFiles" : 2,
  "currentFiles" : [],
  "updatedAt" : "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

    # Asserted on the abandoned-run field rather than on status's exit code,
    # deliberately. This environment has no installed timer, so `status`
    # exits 1 here for scheduler reasons whether or not any wreckage exists —
    # an exit-code assertion would have passed before the tick for the wrong
    # reason and been unreachable after it. The field isolates the one thing
    # this step is about.
    local out rc abandoned
    set +e
    out="$("$HELPER" status --json 2>&1)"
    set -e
    abandoned="$(printf '%s' "$out" | jq -r --arg id "$SET_ID" '.data | .sets[] | select(.id == $id) | .abandonedRun.runId')"
    [[ "$abandoned" == "$run_id" ]] \
        || fail "$step" "precondition: expected the abandoned run to be named before the tick, got '$abandoned'"

    set +e
    out="$("$HELPER" tick 2>&1)"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$step" "tick exited $rc: $out"

    [[ ! -f "$wreckage" ]] || fail "$step" "tick left the abandoned progress file behind: $out"

    set +e
    out="$("$HELPER" status --json 2>&1)"
    set -e
    abandoned="$(printf '%s' "$out" | jq -r --arg id "$SET_ID" '.data | .sets[] | select(.id == $id) | .abandonedRun')"
    [[ "$abandoned" == "null" ]] \
        || fail "$step" "expected no abandoned run after the tick, got '$abandoned': $out"

    rm -rf "$run_dir"
    log "$step OK (cleared, and status stops reporting an abandoned run)"
}

assert_unreadable_run_index_fails_loudly() {
    local step="unreadable runs index (status must not report healthy)"
    log "$step"

    # `(try? runStore.recentRuns(…)) ?? []` turned an unreadable index into
    # "no runs recorded", which derives to idle, which exits 0 — `status`
    # reporting healthy precisely because it could not read the evidence.
    # A corrupt *line* is survivable and stays survivable (recentRuns skips
    # it with a warning); this is the file being unreadable outright.
    if [[ "$(id -u)" -eq 0 ]]; then
        log "$step SKIPPED (running as root: chmod 000 does not deny root, so this would pass for the wrong reason)"
        return
    fi

    local index="$DATA_DIR/runs/index.jsonl"
    [[ -f "$index" ]] || fail "$step" "expected an index to exist by now: $index"
    # `stat` is not portable here, and the usual `stat -f … || stat -c …`
    # idiom is actively wrong: on GNU coreutils `-f` means "file system
    # status", so it *succeeds* on Linux, prints a block of filesystem
    # information, and the `||` fallback never runs — which is exactly how
    # this line reached CI, passing on macOS and feeding `chmod` a paragraph
    # about ext4 on Linux. Branch on the platform explicitly instead.
    local saved_mode
    if [[ "$OS_NAME" == "Darwin" ]]; then
        saved_mode="$(stat -f '%Lp' "$index")"
    else
        saved_mode="$(stat -c '%a' "$index")"
    fi
    [[ "$saved_mode" =~ ^[0-7]{3,4}$ ]] || fail "$step" "could not read the index file's mode: '$saved_mode'"
    chmod 000 "$index"

    # stdout and stderr are captured separately: since issue #81 a failing
    # `--json` command puts an error envelope on stdout, and `status` may
    # also log a discovery `info:` line to stderr — merging the two would
    # feed `jq` something that is not JSON.
    local out err rc
    local err_file="$DATA_DIR/../unreadable-index-stderr"
    set +e
    out="$("$HELPER" status --json 2>"$err_file")"
    rc=$?
    set -e
    err="$(cat "$err_file")"
    rm -f "$err_file"
    chmod "$saved_mode" "$index"

    [[ $rc -ne 0 ]] || fail "$step" "status exited 0 with an unreadable run index: $out"

    # Read through `jq` rather than grepping the raw bytes: the encoder
    # escapes forward slashes, so the file path is spelled `\/var\/…` on the
    # wire and a literal substring match for it silently fails. A caller
    # decodes the JSON and sees the real path, which is what this asserts.
    local code message
    code="$(jq -r '.error.code' <<<"$out")" \
        || fail "$step" "status --json did not emit a parseable envelope. stdout: $out stderr: $err"
    message="$(jq -r '.error.message' <<<"$out")"

    [[ "$code" == "internal_error" ]] \
        || fail "$step" "expected internal_error for an unreadable index, got: $code"
    [[ "$message" == *"could not read the run history"* ]] \
        || fail "$step" "expected the message to name the run history, got: $message"
    [[ "$message" == *"$index"* ]] || fail "$step" "expected the message to name the file, got: $message"

    log "$step OK (exit $rc, code=$code, and it names the file)"
}

assert_lock_busy() {
    local step="lock-busy (run-set while the set lock is held)"
    log "$step"

    mkdir -p "$DATA_DIR/locks"
    local lock_file="$DATA_DIR/locks/set-${SET_ID}.lock"

    python3 - "$lock_file" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "a+")
fcntl.flock(f.fileno(), fcntl.LOCK_EX)
time.sleep(20)
PY
    LOCK_HOLDER_PID=$!

    # Give the background holder a moment to actually acquire the lock
    # before we race it.
    sleep 1

    local out rc
    set +e
    out="$("$HELPER" run-set --set "$SET_ID" --kind backup 2>&1)"
    rc=$?
    set -e

    kill "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
    wait "$LOCK_HOLDER_PID" 2>/dev/null || true
    LOCK_HOLDER_PID=""

    [[ $rc -eq 2 ]] || fail "$step" "expected exit 2 (busy), got $rc: $out"

    local skipped_line summary
    skipped_line="$(idx_select backup skipped "$SET_ID" "$PRIMARY_DEST_ID" "" | tail -n1)"
    [[ -n "$skipped_line" ]] || fail "$step" "expected a skipped backup index record"
    summary="$(field_of "$skipped_line" errorSummary)"
    [[ "$summary" == *"already running"* ]] || fail "$step" "unexpected skipped-record errorSummary: '$summary'"

    log "$step OK (exit 2, skipped record recorded)"
}

# =========================================================================
# M5 story (docs/tasks/T29 / issue #31 "Linux integration test"): import a
# config exported from macOS (checked-in fixture — scripts/fixtures/
# mac-exported-config.json), `secret set` via stdin, a real backup against a
# local repo, a second destination as a mirror (restic copy), `config
# validate` reporting the effective plan and correctly *excluding* a set
# disabled for this machine, and `status --json` reflecting the run.
#
# Runs on every platform this script runs on (not gated to Linux): the whole
# point of extending this script rather than adding a Linux sibling is that
# macOS and Linux cannot silently drift in what they cover. Always forces
# the FILE secret backend regardless of host, matching
# scripts/headless-cli-test.sh's convention — this scenario is specifically
# about the Linux-default secrets path and the cross-machine config story,
# neither of which involves the keychain.
#
# Entirely separate identifiers, repos and data directory from the
# runs-1-4 scenario above — nothing here can collide with or depend on it.
# =========================================================================

assert_fixture_flow() {
    local step="fixture (mac-exported config import)"
    log "$step"

    command -v jq >/dev/null 2>&1 || fail "$step" "jq is required for this scenario (status --json assertions)"
    [[ -f "$FIXTURE_FILE" ]] || fail "$step" "checked-in fixture missing: $FIXTURE_FILE"

    local fixture_root="$WORK/fixture"
    local fixture_data_dir="$fixture_root/data"
    local fixture_source="$fixture_root/source"
    local fixture_primary_repo="$fixture_root/repo-primary"
    local fixture_mirror_repo="$fixture_root/repo-mirror"
    mkdir -p "$fixture_data_dir" "$fixture_source"
    echo "fixture file one" > "$fixture_source/a.txt"
    echo "fixture file two" > "$fixture_source/b.txt"

    # Repoint the shared dump-on-failure globals (fail()/idx_select/
    # idx_count/json_field all read $DATA_DIR/$INDEX_FILE) at this
    # scenario's data directory. Safe because this is the LAST scenario
    # main() runs — nothing downstream still needs the runs-1-4 values.
    DATA_DIR="$fixture_data_dir"
    INDEX_FILE="$fixture_data_dir/runs/index.jsonl"

    local rendered="$fixture_root/imported-config.json"
    sed \
        -e "s#__SOURCE_DIR__#$fixture_source#g" \
        -e "s#__PRIMARY_REPO__#$fixture_primary_repo#g" \
        -e "s#__MIRROR_REPO__#$fixture_mirror_repo#g" \
        -e "s#__MACHINE_ID__#$FIXTURE_MACHINE_ID#g" \
        "$FIXTURE_FILE" > "$rendered"

    fx_helper() {
        RESTIC_STATION_DATA_DIR="$fixture_data_dir" \
            RESTIC_STATION_MACHINE_ID="$FIXTURE_MACHINE_ID" \
            RESTIC_STATION_SECRET_BACKEND=file \
            "$HELPER" "$@"
    }

    local out rc
    set +e
    out="$(fx_helper config import "$rendered" 2>&1)"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$step" "config import exited $rc: $out"
    [[ -f "$fixture_data_dir/config.json" ]] || fail "$step" "config import did not install config.json"
    log "$step OK — imported a config authored (in shape) exactly as macOS's \`config export\` would produce it"

    # ── secret set via stdin (T23), for both real destinations ──────────
    step="fixture (secret set via stdin)"
    printf '%s' "$FIXTURE_PASSWORD" | fx_helper secret set --dest "$FIXTURE_PRIMARY_ID" >/dev/null \
        || fail "$step" "secret set (primary) failed"
    printf '%s' "$FIXTURE_PASSWORD" | fx_helper secret set --dest "$FIXTURE_MIRROR_ID" >/dev/null \
        || fail "$step" "secret set (mirror) failed"
    log "$step OK"

    # ── init both repos: primary directly via restic (proves the fixture's
    #    freshly-stored password authenticates it), mirror via the helper's
    #    own init-secondary ────────────────────────────────────────────────
    step="fixture (init primary + mirror)"
    local primary_id_lower mirror_id_lower pwcmd_primary pwcmd_mirror
    primary_id_lower="$(printf '%s' "$FIXTURE_PRIMARY_ID" | tr '[:upper:]' '[:lower:]')"
    mirror_id_lower="$(printf '%s' "$FIXTURE_MIRROR_ID" | tr '[:upper:]' '[:lower:]')"
    # Quoting rule: double-quote $HELPER only when it contains a character
    # outside [A-Za-z0-9/._+=:,@-] (restic runs RESTIC_PASSWORD_COMMAND
    # through a shell) — same rule scripts/secret-cli-test.sh step 7 applies.
    if [[ "$HELPER" =~ ^[A-Za-z0-9/._+=:,@-]+$ ]]; then
        pwcmd_primary="$HELPER print-password --dest $primary_id_lower"
        pwcmd_mirror="$HELPER print-password --dest $mirror_id_lower"
    else
        pwcmd_primary="\"$HELPER\" print-password --dest $primary_id_lower"
        pwcmd_mirror="\"$HELPER\" print-password --dest $mirror_id_lower"
    fi
    RESTIC_STATION_DATA_DIR="$fixture_data_dir" RESTIC_STATION_MACHINE_ID="$FIXTURE_MACHINE_ID" \
        RESTIC_STATION_SECRET_BACKEND=file RESTIC_PASSWORD_COMMAND="$pwcmd_primary" \
        restic -r "$fixture_primary_repo" init --json >/dev/null \
        || fail "$step" "restic init (primary) failed"

    set +e
    out="$(fx_helper init-secondary --set "$FIXTURE_SET_ID" --dest "$FIXTURE_MIRROR_ID" 2>&1)"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$step" "init-secondary (mirror) exited $rc: $out"
    log "$step OK"

    # Both must forward RESTIC_STATION_DATA_DIR + RESTIC_STATION_SECRET_BACKEND,
    # not just RESTIC_PASSWORD_COMMAND: restic runs the password command as a
    # child of *itself*, inheriting restic's own environment, not this
    # script's ambient one (nothing here exports those two globally — see
    # fx_helper). Without them, print-password falls back to the default
    # data directory and the default (keychain, on macOS) backend — silently
    # the wrong store — which is exactly the bug this comment is pinned
    # against (caught by the red-check noted in the PR description).
    fixture_restic_primary() {
        RESTIC_STATION_DATA_DIR="$fixture_data_dir" RESTIC_STATION_SECRET_BACKEND=file \
            RESTIC_PASSWORD_COMMAND="$pwcmd_primary" restic -r "$fixture_primary_repo" "$@"
    }
    fixture_restic_mirror() {
        RESTIC_STATION_DATA_DIR="$fixture_data_dir" RESTIC_STATION_SECRET_BACKEND=file \
            RESTIC_PASSWORD_COMMAND="$pwcmd_mirror" restic -r "$fixture_mirror_repo" "$@"
    }

    # ── a real backup, plus the mirror destination via restic copy ───────
    step="fixture (real backup + mirror via restic copy)"
    set +e
    out="$(fx_helper run-set --set "$FIXTURE_SET_ID" --kind backup 2>&1)"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$step" "run-set exited $rc: $out"

    local pcount mcount
    pcount="$(fixture_restic_primary snapshots --json | jlen)"
    mcount="$(fixture_restic_mirror snapshots --json | jlen)"
    [[ "$pcount" -eq 1 ]] || fail "$step" "expected 1 primary snapshot, got $pcount"
    [[ "$mcount" -eq 1 ]] || fail "$step" "expected 1 mirror snapshot (restic copy), got $mcount"

    local copy_line
    copy_line="$(idx_select copy success "$FIXTURE_SET_ID" "$FIXTURE_MIRROR_ID" "" | tail -n1)"
    [[ -n "$copy_line" ]] || fail "$step" "no successful copy index record for the mirror destination"
    log "$step OK (primary=$pcount, mirror=$mcount snapshot(s), restic copy record present)"

    # ── config validate: effective plan for this machine, correctly
    #    excluding the Mac-only set disabled here ─────────────────────────
    step="fixture (config validate excludes the set disabled for this machine)"
    set +e
    out="$(fx_helper config validate 2>&1)"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$step" "config validate exited $rc: $out"
    echo "$out" | grep -q "RUNS HERE" \
        || fail "$step" "did not report the \"Projects\" set as RUNS HERE: $out"
    echo "$out" | grep -q "does not run here" \
        || fail "$step" "did not report the Mac-only \"Mac Photos Library\" set as excluded: $out"
    echo "$out" | grep -q "disabled on this machine" \
        || fail "$step" "did not explain WHY the Mac-only set is excluded: $out"
    # Only one of the two sets is disabled here — "nothing will run" is the
    # ALL-disabled message (headless-cli-test.sh covers that case) and must
    # NOT appear for this config.
    if echo "$out" | grep -q "nothing will run on this machine"; then
        fail "$step" "wrongly reported nothing running, when the \"Projects\" set is enabled here: $out"
    fi
    log "$step OK"

    # ── status --json, piped through jq, reflects the run — and the
    #    exclusion (anti-silent-failure guarantee, asserted on real output) ──
    step="fixture (status --json reflects the run and the exclusion)"
    local status_json status_rc
    set +e
    status_json="$(fx_helper status --json)"
    status_rc=$?
    set -e
    # Nothing has installed a timer for this data directory, so on Linux
    # `status` correctly reports the scheduler as unhealthy and exits 1 —
    # that is issues #46/#48 working, not a failure of this scenario. On
    # macOS probes the LaunchAgent directly. Its state belongs to the host,
    # not this fixture: a developer may have the real app enabled while CI
    # will not. Assert the answer is internally consistent in either state.
    if [[ "$OS_NAME" == "Linux" ]]; then
        [[ $status_rc -eq 1 ]] || fail "$step" "expected exit 1 with no timer installed, got $status_rc"
        echo "$status_json" | jq -e '.data | .scheduler.healthy == false' >/dev/null \
            || fail "$step" "expected scheduler.healthy=false with no timer installed: $status_json"
        echo "$status_json" | jq -e '.data | .scheduler.problems | index("unitsMissing")' >/dev/null \
            || fail "$step" "expected scheduler.problems to name unitsMissing: $status_json"
    else
        echo "$status_json" | jq -e '.data | .scheduler.kind == "launchd-agent"' >/dev/null \
            || fail "$step" "expected a launchd-agent scheduler probe on macOS: $status_json"
        local scheduler_health
        scheduler_health="$(echo "$status_json" | jq -r '.data | .scheduler.healthy')"
        case "$scheduler_health" in
            true)
                [[ $status_rc -eq 0 ]] || fail "$step" "healthy LaunchAgent should exit 0, got $status_rc: $status_json"
                ;;
            false)
                [[ $status_rc -eq 1 ]] || fail "$step" "missing LaunchAgent should exit 1, got $status_rc: $status_json"
                echo "$status_json" | jq -e '.data | .scheduler.problems | index("agentNotLoaded")' >/dev/null \
                    || fail "$step" "missing LaunchAgent did not name agentNotLoaded: $status_json"
                ;;
            null)
                [[ $status_rc -eq 0 ]] || fail "$step" "unknown LaunchAgent state should not fail status: $status_json"
                echo "$status_json" | jq -e '.data | .scheduler.problems | index("launchctlProbeFailed")' >/dev/null \
                    || fail "$step" "unknown LaunchAgent state did not name launchctlProbeFailed: $status_json"
                ;;
            *) fail "$step" "unexpected LaunchAgent health '$scheduler_health': $status_json" ;;
        esac
    fi
    echo "$status_json" | jq -e '.data | .sets | length == 1' >/dev/null \
        || fail "$step" "expected exactly one set in status --json (the disabled-here set must not appear): $status_json"
    echo "$status_json" | jq -e '.data | .sets[0].name == "Projects"' >/dev/null \
        || fail "$step" "status --json did not report the \"Projects\" set: $status_json"
    echo "$status_json" | jq -e '.data | .sets[0].lastBackup.status == "success"' >/dev/null \
        || fail "$step" "status --json did not reflect the successful backup: $status_json"
    echo "$status_json" | jq -e '.data | .excludedHere | length == 1' >/dev/null \
        || fail "$step" "expected exactly one exclusion in status --json: $status_json"
    echo "$status_json" | jq -e '.data | .excludedHere[0].reason == "disabledForMachine"' >/dev/null \
        || fail "$step" "status --json's exclusion reason was not disabledForMachine: $status_json"
    echo "$status_json" | jq -e --arg id "$FIXTURE_DISABLED_SET_ID" '.data | .excludedHere[0].id == $id' >/dev/null \
        || fail "$step" "status --json's exclusion named the wrong set (expected $FIXTURE_DISABLED_SET_ID): $status_json"
    log "$step OK"

    log "fixture flow OK — mac-exported config imported, secret set via stdin, real backup + mirror " \
        "via restic copy, config validate and status --json both correctly excluded the set disabled " \
        "for this machine"
}

# =========================================================================
# Main
# =========================================================================

main() {
    preflight_restic
    preflight_jq
    log "Platform: $OS_NAME"
    setup_workspace
    build_helper
    # write_config BEFORE setup_secret_backend: the Linux path seeds through
    # `secret set --dest <id>`, which refuses an id that is not a configured
    # destination. macOS seeds with `security add-generic-password`, which has
    # no such check, so this ordering only ever mattered on Linux.
    write_config "null"
    setup_secret_backend
    init_primary
    init_secondary

    assert_run1
    assert_migration
    assert_run2
    assert_run3
    assert_run4
    assert_retention
    assert_tick_noop
    assert_abandoned_run_is_not_healthy
    assert_tick_clears_wreckage_whose_metadata_is_already_terminal
    assert_unreadable_run_index_fails_loudly
    assert_lock_busy

    assert_fixture_flow

    log "ALL ASSERTIONS PASSED (${SECONDS}s)"
}

main "$@"
