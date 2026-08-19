# The `--json` error envelope

**Normative.** The contract in this document is what automated callers of
`restic-station-helper` are entitled to rely on. Implemented by
`Core/Sources/ResticStationCore/Support/CLIError.swift` (classification) and
`Helper/Sources/HelperOutput.swift` (rendering); pinned by
`Core/Tests/…/Support/CLIErrorTests.swift`,
`Helper/Tests/HelperTests/CLIErrorEnvelopeTests.swift`, and
`scripts/headless-cli-test.sh` §8.

## Why it exists

Exit codes are deliberately coarse — `0` ok, `1` error, `2` busy, `3` offline
(`HelperExitCode`). That is the right shape for `&&` in a shell and useless for
an agent that must distinguish "this set does not exist" from "the repository
is locked" from "the password could not be read".

Rather than allocate a new exit code per failure — which would break every
existing caller — the precise classification moves into the JSON payload and
**the exit code stays exactly what it always was**.

## The envelope

On a handled failure in `--json` mode, stdout contains exactly one document:

```json
{
  "schemaVersion": 1,
  "ok": false,
  "error": {
    "code": "repository_locked",
    "message": "The repository is locked by another operation. If no other backup is running, remove stale locks in Maintenance and try again.",
    "retryable": true,
    "details": { "destinationId": "0a1b2c3d-4e5f-4a1b-8c1d-000000000001", "resticExitCode": 11 }
  }
}
```

`code`, `retryable`, `schemaVersion` and the documented `details` keys are the
stable contract. **`message` is presentation text and may change at any time** —
never match on it. `details` is omitted entirely when empty.

## Codes

| `code` | `retryable` | exit | Meaning |
|---|---|---|---|
| `invalid_arguments` | no | 64 / 1 | Arguments missing, malformed, or out of range. See §Argument-parser failures for the two exit codes. |
| `config_invalid` | no | 1 | A configuration file on this host will not load — `config.json` undecodable, failing `validate()`, or written by a newer build; or `machine.json` unreadable. `message` names which. |
| `set_not_found` | no | 1 | No backup set with that id. |
| `set_disabled_here` | no | 1 | The set exists in the shared config but is switched off for this machine. |
| `destination_not_found` | no | 1 | No such destination in that set. |
| `destination_disabled_here` | no | 1 | The destination is switched off for this machine. |
| `run_not_found` | no | 1 | No run record with that id. |
| `set_busy` | **yes** | **2** | Another operation holds this set's lock. |
| `repository_offline` | **yes** | **3** | The destination did not answer — an unplugged drive, a sleeping NAS. Expected, not a fault. |
| `repository_locked` | **yes** | 1 | restic exit 11: another restic process holds the repository lock. |
| `repository_not_initialized` | no | 1 | restic exit 10: nothing is initialized at that location. |
| `secret_unavailable` | **yes** | 1 | The password or secret env could not be **read** — a locked login keychain, a `secrets.json` whose mode was widened. |
| `secret_rejected` | no | 1 | restic exit 12: the secret was read fine and restic refused it. |
| `restic_not_found` | no | 1 | No restic binary anywhere that was searched. |
| `restic_unsupported` | no | 1 | A restic was found and ran, but is below the minimum or is not restic. |
| `restic_failed` | no | 1 | restic ran and failed. |
| `operation_not_allowed` | no | 1 | Refused by a safety invariant — `forget` with an empty retention policy, `prune` on a mirror behind its primary (`architecture.md` §Invariants). |
| `internal_error` | no | 1 | An unexpected failure. Bounded; never a serialized object description. |

### `retryable`

Means precisely: **the identical request could succeed later with nobody
changing anything.** It is advice for a backoff loop, not a judgement about
severity.

This is why `secret_rejected` is split from `secret_unavailable`. A locked
keychain is worth retrying unchanged; a wrong password will fail identically
forever until a human replaces it. Collapsing them — as the original issue's
taxonomy did — would force one `retryable` value that is wrong for one of them.

### `details`

Every field is an id, a small integer, or a closed enum value:

| Key | Type | Set when |
|---|---|---|
| `setId` | UUID string | The failure is about one backup set. |
| `destinationId` | UUID string | The failure is about one destination. |
| `runId` | string | The failure is about one run record. |
| `machineId` | string | A per-machine resolution decided the outcome. |
| `resticExitCode` | integer | restic ran and returned it. |
| `resticCategory` | `success` \| `warning` \| `terminal` \| `retryable` | Alongside a restic failure. |
| `versionFound` / `versionSupported` | string | A version mismatch — schema or restic binary. |
| `diagnosticReference` | string | A run id or log path worth fetching, when safe. |

## Redaction

`CLIErrorDetails` is a **fixed struct, not a dictionary**, and that *is* the
redaction policy: there is nowhere to put a repository URL, a source path, a
password, a secret environment value, raw keychain output, a subprocess
environment, or an unbounded restic stderr blob. The rule is enforced by the
shape of the type rather than by every call site remembering it.

`message` is capped at 500 characters (`CLIFailure.messageCharacterLimit`),
matching `ResticExitClass.summarize`. The cap is not cosmetic: before it, an
unloadable `config.json` printed the whole `DecodingError` description,
including the `NSDebugDescription` that quotes the offending bytes.

Where a path is genuinely useful to a human — `machine.json`'s location, a log
file — it stays in `message` and is kept out of `details`, which is the half of
the envelope that promises to be safe to log.

## Argument-parser failures

A failure to *parse* the command line happens before any command's `run()`, so
no command can report it. `HelperMain.main()` is hand-written for this reason:
it reproduces the one `AsyncParsableCommand` synthesizes and adds the two catch
clauses. Everything it does not own is handed back to `exit(withError:)`, which
is what still prints usage text and exits `--help` cleanly.

Two consequences, both deliberate:

- **`invalid_arguments` can exit `64` or `1`.** A parser failure keeps
  ArgumentParser's `EX_USAGE` (64); a command that validates its own arguments
  (`runs list --limit 0`) exits 1, as it always has. The envelope exists to
  *describe* the exit contract, not to redefine it, so both output modes always
  agree on the code.
- **The mode is guessed, and only here.** With no parsed command there is
  nothing to ask, so argv is scanned for `--json` (ignoring `argv[0]` and
  anything after a `--` separator). A value that is literally `--json` before
  the separator would be counted, and a command with no `--json` flag still
  gets an envelope for its usage error. Both are accepted: the alternative is
  the silent stdout this contract exists to remove, and a caller who typed
  `--json` has already said which shape it can parse. Everywhere else the
  **parsed command** is the authority.

## What is *not* an error

**A nonzero exit is not the same as a failure.** `status --json` exits 1 when
health is `warning` — it is documented as a Nagios/Icinga check. That is a
successful report with a nonzero exit and still emits a `StatusReport`, never an
envelope. Callers should branch on the presence of `error`/`ok`, not on the exit
code alone.

`--help` is a clean exit in every mode.

## Coverage today

`status`, `sets list`, `runs list`, `runs show`, and `config show`. The
remaining commands are human-only and still write prose to stderr; #79 converts
them as it gives them their own `--json`. That boundary is stated here rather
than papered over.

Two codes have no producer yet — `repository_offline` (#79 wires the
reachability probe) and `operation_not_allowed` (the engine invariants refuse
before throwing). They are defined because the mapping is settled, and their
absence is asserted, not assumed.

## Versioning

`schemaVersion` is bumped only for a **breaking change to the envelope's
shape**.

**Adding a `code`, or adding a `details` key, is additive and does not bump
it.** Clients must treat an unrecognised `code` as a failure of unknown class
and must ignore unknown fields — that is what lets #82/#88 add the `preview_*`
family without a version break.

### Codes deliberately absent

From the taxonomy issue #81 proposed, four are not defined, because defining a
code nothing can emit invites callers to branch on a case that will never
arrive:

- **`config_missing`** — a missing `config.json` is not an error.
  `ConfigStore.load()` returns an empty `AppConfig`.
- **`preview_required` / `preview_expired` / `preview_stale` /
  `preview_already_used`** — the preview-token mechanism lands with #82/#88;
  the codes land with it.
- **`cloud_repository_not_hydrated`** — no detector exists. Inferring it would
  mean matching restic's English stderr, which is exactly the practice this
  contract exists to stop.

Two codes not in that list are defined: `secret_rejected` (see §`retryable`)
and `run_not_found` (`runs show <unknown-id>` is a real failure of a `--json`
command and had no code at all).
