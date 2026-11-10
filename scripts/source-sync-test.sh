#!/usr/bin/env bash
# Disposable, synthetic integration: real rsync, restic backup, restore,
# exact old-version recovery, and an independent broader backup selection.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${RESTIC_STATION_HELPER_OVERRIDE:-$ROOT/.build/debug/restic-station-helper}"
HELPER="$(cd "$(dirname "$HELPER")" && pwd -P)/$(basename "$HELPER")"
RESTIC="$(command -v restic)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/restic-source-sync.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
export RESTIC_STATION_DATA_DIR="$WORK/state"
export RESTIC_STATION_SECRET_BACKEND=file
export RESTIC_STATION_MACHINE_ID=laptop
SET=11111111-1111-4111-8111-111111111111
DEST=22222222-2222-4222-8222-222222222222
GROUP=33333333-3333-4333-8333-333333333333
MIRROR=44444444-4444-4444-8444-444444444444
mkdir -p "$WORK/workspace/notes/nested" "$WORK/other copy" "$WORK/repo" "$WORK/mirror" "$WORK/state"
chmod 700 "$WORK/state"
python3 - "$WORK" "$RESTIC" "$SET" "$DEST" "$GROUP" "$MIRROR" <<'PY'
import json, os, pathlib, sys
base, restic, sid, did, gid, mid = sys.argv[1:]
p = pathlib.Path(base)
config = {"version": 6, "showMenuBarIcon": True, "sets": [{"id": sid, "name": "Workspace", "sources": [str(p/"workspace")],
    "usesGlobalExcludes": False, "excludes": [], "stalenessWarningDays": 14, "schedule": {"kind": "daily", "hour": 2, "minute": 0},
    "destinations": [{"id": did, "label": "Archive", "repoURL": str(p/"repo"), "isPrimary": True, "nonSecretEnv": {}},
        {"id": mid, "label": "Second archive", "repoURL": str(p/"mirror"), "isPrimary": False, "nonSecretEnv": {}}],
    "syncFolders": [{"id": gid, "name": "Notes", "localPath": str(p/"workspace/notes"),
        "peer": {"path": str(p/"other copy"), "helperPath": "restic-station-helper"}, "coordinatorMachineId": "laptop"}]}]}
(p/"state/config.json").write_text(json.dumps(config))
(p/"state/machine.json").write_text(json.dumps({"version":1,"machineId":"laptop","resticPath":restic}))
(p/"workspace/notes/nested/from local").write_text("local version")
(p/"workspace/notes/nested").chmod(0o750)
(p/"workspace/notes/read-only").mkdir()
(p/"workspace/notes/read-only/note").write_text("read-only tree")
(p/"workspace/notes/read-only").chmod(0o500)
(p/"other copy/from peer").write_text("peer version")
os.utime(p/"workspace/notes/nested/from local", ns=(981173106_000000000, 981173106_000000000))
os.utime(p/"other copy/from peer", ns=(1234567890_000000000, 1234567890_000000000))
(p/"workspace/sibling").write_text("backup only")
PY
printf '%s' 'synthetic-sync-password' | "$HELPER" secret set --dest "$DEST" >/dev/null
printf '%s' 'synthetic-sync-password' | "$HELPER" secret set --dest "$MIRROR" >/dev/null
# Match FileSecretStore's quoting: restic splits this string itself and
# does not interpret Bash's %q escaping (notably app bundle spaces).
QUOTED_HELPER="\"$HELPER\""
PASSWORD_COMMAND="$QUOTED_HELPER print-password --dest $DEST"
RESTIC_PASSWORD_COMMAND="$PASSWORD_COMMAND" "$RESTIC" -r "$WORK/repo" init >/dev/null
"$HELPER" init-secondary --set "$SET" --dest "$MIRROR" >/dev/null
plan() { "$HELPER" sync plan --set "$SET" --json > "$WORK/plan.json"; }
apply() {
    if jq -r .data.previewToken "$WORK/plan.json" | "$HELPER" sync apply --set "$SET" --preview-token-stdin --json > "$WORK/result.json"; then return 0; fi
    cat "$WORK/result.json" >&2
    return 1
}
plan
jq -e '.ok and .data.copies == 5 and .data.conflicts == 0 and (.data | has("changes") | not)' "$WORK/plan.json" >/dev/null
apply
cmp "$WORK/workspace/notes/nested/from local" "$WORK/other copy/nested/from local"
cmp "$WORK/workspace/notes/from peer" "$WORK/other copy/from peer"
test ! -e "$WORK/other copy/sibling"
cmp "$WORK/workspace/notes/read-only/note" "$WORK/other copy/read-only/note"
python3 - "$WORK" <<'PYMODES'
import pathlib, stat, sys
p = pathlib.Path(sys.argv[1])
for root in [p/"workspace/notes", p/"other copy"]:
    assert stat.S_IMODE((root/"read-only").stat().st_mode) == 0o500
    assert stat.S_IMODE((root/"nested").stat().st_mode) == 0o750
    # Real rsync carries each file's original modification time (whole
    # seconds: openrsync speaks protocol 29, without nanosecond times).
    assert (root/"nested/from local").stat().st_mtime_ns == 981173106_000000000
    assert (root/"from peer").stat().st_mtime_ns == 1234567890_000000000
# Both copies were finalized; make them writable for subsequent manual edits.
for root in [p/"workspace/notes", p/"other copy"]:
    (root/"read-only").chmod(0o700)
PYMODES
# The same token cannot authorize a second operation.
if apply; then echo 'FAIL: replayed token accepted' >&2; exit 1; fi
printf '%s' 'replacement' > "$WORK/other copy/nested/from local"
plan
apply
test "$(cat "$WORK/workspace/notes/nested/from local")" = replacement
# Restore the exact protection snapshot's vault and prove it retained the
# old local version before replacement. Do not infer coverage from status.
# Locate the journal/vault pair containing the replaced value rather than
# relying on UUID directory order.
python3 - "$WORK" <<'PY'
import hashlib, json, pathlib, sys
p=pathlib.Path(sys.argv[1]); found=False
for journal in (p/"state/source-sync").rglob("journal.json"):
    vault=journal.parent/"vault"
    record=json.loads(journal.read_text())
    changes=record["preview"]["plan"]["changes"]
    if any(c["path"]=="nested/from local" and c["action"]=="copyToLocal" and c["local"]["digest"]==hashlib.sha256(b"local version").hexdigest() for c in changes):
        (p/"snapshot").write_text(record["protectedSnapshot"])
        (p/"vault").write_text(str(vault)); found=True
assert found, "old version missing from recovery vault"
PY
SNAPSHOT="$(cat "$WORK/snapshot")"
VAULT="$(cat "$WORK/vault")"
RESTIC_PASSWORD_COMMAND="$PASSWORD_COMMAND" "$RESTIC" -r "$WORK/repo" restore "$SNAPSHOT:$VAULT" --target "$WORK/recovered" >/dev/null
test "$(cat "$WORK/recovered/local/nested/from local")" = 'local version'
MIRROR_PASSWORD_COMMAND="$QUOTED_HELPER print-password --dest $MIRROR"
MIRROR_SNAPSHOT="$(RESTIC_PASSWORD_COMMAND="$MIRROR_PASSWORD_COMMAND" "$RESTIC" -r "$WORK/mirror" snapshots --json | jq -r --arg snapshot "$SNAPSHOT" 'first(.[] | select(.id == $snapshot or .original == $snapshot) | .id)')"
test -n "$MIRROR_SNAPSHOT"
RESTIC_PASSWORD_COMMAND="$MIRROR_PASSWORD_COMMAND" "$RESTIC" -r "$WORK/mirror" restore "$MIRROR_SNAPSHOT:$VAULT" --target "$WORK/mirror-recovered" >/dev/null
test "$(cat "$WORK/mirror-recovered/local/nested/from local")" = 'local version'
RESTIC_PASSWORD_COMMAND="$PASSWORD_COMMAND" "$RESTIC" -r "$WORK/repo" restore "latest:$VAULT" --target "$WORK/agreement-recovered" >/dev/null
jq -e '.localEndpointGeneration != null and .peerEndpointGeneration != null and .agreed["nested/from local"].kind == "file"' "$WORK/agreement-recovered/agreement.json" >/dev/null
RESTIC_PASSWORD_COMMAND="$PASSWORD_COMMAND" "$RESTIC" -r "$WORK/repo" restore latest --include "$WORK/workspace/sibling" --target "$WORK/full-backup" >/dev/null
test "$(cat "$WORK/full-backup$WORK/workspace/sibling")" = 'backup only'
rm -rf "$WORK/workspace/notes/nested"
plan
apply
test ! -e "$WORK/other copy/nested"
# A plan that only creates runs no protection backup, so it asks the primary
# repository for its identity first (#204): with the repository unreadable,
# apply refuses before either copy changes, and the same operation resumes
# once the repository answers again. The directory stays: a missing local
# repository directory is already refused earlier, before any journal.
printf '%s' 'created while unplugged' > "$WORK/workspace/notes/created"
plan
mv "$WORK/repo/config" "$WORK/repo-config"
if apply; then echo 'FAIL: create-only sync installed with the repository unreachable' >&2; exit 1; fi
jq -e '.ok == false and .error.code == "restic_failed" and (.error.message | test("did not answer"))' "$WORK/result.json" >/dev/null
test ! -e "$WORK/other copy/created"
"$HELPER" sync status --set "$SET" --json | jq -e '.data.status == "needsRecovery" and .data.canCancel == true' >/dev/null
mv "$WORK/repo-config" "$WORK/repo/config"
"$HELPER" sync recover --set "$SET" >/dev/null
cmp "$WORK/workspace/notes/created" "$WORK/other copy/created"
# An offline backup mirror does not block a sync (#197): protection needs
# only the restore-verified primary snapshot. The sync reports the mirror,
# and an ordinary backup brings it up to date afterwards.
mv "$WORK/mirror" "$WORK/mirror-away"
printf '%s' 'edited while the mirror is away' > "$WORK/other copy/from peer"
plan
apply
jq -e '.ok and .data.status == "synchronized" and (.data.warnings | length) == 1 and (.data.warnings[0] | test("Second archive"))' "$WORK/result.json" >/dev/null \
    || { echo 'FAIL: an offline mirror blocked the sync or went unreported' >&2; cat "$WORK/result.json" >&2; exit 1; }
test "$(cat "$WORK/workspace/notes/from peer")" = 'edited while the mirror is away'
mv "$WORK/mirror-away" "$WORK/mirror"
"$HELPER" run-set --set "$SET" --kind backup >/dev/null
PRIMARY_LATEST="$(RESTIC_PASSWORD_COMMAND="$PASSWORD_COMMAND" "$RESTIC" -r "$WORK/repo" snapshots --json | jq -r 'sort_by(.time) | last | .id')"
RESTIC_PASSWORD_COMMAND="$MIRROR_PASSWORD_COMMAND" "$RESTIC" -r "$WORK/mirror" snapshots --json \
    | jq -e --arg id "$PRIMARY_LATEST" 'any(.[]; .id == $id or .original == $id)' >/dev/null \
    || { echo 'FAIL: the mirror did not catch up at the next ordinary backup' >&2; exit 1; }
# An entry its group or others could write is refused by name, with the
# remedy (#197); making it owner-writable only lets the sync go on.
mkdir -p "$WORK/workspace/notes/shared"
printf '%s' 'group file' > "$WORK/workspace/notes/shared/team.txt"
chmod 0664 "$WORK/workspace/notes/shared/team.txt"
if "$HELPER" sync plan --set "$SET" --json > "$WORK/plan.json" 2>/dev/null; then
    echo 'FAIL: a group-writable file was accepted' >&2; exit 1
fi
jq -e '.ok == false and (.error.message | contains("shared/team.txt") and contains("chmod -R go-w"))' "$WORK/plan.json" >/dev/null \
    || { echo 'FAIL: the refusal does not name the entry and the remedy' >&2; cat "$WORK/plan.json" >&2; exit 1; }
chmod 0644 "$WORK/workspace/notes/shared/team.txt"
plan
apply
test "$(cat "$WORK/other copy/shared/team.txt")" = 'group file'

# Sync covers only what the backup covers (#202): bytecode the set's backup
# excludes differs between the copies, yet a replacement beside it is
# protected, restore-verified and applied, and neither bytecode file moves.
python3 - "$WORK/state/config.json" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); c=json.loads(p.read_text()); c["sets"][0]["excludes"]=["__pycache__"]; p.write_text(json.dumps(c))
PY
mkdir -p "$WORK/workspace/notes/pkg/__pycache__" "$WORK/other copy/pkg/__pycache__"
printf '%s' 'local bytecode' > "$WORK/workspace/notes/pkg/__pycache__/m.pyc"
printf '%s' 'peer bytecode' > "$WORK/other copy/pkg/__pycache__/m.pyc"
printf '%s' 'replaced beside bytecode' > "$WORK/other copy/from peer"
"$HELPER" sync plan --set "$SET" --include-paths --json > "$WORK/plan.json"
jq -e '.ok and .data.conflicts == 0 and .data.excluded == 1 and .data.excludedPaths == ["pkg/__pycache__"]' "$WORK/plan.json" >/dev/null \
    || { echo 'FAIL: excluded bytecode was planned' >&2; cat "$WORK/plan.json" >&2; exit 1; }
apply
test "$(cat "$WORK/workspace/notes/from peer")" = 'replaced beside bytecode'
test "$(cat "$WORK/workspace/notes/pkg/__pycache__/m.pyc")" = 'local bytecode'
test "$(cat "$WORK/other copy/pkg/__pycache__/m.pyc")" = 'peer bytecode'
printf '%s' 'peer version' > "$WORK/other copy/from peer"
plan
apply
test "$(cat "$WORK/workspace/notes/from peer")" = 'peer version'
# Excluding the private protection payload must refuse before replacing a
# live value, even when an ordinary backup snapshot can still be created.
printf '%s' 'excluded replacement' > "$WORK/other copy/from peer"
python3 - "$WORK/state/config.json" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); c=json.loads(p.read_text()); c["sets"][0]["excludes"]=["vault"]; p.write_text(json.dumps(c))
PY
plan
if apply; then echo 'FAIL: excluded recovery vault authorized replacement' >&2; exit 1; fi
test "$(cat "$WORK/workspace/notes/from peer")" = 'peer version'
# Each sync backup adds a per-operation vault path, so restic's own
# host-and-paths match never finds a parent; without an explicit one every
# sync re-reads the whole backup scope. Only the repository's first snapshot
# may lack a parent.
RESTIC_PASSWORD_COMMAND="$PASSWORD_COMMAND" "$RESTIC" -r "$WORK/repo" snapshots --json > "$WORK/snapshots.json"
jq -e 'length >= 6 and ([.[] | select(.parent == null)] | length) == 1' "$WORK/snapshots.json" >/dev/null \
    || { echo 'FAIL: sync backups ran without a parent snapshot' >&2; jq -c '[.[] | {id: .short_id, parent}]' "$WORK/snapshots.json" >&2; exit 1; }
# Re-enrolling after an identity change (#197), the documented manual steps
# (docs/source-sync.md §Re-enrolling): with the exclusion removed again and
# nothing pending, drop the group's state on the coordinator and each folder's
# private control directory, and the next preview is a first run. A first run
# never deletes: identical paths agree and a path on only one side is copied.
python3 - "$WORK/state/config.json" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); c=json.loads(p.read_text()); c["sets"][0]["excludes"]=[]; p.write_text(json.dumps(c))
PY
"$HELPER" sync status --set "$SET" --json | jq -e '.data.operationId == null' >/dev/null
# Copies that differ conflict on a first run, whichever is newer; make them agree.
printf '%s' 'peer version' > "$WORK/other copy/from peer"
rm -rf "$WORK/workspace/notes/pkg/__pycache__" "$WORK/other copy/pkg/__pycache__"
printf '%s' 'only on the other copy' > "$WORK/other copy/survivor.txt"
# The control directory names are the documented ones, not a glob that could
# also hit another group's directory in the same parent.
control_name() { printf '.restic-station-sync-%s' "$(printf %s "$(cd "$1" && pwd -P)" | shasum -a 256 | cut -c1-24)"; }
test -d "$WORK/workspace/$(control_name "$WORK/workspace/notes")" && test -d "$WORK/$(control_name "$WORK/other copy")" \
    || { echo 'FAIL: the documented control directory names do not match the real ones' >&2; ls -a "$WORK/workspace" "$WORK" >&2; exit 1; }
rm -rf "$WORK/state/source-sync/$GROUP" "$WORK/workspace/$(control_name "$WORK/workspace/notes")" "$WORK/$(control_name "$WORK/other copy")"
plan
jq -e '.ok and .data.conflicts == 0 and .data.removals == 0' "$WORK/plan.json" >/dev/null \
    || { echo 'FAIL: the documented re-enrol steps did not give a first run' >&2; cat "$WORK/plan.json" >&2; exit 1; }
apply
cmp "$WORK/workspace/notes/survivor.txt" "$WORK/other copy/survivor.txt"
test "$(cat "$WORK/workspace/notes/from peer")" = 'peer version'
echo 'PASS: source sync, real restore proof, modification times, independent backup scope, deletion, replay, exclusion refusal, unreachable-repository refusal, offline mirror warning, writable-by-others refusal, backup-excluded paths, re-enrolment and parent snapshots'
