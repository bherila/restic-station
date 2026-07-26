# T03 — KeychainClient (security-CLI backend) + ProcessRunning protocol

**Size:** S · **Model:** Sonnet · **Review:** Fable (label `fable-review`) · **Depends on:** T01 · **Milestone:** M1

## Goal
Keychain access exactly per `docs/keychain-and-fda.md` §1 — all I/O via `/usr/bin/security` subprocess, items created with `-T /usr/bin/security`. Also introduces the `ProcessRunning` protocol used by the whole codebase.

## Create
- `Core/Sources/ResticStationCore/Support/ProcessRunning.swift` — protocol + `ProcessResult` + `ProcessRunnerError` exactly as in `docs/architecture.md` §DI, plus `DefaultProcessRunner`: `Process` + `Pipe`s, streams stdout/stderr line-by-line to the callbacks (buffer partial lines; flush remainder at EOF), replaces environment when `env != nil`, timeout via structured-concurrency race → SIGINT → 10 s → SIGKILL. Linux-compatible (`Process` works; signals via `kill(2)`).
- `Core/Sources/ResticStationCore/Secrets/KeychainClient.swift`:
  ```swift
  public struct KeychainClient {
      public init(runner: ProcessRunning)
      public func setPassword(_ pw: String, destId: UUID) async throws
      public func password(destId: UUID) async throws -> String
      public func deletePassword(destId: UUID) async throws
      public func setSecretEnv(_ env: [String: String], destId: UUID) async throws  // account "<uuid>-env", value = JSON
      public func secretEnv(destId: UUID) async throws -> [String: String]          // missing item → [:]
      public func deleteSecretEnv(destId: UUID) async throws
      public static func passwordCommand(destId: UUID) -> String
      // = "/usr/bin/security find-generic-password -s restic-station -a <uuid-lowercased> -w"
  }
  ```
  argv per keychain-and-fda.md: add uses `add-generic-password -U -s restic-station -a <acct> -w <value> -T /usr/bin/security`. Because `-U` cannot fix a missing ACL, `set*` must **delete-then-add** when the item already exists without our ACL — simplest correct approach: always `delete-generic-password` (ignore not-found exit 44) then `add` WITHOUT `-U`. Read: `find-generic-password … -w`, trim trailing newline. Distinguish errors: exit 44 = not found → typed `KeychainError.itemNotFound`; other nonzero → `.securityCommandFailed(stderr)`. Account strings are `uuidString.lowercased()`.
- `#if os(macOS)` is NOT needed — the type only builds argv; tests run on Linux with the fake.

## Tests
FakeProcessRunner (create it in this task under `Core/Tests/…/Support/FakeProcessRunner.swift` per `docs/testing.md` — later tasks reuse it): assert exact argv for set (delete+add sequence, `-T /usr/bin/security` present), get (trailing-newline trim), delete-not-found tolerated, env blob JSON round-trip, `passwordCommand` exact string match. DefaultProcessRunner smoke test (`/bin/echo hi`, line callback) gated `#if os(macOS)` OR portable (`echo` exists on Linux — keep portable).

## Acceptance criteria
- [ ] `swift test` green (macOS + Linux container).
- [ ] `passwordCommand` output matches restic-cli.md's documented string byte-for-byte.
- [ ] Manual smoke (documented in the PR, run locally, not CI): `RESTIC_STATION_KEYCHAIN_SMOKE=1 swift test --filter KeychainSmoke` adds/reads/deletes a real item named with service `restic-station-test` and confirms `security find-generic-password` (as a bare subprocess) reads it without any GUI prompt.

## Fable review focus
ACL correctness (delete-then-add, `-T` on every create path), no path where a secret lands in a file or log, account-string stability.
