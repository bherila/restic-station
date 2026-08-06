# Release checklist

Manual process for cutting a Restic Station release. There is no release automation yet; every step below is run by hand from a clean, green `main`.

## 0. Pre-flight

- [ ] CI green on `main` — all five jobs (`linux`, `macos`, `release-linux`, `linux-integration`, `linux-runtime-verify`; see `docs/testing.md`'s CI table).
- [ ] Run the **manual checklists** in [testing.md §Layer 3](testing.md#layer-3--manual-checklists-docstasks-reference-these-run-before-tagging-a-release) with the release build copied to `/Applications`: SMAppService, FDA badges, keychain-under-scheduler, sleep catch-up, restore. These cannot be automated — do not skip them.
- [ ] No open issues labeled release-blocking.

## 1. Version bump

Both fields live in `project.yml` (they flow into the app *and* embedded helper Info.plists via xcodegen):

| Field | Meaning |
|---|---|
| `MARKETING_VERSION` | User-visible semver, e.g. `0.2.0` |
| `CURRENT_PROJECT_VERSION` | Monotonic build number; bump by 1 every release |

After editing: `./scripts/bootstrap.sh` (re-runs `xcodegen generate`), commit as `Release vX.Y.Z`.

## 2. Build

Requires a machine with full Xcode (not CLT-only):

```sh
./scripts/bootstrap.sh
xcodebuild -scheme "Restic Station" -configuration Release \
  -derivedDataPath build build
APP="build/Build/Products/Release/Restic Station.app"
```

## 3. Sign — Developer ID + hardened runtime

The app is intentionally **not sandboxed** (see [keychain-and-fda.md §4](keychain-and-fda.md)); it needs no entitlement exceptions (no JIT, no plugins), so hardened runtime is enabled with no entitlements file. Sign inside-out — the embedded helper first, then the bundle:

```sh
IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  "$APP/Contents/MacOS/restic-station-helper"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
```

> No Developer ID certificate? Stop after an ad-hoc sign (`codesign --force --deep -s - "$APP"`) and mark the release as **unsigned/personal-use** in the release notes — recipients must clear quarantine themselves (`xattr -dr com.apple.quarantine`). Notarization (step 4) is impossible without Developer ID; skip to step 5.

## 4. Notarize and staple

One-time setup: `xcrun notarytool store-credentials restic-station --apple-id <id> --team-id <TEAMID> --password <app-specific-password>`.

```sh
ditto -c -k --keepParent "$APP" ResticStation.zip
xcrun notarytool submit ResticStation.zip --keychain-profile restic-station --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"   # expect: accepted, Notarized Developer ID
# re-zip AFTER stapling — the stapled ticket must ship in the archive
rm ResticStation.zip
ditto -c -k --keepParent "$APP" "Restic-Station-vX.Y.Z.zip"
```

## 5. Tag and publish

```sh
git tag vX.Y.Z && git push origin main vX.Y.Z
gh release create vX.Y.Z "Restic-Station-vX.Y.Z.zip" \
  --title "Restic Station vX.Y.Z" --notes-file <release-notes.md>
```

Release notes should state the signing posture (notarized / ad-hoc), the minimum macOS (14) and restic (≥ 0.18) versions, and link the FDA setup walkthrough in the README.

## 6. Post-release smoke test

On a machine (or account) that has never run the app: download the release zip, unzip, move to `/Applications`, launch — Gatekeeper must open it without warnings (notarized builds). Complete onboarding through the FDA step and confirm one scheduled backup fires.

---

**Dry-run status (2026-07-27):** steps 1–3 verified through *ad-hoc* signing (no Developer ID certificate on the dev machine); notarization steps are written from the standard `notarytool` flow but have not been executed yet — verify on first real Developer ID release.
