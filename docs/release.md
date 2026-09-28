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

Also set `Version.version` in `Helper/Sources/Commands/Version.swift` to the same `MARKETING_VERSION` — the Linux helper has no bundle to read it from, and `VersionReportTests` fails until the two match. `CURRENT_PROJECT_VERSION` is what Sparkle orders updates by, and `scripts/make-appcast.sh` refuses a build that isn't newer than the published one.

After editing: `./scripts/bootstrap.sh` (re-runs `xcodegen generate`), commit as `Release vX.Y.Z`.

## 2. Build

Requires a machine with full Xcode (not CLT-only):

```sh
./scripts/bootstrap.sh
xcodebuild -scheme "Restic Station" -configuration Release \
  -derivedDataPath build build
APP="build/Build/Products/Release/Restic Station.app"
```

## 3. Sign — ad-hoc

Restic Station is **not** signed with a Developer ID and is **not** notarized;
this is the permanent posture, not a stopgap. Releases are ad-hoc signed and
personal-use.

The app is intentionally **not sandboxed** (see [keychain-and-fda.md §4](keychain-and-fda.md)).
The Release build from step 2 is already ad-hoc signed. If anything in the
bundle was changed afterwards, re-sign it inside-out — the embedded helper and
Sparkle's nested helpers first, then the bundle:

```sh
codesign --force --sign - "$APP/Contents/MacOS/restic-station-helper"
SPK="$APP/Contents/Frameworks/Sparkle.framework"
codesign -f -s - "$SPK/Versions/B/XPCServices/Installer.xpc"
codesign -f -s - --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s - "$SPK/Versions/B/Autoupdate"
codesign -f -s - "$SPK/Versions/B/Updater.app"
codesign -f -s - "$SPK"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
```

Consequences, stated in every release's notes:

- **First install:** Gatekeeper blocks a downloaded ad-hoc app. The user
  clears quarantine (`xattr -dr com.apple.quarantine "/Applications/Restic Station.app"`)
  or approves it in System Settings → Privacy & Security → Open Anyway.
  Updates installed by Sparkle don't go through this.
- **Full Disk Access after an update:** TCC keys an ad-hoc binary to its exact
  code, so FDA for the app *and* the helper may have to be re-granted after
  each update; see §Updates.

## 4. Notarize

Not applicable — notarization requires a Developer ID.

## 5. Release-artifact verification

- [ ] Run **every** manual checklist in [testing.md §Layer 3](testing.md#layer-3--manual-checklists-docstasks-reference-these-run-before-tagging-a-release) with the final signed release artifact copied to `/Applications`, and record the required build SHA/artifact identity with each result. This includes SMAppService, stall detection, FDA, the Keychain evidence matrix, sleep/catch-up, physical-mirror recovery, read-only retention preview, the manual-apply containment refusal, scheduled retention via a due tick, token-confirmed reclaim space, and restores from local, external-volume, and SFTP destinations. These cannot be automated — do not skip them. A release that waives this gate anyway says so in its release notes, and names the evidence that ran instead (for example, the hosted `macOS Release Verification` workflow).

## 6. Tag and publish

```sh
git tag vX.Y.Z && git push origin main vX.Y.Z
scripts/make-appcast.sh "$APP" dist/sparkle release-notes.html   # see §Updates
gh release create vX.Y.Z dist/sparkle/Restic-Station-X.Y.Z.zip dist/sparkle/appcast.xml \
  --title "Restic Station vX.Y.Z" --notes-file <release-notes.md>
```

The Sparkle zip is the macOS app download: build it with the script (it zips the
final, stapled `$APP`) rather than zipping by hand, because its signature is
what every installed copy checks. Upload `appcast.xml` exactly as the script
wrote it — the feed is signed, and any edit (even whitespace) makes every
installed copy refuse it until it is re-signed.

Release notes should state the signing posture (ad-hoc, not notarized, and what that means for first install and Full Disk Access), the minimum macOS (14) and restic (≥ 0.18) versions, and link the FDA setup walkthrough in the README.

## 7. Post-release smoke test

On a machine (or account) that has never run the app: download the release zip, unzip, move to `/Applications`, clear quarantine as the release notes say, launch. Complete onboarding through the FDA step and confirm one scheduled backup fires.


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

**Signed feed.** The appcast is signed as a whole, not just the archive
(`SURequireSignedFeed`, with `SUVerifyUpdateBeforeExtraction`, which Sparkle
requires alongside it). Sparkle's archive signature covers only the zip, so an
unsigned feed could pair any genuine release archive — including an old one —
with any version number or schema claim. `SUSignedFeedFailureExpirationInterval`
is 0: by default Sparkle falls back, after 20 days of failures, to offering
items from a feed it cannot verify; with 0 a feed that fails verification is
always an error and nothing is downloaded.

**Signing key.** Updates are signed with an Ed25519 key whose public half is
`SUPublicEDKey`. The private key lives in the release machine's login keychain
(generic password, account `restic-station`, service
`https://sparkle-project.org`) with one offline backup kept by the maintainer.
The same key signs the archive and the feed.
**Losing it strands every installed copy**: Sparkle rejects any update not
signed by the key the running app trusts. Rotating it requires an update signed
by the *old* key that ships the new `SUPublicEDKey`. `scripts/make-appcast.sh`
cannot package that transition yet: it verifies every signature against the
key inside the bundle being released, which is the new one. Add a
transitional trust-key option before attempting a rotation.

**Code signing.** Sparkle accepts an update whose EdDSA signature verifies even
when the Apple code signature differs, which is what makes ad-hoc releases
updatable at all. The new bundle must still be validly signed (ad-hoc at
minimum). On an ad-hoc build, macOS keys Full Disk Access to the exact binary,
so FDA — for the app *and* the helper — must be re-granted after each update,
and the Login Items approval may reset; Settings → Permissions shows both.
The project does not use a Developer ID, so this cost is permanent unless a
stable self-signed identity turns out to keep grants across updates
(untested).

**Config schema gate.** Each appcast item carries
`<resticstation:configSchemaVersion>` — the `config.json` schema the release
writes, read by `scripts/make-appcast.sh` from the built helper's
`version --json`, never from source. The running app compares it with its own
`AppConfig.currentVersion` before Sparkle may offer the update. The element is
evidence only because the feed is signed: it and the archive's signature sit in
the same signed document, so the claim is bound to that archive.

| Declared schema | Behaviour |
|---|---|
| any, from a feed whose signature did not verify | refused (Sparkle normally stops before this point; the gate re-checks `SUAppcastItem.signingValidationStatus` so it never trusts an unverified claim) |
| equal | offered normally |
| higher | an alert explains that installing migrates the shared config and that every host sharing it must upgrade together; "Not Now" cancels, "Continue to Update…" proceeds to Sparkle's window and is remembered for that build |
| missing or malformed | treated as an unknown change: same alert |
| lower | refused — that release could not read the config this one wrote |

The element prefix must stay exactly `resticstation:` — Sparkle keys
non-Sparkle elements by their qualified name as written.

**`scripts/make-appcast.sh`** takes the final signed `.app`, zips it, signs the
zip, verifies the signature against the app's own `SUPublicEDKey` with
OpenSSL 3, and writes a one-item `appcast.xml`, which it then signs with
`sign_update` and verifies the same way — over the bytes before the trailing
`<!-- sparkle-signatures:` block, the only bytes Sparkle parses — including
that the signed feed still declares the helper's schema. The published feed it
compares against must verify too; its build and schema are read only from the
signed bytes. It refuses a build number not
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
archive. With the feed signed, the same build-1 copy installed build 2 from the
signed feed, and after a one-byte edit to that feed it fetched the appcast and
downloaded nothing. Not yet exercised: an update of a
running copy that holds FDA.

---

**Dry-run status (2026-07-27):** steps 1–3 verified with ad-hoc signing.
