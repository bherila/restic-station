# T16 — Restore UI (browse, search, restore, optional mount)

**Size:** L · **Model:** Opus (layout latitude) · **Depends on:** T13, T04, T05, T10 · **Milestone:** M3

## Goal
The Restore screen per `docs/ui-spec.md` §Restore. Read-only browsing calls `ResticRunner` directly from the app (the sanctioned exception in `docs/architecture.md`); the restore action itself goes through the helper.

## Create (`App/Sources/Views/Restore/`)
- `RestoreView.swift` — destination picker (grouped "Set ▸ Destination", secondaries included), snapshot list (`snapshots --json`, "mirrored" badge when `original` present), search field.
- `SnapshotBrowserView.swift` — lazy tree: root `ls <snap> /`; expanding a dir node runs `ls <snap> <node.path>` (**always use the `path` field from returned nodes — never reconstruct paths**; see restic-cli.md §ls); loading spinners per node; multi-select; breadcrumbs. Cache per (snapshot, path) for the session.
- `SearchResultsView.swift` — `find --json` within selected snapshot by default, "all snapshots" toggle; result rows selectable for restore.
- `RestoreSheet.swift` — target picker ("Original location" / "Choose folder…"), overwrite mode picker (maps to `--overwrite`, default Always), the original-location warning banner + "Consider backing up first — Back Up Now" button (invokes helper backup, sheet stays), Restore button → `HelperInvoker.restore` (selected paths become `--include` patterns rooted at the common `--sub` in-snapshot path); progress from `state/` current-run; completion summary (files/bytes from restore summary) + Reveal in Finder.
- `MountSection.swift` — macFUSE detection (`FileManager.fileExists(atPath: "/Library/Filesystems/macfuse.fs")`); present → Mount button spawning `restic mount` per restic-cli.md §mount (child `Process` owned by an `@MainActor MountController`; mountpoint `AppPaths.mountsDir(destId:)`; Unmount = SIGINT → 5 s → `diskutil unmount force` → SIGKILL; app termination unmounts (register in `applicationWillTerminate`)); absent → disabled card with the ui-spec copy.

## Acceptance criteria
- [ ] Manual E2E in PR: back up a fixture tree → browse root → expand two levels → select a file + a folder → restore to a temp target → `diff -r` matches originals.
- [ ] Restore to original location shows warning + backup suggestion; restore to fresh folder shows neither.
- [ ] Search finds a nested file by glob and restores it.
- [ ] Browsing a secondary (mirrored) repo works identically; mirrored badge visible.
- [ ] Without macFUSE the mount card is disabled with the exact ui-spec copy; with it (if available locally), mount → Finder shows snapshot → Unmount cleans up (evidence optional if macFUSE not installed — state which path was tested).
- [ ] App never invokes mutating restic commands directly (`grep` evidence: only helper invocations for restore).
