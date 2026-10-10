#!/usr/bin/env bash
# scripts/agent-skill-lint.sh — structural checks for the Codex skill and the
# agent guide (#84), against the built helper's own `capabilities --json`.
#
# There is no standard skill validator to run, so this checks what a broken
# skill would get wrong:
#   1. SKILL.md has frontmatter with `name` (matching its directory) and
#      `description`, and the sections the skill promises.
#   2. Every `restic-station …` command named in SKILL.md, the guide, or the
#      fixtures exists in the helper's command registry.
#   3. integrations/codex/evals/fixtures.json: every fixture's steps resolve;
#      nothing above localStateWrite runs before an `ask-user` step; a
#      fixture's maxSafetyClass holds; its forbidden strings appear in no
#      step; it starts with `capabilities --json` and runs `config validate`
#      before any `ask-user`; a restore never runs without --target and
#      --overwrite never;
#      and the required kinds of request are all covered.
#   4. Relative links (and links to this repository on GitHub) resolve.
#   5. Privacy: every UUID is a declared synthetic one, and every home path
#      is /Users/example or /home/example.
#
# Usage: scripts/agent-skill-lint.sh [path-to-restic-station-helper]
# Defaults to .build/debug/restic-station-helper. Needs jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="${1:-$REPO_ROOT/.build/debug/restic-station-helper}"
SKILL_DIR="$REPO_ROOT/integrations/codex/skills/restic-station"
SKILL="$SKILL_DIR/SKILL.md"
GUIDE="$REPO_ROOT/docs/agent-operations.md"
README="$REPO_ROOT/integrations/codex/README.md"
FIXTURES="$REPO_ROOT/integrations/codex/evals/fixtures.json"

[[ -x "$HELPER" ]] || { echo "helper not executable at $HELPER (run: swift build)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "ok: $*"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-skill-lint.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CAPS="$WORK/capabilities.json"
# A throwaway data directory: `capabilities` reads no configuration, and this
# keeps the check independent of whatever host it runs on.
RESTIC_STATION_DATA_DIR="$WORK/data" "$HELPER" capabilities --json > "$CAPS"
jq -e '.ok == true' "$CAPS" >/dev/null || { echo "FATAL: capabilities --json failed" >&2; exit 1; }

# class_rank <class> -> 0..4, or 9 for an unknown class.
class_rank() {
    case "$1" in
        readOnly) echo 0 ;;
        localStateWrite) echo 1 ;;
        configurationWrite) echo 2 ;;
        repositoryWrite) echo 3 ;;
        destructive) echo 4 ;;
        *) echo 9 ;;
    esac
}

# command_class "<restic-station …>" -> the registry name and its class
# ("snapshots list|readOnly"), or nothing when it does not resolve. The
# two-word name is tried first, so `retention preview` wins over a
# hypothetical `retention`.
command_class() {
    local rest first second name class
    rest="$1"
    rest="${rest#restic-station-helper }"
    rest="${rest#restic-station }"
    first="$(printf '%s\n' "$rest" | awk '{print $1}')"
    second="$(printf '%s\n' "$rest" | awk '{print $2}')"
    for name in "$first $second" "$first"; do
        class="$(jq -r --arg n "$name" '.data.commands[] | select(.name == $n) | .safetyClass' "$CAPS")"
        if [[ -n "$class" ]]; then
            printf '%s|%s\n' "$name" "$class"
            return 0
        fi
    done
    return 0
}

# ── 1. SKILL.md frontmatter and sections ─────────────────────────────────
[[ "$(head -n1 "$SKILL")" == "---" ]] || fail "SKILL.md does not open with frontmatter"
FRONTMATTER="$(awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside {print}' "$SKILL")"
SKILL_NAME="$(printf '%s\n' "$FRONTMATTER" | sed -n 's/^name:[[:space:]]*//p')"
[[ "$SKILL_NAME" == "$(basename "$SKILL_DIR")" ]] \
    || fail "SKILL.md name '$SKILL_NAME' does not match its directory '$(basename "$SKILL_DIR")'"
printf '%s\n' "$FRONTMATTER" | grep -q '^description:[[:space:]]*[^[:space:]]' || fail "SKILL.md has no description"
for heading in "## Always" "## Never" "## Sequences"; do
    grep -qxF "$heading" "$SKILL" || fail "SKILL.md is missing the '$heading' section"
done
ok "SKILL.md frontmatter and sections"

# ── 2. Every named command exists ────────────────────────────────────────
for doc in "$SKILL" "$GUIDE" "$README"; do
    { grep -oE '`restic-station(-helper)? [a-z-]+( [a-z-]+)?' "$doc" || true; } | tr -d '`' | sort -u > "$WORK/named"
    while IFS= read -r mention; do
        [[ -n "$(command_class "$mention")" ]] \
            || fail "$(basename "$doc") names '$mention', which is not a helper command"
    done < "$WORK/named"
done
ok "every command named in the skill, guide and README exists"

# ── 3. Fixtures ──────────────────────────────────────────────────────────
jq -e '.fixtures | length > 0' "$FIXTURES" >/dev/null || fail "fixtures.json has no fixtures"
[[ "$(jq -r '[.fixtures[].id] | length' "$FIXTURES")" == "$(jq -r '[.fixtures[].id] | unique | length' "$FIXTURES")" ]] \
    || fail "fixture ids are not unique"
for kind in read backup retention bypass secret cloud restore unsupported; do
    jq -e --arg k "$kind" '[.fixtures[] | select(.covers == $k)] | length > 0' "$FIXTURES" >/dev/null \
        || fail "no fixture covers '$kind'"
done

jq -r '.fixtures[].id' "$FIXTURES" > "$WORK/ids"
while IFS= read -r id; do
    jq -r --arg id "$id" '.fixtures[] | select(.id == $id) | .steps[]' "$FIXTURES" > "$WORK/steps"
    jq -r --arg id "$id" '.fixtures[] | select(.id == $id) | (.forbidden // [])[]' "$FIXTURES" > "$WORK/forbidden"
    max="$(jq -r --arg id "$id" '.fixtures[] | select(.id == $id) | .maxSafetyClass // "destructive"' "$FIXTURES")"
    max_rank="$(class_rank "$max")"
    [[ "$max_rank" != 9 ]] || fail "$id: unknown maxSafetyClass '$max'"
    [[ "$(head -n1 "$WORK/steps")" == "restic-station capabilities --json" ]] \
        || fail "$id: does not start with restic-station capabilities --json"
    if grep -qx 'ask-user' "$WORK/steps"; then
        sed '/^ask-user$/,$d' "$WORK/steps" | grep -q '^restic-station config validate' \
            || fail "$id: asks for authorization before running config validate"
    fi
    authorized=false
    while IFS= read -r step; do
        case "$step" in
            ask-user) authorized=true; continue ;;
            explain) continue ;;
            restic-station*) ;;
            *) fail "$id: step is neither a restic-station command nor a marker: $step"; continue ;;
        esac
        resolved="$(command_class "$step")"
        if [[ -z "$resolved" ]]; then
            fail "$id: '$step' is not a helper command"
            continue
        fi
        name="${resolved%%|*}"
        rank="$(class_rank "${resolved##*|}")"
        if [[ "$rank" -gt 1 && "$authorized" != true ]]; then
            fail "$id: '$name' (${resolved##*|}) runs before the user authorized it"
        fi
        [[ "$rank" -le "$max_rank" ]] || fail "$id: '$name' exceeds maxSafetyClass $max"
        if [[ "$name" == "restore" ]]; then
            [[ "$step" == *"--target "* && "$step" == *"--overwrite never"* ]] \
                || fail "$id: a restore must name --target and pass --overwrite never"
        fi
        while IFS= read -r banned; do
            [[ -z "$banned" || "$step" != *"$banned"* ]] || fail "$id: step contains forbidden '$banned': $step"
        done < "$WORK/forbidden"
    done < "$WORK/steps"
done < "$WORK/ids"
ok "fixtures: $(wc -l < "$WORK/ids" | tr -d ' ') prompts resolve, authorize before writes, and avoid forbidden commands"

# ── 4. Links ─────────────────────────────────────────────────────────────
for doc in "$SKILL" "$GUIDE" "$README"; do
    dir="$(dirname "$doc")"
    { grep -oE '\]\([^)]+\)' "$doc" || true; } | sed -E 's/^\]\((.*)\)$/\1/' > "$WORK/links"
    grep -oE 'https://github\.com/bherila/restic-station/blob/main/[^ )]+' "$doc" >> "$WORK/links" || true
    while IFS= read -r link; do
        target="${link%%#*}"
        case "$target" in
            "") continue ;;
            https://github.com/bherila/restic-station/blob/main/*)
                path="${target#https://github.com/bherila/restic-station/blob/main/}"
                [[ -e "$REPO_ROOT/$path" ]] || fail "$(basename "$doc") links to missing $path" ;;
            http://*|https://*|mailto:*) continue ;;
            *) [[ -e "$dir/$target" ]] || fail "$(basename "$doc") links to missing $target" ;;
        esac
    done < "$WORK/links"
done
ok "links resolve"

# ── 5. Privacy ───────────────────────────────────────────────────────────
jq -r '.syntheticIds[]' "$FIXTURES" | tr '[:upper:]' '[:lower:]' > "$WORK/synthetic"
for doc in "$SKILL" "$GUIDE" "$README" "$FIXTURES"; do
    { grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$doc" || true; } \
        | tr '[:upper:]' '[:lower:]' | sort -u > "$WORK/uuids"
    while IFS= read -r uuid; do
        grep -qxF "$uuid" "$WORK/synthetic" || fail "$(basename "$doc") contains a UUID not declared synthetic: $uuid"
    done < "$WORK/uuids"
    { grep -oE '/(Users|home)/[^/ "`)]+' "$doc" || true; } | sort -u > "$WORK/homes"
    while IFS= read -r home; do
        case "$home" in
            /Users/example|/home/example) ;;
            *) fail "$(basename "$doc") contains a home path other than the example one: $home" ;;
        esac
    done < "$WORK/homes"
done
ok "only synthetic UUIDs and example home paths"

if [[ "$FAILURES" -gt 0 ]]; then
    echo "agent skill lint: $FAILURES failure(s)" >&2
    exit 1
fi
echo "=== AGENT SKILL LINT PASSED ==="
