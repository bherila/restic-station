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
echo 'PASS: source sync, real restore proof, modification times, independent backup scope, deletion, replay and exclusion refusal'
