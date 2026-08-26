#!/bin/bash
# scripts/linux-docs-transcript.sh — produces the real command transcripts
# `docs/linux.md` quotes, against a genuine (non-container) Linux host with
# real restic installed: `.github/workflows/ci.yml`'s `linux-integration`
# job, which already builds/unpacks the static release binary and installs
# real restic 0.18.1 for T29's fixture-flow test.
#
# T30 (issue #32) requires every command printed in docs/linux.md to have
# actually been run on Linux, not paraphrased or copied from a macOS
# terminal. This script is how: every `$ <command>` line below is echoed
# immediately before running it, so the job log IS the transcript — copy it
# into docs/linux.md verbatim. Running it in CI (rather than by hand once)
# also makes the docs regression-checked: if a command's output changes,
# this job's log changes with it.
#
# Usage: scripts/linux-docs-transcript.sh <path-to-restic-station-helper>
# Requires: a real `restic` (>= 0.17.0) and `jq` on PATH.
set -uo pipefail

BIN_SRC="${1:?usage: linux-docs-transcript.sh <path-to-restic-station-helper>}"
[[ -x "$BIN_SRC" ]] || { echo "not executable: $BIN_SRC" >&2; exit 1; }
command -v restic >/dev/null 2>&1 || { echo "restic not on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not on PATH" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK="$(mktemp -d)"
# shellcheck disable=SC2329 # invoked indirectly by trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# `restic-station-helper` on PATH, matching what every command in the docs
# is written as (the reader is assumed to have already run `install.sh`).
BIN_DIR="$WORK/bin"
mkdir -p "$BIN_DIR"
cp "$BIN_SRC" "$BIN_DIR/restic-station-helper"
export PATH="$BIN_DIR:$PATH"

DATA="$WORK/data"
mkdir -p "$DATA"
export RESTIC_STATION_DATA_DIR="$DATA"
export RESTIC_STATION_SECRET_BACKEND=file
# A stable, readable machine id instead of whatever this runner's hostname
# slugifies to — RESTIC_STATION_MACHINE_ID is documented
# (docs/data-model.md §machine.json) as exactly this: a non-persistent
# override safe for tests and for giving a host a second identity. It is
# never written to machine.json.
export RESTIC_STATION_MACHINE_ID=linux-nas

# Echoes the command, runs it, and always returns 0 so one failing/expected-
# to-fail command doesn't stop the transcript short — the docs need to show
# real failures (rejection messages, permission refusals) too. Exit status
# is still reported inline.
run() {
    printf '\n$ %s\n' "$*"
    "$@"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '(exit %d)\n' "$rc"
    fi
    return 0
}

# Same, but for a pipeline (`printf ... | helper ...`) that can't be spread
# across run()'s "$@". $1 is a label only, for grep-ability in the log.
run_pipe() {
    local label="$1"
    shift
    printf '\n$ %s\n' "$label"
    eval "$*"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        printf '(exit %d)\n' "$rc"
    fi
    return 0
}

section() { printf '\n\n########## %s ##########\n' "$*"; }

# ===========================================================================
section "Prerequisites"
# ===========================================================================
run restic version
run restic-station-helper version

# ===========================================================================
section "Get a config across: import a Mac-exported config.json"
# ===========================================================================
# scripts/fixtures/mac-exported-config.json is a checked-in fixture in the
# exact shape macOS's `config export` produces (same file T29's
# assert_fixture_flow imports) — placeholder tokens are substituted for real
# paths on this run, never invented content.
FIXTURE_SOURCE="$WORK/source"
FIXTURE_PRIMARY_REPO="$WORK/repo-primary"
FIXTURE_MIRROR_REPO="$WORK/repo-mirror"
mkdir -p "$FIXTURE_SOURCE"
echo "quarterly-report.docx (fixture content)" > "$FIXTURE_SOURCE/quarterly-report.docx"
echo "notes.md (fixture content)" > "$FIXTURE_SOURCE/notes.md"

RENDERED="$WORK/mac-exported-config.json"
sed \
    -e "s#__SOURCE_DIR__#$FIXTURE_SOURCE#g" \
    -e "s#__PRIMARY_REPO__#$FIXTURE_PRIMARY_REPO#g" \
    -e "s#__MIRROR_REPO__#$FIXTURE_MIRROR_REPO#g" \
    -e "s#__MACHINE_ID__#linux-nas#g" \
    "$REPO_ROOT/scripts/fixtures/mac-exported-config.json" > "$RENDERED"

run restic-station-helper config import "$RENDERED"
run restic-station-helper config validate

PROJECTS_ID="f1000000-0000-4000-8000-000000000001"
PRIMARY_ID="f1000000-0000-4000-8000-000000000002"
MIRROR_ID="f1000000-0000-4000-8000-000000000003"

# ===========================================================================
section "Secrets: store the primary and mirror passwords (piped, never argv)"
# ===========================================================================
run_pipe "printf '%s' 'quarterly-4x-mirror' | restic-station-helper secret set --dest $PRIMARY_ID" \
    "printf '%s' 'quarterly-4x-mirror' | restic-station-helper secret set --dest $PRIMARY_ID"
run_pipe "printf '%s' 'quarterly-4x-mirror' | restic-station-helper secret set --dest $MIRROR_ID" \
    "printf '%s' 'quarterly-4x-mirror' | restic-station-helper secret set --dest $MIRROR_ID"
run restic-station-helper secret list
run ls -l "$DATA/secrets.json"
run stat -c '%a %n' "$DATA/secrets.json" "$DATA"

# Widen the mode by hand (the accidental `chmod -R` scenario) and show the
# refusal, then fix it — the exact troubleshooting flow the docs describe.
chmod 644 "$DATA/secrets.json"
run restic-station-helper secret list
chmod 600 "$DATA/secrets.json"
run restic-station-helper secret list

# ===========================================================================
section "Initialize the repositories (one-time; run-set never auto-inits)"
# ===========================================================================
PRIMARY_PWCMD="$BIN_DIR/restic-station-helper print-password --dest $PRIMARY_ID"
run env RESTIC_PASSWORD_COMMAND="$PRIMARY_PWCMD" restic -r "$FIXTURE_PRIMARY_REPO" init
run restic-station-helper init-secondary --set "$PROJECTS_ID" --dest "$MIRROR_ID"

# ===========================================================================
section "Run the set: backup to primary, mirror via restic copy"
# ===========================================================================
run restic-station-helper run-set --set "$PROJECTS_ID" --kind backup

# ===========================================================================
section "Operating it: status, runs"
# ===========================================================================
run restic-station-helper status
run restic-station-helper status --json
STATUS_JSON="$(restic-station-helper status --json)"
echo "$STATUS_JSON" | jq . >/dev/null 2>&1

run restic-station-helper runs list
RUN_ID="$(restic-station-helper runs list --json | jq -r '.data | [.[] | select(.kind=="backup")][0].runId')"
printf '\n(runId captured for the next command: %s)\n' "$RUN_ID"
run restic-station-helper runs show "$RUN_ID" --log

SNAPSHOT_ID="$(restic-station-helper runs show "$RUN_ID" --json | jq -r '.data.snapshotId')"

# ===========================================================================
section "Restore"
# ===========================================================================
RESTORE_TARGET="$WORK/restore-target"
mkdir -p "$RESTORE_TARGET"
run restic-station-helper restore --set "$PROJECTS_ID" --dest "$PRIMARY_ID" \
    --snapshot "$SNAPSHOT_ID" --target "$RESTORE_TARGET"
run diff -r "$FIXTURE_SOURCE" "$RESTORE_TARGET$FIXTURE_SOURCE"

# ===========================================================================
section "Troubleshooting: a repo that is unreachable"
# ===========================================================================
run restic-station-helper probe-repo --set "$PROJECTS_ID" --dest "$PRIMARY_ID"
mv "$FIXTURE_PRIMARY_REPO" "$FIXTURE_PRIMARY_REPO.unplugged"
run restic-station-helper probe-repo --set "$PROJECTS_ID" --dest "$PRIMARY_ID"
mv "$FIXTURE_PRIMARY_REPO.unplugged" "$FIXTURE_PRIMARY_REPO"

# ===========================================================================
section "Per-machine override worked examples (checked-in fixture)"
# ===========================================================================
# Core/Tests/ResticStationCoreTests/Fixtures/config-v2.json is the exact
# fixture the per-machine resolution unit tests load — the same JSON
# docs/data-model.md's two worked examples are drawn from. Validating it
# here for real, for both a machine with overrides and one without, ties
# the doc's JSON to something CI actually resolves.
LINUX_NAS_DATA="$WORK/data-linux-nas"
mkdir -p "$LINUX_NAS_DATA"
cp "$REPO_ROOT/Core/Tests/ResticStationCoreTests/Fixtures/config-v2.json" "$LINUX_NAS_DATA/config.json"

echo
echo "--- as linux-nas (Documents overridden to run here; Photos excluded) ---"
RESTIC_STATION_DATA_DIR="$LINUX_NAS_DATA" run restic-station-helper config validate --machine linux-nas

echo
echo "--- as old-laptop (Documents excluded; Photos still runs, unmodified) ---"
RESTIC_STATION_DATA_DIR="$LINUX_NAS_DATA" run restic-station-helper config validate --machine old-laptop

# A machine with every one of ITS sets disabled — the mirror/restore-only
# story (data-model.md worked example 2). Built from the same fixture shape
# headless-cli-test.sh's ALL_DISABLED_DATA uses.
MIRROR_BOX_DATA="$WORK/data-mirror-box"
mkdir -p "$MIRROR_BOX_DATA"
cat > "$MIRROR_BOX_DATA/config.json" <<'JSON'
{
  "version": 3,
  "resticPath": null,
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "Documents",
      "sources": ["/Users/bwh/Documents"],
      "excludes": [],
      "purgeExcludes": [],
      "schedule": {"kind": "daily", "hour": 2, "minute": 30},
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 14,
      "machines": {"mirror-box": {"enabled": false}},
      "destinations": [
        {"id": "0A1B2C3D-4E5F-4A1B-8C1D-000000000001", "label": "Big Drive",
         "repoURL": "/Volumes/Big/documents.restic", "isPrimary": true, "nonSecretEnv": {}}
      ]
    },
    {
      "id": "7A8B9C0D-1E2F-4A3B-8C4D-000000000010",
      "name": "Photos",
      "sources": ["/Users/bwh/Pictures"],
      "excludes": [],
      "purgeExcludes": [],
      "schedule": {"kind": "weekly", "weekday": 1, "hour": 3, "minute": 0},
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 30,
      "machines": {"mirror-box": {"enabled": false}},
      "destinations": [
        {"id": "3D4E5F60-6162-4A1B-8C1D-000000000004", "label": "Big Drive",
         "repoURL": "/Volumes/Big/photos.restic", "isPrimary": true, "nonSecretEnv": {}}
      ]
    }
  ]
}
JSON
echo
echo "--- as mirror-box (every set disabled: mirror/restore-only host) ---"
RESTIC_STATION_DATA_DIR="$MIRROR_BOX_DATA" run restic-station-helper config validate --machine mirror-box

# ===========================================================================
section "Scheduling: timer status on this host"
# ===========================================================================
# Note: this runner is a bare Ubuntu VM (systemd genuinely is pid 1 — unlike
# the swift:6.1 container `linux` job uses). issue #45 assumed a GitHub-
# hosted runner's default account has no logind session at all — that
# turned out not to hold for this runner (ubuntu-24.04-arm): `loginctl`
# reports a real user session with lingering already enabled. Whether that
# is a property of this specific runner image/version or something to rely
# on generally is not something a single CI run can answer — reported
# honestly below, not overclaimed as "issue #45 fixed everywhere."
run restic-station-helper timer install
run restic-station-helper timer status
run loginctl show-user "$(whoami)" --property=Linger

# ===========================================================================
section "Scheduling: a custom XDG_STATE_HOME reaches the timer (issue #48)"
# ===========================================================================
# issue #48 (found via @codex review on #47): timer install used to bake only
# RESTIC_STATION_DATA_DIR into the unit, so a custom XDG_STATE_HOME set in an
# interactive shell's profile was invisible to the systemd --user manager
# that actually runs the tick — which then resolved ~/.local/state/
# restic-station, found no config there, and backed up nothing while exiting
# 0. `timer install` now resolves the data directory through AppPaths (the
# whole override chain) and pins the absolute result.
#
# Verified against the real unit file this same job's `timer install` writes,
# not read from source. Reinstalling here is safe (idempotent; overwrites in
# place) and Fire Check below reinstalls again over its own environment
# before it matters for anything downstream.
UNIT_FILE="$HOME/.config/systemd/user/restic-station.service"
CUSTOM_STATE="$WORK/custom-xdg-state"

echo
echo "--- reinstalled with a custom XDG_STATE_HOME and no RESTIC_STATION_DATA_DIR override ---"
env -u RESTIC_STATION_DATA_DIR XDG_STATE_HOME="$CUSTOM_STATE" \
    restic-station-helper timer install >/dev/null
echo "\$ cat $UNIT_FILE"
cat "$UNIT_FILE"
echo
# The assertion, not just the display: this is the regression check for #48,
# and a transcript that only printed the file would keep printing it happily
# after a regression.
if grep -qF "Environment=\"RESTIC_STATION_DATA_DIR=$CUSTOM_STATE/restic-station\"" "$UNIT_FILE"; then
    echo "CONFIRMED: the unit pins $CUSTOM_STATE/restic-station — the directory this shell's"
    echo "XDG_STATE_HOME resolves to. The tick the timer fires reads the same data the shell"
    echo "that installed it does, with no reliance on the user manager's environment."
else
    echo "REGRESSION (issue #48): the unit does not pin the XDG_STATE_HOME-derived data directory."
    exit 1
fi

echo
echo "--- and an explicit RESTIC_STATION_DATA_DIR still wins, as the highest-priority override ---"
env RESTIC_STATION_DATA_DIR="$WORK/explicit-data-dir" \
    restic-station-helper timer install >/dev/null
echo "\$ cat $UNIT_FILE"
cat "$UNIT_FILE"
grep -qF "Environment=\"RESTIC_STATION_DATA_DIR=$WORK/explicit-data-dir\"" "$UNIT_FILE" || {
    echo "REGRESSION: an explicit RESTIC_STATION_DATA_DIR did not reach the unit"
    exit 1
}

# ===========================================================================
section "Scheduling: waiting to see whether the installed timer actually fires"
# ===========================================================================
# Issue #45's live scheduler gate: observe both the initial OnBootSec firing
# and a later OnUnitActiveSec firing, not merely `timer install` reporting
# enabled+active. A dedicated set has a repo already initialized and its
# password already stored, but has never run (so ScheduleMath's "never-run is
# immediately due" rule applies to the first tick). Its 5-minute backup
# schedule deliberately exceeds the timer's 2-minute cadence: the repeat tick
# must happen, but must not create a second backup before the set is due.
FIRE_DATA="$WORK/data-fire-check"
FIRE_SOURCE="$WORK/fire-source"
FIRE_REPO="$WORK/fire-repo"
mkdir -p "$FIRE_DATA" "$FIRE_SOURCE"
echo "fire-check content" > "$FIRE_SOURCE/f.txt"
FIRE_SET_ID="e1000000-0000-4000-8000-000000000001"
FIRE_PRIMARY_ID="e1000000-0000-4000-8000-000000000002"
cat > "$FIRE_DATA/config.json" <<JSON
{
  "version": 3,
  "resticPath": null,
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$FIRE_SET_ID",
      "name": "Fire Check",
      "sources": ["$FIRE_SOURCE"],
      "excludes": [],
      "purgeExcludes": [],
      "schedule": {"kind": "everyMinutes", "minutes": 5},
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 14,
      "destinations": [
        {"id": "$FIRE_PRIMARY_ID", "label": "Fire Primary", "repoURL": "$FIRE_REPO", "isPrimary": true, "nonSecretEnv": {}}
      ]
    }
  ]
}
JSON
RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic-station-helper config validate >/dev/null
printf '%s' 'fire-check-password' \
    | RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic-station-helper secret set --dest "$FIRE_PRIMARY_ID" >/dev/null
RESTIC_PASSWORD_COMMAND="$BIN_DIR/restic-station-helper print-password --dest $FIRE_PRIMARY_ID" \
    RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic -r "$FIRE_REPO" init >/dev/null

BEFORE=$(RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic-station-helper runs list --json | jq '.data | length')
echo
echo "runs recorded for \"Fire Check\" before installing its timer: $BEFORE (expect 0)"
JOURNAL_START="$(date --iso-8601=seconds)"
RESTIC_STATION_DATA_DIR="$FIRE_DATA" run restic-station-helper timer install --interval 2

service_start_count() {
    journalctl --user -u restic-station.service --no-pager --since "$JOURNAL_START" -o json 2>/dev/null \
        | jq -s '[.[] | select((.MESSAGE // "") | startswith("Starting restic-station.service"))] | length' \
        2>/dev/null || echo 0
}

WAIT_SECONDS=250
echo
echo "waiting up to ${WAIT_SECONDS}s, polling every 10s, for two unattended service activations:"
echo "the first must back up the never-run set; the OnUnitActiveSec repeat must tick again without"
echo "backing it up early (the set itself is due every 5 minutes):"
FIRED=0
REPEATED=0
ELAPSED=0
while [[ $ELAPSED -lt $WAIT_SECONDS ]]; do
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    AFTER=$(RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic-station-helper runs list --json | jq '.data | length' 2>/dev/null || echo "$BEFORE")
    SERVICE_STARTS=$(service_start_count)
    printf '  t=+%3ds  service starts=%s  backup runs=%s\n' "$ELAPSED" "$SERVICE_STARTS" "$AFTER"
    if [[ "$AFTER" -gt "$BEFORE" ]]; then
        FIRED=1
    fi
    if [[ "$SERVICE_STARTS" -ge 2 ]]; then
        REPEATED=1
    fi
    if [[ $FIRED -eq 1 && $REPEATED -eq 1 ]]; then
        break
    fi
done

echo
RESTIC_STATION_DATA_DIR="$FIRE_DATA" run restic-station-helper runs list --json
run journalctl --user -u restic-station.service --no-pager --since "-5 minutes"

echo
if [[ $FIRED -ne 1 ]]; then
    echo "REGRESSION: no unattended backup appeared within ${WAIT_SECONDS}s"
    exit 1
fi
if [[ $REPEATED -ne 1 ]]; then
    echo "REGRESSION: OnUnitActiveSec did not produce a second service activation within ${WAIT_SECONDS}s"
    exit 1
fi
if [[ "$AFTER" -ne $((BEFORE + 1)) ]]; then
    echo "REGRESSION: the 2-minute timer cadence created $((AFTER - BEFORE)) backups even though the"
    echo "set's 5-minute due time permits exactly one in this observation window"
    exit 1
fi
echo "CONFIRMED: systemd fired the initial due backup and then activated the service again through"
echo "OnUnitActiveSec. The repeat tick created no early backup; due-ness still came from schedule state."

RESTIC_STATION_DATA_DIR="$FIRE_DATA" run restic-station-helper timer uninstall

# ===========================================================================
section "Monitoring: status --json sees the scheduler (issues #46, #48)"
# ===========================================================================
# Status.run() used to pass backgroundAgentEnabled: true into
# HealthDerivation unconditionally on every platform, so `status --json` was
# blind to whether anything was still scheduled: after the Fire Check timer
# was uninstalled just above, it went on reporting this host healthy (exit 0)
# because the one backup it had already run succeeded. It now asks the same
# SystemdTimerManager `timer status` does.
#
# This is the regression check for that. The script runs without `set -e`
# (the transcript has to show real failures too), so the assertion below is
# an explicit `exit 1` rather than a bare command's status: a `status --json`
# that exits 0 here must fail the job. That is the whole finding — it used to
# exit 0 on a host with no scheduler at all.
echo
echo "--- status --json for the same data dir, right after the timer above was uninstalled ---"
STATUS_RC=0
SCHED_JSON="$(RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic-station-helper status --json)" || STATUS_RC=$?
echo "\$ restic-station-helper status --json; echo \"exit \$?\""
echo "$SCHED_JSON"
echo "exit $STATUS_RC"
echo
if [[ "$STATUS_RC" -ne 1 ]]; then
    echo "REGRESSION: status --json exited $STATUS_RC on a host with no scheduler installed;"
    echo "expected 1. This is the exact 'green while broken' failure issue #46 tracked."
    exit 1
fi
echo "$SCHED_JSON" | jq -e '.data | .scheduler.healthy == false' >/dev/null || {
    echo "REGRESSION: status --json did not report the scheduler as unhealthy"
    exit 1
}
echo "$SCHED_JSON" | jq -e '.data | .scheduler.problems | index("unitsMissing")' >/dev/null || {
    echo "REGRESSION: status --json did not name unitsMissing as the reason"
    exit 1
}
echo "CONFIRMED: status --json reports scheduler.healthy=false, names the reason in"
echo "scheduler.problems, and exits 1 — on the same host and data directory that used to"
echo "exit 0 with no mention of the scheduler at all."

echo
echo "--- and the human rendering says it in one line ---"
RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic-station-helper status || true

echo
echo "--- timer status for the same host: the same verdict, the same exit code ---"
RESTIC_STATION_DATA_DIR="$FIRE_DATA" run restic-station-helper timer status

# ===========================================================================
section "Monitoring: a killed run does not leave the host reporting healthy forever"
# ===========================================================================
# A SIGKILL/OOM/power-cut skips the `defer` that deletes
# state/current-run-<setId>.json, and a current-run file is what "a run is in
# flight" means to every reader. `.running` outranks `.warning`, so one dead
# run used to pin this host green permanently. Readers now check the run's
# recorded pid (RunStore.liveness) instead of trusting the file's existence.
#
# Forged rather than actually SIGKILLing a backup: the file contents are what
# the reader sees either way, and a forged one is deterministic in CI. The
# run id points at a run directory that does not exist, which is the same
# thing a killed run looks like once its metadata has been recovered.
FIRE_SET_ID="$(RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic-station-helper status --json \
    | jq -r '.data.sets[0].id')"
WRECKAGE="$FIRE_DATA/state/current-run-$FIRE_SET_ID.json"
cat >"$WRECKAGE" <<JSON
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
echo
echo "--- a current-run file whose process is gone (updatedAt is *now*, so no timestamp"
echo "    heuristic would catch it) ---"
WRECK_RC=0
WRECK_JSON="$(RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic-station-helper status --json)" || WRECK_RC=$?
echo "$WRECK_JSON" | jq '.data | {health, sets: [.sets[] | {name, isRunning, needsAttention, abandonedRun}]}'
echo "exit $WRECK_RC"
echo
echo "$WRECK_JSON" | jq -e '.data | .health == "warning"' >/dev/null || {
    echo "REGRESSION: an abandoned run left health as $(echo "$WRECK_JSON" | jq -r '.data.health'), not warning"
    exit 1
}
echo "$WRECK_JSON" | jq -e '.data | .sets[0].isRunning == false' >/dev/null || {
    echo "REGRESSION: an abandoned run still reports isRunning"
    exit 1
}
echo "$WRECK_JSON" | jq -e '.data | .sets[0].abandonedRun != null' >/dev/null || {
    echo "REGRESSION: the abandoned run was discarded rather than reported"
    exit 1
}
echo "CONFIRMED: health is \"warning\" (not \"running\"), the set reports isRunning=false, and the"
echo "abandoned run is named so it can be cleared. Before this, the same file made every"
echo "subsequent health check on this host exit 0 forever."
rm -f "$WRECKAGE"

exit 0
