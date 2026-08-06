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

FAILURES=0

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
RUN_ID="$(restic-station-helper runs list --json | jq -r '[.[] | select(.kind=="backup")][0].runId')"
printf '\n(runId captured for the next command: %s)\n' "$RUN_ID"
run restic-station-helper runs show "$RUN_ID" --log

SNAPSHOT_ID="$(restic-station-helper runs show "$RUN_ID" --json | jq -r '.snapshotId')"

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
  "version": 2,
  "resticPath": null,
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "Documents",
      "sources": ["/Users/bwh/Documents"],
      "excludes": [],
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
section "Scheduling: waiting to see whether the installed timer actually fires"
# ===========================================================================
# The one thing issue #45 says CI has never observed: a real systemd --user
# timer firing `tick` on its own, not `timer install` merely reporting
# enabled+active. A dedicated set with a repo already initialized and its
# password already stored, never yet backed up (so ScheduleMath's "never-run
# is immediately due" rule applies to the very first tick that runs it), in
# its own timer/data dir so it cannot collide with anything above.
FIRE_DATA="$WORK/data-fire-check"
FIRE_SOURCE="$WORK/fire-source"
FIRE_REPO="$WORK/fire-repo"
mkdir -p "$FIRE_DATA" "$FIRE_SOURCE"
echo "fire-check content" > "$FIRE_SOURCE/f.txt"
FIRE_SET_ID="e1000000-0000-4000-8000-000000000001"
FIRE_PRIMARY_ID="e1000000-0000-4000-8000-000000000002"
cat > "$FIRE_DATA/config.json" <<JSON
{
  "version": 2,
  "resticPath": null,
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$FIRE_SET_ID",
      "name": "Fire Check",
      "sources": ["$FIRE_SOURCE"],
      "excludes": [],
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

BEFORE=$(RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic-station-helper runs list --json | jq 'length')
echo
echo "runs recorded for \"Fire Check\" before installing its timer: $BEFORE (expect 0)"
RESTIC_STATION_DATA_DIR="$FIRE_DATA" run restic-station-helper timer install --interval 2

WAIT_SECONDS=170
echo
echo "waiting up to ${WAIT_SECONDS}s, polling every 10s, for the installed timer to fire a REAL tick"
echo "that finds \"Fire Check\" due and runs it — the one thing docs/testing.md and issue #45 say"
echo "has never been observed in CI:"
FIRED=0
ELAPSED=0
while [[ $ELAPSED -lt $WAIT_SECONDS ]]; do
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    AFTER=$(RESTIC_STATION_DATA_DIR="$FIRE_DATA" restic-station-helper runs list --json | jq 'length' 2>/dev/null || echo "$BEFORE")
    printf '  t=+%3ds  runs=%s\n' "$ELAPSED" "$AFTER"
    if [[ "$AFTER" -gt "$BEFORE" ]]; then
        FIRED=1
        break
    fi
done

echo
RESTIC_STATION_DATA_DIR="$FIRE_DATA" run restic-station-helper runs list --json
run journalctl --user -u restic-station.service --no-pager --since "-5 minutes"

echo
if [[ $FIRED -eq 1 ]]; then
    echo "OBSERVED: the systemd --user timer fired on its own and ran a real, previously-never-run"
    echo "backup — a live end-to-end firing, not just 'enabled/active'. See the PR description for"
    echo "what this does and does not settle about issue #45."
else
    echo "NOT OBSERVED within ${WAIT_SECONDS}s: the timer reported enabled+active above, but no new run"
    echo "appeared in that window. Left as still-open per issue #45; the wait ran out, this was not"
    echo "given up on early."
fi

RESTIC_STATION_DATA_DIR="$FIRE_DATA" run restic-station-helper timer uninstall

exit 0
