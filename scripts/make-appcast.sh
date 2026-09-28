#!/usr/bin/env bash
# make-appcast.sh — package a signed Restic Station.app for Sparkle and write
# the appcast.xml that goes beside it on the GitHub release
# (docs/release.md §Updates).
#
# Usage:
#   scripts/make-appcast.sh <path/to/Restic Station.app> <out-dir> [release-notes.html]
#
# Environment:
#   SPARKLE_BIN        Sparkle's bin/ (default: the SwiftPM artifact under build/)
#   SPARKLE_KEY_FILE   sign with this exported private key instead of the
#                      login-keychain item (account "restic-station")
#   RELEASE_TAG        the tag the assets are uploaded to (default: v<version>)
#   PREVIOUS_APPCAST   appcast to compare against (default: the one currently
#                      published at the feed URL; "none" for the first release)
#
# Every value in the appcast is read from the artifact, never from source:
# the version and build from its Info.plist, the config schema from its own
# helper's `version --json`, and the signature is verified against the
# SUPublicEDKey baked into the app before anything is written.
#
# macOS only (ditto, codesign, PlistBuddy); bash 3.2-compatible.
set -euo pipefail

die() { echo "make-appcast: $*" >&2; exit 1; }

[ $# -ge 2 ] && [ $# -le 3 ] || die "usage: $0 <app> <out-dir> [release-notes.html]"
APP=${1%/}
OUT=$2
NOTES=${3:-}
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SPARKLE_BIN=${SPARKLE_BIN:-"$REPO_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"}
SCHEMA_ELEMENT=resticstation:configSchemaVersion
SCHEMA_NS=https://github.com/bherila/restic-station/blob/main/docs/release.md

[ -d "$APP" ] || die "no app bundle at $APP"
[ -x "$SPARKLE_BIN/sign_update" ] || die "sign_update not found in $SPARKLE_BIN (build once, or set SPARKLE_BIN)"
[ -z "$NOTES" ] || [ -f "$NOTES" ] || die "release notes file $NOTES does not exist"
command -v jq >/dev/null || die "jq is required"

# OpenSSL 3 for the Ed25519 check (macOS's LibreSSL cannot verify raw Ed25519).
OPENSSL=""
for candidate in "${OPENSSL_BIN:-}" /opt/homebrew/bin/openssl /usr/local/bin/openssl openssl; do
    [ -n "$candidate" ] || continue
    if "$candidate" version 2>/dev/null | grep -q '^OpenSSL 3'; then OPENSSL=$candidate; break; fi
done
[ -n "$OPENSSL" ] || die "OpenSSL 3 is required to verify the signature (brew install openssl@3)"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
VERSION=$(plist CFBundleShortVersionString) || die "app has no CFBundleShortVersionString"
BUILD=$(plist CFBundleVersion) || die "app has no CFBundleVersion"
FEED_URL=$(plist SUFeedURL) || die "app has no SUFeedURL — was it built from a tree with Sparkle?"
PUBLIC_KEY=$(plist SUPublicEDKey) || die "app has no SUPublicEDKey"
MIN_OS=$(plist LSMinimumSystemVersion) || MIN_OS=14.0
TAG=${RELEASE_TAG:-v$VERSION}

case $BUILD in ''|*[!0-9]*) die "CFBundleVersion '$BUILD' is not a plain integer; Sparkle orders updates by it" ;; esac

SCHEMA=$("$APP/Contents/MacOS/restic-station-helper" version --json | jq -er '.data.configSchemaVersion') \
    || die "the embedded helper does not report configSchemaVersion"
case $SCHEMA in ''|*[!0-9]*|0) die "configSchemaVersion '$SCHEMA' is not a positive integer" ;; esac

codesign --verify --deep --strict "$APP" || die "$APP is not validly signed (Sparkle requires at least an ad-hoc signature)"

# The previous release: its build must be lower (Sparkle ignores anything
# else), and a schema change gets a fleet warning in the notes.
PREVIOUS=${PREVIOUS_APPCAST:-$FEED_URL}
PREV_BUILD=""
PREV_SCHEMA=""
if [ "$PREVIOUS" != none ]; then
    if [ -f "$PREVIOUS" ]; then
        PREV_XML=$(cat "$PREVIOUS")
    else
        # -f: a 404 (no appcast published yet) is an error, not an empty feed.
        PREV_XML=$(curl -fsSL "$PREVIOUS") \
            || die "could not fetch the published appcast at $PREVIOUS (first release? set PREVIOUS_APPCAST=none)"
    fi
    PREV_BUILD=$(printf '%s' "$PREV_XML" | xmllint --xpath 'string(//*[local-name()="version"])' - 2>/dev/null || true)
    PREV_SCHEMA=$(printf '%s' "$PREV_XML" | xmllint --xpath 'string(//*[local-name()="configSchemaVersion"])' - 2>/dev/null || true)
    [ -n "$PREV_BUILD" ] || die "previous appcast has no sparkle:version"
    [ -n "$PREV_SCHEMA" ] || die "previous appcast has no $SCHEMA_ELEMENT"
    [ "$BUILD" -gt "$PREV_BUILD" ] || die "build $BUILD is not newer than the published build $PREV_BUILD — bump CURRENT_PROJECT_VERSION"
    [ "$SCHEMA" -ge "$PREV_SCHEMA" ] || die "config schema $SCHEMA is older than the published $PREV_SCHEMA"
fi

mkdir -p "$OUT"
ZIP_NAME="Restic-Station-$VERSION.zip"
ZIP="$OUT/$ZIP_NAME"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    SIGNATURE=$("$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" -p "$ZIP")
else
    SIGNATURE=$("$SPARKLE_BIN/sign_update" --account restic-station -p "$ZIP")
fi
LENGTH=$(stat -f %z "$ZIP")

# Verify against the key the *app* trusts, not the key we signed with: a
# release signed by the wrong key is one every installed copy rejects.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$PUBLIC_KEY" | base64 -D; } > "$WORK/pub.der"
printf '%s' "$SIGNATURE" | base64 -D > "$WORK/sig"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.der" -keyform DER -rawin -in "$ZIP" -sigfile "$WORK/sig" >/dev/null \
    || { rm -f "$ZIP"; die "the signature does not verify against the app's SUPublicEDKey — wrong signing key?"; }

NOTES_HTML=""
if [ -n "$PREV_SCHEMA" ] && [ "$SCHEMA" -gt "$PREV_SCHEMA" ]; then
    NOTES_HTML="<p><strong>This update changes the shared configuration from schema v$PREV_SCHEMA to v$SCHEMA.</strong> \
Every machine that shares config.json, including Linux hosts, must be upgraded at the same time, or backups stop on the ones left behind.</p>"
fi
[ -z "$NOTES" ] || NOTES_HTML="$NOTES_HTML$(cat "$NOTES")"
case $NOTES_HTML in *']]>'*) die "release notes contain ']]>', which would end the CDATA section" ;; esac

cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:resticstation="$SCHEMA_NS">
  <channel>
    <title>Restic Station</title>
    <link>$FEED_URL</link>
    <item>
      <title>Restic Station $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <$SCHEMA_ELEMENT>$SCHEMA</$SCHEMA_ELEMENT>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/bherila/restic-station/releases/download/$TAG/$ZIP_NAME" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$OUT/appcast.xml" || die "wrote malformed XML"

echo "Wrote $ZIP ($LENGTH bytes) and $OUT/appcast.xml"
echo "  version $VERSION (build $BUILD), config schema v$SCHEMA${PREV_SCHEMA:+ (published: v$PREV_SCHEMA, build $PREV_BUILD)}"
echo "Upload both to the $TAG release: gh release upload $TAG \"$ZIP\" \"$OUT/appcast.xml\""
