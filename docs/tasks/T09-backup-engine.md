# T09 — BackupEngine pipeline

**Size:** L · **Model:** Opus · **Review:** Fable (label `fable-review`) — **this is the component that can destroy data; treat every spec sentence as a requirement** · **Depends on:** T03, T04, T05, T06, T07, T08 · **Milestone:** M2

## Goal
The orchestration heart: scheduled/manual set runs (backup → mirror → retention), checks, and all status/state bookkeeping — implementing `docs/architecture.md` (error taxonomy, RunStatus), `docs/scheduling.md` (locking, staleness), `docs/restic-cli.md` (command semantics), and the scenario table in `docs/testing.md` **row by row**.

## Create
`Core/Sources/ResticStationCore/Engine/BackupEngine.swift`:
```swift
public final class BackupEngine {
    public init(config: AppConfig, paths: AppPaths, restic: ResticRunner,
                keychain: KeychainClient, runStore: RunStore,
                stateStore: StateStore, reachability: Reachability,
                now: @Sendable () -> Date = Date.init)          // injectable clock
    public func runSet(_ set: BackupSet, trigger: RunTrigger) async -> SetRunOutcome
    public func runCheck(_ set: BackupSet) async -> RunStatus    // scheduled slice check on primary
    public func runPrune(_ set: BackupSet) async -> RunStatus    // manual "apply retention now" (primary + synced secondaries)
    public func runRestore(request: RestoreRequest) async -> RunStatus
    public func initSecondary(_ set: BackupSet, dest: Destination) async -> RunStatus
}
```

### `runSet` sequence (each numbered step maps to scenario-table rows)
1. **Keychain pre-flight** for primary (T04's mechanism): unavailable → log, return `.retryable` — NO run record, NO `lastBackupStart` update. *(row 9)*
2. Acquire `locks/set-<id>.lock` (`tryAcquire`): busy → `.skipped` index record, stop. *(row 10)*
3. Update `lastBackupStart = now()` in schedule-state (attempt-based semantics — BEFORE the backup, per scheduling.md).
4. Probe primary: not `.reachable` → `backup` run record `.failed` with reason, stop. *(row 2)*
5. `backup` (begin run w/ new groupId = runId; stream: every `status` → throttled `current-run` state write ≤ 1/1.5 s, every raw line → log). Exit 3 → `.warning`, continue. Exit 11 → `unlock` + one retry per restic-cli.md. Exit 1/2/10/12 → `.failed`, stop (no copies, no retention). *(rows 4, 5, 7, 8)* On success/warning update primary repo-status `lastSyncedAt`.
6. For each secondary (config order): probe → offline: update repo-status (`reachable:false`), NO run record, continue *(row 3)*. Reachable: `copy` run record (from=primary; phase `copying-<destId>`); success → update `lastSyncedAt`, then **if retention non-empty: `forget` on the secondary** (`prune` record, same groupId). Copy failure → `.failed` copy record, NO forget on that secondary *(rows 6, 12)*, continue with others.
7. Retention on primary if policy non-empty *(row 11: empty → skip)*: `forget --prune` → `prune` record.
8. Clear `current-run` state, release lock. Group outcome = worst child status.

### Safety invariants (Fable review checklist — violations are blockers)
- `forget` is invoked with `--prune` ONLY in steps 6/7 flows shown; NEVER without an explicit non-empty `RetentionPolicy` (double guard: `ResticCommand.forget` preconditions + engine check).
- `forget` never targets a destination whose copy did not succeed **in this run** (stale mirror + aggressive forget = data loss window).
- Restore never runs concurrently with a backup of the same set (same set lock).
- Every restic child's raw output lands in a run log before any parsing decision.
- `checkSliceCursor` advances only on check success.

### runCheck / runPrune / runRestore / initSecondary
Per restic-cli.md: check uses slice rotation (T06 `nextCheckSlice`), structure-only on secondaries every 4th check; prune = dry-run first is the UI's job — engine's `runPrune` is the real one; restore builds `RestoreRequest {destId, snapshotID, subpath?, targetPath, includes, overwriteMode}`; all take the set lock and write run records.

## Tests
The 12-row scenario table from `docs/testing.md` §BackupEngine, one parameterized test each, driven by FakeProcessRunner scripts (script BOTH the keychain pre-flight `find-generic-password` replies and the restic replies — order matters and is part of the assertion). Assert: exact sequence of spawned argvs, index records (kind/status/groupId), schedule-state and repo-status mutations, current-run lifecycle (written during, cleared after). Plus: throttling test (status flood → ≤ N state writes), clock injection (fixed `now`).

## Acceptance criteria
- [ ] All 12 scenario rows implemented as tests and green (macOS + Linux container).
- [ ] Safety invariants each have at least one dedicated negative test.
- [ ] No direct `Process`/`Date()`/`Calendar.current` usage (everything injected).
