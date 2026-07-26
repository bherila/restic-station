# T01 — Repo scaffold: XcodeGen project, targets, CI

**Size:** M · **Model:** Sonnet · **Depends on:** — · **Milestone:** M0

## Goal
`xcodegen generate && xcodebuild -scheme "Restic Station" build CODE_SIGNING_ALLOWED=NO` succeeds; `swift test --package-path Core` runs (with a placeholder test); the built app bundle contains the helper binary and LaunchAgent plist in the right places; CI is green on both jobs.

## Create
- `project.yml` — XcodeGen spec:
  - Project `ResticStation`, bundle id prefix `net.herila`, deployment target macOS 14.0.
  - Target **Restic Station** (type `application`, SwiftUI): sources `App/Sources`, resources `App/Resources/Assets.xcassets`; NOT sandboxed (no entitlements file needed for dev; create empty `App/ResticStation.entitlements` wired in for future use); `INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.utilities`.
  - Target **restic-station-helper** (type `tool`): sources `Helper/Sources`; dependency on package + `swift-argument-parser` (add package dependency `https://github.com/apple/swift-argument-parser` from: 1.3.0 at project level).
  - Both targets depend on local package: `packages: { ResticStationCore: { path: Core } }`.
  - App embeds helper: `dependencies: [{ target: restic-station-helper, embed: true, codeSign: true, copy: { destination: executables } }]` — verify with XcodeGen docs; the result must be `Contents/MacOS/restic-station-helper` inside the app bundle.
  - App copies the plist: build phase `copyFiles` destination `wrapper`, subpath `Contents/Library/LaunchAgents`, file `App/Resources/net.herila.ResticStation.helper.plist`.
- `Core/Package.swift` — swift-tools 5.9+, `platforms: [.macOS(.v14)]`, library `ResticStationCore`, test target with `resources: [.copy("Fixtures")]` (create empty `Fixtures/.gitkeep`). One placeholder source file + one passing placeholder test.
- `App/Sources/ResticStationApp.swift` — `@main` App with a `WindowGroup` showing `Text("Restic Station")`.
- `App/Resources/net.herila.ResticStation.helper.plist` — exact content from `docs/scheduling.md` §plist.
- `App/Resources/Assets.xcassets` — empty app icon set + accent color (placeholder).
- `Helper/Sources/HelperMain.swift` — `@main` ArgumentParser `ParsableCommand` named `restic-station-helper`, one subcommand `version` printing `restic-station-helper 0.1.0` (real subcommands come in T10; structure them as separate files from the start).
- `scripts/bootstrap.sh` — `#!/bin/sh -e`: check xcodegen installed (else print `brew install xcodegen`), run `xcodegen generate`.
- `.github/workflows/ci.yml` — two jobs exactly as specified in `docs/testing.md` §CI (the integration-script step is added in T19; leave it out or guard on file existence).

## Acceptance criteria
- [ ] `./scripts/bootstrap.sh` then `xcodebuild -scheme "Restic Station" build CODE_SIGNING_ALLOWED=NO` exits 0.
- [ ] Built bundle: `Contents/MacOS/restic-station-helper` exists and `--version`/`version` runs; `Contents/Library/LaunchAgents/net.herila.ResticStation.helper.plist` exists (verify with `ls` + `plutil -lint`).
- [ ] `swift test --package-path Core` passes.
- [ ] `swift test` also passes inside a `swift:6.1` Linux container (CI `core-linux` job green).
- [ ] `*.xcodeproj` is git-ignored and not committed.
