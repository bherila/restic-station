#!/bin/sh
# install.sh — installs restic-station-helper from this unpacked tarball.
# (T29 / issue #31; packaged by scripts/package-linux.sh)
#
#   ./install.sh            installs to ~/.local/bin
#   ./install.sh --system   installs to /usr/local/bin (needs write access —
#                            typically root, e.g. `sudo ./install.sh --system`)
#   ./install.sh --prefix=/some/dir   installs anywhere else
#
# Idempotent: safe to re-run (e.g. after unpacking a newer tarball over the
# same directory) — it always just overwrites the one file it installs.
# Never needs root for the default (--system not given).
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BINARY="$SCRIPT_DIR/restic-station-helper"

SYSTEM=0
PREFIX=""

for arg in "$@"; do
    case "$arg" in
        --system)
            SYSTEM=1
            ;;
        --prefix=*)
            PREFIX=${arg#--prefix=}
            ;;
        -h | --help)
            echo "Usage: $0 [--system] [--prefix=DIR]"
            echo ""
            echo "  (default)   install to \$HOME/.local/bin"
            echo "  --system    install to /usr/local/bin"
            echo "  --prefix=D  install to D"
            exit 0
            ;;
        *)
            echo "unknown option: $arg (see --help)" >&2
            exit 1
            ;;
    esac
done

if [ -z "$PREFIX" ]; then
    if [ "$SYSTEM" -eq 1 ]; then
        PREFIX="/usr/local/bin"
    else
        PREFIX="${HOME:?HOME is not set — pass --prefix=DIR instead}/.local/bin"
    fi
fi

if [ ! -f "$BINARY" ]; then
    echo "FATAL: $BINARY not found — run this script from inside the unpacked tarball." >&2
    exit 1
fi

mkdir -p "$PREFIX"
cp "$BINARY" "$PREFIX/restic-station-helper.tmp.$$"
chmod 755 "$PREFIX/restic-station-helper.tmp.$$"
mv "$PREFIX/restic-station-helper.tmp.$$" "$PREFIX/restic-station-helper"

echo "installed $PREFIX/restic-station-helper"
"$PREFIX/restic-station-helper" version 2>/dev/null || true

# Warn — do not fail — when the chosen prefix is not on PATH. A fresh
# ~/.local/bin is the single most common way this bites a first-time user.
case ":${PATH:-}:" in
    *":$PREFIX:"*)
        ;;
    *)
        echo ""
        echo "WARNING: $PREFIX is not on your PATH."
        echo "  Add it to your shell profile, e.g.:"
        echo "    echo 'export PATH=\"$PREFIX:\$PATH\"' >> ~/.profile"
        echo "  (then start a new shell, or: export PATH=\"$PREFIX:\$PATH\")"
        ;;
esac

echo ""
echo "Next steps:"
echo "  1. Make sure restic (>= 0.18) is on PATH: restic version"
echo "  2. Set up config.json — either:"
echo "       - copy one exported from another machine:"
echo "         $PREFIX/restic-station-helper config import /path/to/config.json"
echo "       - or write \$XDG_STATE_HOME/restic-station/config.json by hand"
echo "         (see README.md in this tarball, and docs/data-model.md upstream)"
echo "  3. Store each destination's password: "
echo "       $PREFIX/restic-station-helper secret set --dest <destination-id>"
echo "  4. Schedule it: $PREFIX/restic-station-helper timer install"
echo "     (systemd --user; falls back to printing a cron line on hosts without systemd)"
echo "  5. Check it: $PREFIX/restic-station-helper config validate"
