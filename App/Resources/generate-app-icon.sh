#!/bin/sh
set -eu

resource_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_png="$resource_dir/AppIconSource.png"
icon_dir="$resource_dir/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$source_png" ]; then
    echo "missing app icon source: $source_png" >&2
    exit 1
fi

for pixels in 16 32 64 128 256 512 1024; do
    sips --resampleHeightWidth "$pixels" "$pixels" "$source_png" \
        --out "$icon_dir/AppIcon-${pixels}.png" >/dev/null
done

echo "Generated macOS app icon sizes in $icon_dir"
