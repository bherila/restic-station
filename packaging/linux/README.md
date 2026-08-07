# Restic Station — Linux headless build

A single, statically-linked `restic-station-helper` binary — the same
scheduling/backup/restore engine as the macOS app, with no GUI, for a NAS,
VPS, or any headless Linux box. No Swift runtime, no glibc, no ICU install
required: `restic-station-helper` is the only thing in this tarball that has
to run, and it runs standalone (see **Static build** below).

Restic Station wraps an off-the-shelf `restic` binary already on the system
— it never bundles or manages restic itself. Install restic first, and note
the minimum version: **restic 0.17.0 or newer** (`docs/restic-cli.md`
§version — it is the first release with the exit-code contract this tool
relies on). Anything older is rejected during discovery, and the helper says
so by name and version — "restic 0.16.4 at /usr/bin/restic is too old" —
rather than the "restic not found" it used to report, which read as nonsense
if you had just installed one (issue #50).

> **Your distro's package is probably too old.** Ubuntu 24.04 LTS ships
> restic **0.16.4**, and Debian stable is comparable. `apt install restic`
> therefore gets you a restic this tool will not use. Prefer the [official
> release binaries](https://github.com/restic/restic/releases):
>
> ```sh
> curl -fsSL -o restic.bz2 \
>   https://github.com/restic/restic/releases/download/v0.18.1/restic_0.18.1_linux_amd64.bz2
> bunzip2 restic.bz2 && sudo install -m 0755 restic /usr/local/bin/restic
> ```
>
> (Swap `amd64` for `arm64` on aarch64.) Check with `restic version`.

If you must use an older restic deliberately, setting `resticPath`
explicitly in `config.json` bypasses the version check — but you are then
outside what this tool is tested against.

## Contents

```
restic-station-helper     the binary (static, no dependencies)
install.sh                installer — see below
LICENSE                   MIT
README.md                 this file
systemd/
  restic-station.service  reference copy of the unit `timer install` writes
  restic-station.timer    (ExecStart=<HELPER_PATH> is a placeholder here —
                           `timer install` fills in this binary's real path)
```

## Install

```sh
./install.sh              # ~/.local/bin, no root needed
./install.sh --system      # /usr/local/bin (needs write access, e.g. sudo)
./install.sh --prefix=/opt/restic-station/bin
```

Safe to re-run any time (idempotent — it just overwrites the one file it
installs). If the chosen prefix is not already on your `PATH`, `install.sh`
tells you and prints the line to add to your shell profile.

## First run

1. Confirm restic is on `PATH`: `restic version` — 0.17.0 is the minimum,
   0.18 or newer is recommended (see the version note above; the distro
   package is very likely too old).
2. Get a `config.json` onto this machine. Two ways:
   - **Moved from another machine** (the headline M5 story — author backup
     sets on the Mac app, then bring the same fleet-wide config here):
     ```sh
     restic-station-helper config import /path/to/exported-config.json
     ```
     This never touches secrets — passwords are never in `config.json`, so
     the next step is still required on *every* machine.
   - **Written by hand** at `$XDG_STATE_HOME/restic-station/config.json`
     (falls back to `~/.local/state/restic-station/config.json`) — see
     `docs/data-model.md` in the source repository for the schema.
3. Store each destination's password (never on the command line — reads
   from stdin). Prefer the interactive form, which leaves no trace in your
   shell history:
   ```sh
   restic-station-helper secret set --dest <destination-id>
   ```
   For scripted setup, pipe it in — but note that typing the password
   inline persists it to `~/.bash_history`, so read it from a file or a
   secret manager instead:
   ```sh
   your-secret-manager get repo-password | restic-station-helper secret set --dest <destination-id>
   ```
4. Check what will actually run on *this* machine before scheduling
   anything — this also explains any set or destination that per-machine
   config scoping excludes here:
   ```sh
   restic-station-helper config validate
   ```
5. Schedule it:
   ```sh
   restic-station-helper timer install
   ```
   Installs and enables a `systemd --user` timer that fires `tick` every 2
   minutes (`--interval` to change it); `tick` itself decides what is
   actually due. On a host without a systemd user session, `timer install`
   prints a ready-to-paste `crontab -e` line instead of failing opaquely.

   **Headless/NAS note:** systemd stops a user's units on logout unless
   lingering is enabled. `timer install` checks this and warns with the
   exact fix (`loginctl enable-linger <user>`) if it is not already on.

6. `restic-station-helper status` any time to see backup health; `runs
   list` / `runs show <id>` for history.

## Static build — what "no dependencies" means here

This binary is built with Apple's Static Linux SDK (Swift + musl libc),
statically linked end to end: no libc, no Swift runtime, no ICU shared
library. `ldd restic-station-helper` reports "not a dynamic executable", and
it has been verified to run unmodified in a `scratch` container, on Debian
stable, and on a deliberately old-glibc distro — the whole point of a static
build is that the host's glibc version (or its absence, as in `scratch`)
never matters. See the upstream repository's `docs/testing.md` for exactly
which environments CI exercises this in, and the exact toolchain/SDK version
pinned by `scripts/setup-static-linux-sdk.sh`.

## Uninstall

```sh
restic-station-helper timer uninstall   # first, while the binary still exists
rm ~/.local/bin/restic-station-helper   # or /usr/local/bin, per your install
```

`config.json`, `machine.json`, `secrets.json` and all state/run history live
under `$XDG_STATE_HOME/restic-station` (default
`~/.local/state/restic-station`) — remove that directory too if you want a
clean slate. It is never touched by `install.sh` or `timer uninstall`.
