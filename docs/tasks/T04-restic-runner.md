# T04 — ResticRunner, command builders, error mapping

**Size:** L · **Model:** Opus · **Review:** Fable (label `fable-review`) · **Depends on:** T01, T03 (ProcessRunning + KeychainClient) · **Milestone:** M1

## Goal
The typed execution layer every feature uses: build argv + env for each restic operation per `docs/restic-cli.md`, stream NDJSON, map exit codes, support cancellation and timeouts.

## Create
- `Core/Sources/ResticStationCore/Restic/ResticCommand.swift` — value type: `argv: [String]` (WITHOUT the binary path), `repoURL: String?`, `fromRepoURL: String?`, plus static builders for every command in restic-cli.md §Commands with the exact flags shown there:
  `.initRepo(repo:)`, `.initSecondary(repo:fromRepo:)` (adds `--copy-chunker-params`), `.backup(repo:sources:excludes:)`, `.copy(toRepo:fromRepo:)`, `.snapshots(repo:)`, `.ls(repo:snapshotID:path:)`, `.find(repo:pattern:snapshotID:)`, `.stats(repo:mode:)`, `.forget(repo:policy:prune:dryRun:)` (maps each non-nil RetentionPolicy field to its `--keep-*` flag; **precondition-fails on `policy.isEmpty`**), `.check(repo:readDataSubset:)` (subset as `"n/t"` string or nil), `.restore(repo:snapshotID:subpath:target:includes:overwrite:dryRun:)` (snapshot arg formatted `id:subpath` when subpath non-nil), `.mount(repo:mountpoint:)`, `.catConfig(repo:)`, `.unlock(repo:)`, `.version`. `--json` added automatically except for `copy`, `check`, `unlock`, `mount`.
- `Core/Sources/ResticStationCore/Restic/ResticRunner.swift`:
  ```swift
  public struct ResticInvocation { let destination: Destination; let fromDestination: Destination? }
  public final class ResticRunner {
      public init(resticPath: String, paths: AppPaths, keychain: KeychainClient, runner: ProcessRunning)
      /// Assembles env per restic-cli.md §General: minimal base (HOME, USER, TMPDIR),
      /// RESTIC_PASSWORD_COMMAND (+ RESTIC_FROM_PASSWORD_COMMAND when fromDestination != nil),
      /// RESTIC_CACHE_DIR, nonSecretEnv, secret env from keychain (both destinations' blobs;
      /// on key conflict the primary/from side loses — document inline).
      public func run(_ cmd: ResticCommand, for inv: ResticInvocation,
                      onLine: (@Sendable (ResticMessage) -> Void)? = nil,
                      onRawLine: (@Sendable (String) -> Void)? = nil,
                      timeout: TimeInterval? = nil) async throws -> ResticOutcome
  }
  public struct ResticOutcome { public let exitCode: Int32; public let status: ResticExitClass; public let messages: [ResticMessage]; public let rawOutput: String }
  ```
  `ResticMessage` is a minimal enum over parsed NDJSON lines: `.status(BackupStatus)`, `.summary(BackupSummary)`, `.exitError(code:message:)`, `.node(LsNode)`, `.snapshotHeader(Snapshot)`, `.restoreSummary(RestoreSummary)`, `.unparsed(String)` — decoding delegated to T05's parsers via a `ResticMessageDecoder` protocol so T04 and T05 can land independently (T04 ships a placeholder decoder returning `.unparsed`; T05 swaps in the real one).
- `Core/Sources/ResticStationCore/Restic/ResticError.swift` — `ResticExitClass` enum mapping exit codes per restic-cli.md table: `.success`, `.warningIncompleteRead` (3), `.fatal(stderrSummary)` (1/2), `.repoDoesNotExist` (10), `.repoLocked` (11), `.wrongPassword` (12), `.other(Int32)`. Include `userFacingMessage` per error with the "one next step" rule from ui-spec.md.
- Keychain **pre-flight**: before spawning restic, `runner.run(find-generic-password …)` for the destination (and from-destination); on failure throw `ResticRunnerError.keychainUnavailable` — the retryable case in architecture.md's taxonomy. (Engine relies on this; see T09 scenario 9.)

## Constraints
- Cancellation: task cancellation → SIGINT to restic, 10 s grace, SIGKILL (via ProcessRunning timeout machinery; verify restic removes its repo lock on SIGINT — it does; note in code).
- Never log or include env values in errors/logs; argv is loggable (contains no secrets by construction).
- Linux-compilable (no Darwin-only imports).

## Tests
For every builder: exact-argv golden test against restic-cli.md. Env assembly: password command exact string, from-password variant, secret-env injection (fake keychain via FakeProcessRunner scripted `find-generic-password` replies), no inherited env leakage, cache dir set. Exit-mapping table test. NDJSON chunking test (split fixture stream at awkward boundaries → identical messages). Keychain pre-flight failure → `keychainUnavailable`. exit_error line (fixture `locked-error.json`) surfaces `.repoLocked` even when process exit code is 11.

## Acceptance criteria
- [ ] `swift test` green (macOS + Linux).
- [ ] Golden argv tests quote restic-cli.md exactly (reviewer diffs them side-by-side).
- [ ] Documented manual smoke: run `.version` and a real `backup` against a throwaway local repo using the real DefaultProcessRunner + real keychain item.

## Fable review focus
Env assembly (secret handling, replace-not-inherit), cancellation/timeout path, exit-code mapping completeness, the T05 decoder seam.
