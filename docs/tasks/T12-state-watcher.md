# T12 — StateWatcher (app side)

**Size:** S · **Model:** Sonnet · **Depends on:** T08 · **Milestone:** M2

## Goal
Reactive bridge from the on-disk state (`state/`, `runs/index.jsonl`) to SwiftUI, per `docs/architecture.md` §Process model: directory watcher is the source of truth, distributed notification is a latency nudge.

## Create (`App/Sources/Support/StateWatcher.swift`)
```swift
@MainActor final class StateWatcher: ObservableObject {
    @Published private(set) var scheduleState: ScheduleState?
    @Published private(set) var currentRuns: [UUID: CurrentRunState]   // keyed by setId
    @Published private(set) var repoStatuses: [UUID: RepoStatus]       // keyed by destId
    @Published private(set) var fdaCheck: FdaCheckResult?
    @Published private(set) var recentRuns: [RunIndexEntry]            // via RunStore.recentRuns(limit: 200)
    init(paths: AppPaths, runStore: RunStore, stateStore: StateStore)
    func start()
    func stop()
    func reloadNow()
}
```
Implementation: `DispatchSource.makeFileSystemObjectSource(fileDescriptor: open(stateDir), eventMask: .write)` for the `state/` directory + a second source for `runs/` (index appends); `DistributedNotificationCenter` observer for `net.herila.ResticStation.stateChanged` → same handler. Debounce 250 ms (Task-based). Handler re-reads everything through StateStore/RunStore read APIs (all tolerant of partial writes by construction) and publishes on main actor. `current-run-*.json` files are enumerated by filename pattern to build the dictionary. Directory FD must be reopened if the directory is recreated (watch for `.delete` event too).

## Verification
Read APIs already unit-tested in Core (T08/T07). App-side: small XCTest in a new app-target test bundle is NOT required; instead document a manual check in the PR: launch app with `RESTIC_STATION_DATA_DIR` pointing at a temp dir, `touch`/write a `current-run-<uuid>.json` from a terminal, observe (via a debug `print` in the handler or the T13 UI once merged) the update within ~300 ms; delete it, observe clearing.

## Acceptance criteria
- [ ] Builds; publishes update after external file write ≤ 500 ms (manual evidence).
- [ ] No polling timers; CPU idle when nothing changes.
- [ ] Survives the state directory being deleted and recreated.
