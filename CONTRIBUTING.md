# Contributing

Thanks for your interest in Restic Station. Two things make this repo unusual — read these before opening a PR.

**The Xcode project is generated.** `ResticStation.xcodeproj` is produced by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml` — never edit the project file directly; edit `project.yml` and run `./scripts/bootstrap.sh`. All logic lives in the `Core` Swift package, which must compile and pass its tests on **Linux** as well as macOS (`swift test --package-path Core`; CI runs it in a `swift:6.1` container). Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) — not XCTest. Darwin-only API belongs in the App/Helper targets or behind `#if os(macOS)`.

**The spec docs in [`docs/`](docs/) are normative.** `architecture.md`, `data-model.md`, `restic-cli.md`, `scheduling.md`, `keychain-and-fda.md`, `ui-spec.md`, and `testing.md` define the intended behavior; the code implements them. If your change alters behavior, update the relevant doc in the same PR — a PR that makes code and docs disagree will be asked to reconcile them. Key invariants to preserve (each has negative tests — keep them): all mutating restic operations go through `restic-station-helper`; keychain access only via the `/usr/bin/security` subprocess with `-T /usr/bin/security` at item creation; never `forget` with an empty retention policy, never `forget`/`prune` a mirror that isn't caught up to the primary.

CI must be green (Linux Core tests, macOS build + Core tests + real-restic integration script) before merge.
