#!/usr/bin/env bash
# Keep every checked-in shell script valid under the oldest supported macOS
# shell and catch the quoting/process mistakes that have escaped review.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"
BASH32_BIN="${BASH32_BIN:-/bin/bash}"

command -v "$SHELLCHECK_BIN" >/dev/null 2>&1 || {
    echo "shellcheck is required" >&2
    exit 1
}
[[ -x "$BASH32_BIN" ]] || {
    echo "Bash 3.2 executable not found at $BASH32_BIN" >&2
    exit 1
}

BASH_VERSION_LINE="$("$BASH32_BIN" --version | sed -n '1p')"
case "$BASH_VERSION_LINE" in
    *"GNU bash, version 3.2."*) ;;
    *)
        echo "expected Bash 3.2, got: $BASH_VERSION_LINE" >&2
        exit 1
        ;;
esac

SCRIPTS=(scripts/*.sh)

# SC2005 is a style-only preference. Several test assertions deliberately
# normalize command-substitution output before piping it to jq; retain that
# existing idiom while gating every correctness, portability, and info rule.
"$SHELLCHECK_BIN" --exclude=SC2005 "${SCRIPTS[@]}"
for script in "${SCRIPTS[@]}"; do
    "$BASH32_BIN" -n "$script"
done

echo "shellcheck passed; Bash 3.2 parsed ${#SCRIPTS[@]} scripts"
