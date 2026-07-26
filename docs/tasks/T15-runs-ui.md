# T15 — Runs history, run detail, live progress

**Size:** M · **Model:** Opus (layout latitude) · **Depends on:** T13, T07 · **Milestone:** M3

## Goal
The Runs screen per `docs/ui-spec.md` §Runs: grouped history, filters, live in-flight progress, log viewer.

## Create (`App/Sources/Views/Runs/`)
- `RunListView.swift` — newest-first from `StateWatcher.recentRuns`, grouped by `groupId` (backup row expands to nested copy/prune rows); columns and filter bar per ui-spec; running run shows determinate `ProgressView` fed by `currentRuns[setId]` (indeterminate when `totalBytes` unknown); toolbar Back Up Now with busy-disable + explanation.
- `RunDetailView.swift` — metadata header per ui-spec (monospaced copyable snapshot id via `.textSelection(.enabled)` + copy button; stats formatted with `ByteCountFormatter`); log view: monospaced, auto-scrolling tail while `status == running` (re-read `RunStore.logURL` on StateWatcher events; read only the appended suffix — keep a file offset), full static content when finished; "Reveal log in Finder" (`NSWorkspace.activateFileViewerSelecting`).
- Relative timestamps via `RelativeDateTimeFormatter`, absolute on hover/tooltip.

## Acceptance criteria
- [ ] With a fixture config + local repos: trigger Back Up Now → running row appears with live progress → completes → group shows backup + copy children with stats.
- [ ] Log tail updates while running (back up a directory big enough to take ~10 s, e.g. generated 200 MB of random files) and stops cleanly at completion.
- [ ] Filters (set / kind / status) compose; empty-state text when filters match nothing.
- [ ] `.skipped` and `.warning` runs render distinctly (badge + reason in detail).
