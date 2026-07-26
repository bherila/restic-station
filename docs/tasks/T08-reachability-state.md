# T08 — Reachability + StateStore

**Size:** S · **Model:** Sonnet · **Depends on:** T02, T04 · **Milestone:** M1

## Goal
Destination reachability probing and the shared state-file layer per `docs/data-model.md` (state schemas) and `docs/architecture.md` (§Process model).

## Create
- `Core/Sources/ResticStationCore/Engine/Reachability.swift`:
  ```swift
  public struct Reachability {
      public init(restic: ResticRunner)
      public func probe(_ dest: Destination) async -> RepoProbeResult
  }
  public enum RepoProbeResult { case reachable; case offline(reason: String); case error(ResticExitClass) }
  ```
  Local kind: `FileManager.fileExists(atPath: repoURL)` → missing = `.offline` (for `/Volumes/...` add reason "volume not mounted"). Remote kinds: `restic cat config` with 10 s timeout → exit 0 `.reachable`; timeout/network fail `.offline`; exit 10/12 `.error` (repo problems are NOT "offline" — they need user attention). Keychain-unavailable → `.offline(reason: "keychain locked")` (retryable, not alarming).
- `Core/Sources/ResticStationCore/Engine/StateStore.swift` — typed read/write for the four state files in data-model.md (`ScheduleState`, `CurrentRunState`, `RepoStatus`, `FdaCheckResult` as Codable structs matching the documented JSON exactly). Writes atomic; after each write, `#if os(macOS)` post `DistributedNotificationCenter.default().postNotificationName(Notification.Name("net.herila.ResticStation.stateChanged"), object: nil, userInfo: nil, deliverImmediately: true)` `#endif`. Reads return nil on missing/corrupt file (state is regenerable — never throw to callers). Helpers: `updateRepoStatus(destId:mutate:)`, `writeCurrentRun/clearCurrentRun(setId:)`, `updateScheduleState(setId:mutate:)`, `writeFdaCheck(_:)` (+ matching read functions).

## Tests
Fake-runner probes: local missing/present; remote scripted exit 0 / timeout(delay > timeout) / exit 10 / exit 12 / keychain pre-flight fail. StateStore round-trips for all four schemas against the JSON examples in data-model.md (decode the documented literal strings); corrupt file → nil; atomic write leaves no temp files.

## Acceptance criteria
- [ ] `swift test` green (macOS + Linux container; notification post correctly gated for Linux build).
- [ ] State JSON matches data-model.md examples byte-compatibly (modulo key order — use sortedKeys).
