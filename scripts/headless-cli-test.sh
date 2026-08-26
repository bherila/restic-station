#!/bin/bash
# scripts/headless-cli-test.sh — end-to-end verification of T27's headless
# CLI ergonomics (issue #29): `config export/import/validate/show`, `status`,
# `sets list`, `runs list/show`.
#
# Mirrors scripts/secret-cli-test.sh's shape: a real built binary, real data
# directories under a throwaway temp root, assertions on actual process
# output and exit codes — not just "did it not crash".
#
# What it proves (numbered to match the issue's own test list):
#   1. `config export`/`config import` round-trip a real config.json,
#      migrating a v1 file and backing it up in the process.
#   2. `config validate` on a config where every set is disabled for this
#      machine exits 0 but clearly explains that nothing will run — this is
#      the anti-silent-failure guarantee, asserted on actual stdout.
#   3. `config validate --machine <other>` resolves for a machine that is
#      not this host.
#   4. `status --json` against fixture state directories — healthy,
#      in-flight, failed, stale-mirror — asserting the exit code each time.
#   5. Every `--json` mode emits parseable JSON with nothing else on stdout
#      (piped through `jq` here, not just eyeballed).
#   6. Capability selectors carry their value only on stdin: retired argv
#      forms exit 64 without reflection, and Linux /proc never sees a canary.
#   7. No subcommand prints a secret: every stdout/stderr byte this script's
#      subcommands produce is captured to one combined log, and that log is
#      grepped for the fixture secret value at the very end.
#   8. Exit-code contract (0 ok / 1 error) spot-checked for the new
#      subcommands on both the happy and unhappy path.
#   9. Every `--json` command emits one success envelope
#      ({schemaVersion, ok, data}) on stdout and nothing else (issue #79).
#   8. A failing `--json` command emits exactly one error envelope on
#      stdout with the documented `error.code` (issue #81,
#      `docs/cli-json.md`), human mode is unchanged, and a nonzero exit
#      that is *not* a failure — `status --json` on a warning — still
#      emits its report rather than an envelope.
#
# Usage:
#   scripts/headless-cli-test.sh [path-to-restic-station-helper]
# Defaults to .build/debug/restic-station-helper (built by `swift build`).
# Uses the FILE secret backend unconditionally (RESTIC_STATION_SECRET_BACKEND=file),
# the same choice scripts/secret-cli-test.sh makes, so this exercises the
# Linux-default path on every platform it runs on.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="${1:-$REPO_ROOT/.build/debug/restic-station-helper}"

[[ -x "$HELPER" ]] || { echo "helper not executable at $HELPER (run: swift build)" >&2; exit 1; }

WORK=""
cleanup() {
    local code=$?
    [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
    exit "$code"
}
trap cleanup EXIT

WORK="$(mktemp -d "${TMPDIR:-/tmp}/restic-station-headless.XXXXXX")"
COMBINED_LOG="$WORK/combined.log"
touch "$COMBINED_LOG"

log()  { printf '\n=== %s ===\n' "$*" | tee -a "$COMBINED_LOG"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok: %s\n' "$*"; }

# Runs the helper with the given args; every byte of stdout+stderr is both
# captured to $COMBINED_LOG (for the end-of-script secret grep) and to
# $OUT_FILE (for this call's own assertions). Exit code is preserved in
# $RC. Never uses `set -e`-incompatible constructs so a nonzero exit is
# always observed, not silently swallowed by a pipeline.
OUT_FILE="$WORK/last-output"
RC=0
run_helper() {
    OUT_FILE="$WORK/out-$$-$RANDOM"
    set +e
    "$HELPER" "$@" >"$OUT_FILE" 2>&1
    RC=$?
    set -e
    cat "$OUT_FILE" >>"$COMBINED_LOG"
}

# Same as `run_helper`, but keeps the two streams apart in $OUT_FILE and
# $ERR_FILE. Needed by section 8: "exactly one JSON document on stdout" is
# only a claim about stdout, and `run_helper` merges stderr into it.
ERR_FILE="$WORK/last-stderr"
run_helper_split() {
    OUT_FILE="$WORK/out-$$-$RANDOM"
    ERR_FILE="$WORK/err-$$-$RANDOM"
    set +e
    "$HELPER" "$@" >"$OUT_FILE" 2>"$ERR_FILE"
    RC=$?
    set -e
    cat "$OUT_FILE" "$ERR_FILE" >>"$COMBINED_LOG"
}

# The capability transport test must feed stdin without placing its canary in
# argv, environment, or the combined diagnostic log. Capture the helper's
# exit status (not printf's) from the pipeline explicitly.
run_helper_split_stdin() {
    local payload="$1"
    shift
    OUT_FILE="$WORK/out-$$-$RANDOM"
    ERR_FILE="$WORK/err-$$-$RANDOM"
    set +e
    printf '%s' "$payload" | "$HELPER" "$@" >"$OUT_FILE" 2>"$ERR_FILE"
    RC=${PIPESTATUS[1]}
    set -e
    cat "$OUT_FILE" "$ERR_FILE" >>"$COMBINED_LOG"
}

expect_rc() {
    local expected="$1"
    [[ "$RC" -eq "$expected" ]] || {
        cat "$OUT_FILE" >&2
        fail "expected exit $expected, got $RC"
    }
}

# A fixture can prove its backup state is healthy without controlling the
# host scheduler. On macOS the status command now probes the real LaunchAgent;
# on Linux it probes the real user timer. A definite scheduler failure makes
# status exit 1, while healthy or unknown scheduler state contributes 0.
CLEAN_STATUS_RC=0
capture_clean_status_rc() {
    if jq -e '.data | .scheduler.healthy == false' "$OUT_FILE" >/dev/null; then
        CLEAN_STATUS_RC=1
    else
        CLEAN_STATUS_RC=0
    fi
}

# shellcheck disable=SC2016 # literal $, deliberately awkward, never expanded
SECRET_PASSWORD='h34dl3ss "cli" $ecret with spaces '

# ─────────────────────────────────────────────────────────────────────────
# 1. config export / import round trip, including a v1 → v3 migration.
# ─────────────────────────────────────────────────────────────────────────
log "1. config export / import round trip"

MAC_DATA="$WORK/mac-data"
LINUX_DATA="$WORK/linux-data"
mkdir -p "$MAC_DATA" "$LINUX_DATA"

SET_ID="10000000-0000-4000-8000-000000000001"
PRIMARY_ID="10000000-0000-4000-8000-000000000002"
MIRROR_ID="10000000-0000-4000-8000-000000000003"
REPO_DIR="$WORK/repo"
MIRROR_DIR="$WORK/mirror-repo"
mkdir -p "$REPO_DIR" "$MIRROR_DIR"

# Authored as a v1 config, exactly the shape the pre-T24 macOS app writes.
cat > "$MAC_DATA/config.json" <<EOF
{
  "version": 1,
  "resticPath": "$(command -v restic || echo /usr/bin/restic)",
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$SET_ID",
      "name": "Projects",
      "sources": ["$WORK/does-not-need-to-exist-for-config-only-tests"],
      "excludes": [],
      "schedule": {"kind": "everyMinutes", "minutes": 5},
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 14,
      "destinations": [
        {"id": "$PRIMARY_ID", "label": "Primary", "repoURL": "$REPO_DIR", "isPrimary": true, "nonSecretEnv": {}},
        {"id": "$MIRROR_ID", "label": "Mirror", "repoURL": "$MIRROR_DIR", "isPrimary": false, "nonSecretEnv": {}}
      ]
    }
  ]
}
EOF

RESTIC_STATION_DATA_DIR="$MAC_DATA" run_helper config export --out "$WORK/exported-config.json"
expect_rc 0
grep -q '"version" : 3' "$WORK/exported-config.json" \
    || fail "exported config was not migrated to v3 in memory before export"
grep -q 'machine.json' "$OUT_FILE" || true # note-only; not asserted further
ok "export migrates v1 → v3 and writes to --out"

RESTIC_STATION_DATA_DIR="$LINUX_DATA" run_helper config import "$WORK/exported-config.json" --dry-run
expect_rc 0
grep -q 'added set "Projects"' "$OUT_FILE" || fail "dry-run did not summarize the incoming set"
grep -q 'dry run' "$OUT_FILE" || fail "dry-run did not say it wrote nothing"
[[ -f "$LINUX_DATA/config.json" ]] && fail "--dry-run wrote config.json"
ok "--dry-run summarizes and writes nothing"

RESTIC_STATION_DATA_DIR="$LINUX_DATA" run_helper config import "$WORK/exported-config.json"
expect_rc 0
[[ -f "$LINUX_DATA/config.json" ]] || fail "import did not install config.json"
ok "real import installs config.json"

RESTIC_STATION_DATA_DIR="$LINUX_DATA" run_helper config show --json
expect_rc 0
echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].name == "Projects"' >/dev/null \
    || fail "imported config does not resolve the same set on the new host"
echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].destinations | length == 2' >/dev/null \
    || fail "imported config lost a destination"
ok "config show --json on the importing host matches the exported set semantically"

# Re-import: must back up the existing config before overwriting.
RESTIC_STATION_DATA_DIR="$LINUX_DATA" run_helper config import "$WORK/exported-config.json"
expect_rc 0
grep -q 'backed up the existing config' "$OUT_FILE" || fail "re-import did not back up the existing config"
BACKUP_COUNT=$(find "$LINUX_DATA" -maxdepth 1 -name 'config.import-backup-*.json' | wc -l | tr -d ' ')
[[ "$BACKUP_COUNT" -ge 1 ]] || fail "no config.import-backup-*.json was written"
ok "re-importing backs up the previously-installed config beside itself"

# A v1 file imported directly is migrated AND backed up (config.v1.backup.json).
V1_IMPORT_DATA="$WORK/v1-import-data"
mkdir -p "$V1_IMPORT_DATA"
cat > "$WORK/incoming-v1.json" <<EOF
{"version":1,"resticPath":"/usr/bin/restic","showMenuBarIcon":true,"sets":[]}
EOF
RESTIC_STATION_DATA_DIR="$V1_IMPORT_DATA" run_helper config import "$WORK/incoming-v1.json"
expect_rc 0
grep -q '"version" : 3' "$V1_IMPORT_DATA/config.json" || fail "v1 import was not migrated to v3 on disk"
[[ -f "$V1_IMPORT_DATA/config.v1.backup.json" ]] || fail "v1 import did not write config.v1.backup.json"
ok "importing a v1 file migrates it to v3 and writes config.v1.backup.json (T24's migration, reused)"

# ─────────────────────────────────────────────────────────────────────────
# 2. config validate: every set disabled here still exits 0, and says so.
# ─────────────────────────────────────────────────────────────────────────
log "2. config validate on an all-disabled-here config"

ALL_DISABLED_DATA="$WORK/all-disabled-data"
mkdir -p "$ALL_DISABLED_DATA"
cat > "$ALL_DISABLED_DATA/config.json" <<EOF
{
  "version": 3,
  "resticPath": null,
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$SET_ID",
      "name": "Projects",
      "sources": ["/tmp/src"],
      "excludes": [],
      "purgeExcludes": [],
      "schedule": {"kind": "daily", "hour": 2, "minute": 30},
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 14,
      "destinations": [
        {"id": "$PRIMARY_ID", "label": "Primary", "repoURL": "$REPO_DIR", "isPrimary": true, "nonSecretEnv": {}}
      ],
      "machines": {"mirror-box": {"enabled": false}}
    }
  ]
}
EOF
RESTIC_STATION_DATA_DIR="$ALL_DISABLED_DATA" run_helper config validate --machine mirror-box
expect_rc 0
grep -q 'Errors:' "$OUT_FILE" || fail "validate did not print an Errors: section"
grep -q 'does not run here' "$OUT_FILE" || fail "validate did not mark the set as not running"
grep -q 'nothing will run on this machine' "$OUT_FILE" \
    || fail "validate did not clearly say nothing will run — this is the anti-silent-failure assertion"
grep -q 'disabled on this machine' "$OUT_FILE" || fail "validate did not explain WHY the set is excluded"
ok "config validate on an all-disabled-here machine exits 0 and unambiguously says nothing will run"

# ─────────────────────────────────────────────────────────────────────────
# 3. config validate --machine resolves for a machine that is not this host.
# ─────────────────────────────────────────────────────────────────────────
log "3. config validate --machine <other> resolves for a non-local machine"

RESTIC_STATION_DATA_DIR="$ALL_DISABLED_DATA" run_helper config validate --machine some-other-host-entirely
expect_rc 0
grep -q 'RUNS HERE' "$OUT_FILE" \
    || fail "a machine with no override on this set should run it, and the report should say so"
grep -q 'Effective plan for machine "some-other-host-entirely"' "$OUT_FILE" \
    || fail "validate did not resolve for the requested --machine"
ok "--machine resolves for an arbitrary machine id, not just this host's own"

# An invalid slug (uppercase, here) can never match any `machines` override
# key — resolving against it anyway would silently fall back to "no
# override applies", which for a set disabled on the machine the user
# actually meant could report it as running. Must be a hard error, not a
# quiet no-op (issue #29 finding 4).
RESTIC_STATION_DATA_DIR="$ALL_DISABLED_DATA" run_helper config validate --machine Mirror-Box
expect_rc 1
grep -qi 'not a valid machine id' "$OUT_FILE" \
    || fail "config validate --machine <invalid slug> should reject it with a clear message, not silently resolve"
ok "config validate rejects an invalid --machine slug instead of silently resolving nothing"

RESTIC_STATION_DATA_DIR="$ALL_DISABLED_DATA" run_helper config show --machine Mirror-Box
expect_rc 1
grep -qi 'not a valid machine id' "$OUT_FILE" \
    || fail "config show --machine <invalid slug> should reject it with a clear message, not silently resolve"
ok "config show rejects an invalid --machine slug instead of silently resolving nothing"

# ─────────────────────────────────────────────────────────────────────────
# 4. status --json fixture scenarios: healthy, in-flight, failed, stale.
# ─────────────────────────────────────────────────────────────────────────
log "4. status --json against fixture state directories"

make_status_fixture() {
    local dir="$1"
    mkdir -p "$dir/state" "$dir/runs"
    cat > "$dir/config.json" <<EOF
{
  "version": 3,
  "resticPath": null,
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$SET_ID",
      "name": "Projects",
      "sources": ["/tmp/src"],
      "excludes": [],
      "purgeExcludes": [],
      "schedule": {"kind": "daily", "hour": 2, "minute": 30},
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 1,
      "destinations": [
        {"id": "$PRIMARY_ID", "label": "Primary", "repoURL": "$REPO_DIR", "isPrimary": true, "nonSecretEnv": {}}
      ]
    }
  ]
}
EOF
}

# --- healthy: a recent successful backup, destination reachable+fresh. ---
HEALTHY="$WORK/status-healthy"
make_status_fixture "$HEALTHY"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
ONE_HOUR_AGO_TS=$(( $(date -u +%s) - 3600 ))
ONE_HOUR_AGO_ISO=$(date -u -r "$ONE_HOUR_AGO_TS" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
    || date -u -d "@$ONE_HOUR_AGO_TS" +%Y-%m-%dT%H:%M:%S.000Z)
cat > "$HEALTHY/runs/index.jsonl" <<EOF
{"runId":"r-healthy","kind":"backup","setId":"$SET_ID","destId":"$PRIMARY_ID","groupId":"r-healthy","status":"success","start":"$ONE_HOUR_AGO_ISO","end":"$ONE_HOUR_AGO_ISO","trigger":"scheduled","snapshotId":"abc123","filesNew":1,"filesChanged":0,"dataAdded":100,"errorSummary":null}
EOF
cat > "$HEALTHY/state/repo-status-$PRIMARY_ID.json" <<EOF
{"destId":"$PRIMARY_ID","reachable":true,"probedAt":"$NOW_ISO","lastSyncedAt":"$ONE_HOUR_AGO_ISO","lastError":null}
EOF
# `runs show` reads runs/<runId>/metadata.json, not the index line — needed
# for the `runs show r-healthy --json` assertion in step 5 below.
mkdir -p "$HEALTHY/runs/r-healthy"
cat > "$HEALTHY/runs/r-healthy/metadata.json" <<EOF
{"runId":"r-healthy","kind":"backup","setId":"$SET_ID","destId":"$PRIMARY_ID","groupId":"r-healthy","status":"success","trigger":"scheduled","start":"$ONE_HOUR_AGO_ISO","end":"$ONE_HOUR_AGO_ISO","pid":1,"resticExitCode":0,"argvRedacted":["restic","backup"],"snapshotId":"abc123","filesNew":1,"filesChanged":0,"dataAdded":100,"errorSummary":null,"stats":null}
EOF
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper status --json
capture_clean_status_rc
expect_rc "$CLEAN_STATUS_RC"
jq -e '
    .data |
    .sets[0].needsAttention == false
    and .sets[0].lastBackup.status == "success"
    and .health == (if .scheduler.healthy == false then "warning" else "idle" end)
' "$OUT_FILE" >/dev/null || fail "healthy fixture was not healthy apart from an independently reported scheduler finding"
ok "healthy fixture: backup state is idle; exit reflects the host scheduler"

# --- first backup grace: fresh config stays quiet; old never-run config warns. ---
FIRST_BACKUP_FRESH="$WORK/status-first-backup-fresh"
make_status_fixture "$FIRST_BACKUP_FRESH"
RESTIC_STATION_DATA_DIR="$FIRST_BACKUP_FRESH" run_helper status --json
capture_clean_status_rc
expect_rc "$CLEAN_STATUS_RC"
echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].firstBackupOverdue == false' >/dev/null \
    || fail "a fresh never-run set warned before its first-backup grace elapsed"

FIRST_BACKUP_OVERDUE="$WORK/status-first-backup-overdue"
make_status_fixture "$FIRST_BACKUP_OVERDUE"
# First load creates machine.json; aging both files exercises the exact mtime
# anchor production uses. POSIX `touch -t` works on macOS and Linux.
RESTIC_STATION_DATA_DIR="$FIRST_BACKUP_OVERDUE" run_helper config validate
expect_rc 0
touch -t 202001010000 "$FIRST_BACKUP_OVERDUE/config.json" "$FIRST_BACKUP_OVERDUE/machine.json"
RESTIC_STATION_DATA_DIR="$FIRST_BACKUP_OVERDUE" run_helper status --json
expect_rc 1
echo "$(cat "$OUT_FILE")" | jq -e '
    .data |
    .health == "warning"
    and .sets[0].lastBackup == null
    and .sets[0].firstBackupOverdue == true
' >/dev/null || fail "an old never-attempted set did not report its overdue first backup"
ok "first-backup grace: fresh config stays healthy; old never-attempted config warns"

# --- in-flight: a live current-run file, backed by a live run record. ---
# Both halves are required, and that is the point. A current-run file whose
# `runId` has no `runs/<runId>/metadata.json` with a live `pid` is precisely
# what a SIGKILL'd run leaves behind, so this fixture used to be
# indistinguishable from wreckage — it only "passed" because nothing checked.
# `pid: $$` is this script's own process: alive for as long as the assertion
# below takes, which is exactly the claim being made.
INFLIGHT="$WORK/status-inflight"
make_status_fixture "$INFLIGHT"
mkdir -p "$INFLIGHT/runs/r-live"
cat > "$INFLIGHT/runs/r-live/metadata.json" <<EOF
{"runId":"r-live","kind":"backup","setId":"$SET_ID","destId":"$PRIMARY_ID","groupId":"r-live","status":"running","trigger":"manual","start":"$NOW_ISO","end":null,"pid":$$,"resticExitCode":null,"argvRedacted":[],"snapshotId":null,"filesNew":null,"filesChanged":null,"dataAdded":null,"errorSummary":null,"stats":null}
EOF
cat > "$INFLIGHT/state/current-run-$SET_ID.json" <<EOF
{"runId":"r-live","kind":"backup","phase":"backing-up-primary","percentDone":0.42,"bytesDone":1234,"totalBytes":9999,"filesDone":3,"totalFiles":10,"currentFiles":["/tmp/src/big.dat"],"updatedAt":"$NOW_ISO"}
EOF
RESTIC_STATION_DATA_DIR="$INFLIGHT" run_helper status --json
capture_clean_status_rc
expect_rc "$CLEAN_STATUS_RC"
echo "$(cat "$OUT_FILE")" | jq -e '.data | .health == "running"' >/dev/null || fail "in-flight fixture did not report running"
echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].currentRun.phase == "backing-up-primary"' >/dev/null \
    || fail "in-flight fixture did not surface live progress"
echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].abandonedRun == null' >/dev/null \
    || fail "a live run was misreported as abandoned"
ok "in-flight fixture: health=running, live progress surfaced; exit reflects the host scheduler"

# --- stalled: the pid still exists, but the independent awake-time heartbeat
#     is stale. A negative fixture value is intentionally older than every
#     possible system uptime, keeping this test deterministic on fresh CI VMs. ---
STALLED="$WORK/status-stalled"
make_status_fixture "$STALLED"
mkdir -p "$STALLED/runs/r-stalled"
cat > "$STALLED/runs/r-stalled/metadata.json" <<EOF
{"runId":"r-stalled","kind":"backup","setId":"$SET_ID","destId":"$PRIMARY_ID","groupId":"r-stalled","status":"running","trigger":"manual","start":"$NOW_ISO","end":null,"pid":$$,"resticExitCode":null,"argvRedacted":[],"snapshotId":null,"filesNew":null,"filesChanged":null,"dataAdded":null,"errorSummary":null,"stats":null}
EOF
cat > "$STALLED/state/current-run-$SET_ID.json" <<EOF
{"runId":"r-stalled","kind":"backup","phase":"backing-up-primary","percentDone":0.42,"bytesDone":1234,"totalBytes":9999,"filesDone":3,"totalFiles":10,"currentFiles":["/tmp/src/big.dat"],"heartbeatAt":"$NOW_ISO","heartbeatUptime":-301,"updatedAt":"$NOW_ISO"}
EOF
RESTIC_STATION_DATA_DIR="$STALLED" run_helper status --json
expect_rc 1
jq -e '
    .data |
    .health == "warning"
    and .sets[0].isRunning == false
    and .sets[0].currentRun == null
    and .sets[0].stalledRun.runId == "r-stalled"
    and (.sets[0].stalledRunLog | endswith("/runs/r-stalled/log.txt"))
' "$OUT_FILE" >/dev/null || fail "stalled fixture was not reported as warning with its diagnostic log"
RESTIC_STATION_DATA_DIR="$STALLED" run_helper status
expect_rc 1
grep -qF "STALLED:     backup run r-stalled" "$OUT_FILE" \
    || fail "human status did not name the stalled run"
if grep -qF "current-run-$SET_ID.json" "$OUT_FILE"; then
    fail "human status suggested deleting a current-run file still owned by a stalled process"
fi
ok "stalled fixture: a live pid with a stale heartbeat is warning, not progress or safe wreckage"

# --- abandoned: the same progress file, with no live run behind it. ---
# The counterpart, and the regression this pairing guards: one SIGKILL'd run
# used to pin a host to health=running and exit 0 forever, because a
# current-run file's mere existence meant "in flight".
ABANDONED="$WORK/status-abandoned"
make_status_fixture "$ABANDONED"
cat > "$ABANDONED/state/current-run-$SET_ID.json" <<EOF
{"runId":"r-dead","kind":"backup","phase":"backing-up-primary","percentDone":0.42,"bytesDone":1234,"totalBytes":9999,"filesDone":3,"totalFiles":10,"currentFiles":["/tmp/src/big.dat"],"updatedAt":"$NOW_ISO"}
EOF
RESTIC_STATION_DATA_DIR="$ABANDONED" run_helper status --json
expect_rc 1
echo "$(cat "$OUT_FILE")" | jq -e '.data | .health == "warning"' >/dev/null \
    || fail "abandoned fixture did not report warning"
echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].isRunning == false' >/dev/null \
    || fail "abandoned fixture still reported the set as running"
echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].abandonedRun.runId == "r-dead"' >/dev/null \
    || fail "abandoned fixture did not name the abandoned run"
ok "abandoned fixture: status --json exits 1, health=warning, the dead run is named"

# --- unattributed: current-run files whose sets were deleted from config. ---
# These still determine global health and the exit code, so both a live and
# an abandoned one must remain visible even though `sets[]` has nowhere to
# carry them. A punctuation-heavy data dir red-checks the printed rm command.
UNATTRIBUTED="$WORK/status unattributed; safe"
make_status_fixture "$UNATTRIBUTED"
jq '.sets = []' "$UNATTRIBUTED/config.json" > "$UNATTRIBUTED/config.json.tmp"
mv "$UNATTRIBUTED/config.json.tmp" "$UNATTRIBUTED/config.json"
UNATTRIBUTED_LIVE_SET_ID="10000000-0000-4000-8000-000000000001"
UNATTRIBUTED_DEAD_SET_ID="20000000-0000-4000-8000-000000000002"
mkdir -p "$UNATTRIBUTED/runs/r-unattributed-live"
cat > "$UNATTRIBUTED/runs/r-unattributed-live/metadata.json" <<EOF
{"runId":"r-unattributed-live","kind":"backup","setId":"$UNATTRIBUTED_LIVE_SET_ID","destId":"$PRIMARY_ID","groupId":"r-unattributed-live","status":"running","trigger":"manual","start":"$NOW_ISO","end":null,"pid":$$,"resticExitCode":null,"argvRedacted":[],"snapshotId":null,"filesNew":null,"filesChanged":null,"dataAdded":null,"errorSummary":null,"stats":null}
EOF
cat > "$UNATTRIBUTED/state/current-run-$UNATTRIBUTED_LIVE_SET_ID.json" <<EOF
{"runId":"r-unattributed-live","kind":"backup","phase":"backing-up-primary","percentDone":0.25,"bytesDone":1,"totalBytes":4,"filesDone":1,"totalFiles":4,"currentFiles":[],"updatedAt":"$NOW_ISO"}
EOF
cat > "$UNATTRIBUTED/state/current-run-$UNATTRIBUTED_DEAD_SET_ID.json" <<EOF
{"runId":"r-unattributed-dead","kind":"backup","phase":"backing-up-primary","percentDone":0.5,"bytesDone":2,"totalBytes":4,"filesDone":2,"totalFiles":4,"currentFiles":[],"updatedAt":"$NOW_ISO"}
EOF
RESTIC_STATION_DATA_DIR="$UNATTRIBUTED" run_helper status --json
expect_rc 1
echo "$(cat "$OUT_FILE")" | jq -e '
    .data |
    (.sets | length) == 0
    and (.unattributedRuns | length) == 2
    and any(.unattributedRuns[]; .currentRun.runId == "r-unattributed-live" and .liveness == "live")
    and any(.unattributedRuns[]; .currentRun.runId == "r-unattributed-dead" and .liveness == "abandoned")
' >/dev/null || fail "unattributed live/abandoned runs were not both explained in JSON"
RESTIC_STATION_DATA_DIR="$UNATTRIBUTED" run_helper status
expect_rc 1
grep -qF "LIVE: backup run r-unattributed-live" "$OUT_FILE" \
    || fail "human status did not name the unattributed live run"
grep -qF "ABANDONED: backup run r-unattributed-dead" "$OUT_FILE" \
    || fail "human status did not name the unattributed abandoned run"
grep -qF "rm '$UNATTRIBUTED/state/current-run-$UNATTRIBUTED_DEAD_SET_ID.json'" "$OUT_FILE" \
    || fail "human status did not shell-quote the unattributed run cleanup path"
ok "unattributed fixture: live and abandoned runs explain global health in JSON and human output"

# --- failed: last backup failed. ---
FAILED="$WORK/status-failed"
make_status_fixture "$FAILED"
cat > "$FAILED/runs/index.jsonl" <<EOF
{"runId":"r-failed","kind":"backup","setId":"$SET_ID","destId":"$PRIMARY_ID","groupId":"r-failed","status":"failed","start":"$ONE_HOUR_AGO_ISO","end":"$ONE_HOUR_AGO_ISO","trigger":"scheduled","snapshotId":null,"filesNew":null,"filesChanged":null,"dataAdded":null,"errorSummary":"wrong password"}
EOF
RESTIC_STATION_DATA_DIR="$FAILED" run_helper status --json
expect_rc 1
echo "$(cat "$OUT_FILE")" | jq -e '.data | .health == "warning"' >/dev/null || fail "failed fixture did not report warning"
echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].needsAttention == true' >/dev/null \
    || fail "failed fixture's set was not flagged needsAttention"
ok "failed fixture: status --json exits 1, health=warning"

# --- stale-mirror: a successful backup once, but the destination hasn't
#     synced in far longer than stalenessWarningDays. ---
STALE="$WORK/status-stale"
make_status_fixture "$STALE"
LONG_AGO_TS=$(( $(date -u +%s) - 30*24*3600 ))
LONG_AGO_ISO=$(date -u -r "$LONG_AGO_TS" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
    || date -u -d "@$LONG_AGO_TS" +%Y-%m-%dT%H:%M:%S.000Z)
cat > "$STALE/runs/index.jsonl" <<EOF
{"runId":"r-stale","kind":"backup","setId":"$SET_ID","destId":"$PRIMARY_ID","groupId":"r-stale","status":"success","start":"$LONG_AGO_ISO","end":"$LONG_AGO_ISO","trigger":"scheduled","snapshotId":"abc123","filesNew":1,"filesChanged":0,"dataAdded":100,"errorSummary":null}
EOF
cat > "$STALE/state/repo-status-$PRIMARY_ID.json" <<EOF
{"destId":"$PRIMARY_ID","reachable":true,"probedAt":"$NOW_ISO","lastSyncedAt":"$LONG_AGO_ISO","lastError":null}
EOF
RESTIC_STATION_DATA_DIR="$STALE" run_helper status --json
expect_rc 1
echo "$(cat "$OUT_FILE")" | jq -e '.data | .health == "warning"' >/dev/null || fail "stale fixture did not report warning"
echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].destinations[0].stale == true' >/dev/null \
    || fail "stale fixture's destination was not flagged stale"
ok "stale-mirror fixture: status --json exits 1, health=warning, destination flagged stale"

# --- crowded-quiet-set: the configured set's own last run failed, but a
#     flood of newer runs from an unrelated set must not crowd it out of
#     whatever window `status` reads before deriving health (issue #29
#     finding 5). `--json`'s exit code is documented as a Nagios/Icinga
#     check, so a quiet set's failure being hidden behind busier ones — and
#     the exit code flipping back to 0 — is the worst failure mode
#     available here. ---
CROWDED="$WORK/status-crowded"
make_status_fixture "$CROWDED"
OTHER_SET_ID="20000000-0000-4000-8000-000000000099"
NOW_TS=$(date -u +%s)
{
    echo "{\"runId\":\"r-quiet-failed\",\"kind\":\"backup\",\"setId\":\"$SET_ID\",\"destId\":\"$PRIMARY_ID\",\"groupId\":\"r-quiet-failed\",\"status\":\"failed\",\"start\":\"$LONG_AGO_ISO\",\"end\":\"$LONG_AGO_ISO\",\"trigger\":\"scheduled\",\"snapshotId\":null,\"filesNew\":null,\"filesChanged\":null,\"dataAdded\":null,\"errorSummary\":\"wrong password\"}"
    for i in $(seq 1 205); do
        TS_EPOCH=$(( NOW_TS - 205 + i ))
        TS=$(date -u -r "$TS_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
            || date -u -d "@$TS_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)
        echo "{\"runId\":\"r-busy-$i\",\"kind\":\"backup\",\"setId\":\"$OTHER_SET_ID\",\"destId\":\"$PRIMARY_ID\",\"groupId\":\"r-busy-$i\",\"status\":\"success\",\"start\":\"$TS\",\"end\":\"$TS\",\"trigger\":\"scheduled\",\"snapshotId\":\"abc\",\"filesNew\":1,\"filesChanged\":0,\"dataAdded\":10,\"errorSummary\":null}"
    done
} > "$CROWDED/runs/index.jsonl"
RESTIC_STATION_DATA_DIR="$CROWDED" run_helper status --json
expect_rc 1
echo "$(cat "$OUT_FILE")" | jq -e '.data | .health == "warning"' >/dev/null \
    || fail "a quiet set's failed last run must not be hidden behind 200+ newer runs from another set"
echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].needsAttention == true' >/dev/null \
    || fail "the quiet, configured set was not flagged needsAttention despite its last run having failed"
ok "a quiet set's failed last run survives 200+ newer runs from another set — status --json exit code stays 1"

# ─────────────────────────────────────────────────────────────────────────
# 5. every --json mode is ONLY JSON on stdout (piped through jq).
# ─────────────────────────────────────────────────────────────────────────
log "5. --json output is parseable JSON with nothing else on stdout"

RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper status --json
capture_clean_status_rc
expect_rc "$CLEAN_STATUS_RC"
jq -e '.data | .machineId | length > 0' "$OUT_FILE" >/dev/null \
    || fail "status --json did not produce clean JSON"
RESTIC_STATION_DATA_DIR="$HEALTHY" "$HELPER" sets list --json | jq -e '.data | type == "array"' >/dev/null \
    || fail "sets list --json did not pipe cleanly through jq"
RESTIC_STATION_DATA_DIR="$HEALTHY" "$HELPER" runs list --json | jq -e '.data | type == "array"' >/dev/null \
    || fail "runs list --json did not pipe cleanly through jq"
RESTIC_STATION_DATA_DIR="$HEALTHY" "$HELPER" config show --json | jq -e '.data | .machineId | length > 0' >/dev/null \
    || fail "config show --json did not pipe cleanly through jq"
RESTIC_STATION_DATA_DIR="$HEALTHY" "$HELPER" runs show r-healthy --json | jq -e '.data | .runId == "r-healthy"' >/dev/null \
    || fail "runs show --json did not pipe cleanly through jq"
ok "status, sets list, runs list, runs show, config show --json all parse cleanly through jq"

# ─────────────────────────────────────────────────────────────────────────
# 6 (deferred to the end) + 7. Exit-code contract spot checks.
# ─────────────────────────────────────────────────────────────────────────
log "7. exit-code contract spot checks (0 ok, 1 error)"

RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper runs show "no-such-run-id-at-all"
expect_rc 1
ok "runs show <unknown runId> → exit 1"

RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper runs list --limit 0
expect_rc 1
ok "runs list --limit 0 → exit 1 (ArgumentParser validation)"

BROKEN_CONFIG_DATA="$WORK/broken-config-data"
mkdir -p "$BROKEN_CONFIG_DATA"
echo 'not valid json{{{' > "$BROKEN_CONFIG_DATA/config.json"
RESTIC_STATION_DATA_DIR="$BROKEN_CONFIG_DATA" run_helper config validate
expect_rc 1
grep -q 'Errors:' "$OUT_FILE" || fail "an unloadable config should still print an Errors: section before exiting 1"
RESTIC_STATION_DATA_DIR="$BROKEN_CONFIG_DATA" run_helper status
expect_rc 1
RESTIC_STATION_DATA_DIR="$BROKEN_CONFIG_DATA" run_helper sets list
expect_rc 1
ok "an unloadable config.json → exit 1 for config validate, status, sets list"

RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper config validate
expect_rc 0
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper status
expect_rc "$CLEAN_STATUS_RC"
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper sets list
expect_rc 0
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper runs list
expect_rc 0
ok "a healthy, well-formed setup → commands succeed; status exit independently reflects the host scheduler"

# ─────────────────────────────────────────────────────────────────────────
# The real-restic half: secret set/list, a real run-set, status reflecting
# it — skipped (not failed) when restic is not on PATH, matching
# scripts/secret-cli-test.sh's convention.
# ─────────────────────────────────────────────────────────────────────────
log "real restic: secret set → run-set → status reflects a real backup"

RESTIC_BIN="$(command -v restic || true)"
if [[ -z "$RESTIC_BIN" ]]; then
    echo "restic not on PATH — skipping the real-backup half"
else
    export RESTIC_STATION_SECRET_BACKEND=file
    REAL_DATA="$WORK/real-data"
    mkdir -p "$REAL_DATA" "$WORK/real-source"
    echo "hello" > "$WORK/real-source/a.txt"
    cat > "$REAL_DATA/config.json" <<EOF
{
  "version": 3,
  "resticPath": "$RESTIC_BIN",
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$SET_ID",
      "name": "Projects",
      "sources": ["$WORK/real-source"],
      "excludes": [],
      "purgeExcludes": [],
      "schedule": {"kind": "everyMinutes", "minutes": 5},
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 14,
      "destinations": [
        {"id": "$PRIMARY_ID", "label": "Primary", "repoURL": "$WORK/real-repo", "isPrimary": true, "nonSecretEnv": {}}
      ]
    }
  ]
}
EOF
    # `VAR=val cmd1 | cmd2` only scopes VAR to cmd1 — a real bug here would
    # point the helper at the process's ambient default data directory
    # instead of the sandboxed one, which is exactly what
    # RESTIC_STATION_DATA_DIR exists to prevent. `export` for the whole
    # pipeline instead.
    export RESTIC_STATION_DATA_DIR="$REAL_DATA"
    printf '%s' "$SECRET_PASSWORD" | "$HELPER" secret set --dest "$PRIMARY_ID" >>"$COMBINED_LOG" 2>&1
    run_helper secret list
    expect_rc 0
    if grep -qF -- "$SECRET_PASSWORD" "$OUT_FILE"; then fail "secret list leaked the password"; fi

    # The engine does not auto-init a primary — the app / `restic init`
    # does. Init it directly with the real binary, via the SAME
    # RESTIC_PASSWORD_COMMAND the engine itself will use for the backup
    # below (matching scripts/secret-cli-test.sh step 7's proven pattern) —
    # not a plain RESTIC_PASSWORD env var. restic's key derivation is not
    # guaranteed to treat the two sources identically for a password with
    # trailing whitespace, and using the env var here produced a real
    # "wrong password" failure against a password store that
    # print-password proved byte-identical: the mismatch was between
    # restic's own env-var and password-command handling, not this repo's
    # code — reusing the exact mechanism the engine uses sidesteps it.
    PRIMARY_ID_LOWER="$(printf '%s' "$PRIMARY_ID" | tr '[:upper:]' '[:lower:]')"
    # restic runs RESTIC_PASSWORD_COMMAND through a shell, so a helper path
    # containing a space (the app bundle's "Restic Station.app") must be
    # quoted — the same rule scripts/secret-cli-test.sh's step 7 documents
    # and applies.
    if [[ "$HELPER" =~ ^[A-Za-z0-9/._+=:,@-]+$ ]]; then
        PWCMD="$HELPER print-password --dest $PRIMARY_ID_LOWER"
    else
        PWCMD="\"$HELPER\" print-password --dest $PRIMARY_ID_LOWER"
    fi
    RESTIC_PASSWORD_COMMAND="$PWCMD" "$RESTIC_BIN" -r "$WORK/real-repo" init --json >>"$COMBINED_LOG" 2>&1

    RESTIC_STATION_DATA_DIR="$REAL_DATA" run_helper run-set --set "$SET_ID" --kind backup
    expect_rc 0

    RESTIC_STATION_DATA_DIR="$REAL_DATA" run_helper status --json
    capture_clean_status_rc
    expect_rc "$CLEAN_STATUS_RC"
    echo "$(cat "$OUT_FILE")" | jq -e '.data | .sets[0].lastBackup.status == "success"' >/dev/null \
        || fail "status did not reflect the real backup that just ran"
    ok "a real run-set backup is reflected by status --json"

    RESTIC_STATION_DATA_DIR="$REAL_DATA" run_helper config export --out "$WORK/real-exported.json"
    if grep -qF -- "$SECRET_PASSWORD" "$WORK/real-exported.json"; then
        fail "config export leaked the password into the exported config"
    fi
    ok "config export of a set with a stored password does not leak it"
    unset RESTIC_STATION_DATA_DIR
fi

# ─────────────────────────────────────────────────────────────────────────
# 8. The --json error envelope (issue #81, docs/cli-json.md).
#
#    Before this, a --json command that failed wrote prose to stderr and
#    left stdout completely empty — a caller that had already committed to
#    `jq` got nothing at all. What is asserted here is the part the Swift
#    tests cannot reach: the real binary's real streams and real exit codes.
# ─────────────────────────────────────────────────────────────────────────
log "8. --json failures emit one error envelope on stdout"

ENVELOPE_DATA="$WORK/envelope-data"
mkdir -p "$ENVELOPE_DATA"
echo 'not valid json{{{' > "$ENVELOPE_DATA/config.json"

# `runs list` is deliberately absent: it reads only runs/index.jsonl and
# never loads config.json, so an unloadable config is not a failure for it —
# it correctly reports an empty history and exits 0. Its own failure path is
# asserted separately below.
# `secret list` is in this loop because its setup path is a *different* one:
# it does not go through `HelperContext.make()` at all (entering a password
# must work before restic is configured), so it had its own `HelperExit.fail`
# and answered a broken config with an empty stdout long after the other
# commands stopped doing that.
for CMD in "status" "sets list" "config show" "secret list"; do
    # shellcheck disable=SC2086
    RESTIC_STATION_DATA_DIR="$ENVELOPE_DATA" run_helper_split $CMD --json
    expect_rc 1
    jq -e . "$OUT_FILE" >/dev/null 2>&1 \
        || fail "\`$CMD --json\` on a broken config did not put one JSON document on stdout"
    [[ "$(jq -r '.error.code' "$OUT_FILE")" == "config_invalid" ]] \
        || fail "\`$CMD --json\` reported $(jq -r '.error.code' "$OUT_FILE"), expected config_invalid"
    [[ "$(jq -r '.ok' "$OUT_FILE")" == "false" ]] || fail "\`$CMD --json\` did not set ok=false"
    [[ "$(jq -r '.schemaVersion' "$OUT_FILE")" == "1" ]] || fail "\`$CMD --json\` did not pin schemaVersion 1"
    [[ "$(jq -r '.error.retryable' "$OUT_FILE")" == "false" ]] \
        || fail "\`$CMD --json\` marked an invalid config retryable"
done
ok "every --json command reports an unloadable config.json as config_invalid, exit 1"

# Purge has required operands, so it cannot share the no-argument loop
# above. These two calls pin the setup path instead: `HelperContext.make()`
# must surface a broken config as the usual envelope before a read-only
# preview or a token-gated apply can touch a repository.
for CMD in \
    "purge preview --set 6F9619FF-8B86-D011-B42D-00C04FC964FF" \
    "maintenance prune --set 6F9619FF-8B86-D011-B42D-00C04FC964FF --dry-run"; do
    # shellcheck disable=SC2086
    RESTIC_STATION_DATA_DIR="$ENVELOPE_DATA" run_helper_split $CMD --json
    expect_rc 1
    jq -e '.ok == false and .error.code == "config_invalid"' "$OUT_FILE" >/dev/null \
        || fail "\`$CMD --json\` on a broken config did not emit config_invalid"
done
CAPABILITY_CANARY='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
RESTIC_STATION_DATA_DIR="$ENVELOPE_DATA" run_helper_split_stdin "$CAPABILITY_CANARY" \
    purge apply --set 6F9619FF-8B86-D011-B42D-00C04FC964FF --preview-token-stdin --json
expect_rc 1
jq -e '.ok == false and .error.code == "config_invalid"' "$OUT_FILE" >/dev/null \
    || fail "purge apply --json on a broken config did not emit config_invalid after bounded stdin parsing"
ok "purge and maintenance prune --json preserve the setup-failure envelope"

# `config validate --json` has a second setup failure of its own: with no
# `--machine`, the answer comes from this host's `machine.json`, and an
# unreadable one used to exit with prose rather than an envelope. The config
# here is *valid* — this is specifically the identity path, not the config
# path the loop above covers.
MACHINE_DATA="$WORK/bad-machine"
mkdir -p "$MACHINE_DATA"
cp "$HEALTHY/config.json" "$MACHINE_DATA/config.json"
echo 'not valid json{{{' > "$MACHINE_DATA/machine.json"
RESTIC_STATION_DATA_DIR="$MACHINE_DATA" run_helper_split config validate --json
expect_rc 1
jq -e . "$OUT_FILE" >/dev/null 2>&1 \
    || fail "config validate --json on an unreadable machine.json put no JSON document on stdout"
[[ "$(jq -r '.error.code' "$OUT_FILE")" == "config_invalid" ]] \
    || fail "config validate --json reported $(jq -r '.error.code' "$OUT_FILE") for an unreadable machine.json"
jq -e '.error.message | test("machine")' "$OUT_FILE" >/dev/null \
    || fail "the envelope did not say which file it was: $(jq -r '.error.message' "$OUT_FILE")"
ok "config validate --json reports an unreadable machine.json as config_invalid, exit 1"

# `runs list`'s own classified failure: its --limit check is hand-written
# rather than an ArgumentParser `validate()` throw, specifically so it exits
# 1 rather than 64. That makes it the one invalid_arguments case carrying the
# ordinary exit code, and both halves are worth pinning.
run_helper_split runs list --limit 0 --json
expect_rc 1
[[ "$(jq -r '.error.code' "$OUT_FILE")" == "invalid_arguments" ]] \
    || fail "runs list --limit 0 --json did not report invalid_arguments"
ok "runs list --limit 0 --json is invalid_arguments at exit 1, not exit 64"

# `runs show` takes an operand, so it is spelled out rather than folded into
# the loop above — and it exercises a different code on the way.
RESTIC_STATION_DATA_DIR="$ENVELOPE_DATA" run_helper_split runs show no-such-run-id --json
expect_rc 1
[[ "$(jq -r '.error.code' "$OUT_FILE")" == "run_not_found" ]] \
    || fail "runs show <unknown> --json did not report run_not_found"
[[ "$(jq -r '.error.details.runId' "$OUT_FILE")" == "no-such-run-id" ]] \
    || fail "run_not_found did not carry the runId in details"
ok "runs show <unknown-id> --json reports run_not_found with the id in details"

# Human mode is unchanged: prose on stderr, nothing on stdout, same code.
RESTIC_STATION_DATA_DIR="$ENVELOPE_DATA" run_helper_split sets list
expect_rc 1
[[ ! -s "$OUT_FILE" ]] || fail "human mode wrote to stdout on failure"
grep -q 'could not load configuration' "$ERR_FILE" \
    || fail "human mode stopped printing the load error to stderr"
ok "human mode still writes prose to stderr and leaves stdout empty"

# An argument-parser failure never reaches run(), so only the custom main()
# can classify it. Both modes must agree on the exit code — ArgumentParser's
# own EX_USAGE (64), not the 1 that invalid_arguments otherwise implies.
run_helper_split runs show --json
expect_rc 64
jq -e '.error.code == "invalid_arguments"' "$OUT_FILE" >/dev/null \
    || fail "a parse failure in --json mode did not produce an invalid_arguments envelope"
run_helper_split runs show
expect_rc 64
[[ ! -s "$OUT_FILE" ]] || fail "a parse failure in human mode wrote to stdout"
ok "a parse failure is invalid_arguments in --json mode and keeps exit 64 in both modes"

# --help is a clean exit, not a failure, whatever mode was asked for.
run_helper_split status --json --help
expect_rc 0
grep -q 'OVERVIEW' "$OUT_FILE" || fail "--json --help stopped printing help"
ok "--json --help still prints help and exits 0"

# THE TRAP: `status --json` exits 1 when health is warning. That is a
# successful report with a nonzero exit — a Nagios/Icinga check — and must
# stay a StatusReport, never an error envelope.
RESTIC_STATION_DATA_DIR="$FAILED" run_helper_split status --json
expect_rc 1
jq -e '.data | .sets' "$OUT_FILE" >/dev/null \
    || fail "status --json stopped emitting a report when health is warning"
jq -e 'has("error") | not' "$OUT_FILE" >/dev/null \
    || fail "status --json turned a warning-level report into an error envelope"
ok "status --json exit 1 on a warning is still a report, not an error envelope"

# ─────────────────────────────────────────────────────────────────────────
# 9. The success envelope, across every --json command (issue #79).
#
#    The Swift suite checks that each of these conforms to JSONRenderable;
#    what only a real process can show is that stdout carries exactly one
#    envelope and nothing else — no progress prose, no warning line, no
#    ANSI. Stdout and stderr are captured separately for that reason.
# ─────────────────────────────────────────────────────────────────────────
log "9. every --json command emits one success envelope on stdout"

# `probe-repo` is deliberately absent from this loop and handled below:
# it is the only command here that must resolve a usable restic before it
# can produce any report at all, so on a host without one its correct
# output is an error envelope, not a success. The `linux` CI job is exactly
# such a host.
ENVELOPE_CMDS=(
    "version"
    "status"
    "sets list"
    "runs list"
    "runs show r-healthy"
    "config show"
    "config validate"
    "secret list"
    "cli status"
    "fda-check"
)

for CMD in "${ENVELOPE_CMDS[@]}"; do
    # shellcheck disable=SC2086
    RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper_split $CMD --json
    jq -e . "$OUT_FILE" >/dev/null 2>&1 \
        || fail "\`$CMD --json\` did not put exactly one JSON document on stdout: $(cat "$OUT_FILE")"
    [[ "$(jq -r '.ok' "$OUT_FILE")" == "true" ]] \
        || fail "\`$CMD --json\` did not report ok=true (got $(jq -c '.' "$OUT_FILE"))"
    [[ "$(jq -r '.schemaVersion' "$OUT_FILE")" == "1" ]] \
        || fail "\`$CMD --json\` did not pin schemaVersion 1"
    jq -e 'has("data")' "$OUT_FILE" >/dev/null \
        || fail "\`$CMD --json\` emitted no data key"
    # The three envelope keys and nothing else: a command that leaks an
    # extra top-level field has escaped CLIJSON.
    [[ "$(jq -r 'keys | join(",")' "$OUT_FILE")" == "data,ok,schemaVersion" ]] \
        || fail "\`$CMD --json\` has unexpected top-level keys: $(jq -r 'keys | join(",")' "$OUT_FILE")"
done
ok "all ${#ENVELOPE_CMDS[@]} restic-independent --json commands emit {schemaVersion, ok, data} and nothing else"

# The payload each one actually carries, spot-checked so the envelope test
# above cannot pass on an empty or wrong `data`.
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper_split version --json
[[ "$(jq -r '.data.name' "$OUT_FILE")" == "restic-station-helper" ]] || fail "version --json lost its name"
[[ -n "$(jq -r '.data.platform' "$OUT_FILE")" ]] || fail "version --json did not name a platform"

# probe-repo, on both kinds of host.
#
# With a usable restic its *outcome mapping* is what gets pinned, not one
# outcome — whether the fixture's repository path happens to exist is not
# this test's subject. Every outcome is a success envelope, and the exit
# code is the coarse shell signal for the same fact; an offline destination
# reported as an error envelope would make a sleeping NAS look like a
# broken config.
#
# Without one, `HelperContext.make()` fails before any probe happens and
# restic_not_found is the correct answer. Asserting that rather than
# skipping keeps the no-restic host covered instead of silently untested.
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper_split probe-repo --set "$SET_ID" --dest "$PRIMARY_ID" --json
PROBE_RC="$RC"
# Branch on what the helper actually reported, not on `command -v restic`:
# discovery also searches well-known absolute paths, so a host can have a
# usable restic that is not on PATH and the two would disagree.
if [[ "$(jq -r '.ok' "$OUT_FILE")" == "false" ]]; then
    # The only legitimate failures here are the two that mean "no usable
    # restic". Any other code is a regression, not an environment.
    PROBE_CODE="$(jq -r '.error.code' "$OUT_FILE")"
    case "$PROBE_CODE" in
        restic_not_found|restic_unsupported) ;;
        *) fail "probe-repo --json failed with $PROBE_CODE, which is not a restic-availability problem" ;;
    esac
    [[ "$PROBE_RC" -eq 1 ]] || fail "$PROBE_CODE must exit 1, got $PROBE_RC"
    ok "probe-repo --json on a host with no usable restic reports $PROBE_CODE, exit 1"
else
    PROBE_OUTCOME="$(jq -r '.data.outcome' "$OUT_FILE")"
    [[ "$(jq -r '.ok' "$OUT_FILE")" == "true" ]] \
        || fail "probe-repo --json reported an error envelope for outcome=$PROBE_OUTCOME"
    case "$PROBE_OUTCOME" in
        reachable) [[ "$PROBE_RC" -eq 0 ]] || fail "probe-repo reachable must exit 0, got $PROBE_RC" ;;
        offline)   [[ "$PROBE_RC" -eq 3 ]] || fail "probe-repo offline must exit 3, got $PROBE_RC" ;;
        error)     [[ "$PROBE_RC" -eq 1 ]] || fail "probe-repo error must exit 1, got $PROBE_RC" ;;
        *)         fail "probe-repo --json reported an unknown outcome: $PROBE_OUTCOME" ;;
    esac
    [[ "$(jq -r '.data.reachable' "$OUT_FILE")" == "$([[ "$PROBE_OUTCOME" == "reachable" ]] && echo true || echo false)" ]] \
        || fail "probe-repo's reachable flag disagrees with its outcome"
    # The optional field is present as an explicit null, never omitted.
    jq -e 'has("reason")' <<<"$(jq -c '.data' "$OUT_FILE")" >/dev/null \
        || fail "probe-repo --json omitted the reason key instead of encoding null"
    ok "probe-repo --json maps every outcome to a success envelope and its exit code"
fi

RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper_split config validate --json
[[ "$(jq -r '.data.nothingRunsHere' "$OUT_FILE")" == "false" ]] \
    || fail "config validate --json did not report that something runs here"
jq -e '.data.effective.sets | length >= 1' "$OUT_FILE" >/dev/null \
    || fail "config validate --json carried no effective plan"

# secret list reports presence, never values — the reason it can have a JSON
# mode at all. Asserted structurally, not just by the end-of-run grep.
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper_split secret list --json
jq -e '[.data[] | keys] | flatten | unique | inside(["destId","label","setName","hasPassword","secretEnvCount"])' \
    "$OUT_FILE" >/dev/null \
    || fail "secret list --json grew a field beyond presence metadata: $(jq -c '.data' "$OUT_FILE")"
# Both modes list the same destinations. JSON mode used to serialize every
# configured destination, including the ones with nothing stored, while
# human mode filtered them — so an empty store answered `[]` to a person
# and a full array of "has nothing" rows to a script.
jq -e 'all(.data[]; .hasPassword or .secretEnvCount > 0)' "$OUT_FILE" >/dev/null \
    || fail "secret list --json listed a destination with nothing stored: $(jq -c '.data' "$OUT_FILE")"
# Nothing is stored in this fixture, so both modes must say so — `[]` and
# the sentence, not a row per configured destination.
[[ "$(jq -r '.data | length' "$OUT_FILE")" -eq 0 ]] \
    || fail "secret list --json listed destinations from a store with nothing in it: $(jq -c '.data' "$OUT_FILE")"
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper_split secret list
grep -q "no destination has a stored password" "$OUT_FILE" \
    || fail "secret list (human) did not report an empty store: $(cat "$OUT_FILE")"

# ...and with one stored, both modes list exactly it. The two counts are
# what caught the divergence: JSON mode served every configured destination
# while human mode filtered, so the modes disagreed about the result set.
printf '%s' "$SECRET_PASSWORD" \
    | RESTIC_STATION_DATA_DIR="$HEALTHY" "$HELPER" secret set --dest "$PRIMARY_ID" >>"$COMBINED_LOG" 2>&1 \
    || fail "could not store a password in the healthy fixture"
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper_split secret list --json
JSON_ROWS="$(jq -r '.data | length' "$OUT_FILE")"
[[ "$JSON_ROWS" -eq 1 ]] || fail "secret list --json listed $JSON_ROWS destinations, expected 1"
jq -e --arg id "$PRIMARY_ID" '.data[0] | .destId == $id and .hasPassword' "$OUT_FILE" >/dev/null \
    || fail "secret list --json did not report the stored password: $(jq -c '.data' "$OUT_FILE")"
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper_split secret list
HUMAN_ROWS="$(grep -c "$PRIMARY_ID" "$OUT_FILE" || true)"
[[ "$JSON_ROWS" -eq "$HUMAN_ROWS" ]] \
    || fail "secret list listed $HUMAN_ROWS destinations to a human and $JSON_ROWS to a script"
RESTIC_STATION_DATA_DIR="$HEALTHY" "$HELPER" secret rm --dest "$PRIMARY_ID" >>"$COMBINED_LOG" 2>&1 \
    || fail "could not remove the fixture password again"
ok "payloads carry what they claim, secret list --json stays presence-only and agrees with human mode"

# ─────────────────────────────────────────────────────────────────────────
# 10. #110: a machine that cannot take its own locks must not look idle.
#
#     The unit tests prove `FileLock` tells contention apart from breakage
#     and that the engine records the fault. Only a real process can show
#     the end of that chain: `tick` exiting non-zero so launchd/systemd sees
#     a failing unit, and `status --json` refusing to report a healthy,
#     idle machine. That is the pair the issue's acceptance criteria name.
#
#     The fault is a *directory* where `locks/tick.lock` belongs. Root
#     ignores file modes — and the `linux` CI job runs as root — so a
#     chmod-based denial would pass there for the wrong reason. A directory
#     cannot be opened as a regular file by anyone, root included. Same
#     reasoning as the run-index step in ci.yml.
# ─────────────────────────────────────────────────────────────────────────
log "10. broken locking is never reported as a healthy, idle machine"

# A fresh install under either a permissive or maximally restrictive service
# umask must not manufacture a lock tree that it then rejects or cannot reopen.
# Run the real helper in a subshell because umask is process-global. Pre-create
# output files so umask 0777 cannot make the test harness's captures unreadable.
for TEST_UMASK in 0000 0777; do
    UMASK_DATA="$WORK/umask-$TEST_UMASK-data"
    UMASK_OUT="$WORK/umask-$TEST_UMASK-status.json"
    UMASK_ERR="$WORK/umask-$TEST_UMASK-status.err"
    : >"$UMASK_OUT"
    : >"$UMASK_ERR"
    # Prime only the machine identity outside the test umask, then remove the
    # generated internal directories. MachineStore's independent permission
    # contract is outside this locking regression; both restrictive-umask
    # attempts below must create and then reopen the lock tree themselves.
    set +e
    RESTIC_STATION_DATA_DIR="$UMASK_DATA" \
        "$HELPER" status --json >"$UMASK_OUT" 2>"$UMASK_ERR"
    set -e
    rm -r "$UMASK_DATA/runs" "$UMASK_DATA/state" "$UMASK_DATA/locks"
    for UMASK_ATTEMPT in 1 2; do
        set +e
        (
            umask "$TEST_UMASK"
            RESTIC_STATION_DATA_DIR="$UMASK_DATA" \
                "$HELPER" status --json >"$UMASK_OUT" 2>"$UMASK_ERR"
        )
        UMASK_RC=$?
        set -e
        cat "$UMASK_OUT" "$UMASK_ERR" >>"$COMBINED_LOG"
        jq -e '.data.locking.usable == true' "$UMASK_OUT" >/dev/null \
            || fail "umask-$TEST_UMASK status attempt $UMASK_ATTEMPT rejected its lock tree: $(cat "$UMASK_OUT")"
        # Scheduler health can independently make status exit 1; only a
        # parser/setup failure may use another code here.
        [[ "$UMASK_RC" -eq 0 || "$UMASK_RC" -eq 1 ]] \
            || fail "umask-$TEST_UMASK status attempt $UMASK_ATTEMPT exited $UMASK_RC"
    done
    for directory in \
        "$UMASK_DATA" \
        "$UMASK_DATA/runs" \
        "$UMASK_DATA/state" \
        "$UMASK_DATA/locks"; do
        if [[ "$(uname -s)" == "Darwin" ]]; then
            DIRECTORY_MODE="$(stat -f '%Lp' "$directory")"
        else
            DIRECTORY_MODE="$(stat -c '%a' "$directory")"
        fi
        [[ "$DIRECTORY_MODE" == "700" ]] \
            || fail "$directory was mode $DIRECTORY_MODE after setup under umask $TEST_UMASK, expected 700"
    done
    for lock_file in \
        "$UMASK_DATA/locks/health.lock" \
        "$UMASK_DATA/state/health.lock" \
        "$UMASK_DATA/runs/health.lock"; do
        if [[ "$(uname -s)" == "Darwin" ]]; then
            LOCK_MODE="$(stat -f '%Lp' "$lock_file")"
        else
            LOCK_MODE="$(stat -c '%a' "$lock_file")"
        fi
        [[ "$LOCK_MODE" == "600" ]] \
            || fail "$lock_file was mode $LOCK_MODE after setup under umask $TEST_UMASK, expected 600"
    done
done
ok "fresh lock trees stay reusable at 0700/0600 under umasks 0000 and 0777"

BROKEN_LOCKS="$WORK/broken-locks"
mkdir -p "$BROKEN_LOCKS/locks/tick.lock"

RESTIC_STATION_DATA_DIR="$BROKEN_LOCKS" run_helper tick
[[ "$RC" -ne 0 ]] \
    || fail "tick exited 0 on a tick lock it could not use — the silent-stoppage bug (#110)"
grep -q "could not acquire the tick lock" "$OUT_FILE" \
    || fail "tick did not say which lock it could not use: $(cat "$OUT_FILE")"
ok "tick exits non-zero and names the lock, instead of exiting 0 like a busy tick"

# Break the audit gate too. Its verifier runs before the shared lock-health
# probe; status must still emit the documented StatusReport rather than a
# generic internal-error envelope when that early acquisition fails.
mkdir -p "$BROKEN_LOCKS/locks/destructive-audit.lock"
RESTIC_STATION_DATA_DIR="$BROKEN_LOCKS" run_helper_split status --json
[[ "$RC" -ne 0 ]] \
    || fail "status --json exited 0 on a machine that cannot take a lock"
[[ "$(jq -r '.data.locking.usable' "$OUT_FILE")" == "false" ]] \
    || fail "status --json did not report locking as unusable: $(jq -c '.data.locking' "$OUT_FILE")"
[[ "$(jq -r '.data.health' "$OUT_FILE")" == "warning" ]] \
    || fail "status --json reported health $(jq -r '.data.health' "$OUT_FILE"), expected warning"
jq -e '.data.locking | has("problem") and .problem != null' "$OUT_FILE" >/dev/null \
    || fail "status --json did not name the specific fault"
ok "status --json reports locking.usable false, health warning, and exits non-zero"

RESTIC_STATION_DATA_DIR="$BROKEN_LOCKS" run_helper status
grep -q "NOTHING CAN RUN ON THIS MACHINE" "$OUT_FILE" \
    || fail "human status did not state the locking failure plainly: $(cat "$OUT_FILE")"
ok "human status states it plainly, above the scheduler line"

# #117 review: a hostile *per-set* lock, with `locks/` and `tick.lock` both
# perfectly usable. The set can never run again, so neither the tick nor
# status may report success — previously the tick printed the failure and
# exited 0, and the live probe only ever looked at `tick.lock`.
BROKEN_SET_LOCK="$WORK/broken-set-lock"
mkdir -p "$BROKEN_SET_LOCK"
cp -R "$HEALTHY/." "$BROKEN_SET_LOCK/" 2>/dev/null || true
SET_UUID="$(RESTIC_STATION_DATA_DIR="$BROKEN_SET_LOCK" "$HELPER" sets list --json 2>/dev/null \
    | jq -r '.data[0].id' 2>/dev/null || true)"
if [[ -n "$SET_UUID" && "$SET_UUID" != "null" ]]; then
    # Pin an executable path for this fixture. The set lock must reject the
    # check before that path can ever launch, but `tick` resolves its
    # configured binary before constructing the engine. `/usr/bin/restic`
    # exists on the local macOS runner and not in the Linux CI container,
    # which previously made this assertion test discovery instead of locks.
    jq --arg restic_path "$HELPER" '.resticPath = $restic_path' \
        "$BROKEN_SET_LOCK/machine.json" > "$BROKEN_SET_LOCK/machine.json.tmp"
    mv "$BROKEN_SET_LOCK/machine.json.tmp" "$BROKEN_SET_LOCK/machine.json"
    mkdir -p "$BROKEN_SET_LOCK/locks/set-$SET_UUID.lock"
    RESTIC_STATION_DATA_DIR="$BROKEN_SET_LOCK" run_helper_split status --json
    [[ "$RC" -ne 0 ]] \
        || fail "status --json exited 0 with an unusable per-set lock"
    [[ "$(jq -r '.data.locking.usable' "$OUT_FILE")" == "false" ]] \
        || fail "status --json missed a hostile per-set lock: $(jq -c '.data.locking' "$OUT_FILE")"
    grep -q "$SET_UUID" <<<"$(jq -r '.data.locking.problem' "$OUT_FILE")" \
        || fail "status --json did not name the offending set lock"
    [[ "$(jq -r '.data.locking.scope' "$OUT_FILE")" == "set" ]] \
        || fail "status --json did not scope the lock fault to one set: $(jq -c '.data.locking' "$OUT_FILE")"
    LOWER_SET_UUID="$(printf '%s' "$SET_UUID" | tr '[:upper:]' '[:lower:]')"
    [[ "$(jq -r '.data.locking.setId' "$OUT_FILE" | tr '[:upper:]' '[:lower:]')" == "$LOWER_SET_UUID" ]] \
        || fail "status --json did not identify the affected set: $(jq -c '.data.locking' "$OUT_FILE")"
    ok "a hostile per-set lock is reported even when locks/ and tick.lock are fine"

    RESTIC_STATION_DATA_DIR="$BROKEN_SET_LOCK" run_helper status
    grep -q "ONE OR MORE BACKUP SETS CANNOT RUN" "$OUT_FILE" \
        || fail "human status did not classify the per-set lock as a partial outage: $(cat "$OUT_FILE")"
    ! grep -q "NOTHING CAN RUN ON THIS MACHINE" "$OUT_FILE" \
        || fail "human status incorrectly classified one broken set as a machine-wide outage"
    ok "human status scopes a hostile set lock without claiming the whole machine is stopped"

    # Make only the check due: a fresh backup timestamp suppresses the
    # backup, while a nil check timestamp fires immediately. This pins the
    # separate check outcome path that used to print `failed` and exit 0.
    jq '.sets[0].checkPolicy = {"enabled": true, "readDataSubsetSlices": 20}' \
        "$BROKEN_SET_LOCK/config.json" > "$BROKEN_SET_LOCK/config.json.tmp"
    mv "$BROKEN_SET_LOCK/config.json.tmp" "$BROKEN_SET_LOCK/config.json"
    cat > "$BROKEN_SET_LOCK/state/schedule-state.json" <<EOF
{"sets":{"$SET_UUID":{"lastBackupStart":"$NOW_ISO","lastCheckStart":null,"checkSliceCursor":null,"checkCount":null,"appliedPurgeExcludes":{}}}}
EOF
    printf '%s\n' "$SECRET_PASSWORD" \
        | RESTIC_STATION_DATA_DIR="$BROKEN_SET_LOCK" "$HELPER" secret set --dest "$PRIMARY_ID" \
            >>"$COMBINED_LOG" 2>&1 \
        || fail "could not seed the due-check fixture's password"
    RESTIC_STATION_DATA_DIR="$BROKEN_SET_LOCK" run_helper tick
    [[ "$RC" -ne 0 ]] \
        || fail "tick exited 0 when a due check could not use its set lock: $(cat "$OUT_FILE")"
    grep -q 'check cannot run here' "$OUT_FILE" \
        || fail "tick did not classify the due check as infrastructure failure: $(cat "$OUT_FILE")"
    ok "a due check with an unusable set lock makes tick exit non-zero"
else
    echo "  (skipped per-set lock assertion: could not resolve a set id from the fixture)"
fi

# The control: the same commands on a healthy fixture must not trip any of
# the above. A check that fires everywhere is not a check.
RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper_split status --json
[[ "$(jq -r '.data.locking.usable' "$OUT_FILE")" == "true" ]] \
    || fail "a healthy fixture was reported as having unusable locking"
[[ "$(jq -r '.data.locking.problem' "$OUT_FILE")" == "null" ]] \
    || fail "a healthy fixture reported a locking problem"
ok "a healthy data directory still reports usable locking and no problem"

# ─────────────────────────────────────────────────────────────────────────
# 6. Capability transport: retired argv forms must fail redacted at EX_USAGE,
#    while selected stdin input stays out of the observable child argv.
# ─────────────────────────────────────────────────────────────────────────
log "6. capability transport is redacted and stdin-bound"

assert_legacy_capability_rejected() {
    local mode="$1"
    shift
    run_helper_split "$@"
    expect_rc 64
    ! grep -qF -- "$CAPABILITY_CANARY" "$OUT_FILE" "$ERR_FILE" \
        || fail "legacy capability rejection reflected its supplied value"
    if [[ "$mode" == json ]]; then
        jq -e '.ok == false and .error.code == "invalid_arguments"' "$OUT_FILE" >/dev/null \
            || fail "legacy capability rejection in JSON mode did not emit invalid_arguments"
    else
        [[ ! -s "$OUT_FILE" ]] || fail "legacy human rejection wrote to stdout"
    fi
}

# Attached and separated forms both hit the early shim, before ArgumentParser
# can echo the raw option text. Keep the calls explicit instead of expanding
# an empty array: macOS ships Bash 3, where an empty array trips `set -u` as
# an unbound variable before the assertion even reaches the helper.
for mode in human json; do
    if [[ "$mode" == json ]]; then
        assert_legacy_capability_rejected "$mode" purge apply --set "$SET_ID" "--preview-token=$CAPABILITY_CANARY" --json
        assert_legacy_capability_rejected "$mode" purge apply --set "$SET_ID" --preview-token "$CAPABILITY_CANARY" --json
        assert_legacy_capability_rejected "$mode" maintenance prune --set "$SET_ID" "--expected-destination=$CAPABILITY_CANARY" --json
        assert_legacy_capability_rejected "$mode" maintenance prune --set "$SET_ID" --expected-destination "$CAPABILITY_CANARY" --json
    else
        assert_legacy_capability_rejected "$mode" purge apply --set "$SET_ID" "--preview-token=$CAPABILITY_CANARY"
        assert_legacy_capability_rejected "$mode" purge apply --set "$SET_ID" --preview-token "$CAPABILITY_CANARY"
        assert_legacy_capability_rejected "$mode" maintenance prune --set "$SET_ID" "--expected-destination=$CAPABILITY_CANARY"
        assert_legacy_capability_rejected "$mode" maintenance prune --set "$SET_ID" --expected-destination "$CAPABILITY_CANARY"
    fi
done
ok "legacy attached and separated capability options exit 64 without reflection"

# Linux grants access to a same-user child command line through /proc. Keep
# each selected command blocked on a pipe, observe that its selector is there
# but its capability is not, then release the pipe. macOS deliberately has no
# equivalent world-readable /proc surface, so this exact regression is Linux
# only (the Linux CI job runs this script).
assert_stdin_selector_is_not_argv() {
    local label="$1"
    local selector="$2"
    shift 2
    local fifo="$WORK/$label.stdin"
    local observed="$WORK/$label.cmdline"
    OUT_FILE="$WORK/out-$$-$RANDOM"
    ERR_FILE="$WORK/err-$$-$RANDOM"
    mkfifo "$fifo"
    # Keep one read/write end open so the child starts and remains blocked in
    # its bounded stdin reader until this test writes the canary.
    exec 9<>"$fifo"
    set +e
    # The background child would otherwise inherit fd 9's write end and
    # keep its own FIFO open forever after the parent releases the canary.
    # Close it only in that child; the parent retains it until after /proc
    # observation and the one payload write.
    RESTIC_STATION_DATA_DIR="$ENVELOPE_DATA" "$HELPER" "$@" 9>&- <"$fifo" >"$OUT_FILE" 2>"$ERR_FILE" &
    local pid=$!
    set -e
    for _ in $(seq 1 50); do
        [[ -r "/proc/$pid/cmdline" ]] && break
        sleep 0.02
    done
    [[ -r "/proc/$pid/cmdline" ]] || fail "$label helper was not observable in /proc"
    tr '\0' ' ' <"/proc/$pid/cmdline" >"$observed"
    grep -qF -- "$selector" "$observed" || fail "$label argv omitted its stdin selector"
    ! grep -qF -- "$CAPABILITY_CANARY" "$observed" \
        || fail "$label exposed its capability in /proc/<pid>/cmdline"
    printf '%s' "$CAPABILITY_CANARY" >&9
    exec 9>&-
    set +e
    wait "$pid"
    RC=$?
    set -e
    cat "$OUT_FILE" "$ERR_FILE" >>"$COMBINED_LOG"
    [[ "$RC" -eq 1 ]] || fail "$label should reach the broken-config fixture after stdin parsing, got $RC"
    ! grep -qF -- "$CAPABILITY_CANARY" "$OUT_FILE" "$ERR_FILE" \
        || fail "$label reflected its stdin capability in output"
}

if [[ -d /proc && -r /proc/self/cmdline ]]; then
    assert_stdin_selector_is_not_argv purge-apply --preview-token-stdin \
        purge apply --set "$SET_ID" --preview-token-stdin --json
    assert_stdin_selector_is_not_argv maintenance-prune --expected-destination-stdin \
        maintenance prune --set "$SET_ID" --expected-destination-stdin --json
    RESTIC_STATION_DATA_DIR="$ENVELOPE_DATA" run_helper_split status --json
    ! grep -qF -- "$CAPABILITY_CANARY" "$OUT_FILE" "$ERR_FILE" \
        || fail "capability reached status output"
    ! grep -r -qF -- "$CAPABILITY_CANARY" "$ENVELOPE_DATA" 2>/dev/null \
        || fail "capability reached a run, log, current-run, or other fixture-state artifact"
    ok "both stdin selectors hide the capability from Linux child argv, output, and fixture-state artifacts"
else
    echo "  (skipped /proc capability-argv assertion: no Linux /proc)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 7. THE secret-leak check: every byte this script's helper invocations
#    produced, grepped for the fixture secret value.
# ─────────────────────────────────────────────────────────────────────────
log "7. no subcommand printed the fixture secret anywhere in this run's output"
if grep -qF -- "$SECRET_PASSWORD" "$COMBINED_LOG"; then
    fail "the fixture secret value appeared in captured helper output — see $COMBINED_LOG"
fi
ok "grepped the full combined output of every subcommand invoked above: the secret never appeared"

log "ALL HEADLESS CLI ASSERTIONS PASSED"
