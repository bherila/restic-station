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

Every transcript in this document is real. It comes from `scripts/linux-docs-transcript.sh`,
which CI's `linux-integration` job (`.github/workflows/ci.yml`) runs against the **static**
release binary and a real restic 0.18.1, on a genuine (non-container) Ubuntu VM — the same job
that runs `scripts/integration-test.sh`'s Linux fixture-import scenario. Nothing below was typed
by hand on a Mac and relabeled; where something could not be run in CI, that is stated
explicitly instead of shown as if it were observed (see [Scheduling](#scheduling) and
[Not executed in CI](#not-executed-in-ci)).

## Prerequisites

- **A restic binary, 0.17.0 or newer (0.18+ recommended), on `PATH` or at an explicit
  `resticPath`.** This is the single most common first-run failure, so it is stated again here,
  prominently, not just in `packaging/linux/README.md`: **your distro's package is almost
  certainly too old.** Ubuntu 24.04 LTS ships restic **0.16.4**; Debian stable is comparable.
  `apt install restic` gets you a restic this tool refuses to use — and the failure reads
  confusingly, because `ResticDiscovery` reports it as **"restic not found"** right after you
  watched a package manager install one. `docs/restic-cli.md` §version explains why 0.17.0 is
  the floor (the first release with the exit-code contract this tool relies on).

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
required), verify the checksums, and run the installer:

```sh
tar xzf restic-station-linux-aarch64.tar.gz    # or -x86_64
cd restic-station-linux-aarch64
sha256sum -c ../SHA256SUMS --ignore-missing     # or: shasum -a 256 -c
./install.sh                                    # ~/.local/bin, no root needed
```

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
right after a successful import. It also never touches `machine.json` (see next section) except
to read this host's own identity for the report above.

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
implicit and silently wrong at the edges). Both examples below are real JSON, taken from
`Core/Tests/ResticStationCoreTests/Fixtures/config-v2.json` — the same fixture the per-machine
resolution unit tests load — and re-validated for real in CI (not just eyeballed) against exactly
this file.

**Example 1 — Linux as a source.** A NAS backs up its own directories, on its own schedule, to
its own path into the (shared) repository; a Mac-only scratch drive is not something the NAS can
see, so it is disabled there:

```json
"sets": [{
  "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "name": "Documents",
  "sources": ["/Users/bwh/Documents"],
  "schedule": { "kind": "daily", "hour": 2, "minute": 30 },
  "machines": {
    "linux-nas": { "sources": ["/srv/data"], "schedule": { "kind": "daily", "hour": 4, "minute": 0 } },
    "old-laptop": { "enabled": false }
  },
  "destinations": [
    { "id": "0A1B2C3D-4E5F-4A1B-8C1D-000000000001", "label": "Big Drive",
      "repoURL": "/Volumes/Big/documents.restic", "isPrimary": true,
      "machines": { "linux-nas": { "repoURL": "/mnt/big/documents.restic" } } },
    { "id": "2C3D4E5F-6061-4A1B-8C1D-000000000003", "label": "Mac-only external HDD",
      "repoURL": "/Volumes/Scratch/documents.restic", "isPrimary": false,
      "machines": { "linux-nas": { "enabled": false } } }
  ]
}]
```

Real `config validate` output for this exact fixture, as `linux-nas` and as `old-laptop`:

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
Real output, for a config where both "Documents" and "Photos" are disabled for `mirror-box`:

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
`~/.local/state/restic-station`) — created at mode `0600`, in a directory created at `0700`,
**never** in `config.json`. This is a narrower guarantee than the macOS Keychain's (no
encryption at rest, no ACL) and that is stated rather than papered over — see
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
755 .
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

**Check the `linger` line explicitly — do not trust `timer status`'s exit code for this.**
`timer status` currently exits 0 whenever the timer unit is installed, enabled and active, **even
if lingering is disabled** (tracked as [issue #46](https://github.com/bherila/restic-station/issues/46);
not fixed here because a docs task is the wrong place to change scheduling exit-code behavior).
A disabled-linger host can look completely healthy to a script checking only the exit code and
still stop backing up the next time its owner logs out. Read the `linger` line in the human
output, or `loginctl show-user <user> --property=Linger` directly.

Real `timer install`/`timer status` output, from CI's `linux-integration` job (a bare Ubuntu VM
where systemd genuinely is pid 1, unlike the `swift:6.1` container above):

```
$ restic-station-helper timer install
wrote /home/runner/.config/systemd/user/restic-station.service
wrote /home/runner/.config/systemd/user/restic-station.timer
  RESTIC_STATION_DATA_DIR=/tmp/tmp.XXXXXXXXXX/data (baked in from this shell's environment)
enabled restic-station.timer — ticking every 2min
  /tmp/tmp.XXXXXXXXXX/bin/restic-station-helper tick

$ restic-station-helper timer status
Restic Station — systemd --user timer

  units       installed in /home/runner/.config/systemd/user
                restic-station.service
                restic-station.timer
  interval    every 2min (OnUnitActiveSec)
  enabled     enabled
  active      active
  linger      enabled — user units keep running after logout

  next firing
    NEXT                        LEFT LAST PASSED UNIT                 ACTIVATES
    Thu 2026-08-06 00:29:57 UTC  32s -         - restic-station.timer restic-station.service

    1 timers listed.

  last tick activity (from state/ and runs/)
    "Projects": backup just now (2026-08-06T00:29:21Z)
    "Mac Photos Library": backup never
    last run: restore success (just now (2026-08-06T00:29:24Z))

$ loginctl show-user runner --property=Linger
Linger=yes
```

(This particular CI runner happens to have lingering enabled by default — see
[Not executed in CI](#not-executed-in-ci) for what that does and does not settle.)

### A real firing, not just "enabled/active"

`timer status` reporting `enabled`/`active` is not the same thing as a timer actually firing on
its own — the gap `docs/testing.md` and [issue #45](https://github.com/bherila/restic-station/issues/45)
originally called out. CI now checks this directly: install a timer for a dedicated backup set
that has never run before (so `ScheduleMath`'s "never-run is immediately due" rule makes it due
on the very first tick), then poll for up to ~3 minutes without touching anything by hand. Real
output — the timer fired unattended at the 50-second mark and ran a genuine backup:

```
$ restic-station-helper timer install --interval 2
wrote /home/runner/.config/systemd/user/restic-station.service
wrote /home/runner/.config/systemd/user/restic-station.timer
enabled restic-station.timer — ticking every 2min

waiting up to 170s, polling every 10s, for the installed timer to fire on its own:
  t=+ 10s  runs=0
  t=+ 20s  runs=0
  t=+ 30s  runs=0
  t=+ 40s  runs=0
  t=+ 50s  runs=1

$ restic-station-helper runs list --json
[
  {
    "kind" : "backup",
    "runId" : "20260806T003011Z-backup-e1000000",
    "setId" : "E1000000-0000-4000-8000-000000000001",
    "snapshotId" : "7a341607c8e0f92e36c0ceec95d1601144745861b68ab6a7cb3447b55a2c468d",
    "status" : "success",
    "trigger" : "scheduled",
    ...
  }
]

$ journalctl --user -u restic-station.service --no-pager --since -5 minutes
Aug 06 00:30:11 runnervma9114 systemd[1250]: Starting restic-station.service - Restic Station scheduling tick...
Aug 06 00:30:11 runnervma9114 restic-station-helper[3903]: info: restic not configured; discovered /usr/bin/restic (version 0.18.1)
Aug 06 00:30:12 runnervma9114 restic-station-helper[3903]: set "Fire Check": success (1 run)
Aug 06 00:30:12 runnervma9114 systemd[1250]: Finished restic-station.service - Restic Station scheduling tick.
```

`"trigger": "scheduled"` (not `"manual"`) confirms the tick that produced this run really was
invoked by the timer, not by anything in the script calling the helper directly. This is a
genuine, unattended, `OnBootSec=` → due-set discovery → real backup firing, on a real
(non-container) host — see [issue #45](https://github.com/bherila/restic-station/issues/45) for
exactly what this does and does not settle (it does not cover an `OnUnitActiveSec=` repeat
firing, or survival across an actual logout of the account that ran `timer install`).

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

`status`, `runs list`, and `runs show --log` are read-only and safe to run as often as a
monitoring check likes — no restic invocation, no network access. Real output, continuing the
session above (a real backup + mirror copy already ran via `run-set --kind backup`):

```
$ restic-station-helper status
machine "linux-nas" — idle

set "Projects" (f1000000-0000-4000-8000-000000000001)
    last backup: success, 1s ago (20260806T002921Z-backup-f1000000)
    last check:  never
    last prune:  never
    next due:    2026-08-06T00:34:21.599Z
      - primary "NAS Primary": reachable
      - secondary "Offsite Mirror": reachable

excluded here, and why:
  - backup set "Mac Photos Library" is disabled on this machine

$ restic-station-helper status --json
{
  "excludedHere" : [
    {
      "description" : "backup set \"Mac Photos Library\" is disabled on this machine",
      "reason" : "disabledForMachine",
      "subject" : "backupSet",
      ...
    }
  ],
  "health" : "idle",
  "machineId" : "linux-nas",
  "sets" : [
    {
      "lastBackup" : { "runId" : "20260806T002921Z-backup-f1000000", "status" : "success", ... },
      "name" : "Projects",
      "needsAttention" : false,
      ...
    }
  ]
}

$ restic-station-helper runs list
20260806T002922Z-copy-f1000000  copy  success  start=2026-08-06T00:29:22.314Z  end=2026-08-06T00:29:23.708Z
20260806T002921Z-backup-f1000000  backup  success  start=2026-08-06T00:29:21.601Z  end=2026-08-06T00:29:22.310Z
20260806T002918Z-init-f1000000  init  success  start=2026-08-06T00:29:18.582Z  end=2026-08-06T00:29:21.581Z

$ restic-station-helper runs show 20260806T002921Z-backup-f1000000 --log
runId:    20260806T002921Z-backup-f1000000
kind:     backup
setId:    f1000000-0000-4000-8000-000000000001
destId:   f1000000-0000-4000-8000-000000000002
status:   success
trigger:  manual
start:    2026-08-06T00:29:21.601Z
end:      2026-08-06T00:29:22.310Z
snapshot: e0f6f5fd45d8edd8f9cc923a6e81f435639637c8424bd7ce2756c2d422d2ee1a
argv:     -r /tmp/tmp.XXXXXXXXXX/repo-primary backup --json /tmp/tmp.XXXXXXXXXX/source

[00:29:21] $ -r /tmp/tmp.XXXXXXXXXX/repo-primary backup --json /tmp/tmp.XXXXXXXXXX/source
[00:29:21] probe primary "NAS Primary": reachable
[00:29:22] {"message_type":"summary","files_new":2,"files_changed":0,...,"snapshot_id":"e0f6f5fd..."}
```

`status --json` and `runs list --json`/`runs show --json` are documented, stable interfaces
(`docs/data-model.md` §"Headless CLI `--json` shapes") — a script piping one into `jq` is
expected to keep working release to release, the same guarantee `runs/index.jsonl` carries.
`status --json` exits **1** whenever any set needs attention, so it doubles as a Nagios/Icinga
health check with no extra wrapping.

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
ended. Fix: `sudo loginctl enable-linger <user>`, then `restic-station-helper timer status` and
confirm the `linger` line says `enabled`.

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

**"restic not found."** Almost always the distro-package-too-old problem from
[Prerequisites](#prerequisites) — `ResticDiscovery` requires a candidate to actually *run* a
successful `restic version --json` above the 0.17.0 floor, not merely exist and be executable, so
an old or broken binary is reported the same as no binary at all. Real message, from CI's `linux`
job ("restic discovery resolves the helper's binary on Linux" step — no restic anywhere on this
container's `PATH` at all, the simplest case that produces it):

```
restic not found. Searched /usr/bin/restic, /usr/local/bin/restic, /opt/restic/bin/restic, and every directory on PATH.
Install restic (for example `apt install restic` or `dnf install restic`), or set "resticPath" in /tmp/tmp.XXXXXXXXXX/machine.json.
```

Note the message's own example (`apt install restic`) is exactly the command that produces a
too-old binary on Ubuntu/Debian — worth knowing before following it literally; use the [official
release binary](#prerequisites) instead. The message names every location actually searched
(well-known paths, then one `<dir>/restic` per `PATH` entry) and where to set `resticPath`
explicitly (`machine.json`, not `config.json` — a binary path is host-local; see
`docs/architecture.md` §restic discovery) if you need to point at something off the beaten path.

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
- **A `systemd --user` timer surviving an actual logout, or firing repeatedly over hours/days.**
  [A real, unattended `OnBootSec=` firing *is* now observed in CI](#a-real-firing-not-just-enabledactive)
  — that specific gap is closed. What a single ~3-minute CI job cannot show: an
  `OnUnitActiveSec=` repeat firing (the job doesn't wait that long), or the timer surviving the
  account that ran `timer install` actually logging out (the CI job's own session never ends
  mid-run). That longer-horizon verification is tracked in
  [issue #45](https://github.com/bherila/restic-station/issues/45).
