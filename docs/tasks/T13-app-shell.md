# T13 — App shell, AppModel, navigation, MenuBarExtra

**Size:** M · **Model:** Opus (layout latitude — see ui-spec.md preamble) · **Depends on:** T02, T11, T12 · **Milestone:** M3

## Goal
The application skeleton per `docs/ui-spec.md` §Shell and §Menu bar: window + sidebar navigation with placeholder detail views (replaced by T14–T18), working menu bar extra, and the `AppModel` every screen builds on.

## Create (`App/Sources/`)
- `ResticStationApp.swift` (replace T01 stub) — `WindowGroup` (main window) + `Settings` scene + `MenuBarExtra(isInserted:)` bound through AppModel to `config.showMenuBarIcon`.
- `ViewModels/AppModel.swift` — `@MainActor ObservableObject` owning: `AppConfig` (loaded via ConfigStore; `saveConfig()` validates, persists, and calls `launchd.kickstartTick()` when schedule-relevant fields changed), `StateWatcher`, `LaunchdManager`, `HelperInvoker`, restic path/version info. Derived published values: per-set `SetHealth` (last run status + staleness + next due via ScheduleMath) and global `AppHealth` (drives menubar icon state: unresolved destructive audit failure → critical; otherwise any running → running; any failed-last-run/stale/FDA-denied/agent-not-enabled → warning; else idle).
- `MenuBar/MenuBarView.swift` — menu content exactly per ui-spec.md §Menu bar (per-set status lines, in-flight progress line, Back Up Now submenu → `HelperInvoker.backUpNow` in a Task, Open Restic Station (`NSApp.activate` + open window via `openWindow`), Quit with the "backups keep running" help text). Icon: the ordinary three SF Symbols from ui-spec.md plus the destructive-audit critical symbol, driven by `AppHealth`.
- `Views/MainWindow.swift` — `NavigationSplitView`; sidebar `List` with the five sections; detail = routed placeholder views (`Text("…")`) for Sets/Runs/Restore/Maintenance; Settings section opens the Settings scene. Min window size per ui-spec.

## Acceptance criteria
- [ ] Builds & launches; sidebar navigation works; window title "Restic Station".
- [ ] Menubar icon appears, reflects health (manually simulate: hand-write a `current-run` state file → icon flips to running; write repo-status with old `lastSyncedAt` + a config with small stalenessWarningDays → warning).
- [ ] Back Up Now on a fixture config actually invokes the helper (run record appears).
- [ ] Toggling `showMenuBarIcon` in config removes/restores the icon live.
- [ ] Quit leaves the launchd agent running (`launchctl print` still shows it).
