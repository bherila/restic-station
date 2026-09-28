# Release checklist

Manual process for cutting a Restic Station release. There is no release automation yet; every step below is run by hand from a clean, green `main`.

## 0. Pre-flight

- [ ] CI green on `main` — all five jobs (`linux`, `macos`, `release-linux`, `linux-integration`, `linux-runtime-verify`; see `docs/testing.md`'s CI table).
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
# Sparkle's nested helpers, innermost first (Sparkle's own documented order;
# Downloader.xpc keeps its entitlements).
SPK="$APP/Contents/Frameworks/Sparkle.framework"
codesign -f -s "$IDENTITY" -o runtime --timestamp "$SPK/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$IDENTITY" -o runtime --timestamp --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$IDENTITY" -o runtime --timestamp "$SPK/Versions/B/Autoupdate"
codesign -f -s "$IDENTITY" -o runtime --timestamp "$SPK/Versions/B/Updater.app"
codesign -f -s "$IDENTITY" -o runtime --timestamp "$SPK"
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

## 5. Release-artifact verification

- [ ] Run **every** manual checklist in [testing.md §Layer 3](testing.md#layer-3--manual-checklists-docstasks-reference-these-run-before-tagging-a-release) with the final signed release artifact (stapled when notarized) copied to `/Applications`, and record the required build SHA/artifact identity with each result. This includes SMAppService, stall detection, FDA, the Keychain evidence matrix, sleep/catch-up, physical-mirror recovery, read-only retention preview, the manual-apply containment refusal, scheduled retention via a due tick, token-confirmed reclaim space, and restores from local, external-volume, and SFTP destinations. These cannot be automated — do not skip them.

## 6. Tag and publish

```sh
git tag vX.Y.Z && git push origin main vX.Y.Z
scripts/make-appcast.sh "$APP" dist/sparkle release-notes.html   # see §Updates
gh release create vX.Y.Z dist/sparkle/Restic-Station-X.Y.Z.zip dist/sparkle/appcast.xml \
  --title "Restic Station vX.Y.Z" --notes-file <release-notes.md>
```

The Sparkle zip is the macOS app download: build it with the script (it zips the
final, stapled `$APP`) rather than zipping by hand, because its signature is
what every installed copy checks.

Release notes should state the signing posture (notarized / ad-hoc), the minimum macOS (14) and restic (≥ 0.18) versions, and link the FDA setup walkthrough in the README.

## 7. Post-release smoke test

On a machine (or account) that has never run the app: download the release zip, unzip, move to `/Applications`, launch — Gatekeeper must open it without warnings (notarized builds). Complete onboarding through the FDA step and confirm one scheduled backup fires.


## Updates (Sparkle)

The app updates itself with [Sparkle](https://sparkle-project.org) 2.10.0
(pinned exactly in `project.yml`), reading the appcast attached to the
**latest** GitHub release:
`https://github.com/bherila/restic-station/releases/latest/download/appcast.xml`.
GitHub's `latest` skips pre-releases and drafts, so a release that installed
copies should be offered must be published as a normal release.

**Policy** (Info.plist, `App/Resources/Info.plist`): checks once a day
(`SUScheduledCheckInterval` 86400), shows Sparkle's standard update window,
and never installs silently (`SUAllowsAutomaticUpdates` NO). Users can turn
background checks off in Settings → General; "Check for Updates…" is in the
app menu, the menu bar extra, and Settings.

**Signing key.** Updates are signed with an Ed25519 key whose public half is
`SUPublicEDKey`. The private key lives in the release machine's login keychain
(generic password, account `restic-station`, service
`https://sparkle-project.org`) with one offline backup kept by the maintainer.
**Losing it strands every installed copy**: Sparkle rejects any update not
signed by the key the running app trusts. Rotating it requires an update signed
by the *old* key that ships the new `SUPublicEDKey`.

**Code signing.** Sparkle accepts an update whose EdDSA signature verifies even
when the Apple code signature differs, which is what makes ad-hoc releases
updatable at all. The new bundle must still be validly signed (ad-hoc at
minimum). On an ad-hoc build, macOS keys Full Disk Access to the exact binary,
so FDA — for the app *and* the helper — must be re-granted after each update,
and the Login Items approval may reset; Settings → Permissions shows both.
Developer ID signing removes this, because the designated requirement then
survives updates.

**Config schema gate.** Each appcast item carries
`<resticstation:configSchemaVersion>` — the `config.json` schema the release
writes, read by `scripts/make-appcast.sh` from the built helper's
`version --json`, never from source. The running app compares it with its own
`AppConfig.currentVersion` before Sparkle may offer the update:

| Declared schema | Behaviour |
|---|---|
| equal | offered normally |
| higher | an alert explains that installing migrates the shared config and that every host sharing it must upgrade together; "Not Now" cancels, "Continue to Update…" proceeds to Sparkle's window and is remembered for that build |
| missing or malformed | treated as an unknown change: same alert |
| lower | refused — that release could not read the config this one wrote |

The element prefix must stay exactly `resticstation:` — Sparkle keys
non-Sparkle elements by their qualified name as written.

**`scripts/make-appcast.sh`** takes the final signed `.app`, zips it, signs the
zip, verifies the signature against the app's own `SUPublicEDKey` with
OpenSSL 3, and writes a one-item `appcast.xml`. It refuses a build number not
greater than the published one (Sparkle orders by `CFBundleVersion`, so bump
`CURRENT_PROJECT_VERSION` every release), a schema older than the published
one, and a missing published feed unless `PREVIOUS_APPCAST=none` (first
Sparkle release only). On a schema bump it prepends the fleet warning to the
release notes. Sign from another machine with
`SPARKLE_KEY_FILE=<exported key>`.

**Verified 2026-09-28** on macOS with ad-hoc builds: a build-1 copy under a
separate bundle ID and data directory found a localhost appcast for build 2,
downloaded and installed it, and the result passed
`codesign --verify --deep --strict`. With the same feed declaring schema v5,
it fetched the appcast and stopped at the confirmation without downloading the
archive. Not yet exercised: a Developer ID-signed update, and an update of a
running copy that holds FDA.

---

**Dry-run status (2026-07-27):** steps 1–3 verified through *ad-hoc* signing (no Developer ID certificate on the dev machine); notarization steps are written from the standard `notarytool` flow but have not been executed yet — verify on first real Developer ID release.
