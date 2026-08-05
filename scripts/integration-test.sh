#!/bin/bash -euo pipefail
# shellcheck disable=SC2096
# ^ the shebang above intentionally packs -euo pipefail into one shebang
# line per docs/tasks/T19-integration-test.md ("#!/bin/bash -euo pipefail");
# not every OS splits that into three flags, which is exactly why the `set
# -euo pipefail` a few lines down is the one that actually matters.
# scripts/integration-test.sh — Layer 2 integration test (docs/testing.md
# §Layer 2, docs/tasks/T19-integration-test.md): builds the real app/helper,
# seeds a real login-keychain item, and drives `restic-station-helper`
# against two real local restic repositories end to end.
#
# Local dev escape hatch: this machine may have no Xcode.app, in which case
# `xcodebuild` cannot run. Set RESTIC_STATION_HELPER_OVERRIDE to the path of
# an already-built helper binary (e.g. from a throwaway SwiftPM harness) to
# skip the xcodebuild step entirely. CI never sets this — it always builds
# the real app bundle.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

    /usr/bin/security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$PRIMARY_DEST_ID_LOWER" >/dev/null 2>&1
    /usr/bin/security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$SECONDARY_DEST_ID_LOWER" >/dev/null 2>&1

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
trap cleanup EXIT

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

# =========================================================================
# Build
# =========================================================================

build_helper() {
    if [[ -n "${RESTIC_STATION_HELPER_OVERRIDE:-}" ]]; then
        HELPER="$RESTIC_STATION_HELPER_OVERRIDE"
        log "Using RESTIC_STATION_HELPER_OVERRIDE (local dev escape hatch): $HELPER"
        [[ -x "$HELPER" ]] || { echo "FATAL: override helper is not executable: $HELPER" >&2; exit 1; }
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
# config.json: every helper invocation below therefore runs the real v1 → v2
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
    RESTIC_PASSWORD_COMMAND="/usr/bin/security find-generic-password -s $KEYCHAIN_SERVICE -a $PRIMARY_DEST_ID_LOWER -w" \
        restic -r "$PRIMARY_REPO" "$@"
}

restic_secondary_at() { # restic_secondary_at <repo-path> <args...>
    local repo="$1"
    shift
    RESTIC_PASSWORD_COMMAND="/usr/bin/security find-generic-password -s $KEYCHAIN_SERVICE -a $SECONDARY_DEST_ID_LOWER -w" \
        restic -r "$repo" "$@"
}

primary_snapshot_count() { restic_primary snapshots --json | jlen; }
secondary_snapshot_count_at() { restic_secondary_at "$1" snapshots --json | jlen; }

init_primary() {
    log "Initializing the primary repository directly via restic (proves the keychain path)"
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
    local step="migration (v1 -> v2, resticPath relocated, v1 backed up)"
    log "$step"

    local version restic_in_config machine_id machine_restic
    version="$(jq -r '.version' "$DATA_DIR/config.json")"
    restic_in_config="$(jq -r '.resticPath' "$DATA_DIR/config.json")"
    [[ "$version" == "2" ]] || fail "$step" "expected config.json at version 2, got '$version'"
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

assert_retention() {
    local step="retention (keep-last 2 via run-set --kind prune)"
    log "$step"

    local prune_primary_before prune_secondary_before
    prune_primary_before="$(idx_count prune success "$SET_ID" "$PRIMARY_DEST_ID" "")"
    prune_secondary_before="$(idx_count prune success "$SET_ID" "$SECONDARY_DEST_ID" "")"
    [[ "$prune_primary_before" -eq 0 ]] || fail "$step" "unexpected prune records before this step (retention was null throughout runs 1-4)"

    write_config '{"keepLast": 2, "keepHourly": null, "keepDaily": null, "keepWeekly": null, "keepMonthly": null, "keepYearly": null}'

    local out rc
    set +e
    out="$("$HELPER" run-set --set "$SET_ID" --kind prune 2>&1)"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || fail "$step" "run-set --kind prune exited $rc: $out"

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
    # The mirror just synced in run4 (lastSyncedAt >= primary's), so runPrune's
    # freshness guard (docs/tasks/T19) must let it qualify too.
    [[ "$prune_secondary_after" -eq $((prune_secondary_before + 1)) ]] \
        || fail "$step" "expected the freshly-synced secondary to also be pruned, before=$prune_secondary_before after=$prune_secondary_after"

    log "$step OK (primary=$pcount, secondary=$scount snapshots)"
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
# Main
# =========================================================================

main() {
    preflight_restic
    preflight_jq
    setup_workspace
    setup_keychain_access
    seed_keychain
    build_helper
    write_config "null"
    init_primary
    init_secondary

    assert_run1
    assert_migration
    assert_run2
    assert_run3
    assert_run4
    assert_retention
    assert_tick_noop
    assert_lock_busy

    log "ALL ASSERTIONS PASSED (${SECONDS}s)"
}

main "$@"
