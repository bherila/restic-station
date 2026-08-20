# The `--json` contract

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

## The two envelopes

Every `--json` command emits exactly one document with the same three
top-level keys. `ok` is the only discriminator a caller needs — it never has
to probe for the presence of a key, and never has to know which command it
called to know the shape.

```json
{ "schemaVersion": 1, "ok": true,  "data":  { … } }
{ "schemaVersion": 1, "ok": false, "error": { … } }
```

`schemaVersion` covers both branches: they are one contract, and a caller
that has pinned `1` has pinned both.

The wrapping happens in one place (`CLIJSON.print`), which is what stops it
from being something each command has to remember. `config export` is the
single deliberate exception — it emits the exported `config.json` document
itself, unwrapped, because its output is meant to be fed straight back into
`config import`.

## Command matrix

| Command | `--json` | Payload (`data`) |
|---|---|---|
| `version` | ✅ | `{ name, version, platform }` |
| `status` | ✅ | `StatusReport` — see `data-model.md` §`status --json` |
| `sets list` | ✅ | array of set entries — `data-model.md` §`sets list --json` |
| `runs list` | ✅ | array of `RunIndexEntry` |
| `runs show <id>` | ✅ | `RunMetadata` |
| `config show` | ✅ | effective-config report |
| `config validate` | ✅ | `{ machineId, errors, warnings, effective, nothingRunsHere }` |
| `probe-repo` | ✅ | `{ setId, destinationId, label, outcome, reachable, reason }` |
| `secret list` | ✅ | array of `{ destId, label, setName, hasPassword, secretEnvCount }` — only destinations that have something stored, the same set human mode prints |
| `cli status` | ✅ | `CLIInstaller.Status` |
| `fda-check` | ✅ | `{ applicable, granted, probedPath, checkedAt, context }` |
| `purge preview` | ✅ | array of per-destination purge plans: matched/changed/unattributed snapshots and patterns |
| `purge apply` | ✅ | `{ setId, status, children }` for the token-gated destructive purge |
| `config export` | — | **Unwrapped by design.** The exported config document itself, so it round-trips into `config import`. |
| `timer status` (Linux) | — | **Human-only.** Its report is narrative assembled while probing; the machine-readable equivalent is `status --json`'s `.scheduler`, in the same problem vocabulary. |
| `print-password` | — | Hidden; exists for `RESTIC_PASSWORD_COMMAND` and writes a secret to stdout. |
| `tick`, `run-set`, `restore`, `init-secondary`, `unlock`, `config import`, `secret set`/`set-env`/`rm`, `cli install`/`uninstall`, `timer install`/`uninstall` | — | Mutating, not inspection. Progress is a human/log concern; the machine-readable record of what happened is the run record (`runs show --json`). |

Two payload notes that are easy to get wrong:

- **`probe-repo` reports offline as a success.** `outcome: "offline"` with
  `ok: true` and exit 3. An unplugged drive is a destination's expected
  state, not a fault — an error envelope would make a sleeping NAS
  indistinguishable from a broken config. Branch on `outcome`.
- **`fda-check` has three states, not two.** Off macOS, `applicable` is
  `false` and `granted` is `null`. A caller must check `applicable` before
  reading `granted`, exactly as an absent `state/fda-check.json` means
  *unknown* rather than *denied*.

## The error branch

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
| `config_invalid` | no | 1 | A configuration file on this host will not load — `config.json` undecodable, failing `validate()`, or written by a newer build; `machine.json` unreadable; or `RESTIC_STATION_SECRET_BACKEND` naming a backend that does not exist. `message` names which. |
| `set_not_found` | no | 1 | No backup set with that id. |
| `set_disabled_here` | no | 1 | The set exists in the shared config but is switched off for this machine. |
| `destination_not_found` | no | 1 | No such destination in that set. |
| `destination_disabled_here` | no | 1 | The destination is switched off for this machine. |
| `run_not_found` | no | 1 | No run record with that id. |
| `set_busy` | **yes** | **2** | Another operation holds this set's lock. |
| `repository_offline` | **yes** | **3** | The destination did not answer — an unplugged drive, a sleeping NAS. Expected, not a fault. |
| `repository_locked` | **yes** | 1 | restic exit 11: another restic process holds the repository lock. |
| `repository_not_initialized` | no | 1 | restic exit 10: nothing is initialized at that location. |
| `secret_unavailable` | **yes** | 1 | The secret backend answered badly and may answer well later — a locked login keychain, a transient I/O error. **Also currently reported for the file backend's permanent refusals** (a group-accessible or symlinked `secrets.json`, an untrusted owner, malformed contents), which retrying cannot fix — see #96. |
| `secret_not_configured` | no | 1 | The backend answered "no such item": no password is stored for this destination. Run `secret set`. Also what `ResticRunner`'s pre-flight reports, so the distinction survives to the commands that actually run restic. |
| `secret_rejected` | no | 1 | restic exit 12: the secret was read fine and restic refused it. |
| `restic_not_found` | no | 1 | No restic binary anywhere that was searched. |
| `restic_unsupported` | no | 1 | A restic was found and ran, but is below the minimum or is not restic. |
| `restic_failed` | no | 1 | restic ran and failed. |
| `operation_timed_out` | **yes** | 1 | The operation exceeded the caller's timeout and was stopped; restic never reported. A stalled network or a spinning-up remote clears on its own. |
| `preview_expired` | no | 1 | A destructive preview token has expired. Run a fresh preview; the old token can never be applied. |
| `operation_not_allowed` | no | 1 | Refused by a safety invariant — `forget` with an empty retention policy, `prune` on a mirror behind its primary (`architecture.md` §Invariants). |
| `internal_error` | no | 1 | An unexpected failure. Bounded; never a serialized object description. |

### `retryable`

Means precisely: **the identical request could succeed later with nobody
changing anything.** It is advice for a backoff loop, not a judgement about
severity.

This is why `secret_rejected` and `secret_not_configured` are split from
`secret_unavailable`. A locked keychain is worth retrying unchanged; a wrong
password will fail identically forever until a human replaces it, and a
destination with no password stored stays that way until someone runs
`secret set`. Collapsing them — as the original issue's taxonomy did — would
force one `retryable` value that is wrong for two of the three.

The split is by **condition, not by backend**: `SecretStoreError.itemNotFound`
is what the macOS keychain backend reports for `security`'s exit 44 and what
the Linux file backend reports for a missing key, so #81's requirement that the
two backends be indistinguishable to a caller still holds.

### `details`

Every field is an id, a small integer, or a closed enum value:

| Key | Type | Set when |
|---|---|---|
| `setId` | UUID string | The failure is about one backup set. |
| `destinationId` | UUID string | The failure is about one destination. |
| `runId` | string | The failure is about one run record. |
| `machineId` | string | A per-machine resolution decided the outcome. |
| `resticExitCode` | integer | restic ran and returned it. |
| `resticCategory` | `success` \| `warning` \| `terminal` \| `retryable` | Alongside a restic failure whose run-record category and `retryable` agree. Omitted for `operation_timed_out`, where they do not: the operation did not complete (a `.failed` record is written) *and* repeating it can succeed. |
| `versionFound` / `versionSupported` | string | A version mismatch — schema or restic binary. Reduced to a dotted numeric triple; see §Redaction. |
| `diagnosticReference` | string | A run id or log path worth fetching, when safe. |

## Redaction

`CLIErrorDetails` is a **fixed struct, not a dictionary**, and that *is* the
redaction policy: there is nowhere to put a repository URL, a source path, a
password, a secret environment value, raw keychain output, a subprocess
environment, or an unbounded restic stderr blob. The rule is enforced by the
shape of the type rather than by every call site remembering it.

The fixed key set bounds *what* can appear, not *how much*: `machineId` comes
from `config.json`, where `MachineIdentity` imposes no length limit. So every
free-form value is additionally capped at 128 characters
(`CLIErrorDetails.valueCharacterLimit`), applied when the envelope is
encoded rather than when the value is set — the fields are mutable, and a cap
on the way in can be undone on the way past. A truncated value keeps a
trailing `…` so it reads as truncated rather than as a different id.

`message` is capped at 500 characters (`CLIFailure.messageCharacterLimit`),
ellipsis included — a truncated message is exactly 500, never 501 —
matching `ResticExitClass.summarize`. The cap is not cosmetic: before it, an
unloadable `config.json` printed the whole `DecodingError` description,
including the `NSDebugDescription` that quotes the offending bytes.

`versionFound` is the one `details` value that originates outside this
process: a binary on PATH answers `version` with a JSON object, and
`VersionInfo` accepts any string there because its comparison ignores what it
cannot read. It is therefore published as the dotted numeric triple the
comparison actually used (`CLIFailure.boundedVersion`), never verbatim — the
raw text still reaches a human through `message`, which is capped. This keeps
`details` bounded by construction rather than by trusting what was probed.

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

Eleven commands, listed in the matrix above. The mutating commands remain
human-only and still write prose to stderr — the boundary is stated in the
matrix rather than papered over.

Two codes have no producer yet — `repository_offline` (#79 wires the
reachability probe) and `operation_not_allowed` (the engine invariants refuse
before throwing). They are defined because the mapping is settled, and their
absence is asserted, not assumed.

## Migrating from the unwrapped shape

Before this contract, the five commands that had `--json` emitted their
payload bare: `status --json` was the `StatusReport` object itself, and
`sets list --json` was a bare array. Every one of them is now wrapped.

The migration is mechanical — prefix the path:

```console
# before
$ restic-station-helper status --json | jq -r '.health'
$ restic-station-helper sets list --json | jq 'length'

# after
$ restic-station-helper status --json | jq -r '.data.health'
$ restic-station-helper sets list --json | jq '.data | length'
```

This was a deliberate break rather than an additive `schemaVersion` key.
Two shapes coexisting — some commands wrapped, some bare, arrays unable to
carry a version at all — would have been permanent, and the alternative cost
is one `.data` in each caller while the tool is pre-1.0.

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
- **`preview_required` / `preview_stale` / `preview_already_used`** — these
  may be useful for a future preview-token operation, but no current path
  produces them. `preview_expired` is defined above because purge does.
- **`cloud_repository_not_hydrated`** — no detector exists. Inferring it would
  mean matching restic's English stderr, which is exactly the practice this
  contract exists to stop.

Three codes not in that list are defined: `secret_rejected` and
`secret_not_configured` (see §`retryable`) and `run_not_found`
(`runs show <unknown-id>` is a real failure of a `--json` command and had no
code at all).
