#!/bin/bash -euo pipefail
# shellcheck disable=SC2096
# ^ see scripts/integration-test.sh's identical header comment: this packs
# -euo pipefail into the shebang per project convention; the `set -euo
# pipefail` below is what actually takes effect on every OS.
# scripts/package-linux.sh — builds a fully static `restic-station-helper`
# for one or more Linux architectures and packages each into
# `restic-station-linux-<arch>.tar.gz` (T29 / issue #31).
#
# Usage:
#   scripts/package-linux.sh                # both x86_64 and aarch64
#   scripts/package-linux.sh x86_64
#   scripts/package-linux.sh aarch64
#   scripts/package-linux.sh x86_64 aarch64
#
# Reproducible build, exact command (also what this script runs):
#   SWIFT="$(scripts/setup-static-linux-sdk.sh)"   # pins toolchain + SDK version
#   "$SWIFT" build --swift-sdk <arch>-swift-linux-musl -c release \
#       --product restic-station-helper
#
# Output: dist/restic-station-linux-<arch>.tar.gz (one per requested arch)
#         dist/SHA256SUMS (sha256 of every tarball produced this run)
#
# Each tarball unpacks to a directory (restic-station-linux-<arch>/)
# containing the binary, install.sh, LICENSE, README.md and the reference
# systemd units — see packaging/linux/README.md for the shipped copy of this
# layout description.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"

log() { printf '\n=== %s ===\n' "$*"; }

ARCHES=("$@")
if [[ ${#ARCHES[@]} -eq 0 ]]; then
    ARCHES=(x86_64 aarch64)
fi
for arch in "${ARCHES[@]}"; do
    case "$arch" in
        x86_64 | aarch64) ;;
        *)
            echo "FATAL: unknown architecture '$arch' (supported: x86_64, aarch64)" >&2
            exit 1
            ;;
    esac
done

log "Resolving toolchain + Static Linux SDK"
SWIFT="$("$SCRIPT_DIR/setup-static-linux-sdk.sh")"
echo "swift: $SWIFT"
TOOLCHAIN_BIN_DIR="$(dirname "$SWIFT")"
OBJCOPY="$TOOLCHAIN_BIN_DIR/llvm-objcopy"
[[ -x "$OBJCOPY" ]] || { echo "FATAL: llvm-objcopy not found next to swift at $OBJCOPY" >&2; exit 1; }

mkdir -p "$DIST_DIR"

package_one() {
    local arch="$1"
    local triple="${arch}-swift-linux-musl"

    log "Building restic-station-helper for $arch ($triple)"
    (cd "$REPO_ROOT" && "$SWIFT" build --swift-sdk "$triple" -c release --product restic-station-helper)

    local built_binary="$REPO_ROOT/.build/$triple/release/restic-station-helper"
    [[ -x "$built_binary" ]] || { echo "FATAL: build did not produce $built_binary" >&2; exit 1; }

    local stage="$DIST_DIR/restic-station-linux-$arch"
    rm -rf "$stage"
    mkdir -p "$stage/systemd"

    log "Stripping debug symbols ($arch)"
    cp "$built_binary" "$stage/restic-station-helper"
    local before after
    before=$(wc -c < "$stage/restic-station-helper" | tr -d ' ')
    "$OBJCOPY" --strip-debug --strip-unneeded "$stage/restic-station-helper"
    chmod 755 "$stage/restic-station-helper"
    after=$(wc -c < "$stage/restic-station-helper" | tr -d ' ')
    echo "  $before -> $after bytes"

    # `file` reads the ELF header directly, so this check works even though
    # this host cannot execute the binary it just produced (macOS, foreign
    # arch). "statically linked" here is what `ldd` reports as "not a
    # dynamic executable" once this runs on an actual Linux host — CI's
    # linux-runtime-verify job is what proves that with a real `ldd` and a
    # real container run; this is a fast local sanity check that catches an
    # accidentally-dynamic build before it is ever pushed.
    log "Verifying static linkage (ELF header inspection)"
    local file_out
    file_out="$(file "$stage/restic-station-helper")"
    echo "  $file_out"
    if [[ "$file_out" != *"statically linked"* ]]; then
        echo "FATAL: $stage/restic-station-helper is not statically linked:" >&2
        echo "  $file_out" >&2
        exit 1
    fi

    cp "$REPO_ROOT/packaging/linux/install.sh" "$stage/install.sh"
    chmod 755 "$stage/install.sh"
    cp "$REPO_ROOT/packaging/linux/README.md" "$stage/README.md"
    cp "$REPO_ROOT/LICENSE" "$stage/LICENSE"
    cp "$REPO_ROOT/packaging/linux/systemd/restic-station.service" "$stage/systemd/restic-station.service"
    cp "$REPO_ROOT/packaging/linux/systemd/restic-station.timer" "$stage/systemd/restic-station.timer"

    local tarball="$DIST_DIR/restic-station-linux-$arch.tar.gz"
    rm -f "$tarball"
    # --numeric-owner + owner/group 0: reproducible-ish archive, and no
    # meaning is lost — none of these files care who built them.
    tar -czf "$tarball" --numeric-owner --owner=0 --group=0 -C "$DIST_DIR" "restic-station-linux-$arch"
    echo "  wrote $tarball ($(wc -c < "$tarball" | tr -d ' ') bytes)"
}

for arch in "${ARCHES[@]}"; do
    package_one "$arch"
done

log "SHA256SUMS"
(
    cd "$DIST_DIR"
    : > SHA256SUMS
    for arch in "${ARCHES[@]}"; do
        tarball="restic-station-linux-$arch.tar.gz"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$tarball" >> SHA256SUMS
        else
            shasum -a 256 "$tarball" >> SHA256SUMS
        fi
    done
)
cat "$DIST_DIR/SHA256SUMS"

log "Done — $DIST_DIR"
ls -la "$DIST_DIR"
