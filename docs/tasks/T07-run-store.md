# T07 — RunStore, LogWriter, FileLock

**Size:** M · **Model:** Sonnet · **Depends on:** T02 (AppPaths) · **Milestone:** M1

## Goal
Run recording per `docs/data-model.md` (§index.jsonl, §metadata.json) and `docs/architecture.md` (§RunStatus, runId format), plus the flock wrapper per `docs/scheduling.md` §Locking.

## Create
- `Core/Sources/ResticStationCore/Runs/RunRecord.swift` — `RunKind` (backup/copy/check/prune/restore/init), `RunStatus` (success/warning/failed/skipped/running), `RunTrigger` (scheduled/manual), `RunIndexEntry` (the compact index-line type: fields per data-model.md incl. `groupId`), `RunMetadata` (superset per data-model.md incl. `pid`, `resticExitCode`, `argvRedacted`, `stats?`).
- `Core/Sources/ResticStationCore/Runs/RunStore.swift`:
  ```swift
  public struct RunStore {
      public init(paths: AppPaths)
      public func begin(kind:setId:destId:trigger:groupId:) throws -> ActiveRun
        // makes runId per architecture.md format, creates dir, writes metadata (status running, pid = getpid())
      public func finish(_ run: ActiveRun, status:…, stats:…, errorSummary:…) throws
        // atomic metadata rewrite + append index line under flock on index.jsonl companion lock
      public func recoverInterrupted() throws -> [String]
        // scan metadata with status==running, kill(pid,0) fails → rewrite failed("interrupted") + index line; returns runIds
      public func recentRuns(limit: Int) throws -> [RunIndexEntry]      // reads index.jsonl tail, newest first
      public func lastRun(setId: UUID, kind: RunKind) throws -> RunIndexEntry?
      public func metadata(runId: String) throws -> RunMetadata
      public func logURL(runId: String) -> URL
  }
  ```
- `Core/Sources/ResticStationCore/Runs/LogWriter.swift` — line-append handle to `runs/<id>/log.txt`, timestamps each line `[HH:mm:ss] `, flushes per line, `close()`.
- `Core/Sources/ResticStationCore/Locking/FileLock.swift` — per scheduling.md: `init(path:)`, `tryAcquire() -> Bool` (open O_CREAT, `flock(fd, LOCK_EX|LOCK_NB)`), `release()`, deinit releases. Import `Darwin`/`Glibc` conditionally.

Index reading must tolerate a truncated/corrupt last line (crash mid-append): skip undecodable lines with a warning, never throw from `recentRuns`.

## Tests
Temp AppPaths root. begin/finish round-trip (metadata + index line contents, groupId propagation). Interrupted recovery: write running-metadata with pid 999999 (dead) → recover → failed + index entry; with own live pid → untouched. Index corruption tolerance (append garbage line). `lastRun` filtering. FileLock: two instances same path — second `tryAcquire` false while first held, true after release (flock is per open-file-description — two separate opens, valid in-process). LogWriter format + flush (read while open).

## Acceptance criteria
- [ ] `swift test` green (macOS + Linux container).
- [ ] runId format exactly `20260726T205704Z-backup-6f9619ff` style (UTC, lowercased uuid prefix).
- [ ] All writes atomic per data-model.md preamble; index append is O_APPEND single write under lock.
