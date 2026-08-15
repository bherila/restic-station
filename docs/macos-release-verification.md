# macOS release verification

The manually triggered **macOS Release Verification** workflow is the
canonical clean-machine evidence run for a macOS build. In GitHub, open
**Actions → macOS Release Verification → Run workflow** and choose the branch
or tag to verify. It runs on the standard GitHub-hosted `macos-15` image.

The workflow builds a Release app, ad-hoc signs it, copies that exact bundle to
`/Applications`, and then verifies:

- app and Core unit tests;
- the shipped bundle, helper, LaunchAgent plist, version, and strict nested
  code-signature validity;
- an eight-second launch smoke test against isolated app data;
- `cli install --user`, the exact symlink destination, direct-versus-symlink
  helper identity, and equivalent FDA probe results in both invocation paths;
- a real disposable restic backup and restore, including the macOS Keychain
  path used by the integration suite;
- file-backed secret handling and the exhaustive headless
  config/status/sets/runs fixture matrix. The matrix uses the Debug helper
  produced by the same run; the exact installed Release helper separately
  exercises config import/validate/status and real backup/mirror/restore in
  the integration suite.

Every run retains the verified app for 14 days and the check results, probe
JSON, signing metadata, and integration logs for 30 days. The same evidence is
summarized on the workflow run page.

## Deliberate boundary

A hosted runner is an ephemeral VM with no durable, human-approved privacy or
login state. It therefore cannot establish any of the following:

- a user granting Full Disk Access in System Settings;
- a user approving the `SMAppService` background item;
- behavior across sleep/wake or logout/reboot;
- catch-up of a run missed while the Mac was powered off.

Those remain manual checks on a persistent Mac. The workflow records this
boundary in every run rather than treating an unapproved runner as evidence of
either approval or denial.

The bundle-only verifier is also available as
`scripts/macos-release-verification.sh`. Its CLI-install mode is intentionally
restricted to GitHub Actions so invoking it locally cannot silently change a
developer's `~/.local/bin/restic-station` entry.
