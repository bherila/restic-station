#!/bin/bash
# scripts/secret-cli-test.sh — end-to-end verification of the `secret`
# subcommands and of `FileSecretStore` (T23 / issue #25).
#
# Everything here runs against the FILE backend
# (`RESTIC_STATION_SECRET_BACKEND=file`) on whatever host it is invoked on.
# That is the point: the file backend is Linux's default, and forcing it on
# macOS is how this repository verifies the Linux secrets path before T29
# adds a Linux integration matrix.
#
# What it proves:
#   1. `secret set` reads the password from a PIPE, never from argv.
#   2. After config import creates state first, `secret set` tightens the
#      existing directory from 0755 to 0700 and creates `secrets.json` 0600.
#   3. `print-password` returns the EXACT bytes, with no trailing newline
#      (asserted byte-for-byte with `od`, not by string comparison).
#   4. `secret list` output contains no secret value.
#   5. `secret rm` is idempotent (exit 0 twice).
#   6. A widened mode (0644) is refused with an actionable message.
#   7. real restic authenticates via RESTIC_PASSWORD_COMMAND against
#      FileSecretStore — both directly and through `helper run-set`.
#   8. The password appears NOWHERE in the run log, the run index, the
#      config, or any state file the run produced.
#
# Usage:
#   scripts/secret-cli-test.sh [path-to-restic-station-helper]
# Defaults to .build/debug/restic-station-helper (built by `swift build`).
# Steps 7+8 are skipped when restic is not on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="${1:-$REPO_ROOT/.build/debug/restic-station-helper}"

SET_ID="00000000-0000-4000-8000-0000000000C0"
DEST_ID="00000000-0000-4000-8000-0000000000C1"
DEST_ID_LOWER="$(printf '%s' "$DEST_ID" | tr '[:upper:]' '[:lower:]')"

# Deliberately awkward: spaces, quotes, a dollar sign and a trailing space,
# so "we read stdin raw" is a real claim and not an artifact of a tame value.
PASSWORD='p@ss "word" with $spaces and a trailing space '

WORK=""
cleanup() {
    local code=$?
    [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
    exit "$code"
}
trap cleanup EXIT

log()  { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok: %s\n' "$*"; }

[[ -x "$HELPER" ]] || fail "helper not executable at $HELPER (run: swift build)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/restic-station-secret.XXXXXX")"
DATA_DIR="$WORK/data"
SOURCE_DIR="$WORK/source"
REPO="$WORK/repo"
mkdir -p "$DATA_DIR" "$SOURCE_DIR"
# Reproduce the ordering behind issue #49: config import reaches the data
# directory first, while it is still at the process-default 0755 mode, and
# only then does `secret set` prepare it to hold secrets. The unit test pins
# the same ordering; this is the real-helper coverage that used to be absent.
chmod 755 "$DATA_DIR"
echo "hello" > "$SOURCE_DIR/a.txt"

export RESTIC_STATION_DATA_DIR="$DATA_DIR"
export RESTIC_STATION_SECRET_BACKEND=file

RESTIC_BIN="$(command -v restic || true)"

IMPORT_CONFIG="$WORK/import-config.json"
cat > "$IMPORT_CONFIG" <<EOF
{
  "version": 1,
  "resticPath": "${RESTIC_BIN:-/usr/bin/false}",
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$SET_ID",
      "name": "Secret CLI Set",
      "sources": ["$SOURCE_DIR"],
      "excludes": [],
      "schedule": {"kind": "everyMinutes", "minutes": 5},
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 14,
      "destinations": [
        {
          "id": "$DEST_ID",
          "label": "Primary",
          "repoURL": "$REPO",
          "isPrimary": true,
          "nonSecretEnv": {}
        }
      ]
    }
  ]
}
EOF

"$HELPER" config import "$IMPORT_CONFIG" >/dev/null

SECRETS_FILE="$DATA_DIR/secrets.json"

# Portable `stat` for the permission bits.
mode_of() {
    if stat -f '%Lp' "$1" >/dev/null 2>&1; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

[[ "$(mode_of "$DATA_DIR")" == "755" ]] \
    || fail "config import did not leave the pre-existing data dir at mode 755"

# ─────────────────────────────────────────────────────────────────────────
log "1. secret set reads the password from a pipe (never argv)"
# A maximally restrictive service umask must still produce a reusable 0600
# file and mutation lock. The later set and print-password invocations are
# separate processes and therefore prove these artifacts can be reopened.
printf '%s' "$PASSWORD" | (umask 0777; "$HELPER" secret set --dest "$DEST_ID")
[[ -f "$SECRETS_FILE" ]] || fail "no $SECRETS_FILE was created"
ok "secret set stored a password"

# ─────────────────────────────────────────────────────────────────────────
log "2. file is 0600, directory is 0700"
FILE_MODE="$(mode_of "$SECRETS_FILE")"
DIR_MODE="$(mode_of "$DATA_DIR")"
LOCK_MODE="$(mode_of "$DATA_DIR/locks/secrets.lock")"
[[ "$FILE_MODE" == "600" ]] || fail "expected secrets.json mode 600, got $FILE_MODE"
[[ "$DIR_MODE" == "700" ]] || fail "expected data dir mode 700, got $DIR_MODE"
[[ "$LOCK_MODE" == "600" ]] || fail "expected secrets.lock mode 600, got $LOCK_MODE"
ok "secrets.json=$FILE_MODE secrets.lock=$LOCK_MODE data dir=$DIR_MODE"

grep -q "\"$DEST_ID_LOWER\"" "$SECRETS_FILE" \
    || fail "secrets.json is not keyed on the lowercased destination uuid"
ok "keyed on the lowercased destination uuid, mirroring the keychain accounts"

# ─────────────────────────────────────────────────────────────────────────
log "3. print-password returns the exact bytes, with no trailing newline"
# Compared as hex dumps rather than with `cmp`/`diff`: `od` is coreutils and
# is present in every container this runs in, diffutils is not guaranteed.
hexdump_of() { od -An -v -tx1 < "$1" | tr -d ' \n'; }

"$HELPER" print-password --dest "$DEST_ID" > "$WORK/printed"
printf '%s' "$PASSWORD" > "$WORK/expected"
PRINTED_HEX="$(hexdump_of "$WORK/printed")"
EXPECTED_HEX="$(hexdump_of "$WORK/expected")"
if [[ "$PRINTED_HEX" != "$EXPECTED_HEX" ]]; then
    echo "printed:  $PRINTED_HEX"
    echo "expected: $EXPECTED_HEX"
    fail "print-password did not return the exact bytes"
fi
# 0a is LF: the last byte must not be one.
[[ "${PRINTED_HEX: -2}" != "0a" ]] || fail "print-password emitted a trailing newline"
ok "byte-identical, $(wc -c < "$WORK/printed" | tr -d ' ') bytes, last byte 0x${PRINTED_HEX: -2}"

# `echo` (which appends a newline) must round-trip to the same value: the
# implementation strips exactly one trailing newline.
echo "$PASSWORD" | "$HELPER" secret set --dest "$DEST_ID" >/dev/null
"$HELPER" print-password --dest "$DEST_ID" > "$WORK/printed2"
[[ "$(hexdump_of "$WORK/printed2")" == "$EXPECTED_HEX" ]] \
    || fail "echo-piped input did not round-trip"
ok "exactly one trailing newline is stripped from piped input"

# ─────────────────────────────────────────────────────────────────────────
log "4. secret set-env, and secret list never prints a value"
printf '%s' '{"AWS_ACCESS_KEY_ID":"AKIAEXAMPLE","AWS_SECRET_ACCESS_KEY":"env-secret-value"}' \
    | "$HELPER" secret set-env --dest "$DEST_ID"

"$HELPER" secret list > "$WORK/list-out" 2>&1
cat "$WORK/list-out"
grep -q "$DEST_ID_LOWER" "$WORK/list-out" || fail "secret list did not list the destination"
grep -q "Primary" "$WORK/list-out" || fail "secret list did not print the label"
for forbidden in "$PASSWORD" "AKIAEXAMPLE" "env-secret-value"; do
    if grep -qF -- "$forbidden" "$WORK/list-out"; then
        fail "secret list leaked a secret value"
    fi
done
ok "secret list names destinations only — no password, no key, no value"

# set-env must reject junk with a clear message and a nonzero exit.
set +e
printf '%s' '["not","an","object"]' | "$HELPER" secret set-env --dest "$DEST_ID" >"$WORK/bad-env" 2>&1
BAD_RC=$?
set -e
[[ $BAD_RC -eq 1 ]] || fail "expected exit 1 for a non-object set-env, got $BAD_RC"
grep -q "array" "$WORK/bad-env" || fail "set-env error did not name the kind it got: $(cat "$WORK/bad-env")"
ok "set-env rejects a non-object with exit 1"

# ─────────────────────────────────────────────────────────────────────────
log "5. an unknown destination exits 1"
set +e
"$HELPER" secret set --dest "11111111-1111-4111-8111-111111111111" </dev/null >"$WORK/unknown" 2>&1
UNKNOWN_RC=$?
set -e
[[ $UNKNOWN_RC -eq 1 ]] || fail "expected exit 1 for an unknown destination, got $UNKNOWN_RC"
ok "unknown destination → exit 1"

# ─────────────────────────────────────────────────────────────────────────
log "6. a widened mode is refused with an actionable message"
chmod 644 "$SECRETS_FILE"
set +e
"$HELPER" print-password --dest "$DEST_ID" >"$WORK/widened" 2>&1
WIDENED_RC=$?
set -e
cat "$WORK/widened"
[[ $WIDENED_RC -ne 0 ]] || fail "a 0644 secrets file was read instead of refused"
grep -q "chmod 600" "$WORK/widened" || fail "the refusal did not name the chmod to run"
grep -qF "$SECRETS_FILE" "$WORK/widened" || fail "the refusal did not name the file"
if grep -qF -- "$PASSWORD" "$WORK/widened"; then fail "the refusal leaked the password"; fi
chmod 600 "$SECRETS_FILE"
ok "0644 refused, naming the file and the fix, without echoing the secret"

# ─────────────────────────────────────────────────────────────────────────
log "7. real restic authenticates via RESTIC_PASSWORD_COMMAND"
if [[ -z "$RESTIC_BIN" ]]; then
    echo "restic not on PATH — skipping the restic half (T29 covers it in the Linux matrix)"
else
    "$RESTIC_BIN" version

    # 7a. restic directly, with exactly the command FileSecretStore emits —
    #     including its quoting rule: double-quote the helper path only when
    #     it contains a character outside [A-Za-z0-9/._+=:,@-]. The app
    #     bundle's path ("…/Restic Station.app/…") really does contain a
    #     space, so this is not a hypothetical.
    if [[ "$HELPER" =~ ^[A-Za-z0-9/._+=:,@-]+$ ]]; then
        PWCMD="$HELPER print-password --dest $DEST_ID_LOWER"
    else
        PWCMD="\"$HELPER\" print-password --dest $DEST_ID_LOWER"
    fi
    echo "RESTIC_PASSWORD_COMMAND=[$PWCMD]"
    RESTIC_PASSWORD_COMMAND="$PWCMD" "$RESTIC_BIN" -r "$REPO" init --json >/dev/null
    ok "restic init opened the repo using the helper's print-password"

    # 7b. the whole engine path: ResticRunner assembles the env from
    #     FileSecretStore and restic authenticates with it.
    "$HELPER" run-set --set "$SET_ID" --kind backup
    SNAPSHOTS="$(RESTIC_PASSWORD_COMMAND="$PWCMD" "$RESTIC_BIN" -r "$REPO" snapshots --json)"
    printf '%s' "$SNAPSHOTS" | grep -q '"short_id"' \
        || fail "no snapshot after run-set: $SNAPSHOTS"
    ok "helper run-set produced a snapshot through FileSecretStore"

    # ─────────────────────────────────────────────────────────────────────
    log "8. the password appears in no log, run record, state file or config"
    LEAKS="$(grep -rlF -- "$PASSWORD" "$DATA_DIR" 2>/dev/null | grep -v "^$SECRETS_FILE$" || true)"
    if [[ -n "$LEAKS" ]]; then
        echo "$LEAKS"
        fail "the password appeared outside secrets.json"
    fi
    ok "the only file containing the password is secrets.json itself"

    LEAKS_ENV="$(grep -rlF "env-secret-value" "$DATA_DIR" 2>/dev/null | grep -v "^$SECRETS_FILE$" || true)"
    if [[ -n "$LEAKS_ENV" ]]; then
        echo "$LEAKS_ENV"
        fail "a secret env value appeared outside secrets.json"
    fi
    ok "no secret-env value outside secrets.json either"
fi

# ─────────────────────────────────────────────────────────────────────────
log "9. secret rm is idempotent"
"$HELPER" secret rm --dest "$DEST_ID"
"$HELPER" secret rm --dest "$DEST_ID"
"$HELPER" secret rm --dest "$DEST_ID" --env
"$HELPER" secret rm --dest "$DEST_ID" --env
ok "two removes of each kind, both exit 0"

set +e
"$HELPER" print-password --dest "$DEST_ID" >"$WORK/gone" 2>&1
GONE_RC=$?
set -e
[[ $GONE_RC -eq 1 ]] || fail "expected exit 1 reading a removed password, got $GONE_RC"
ok "the password really is gone"

"$HELPER" secret list | grep -q "no destination has a stored password" \
    || fail "secret list should report an empty store"
ok "secret list reports an empty store"

log "ALL SECRET CLI ASSERTIONS PASSED"
