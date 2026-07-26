# T11 — LaunchdManager (SMAppService) + HelperInvoker

**Size:** M · **Model:** Opus · **Review:** Fable (label `fable-review`) · **Depends on:** T01, T10 · **Milestone:** M2

## Goal
The app's bridge to launchd and the helper, per `docs/keychain-and-fda.md` §3 and `docs/scheduling.md` §plist. This task is small in lines but dense in gotchas — read both docs fully first.

## Create (`App/Sources/Support/`)
- `LaunchdManager.swift` — wraps `SMAppService.agent(plistName: "net.herila.ResticStation.helper.plist")`:
  ```swift
  @MainActor final class LaunchdManager: ObservableObject {
      @Published private(set) var status: SMAppService.Status
      func refreshStatus()
      func register() throws          // then refreshStatus
      func unregister() async throws
      func openLoginItemsSettings()   // SMAppService.openSystemSettingsLoginItemsSettings()
      func kickstartTick(restart: Bool = false)
      // Process: /bin/launchctl kickstart [-k] gui/<getuid()>/net.herila.ResticStation.helper
      // restart=true (-k) ONLY for the FDA re-check flow; default must NOT kill a running backup
  }
  ```
- `HelperInvoker.swift`:
  ```swift
  struct HelperInvoker {
      static var helperURL: URL   // Bundle.main.bundleURL/Contents/MacOS/restic-station-helper
      func backUpNow(setId: UUID) async -> HelperResult
      func prune(setId: UUID) async -> HelperResult
      func check(setId: UUID) async -> HelperResult
      func initSecondary(setId: UUID, destId: UUID) async -> HelperResult
      func probeRepo(setId: UUID, destId: UUID) async -> HelperResult
      func restore(_ req: RestoreRequestArgs) async -> HelperResult
      func fdaCheck() async -> HelperResult          // runs helper directly with --context app-spawned
  }
  enum HelperResult { case ok(output: String); case busy; case failed(output: String) } // exit 0/2/other per T10 contract
  ```
  Spawns via `Process` (this is App target — direct `Process` use is fine here; the Core-only injection rule doesn't apply, but keep it in one file). Long operations run detached — the invoker returns when the helper exits; callers use Swift concurrency `Task` so UI never blocks. Do NOT capture the helper's streaming progress here; the UI reads `state/` (StateWatcher, T12) — helper stdout is only for the final result line.

## Gotchas to honor (from keychain-and-fda.md — Fable review checklist)
- Registration only meaningful from a stable app location; when `status == .notFound` and bundle path contains `DerivedData`, surface the "copy to /Applications" hint in the thrown error/status text.
- Handle all four `SMAppService.Status` cases explicitly; `.requiresApproval` → UI must call `openLoginItemsSettings()`.
- `kickstart` argv exactly `gui/<uid>/<label>`; uid via `getuid()`, never hard-coded 501.
- After any config save that changes schedules, callers kick a tick (no `-k`).

## Verification (manual, documented in PR — CI cannot exercise SMAppService)
The SMAppService manual checklist in `docs/testing.md` §Layer 3, executed with a locally built app copied to /Applications; paste the `launchctl print` output into the PR. `HelperInvoker` verified by wiring a temporary debug menu (or unit-testing argv construction by extracting a pure `argv(for:)` function).

## Acceptance criteria
- [ ] Builds; `argv(for:)` unit-tested for every helper action (exact strings).
- [ ] Manual checklist passed and evidenced in PR (register → tick fires ≤ 2 min → quit app → tick still fires → unregister → gone).
- [ ] `kickstartTick()` default path proven not to interrupt a running helper (`kickstart` without `-k` on a busy service is a no-op — show `launchctl` output).
