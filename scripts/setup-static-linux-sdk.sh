#!/usr/bin/env bash
# See scripts/integration-test.sh's header for why this is not
# `#!/bin/bash -euo pipefail`: Linux passes the shebang remainder as one
# argument and bash dies with "invalid option name" before the script runs.
# `set -euo pipefail` is below.
# scripts/setup-static-linux-sdk.sh — installs (idempotently, no sudo) the
# exact toolchain + Swift SDK combination `scripts/package-linux.sh` uses to
# cross-compile a fully static `restic-station-helper` for Linux (T29 /
# issue #31).
#
# Why a pinned open-source toolchain, not the host's Xcode `swift`:
# the Static Linux SDK's precompiled `Foundation.swiftmodule` was built by a
# specific swift.org release; a same-numbered Apple/Xcode toolchain is NOT
# guaranteed binary-module-compatible with it — on this project's own dev
# machine (Xcode/Apple Swift 6.3.3) it failed with "compiled module was
# created by an older version of the compiler". Downloading the swift.org
# **macOS toolchain** for the exact SDK version sidesteps that: both halves
# come from the same build. This is also what makes the build reproducible
# from a clean checkout regardless of whichever Xcode happens to be
# installed on the machine running it (dev laptop or CI runner alike).
#
# What this script does, idempotently:
#   1. Downloads (if not already cached) the swift.org open-source macOS
#      toolchain .pkg for $SWIFT_VERSION and expands it — WITHOUT installing
#      it system-wide / without sudo — via `pkgutil --expand-full`, which
#      unpacks the payload into a plain, self-contained `usr/` tree that can
#      be invoked directly.
#   2. Installs the matching Static Linux SDK (musl) artifact bundle via
#      `swift sdk install --checksum`, if not already installed.
#   3. Prints the resolved `swift` binary's path as the ONLY line on stdout
#      (everything else is logged to stderr), so callers do:
#          SWIFT="$(scripts/setup-static-linux-sdk.sh)"
#          "$SWIFT" build --swift-sdk x86_64-swift-linux-musl -c release …
#
# Caching: both downloads land under $CACHE_DIR (default
# .build/static-linux-sdk-cache, override with
# RESTIC_STATION_SDK_CACHE_DIR — CI keys an actions/cache on this path so a
# green run does not re-download ~1.7 GB every time).
set -euo pipefail

# Pinned to the exact toolchain on the machine this was last verified on
# (`swift --version`: Apple Swift 6.3.3 / swiftlang-6.3.3.1.3). Bump
# deliberately, together, and re-verify with a clean cache when Xcode moves
# to a newer Swift — an out-of-sync pair reproduces the "older version of
# the compiler" failure this script exists to avoid.
SWIFT_VERSION="${RESTIC_STATION_SWIFT_VERSION:-6.3.3}"
STATIC_SDK_ARTIFACT_VERSION="0.1.0"

TOOLCHAIN_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/xcode/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-osx.pkg"
# TOFU (trust-on-first-use) pin: computed with `shasum -a 256` against the
# download above when this script was written. swift.org does not publish a
# machine-readable checksum file for toolchain .pkg installers (only a PGP
# .sig), so this is the strongest integrity check practical here — it still
# catches a corrupted download or a tampered mirror on every subsequent run.
TOOLCHAIN_SHA256="ee82e57774d6650f94aa06302435d6f44a055b9411698db8ecb85d9a3bcc91d0"

STATIC_SDK_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/static-sdk/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE_static-linux-${STATIC_SDK_ARTIFACT_VERSION}.artifactbundle.tar.gz"
# Same TOFU reasoning, but this one IS independently meaningful even though
# we computed it ourselves: `swift sdk install --checksum` refuses to
# install a bundle whose downloaded bytes don't hash to this value, so
# pinning it here (rather than computing it fresh from whatever gets
# downloaded) is what turns the check into "matches what we verified before"
# instead of "matches itself".
STATIC_SDK_CHECKSUM="87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b"
STATIC_SDK_BUNDLE_ID="swift-${SWIFT_VERSION}-RELEASE_static-linux-${STATIC_SDK_ARTIFACT_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="${RESTIC_STATION_SDK_CACHE_DIR:-$REPO_ROOT/.build/static-linux-sdk-cache}"
TOOLCHAIN_DIR="$CACHE_DIR/swift-${SWIFT_VERSION}-toolchain"
SWIFT_BIN="$TOOLCHAIN_DIR/usr/bin/swift"

log() { printf '[setup-static-linux-sdk] %s\n' "$*" >&2; }

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# ── 1. Toolchain (extracted, not installed) ─────────────────────────────
if [[ -x "$SWIFT_BIN" ]]; then
    log "toolchain already present: $SWIFT_BIN"
else
    mkdir -p "$CACHE_DIR"
    PKG_PATH="$CACHE_DIR/swift-${SWIFT_VERSION}-RELEASE-osx.pkg"
    if [[ ! -f "$PKG_PATH" ]]; then
        log "downloading $TOOLCHAIN_URL"
        curl -fL --progress-bar -o "$PKG_PATH.partial" "$TOOLCHAIN_URL"
        mv "$PKG_PATH.partial" "$PKG_PATH"
    fi
    ACTUAL_SHA256="$(sha256_of "$PKG_PATH")"
    if [[ "$ACTUAL_SHA256" != "$TOOLCHAIN_SHA256" ]]; then
        echo "FATAL: $PKG_PATH sha256 mismatch." >&2
        echo "  expected: $TOOLCHAIN_SHA256" >&2
        echo "  actual:   $ACTUAL_SHA256" >&2
        echo "  refusing to use a toolchain download that does not match the pinned checksum." >&2
        exit 1
    fi
    log "sha256 verified: $ACTUAL_SHA256"

    log "expanding $PKG_PATH (pkgutil --expand-full; no sudo, not installed system-wide)"
    EXPAND_DIR="$CACHE_DIR/expand-$$"
    rm -rf "$EXPAND_DIR"
    pkgutil --expand-full "$PKG_PATH" "$EXPAND_DIR"
    PAYLOAD_DIR="$EXPAND_DIR/swift-${SWIFT_VERSION}-RELEASE-osx-package.pkg/Payload"
    [[ -x "$PAYLOAD_DIR/usr/bin/swift" ]] || {
        echo "FATAL: expanded payload has no usr/bin/swift at $PAYLOAD_DIR" >&2
        exit 1
    }
    rm -rf "$TOOLCHAIN_DIR"
    mv "$PAYLOAD_DIR" "$TOOLCHAIN_DIR"
    rm -rf "$EXPAND_DIR"
    log "toolchain ready: $SWIFT_BIN"
fi

"$SWIFT_BIN" --version >&2

# ── 2. Static Linux SDK ──────────────────────────────────────────────────
#
# Idempotency check. `swift sdk list` prints the *bundle* name on Swift
# 6.3.3 (verified: it emits exactly "swift-6.3.3-RELEASE_static-linux-0.1.0"),
# but its own --help says it prints "IDs", and on some versions that means
# the per-target ids `x86_64-swift-linux-musl` / `aarch64-swift-linux-musl`.
# The output shape is not a contract, and SWIFT_VERSION is overridable, so
# accept either form rather than pinning this script to one toolchain's
# formatting. Matching on the wrong shape would send an already-provisioned
# machine into `swift sdk install`, which then fails on the duplicate.
sdk_already_installed() {
    local listing
    listing="$("$SWIFT_BIN" sdk list 2>/dev/null)" || return 1
    grep -qF "$STATIC_SDK_BUNDLE_ID" <<<"$listing" && return 0
    # Per-target ids: require both arches, so a half-installed bundle still
    # takes the install path.
    grep -qF "x86_64-swift-linux-musl" <<<"$listing" \
        && grep -qF "aarch64-swift-linux-musl" <<<"$listing" \
        && return 0
    return 1
}

if sdk_already_installed; then
    log "Static Linux SDK already installed: $STATIC_SDK_BUNDLE_ID"
else
    SDK_PATH="$CACHE_DIR/${STATIC_SDK_BUNDLE_ID}.artifactbundle.tar.gz"
    if [[ ! -f "$SDK_PATH" ]]; then
        log "downloading $STATIC_SDK_URL"
        curl -fL --progress-bar -o "$SDK_PATH.partial" "$STATIC_SDK_URL"
        mv "$SDK_PATH.partial" "$SDK_PATH"
    fi
    log "installing Static Linux SDK (checksum-verified by swift sdk install)"
    # Tolerate "already installed": if the listing shape changes again, a
    # re-run must not hard-fail a machine that is in fact ready. Any other
    # failure still aborts, because the build cannot proceed without the SDK.
    if ! "$SWIFT_BIN" sdk install "$SDK_PATH" --checksum "$STATIC_SDK_CHECKSUM" >&2; then
        if sdk_already_installed; then
            log "SDK install reported failure but the SDK is present — continuing"
        else
            echo "FATAL: could not install the Static Linux SDK" >&2
            exit 1
        fi
    fi
fi

# The one line of real stdout output — everything else above went to stderr.
echo "$SWIFT_BIN"
