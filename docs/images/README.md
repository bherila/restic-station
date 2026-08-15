# Screenshot source

The README screenshots are captures of the real macOS app—not mockups—using the non-secret fixture in `scripts/fixtures/demo-macos/`.

To reproduce them from a built checkout:

```sh
DEMO_DIR=$(mktemp -d)
cp -R scripts/fixtures/demo-macos/. "$DEMO_DIR/"
RESTIC_STATION_DATA_DIR="$DEMO_DIR" \
  "dd/Build/Products/Debug/Restic Station.app/Contents/MacOS/Restic Station"
```

The fixture contains illustrative paths and run history only. It has no credentials, passwords, personal paths, or live repository endpoints.
