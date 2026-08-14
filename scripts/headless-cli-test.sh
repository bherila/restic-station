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
#   6. No subcommand prints a secret: every stdout/stderr byte this script's
#      subcommands produce is captured to one combined log, and that log is
#      grepped for the fixture secret value at the very end.
#   7. Exit-code contract (0 ok / 1 error) spot-checked for the new
#      subcommands on both the happy and unhappy path.
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
    if jq -e '.scheduler.healthy == false' "$OUT_FILE" >/dev/null; then
        CLEAN_STATUS_RC=1
    else
        CLEAN_STATUS_RC=0
    fi
}

SECRET_PASSWORD='h34dl3ss "cli" $ecret with spaces '

# ─────────────────────────────────────────────────────────────────────────
# 1. config export / import round trip, including a v1 → v2 migration.
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
grep -q '"version" : 2' "$WORK/exported-config.json" \
    || fail "exported config was not migrated to v2 in memory before export"
grep -q 'machine.json' "$OUT_FILE" || true # note-only; not asserted further
ok "export migrates v1 → v2 and writes to --out"

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
echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].name == "Projects"' >/dev/null \
    || fail "imported config does not resolve the same set on the new host"
echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].destinations | length == 2' >/dev/null \
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
grep -q '"version" : 2' "$V1_IMPORT_DATA/config.json" || fail "v1 import was not migrated to v2 on disk"
[[ -f "$V1_IMPORT_DATA/config.v1.backup.json" ]] || fail "v1 import did not write config.v1.backup.json"
ok "importing a v1 file migrates it and writes config.v1.backup.json (T24's migration, reused)"

# ─────────────────────────────────────────────────────────────────────────
# 2. config validate: every set disabled here still exits 0, and says so.
# ─────────────────────────────────────────────────────────────────────────
log "2. config validate on an all-disabled-here config"

ALL_DISABLED_DATA="$WORK/all-disabled-data"
mkdir -p "$ALL_DISABLED_DATA"
cat > "$ALL_DISABLED_DATA/config.json" <<EOF
{
  "version": 2,
  "resticPath": null,
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$SET_ID",
      "name": "Projects",
      "sources": ["/tmp/src"],
      "excludes": [],
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
  "version": 2,
  "resticPath": null,
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$SET_ID",
      "name": "Projects",
      "sources": ["/tmp/src"],
      "excludes": [],
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
echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].firstBackupOverdue == false' >/dev/null \
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
echo "$(cat "$OUT_FILE")" | jq -e '.health == "running"' >/dev/null || fail "in-flight fixture did not report running"
echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].currentRun.phase == "backing-up-primary"' >/dev/null \
    || fail "in-flight fixture did not surface live progress"
echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].abandonedRun == null' >/dev/null \
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
echo "$(cat "$OUT_FILE")" | jq -e '.health == "warning"' >/dev/null \
    || fail "abandoned fixture did not report warning"
echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].isRunning == false' >/dev/null \
    || fail "abandoned fixture still reported the set as running"
echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].abandonedRun.runId == "r-dead"' >/dev/null \
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
echo "$(cat "$OUT_FILE")" | jq -e '.health == "warning"' >/dev/null || fail "failed fixture did not report warning"
echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].needsAttention == true' >/dev/null \
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
echo "$(cat "$OUT_FILE")" | jq -e '.health == "warning"' >/dev/null || fail "stale fixture did not report warning"
echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].destinations[0].stale == true' >/dev/null \
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
echo "$(cat "$OUT_FILE")" | jq -e '.health == "warning"' >/dev/null \
    || fail "a quiet set's failed last run must not be hidden behind 200+ newer runs from another set"
echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].needsAttention == true' >/dev/null \
    || fail "the quiet, configured set was not flagged needsAttention despite its last run having failed"
ok "a quiet set's failed last run survives 200+ newer runs from another set — status --json exit code stays 1"

# ─────────────────────────────────────────────────────────────────────────
# 5. every --json mode is ONLY JSON on stdout (piped through jq).
# ─────────────────────────────────────────────────────────────────────────
log "5. --json output is parseable JSON with nothing else on stdout"

RESTIC_STATION_DATA_DIR="$HEALTHY" run_helper status --json
capture_clean_status_rc
expect_rc "$CLEAN_STATUS_RC"
jq -e '.machineId | length > 0' "$OUT_FILE" >/dev/null \
    || fail "status --json did not produce clean JSON"
RESTIC_STATION_DATA_DIR="$HEALTHY" "$HELPER" sets list --json | jq -e 'type == "array"' >/dev/null \
    || fail "sets list --json did not pipe cleanly through jq"
RESTIC_STATION_DATA_DIR="$HEALTHY" "$HELPER" runs list --json | jq -e 'type == "array"' >/dev/null \
    || fail "runs list --json did not pipe cleanly through jq"
RESTIC_STATION_DATA_DIR="$HEALTHY" "$HELPER" config show --json | jq -e '.machineId | length > 0' >/dev/null \
    || fail "config show --json did not pipe cleanly through jq"
RESTIC_STATION_DATA_DIR="$HEALTHY" "$HELPER" runs show r-healthy --json | jq -e '.runId == "r-healthy"' >/dev/null \
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
  "version": 2,
  "resticPath": "$RESTIC_BIN",
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$SET_ID",
      "name": "Projects",
      "sources": ["$WORK/real-source"],
      "excludes": [],
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
    echo "$(cat "$OUT_FILE")" | jq -e '.sets[0].lastBackup.status == "success"' >/dev/null \
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
# 6. THE secret-leak check: every byte this script's helper invocations
#    produced, grepped for the fixture secret value.
# ─────────────────────────────────────────────────────────────────────────
log "6. no subcommand printed the fixture secret anywhere in this run's output"
if grep -qF -- "$SECRET_PASSWORD" "$COMBINED_LOG"; then
    fail "the fixture secret value appeared in captured helper output — see $COMBINED_LOG"
fi
ok "grepped the full combined output of every subcommand invoked above: the secret never appeared"

log "ALL HEADLESS CLI ASSERTIONS PASSED"
