#!/bin/bash
# scripts/cli-contract-test.sh — the executable half of docs/cli-json.md.
#
# That document is normative: it is what automated callers of
# `restic-station-helper --json` are entitled to rely on. This script ties
# it to the real built binary so that doc/code drift fails CI instead of
# surfacing as review findings (the motivating failure: PR #122 carried a
# P1 where an integration test still asserted the OLD documented behavior
# of a command that had been changed to refuse).
#
# It has three parts, and the order matters:
#
#   PART 1 — DRIFT CHECK. The set of subcommands in the doc's §Command
#     matrix and the set of error codes (with their documented `retryable`
#     and exit values) in §Codes are extracted from docs/cli-json.md itself
#     and compared, both directions, against this script's own contract
#     tables below. Editing the doc without updating this script — or the
#     reverse — fails here, before a single helper invocation. The built
#     helper's `--help` subcommand list is reconciled against the doc too,
#     so a command added to the binary without a matrix row also fails.
#
#   PART 2 — LIVE ASSERTIONS. For every contract row classed `live` (and
#     `env` rows whose precondition holds), the built helper is actually
#     invoked and the envelope shape (top-level keys, `error.code`,
#     `retryable`, message bound), the exit code, and the documented
#     refusal behaviors are asserted on real process output. A fake,
#     mode-file-driven restic stands in for the real one so every restic
#     exit class is reachable deterministically on hosts with no restic
#     at all (the `linux` CI container) and hosts with a real one alike.
#
#   PART 3 — COVERAGE RECONCILIATION. Every `live` row must have been
#     marked by an assertion in part 2, and every mark must correspond to
#     a table row. A table row nothing asserts, or an assertion for
#     something not in the table, fails here — so the tables cannot
#     quietly rot into documentation of their own.
#
# Coverage classes (third field of the tables):
#   live        asserted below on every platform, unconditionally.
#   env         asserted below when the environment allows; when it does
#               not, the skip is printed with its reason and still counted
#               (`restic_unsupported` needs restic discovery to fail, which
#               a host with a usable well-known restic cannot simulate;
#               `timer …` is Linux-only and its macOS assertion is the
#               documented absence).
#   unit:<why>  no shell-reachable producer exists; the code↔exit↔retryable
#               mapping is pinned by Core/Tests/…/Support/CLIErrorTests.swift
#               and Helper/Tests/HelperTests/CLIErrorEnvelopeTests.swift
#               instead. Declared here so the drift check still covers the
#               doc row, and reconciliation fails if a live assertion is
#               later added without reclassifying.
#
# NEGATIVE-ASSERTION convention (docs/testing.md §Negative assertions):
# every "nothing happened" claim below is proved with a filter-free check —
# a run count that must not change at all, a data directory listing that
# must gain no entry of any kind — never with a success-only filter that a
# differently-shaped record could slip past.
#
# Usage:
#   scripts/cli-contract-test.sh [path-to-restic-station-helper]
# Defaults to .build/debug/restic-station-helper (built by `swift build`).
# Uses the FILE secret backend unconditionally, like the other Layer-2
# scripts, so the same assertions run on macOS and Linux. jq is required
# (#125): CI installs it, and failing fast beats a confusing mid-script
# "jq: command not found".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="${1:-$REPO_ROOT/.build/debug/restic-station-helper}"
DOC="$REPO_ROOT/docs/cli-json.md"

[[ -x "$HELPER" ]] || { echo "helper not executable at $HELPER (run: swift build)" >&2; exit 1; }
[[ -f "$DOC" ]] || { echo "docs/cli-json.md not found at $DOC" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || {
    echo "FATAL: jq is required for cli-contract-test.sh JSON assertions. Install jq and rerun." >&2
    exit 1
}

WORK=""
cleanup() {
    local code=$?
    [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
    exit "$code"
}
trap cleanup EXIT

WORK="$(mktemp -d "${TMPDIR:-/tmp}/restic-station-contract.XXXXXX")"
COMBINED_LOG="$WORK/combined.log"
touch "$COMBINED_LOG" "$WORK/marked-codes" "$WORK/marked-cmds"

log()  { printf '\n=== %s ===\n' "$*" | tee -a "$COMBINED_LOG"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok: %s\n' "$*"; }

# ─────────────────────────────────────────────────────────────────────────
# The contract tables. `code|retryable|exit|class` and `command|mode|class`.
# The first three fields of CODE_TABLE and the first two of CMD_TABLE are
# compared verbatim against what PART 1 extracts from docs/cli-json.md —
# they restate the doc on purpose, so that a doc edit and a table edit have
# to travel together. `exit` is the doc's exit column with whitespace and
# bold markers stripped ("64 / 1" → "64/1").
# ─────────────────────────────────────────────────────────────────────────
CODE_TABLE='invalid_arguments|no|64/1|live
config_invalid|no|1|live
set_not_found|no|1|live
set_disabled_here|no|1|unit:no command emits it — only tests construct it (see the report note in this PR)
destination_not_found|no|1|live
destination_disabled_here|no|1|unit:no command emits it — only tests construct it
run_not_found|no|1|live
set_busy|yes|2|live
repository_offline|yes|3|live
repository_locked|yes|1|live
repository_not_initialized|no|1|live
secret_unavailable|yes|1|unit:every retryable store failure is an errno case (EACCES opening secrets.json is the only portable one) and the linux CI container runs as root, where DAC cannot produce it — pinned in Swift by SecretStoreErrorTableTests and KeychainSecretStoreTests instead
secret_not_configured|no|1|unit:reaching classify(itemNotFound) needs a keychain/secret-env miss no fixture can stage portably
secret_store_unusable|no|1|live
secret_rejected|no|1|live
restic_not_found|no|1|live
restic_unsupported|no|1|env
restic_failed|no|1|live
operation_timed_out|yes|1|unit:needs a restic that stalls past ResticRunner timeouts — not stageable in a bounded shell test
preview_expired|no|1|live
operation_not_allowed|no|1|live
operation_completed_audit_failed|no|1|unit:needs a destructive launch whose audit trail is corrupted mid-flight (#128 pins it in Swift)
internal_error|no|1|live'

CMD_TABLE='version|json|live
status|json|live
sets list|json|live
runs list|json|live
runs show|json|live
config show|json|live
config validate|json|live
probe-repo|json|live
secret list|json|live
cli status|json|live
fda-check|json|live
purge preview|json|live
purge apply|json|live
maintenance prune|json|live
config export|nojson|live
timer status|nojson|env
print-password|nojson|live
tick|nojson|live
run-set|nojson|live
restore|nojson|live
init-secondary|nojson|live
unlock|nojson|live
config import|nojson|live
secret set|nojson|live
secret set-env|nojson|live
secret rm|nojson|live
cli install|nojson|live
cli uninstall|nojson|live
timer install|nojson|env
timer uninstall|nojson|env'

# ─────────────────────────────────────────────────────────────────────────
# Shared plumbing (same shapes as scripts/headless-cli-test.sh).
# ─────────────────────────────────────────────────────────────────────────
OUT_FILE="$WORK/last-out"
ERR_FILE="$WORK/last-err"
RC=0
run_helper_split() {
    OUT_FILE="$WORK/out-$$-$RANDOM"
    ERR_FILE="$WORK/err-$$-$RANDOM"
    set +e
    "$HELPER" "$@" >"$OUT_FILE" 2>"$ERR_FILE"
    RC=$?
    set -e
    cat "$OUT_FILE" "$ERR_FILE" >>"$COMBINED_LOG"
}

# Feeds one bounded stdin payload without ever placing it in argv. The
# helper's exit status is taken from PIPESTATUS immediately — nothing may
# run in between, PIPESTATUS is overwritten by every command.
run_helper_stdin() {
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
        cat "$OUT_FILE" "$ERR_FILE" >&2
        fail "expected exit $expected, got $RC"
    }
}

mark_code() { printf '%s\n' "$1" >>"$WORK/marked-codes"; }
mark_cmd()  { printf '%s\n' "$1" >>"$WORK/marked-cmds"; }

table_field() { # table_field <table> <key> <field-number>
    printf '%s\n' "$1" | awk -F'|' -v k="$2" -v f="$3" '$1==k{print $f; found=1} END{if(!found) exit 1}'
}

# Asserts OUT_FILE holds exactly the documented error envelope for <code>:
# the three top-level keys, ok=false, schemaVersion=1, the code, the
# `retryable` value from CODE_TABLE, the 500-character message bound, and
# an exit code consistent with the table (the caller still pins the exact
# one for `invalid_arguments`, whose documented exit is "64/1").
assert_error_envelope() {
    local code="$1"
    jq -e . "$OUT_FILE" >/dev/null 2>&1 \
        || fail "$code: stdout is not one JSON document: $(cat "$OUT_FILE")"
    [[ "$(jq -r 'keys | join(",")' "$OUT_FILE")" == "error,ok,schemaVersion" ]] \
        || fail "$code: unexpected top-level keys: $(jq -r 'keys | join(",")' "$OUT_FILE")"
    [[ "$(jq -r '.ok' "$OUT_FILE")" == "false" ]] || fail "$code: ok was not false"
    [[ "$(jq -r '.schemaVersion' "$OUT_FILE")" == "1" ]] || fail "$code: schemaVersion was not 1"
    [[ "$(jq -r '.error.code' "$OUT_FILE")" == "$code" ]] \
        || fail "expected error.code $code, got $(jq -r '.error.code' "$OUT_FILE")"
    jq -e '.error | keys - ["code","message","retryable","details"] | length == 0' "$OUT_FILE" >/dev/null \
        || fail "$code: error object has undocumented keys: $(jq -r '.error | keys | join(",")' "$OUT_FILE")"
    local want_retryable
    want_retryable="$(table_field "$CODE_TABLE" "$code" 2)" \
        || fail "$code is not in CODE_TABLE"
    local got_retryable
    got_retryable="$(jq -r '.error.retryable' "$OUT_FILE")"
    [[ "$want_retryable" == "yes" && "$got_retryable" == "true" \
        || "$want_retryable" == "no" && "$got_retryable" == "false" ]] \
        || fail "$code: retryable was $got_retryable, table says $want_retryable"
    jq -e '.error.message | length > 0 and length <= 500' "$OUT_FILE" >/dev/null \
        || fail "$code: message is empty or exceeds the 500-character cap"
    local want_exit
    want_exit="$(table_field "$CODE_TABLE" "$code" 3)"
    case "$want_exit" in
        *"/"*) [[ "$RC" == "${want_exit%%/*}" || "$RC" == "${want_exit##*/}" ]] \
                   || fail "$code: exit $RC not in documented set $want_exit" ;;
        *)     [[ "$RC" == "$want_exit" ]] \
                   || fail "$code: exit $RC, documented exit $want_exit" ;;
    esac
}

# Asserts OUT_FILE holds exactly the documented success envelope.
assert_success_envelope() {
    local label="$1"
    jq -e . "$OUT_FILE" >/dev/null 2>&1 \
        || fail "$label: stdout is not one JSON document: $(cat "$OUT_FILE")"
    [[ "$(jq -r 'keys | join(",")' "$OUT_FILE")" == "data,ok,schemaVersion" ]] \
        || fail "$label: unexpected top-level keys: $(jq -r 'keys | join(",")' "$OUT_FILE")"
    [[ "$(jq -r '.ok' "$OUT_FILE")" == "true" ]] || fail "$label: ok was not true"
    [[ "$(jq -r '.schemaVersion' "$OUT_FILE")" == "1" ]] || fail "$label: schemaVersion was not 1"
}

# ─────────────────────────────────────────────────────────────────────────
# PART 1 — DRIFT CHECK: docs/cli-json.md ↔ the tables above ↔ --help.
#
# Parsing assumptions, stated so a failure here is diagnosable: the
# §Command matrix and §Codes sections are pipe tables whose data rows start
# with "| `"; the matrix's first cell carries backticked command names
# (a " <placeholder>" operand is stripped; a bare shorthand like
# `set-env`/`uninstall` after a two-word name inherits that name's first
# word); its second cell is "✅" for --json rows. A structural rewrite of
# either table will land here — that is this check working, not breaking:
# re-anchor the extraction together with the rewrite.
# ─────────────────────────────────────────────────────────────────────────
log "PART 1: drift check against docs/cli-json.md"

DOC_CMDS_FILE="$WORK/doc-cmds"
awk '/^## Command matrix/{flag=1; next} /^## /{flag=0} flag && /^\| `/' "$DOC" \
| while IFS= read -r row; do
    cell1=$(printf '%s' "$row" | awk -F'|' '{print $2}')
    cell2=$(printf '%s' "$row" | awk -F'|' '{print $3}')
    if printf '%s' "$cell2" | grep -q "✅"; then mode=json; else mode=nojson; fi
    prefix=""
    # shellcheck disable=SC2016 # literal backticks, not command substitution
    printf '%s\n' "$cell1" | grep -o '`[^`]*`' | tr -d '`' | while IFS= read -r tok; do
        tok=$(printf '%s' "$tok" | sed 's/ <[^>]*>.*$//')
        case "$tok" in
            *" "*) prefix="${tok%% *}" ;;
            *) if [[ -n "$prefix" ]]; then tok="$prefix $tok"; fi ;;
        esac
        printf '%s|%s\n' "$tok" "$mode"
    done
done > "$DOC_CMDS_FILE"
[[ -s "$DOC_CMDS_FILE" ]] || fail "extracted no commands from $DOC §Command matrix — did its structure change?"

TABLE_CMDS_FILE="$WORK/table-cmds"
printf '%s\n' "$CMD_TABLE" | awk -F'|' '{print $1 "|" $2}' > "$TABLE_CMDS_FILE"
if ! diff <(sort "$DOC_CMDS_FILE") <(sort "$TABLE_CMDS_FILE") >"$WORK/cmd-drift" 2>&1; then
    cat "$WORK/cmd-drift" >&2
    fail "command drift: docs/cli-json.md §Command matrix and cli-contract-test.sh CMD_TABLE disagree (< doc, > table). Update them together."
fi
ok "command matrix: $(wc -l < "$DOC_CMDS_FILE" | tr -d ' ') documented commands match CMD_TABLE, --json markings included"

DOC_CODES_FILE="$WORK/doc-codes"
awk '/^## Codes/{flag=1; next} /^##/{flag=0} flag && /^\| `/' "$DOC" \
| while IFS= read -r row; do
    code=$(printf '%s' "$row" | awk -F'|' '{print $2}' | tr -d '` ')
    [[ "$code" == "code" ]] && continue   # the header row
    retry=$(printf '%s' "$row" | awk -F'|' '{print $3}' | sed 's/\*//g; s/^ *//; s/ *$//')
    exitc=$(printf '%s' "$row" | awk -F'|' '{print $4}' | sed 's/\*//g; s/ //g')
    printf '%s|%s|%s\n' "$code" "$retry" "$exitc"
done > "$DOC_CODES_FILE"
[[ -s "$DOC_CODES_FILE" ]] || fail "extracted no codes from $DOC §Codes — did its structure change?"

TABLE_CODES_FILE="$WORK/table-codes"
printf '%s\n' "$CODE_TABLE" | awk -F'|' '{print $1 "|" $2 "|" $3}' > "$TABLE_CODES_FILE"
if ! diff <(sort "$DOC_CODES_FILE") <(sort "$TABLE_CODES_FILE") >"$WORK/code-drift" 2>&1; then
    cat "$WORK/code-drift" >&2
    fail "code drift: docs/cli-json.md §Codes and cli-contract-test.sh CODE_TABLE disagree (< doc, > table) on code, retryable, or exit. Update them together."
fi
ok "codes: $(wc -l < "$DOC_CODES_FILE" | tr -d ' ') documented codes match CODE_TABLE, retryable and exit columns included"

# The binary leg: every top-level subcommand `--help` advertises must have
# a matrix row, and every documented top level must exist in the binary.
# `print-password` is documented as hidden (absent from --help, reachable);
# `timer` is documented Linux-only. Both are the special cases they say
# they are, and both directions are asserted rather than skipped.
HELP_OUT="$WORK/help-out"
"$HELPER" --help > "$HELP_OUT" 2>&1 || fail "--help exited non-zero"
HELP_SUBS_FILE="$WORK/help-subs"
awk '/^SUBCOMMANDS/{flag=1; next} /^[A-Z]/{flag=0} flag' "$HELP_OUT" \
    | sed -n 's/^  \([a-z][a-z-]*\).*/\1/p' | sort -u > "$HELP_SUBS_FILE"
[[ -s "$HELP_SUBS_FILE" ]] || fail "could not parse a SUBCOMMANDS list out of --help"

DOC_TOPS_FILE="$WORK/doc-tops"
awk -F'|' '{print $1}' "$DOC_CMDS_FILE" | awk '{print $1}' | sort -u > "$DOC_TOPS_FILE"
while IFS= read -r sub; do
    grep -qx "$sub" "$DOC_TOPS_FILE" \
        || fail "--help lists subcommand '$sub' but docs/cli-json.md's matrix has no row for it"
done < "$HELP_SUBS_FILE"
while IFS= read -r top; do
    case "$top" in
        print-password)
            grep -qx "$top" "$HELP_SUBS_FILE" \
                && fail "print-password is documented as hidden but appears in --help"
            "$HELPER" print-password --help >/dev/null 2>&1 \
                || fail "print-password is documented as reachable but --help on it failed"
            ;;
        timer)
            if [[ "$(uname -s)" == "Darwin" ]]; then
                grep -qx "$top" "$HELP_SUBS_FILE" \
                    && fail "timer is documented as Linux-only but appears in macOS --help"
            else
                grep -qx "$top" "$HELP_SUBS_FILE" \
                    || fail "timer is documented for Linux but missing from Linux --help"
            fi
            ;;
        *)
            grep -qx "$top" "$HELP_SUBS_FILE" \
                || fail "docs/cli-json.md documents '$top' but --help does not list it"
            ;;
    esac
done < "$DOC_TOPS_FILE"
ok "--help subcommand list reconciles with the matrix (print-password hidden, timer platform-scoped)"

# ─────────────────────────────────────────────────────────────────────────
# Fixtures. One fake, mode-file-driven restic serves every scenario: line 1
# is its exit code, line 2 its stdout (or "-"), line 3 a FIFO to block on
# (or "-"). The helper deliberately does not pass its own environment to
# restic, so an env-var-driven fake would silently test nothing — the
# control has to travel through the filesystem.
# ─────────────────────────────────────────────────────────────────────────
log "fixtures"

SET_ID="20000000-0000-4000-8000-000000000001"
PRIMARY_ID="20000000-0000-4000-8000-000000000002"
UNKNOWN_ID="99999999-0000-4000-8000-000000000009"
FIXTURE="$WORK/data"
REPO_DIR="$WORK/repo"
FAKE_DIR="$WORK/fake"
MODE_FILE="$FAKE_DIR/mode"
mkdir -p "$FIXTURE" "$REPO_DIR" "$FAKE_DIR"

fake_mode() { printf '%s\n%s\n%s\n' "${1:-0}" "${2:--}" "${3:--}" > "$MODE_FILE"; }
fake_mode 0

cat > "$FAKE_DIR/restic" <<SH
#!/bin/sh
if [ "\$1" = "version" ]; then
  echo '{"version":"0.18.1","go_version":"go1.22.0","go_os":"any","go_arch":"any"}'
  exit 0
fi
CODE=\$(sed -n 1p "$MODE_FILE")
OUT=\$(sed -n 2p "$MODE_FILE")
FIFO=\$(sed -n 3p "$MODE_FILE")
if [ -n "\$FIFO" ] && [ "\$FIFO" != "-" ]; then
  : > "\$FIFO.reached"
  cat "\$FIFO" > /dev/null
fi
if [ -n "\$OUT" ] && [ "\$OUT" != "-" ]; then printf '%s\n' "\$OUT"; fi
exit "\${CODE:-0}"
SH
chmod +x "$FAKE_DIR/restic"

write_config() { # write_config <dir> <resticPath-or-null-json>
    local dir="$1" restic_json="$2"
    cat > "$dir/config.json" <<EOF
{
  "version": 3,
  "resticPath": $restic_json,
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "$SET_ID",
      "name": "Projects",
      "sources": ["/tmp/src"],
      "excludes": [],
      "purgeExcludes": ["/tmp/src/scratch"],
      "schedule": {"kind": "daily", "hour": 2, "minute": 30},
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 14,
      "destinations": [
        {"id": "$PRIMARY_ID", "label": "Primary", "repoURL": "$REPO_DIR", "isPrimary": true, "nonSecretEnv": {}}
      ]
    }
  ]
}
EOF
}
write_config "$FIXTURE" "\"$FAKE_DIR/restic\""

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
ONE_HOUR_AGO_TS=$(( $(date -u +%s) - 3600 ))
ONE_HOUR_AGO_ISO=$(date -u -r "$ONE_HOUR_AGO_TS" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
    || date -u -d "@$ONE_HOUR_AGO_TS" +%Y-%m-%dT%H:%M:%S.000Z)
mkdir -p "$FIXTURE/runs/r-1" "$FIXTURE/state"
cat > "$FIXTURE/runs/index.jsonl" <<EOF
{"runId":"r-1","kind":"backup","setId":"$SET_ID","destId":"$PRIMARY_ID","groupId":"r-1","status":"success","start":"$ONE_HOUR_AGO_ISO","end":"$ONE_HOUR_AGO_ISO","trigger":"scheduled","snapshotId":"abc123","filesNew":1,"filesChanged":0,"dataAdded":100,"errorSummary":null}
EOF
cat > "$FIXTURE/runs/r-1/metadata.json" <<EOF
{"runId":"r-1","kind":"backup","setId":"$SET_ID","destId":"$PRIMARY_ID","groupId":"r-1","status":"success","trigger":"scheduled","start":"$ONE_HOUR_AGO_ISO","end":"$ONE_HOUR_AGO_ISO","pid":1,"resticExitCode":0,"argvRedacted":["restic","backup"],"snapshotId":"abc123","filesNew":1,"filesChanged":0,"dataAdded":100,"errorSummary":null,"stats":null}
EOF
cat > "$FIXTURE/state/repo-status-$PRIMARY_ID.json" <<EOF
{"destId":"$PRIMARY_ID","reachable":true,"probedAt":"$NOW_ISO","lastSyncedAt":"$ONE_HOUR_AGO_ISO","lastError":null}
EOF

BROKEN="$WORK/broken-data"
mkdir -p "$BROKEN"
echo 'not valid json{{{' > "$BROKEN/config.json"

WARN="$WORK/warn-data"
mkdir -p "$WARN/runs" "$WARN/state"
write_config "$WARN" "\"$FAKE_DIR/restic\""
cat > "$WARN/runs/index.jsonl" <<EOF
{"runId":"r-bad","kind":"backup","setId":"$SET_ID","destId":"$PRIMARY_ID","groupId":"r-bad","status":"failed","start":"$ONE_HOUR_AGO_ISO","end":"$ONE_HOUR_AGO_ISO","trigger":"scheduled","snapshotId":null,"filesNew":null,"filesChanged":null,"dataAdded":null,"errorSummary":"wrong password"}
EOF

export RESTIC_STATION_SECRET_BACKEND=file
# Exported as the default for every invocation below, so a call that
# forgets its per-command override can only ever touch this sandbox —
# never the real data directory of the machine running the tests. The
# broken/warn/containment fixtures still override it per call.
export RESTIC_STATION_DATA_DIR="$FIXTURE"
# shellcheck disable=SC2016 # a literal $, deliberately awkward, never expanded
SECRET_PASSWORD='c0ntract "cli" $ecret with spaces '
printf '%s' "$SECRET_PASSWORD" \
    | RESTIC_STATION_DATA_DIR="$FIXTURE" "$HELPER" secret set --dest "$PRIMARY_ID" >>"$COMBINED_LOG" 2>&1 \
    || fail "could not seed the fixture password"

# `status --json` documents exit 1 for warning/critical health, and the
# real host scheduler (LaunchAgent / systemd timer) is probed for real —
# so on an otherwise healthy fixture the exit depends on the machine this
# runs on. Same accommodation scripts/headless-cli-test.sh makes.
CLEAN_STATUS_RC=0
capture_clean_status_rc() {
    if jq -e '.data | .scheduler.healthy == false' "$OUT_FILE" >/dev/null; then
        CLEAN_STATUS_RC=1
    else
        CLEAN_STATUS_RC=0
    fi
}

run_count() {
    RESTIC_STATION_DATA_DIR="$FIXTURE" "$HELPER" runs list --json 2>/dev/null | jq -r '.data | length'
}

# ─────────────────────────────────────────────────────────────────────────
# PART 2a — §The two envelopes: every --json command emits exactly
# {schemaVersion, ok, data} on success, and the payload carries what the
# matrix row says it carries.
# ─────────────────────────────────────────────────────────────────────────
log "PART 2a: success envelopes and documented payloads"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split version --json
expect_rc 0
assert_success_envelope "version --json"
jq -e '.data | has("name") and has("version") and has("platform")' "$OUT_FILE" >/dev/null \
    || fail "version --json payload is not { name, version, platform }"
mark_cmd "version"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split status --json
capture_clean_status_rc
expect_rc "$CLEAN_STATUS_RC"
assert_success_envelope "status --json"
jq -e '.data | (.machineId | length > 0) and has("health") and has("sets")' "$OUT_FILE" >/dev/null \
    || fail "status --json payload is not a StatusReport"
mark_cmd "status"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split sets list --json
expect_rc 0
assert_success_envelope "sets list --json"
jq -e '.data | type == "array"' "$OUT_FILE" >/dev/null || fail "sets list --json data is not an array"
mark_cmd "sets list"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split runs list --json
expect_rc 0
assert_success_envelope "runs list --json"
jq -e '.data | type == "array" and (.[0].runId == "r-1")' "$OUT_FILE" >/dev/null \
    || fail "runs list --json data is not an array of RunIndexEntry"
mark_cmd "runs list"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split runs show r-1 --json
expect_rc 0
assert_success_envelope "runs show --json"
jq -e '.data | .runId == "r-1" and has("argvRedacted")' "$OUT_FILE" >/dev/null \
    || fail "runs show --json data is not RunMetadata"
mark_cmd "runs show"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split config show --json
expect_rc 0
assert_success_envelope "config show --json"
jq -e '.data | (.machineId | length > 0) and (.sets | length == 1)' "$OUT_FILE" >/dev/null \
    || fail "config show --json data is not the effective-config report"
mark_cmd "config show"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split config validate --json
expect_rc 0
assert_success_envelope "config validate --json"
jq -e '.data | has("machineId") and has("errors") and has("warnings") and has("effective") and has("nothingRunsHere")' \
    "$OUT_FILE" >/dev/null \
    || fail "config validate --json data is not { machineId, errors, warnings, effective, nothingRunsHere }"
mark_cmd "config validate"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split secret list --json
expect_rc 0
assert_success_envelope "secret list --json"
jq -e --arg id "$PRIMARY_ID" \
    '.data | type == "array" and length == 1
        and (.[0] | (.destId | ascii_downcase) == ($id | ascii_downcase) and .hasPassword)
        and ([.[0] | keys] | flatten | unique | inside(["destId","label","setName","hasPassword","secretEnvCount"]))' \
    "$OUT_FILE" >/dev/null \
    || fail "secret list --json is not the documented presence-only array: $(jq -c '.data' "$OUT_FILE")"
mark_cmd "secret list"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split cli status --json
expect_rc 0
assert_success_envelope "cli status --json"
jq -e '.data | has("installed") and has("linkPath")' "$OUT_FILE" >/dev/null \
    || fail "cli status --json data is not CLIInstaller.Status"
mark_cmd "cli status"

# fda-check has three documented states, not two: off macOS `applicable`
# is false and `granted` is null — a caller must branch on `applicable`
# before reading `granted`.
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split fda-check --json
assert_success_envelope "fda-check --json"
jq -e '.data | has("applicable") and has("granted") and has("probedPath") and has("checkedAt") and has("context")' \
    "$OUT_FILE" >/dev/null \
    || fail "fda-check --json data is missing documented keys"
if [[ "$(uname -s)" == "Darwin" ]]; then
    jq -e '.data.applicable == true' "$OUT_FILE" >/dev/null \
        || fail "fda-check --json on macOS did not report applicable=true"
else
    jq -e '.data.applicable == false and .data.granted == null' "$OUT_FILE" >/dev/null \
        || fail "fda-check --json off macOS must report applicable=false, granted=null"
fi
mark_cmd "fda-check"

# probe-repo: both non-error outcomes, deterministically. Offline is a
# SUCCESS envelope at exit 3 — an unplugged drive is a destination's
# expected state, and the field to branch on is `outcome`.
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split probe-repo --set "$SET_ID" --dest "$PRIMARY_ID" --json
expect_rc 0
assert_success_envelope "probe-repo --json (reachable)"
[[ "$(jq -r '.data | keys | join(",")' "$OUT_FILE")" == "destinationId,label,outcome,reachable,reason,setId" ]] \
    || fail "probe-repo --json payload keys drifted: $(jq -r '.data | keys | join(",")' "$OUT_FILE")"
jq -e '.data | .outcome == "reachable" and .reachable == true and .reason == null' "$OUT_FILE" >/dev/null \
    || fail "probe-repo did not report the existing local repo as reachable"

mv "$REPO_DIR" "$REPO_DIR.unplugged"
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split probe-repo --set "$SET_ID" --dest "$PRIMARY_ID" --json
expect_rc 3
assert_success_envelope "probe-repo --json (offline)"
jq -e '.data | .outcome == "offline" and .reachable == false and .reason != null' "$OUT_FILE" >/dev/null \
    || fail "probe-repo offline must be a success envelope with outcome=offline at exit 3, got $(jq -c . "$OUT_FILE")"
mv "$REPO_DIR.unplugged" "$REPO_DIR"

# There is deliberately no third probe-repo case here: this fixture's only
# destination is a local path, which `Reachability` answers with a
# `FileManager` existence check and never reads a secret for. The
# permanent-refusal arm (`outcome` replaced by a non-retryable error
# envelope, #96) is pinned in Swift by `ReachabilityTests` instead.
mark_cmd "probe-repo"
ok "probe-repo: reachable → ok/0, offline → success envelope with outcome=offline at exit 3"

# purge preview: a success is an array of per-destination plans.
fake_mode 0 '[]'
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split purge preview --set "$SET_ID" --json
expect_rc 0
assert_success_envelope "purge preview --json"
jq -e '.data | type == "array" and (.[0] | has("matched") and has("changed") and has("unattributed") and has("patterns") and has("previewToken"))' \
    "$OUT_FILE" >/dev/null \
    || fail "purge preview --json data is not an array of per-destination purge plans"
fake_mode 0
mark_cmd "purge preview"

# maintenance prune: a completed dry run carries `confirmationBinding` and
# `destinationFingerprint`; a real prune without the selector (the
# documented unbound direct-CLI path) completes and does NOT carry a
# binding — "present only for a dry run that completed".
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split maintenance prune --set "$SET_ID" --dry-run --json
expect_rc 0
assert_success_envelope "maintenance prune --dry-run --json"
jq -e '.data | .dryRun == true and .status == "success"
    and (.confirmationBinding | type == "string" and length > 0)
    and (.destinationFingerprint | length > 0)' "$OUT_FILE" >/dev/null \
    || fail "maintenance prune dry run did not carry its confirmation binding: $(jq -c '.data' "$OUT_FILE")"
DRY_BINDING="$(jq -r '.data.confirmationBinding' "$OUT_FILE")"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split maintenance prune --set "$SET_ID" --json
expect_rc 0
assert_success_envelope "maintenance prune --json (unbound real prune)"
jq -e '.data | .dryRun == false and .status == "success" and (has("confirmationBinding") | not)' \
    "$OUT_FILE" >/dev/null \
    || fail "an unbound real prune must complete without a confirmationBinding: $(jq -c '.data' "$OUT_FILE")"
mark_cmd "maintenance prune"
ok "all 13 asserted --json commands emit {schemaVersion, ok, data} with their documented payloads"

# The consumed-binding flow: the dry run's binding, fed through the
# documented stdin selector, authorizes exactly one real prune.
run_helper_stdin "$DRY_BINDING" maintenance prune --set "$SET_ID" --expected-destination-stdin --json
expect_rc 0
assert_success_envelope "maintenance prune (bound)"
jq -e '.data.status == "success"' "$OUT_FILE" >/dev/null \
    || fail "a fresh binding was refused: $(jq -c . "$OUT_FILE")"
ok "a fresh confirmationBinding round-trips through --expected-destination-stdin"

# ─────────────────────────────────────────────────────────────────────────
# PART 2b — §The error branch and §Codes: produce each `live` code for
# real and assert the envelope against the CODE_TABLE row (which PART 1
# proved identical to the doc's row).
# ─────────────────────────────────────────────────────────────────────────
log "PART 2b: error envelopes, code by code"

# config_invalid — also the documented 500-character message cap's own
# test case: an unloadable config.json used to quote the offending bytes.
RESTIC_STATION_DATA_DIR="$BROKEN" run_helper_split status --json
assert_error_envelope "config_invalid"
mark_code "config_invalid"
ok "config_invalid: broken config.json → envelope, exit 1, message capped"

# invalid_arguments exits 64 for a parse failure (with an envelope even
# though parsing never reached a --json flag) and 1 for a command's own
# validation. Human-mode parse failures keep stdout empty at the same 64.
run_helper_split runs show --json
expect_rc 64
assert_error_envelope "invalid_arguments"
run_helper_split runs show
expect_rc 64
[[ ! -s "$OUT_FILE" ]] || fail "a human-mode parse failure wrote to stdout"
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split runs list --limit 0 --json
expect_rc 1
assert_error_envelope "invalid_arguments"
jq -e '.error | has("details") | not' "$OUT_FILE" >/dev/null \
    || fail "empty details must be omitted entirely, got $(jq -c '.error.details' "$OUT_FILE")"
mark_code "invalid_arguments"
ok "invalid_arguments: 64 for a parse failure (both modes agree), 1 for --limit 0, empty details omitted"

# --help is a clean exit in every mode.
run_helper_split status --json --help
expect_rc 0
grep -q 'OVERVIEW' "$OUT_FILE" || fail "--json --help stopped printing help"
ok "--json --help prints help and exits 0"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split runs show no-such-run --json
expect_rc 1
assert_error_envelope "run_not_found"
[[ "$(jq -r '.error.details.runId' "$OUT_FILE")" == "no-such-run" ]] \
    || fail "run_not_found did not carry details.runId"
mark_code "run_not_found"
ok "run_not_found: exit 1 with the runId in details"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split probe-repo --set "$UNKNOWN_ID" --dest "$PRIMARY_ID" --json
expect_rc 1
assert_error_envelope "set_not_found"
jq -e --arg id "$UNKNOWN_ID" '.error.details.setId == ($id | ascii_downcase) or .error.details.setId == $id' \
    "$OUT_FILE" >/dev/null || fail "set_not_found did not carry details.setId"
mark_code "set_not_found"

RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split probe-repo --set "$SET_ID" --dest "$UNKNOWN_ID" --json
expect_rc 1
assert_error_envelope "destination_not_found"
jq -e '.error.details | has("setId") and has("destinationId")' "$OUT_FILE" >/dev/null \
    || fail "destination_not_found did not carry both ids"
mark_code "destination_not_found"
ok "set_not_found / destination_not_found: exit 1 with ids in details"

# repository_offline from a mutating-path command IS an error (unlike
# probe-repo's report) and keeps exit 3. The doc names purge preview.
mv "$REPO_DIR" "$REPO_DIR.unplugged"
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split purge preview --set "$SET_ID" --json
expect_rc 3
assert_error_envelope "repository_offline"
mv "$REPO_DIR.unplugged" "$REPO_DIR"
mark_code "repository_offline"
ok "repository_offline: purge preview on a missing local repo → envelope, exit 3"

# restic exit classes, via the fake restic's mode file. The documented
# `details.resticExitCode` must carry restic's own code.
restic_exit_case() { # restic_exit_case <restic-exit> <expected-code>
    fake_mode "$1"
    RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split maintenance prune --set "$SET_ID" --dry-run --json
    expect_rc 1
    assert_error_envelope "$2"
    [[ "$(jq -r '.error.details.resticExitCode' "$OUT_FILE")" == "$1" ]] \
        || fail "$2 did not carry details.resticExitCode=$1"
    fake_mode 0
    mark_code "$2"
}
restic_exit_case 11 "repository_locked"
restic_exit_case 10 "repository_not_initialized"
restic_exit_case 12 "secret_rejected"
restic_exit_case 9  "restic_failed"
ok "restic exits 11/10/12/9 → repository_locked / repository_not_initialized / secret_rejected / restic_failed, each with resticExitCode in details"

# restic_not_found: the pinned executable cannot be read, so the
# destructive path refuses before anything can launch.
write_config "$FIXTURE" "\"$FAKE_DIR/no-such-restic\""
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split maintenance prune --set "$SET_ID" --dry-run --json
expect_rc 1
assert_error_envelope "restic_not_found"
write_config "$FIXTURE" "\"$FAKE_DIR/restic\""
mark_code "restic_not_found"
ok "restic_not_found: an unreadable pinned restic refuses the prune at exit 1"

# secret_store_unusable: the file backend's documented refusal of a widened
# secrets.json. Mode-based, so it holds even when running as root (the
# linux CI container does) — which is also why it is this code and not
# `secret_unavailable` that a shell fixture can reach. The refusal is
# permanent: no repetition of this request can widen-then-narrow the mode,
# so the envelope must say `retryable: false` (#96).
chmod 0644 "$FIXTURE/secrets.json"
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split maintenance prune --set "$SET_ID" --dry-run --json
expect_rc 1
assert_error_envelope "secret_store_unusable"
jq -e '.error.message | test("chmod 600")' "$OUT_FILE" >/dev/null \
    || fail "the refusal did not carry the exact chmod to run"
chmod 0600 "$FIXTURE/secrets.json"
mark_code "secret_store_unusable"
ok "secret_store_unusable: a group-accessible secrets.json is refused, non-retryable, exit 1"

# set_busy: a purge preview parked inside the fake restic (blocked on a
# FIFO) holds the set lock; a concurrent prune of the same set must answer
# set_busy at exit 2 rather than wait or proceed.
BUSY_FIFO="$WORK/busy-fifo"
mkfifo "$BUSY_FIFO"
fake_mode 0 '[]' "$BUSY_FIFO"
RESTIC_STATION_DATA_DIR="$FIXTURE" "$HELPER" purge preview --set "$SET_ID" --json \
    >"$WORK/busy-bg.out" 2>"$WORK/busy-bg.err" &
BUSY_PID=$!
BUSY_REACHED=0
for _ in $(seq 1 200); do
    [[ -e "$BUSY_FIFO.reached" ]] && { BUSY_REACHED=1; break; }
    sleep 0.05
done
[[ "$BUSY_REACHED" -eq 1 ]] || fail "the backgrounded preview never reached its restic invocation"
fake_mode 0   # the foreground prune must not block if it ever reaches restic
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split maintenance prune --set "$SET_ID" --dry-run --json
expect_rc 2
assert_error_envelope "set_busy"
: > "$BUSY_FIFO"   # release the parked preview
set +e
wait "$BUSY_PID"
BUSY_BG_RC=$?
set -e
cat "$WORK/busy-bg.out" "$WORK/busy-bg.err" >>"$COMBINED_LOG"
[[ "$BUSY_BG_RC" -eq 0 ]] || fail "the released background preview failed with $BUSY_BG_RC"
rm -f "$BUSY_FIFO" "$BUSY_FIFO.reached"
mark_code "set_busy"
ok "set_busy: a concurrent operation on a locked set → envelope, exit 2"

# preview_expired: issue a real binding, expire it in the store (a recent
# timestamp — an ancient one is swept as garbage instead of refused as
# expired, and the store is owner-only, so the rewrite must stay 0600),
# and consume it through the documented stdin selector.
fake_mode 0
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split maintenance prune --set "$SET_ID" --dry-run --json
expect_rc 0
EXPIRING_BINDING="$(jq -r '.data.confirmationBinding' "$OUT_FILE")"
TWO_MIN_AGO_TS=$(( $(date -u +%s) - 120 ))
TWO_MIN_AGO_ISO=$(date -u -r "$TWO_MIN_AGO_TS" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
    || date -u -d "@$TWO_MIN_AGO_TS" +%Y-%m-%dT%H:%M:%S.000Z)
TOKENS_FILE="$FIXTURE/state/preview-tokens.json"
jq --arg t "$TWO_MIN_AGO_ISO" '.tokens |= with_entries(.value.expiresAt = $t)' \
    "$TOKENS_FILE" > "$TOKENS_FILE.tmp"
mv "$TOKENS_FILE.tmp" "$TOKENS_FILE"
chmod 0600 "$TOKENS_FILE"
run_helper_stdin "$EXPIRING_BINDING" maintenance prune --set "$SET_ID" --expected-destination-stdin --json
expect_rc 1
assert_error_envelope "preview_expired"
mark_code "preview_expired"
ok "preview_expired: an expired confirmationBinding is refused at exit 1"

# operation_not_allowed, route 1: a canonical-format capability that
# matches no current plan. The refusal must not echo the attempted value.
APPLY_CANARY='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
RUNS_BEFORE="$(run_count)"
run_helper_stdin "$APPLY_CANARY" purge apply --set "$SET_ID" --preview-token-stdin --json
expect_rc 1
assert_error_envelope "operation_not_allowed"
! grep -qF -- "$APPLY_CANARY" "$OUT_FILE" "$ERR_FILE" \
    || fail "purge apply echoed the refused capability value"
[[ "$(run_count)" == "$RUNS_BEFORE" ]] \
    || fail "a refused purge apply left a run record (of some status) behind"
mark_code "operation_not_allowed"
ok "operation_not_allowed: an unknown preview token is refused, unechoed, and records no run of any status"

# operation_not_allowed, route 2: `run-set --kind prune` is contained in
# this build and always refuses — but run-set is human-only, so the
# refusal is prose on stderr with exit 1, never an envelope. The doc also
# distinguishes it from exit 64, which stays the usage error. The refusal
# happens before config load, restic discovery, secrets, locks, or run
# records — proved by a fresh data directory gaining NO entry of any kind.
CONTAIN="$WORK/contain-data"
mkdir -p "$CONTAIN"
write_config "$CONTAIN" "\"$FAKE_DIR/restic\""
RESTIC_STATION_DATA_DIR="$CONTAIN" run_helper_split run-set --set "$SET_ID" --kind prune
expect_rc 1
[[ ! -s "$OUT_FILE" ]] || fail "the containment refusal wrote to stdout"
[[ -s "$ERR_FILE" ]] || fail "the containment refusal printed nothing to stderr"
grep -q '{' "$OUT_FILE" && fail "the containment refusal emitted JSON from a human-only command"
[[ "$(ls "$CONTAIN")" == "config.json" ]] \
    || fail "the containment refusal touched the data directory: $(ls "$CONTAIN")"
RESTIC_STATION_DATA_DIR="$CONTAIN" run_helper_split runs list --json
expect_rc 0
jq -e '.data | length == 0' "$OUT_FILE" >/dev/null \
    || fail "the containment refusal left a run record of some status: $(jq -c '.data' "$OUT_FILE")"
run_helper_split run-set --set not-a-uuid --kind prune
expect_rc 64
ok "run-set --kind prune: successfully parsed → refusal at exit 1 touching nothing; malformed UUID stays the exit-64 usage error"

# internal_error: a structurally unusable confirmation store — a
# directory where its lock file belongs — is non-retryable, not set_busy.
mkdir -p "$FIXTURE/state/preview-tokens.lock.parked"
mv "$FIXTURE/state/preview-tokens.lock" "$FIXTURE/state/preview-tokens.lock.parked/real" 2>/dev/null || true
mkdir -p "$FIXTURE/state/preview-tokens.lock"
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split maintenance prune --set "$SET_ID" --dry-run --json
expect_rc 1
assert_error_envelope "internal_error"
rmdir "$FIXTURE/state/preview-tokens.lock"
mv "$FIXTURE/state/preview-tokens.lock.parked/real" "$FIXTURE/state/preview-tokens.lock" 2>/dev/null || true
rm -rf "$FIXTURE/state/preview-tokens.lock.parked"
mark_code "internal_error"
ok "internal_error: an unusable confirmation-store lock is non-retryable, exit 1"

# restic_unsupported (env): only restic *discovery* classifies a too-old
# binary, and discovery only runs with no pinned path — so a host whose
# well-known locations hold a usable restic (a brew-equipped Mac) cannot
# produce this code no matter what PATH says. Assert it where the
# environment allows; report the skip where it does not.
OLDBIN="$WORK/oldbin"
mkdir -p "$OLDBIN"
cat > "$OLDBIN/restic" <<'SH'
#!/bin/sh
if [ "$1" = "version" ]; then
  echo '{"version":"0.16.4","go_version":"go1.21.6","go_os":"any","go_arch":"any"}'
  exit 0
fi
exit 1
SH
chmod +x "$OLDBIN/restic"
write_config "$FIXTURE" "null"
if [[ -f "$FIXTURE/machine.json" ]]; then
    jq '.resticPath = null' "$FIXTURE/machine.json" > "$FIXTURE/machine.json.tmp"
    mv "$FIXTURE/machine.json.tmp" "$FIXTURE/machine.json"
fi
OUT_FILE="$WORK/out-$$-$RANDOM"; ERR_FILE="$WORK/err-$$-$RANDOM"
set +e
RESTIC_STATION_DATA_DIR="$FIXTURE" PATH="$OLDBIN" \
    "$HELPER" probe-repo --set "$SET_ID" --dest "$PRIMARY_ID" --json >"$OUT_FILE" 2>"$ERR_FILE"
RC=$?
set -e
cat "$OUT_FILE" "$ERR_FILE" >>"$COMBINED_LOG"
if [[ "$(jq -r '.ok' "$OUT_FILE")" == "false" ]]; then
    expect_rc 1
    assert_error_envelope "restic_unsupported"
    [[ "$(jq -r '.error.details.versionFound' "$OUT_FILE")" == "0.16.4" ]] \
        || fail "restic_unsupported did not publish the numeric triple it rejected"
    jq -e '.error.details.versionSupported | length > 0' "$OUT_FILE" >/dev/null \
        || fail "restic_unsupported did not name the supported minimum"
    ok "restic_unsupported: discovery rejected the too-old restic with versionFound/versionSupported, exit 1"
else
    echo "  (restic_unsupported not forcible here: discovery found a usable restic outside PATH" \
         "($(head -c 120 "$ERR_FILE" | tr -d '\n')) — asserted on hosts without one, e.g. the linux CI container)"
fi
write_config "$FIXTURE" "\"$FAKE_DIR/restic\""
mark_code "restic_unsupported"

# ─────────────────────────────────────────────────────────────────────────
# PART 2c — §Confirmation capabilities and the argument-parser boundary.
# ─────────────────────────────────────────────────────────────────────────
log "PART 2c: capability transport refusals"

# The retired argv forms are rejection-only shims: exit 64 in both modes,
# before context construction, never redeeming or reflecting the value.
run_helper_split purge apply --set "$SET_ID" "--preview-token=$APPLY_CANARY" --json
expect_rc 64
assert_error_envelope "invalid_arguments"
! grep -qF -- "$APPLY_CANARY" "$OUT_FILE" "$ERR_FILE" \
    || fail "the retired --preview-token= shim reflected its value"
run_helper_split maintenance prune --set "$SET_ID" --expected-destination "$APPLY_CANARY" --json
expect_rc 64
assert_error_envelope "invalid_arguments"
! grep -qF -- "$APPLY_CANARY" "$OUT_FILE" "$ERR_FILE" \
    || fail "the retired --expected-destination shim reflected its value"
ok "retired capability argv forms exit 64 without reflection (both shims)"

# `--preview-token-stdin` is required; a non-canonical stdin payload is
# refused without echo; `--dry-run` cannot be combined with the selector.
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split purge apply --set "$SET_ID" --json
expect_rc 1
assert_error_envelope "invalid_arguments"
run_helper_stdin 'AAAA====' purge apply --set "$SET_ID" --preview-token-stdin --json
expect_rc 1
assert_error_envelope "invalid_arguments"
! grep -qF -- 'AAAA====' "$OUT_FILE" "$ERR_FILE" \
    || fail "a refused non-canonical capability payload was echoed"
run_helper_stdin "$APPLY_CANARY" maintenance prune --set "$SET_ID" --dry-run --expected-destination-stdin --json
expect_rc 1
assert_error_envelope "invalid_arguments"
mark_cmd "purge apply"
ok "purge apply: selector required, non-canonical stdin refused unechoed, --dry-run+selector invalid"

# ─────────────────────────────────────────────────────────────────────────
# PART 2d — §What is *not* an error, and the human-only matrix rows.
# ─────────────────────────────────────────────────────────────────────────
log "PART 2d: non-errors and human-only commands"

# THE TRAP that motivated this script: `status --json` exits 1 on warning
# health, and that is a successful report — never an error envelope.
RESTIC_STATION_DATA_DIR="$WARN" run_helper_split status --json
expect_rc 1
assert_success_envelope "status --json (warning health)"
jq -e '.data.health == "warning"' "$OUT_FILE" >/dev/null \
    || fail "the warning fixture did not report warning health"
ok "status --json warning: exit 1 with a StatusReport, not an envelope"

# config export is unwrapped BY DESIGN: the exported document is the
# config itself (so it round-trips into config import), and the command
# has no --json flag at all.
RESTIC_STATION_DATA_DIR="$FIXTURE" run_helper_split config export --out "$WORK/exported.json"
expect_rc 0
jq -e 'has("version") and has("sets") and (has("schemaVersion") or has("ok") or has("data") | not)' \
    "$WORK/exported.json" >/dev/null \
    || fail "config export emitted something other than the bare config document"
IMPORT_DATA="$WORK/import-data"
mkdir -p "$IMPORT_DATA"
RESTIC_STATION_DATA_DIR="$IMPORT_DATA" run_helper_split config import "$WORK/exported.json"
expect_rc 0
[[ -f "$IMPORT_DATA/config.json" ]] || fail "the exported document did not round-trip into config import"
mark_cmd "config export"
ok "config export: unwrapped document, round-trips into config import"

# Every human-only row: `--json` must be a usage error — exit 64 — and,
# per §Argument-parser failures, argv is scanned so the caller that typed
# --json still gets an invalid_arguments envelope for it. This is the
# tripwire for a command quietly growing a --json mode without a doc/matrix
# update (or losing one). `timer` rows are Linux-only: on macOS the whole
# subcommand must be absent (asserted in PART 1), and its invocation still
# exits 64 as an unknown subcommand, so the same loop runs everywhere.
NOJSON_CMDS='tick
run-set
restore
init-secondary
unlock
config import
config export
secret set
secret set-env
secret rm
cli install
cli uninstall
timer status
timer install
timer uninstall
print-password'
while IFS= read -r cmd; do
    # shellcheck disable=SC2086
    run_helper_split $cmd --json
    expect_rc 64
    assert_error_envelope "invalid_arguments"
    mark_cmd "$cmd"
done <<< "$NOJSON_CMDS"
ok "all 16 human-only commands refuse --json at exit 64 with an invalid_arguments envelope"

# ─────────────────────────────────────────────────────────────────────────
# PART 3 — coverage reconciliation and the secret-leak sweep.
# ─────────────────────────────────────────────────────────────────────────
log "PART 3: coverage reconciliation"

sort -u "$WORK/marked-codes" > "$WORK/marked-codes.sorted"
sort -u "$WORK/marked-cmds" > "$WORK/marked-cmds.sorted"

CODES_LIVE=0; CODES_ENV=0; CODES_UNIT=0
while IFS='|' read -r code _ _ class; do
    case "$class" in
        live) CODES_LIVE=$((CODES_LIVE + 1))
              grep -qx "$code" "$WORK/marked-codes.sorted" \
                  || fail "CODE_TABLE classes $code as live but nothing asserted it" ;;
        env)  CODES_ENV=$((CODES_ENV + 1))
              grep -qx "$code" "$WORK/marked-codes.sorted" \
                  || fail "CODE_TABLE classes $code as env but its branch never ran" ;;
        unit:*) CODES_UNIT=$((CODES_UNIT + 1))
              grep -qx "$code" "$WORK/marked-codes.sorted" \
                  && fail "$code is asserted live below but still classed unit — reclassify it in CODE_TABLE" ;;
        *) fail "CODE_TABLE row for $code has unknown class '$class'" ;;
    esac
done <<< "$CODE_TABLE"
while IFS= read -r code; do
    printf '%s\n' "$CODE_TABLE" | awk -F'|' -v c="$code" '$1==c{found=1} END{exit !found}' \
        || fail "an assertion marked code '$code' which is not in CODE_TABLE"
done < "$WORK/marked-codes.sorted"

CMDS_TOTAL=0
while IFS='|' read -r cmd _ class; do
    CMDS_TOTAL=$((CMDS_TOTAL + 1))
    grep -qx "$cmd" "$WORK/marked-cmds.sorted" \
        || fail "CMD_TABLE lists '$cmd' but nothing asserted it"
done <<< "$CMD_TABLE"
while IFS= read -r cmd; do
    printf '%s\n' "$CMD_TABLE" | awk -F'|' -v c="$cmd" '$1==c{found=1} END{exit !found}' \
        || fail "an assertion marked command '$cmd' which is not in CMD_TABLE"
done < "$WORK/marked-cmds.sorted"

log "secret-leak sweep over every helper byte this run produced"
if grep -qF -- "$SECRET_PASSWORD" "$COMBINED_LOG"; then
    fail "the fixture secret value appeared in captured helper output"
fi
ok "the stored password never appeared in any command's output"

printf '\ncoverage: %s commands asserted (%s/30 rows); codes: %s live + %s env asserted, %s delegated to unit tests (of %s documented)\n' \
    "$(wc -l < "$WORK/marked-cmds.sorted" | tr -d ' ')" "$CMDS_TOTAL" \
    "$CODES_LIVE" "$CODES_ENV" "$CODES_UNIT" \
    "$(wc -l < "$DOC_CODES_FILE" | tr -d ' ')"

log "ALL CLI JSON CONTRACT ASSERTIONS PASSED"
