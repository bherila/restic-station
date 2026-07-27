# Keychain, Full Disk Access, and SMAppService

The three macOS integration points where mistakes don't crash — they make **scheduled headless backups silently stop working**. Read this before touching `KeychainClient`, `LaunchdManager`, or the onboarding UI.

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
A `RunAtLoad` tick can fire before the login keychain is unlocked; `find-generic-password` then fails (nonzero exit). This is **retryable** (see architecture.md error taxonomy): the engine must detect "password command failed" (restic exit 1 with keychain-ish stderr, or our own pre-flight `find-generic-password` probe failing) and simply skip the run WITHOUT writing a `.failed` record or updating `lastBackupStart` — the next tick (2 min later, keychain now unlocked) runs normally. Implement as a pre-flight in `BackupEngine.runSet`: read the primary's password via `KeychainClient` first; on failure → log, exit, no state change.

## 2. Full Disk Access (TCC)

- Reading `~/Library/Mail`, `~/Library/Safari`, Messages, etc. requires FDA. **There is no prompt and no request API** — the user must add the app in System Settings → Privacy & Security → Full Disk Access. Deep link: `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- **Attribution:** processes launched by launchd are normally self-responsible for TCC. But an SMAppService agent whose plist uses `BundleProgram` runs with the containing app as the responsible bundle — so granting FDA to **Restic Station.app** is expected to cover the embedded helper. This is the designed behavior on macOS 14/15, but it has real-world edge cases (unsigned dev builds, app relocated after registration), so we verify empirically instead of assuming:
- **Verification protocol:** the helper has an `fda-check` subcommand: attempt `FileManager.contentsOfDirectory` on `~/Library/Safari` (fall back to `~/Library/Mail` if Safari dir absent); write `{hasFullDiskAccess, probedPath, checkedAt, context:"launchd"}` to `state/fda-check.json`. The app (a) runs the same probe in-process (`context:"app"`), and (b) triggers a real launchd-context probe via `launchctl kickstart -k gui/<uid>/net.herila.ResticStation.helper` and reads the state file. Onboarding shows BOTH results as separate badges — "App" and "Background agent" — because they can genuinely differ.
- **Troubleshooting fallback (docs + onboarding help text):** if the app has FDA but the launchd probe still reports denied, add the helper binary itself via the "+" button in the FDA pane: `Restic Station.app/Contents/MacOS/restic-station-helper` (⌘⇧G to type the path).
- Sources the user picks via `NSOpenPanel` are readable without FDA only by the app process (powerbox), NOT by the helper — so FDA is effectively required for any real backup of user data. Onboarding must treat FDA as a required step, not optional polish.

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

## 4. Signing & distribution (v1 posture)

Local builds: ad-hoc/dev signing, works for personal use (with the dev-workflow caveats above). CI: `CODE_SIGNING_ALLOWED=NO`, build-only. Distribution to others (later): Developer ID + hardened runtime + notarization — no entitlement exceptions needed (we load no plugins, no JIT); steps live in `docs/release.md` (T20). The app is **not sandboxed** by design: it must spawn `/usr/bin/security`, an arbitrary user-configured restic binary, `launchctl`, and take `flock`s — all incompatible with App Sandbox. Consequence: no Mac App Store; accepted.
