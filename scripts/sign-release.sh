#!/usr/bin/env bash
# sign-release.sh — sign a Release build of Restic Station.app with the
# project's release code-signing identity (docs/release.md §3).
#
# Usage:
#   scripts/sign-release.sh <path/to/Restic Station.app>
#   scripts/sign-release.sh --verify <path/to/Restic Station.app>
#
# --verify signs nothing: it only checks that a bundle carries the release
# signature below (make-appcast.sh uses it, so this file is the one place the
# certificate is pinned).
#
# Environment:
#   RESTIC_STATION_SIGNING_KEYCHAIN                keychain file holding the identity
#                                                  (default: the login keychain search list)
#   RESTIC_STATION_SIGNING_KEYCHAIN_PASSWORD_FILE  unlock that keychain with this file's contents
#
# The identity is a self-signed certificate, pinned here by its SHA-1. It is
# not trusted by macOS and does not need to be: what it buys is a designated
# requirement — `identifier "…" and certificate root = H"<EXPECTED_LEAF>"` —
# that is identical for every release, so Full Disk Access granted to the app
# and to its helper survives Sparkle updates. An ad-hoc signature's
# requirement is the build's own cdhash, which changes every release.
#
# Signs inside-out (nested code first), gives the embedded helper a stable
# identifier (the linker's default embeds a per-build UUID, which would
# change its requirement anyway), drops Xcode's debug-only get-task-allow
# entitlement, and refuses to finish unless both requirements are exactly
# the pinned ones.
#
# macOS only; bash 3.2-compatible.
set -euo pipefail

die() { echo "sign-release: $*" >&2; exit 1; }

EXPECTED_LEAF=8c6fa76a26165b3aee42279c994b949f745bd00d
APP_IDENTIFIER=net.herila.ResticStation
HELPER_IDENTIFIER=net.herila.ResticStation.helper

VERIFY_ONLY=false
if [ "${1:-}" = "--verify" ]; then
    VERIFY_ONLY=true
    shift
fi
[ $# -eq 1 ] || die "usage: $0 [--verify] <path/to/Restic Station.app>"
APP=${1%/}
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENTITLEMENTS="$REPO_ROOT/App/ResticStation.entitlements"
[ -d "$APP" ] || die "no app bundle at $APP"
[ -f "$ENTITLEMENTS" ] || die "missing $ENTITLEMENTS"

HELPER="$APP/Contents/MacOS/restic-station-helper"
[ -x "$HELPER" ] || die "no embedded helper at $HELPER"

requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
# A self-signed certificate is its own root, so codesign may phrase the
# requirement as `certificate root` or `certificate leaf`; both pin this hash.
expect_requirement() {
    local got
    got=$(requirement "$1")
    case $got in
        "identifier \"$2\" and certificate root = H\"$EXPECTED_LEAF\""|\
        "identifier \"$2\" and certificate leaf = H\"$EXPECTED_LEAF\"") ;;
        *) die "$1 is not signed with the release identity: designated requirement is '$got' (want identifier \"$2\" and certificate $EXPECTED_LEAF; sign it with scripts/sign-release.sh)" ;;
    esac
}
verify_release_signature() {
    codesign --verify --deep --strict "$APP" || die "the bundle's code signature does not verify"
    expect_requirement "$APP" "$APP_IDENTIFIER"
    expect_requirement "$HELPER" "$HELPER_IDENTIFIER"
    if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
        die "the app carries the debug-only get-task-allow entitlement"
    fi
}

if $VERIFY_ONLY; then
    verify_release_signature
    echo "$APP carries the release signature (certificate $EXPECTED_LEAF)."
    exit 0
fi

KEYCHAIN=${RESTIC_STATION_SIGNING_KEYCHAIN:-}
KEYCHAIN_ARGS=()
if [ -n "$KEYCHAIN" ]; then
    [ -f "$KEYCHAIN" ] || die "no keychain at $KEYCHAIN"
    if [ -n "${RESTIC_STATION_SIGNING_KEYCHAIN_PASSWORD_FILE:-}" ]; then
        security unlock-keychain -p "$(cat "$RESTIC_STATION_SIGNING_KEYCHAIN_PASSWORD_FILE")" "$KEYCHAIN" \
            || die "could not unlock $KEYCHAIN"
    fi
    KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
fi

# Select the identity by its certificate hash, never by name: a second
# certificate with the same common name must not be able to sign a release.
IDENTITY=$(echo "$EXPECTED_LEAF" | tr '[:lower:]' '[:upper:]')
security find-identity -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} | grep -q "$IDENTITY" \
    || die "the release signing identity ($IDENTITY) is not in ${KEYCHAIN:-the keychain search list}"

sign() {
    codesign --force --timestamp=none "${KEYCHAIN_ARGS[@]}" --sign "$IDENTITY" "$@"
}

SPK="$APP/Contents/Frameworks/Sparkle.framework"

sign --identifier "$HELPER_IDENTIFIER" "$HELPER"
if [ -d "$SPK" ]; then
    # Sparkle's documented order, innermost first; Downloader.xpc keeps its
    # entitlements.
    sign "$SPK/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc"
    sign "$SPK/Versions/B/Autoupdate"
    sign "$SPK/Versions/B/Updater.app"
    sign "$SPK"
fi
sign --entitlements "$ENTITLEMENTS" "$APP"

verify_release_signature

echo "Signed $APP with the release identity (leaf $EXPECTED_LEAF)."
