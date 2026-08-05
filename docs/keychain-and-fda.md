# Secret storage, Full Disk Access, and SMAppService

Where Restic Station keeps repository passwords on each platform, plus the two macOS integration points where mistakes don't crash — they make **scheduled headless backups silently stop working**. Read this before touching any `SecretStore` backend, `LaunchdManager`, or the onboarding UI.

> **Filename note.** This file is still `keychain-and-fda.md` even though §5 now covers a non-keychain backend. The name is referenced from a dozen source comments, task files and the other docs; renaming it would churn all of them for no reader benefit. The title above is the accurate description; treat the filename as a stable id.

Secret storage sits behind `SecretStore` (`Core/Sources/ResticStationCore/Secrets/`), with two backends:

| Backend | Default on | Storage | Password command |
|---|---|---|---|
| `KeychainSecretStore` | macOS | login keychain via `/usr/bin/security` | `/usr/bin/security find-generic-password -s restic-station -a <uuid> -w` |
| `FileSecretStore` | Linux (and everywhere else) | `<AppPaths.root>/secrets.json`, mode `0600` | `<absolute-helper-path> print-password --dest <uuid>` |

`RESTIC_STATION_SECRET_BACKEND=keychain|file` overrides the platform default; an unrecognised value is a hard error, never a silent fallback. Both backends key on the destination UUID lowercased, and on `"<uuid>-env"` for the secret-env JSON blob, so the two are structurally comparable. §1–§4 below are macOS; §5 is the file backend.

**Every user-facing string about secret storage is chosen by the backend in use, not by the host OS.** `SecretStore.backend` reports which one a store is, and all the wording (`displayName`, `unavailableSummary`, `unavailableAdvice`, `unavailableProbeReason`) lives on `SecretBackend`. This matters because macOS-with-the-file-backend is a supported configuration: telling that user to "unlock your login keychain" when their `secrets.json` mode was widened sends them down the wrong path during an incident. The one exception is `ResticRunnerError.userFacingMessage`, a property on an error value with no store to ask — it uses `SecretBackend.configured`, which reads the same environment every store is built from.

## 1. Keychain: the `security`-CLI ACL strategy

### The trap
Keychain item ACLs are per-code-identity. An item created through the Security framework (`SecItemAdd`) trusts only the creating app's code signature. When restic later runs `RESTIC_PASSWORD_COMMAND` → `/usr/bin/security find-generic-password …` from a headless launchd context, `security` is a *different* code identity → macOS queues a GUI consent prompt that nobody is there to click → the backup hangs/fails. Worse for development: unsigned/ad-hoc dev builds get a new code identity on every rebuild, invalidating `SecItemAdd`-based ACLs constantly.

### The rule
**All keychain reads AND writes go through the `/usr/bin/security` subprocess — never the Security framework — and items are created with `security` itself in the ACL:**

```sh
# create / update (app, when the user enters a password)
/usr/bin/security add-generic-password -U \
    -s restic-station -a <dest-uuid-lowercase> \
    -w <password> -T /usr/bin/security

# read (restic does this itself via RESTIC_PASSWORD_COMMAND; our code uses the same form)
/usr/bin/security find-generic-password -s restic-station -a <uuid> -w

# delete (when a destination is removed)
/usr/bin/security delete-generic-password -s restic-station -a <uuid>
```

`-T /usr/bin/security` places the Apple-signed `security` tool in the item's trusted-application list **at creation time**, so all future reads are prompt-free, from any context, regardless of how the app itself is signed. `-U` updates an existing item's value (note: `-U` does not modify an existing item's ACL — ACLs are fixed at creation; if an item was ever created without `-T`, delete and re-add).

Items (see data-model.md): service `restic-station`, account `<dest-uuid>` (repo password) and `<dest-uuid>-env` (JSON dict of secret env vars, e.g. S3 keys — restic's password-command mechanism can't deliver those, so `ResticRunner` reads the blob itself and injects real env vars).

### Accepted tradeoff (document, don't "fix")
Passing `-w <password>` puts the secret in `security`'s argv, momentarily visible in `ps` on the local machine. Alternatives (interactive `-w` prompt) don't work programmatically. For a single-user local machine this is acceptable; note it in code comments and README.

### Login-time edge case
A `RunAtLoad` tick can fire before the login keychain is unlocked; `find-generic-password` then fails (nonzero exit). This is **retryable** (see architecture.md error taxonomy): the engine must detect "password command failed" (restic exit 1 with keychain-ish stderr, or our own pre-flight `find-generic-password` probe failing) and simply skip the run WITHOUT writing a `.failed` record or updating `lastBackupStart` — the next tick (2 min later, keychain now unlocked) runs normally. Implement as a pre-flight in `BackupEngine.runSet`: read the primary's password via the active `SecretStore` first; on failure → log, exit, no state change. The same pre-flight covers the file backend's equivalent failure (a `secrets.json` whose mode has been widened), which is why `ResticRunnerError` calls the case `secretsUnavailable` rather than naming a backend.

## 2. Full Disk Access (TCC)

**macOS only.** TCC is a macOS mechanism; on Linux there is no equivalent and ordinary file permissions govern access to everything. Everything in this section applies to the macOS build alone.

- Reading `~/Library/Mail`, `~/Library/Safari`, Messages, etc. requires FDA. **There is no prompt and no request API** — the user must add the app in System Settings → Privacy & Security → Full Disk Access. Deep link: `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- **Attribution:** processes launched by launchd are normally self-responsible for TCC. But an SMAppService agent whose plist uses `BundleProgram` runs with the containing app as the responsible bundle — so granting FDA to **Restic Station.app** is expected to cover the embedded helper. This is the designed behavior on macOS 14/15, but it has real-world edge cases (unsigned dev builds, app relocated after registration), so we verify empirically instead of assuming:
- **Verification protocol:** the helper has an `fda-check` subcommand: attempt `FileManager.contentsOfDirectory` on `~/Library/Safari` (fall back to `~/Library/Mail` if Safari dir absent); write `{hasFullDiskAccess, probedPath, checkedAt, context:"launchd"}` to `state/fda-check.json`. The app (a) runs the same probe in-process (`context:"app"`), and (b) triggers a real launchd-context probe via `launchctl kickstart -k gui/<uid>/net.herila.ResticStation.helper` and reads the state file. Onboarding shows BOTH results as separate badges — "App" and "Background agent" — because they can genuinely differ.
- **Troubleshooting fallback (docs + onboarding help text):** if the app has FDA but the launchd probe still reports denied, add the helper binary itself via the "+" button in the FDA pane: `Restic Station.app/Contents/MacOS/restic-station-helper` (⌘⇧G to type the path).
- Sources the user picks via `NSOpenPanel` are readable without FDA only by the app process (powerbox), NOT by the helper — so FDA is effectively required for any real backup of user data. Onboarding must treat FDA as a required step, not optional polish.

### `fda-check` on non-macOS platforms

The `fda-check` subcommand exists on **every** platform, so scripts, docs and the launchd/systemd unit stay uniform. Off macOS it prints "not applicable on this platform" and exits 0 **without writing `state/fda-check.json`**.

Writing a synthetic `{"hasFullDiskAccess": true}` record was rejected deliberately: it would make the file's meaning platform-dependent and put a claim about a privacy mechanism that does not exist into a file other code reads.

### Absent-file semantics (normative)

**An absent `state/fda-check.json` means "not applicable / not yet known" — never "denied".** It is absent in two legitimate situations:

- macOS, before the first `fda-check` has run (a fresh install, up to the first tick).
- Linux, always.

Every reader must honour this:

- `HealthDerivation.fullDiskAccessDenied(from:)` (Core) is the single definition — `nil` → `false`; only an explicit `hasFullDiskAccess == false` is a denial. `AppModel` feeds `appHealth(…)` through it, so an absent file never paints the menu bar icon yellow and never degrades a set's health.
- The Permissions pane reports an absent record as **unknown**, with its own staleness rule (evidence older than an hour is not evidence — FDA is revocable at any time).

## 3. SMAppService

```swift
let service = SMAppService.agent(plistName: "net.herila.ResticStation.helper.plist")
try service.register()          // may throw; check service.status
SMAppService.openSystemSettingsLoginItems()   // when .requiresApproval
service.unregister()
```

- `status` values to handle: `.enabled`, `.requiresApproval` (user must toggle in System Settings → General → Login Items & Extensions), `.notRegistered`, `.notFound` (plist name mismatch or app not in a stable location).
- Registration ties launchd to the **current app path**. Development workflow gotchas (put in README + this doc):
  - Test SMAppService/FDA behavior with the app **copied to /Applications**, not from DerivedData — DerivedData registrations break on every rebuild and confuse TCC attribution.
  - Stale registrations: `sfltool resetbtm` resets the Background Task Management database (then re-register); `launchctl print gui/$UID/net.herila.ResticStation.helper` inspects the live agent.
  - CI never exercises SMAppService (no GUI session); it is covered by the manual checklist in testing.md.
- After config changes that affect scheduling, the app kicks an immediate tick: `launchctl kickstart gui/<uid>/net.herila.ResticStation.helper` (no `-k`; don't kill a running backup). Get uid via `getuid()`.

## Troubleshooting (from T11/T18 implementation evidence)

Findings observed during implementation and review — not speculation:

- **"Background agent" badge shows *unknown*, not denied.** By design the agent badge never trusts stale evidence: it reports *unknown* whenever `state/fda-check.json` is absent, stale, recorded from the wrong context (`"app"` instead of `"launchd"`), or unreadable. A green agent badge therefore always reflects a *recent launchd-context probe*. If it sticks at unknown: confirm the agent is actually registered and running (`launchctl print gui/$UID/net.herila.ResticStation.helper`) — every tick records fresh launchd-context FDA evidence, so with a live agent the badge resolves within one tick (≤2 min) or via the Re-check button.
- **Re-check appears to do nothing.** Re-check uses `launchctl kickstart -k` and is deliberately gated: it will not fire while a backup is running (kickstarting with `-k` would kill it). Wait for the run to finish, or just wait for the next natural tick — it records the same evidence without `-k`.
- **App badge granted, agent badge denied.** Expected edge case with ad-hoc/dev-signed builds or an app moved after registration (TCC attribution). Fallback: add the helper binary itself in the FDA pane — `Restic Station.app/Contents/MacOS/restic-station-helper` (⌘⇧G in the file picker).
- **Badges wrong after moving/rebuilding the app.** SMAppService registration binds to the app path; run from `/Applications` only. Reset with `sfltool resetbtm`, then re-register from onboarding.
- **Keychain prompt appears, or headless backup hangs on password.** The item was created without `security` in its ACL (e.g. by hand or via `SecItemAdd`). `-U` cannot fix an ACL — delete and re-create: `security delete-generic-password -s restic-station -a <uuid>` then re-enter the password in the app.

## 4. Signing & distribution (v1 posture)

Local builds: ad-hoc/dev signing, works for personal use (with the dev-workflow caveats above). CI: `CODE_SIGNING_ALLOWED=NO`, build-only. Distribution to others (later): Developer ID + hardened runtime + notarization — no entitlement exceptions needed (we load no plugins, no JIT); steps live in `docs/release.md` (T20). The app is **not sandboxed** by design: it must spawn `/usr/bin/security`, an arbitrary user-configured restic binary, `launchctl`, and take `flock`s — all incompatible with App Sandbox. Consequence: no Mac App Store; accepted.

## 5. Linux: the `secrets.json` file backend

`FileSecretStore` (`Core/Sources/ResticStationCore/Secrets/FileSecretStore.swift`) is the default everywhere that is not macOS, and is selectable on macOS with `RESTIC_STATION_SECRET_BACKEND=file`.

### Why a plain file, and not a keyring

The target Linux host is headless: no desktop session, no D-Bus user bus, no keyring daemon, no GPG agent, SSH as the only interactive surface. `gnome-keyring`, `kwallet` and `pass` all need at least one of those. A backup agent whose 03:00 scheduled run depends on a daemon that only exists inside a graphical login is a backup agent that silently stops working — the exact failure mode §1 exists to prevent on macOS. A mode-enforced file has no hidden dependency: its security is the Unix file-permission model and nothing else.

### Shape

```json
{
  "version": 1,
  "secrets": {
    "<uuid-lowercased>": "the repository password",
    "<uuid-lowercased>-env": "{\"AWS_ACCESS_KEY_ID\":\"…\"}"
  }
}
```

Deliberately mirrors the keychain account naming (`SecretAccount`), so a destination's storage key is the same string on both platforms and the two backends stay comparable. A `version` newer than this build understands is refused rather than overwritten.

### Threat model

**In scope — what the `0600` file genuinely defends against:**
- another *user account* on the same host reading the passwords;
- a service account (a web server, a CI runner) running as a different uid;
- the file being copied out of a world-readable backup of the host's own filesystem;
- accidental widening (`chmod -R 755 /opt/restic-station`), which is caught on the next read rather than silently tolerated;
- symlink swapping: reads use `O_NOFOLLOW` and `fstat` the opened descriptor, so the mode checked is the mode of the exact file read.

**Explicitly out of scope — say so, don't pretend otherwise:**
- **root.** root reads anything. On a single-admin host this is not a boundary that can exist.
- **the invoking user themselves.** Anyone who can run the helper can run `print-password`. That is the whole point of a non-interactive backup agent: the passwords must be usable without a human.
- **an unencrypted disk.** The file is plaintext at rest. Use full-disk encryption (LUKS) if the physical medium is a concern; a keyring would not have helped here either, since it too must be unlockable unattended.
- **memory scraping / a debugger attached to the process.**

This is a *narrower* guarantee than macOS's, and that is stated rather than papered over: keychain items are encrypted at rest and gated by ACL and by keychain lock state.

### The `0600` rules

- The file is created **at** `0600` via `open(2)`'s mode argument, and the containing directory **at** `0700` via `mkdir(2)`'s. Never create-then-`chmod`: that leaves a window in which the file is world-readable, and a window is all an attacker needs.
- Writes go through a fixed-name temp file created `O_CREAT|O_EXCL|O_WRONLY, 0600` (any stale temp file is unlinked first, because `open(2)` ignores `mode` for an existing file), `fsync`ed, then `rename(2)`d over the real file — the same atomic pattern as `ConfigStore.save(_:)`. A crash can never truncate `secrets.json`; the worst case is a leftover temp file that the next write removes.
- **Every read re-verifies the mode** and refuses, naming the file and the exact `chmod` to run, if any group or other permission bit is set. Silently reading a leaked secret file is worse than failing: the failure is retryable and visible, the silent read is neither. `0400` is accepted — the rule is "no group/other bits", not "exactly `0600`".
- An **existing** `AppPaths.root` is left at whatever mode it has. It holds non-secret state too (`config.json`, `runs/`, `state/`) and may legitimately have been created `0755` by `AppPaths.ensureDirectories()`; the `0600` *file* is what protects the secrets. The `0700` directory is defence in depth for the case where the secret store gets there first.

### Concurrency

A tick and an interactive `secret set` can run at the same time. Every read-modify-write takes `locks/secrets.lock` (the existing `FileLock`, `flock(2)`, released by the kernel on process death) with a 10 s timeout, so a concurrent `secret set` cannot lose the other writer's entry. Reads take **no** lock: `rename(2)` is atomic, so a reader always sees one complete generation of the file.

### How the password reaches restic

Same seam as macOS — `RESTIC_PASSWORD_COMMAND` / `RESTIC_FROM_PASSWORD_COMMAND`, deliberately *not* a plain `RESTIC_PASSWORD` env var (restic's support for a `RESTIC_FROM_PASSWORD` non-`_COMMAND` variant is not something to assume, and the command seam is already proven here). The command is `<absolute-helper-path> print-password --dest <uuid>`; restic runs it as a child and reads the password off its stdout, with no trailing newline.

**Which binary goes in that command is the caller's decision, not a default.** `SecretStoreFactory.make(paths:runner:helperExecutablePath:environment:)` requires the path, because "this executable" is right only inside the helper. The app process builds a store too — restore browsing, `mount`, primary `init` — and a default there would name the SwiftUI app binary, handing restic a child that cannot print a password and might try to open a UI. So:

- the **helper** passes `FileSecretStore.currentExecutablePath()`, which reads `/proc/self/exe` on Linux (the kernel's answer, correct even when invoked through a symlink or a `PATH` lookup) and `_NSGetExecutablePath` + `realpath` on Darwin. **Never** `CommandLine.arguments[0]`, which is attacker-controlled and would be a straightforward code-execution hole in a string restic is about to execute; and never `Bundle.main.executablePath`, which for a tool inside an `.app` bundle's `Contents/MacOS/` names the *app*.
- the **app** passes `HelperInvoker.helperURL.path` — the embedded `restic-station-helper`, the same binary the LaunchAgent's `BundleProgram` points at.

Because `ResticRunner` *replaces* restic's environment, that child would otherwise resolve the default data directory with the platform-default backend. `FileSecretStore.passwordCommandEnvironment` therefore contributes `RESTIC_STATION_DATA_DIR` and `RESTIC_STATION_SECRET_BACKEND=file` to the assembled environment (the keychain backend contributes nothing, which is why macOS's environment is byte-identical to what it was before this abstraction existed).

### No secret in argv — the one place the two backends differ on purpose

macOS's documented, accepted tradeoff is that `security -w <value>` briefly exposes a secret in the process list (§1). That is forced by `security(1)` having no non-interactive alternative. **The file backend has no such constraint and does not reproduce it.** On this path a secret never appears in argv, in a log line, in a run record, or in an error message:

- `secret set` and `secret set-env` read from **stdin** (echo-disabled prompt on a TTY, raw on a pipe, exactly one trailing newline stripped).
- `print-password` writes to stdout; the value is never an argument.
- `secret list` prints destination ids, labels and *counts* — its renderer is never handed a secret value at all.
- `SecretStoreError.backendFailed` may only carry a backend's own diagnostic text (a path, an errno, a JSON key path) — never a value. `ResticRunnerError.secretsUnavailable` carries only a destination id.

`scripts/secret-cli-test.sh` asserts all of this against the real binary, including a `grep -r` of the whole data directory for the password after a real backup run.

### Managing secrets from a terminal

There is no GUI on the Linux host, so the helper is the entry point:

```sh
# store a password (prompts with echo off on a TTY)
restic-station-helper secret set --dest <uuid>
# …or from a password manager, with no secret in argv or shell history
pass show backups/primary | restic-station-helper secret set --dest <uuid>

# S3-style credentials, as a JSON object of strings
printf '%s' '{"AWS_ACCESS_KEY_ID":"…","AWS_SECRET_ACCESS_KEY":"…"}' \
    | restic-station-helper secret set-env --dest <uuid>

# what is stored (never what it is)
restic-station-helper secret list

# remove (idempotent; --env targets the secret env instead of the password)
restic-station-helper secret rm --dest <uuid>
restic-station-helper secret rm --dest <uuid> --env
```

Exit codes follow the helper contract (`docs/tasks/T10-helper-cli.md`): 0 ok, 1 error. An unknown destination UUID is exit 1. `print-password` exists only for `RESTIC_PASSWORD_COMMAND` and is hidden from `--help`.

### Troubleshooting

- **"refusing to read …/secrets.json: it is group- or world-accessible".** Exactly what it says; run the `chmod 600` the message prints. Then consider *why* it was widened — if something recursively chmod'ed the data directory, other state files were widened too.
- **restic reports "Resolving password failed" on Linux.** The password command is `<helper> print-password --dest <uuid>`. Run it by hand with the same `RESTIC_STATION_DATA_DIR`/`RESTIC_STATION_SECRET_BACKEND` the agent uses; if it exits 1 with "no stored password", the destination has no password stored (`secret set` it), and if it exits 1 with a permissions message, see above.
- **A backup that worked from a shell fails from the timer/agent.** Check that the unit's environment carries the same `RESTIC_STATION_DATA_DIR` the interactive shell had, if you set one at all — the helper resolves the store from its own environment on both sides.
- **`RESTIC_STATION_SECRET_BACKEND=keychain` on Linux.** Hard error, by design: `/usr/bin/security` does not exist there, and a backend that can only fail is worse than no backend.
