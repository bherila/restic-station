# T18 — Onboarding + Settings (restic discovery, FDA, background agent)

**Size:** M · **Model:** Opus (layout latitude) · **Review:** Fable (label `fable-review`) · **Depends on:** T11, T12, T13 · **Milestone:** M3

## Goal
Settings panes and the first-launch wizard per `docs/ui-spec.md` §Settings/§Onboarding, implementing the FDA verification protocol from `docs/keychain-and-fda.md` §2 exactly. This is where silent-failure modes get made visible to the user — treat every status surface as safety-critical.

## Create
- `App/Sources/Support/ResticDiscovery.swift` — candidate probe per restic-cli.md/architecture: `/opt/homebrew/bin/restic`, `/usr/local/bin/restic`, `/opt/local/bin/restic`, then `PATH` entries (from the app's env, best-effort); validate via `version --json` (T05 `VersionInfo`, `meetsMinimum("0.17.0")`); persist chosen absolute path to config.
- `App/Sources/Views/Settings/GeneralSettings.swift` — menubar toggle (+ the launch-at-login note per ui-spec).
- `App/Sources/Views/Settings/ResticSettings.swift` — discovery status chip (OK green w/ version, too-old yellow, missing red with `brew install restic` copy), "Locate manually…".
- `App/Sources/Views/Settings/PermissionsView.swift` —
  - FDA card: App badge (in-process probe: read `~/Library/Safari`, fallback `~/Library/Mail` — same logic as helper, shared via Core if convenient) + Background-agent badge (from `state/fda-check.json` via StateWatcher; "unknown" when file absent/stale > 1 h); **Re-check** button → `LaunchdManager.kickstartTick(restart: true)` then await state change (timeout 30 s → keep "unknown" + hint); "Open Full Disk Access settings" deep-link button; help disclosure with the fallback instructions and copyable helper path per keychain-and-fda.md.
  - Background-agent card: SMAppService status → Enabled / Requires approval ("Open Login Items settings") / Not registered ("Enable") / Not found (copy-to-/Applications hint per T11); caption per ui-spec.
- `App/Sources/Views/Settings/OnboardingView.swift` — 4-step wizard per ui-spec (restic blocks, agent, FDA with live badges, first set → opens editor); shown when config has no sets and not previously completed (persist a `onboardingCompleted` flag — add to AppConfig as optional bool, migration-safe); re-runnable from Settings.

## Acceptance criteria (manual checklist from testing.md §Layer 3, evidenced in PR from /Applications)
- [ ] FDA revoke → both badges denied; grant to app → App badge flips immediately (probe on foreground/appear), Re-check → Agent badge flips (real launchd-context evidence: `state/fda-check.json` has `"context":"launchd"` and fresh timestamp).
- [ ] Agent flow: Not registered → Enable → Enabled (or Requires approval → Settings deep link works).
- [ ] restic discovery: found at `/opt/homebrew/bin/restic` with version chip; manual-locate overrides; missing-binary state renders (temporarily rename restic to test).
- [ ] Onboarding appears on first launch with empty config, completes into a working set editor, never reappears after completion.

## Fable review focus
The Re-check flow's kickstart `-k` usage (must not kill a running backup — gate on no current-run state, or warn), staleness rules for the agent badge, FDA probe correctness (a path that exists AND is TCC-protected on both macOS 14 and 15).
