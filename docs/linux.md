# Linux (headless)

This is the end-to-end guide for running Restic Station on Linux, from an empty machine to a
scheduled, verified backup. It is written for the milestone this document exists to close out:
author a backup config in the macOS GUI, move it to a headless Linux box (a NAS, a VPS, a home
server), and have it keep backing up unattended, with no further hand-holding.

**What Linux is, and is not.** There is no GUI. `restic-station-helper` — the same `Core`
package, the same backup engine, the same restic repositories the Mac app uses — is the entire
product: a single statically-linked binary with a CLI. A Linux host can be a **backup source**
(it has its own directories to back up), a **mirror/restore target** (it stores copies made
elsewhere and can restore from them, but has nothing local to back up), or both — see
[Per-machine setup](#per-machine-setup) below. Everything under `App/` (the SwiftUI app) is
macOS-only and irrelevant here; see `docs/architecture.md`'s components table.

Every transcript in this document is real output from a real run. It comes from
`scripts/linux-docs-transcript.sh`, which CI's `linux-integration` job
(`.github/workflows/ci.yml`) runs against the **static** release binary and a real restic 0.18.1,
on a genuine (non-container) Ubuntu VM — the same job that runs `scripts/integration-test.sh`'s
Linux fixture-import scenario. Nothing below was typed by hand on a Mac and relabeled, and where
something could not be run in CI that is stated explicitly rather than shown as if observed (see
[Scheduling](#scheduling) and [Not executed in CI](#not-executed-in-ci)).

Two honest caveats about how that output is *presented*, so this claim can be taken literally:

- Transcripts are lightly trimmed for readability — unrelated runner noise (e.g. `Failed to set
  thread priority … errno=13` from the CI sandbox) is dropped, long temp paths are normalised to
  `/tmp/tmp.XXXXXXXXXX`, and a banner or two is condensed. Nothing that reflects the tool's own
  behaviour — commands, results, exit codes, warnings, errors — is altered or omitted.
- The **JSON config blocks** in [Per-machine setup](#per-machine-setup) are illustrations, not
  transcripts, and are abridged where marked. Their `config validate` *output* is real; the JSON
  itself is not copy-pasteable. That section says so where it matters.

## Prerequisites

- **A restic binary, 0.17.0 or newer (0.18+ recommended), on `PATH` or at an explicit
  `resticPath`.** This is the single most common first-run failure, so it is stated again here,
  prominently, not just in `packaging/linux/README.md`: **your distro's package is almost
  certainly too old.** Ubuntu 24.04 LTS ships restic **0.16.4**; Debian stable is comparable.
  `apt install restic` gets you a restic this tool refuses to use. It will tell you so in those
  words — *"restic 0.16.4 at /usr/bin/restic is too old"* — rather than the flatly misleading
  "restic not found" it used to report right after you watched a package manager install one
  ([issue #50](https://github.com/bherila/restic-station/issues/50)). `docs/restic-cli.md`
  §version explains why 0.17.0 is the floor (the first release with the exit-code contract this
  tool relies on).

  Install the official release binary instead:

  ```sh
  curl -fsSL -o restic.bz2 \
    https://github.com/restic/restic/releases/download/v0.18.1/restic_0.18.1_linux_amd64.bz2
  bunzip2 restic.bz2 && sudo install -m 0755 restic /usr/local/bin/restic
  ```

  (`arm64` in place of `amd64` on aarch64.) Verify with `restic version`. If you must use an
  older restic deliberately, setting `resticPath` explicitly in `config.json` bypasses the
  version gate — an explicit path skips discovery's version check entirely — but you are then
  outside what this project tests against.
- x86_64 or aarch64. No particular glibc version, and no Swift runtime, ICU, or any other shared
  library: the release binary is fully static (`docs/testing.md` §"Static Linux binary +
  packaging", verified to run unmodified in a `scratch` container, on Alpine, on Debian, and on a
  deliberately old-glibc distro).
- `systemd --user` for the built-in scheduler, or `cron` as a documented fallback if it is
  absent (see [Scheduling](#scheduling)).

## Install

Download a release tarball (produced by every green CI run — see the Actions page, artifact
`restic-station-linux` — or build it yourself with `scripts/package-linux.sh`, no Linux machine
required), verify the checksums, and run the installer. GitHub always serves an Actions artifact
as a single ZIP, never as loose files — `restic-station-linux.zip` here contains both
architectures' tarballs plus `SHA256SUMS` at the top level, no subdirectory — so `unzip` it first:

```sh
unzip restic-station-linux.zip                        # one ZIP: both tarballs + SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing               # or: shasum -a 256 -c SHA256SUMS --ignore-missing
                                                        # (--ignore-missing skips whichever
                                                        # tarball you didn't download; always pass
                                                        # SHA256SUMS explicitly to shasum too — omit
                                                        # it and shasum reads from stdin instead and
                                                        # waits forever)
tar xzf restic-station-linux-aarch64.tar.gz            # or -x86_64
cd restic-station-linux-aarch64
./install.sh                                           # ~/.local/bin, no root needed
```

Verified for real, against this PR's own `release-linux` job output rather than reasoned about:
downloaded the actual `restic-station-linux` artifact via `gh api
.../actions/artifacts/<id>/zip` (byte-identical to what the Actions "Download artifact" button
serves), and `unzip -l` confirms it is a flat ZIP —

```
Archive:  restic-station-linux.zip
  Length      Date    Time    Name
---------  ---------- -----   ----
 23031105  08-06-2026 00:47   restic-station-linux-aarch64.tar.gz
 23897409  08-06-2026 00:46   restic-station-linux-x86_64.tar.gz
      203  08-06-2026 00:47   SHA256SUMS
---------                     -------
 46928717                     3 files
```

— then, after deleting one tarball to simulate downloading only one architecture, both
`sha256sum -c SHA256SUMS --ignore-missing` and `shasum -a 256 -c SHA256SUMS --ignore-missing`
verify the remaining one and exit 0, while `shasum -a 256 -c` with no `SHA256SUMS` argument reads
stdin instead and (confirmed separately, non-interactively, with stdin closed) reports "no
properly formatted SHA checksum lines found" rather than checking anything — with a real terminal
attached instead of closed stdin, that read blocks forever. `unzip`/`sha256sum`/`shasum`/`tar` are
generic archive tools, not Linux-specific, so this was verified on macOS against the real artifact
bytes rather than needing a Linux host — the point being tested is the artifact's shape and the
tools' documented flag behavior, neither of which is platform-dependent.

`install.sh` is idempotent (safe to re-run over a newer tarball) and warns — never fails — if
the chosen prefix is not already on `PATH`. Real output, from CI's `linux-integration` job
("`install.sh` works unprivileged, is idempotent, warns off-PATH" step):

```
$ ./install.sh --prefix=/home/runner/work/_temp/install-test-bin
installed /home/runner/work/_temp/install-test-bin/restic-station-helper
restic-station-helper 0.1.0

WARNING: /home/runner/work/_temp/install-test-bin is not on your PATH.
  Add it to your shell profile, e.g.:
    echo 'export PATH="/home/runner/work/_temp/install-test-bin:$PATH"' >> ~/.profile
  (then start a new shell, or: export PATH="/home/runner/work/_temp/install-test-bin:$PATH")

Next steps:
  1. Make sure restic (>= 0.18) is on PATH: restic version
  2. Set up config.json — either:
       - copy one exported from another machine:
         /home/runner/work/_temp/install-test-bin/restic-station-helper config import /path/to/config.json
       - or write $XDG_STATE_HOME/restic-station/config.json by hand
         (see README.md in this tarball, and docs/data-model.md upstream)
  3. Store each destination's password:
       /home/runner/work/_temp/install-test-bin/restic-station-helper secret set --dest <destination-id>
  4. Schedule it: /home/runner/work/_temp/install-test-bin/restic-station-helper timer install
     (systemd --user; falls back to printing a cron line on hosts without systemd)
  5. Check it: /home/runner/work/_temp/install-test-bin/restic-station-helper config validate
```

A second run over the same prefix is silent about the warning once the prefix is on `PATH`, and
never re-warns once fixed. The rest of this document assumes `restic-station-helper` is on
`PATH` (i.e. step 1 above is done) and writes commands accordingly.

## Get a config across

The headline M5 story: author sets, schedules and repositories once in the macOS app, then bring
that same fleet-wide config to this machine. `config.json` is the file meant to travel —
`config export` on the Mac writes it, `config import` here installs it, `config validate` shows
exactly what runs on *this* machine before you schedule anything.

The transcript below imports `scripts/fixtures/mac-exported-config.json` — a file checked into
this repository in the exact shape macOS's `config export` produces (two sets: "Projects", which
runs everywhere, and "Mac Photos Library", disabled for this machine via a `machines` override —
the same fixture `scripts/integration-test.sh`'s `assert_fixture_flow` imports). Real output:

```
$ restic-station-helper config import mac-exported-config.json
+ added set "Projects" (f1000000-0000-4000-8000-000000000001)
+ added set "Mac Photos Library" (f1000000-0000-4000-8000-000000000004)
installed /tmp/tmp.XXXXXXXXXX/data/config.json

$ restic-station-helper config validate
Errors:
  (none)

Warnings:
  (none)

Effective plan for machine "linux-nas":
  set "Projects" (f1000000-0000-4000-8000-000000000001) — RUNS HERE
      sources: /tmp/tmp.XXXXXXXXXX/source
      schedule: every 5 minutes
        - primary "NAS Primary": /tmp/tmp.XXXXXXXXXX/repo-primary
        - secondary "Offsite Mirror": /tmp/tmp.XXXXXXXXXX/repo-mirror
  set "Mac Photos Library" (f1000000-0000-4000-8000-000000000004) — does not run here
      sources: /Users/author/Pictures/Photos Library.photoslibrary
      schedule: daily 02:30
        - primary "NAS Primary": /Volumes/BackupNAS/photos-repo  (excluded here)

  excluded here, and why:
    - backup set "Mac Photos Library" is disabled on this machine
```

(`linux-nas` here is a demo machine id set via `RESTIC_STATION_MACHINE_ID` for a readable
transcript — see [Per-machine setup](#per-machine-setup); on a real host `machineId` is
generated once from the hostname and you would not normally set this.) This is the
anti-silent-failure guarantee of the whole per-machine design: `config validate` tells you, in
plain language, exactly what will and will not run here, and why — see
[Troubleshooting](#troubleshooting).

`config import` **never touches secrets** — repository passwords and secret env vars are never
in `config.json`, so `secret set` (below) is required on every machine, including this one, even
right after a successful import.

**`machine.json` (see next section) has one exception to "never touched": a v1 config's
deprecated `resticPath`.** A real (non-`--dry-run`) import runs the same v1→v2 migration
`ConfigStore.load()` always runs for an older-schema config
(`ConfigStore.migrateToCurrentVersion`, `Core/Sources/ResticStationCore/Config/ConfigStore.swift`),
and that migration *adopts* a v1 config's top-level `resticPath` into `machine.json` — only if
this host's `machine.json` does not already have one — before clearing the deprecated field from
the config it installs. That is exactly the case a config exported from an older, pre-schema-v2
macOS install is likely to carry (`docs/data-model.md` §Versioning & migration). **Only
`--dry-run` is guaranteed not to touch `machine.json`**: it previews the version bump via
`ConfigStore.previewMigration`, which deliberately does not simulate the `resticPath` relocation —
the import command's own `--dry-run` output says so explicitly ("a v1→v2 preview does not simulate
moving resticPath into machine.json; only a real import does that"). If you need certainty that
nothing on this host changes before committing, run `--dry-run` first and inspect the summary.
(`config import --help`'s abstract still says "Never touches machine.json" unconditionally — that
is the same overstatement, tracked to be tightened separately; this document states the actual
behavior.)

## Per-machine setup

### `machine.json`

`machine.json` holds exactly one thing that must never travel between hosts: this host's
identity (`machineId`) and, optionally, its own restic binary path. **Never copy `machine.json`
between machines.** If two hosts ever share a `machineId`, the second one silently inherits the
first one's per-machine overrides — including, worst case, "back up nothing" or "back up the
wrong directories." If you `rsync` an entire data directory to a new host (rather than using
`config export`/`import`), delete `machine.json` on the destination and let it regenerate.

`config.json`, by contrast, **is** the file meant to be shared — checked into a private repo,
copied by hand, whatever you like. This split (`docs/data-model.md` §machine.json) is what makes
one config file describe a whole fleet safely.

`machineId` is generated once, on first load, from the hostname (lowercased, non-`[a-z0-9-]`
characters become `-`). `RESTIC_STATION_MACHINE_ID`, if set, overrides it for that process only
— it is never written back to `machine.json`, which makes it safe for giving one host a second
identity, or for a reproducible test/demo transcript (as used above and below).

### The two worked examples

A `machines` override on a set or a destination **replaces** the field it names — it never
merges with the shared value — and there is no automatic path rewriting between machines
(`/Users/bwh/...` does not become `/home/bwh/...` on its own; that was considered and rejected as
implicit and silently wrong at the edges). Both examples' `config validate` **output** below is real, produced in CI against a real config —
but read the JSON blocks as *illustrations of the override shape*, not as files to copy:

- **Example 1** is **abridged** from `Core/Tests/ResticStationCoreTests/Fixtures/config-v2.json`
  (the fixture the per-machine resolution unit tests load, and what CI actually validated). The
  elisions are marked `…` below: a third destination and several required keys — `excludes`,
  `stalenessWarningDays`, `nonSecretEnv` — are omitted for readability. They are **not optional**;
  the decoders require them, so this block would fail `config import` if hand-copied as-is. That
  is why the validate output beneath it lists three destinations where the JSON shows two.
- **Example 2**'s config is **not** from that fixture. It is synthesized inline by
  `scripts/linux-docs-transcript.sh`, which is what CI ran to produce the output shown with it.

For a complete, importable file, use `config export` from a working install, or read the fixture
itself — do not reconstruct one from these excerpts.

**Example 1 — Linux as a source.** A NAS backs up its own directories, on its own schedule, to
its own path into the (shared) repository; a Mac-only scratch drive is not something the NAS can
see, so it is disabled there:

```jsonc
// ABRIDGED — see the note above. `…` marks omitted required keys and a third
// destination; this is not a copy-pasteable config.json.
"sets": [{
  "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "name": "Documents",
  "sources": ["/Users/bwh/Documents"],
  "excludes": [ … ],
  "stalenessWarningDays": …,
  "schedule": { "kind": "daily", "hour": 2, "minute": 30 },
  "machines": {
    "linux-nas": { "sources": ["/srv/data"], "schedule": { "kind": "daily", "hour": 4, "minute": 0 } },
    "old-laptop": { "enabled": false }
  },
  "destinations": [
    { "id": "0A1B2C3D-4E5F-4A1B-8C1D-000000000001", "label": "Big Drive",
      "repoURL": "/Volumes/Big/documents.restic", "isPrimary": true, "nonSecretEnv": { … },
      "machines": { "linux-nas": { "repoURL": "/mnt/big/documents.restic" } } },

    // …the fixture's second destination, "R2 mirror", is omitted here — it is
    // why the validate output below lists three destinations, not two…

    { "id": "2C3D4E5F-6061-4A1B-8C1D-000000000003", "label": "Mac-only external HDD",
      "repoURL": "/Volumes/Scratch/documents.restic", "isPrimary": false, "nonSecretEnv": { … },
      "machines": { "linux-nas": { "enabled": false } } }
  ]
}]
```

Real `config validate` output — run in CI against the **full** fixture (`Core/Tests/ResticStationCoreTests/Fixtures/config-v2.json`), not the abridged block above, which is why it lists a third destination:

```
$ restic-station-helper config validate --machine linux-nas
Errors:
  (none)

Warnings:
  - a machines override references "old-laptop", which this host cannot confirm exists — normal in a multi-machine fleet, but if it is a typo, those overrides silently never apply

Effective plan for machine "linux-nas":
  set "Documents" (6f9619ff-8b86-d011-b42d-00c04fc964ff) — RUNS HERE
      sources: /srv/data
      schedule: daily 04:00
        - primary "Big Drive": /mnt/big/documents.restic
        - secondary "R2 mirror": s3:https://accountid.r2.cloudflarestorage.com/backups/documents
        - secondary "Mac-only external HDD": /Volumes/Scratch/documents.restic  (excluded here)
  set "Photos" (7a8b9c0d-1e2f-4a3b-8c4d-000000000010) — does not run here
      sources: /Users/bwh/Pictures
      schedule: weekly Sun 03:00
        - primary "Big Drive": /mnt/big/photos.restic  (excluded here)

  excluded here, and why:
    - destination "Mac-only external HDD" is disabled on this machine
    - backup set "Photos" is disabled on this machine

$ restic-station-helper config validate --machine old-laptop
Errors:
  (none)

Warnings:
  (none)

Effective plan for machine "old-laptop":
  set "Documents" (6f9619ff-8b86-d011-b42d-00c04fc964ff) — does not run here
      sources: /Users/bwh/Documents
      schedule: daily 02:30
        - primary "Big Drive": /Volumes/Big/documents.restic  (excluded here)
        - secondary "R2 mirror": s3:https://accountid.r2.cloudflarestorage.com/backups/documents  (excluded here)
        - secondary "Mac-only external HDD": /Volumes/Scratch/documents.restic  (excluded here)
  set "Photos" (7a8b9c0d-1e2f-4a3b-8c4d-000000000010) — RUNS HERE
      sources: /Users/bwh/Pictures
      schedule: weekly Sun 03:00
        - primary "Big Drive": /Volumes/Big/photos.restic

  excluded here, and why:
    - backup set "Documents" is disabled on this machine
```

Note "Photos" has no `linux-nas` override at all, and still shows up correctly excluded/included
per machine — absent `machines`, or no entry for a given machine, always means "inherit and run
here."

**Example 2 — Linux as a mirror/restore target only.** A host that stores copies and can restore
from them, but backs up nothing of its own: every set is disabled for it, but it still reads the
same `config.json`, so `restore`, `probe-repo` and `unlock` know every repository in the fleet.
Real output, from a config `scripts/linux-docs-transcript.sh` synthesizes inline for this section (not the fixture above), in which both "Documents" and "Photos" are disabled for `mirror-box`:

```
$ restic-station-helper config validate --machine mirror-box
Errors:
  (none)

Warnings:
  (none)

Effective plan for machine "mirror-box":
  set "Documents" (6f9619ff-8b86-d011-b42d-00c04fc964ff) — does not run here
      sources: /Users/bwh/Documents
      schedule: daily 02:30
        - primary "Big Drive": /Volumes/Big/documents.restic  (excluded here)
  set "Photos" (7a8b9c0d-1e2f-4a3b-8c4d-000000000010) — does not run here
      sources: /Users/bwh/Pictures
      schedule: weekly Sun 03:00
        - primary "Big Drive": /Volumes/Big/photos.restic  (excluded here)

  excluded here, and why:
    - backup set "Documents" is disabled on this machine
    - backup set "Photos" is disabled on this machine

  nothing will run on this machine.
```

`tick` on a host like this prints one `skipping backup set "…" is disabled on this machine` line
per set and exits 0 — nothing runs, but nothing is silently broken either. Everything else still
works: `restic-station-helper restore --set … --dest …`, `probe-repo`, and `unlock` all use the
`.addressable` resolution view, which does not drop disabled sets — only `.scheduling` (what
`tick`/`run-set` act on) does. See `docs/data-model.md` §Per-machine scoping for the full
algorithm and the distinction between the two views.

## Secrets

Repository passwords and secret environment variables (e.g. S3 keys) live in `secrets.json`
under the state directory (`$XDG_STATE_HOME/restic-station`, default
`~/.local/state/restic-station`), **never** in `config.json`. The guarantee that actually holds:
**`secrets.json` itself is created `0600`**, via `open(2)`'s `O_EXCL|O_CREAT` (never
create-then-`chmod`, so the mode is never briefly wider), and **every read re-verifies that mode
and the opened file's owner** (see [Troubleshooting](#troubleshooting)). A non-root helper trusts
its effective uid and root; a root helper trusts only root, so it cannot bootstrap secrets from an
attacker-prepared `0600` file. Fresh state directories are created `0700`, including by
`AppPaths.ensureDirectories()`; before any secret is written, `FileSecretStore.prepareDirectories()`
also attempts to tighten an existing directory to `0700` ([issue
#49](https://github.com/bherila/restic-station/issues/49)). The resulting mode is checked rather
than trusting `chmod(2)`'s return value. Group/world write *and search* access is refused when it
would let another user replace `secrets.json` despite its `0600` mode; an owner outside the same
effective-user/root boundary is refused regardless of mode. Sticky directories are accepted when
trusted ownership protects the entry, as it does under `/tmp`. A squatted `secrets.json.tmp` is
still refused, but the diagnostic names its owner and the exact remove-or-relocate recovery instead
of reporting only “File exists.” Group/world read or
search access emits one warning per mutation and continues because the exposure is directory
entries and/or file metadata, not the secret contents. The same replacement check covers the
state directory's immediate parent so another writer cannot rename the whole directory aside; it
does not claim to audit every higher ancestor or filesystem ACL. Neither the refusal nor the
warning can be reached unless a `chmod` this process already attempted failed to take effect, so
both name the two causes that produce that instead of prescribing the same `chmod` again: the
directory belongs to another user (run it as that owner or as root), or the filesystem does not
honour permissions at all (a CIFS/FAT mount with `dir_mode`/`dmask`, `vboxsf`, WSL `drvfs` without
`metadata`), where no `chmod` will ever change it and the data directory has to move — point
`RESTIC_STATION_DATA_DIR` at a filesystem that does. The `0600` file mode is still
what protects the secret contents; the directory mode is defence in depth. This remains a
narrower guarantee than the macOS Keychain's (no encryption at rest, no ACL) and that is stated
rather than papered over — see
`docs/keychain-and-fda.md` §5 for the full threat model, including what is explicitly out of
scope (root, the invoking user, an unencrypted disk). A plain file, not a keyring, is deliberate:
the target hosts are headless, with no desktop session, D-Bus user bus, or keyring daemon for a
`gnome-keyring`/`kwallet`/`pass`-style solution to depend on.

**Never put a password in argv or an inline shell literal** — both end up in shell history and
briefly in the process list. `secret set` and `secret set-env` read from stdin only:

```sh
# interactive: prompts with echo disabled, nothing to type but the password
restic-station-helper secret set --dest <destination-id>

# scripted: read from a password manager or a file, never typed inline
your-secret-manager get repo-password | restic-station-helper secret set --dest <destination-id>

# S3-style credentials, as a JSON object of strings
printf '%s' '{"AWS_ACCESS_KEY_ID":"…","AWS_SECRET_ACCESS_KEY":"…"}' \
    | restic-station-helper secret set-env --dest <destination-id>
```

The interactive echo-disabled prompt itself cannot be shown here — CI has no TTY — but the piped
form exercises the identical code path (`SecretInput.read`) with the same stdin handling. Real
output for the piped form, `secret list`, and the file's mode, from CI:

```
$ printf '%s' '<redacted>' | restic-station-helper secret set --dest f1000000-0000-4000-8000-000000000002
stored a password for "NAS Primary"

$ restic-station-helper secret list
f1000000-0000-4000-8000-000000000002  "NAS Primary" (set "Projects")  password
f1000000-0000-4000-8000-000000000003  "Offsite Mirror" (set "Projects")  password

$ stat -c '%a %n' secrets.json .
600 secrets.json
700 .
```

`secret list` prints which destinations have secrets, never what they are — its renderer is
never handed a secret value at all. `secret rm --dest <uuid>` (add `--env` for the secret-env
blob instead of the password) removes one; both are idempotent.

## Initialize repositories

`run-set` never auto-initializes a primary repository — that is a deliberate one-time action, so
a typo'd repo URL cannot silently create a brand-new empty repository where you meant to point at
an existing one. Initialize the primary directly with restic, using the same
`RESTIC_PASSWORD_COMMAND` the engine itself uses (so you are proving the exact password path that
will run unattended, not a different one); initialize any secondary with `init-secondary`, which
runs `restic init --from-repo` against the primary so key derivation matches:

```
$ RESTIC_PASSWORD_COMMAND="restic-station-helper print-password --dest f1000000-0000-4000-8000-000000000002" \
    restic -r /path/to/primary-repo init
created restic repository 4a6e75218e at /path/to/primary-repo
...

$ restic-station-helper init-secondary --set f1000000-0000-4000-8000-000000000001 --dest f1000000-0000-4000-8000-000000000003
info: restic not configured; discovered /usr/bin/restic (version 0.18.1)
secondary "Offsite Mirror" initialized
```

### A remote destination needing more than a password (e.g. S3)

The `restic init` above supplies only `RESTIC_PASSWORD_COMMAND` — the repository password. Every
other invocation this project makes (`run-set`, `init-secondary`, `probe-repo`, `restore`, …) goes
through `ResticRunner`, which additionally assembles, in order, a destination's `nonSecretEnv`
(from `config.json`) and then its stored secret-env blob (from `secrets.json`, via `secret
set-env`) into the environment before running restic — a stored secret always wins a same-named
`nonSecretEnv` entry (`Core/Sources/ResticStationCore/Restic/ResticRunner.swift`,
`environment(for:)`; this ordering is the real mechanism, read from that function rather than
guessed). The direct `restic init` above **bypasses `ResticRunner` entirely** — it is deliberately
a bare `restic` invocation, run once, by hand — so a destination whose backend needs credentials
beyond the repository password (S3's `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, a B2 key pair,
an SFTP-related variable, …) needs those same variables supplied by hand for this one command too,
or the direct `init` fails authentication against a backend the rest of this tool talks to fine:

```sh
# Non-secret env this destination already carries in config.json (e.g. AWS_DEFAULT_REGION) —
# read it back with:
restic-station-helper config show --json \
    | jq '.sets[].destinations[] | select(.id=="<destination-id>") | .nonSecretEnv'

# Export both that non-secret env and the secret credentials — the same values you are
# about to hand to `secret set-env` — for this one command only:
export AWS_DEFAULT_REGION=us-east-1 AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
RESTIC_PASSWORD_COMMAND="restic-station-helper print-password --dest <destination-id>" \
    restic -r s3:https://bucket.example.com/repo init
```

There is no `secret print-env` counterpart to `print-password` — secret-env values are written,
never read back, by design (`secret list` reports only which destinations have one stored, never
its contents; see [Secrets](#secrets)) — so this one-time export has to come from values you
already have in hand, immediately before `secret set-env` stores them for every future run. After
that, `run-set`/`init-secondary`/`probe-repo`/`restore` all pick the same environment up
automatically through `ResticRunner`; nothing needs exporting by hand again. (This specific S3
example was not run in CI — this project has no S3 test credentials to exercise it with; the
composition order it describes is read directly from `ResticRunner.environment(for:)`'s source,
not inferred or invented — see [Not executed in CI](#not-executed-in-ci).)

## Scheduling

`timer install` writes and enables a per-user `systemd --user` timer that fires `tick` every 2
minutes by default (`--interval` to change it); `tick` decides what is actually due from
`state/schedule-state.json` — the timer only has to fire often enough. On a host with no
`systemd --user` (a stripped container image, `sd_booted(3)`'s own test — no
`/run/systemd/system`), `timer install` fails cleanly and prints a ready-to-paste cron line
instead of a confusing `systemctl: command not found`. Real output, from CI's `linux` job (the
`swift:6.1` container, which genuinely is not booted with systemd — the natural place this
message shows up for real, distinct from the `linux-integration` job the rest of this document's
transcripts come from):

```
$ restic-station-helper timer install
systemd is not available on this host, so there is no user timer to install.
Use cron instead — one line, no tooling needed (`crontab -e`):

    */2 * * * * /path/to/restic-station-helper tick

One behavioural difference: cron has no equivalent of the timer's
boot-time catch-up, so a tick missed while the machine was off is not
replayed at boot — the next scheduled tick picks it up instead. That
delays catch-up by up to one interval and loses nothing, because
due-ness comes from state/schedule-state.json, not from cron slots.
```

(exit 1 — this is the "fail cleanly, don't crash" behavior `timer install` guarantees on such a
host; nothing is written under `~/.config/systemd/user/`.)

### The linger gotcha

Without `sudo loginctl enable-linger <user>`, systemd stops a user's units the moment that user's
last login session ends. On a headless box this is the failure mode that generates bug reports:
everything reports healthy right up until the SSH session that ran `timer install` closes, and
then scheduled backups silently stop with no error anywhere. `timer install` and `timer status`
both check `loginctl show-user <user> --property=Linger` and print the exact fix
(`sudo loginctl enable-linger <user>`) when it is off — but it is never run automatically: it
needs root, and a backup tool that escalates privilege behind your back is a worse bug than the
warning.

**`timer status` exits 1 on a disabled-linger host** ([issue #46](https://github.com/bherila/restic-station/issues/46)),
so the exit code alone is enough — an installed, enabled, active timer that will die at the next
logout is not a host that will keep backing up, and reporting 0 for it was the exact
"green while broken" failure this project exists to prevent. The `VERDICT` block at the end of the
output names the reason.

One deliberate exception: a linger state of **`unknown`** — neither `loginctl` nor
`/var/lib/systemd/linger` could be consulted, which is what a container without logind looks like
— does not fail. Nothing logs out of such a host, so failing would make the check permanently red
with no reachable fix. Only a confirmed `Linger=no` counts. If you want certainty on a host that
reports `unknown`, read `loginctl show-user <user> --property=Linger` yourself.

Real `timer install`/`timer status` output, from CI's `linux-integration` job (a bare Ubuntu VM
where systemd genuinely is pid 1, unlike the `swift:6.1` container above):

```
$ restic-station-helper timer install
wrote /home/runner/.config/systemd/user/restic-station.service
wrote /home/runner/.config/systemd/user/restic-station.timer
  RESTIC_STATION_DATA_DIR=/tmp/tmp.XXXXXXXXXX/data
    (the data directory this command resolved, pinned into the unit — a
     --user service does not inherit your shell's XDG_STATE_HOME)
enabled restic-station.timer — ticking every 2min
  /tmp/tmp.XXXXXXXXXX/bin/restic-station-helper tick

$ restic-station-helper timer status
Restic Station — systemd --user timer

  units       installed in /home/runner/.config/systemd/user
                restic-station.service
                restic-station.timer
  interval    every 2min (OnUnitActiveSec)
  data dir    /tmp/tmp.XXXXXXXXXX/data (pinned in the unit)
  enabled     enabled
  active      active
  linger      enabled — user units keep running after logout

  next firing
    NEXT                        LEFT LAST PASSED UNIT                 ACTIVATES
    Thu 2026-08-06 23:04:18 UTC  41s -         - restic-station.timer restic-station.service
    
    1 timers listed.

  last tick activity (from state/ and runs/)
    "Projects": backup just now (2026-08-06T23:03:33Z)
    "Mac Photos Library": backup never
    last run: restore success (just now (2026-08-06T23:03:36Z))

  VERDICT     scheduled backups will happen on this host (exit 0)

$ loginctl show-user runner --property=Linger
Linger=yes
```

(This particular CI runner happens to have lingering enabled by default — see
[Not executed in CI](#not-executed-in-ci) for what that does and does not settle.)

### The data directory the timer will use

A `systemd --user` **service** runs under the per-user *manager's* environment, not the
interactive shell's: the manager starts once (typically at login, or at boot with lingering) and
keeps whatever environment it started with, which has no reason to include a variable your
`~/.bashrc`/`~/.profile` exports for interactive shells. So a unit that left the data directory
to be re-derived at tick time would resolve a *different* directory from the one you were looking
at when you installed it.

`timer install` therefore resolves the data directory through `AppPaths`
(`Core/Sources/ResticStationCore/Config/AppPaths.swift`) — the whole override chain:
`RESTIC_STATION_DATA_DIR`, then `$XDG_STATE_HOME/restic-station`, then
`~/.local/state/restic-station` — and pins the **absolute result** into the unit:

```ini
# The data directory `timer install` resolved, pinned here on purpose: a
# --user service inherits the systemd user manager's environment, not the
# shell's, so XDG_STATE_HOME and friends do not reach the tick.
Environment="RESTIC_STATION_DATA_DIR=/srv/state/restic-station"
```

This makes `systemctl --user cat restic-station.service` the answer to "which data directory does
this timer drive", instead of something to guess.

It was not always so ([issue #48](https://github.com/bherila/restic-station/issues/48)): the unit
used to carry `RESTIC_STATION_DATA_DIR` only when that variable happened to be exported, so a
host with a custom `XDG_STATE_HOME` installed a timer whose tick fell back to
`~/.local/state/restic-station`, found no `config.json` there, loaded a valid *empty* config —
and backed up nothing while exiting 0. That is a silent stop indistinguishable from "nothing was
due", and it survived a `timer status` check, because the timer really was installed, enabled and
active; it was simply ticking against the wrong directory. If you are reading a unit written by
an older build, look for the `Environment=` line and reinstall if it is missing.

The cron fallback carries the same pin, and needs it more — cron sources no profile at all:

```cron
*/2 * * * * RESTIC_STATION_DATA_DIR=/srv/state/restic-station /usr/local/bin/restic-station-helper tick
```

Confirmed directly against the real unit file this project's own CI writes, not just read from
source — `timer install` run once with a custom `XDG_STATE_HOME` and no `RESTIC_STATION_DATA_DIR`
override, then again with `RESTIC_STATION_DATA_DIR` set explicitly, from CI's `linux-integration`
job (`scripts/linux-docs-transcript.sh`, which asserts on the `Environment=` line rather than
merely printing it, so this stays regression-checked):

```
--- reinstalled with a custom XDG_STATE_HOME and no RESTIC_STATION_DATA_DIR override ---
$ cat /home/runner/.config/systemd/user/restic-station.service
# restic-station.service — installed by `restic-station-helper timer install`
# (docs/scheduling.md §Linux: systemd user timer). Re-running the command
# overwrites this file; hand edits survive only until then.
[Unit]
Description=Restic Station scheduling tick
Documentation=https://github.com/bherila/restic-station/blob/main/docs/scheduling.md

[Service]
Type=oneshot
ExecStart=/tmp/tmp.XXXXXXXXXX/bin/restic-station-helper tick
# The data directory `timer install` resolved, pinned here on purpose: a
# --user service inherits the systemd user manager's environment, not the
# shell's, so XDG_STATE_HOME and friends do not reach the tick.
Environment="RESTIC_STATION_DATA_DIR=/tmp/tmp.XXXXXXXXXX/custom-xdg-state/restic-station"

CONFIRMED: the unit pins /tmp/tmp.XXXXXXXXXX/custom-xdg-state/restic-station — the directory this shell's
XDG_STATE_HOME resolves to. The tick the timer fires reads the same data the shell
that installed it does, with no reliance on the user manager's environment.

--- and an explicit RESTIC_STATION_DATA_DIR still wins, as the highest-priority override ---
$ cat /home/runner/.config/systemd/user/restic-station.service
# restic-station.service — installed by `restic-station-helper timer install`
# (docs/scheduling.md §Linux: systemd user timer). Re-running the command
# overwrites this file; hand edits survive only until then.
[Unit]
Description=Restic Station scheduling tick
Documentation=https://github.com/bherila/restic-station/blob/main/docs/scheduling.md

[Service]
Type=oneshot
ExecStart=/tmp/tmp.XXXXXXXXXX/bin/restic-station-helper tick
# The data directory `timer install` resolved, pinned here on purpose: a
# --user service inherits the systemd user manager's environment, not the
# shell's, so XDG_STATE_HOME and friends do not reach the tick.
Environment="RESTIC_STATION_DATA_DIR=/tmp/tmp.XXXXXXXXXX/explicit-data-dir"
```

### A real firing, not just "enabled/active"

`timer status` reporting `enabled`/`active` is not the same thing as a timer actually firing on
its own — the gap `docs/testing.md` and [issue #45](https://github.com/bherila/restic-station/issues/45)
originally called out. CI now checks this directly: install a timer for a dedicated backup set
that has never run before (so `ScheduleMath`'s "never-run is immediately due" rule makes it due
on the very first tick), then wait for both the initial activation and an `OnUnitActiveSec=`
repeat without touching anything by hand. The set itself is due every five minutes, so the repeat
must tick without creating an early second backup. Real output from the 2026-08-15 run:

```
$ restic-station-helper timer install --interval 2
wrote /home/runner/.config/systemd/user/restic-station.service
wrote /home/runner/.config/systemd/user/restic-station.timer
enabled restic-station.timer — ticking every 2min

waiting up to 250s, polling every 10s, for two unattended service activations:
the first must back up the never-run set; the OnUnitActiveSec repeat must tick again without
backing it up early (the set itself is due every 5 minutes):
  t=+100s  service starts=0  backup runs=0
  t=+110s  service starts=1  backup runs=1
  ...
  t=+220s  service starts=1  backup runs=1
  t=+230s  service starts=2  backup runs=1

$ restic-station-helper runs list --json
[
  {
    "kind" : "backup",
    "runId" : "20260815T185107Z-backup-e1000000",
    "setId" : "E1000000-0000-4000-8000-000000000001",
    "snapshotId" : "c8f3f32b8ece4b56b7813aa2c14ddead13a6dbd999377653babbed9c0323eb58",
    "status" : "success",
    "trigger" : "scheduled",
    ...
  }
]

$ journalctl --user -u restic-station.service --no-pager --since -5 minutes
Aug 15 18:51:07 runnervm69nxj systemd[1238]: Starting restic-station.service - Restic Station scheduling tick...
Aug 15 18:51:07 runnervm69nxj restic-station-helper[4448]: info: restic not configured; discovered /usr/bin/restic (version 0.18.1)
Aug 15 18:51:08 runnervm69nxj restic-station-helper[4448]: set "Fire Check": success (1 run)
Aug 15 18:51:08 runnervm69nxj systemd[1238]: Finished restic-station.service - Restic Station scheduling tick.
Aug 15 18:53:08 runnervm69nxj systemd[1238]: Starting restic-station.service - Restic Station scheduling tick...
Aug 15 18:53:08 runnervm69nxj restic-station-helper[4623]: info: restic not configured; discovered /usr/bin/restic (version 0.18.1)
Aug 15 18:53:08 runnervm69nxj systemd[1238]: Finished restic-station.service - Restic Station scheduling tick.
```

`"trigger": "scheduled"` (not `"manual"`) confirms the tick that produced this run really was
invoked by the timer, not by anything in the script calling the helper directly. This is a
genuine, unattended, `OnBootSec=` → due-set discovery → real backup firing followed two minutes
later by an unattended `OnUnitActiveSec=` repeat on a real (non-container) host. The unchanged
backup-run count proves schedule due-ness remained authoritative. See
[issue #45](https://github.com/bherila/restic-station/issues/45) for the remaining logout/reboot
survival boundary.

### Journal locations

`journalctl --user -u restic-station.service` shows every tick's own stdout/stderr (nothing
sensitive — no secret ever reaches a log line, per `keychain-and-fda.md` §5); add `-f` to follow
it live, or `--since "-1 hour"` to scope it. `journalctl --user -u restic-station.timer` shows
the timer's own activation history.

### The `Persistent=true` in the shipped unit — what it does and does not do

The shipped `restic-station.timer` (`packaging/linux/systemd/`, byte-identical to what
`timer install` writes) carries `Persistent=true`. **On this unit it is inert** —
`systemd.timer(5)` scopes `Persistent=` to `OnCalendar=` timers, and this one uses the monotonic
`OnBootSec=2min` / `OnUnitActiveSec=2min` pair instead. Real catch-up after downtime (a machine
off overnight ticks again ~2 minutes after boot, and that tick finds every set overdue) comes
from `OnBootSec=` plus due-ness stored in `state/schedule-state.json` — not from `Persistent=`.
It is kept in the unit anyway, deliberately, because it states the *intent* (missed runs are
caught up, never skipped) and would become load-bearing the moment anyone switches the interval
to an `OnCalendar=` expression; do not "clean it up" as dead configuration.

### No systemd: the cron fallback

Shown in the `timer install` failure output above. One line, no tooling: `*/2 * * * *
/path/to/restic-station-helper tick`. The one behavioral difference from the systemd path: cron
has no `OnBootSec=` equivalent, so a tick missed while the machine was off is not replayed at
boot — the next scheduled cron slot picks it up instead, delaying catch-up by up to one interval
and losing nothing (due-ness still comes from `schedule-state.json`, never from cron's own
notion of time).

## Operating it

`status`, `runs list`, and `runs show --log` read only existing state — no restic invocation, no
network access — and are safe to run as often as a monitoring check likes. One qualification, on
Linux only: `status` also asks the systemd `--user` timer whether it will fire — three short
`systemctl --user` queries, each bounded by a 5-second timeout — because a status command that
cannot see the scheduler reports a stopped machine as healthy for days. It still writes nothing,
touches no repository, and skips the slowest query (`list-timers`), which is narrative this
caller has no use for.

Real output, continuing the session above: a real backup + mirror copy has already run via
`run-set --kind backup`, and nothing is scheduling *this* data directory.

```
$ restic-station-helper status
machine "linux-nas" — warning
scheduler (systemd-timer): SCHEDULED BACKUPS WILL NOT HAPPEN
  - the installed timer ticks a different data directory than this command reads
  detail: restic-station-helper timer status

set "Projects" (f1000000-0000-4000-8000-000000000001)
    last backup: success, 1s ago (20260806T230333Z-backup-f1000000)
    last check:  never
    last prune:  never
    next due:    2026-08-06T23:08:33.941Z
      - primary "NAS Primary": reachable
      - secondary "Offsite Mirror": reachable

excluded here, and why:
  - backup set "Mac Photos Library" is disabled on this machine
(exit 1)

$ restic-station-helper status --json
{
  "excludedHere" : [
    {
      "description" : "backup set \"Mac Photos Library\" is disabled on this machine",
      "id" : "F1000000-0000-4000-8000-000000000004",
      "name" : "Mac Photos Library",
      "reason" : "disabledForMachine",
      "setId" : "F1000000-0000-4000-8000-000000000004",
      "subject" : "backupSet"
    }
  ],
  "fullDiskAccessDenied" : false,
  "generatedAt" : "2026-08-06T23:03:36.040Z",
  "health" : "warning",
  "machineId" : "linux-nas",
  "scheduler" : {
    "healthy" : false,
    "kind" : "systemd-timer",
    "problems" : [
      "dataDirectoryMismatch"
    ],
    "summaries" : [
      "the installed timer ticks a different data directory than this command reads"
    ]
  },
  "sets" : [
    {
      "abandonedRun" : null,
      "abandonedRunFile" : null,
      "currentRun" : null,
      "destinations" : [
        {
          "id" : "F1000000-0000-4000-8000-000000000002",
          "isPrimary" : true,
          "label" : "NAS Primary",
          "lastError" : null,
          "lastSyncedAt" : "2026-08-06T23:03:34.641Z",
          "reachable" : true,
          "stale" : false
        },
        {
          "id" : "F1000000-0000-4000-8000-000000000003",
          "isPrimary" : false,
          "label" : "Offsite Mirror",
          "lastError" : null,
          "lastSyncedAt" : "2026-08-06T23:03:36.003Z",
          "reachable" : true,
          "stale" : false
        }
      ],
      "firstBackupOverdue" : false,
      "id" : "F1000000-0000-4000-8000-000000000001",
      "isRunning" : false,
      "lastBackup" : {
        "ageSeconds" : 1.400916576385498,
        "end" : "2026-08-06T23:03:34.639Z",
        "runId" : "20260806T230333Z-backup-f1000000",
        "start" : "2026-08-06T23:03:33.943Z",
        "status" : "success"
      },
      "lastCheck" : null,
      "lastPrune" : null,
      "name" : "Projects",
      "needsAttention" : false,
      "nextDue" : "2026-08-06T23:08:33.941Z"
    }
  ],
  "unattributedRuns" : [

  ]
}
(exit 1)

$ restic-station-helper runs list
20260806T230334Z-copy-f1000000  copy  success  start=2026-08-06T23:03:34.643Z  end=2026-08-06T23:03:36.001Z
20260806T230333Z-backup-f1000000  backup  success  start=2026-08-06T23:03:33.943Z  end=2026-08-06T23:03:34.639Z
20260806T230330Z-init-f1000000  init  success  start=2026-08-06T23:03:30.921Z  end=2026-08-06T23:03:33.924Z

(runId captured for the next command: 20260806T230333Z-backup-f1000000)

$ restic-station-helper runs show 20260806T230333Z-backup-f1000000 --log
runId:    20260806T230333Z-backup-f1000000
kind:     backup
setId:    f1000000-0000-4000-8000-000000000001
destId:   f1000000-0000-4000-8000-000000000002
status:   success
trigger:  manual
start:    2026-08-06T23:03:33.943Z
end:      2026-08-06T23:03:34.639Z
snapshot: 7b5316e2d75d2237d3d94290eefe313196bf716da45157acdce057bfad97f95a
argv:     -r /tmp/tmp.XXXXXXXXXX/repo-primary backup --json /tmp/tmp.XXXXXXXXXX/source

[23:03:33] $ -r /tmp/tmp.XXXXXXXXXX/repo-primary backup --json /tmp/tmp.XXXXXXXXXX/source
[23:03:33] probe primary "NAS Primary": reachable
[23:03:34] {"message_type":"summary","files_new":2,"files_changed":0,"files_unmodified":0,"dirs_new":3,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":2,"tree_blobs":4,"data_added":1874,"data_added_packed":1484,"total_files_processed":2,"total_bytes_processed":67,"total_duration":0.678220979,"backup_start":"2026-08-06T23:03:33.956811914Z","backup_end":"2026-08-06T23:03:34.635032885Z","snapshot_id":"7b5316e2d75d2237d3d94290eefe313196bf716da45157acdce057bfad97f95a"}
```

Two things in that output are worth calling out, because they are not what a
first-time reader expects.

`status` exits **1**, and says `SCHEDULED BACKUPS WILL NOT HAPPEN`. That is
correct and is the whole point of [the monitoring section](#monitoring): this
data directory has no timer driving it. On this particular runner the reason is
`dataDirectoryMismatch` rather than `unitsMissing` — an earlier CI step (a T26
diagnostic that checks `timer install` works on a bare Actions VM) had already
installed a timer for a *different* directory. So this is also an unplanned
live demonstration of that check: a timer that is genuinely enabled and active,
correctly reported as not covering the directory being asked about.

`status --json` and `runs list --json`/`runs show --json` are documented, stable interfaces
(`docs/data-model.md` §"Headless CLI `--json` shapes") — a script piping one into `jq` is
expected to keep working release to release, the same guarantee `runs/index.jsonl` carries.

**`status` sees the scheduler on Linux, so one command is enough.** It exits **1** whenever any
backup set needs attention *or* the systemd `--user` timer will not fire — the same verdict
`timer status` exits on, computed by the same `SystemdTimerManager`, so the two can never
disagree. The reason is in the `scheduler` key:

```jsonc
"scheduler": {
  "kind": "systemd-timer",
  "healthy": false,
  "problems": ["lingerDisabled"],          // stable identifiers — branch on these
  "summaries": ["lingering is disabled — the timer stops at logout (`sudo loginctl enable-linger <user>`)"]
}
```

Three answers, and only one of them is a finding:

| `scheduler` | meaning | contributes to health? |
|---|---|---|
| `{"kind": "systemd-timer", "healthy": true, …}` | the timer will fire | no |
| `{"kind": "systemd-timer", "healthy": false, …}` | a real finding: exit 1, reason named | **yes — warning** |
| `{"kind": "unknown", "healthy": null, …}` | no systemd here; the documented fallback is a cron line, which nothing can inspect | no |
| `{"kind": "launchd-agent", "healthy": true, …}` | macOS: launchd reports the SMAppService agent loaded | no |
| `{"kind": "launchd-agent", "healthy": false, …}` | macOS: the agent is not loaded | **yes — warning** |
| `{"kind": "launchd-agent", "healthy": null, …}` | macOS: the launchctl probe failed, so state is unknown | no |

The two "don't know" answers deliberately contribute nothing, exactly as an absent
`fda-check.json` does — a check that goes permanently red inside every container is a check
nobody reads. Only a definite `false` is a warning.

This is a change from earlier builds, and the reason it was worth making: `Status.run()` used to
pass `backgroundAgentEnabled: true` unconditionally on every platform, which reads as "the
scheduler is fine". So if the timer stopped firing entirely — lingering got disabled, someone ran
`timer uninstall` and forgot to reinstall it, the unit got wedged — `status --json` kept reporting
the last known-good state and **stayed exit 0** for as long as every already-recorded run stayed
inside its staleness window, which for a quiet set is days
([issue #46](https://github.com/bherila/restic-station/issues/46)).

`timer status` remains the command to run when something *is* wrong: it prints the units, the
installed interval, the linger state and the next firing, where `status` gives you the verdict and
the reason.

Confirmed directly in CI, not just read from source — the timer this document's scheduling
transcripts installed is uninstalled, and then `status --json` is run against the same data
directory (`scripts/linux-docs-transcript.sh` asserts on `scheduler.healthy` and the exit code,
so this stays regression-checked):

```
--- status --json for the same data dir, right after the timer above was uninstalled ---
$ restic-station-helper status --json; echo "exit $?"
{
  "excludedHere" : [

  ],
  "fullDiskAccessDenied" : false,
  "generatedAt" : "2026-08-06T23:05:10.591Z",
  "health" : "warning",
  "machineId" : "linux-nas",
  "scheduler" : {
    "healthy" : false,
    "kind" : "systemd-timer",
    "problems" : [
      "unitsMissing",
      "notEnabled",
      "notActive"
    ],
    "summaries" : [
      "the units are not installed — run `restic-station-helper timer install`",
      "the timer is not enabled, so it will not come back after a reboot",
      "the timer is not active, so it is not firing now"
    ]
  },
  "sets" : [
    {
      "abandonedRun" : null,
      "abandonedRunFile" : null,
      "currentRun" : null,
      "destinations" : [
        {
          "id" : "E1000000-0000-4000-8000-000000000002",
          "isPrimary" : true,
          "label" : "Fire Primary",
          "lastError" : null,
          "lastSyncedAt" : "2026-08-06T23:05:02.676Z",
          "reachable" : true,
          "stale" : false
        }
      ],
      "firstBackupOverdue" : false,
      "id" : "E1000000-0000-4000-8000-000000000001",
      "isRunning" : false,
      "lastBackup" : {
        "ageSeconds" : 7.917420506477356,
        "end" : "2026-08-06T23:05:02.674Z",
        "runId" : "20260806T230501Z-backup-e1000000",
        "start" : "2026-08-06T23:05:01.986Z",
        "status" : "success"
      },
      "lastCheck" : null,
      "lastPrune" : null,
      "name" : "Fire Check",
      "needsAttention" : false,
      "nextDue" : "2026-08-06T23:10:01.983Z"
    }
  ],
  "unattributedRuns" : [

  ]
}
exit 1

CONFIRMED: status --json reports scheduler.healthy=false, names the reason in
scheduler.problems, and exits 1 — on the same host and data directory that used to
exit 0 with no mention of the scheduler at all.

--- and the human rendering says it in one line ---
machine "linux-nas" — warning
scheduler (systemd-timer): SCHEDULED BACKUPS WILL NOT HAPPEN
  - the units are not installed — run `restic-station-helper timer install`
  - the timer is not enabled, so it will not come back after a reboot
  - the timer is not active, so it is not firing now
  detail: restic-station-helper timer status

set "Fire Check" (e1000000-0000-4000-8000-000000000001)
    last backup: success, 7s ago (20260806T230501Z-backup-e1000000)
    last check:  never
    last prune:  never
    next due:    2026-08-06T23:10:01.983Z
      - primary "Fire Primary": reachable

--- timer status for the same host: the same verdict, the same exit code ---

$ restic-station-helper timer status
Restic Station — systemd --user timer

  units       not installed (looked in /home/runner/.config/systemd/user)
                fix: restic-station-helper timer install
  enabled     not-found
  active      inactive
  linger      enabled — user units keep running after logout

  last tick activity (from state/ and runs/)
    "Fire Check": backup just now (2026-08-06T23:05:01Z)
    last run: backup success (just now (2026-08-06T23:05:02Z))

  VERDICT     scheduled backups will NOT happen on this host (exit 1)
                - the units are not installed — run `restic-station-helper timer install`
                - the timer is not enabled, so it will not come back after a reboot
                - the timer is not active, so it is not firing now
(exit 1)
```

**A killed run does not leave the host reporting healthy.** A `SIGKILL`, an OOM kill or a power
cut skips the `defer` that deletes `state/current-run-<setId>.json`, and that file is what "a run
is in flight" means to every reader — and `running` outranks `warning`. One dead run therefore
used to pin a machine green permanently. `status` now checks the run's recorded `pid` (via
`runs/<runId>/metadata.json`, the same evidence the tick's crash recovery uses) rather than
trusting the file's existence, and reports:

```jsonc
"isRunning": false,
"needsAttention": true,
"abandonedRun": { "runId": "20260101T000000Z-backup-deadbeef", "kind": "backup", … },
"abandonedRunFile": "/srv/state/restic-station/state/current-run-<setId>.json"
```

The next tick clears it (`recoverInterrupted` rewrites the run as `failed`, then deletes the
matching progress file); `rm` the named file to clear it now. Note this is **not** a staleness
rule on `updatedAt` — a `check --read-data` on a large repository legitimately writes nothing for
hours, and a threshold that tolerates that is too coarse to be a health check.

```
--- a current-run file whose process is gone (updatedAt is *now*, so no timestamp
    heuristic would catch it) ---
{
  "health": "warning",
  "sets": [
    {
      "name": "Fire Check",
      "isRunning": false,
      "needsAttention": true,
      "abandonedRun": {
        "bytesDone": 1,
        "filesDone": 1,
        "kind": "backup",
        "percentDone": 50,
        "phase": "backing-up-primary",
        "runId": "20260101T000000Z-backup-deadbeef",
        "totalBytes": 2,
        "totalFiles": 2
      }
    }
  ]
}
exit 1

CONFIRMED: health is "warning" (not "running"), the set reports isRunning=false, and the
abandoned run is named so it can be cleared. Before this, the same file made every
subsequent health check on this host exit 0 forever.
```

### Restore

```
$ restic-station-helper restore --set f1000000-0000-4000-8000-000000000001 \
    --dest f1000000-0000-4000-8000-000000000002 \
    --snapshot e0f6f5fd45d8edd8f9cc923a6e81f435639637c8424bd7ce2756c2d422d2ee1a \
    --target /tmp/tmp.XXXXXXXXXX/restore-target
info: restic not configured; discovered /usr/bin/restic (version 0.18.1)
restore completed

$ diff -r /tmp/tmp.XXXXXXXXXX/source /tmp/tmp.XXXXXXXXXX/restore-target/tmp/tmp.XXXXXXXXXX/source
(no output — restored files matched byte-for-byte)
```

`--snapshot` takes a real snapshot id (from `runs show --json`'s `snapshotId`, or `restic
snapshots`) — there is no `latest` shorthand in this command today. `--overwrite` controls
collision policy (`always` / `if-changed` / `if-newer` / `never`, default `always`); `--sub`
restricts the restore to an in-snapshot path; `restore --set … --dest …` addresses the
`.addressable` view, so it works even for a destination this machine does not back up (the
mirror/restore-only story above).

## Troubleshooting

**A set is silently excluded by a per-machine override.** This is the top failure mode of the
whole per-machine design, and the mitigation is: **run `config validate` (or `config show`)
before you rely on anything, and any time you add or change a `machines` override.** Both report,
in plain language, which sets and destinations run here, which are excluded, and exactly why
(`disabledForMachine`, `noEnabledDestinations`, or `noSources` — see `docs/data-model.md`
§Per-machine scoping). The [worked examples](#the-two-worked-examples) above show real output for
both an override that includes a set and one that excludes it. If a set you expected to run says
"does not run here," check for a `machines` entry keyed on this host's `machineId`
(`restic-station-helper config show` prints it) — a typo'd machine id is reported as a *warning*
("references … which this host cannot confirm exists"), not an error, because a multi-machine
fleet legitimately has overrides for hosts that are not this one.

**Lingering disabled → backups silently stop.** See [The linger gotcha](#the-linger-gotcha).
Symptom: everything looked fine right after `timer install`, then backups just stop days or
weeks later with nothing in any log, because the SSH session that ran `timer install` eventually
ended. Both `timer status` and `status` exit 1 on such a host and name `lingerDisabled` as the
reason, so a monitoring check catches it — but only once you look. Fix:
`sudo loginctl enable-linger <user>`, then `restic-station-helper timer status` and confirm the
`linger` line says `enabled` and the `VERDICT` line says backups will happen.

**"refusing to read …/secrets.json: it is group- or world-accessible."** Exactly what it says —
run the `chmod 600` the message prints. Real output, deliberately reproduced by widening the mode
and then fixing it:

```
$ chmod 644 secrets.json
$ restic-station-helper secret list
could not read stored secrets: refusing to read /path/secrets.json: it is group- or world-accessible (mode 0644). Fix it with: chmod 600 /path/secrets.json

$ chmod 600 secrets.json
$ restic-station-helper secret list
f1000000-0000-4000-8000-000000000002  "NAS Primary" (set "Projects")  password
f1000000-0000-4000-8000-000000000003  "Offsite Mirror" (set "Projects")  password
```

If something recursively `chmod`'ed the whole data directory, other state files were likely
widened too — worth checking, not just `secrets.json`.

**"refusing to read …/secrets.json: it is owned by uid …".** The helper will not consume a
plausible-looking secret file from outside its ownership boundary. Verify that the path really is
the intended data directory, then run the printed `chown` deliberately; for a root-run helper the
file and data directory must be root-owned.

**"could not safely create …/secrets.json.tmp".** A stale or squatted fixed temp entry could not
be removed, or appeared during the secure `O_EXCL` create. The message reports the entry owner:
remove it as that owner or root and retry. If the data root itself is a shared sticky directory
such as `/tmp`, prefer a private directory and point `RESTIC_STATION_DATA_DIR` there.

**"restic not found" / "restic 0.16.4 … is too old."** These are two different messages now, and
the distinction is the point. `ResticDiscovery` requires a candidate to actually *run* a successful
`restic version --json` above the 0.17.0 floor, not merely exist and be executable — so there are
three ways to have no usable restic, and each says which one it is
([issue #50](https://github.com/bherila/restic-station/issues/50)).

**Nothing anywhere.** Names every location actually searched (the well-known paths, then one
`<dir>/restic` per `PATH` entry), and where to set `resticPath` explicitly — `machine.json`, not
`config.json`, because a binary path is host-local (see `docs/architecture.md` §restic discovery).

```
restic not found. Searched /usr/bin/restic, /usr/local/bin/restic, /opt/restic/bin/restic, and every directory on PATH.
Install an official release binary from https://github.com/restic/restic/releases — distribution packages are frequently older than the 0.17.0 minimum.
Or set "resticPath" in /tmp/tmp.XXXXXXXXXX/machine.json to point at one you already have.
```

**Found, but too old** — this is what `apt install restic` gets you on Ubuntu 24.04 (0.16.4). The
message names the binary, the version it reported, and the minimum, because "install restic" is
useless advice to someone who has restic:

```
restic 0.16.4 at /tmp/tmp.XXXXXXXXXX/restic is too old — Restic Station needs 0.17.0 or newer (docs/restic-cli.md §version: it is the first release with the exit-code contract this tool relies on).
Install an official release binary from https://github.com/restic/restic/releases — distribution packages are frequently older than the 0.17.0 minimum.
Or set "resticPath" in /tmp/tmp.XXXXXXXXXX/machine.json to point at one you already have.
```

Until this was fixed, that case printed the *same* "restic not found" text as the case above, and
its own suggested remedy (`apt install restic`) reproduced it — install the package, re-run, get
told restic is not found, with a perfectly good binary sitting on `PATH`. It is how this project's
own `linux-integration` job broke during T29.

**Found, but it does not run** — a wrapper script for an uninstalled package, a broken symlink, an
architecture mismatch. All pass the executable-bit check and fail to execute; the message carries
restic's own exit code or stderr:

```
restic could not be used. /tmp/tmp.XXXXXXXXXX/restic exited 72 when asked for its version.
Install an official release binary from https://github.com/restic/restic/releases — distribution packages are frequently older than the 0.17.0 minimum.
Or set "resticPath" in /tmp/tmp.XXXXXXXXXX/machine.json to point at one you already have.
```

**Repo unreachable vs. an offline mirror.** `probe-repo` reports reachability directly and
records it to `state/repo-status-<destId>.json`; a *mirror* that is offline is not an error at
all — the engine skips it gracefully, tracks staleness, and catches it up in full the next time
it is reachable (retention is never applied to a mirror that is not caught up). A *primary* that
is unreachable fails the backup — there is no destination to write to. Real output, probing a
repo and then simulating it going away:

```
$ restic-station-helper probe-repo --set f1000000-0000-4000-8000-000000000001 --dest f1000000-0000-4000-8000-000000000002
info: restic not configured; discovered /usr/bin/restic (version 0.18.1)
"NAS Primary": reachable

$ mv /path/to/repo-primary /path/to/repo-primary.unplugged
$ restic-station-helper probe-repo --set f1000000-0000-4000-8000-000000000001 --dest f1000000-0000-4000-8000-000000000002
info: restic not configured; discovered /usr/bin/restic (version 0.18.1)
"NAS Primary": offline — repository path does not exist
```

(exits 3 for "offline", distinct from exit 1 for a genuine error — see `restic-cli.md`.)

## Not executed in CI

Two things this document does not claim to have observed, and why:

- **The interactive, echo-disabled `secret set` TTY prompt.** CI has no terminal attached to
  stdin; the piped form shown above exercises the same `SecretInput.read` code path with the
  same trailing-newline stripping, minus the prompt/echo behavior itself, which is a few lines of
  well-isolated code (`Helper/Sources/Commands/Secret.swift`).
- **The direct `restic init` against a real S3 (or other credentialed) destination** in [A remote
  destination needing more than a password](#a-remote-destination-needing-more-than-a-password-eg-s3).
  This project has no S3 test credentials in CI; the export pattern shown is read from
  `ResticRunner.environment(for:)`'s actual composition order, not invented, but the specific
  `restic init` against `s3:https://…` was not executed anywhere for this document.
- **A `systemd --user` timer surviving an actual logout/reboot, or firing repeatedly over
  hours/days.** [A real, unattended initial firing and one `OnUnitActiveSec=` repeat are now
  observed in CI](#a-real-firing-not-just-enabledactive). What the hosted job still cannot show
  is the timer surviving the account that ran `timer install` actually logging out or the VM
  rebooting (the job's own session and host never end mid-run), nor long-duration repetition.
  That remaining persistent-host verification is tracked in
  [issue #45](https://github.com/bherila/restic-station/issues/45).
