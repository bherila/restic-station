# Data model

All persisted JSON uses `JSONEncoder` with `.sortedKeys` + `.prettyPrinted` (except JSONL lines: compact, one per line) and ISO 8601 dates (`.iso8601` with fractional seconds encoder/decoder). All writes are atomic: write to a temp file in the same directory, then `rename(2)` over the target.

Two files hold configuration, and the split matters:

| File | Scope | Shared? |
|---|---|---|
| `config.json` | every backup set, destination, schedule and retention policy | **Yes** — one file, the same on every machine |
| `machine.json` | this host's identity and its restic binary path | **No — never copy it between machines** |

`config.json` is the file a user syncs, exports, or checks into a private repo. `machine.json` is what tells a given host *which* of that shared config applies to it. See §machine.json and §Per-machine scoping.

## config.json — `AppConfig`

The example below is a schema-v2 config with **no** `machines` keys — the shape most installs have, and the one the compatibility guarantee is about: absent `machines` means inherit and run everywhere. `resticPath` is shown for completeness; it is deprecated (see §machine.json) and migration clears it.

```json
{
  "version": 2,
  "resticPath": "/opt/homebrew/bin/restic",
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "Projects",
      "sources": ["/Users/user/proj", "/Users/user/.gitconfig"],
      "excludes": ["node_modules", ".build", "*.tmp"],
      "schedule": { "kind": "daily", "hour": 2, "minute": 30 },
      "retention": {
        "keepLast": null, "keepHourly": null, "keepDaily": 7,
        "keepWeekly": 4, "keepMonthly": 12, "keepYearly": 2
      },
      "checkPolicy": { "enabled": true, "readDataSubsetSlices": 20 },
      "stalenessWarningDays": 14,
      "destinations": [
        {
          "id": "0A1B2C3D-...-PRIMARY",
          "label": "iCloud",
          "repoURL": "/Users/user/Library/Mobile Documents/com~apple~CloudDocs/Backups/proj.restic",
          "isPrimary": true,
          "nonSecretEnv": {}
        },
        {
          "id": "1B2C3D4E-...-MIRROR1",
          "label": "R2 mirror",
          "repoURL": "s3:https://accountid.r2.cloudflarestorage.com/my-bucket/proj",
          "isPrimary": false,
          "nonSecretEnv": { "AWS_DEFAULT_REGION": "auto" }
        },
        {
          "id": "2C3D4E5F-...-MIRROR2",
          "label": "External HDD",
          "repoURL": "/Volumes/BackupDisk/proj.restic",
          "isPrimary": false,
          "nonSecretEnv": {}
        }
      ]
    }
  ]
}
```

### Swift types (Core/Sources/ResticStationCore/Config/Models.swift)

```swift
public struct AppConfig: Codable, Equatable {
    public var version: Int            // = 2; bump on breaking schema change
    public var resticPath: String?     // DEPRECATED — see machine.json; nil = not set
    public var showMenuBarIcon: Bool   // default true
    public var sets: [BackupSet]
}

public struct BackupSet: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var sources: [String]           // absolute paths
    public var excludes: [String]          // restic --exclude patterns
    public var schedule: Schedule
    public var retention: RetentionPolicy? // nil = never forget
    public var checkPolicy: CheckPolicy?   // nil = no scheduled checks
    public var stalenessWarningDays: Int   // default 14
    public var destinations: [Destination] // invariant: exactly one isPrimary
    public var machines: [String: BackupSetMachineOverride]?  // v2; nil = runs everywhere
}

public struct Destination: Codable, Equatable, Identifiable {
    public var id: UUID                    // keychain key — never regenerate
    public var label: String
    public var repoURL: String             // restic -r value, verbatim
    public var isPrimary: Bool
    public var nonSecretEnv: [String: String]  // extra env, non-secret only
    public var machines: [String: DestinationMachineOverride]?  // v2; nil = used everywhere

    public var kind: DestinationKind { /* derived, not encoded */ }
}

// Per-machine overrides (v2). Keyed by MachineConfig.machineId.
// Every field is optional; nil = inherit. Overrides REPLACE, never merge.
public struct BackupSetMachineOverride: Codable, Equatable {
    public var enabled: Bool?          // false = skip this set entirely on this machine
    public var sources: [String]?      // replaces BackupSet.sources wholesale
    public var schedule: Schedule?     // replaces BackupSet.schedule
}

public struct DestinationMachineOverride: Codable, Equatable {
    public var enabled: Bool?          // false = this machine never uses this destination
    public var repoURL: String?        // replaces Destination.repoURL
    public var nonSecretEnv: [String: String]?  // replaces Destination.nonSecretEnv wholesale
}

public enum DestinationKind: Equatable {
    case localPath      // no scheme prefix; includes /Volumes/... and iCloud paths
    case sftp           // "sftp:" prefix
    case rest           // "rest:" prefix
    case s3             // "s3:" prefix (AWS or any S3-compatible endpoint, e.g. R2)
    case otherCloud     // b2:, azure:, gs:, swift:, rclone:
}

public enum Schedule: Codable, Equatable {
    case everyMinutes(Int)                       // {"kind":"everyMinutes","minutes":30}
    case hourly(minute: Int)                     // {"kind":"hourly","minute":15}
    case daily(hour: Int, minute: Int)           // {"kind":"daily","hour":2,"minute":30}
    case weekly(weekday: Int, hour: Int, minute: Int) // weekday 1=Sunday…7=Saturday (Calendar convention)
}

public struct RetentionPolicy: Codable, Equatable {
    public var keepLast: Int?
    public var keepHourly: Int?
    public var keepDaily: Int?
    public var keepWeekly: Int?
    public var keepMonthly: Int?
    public var keepYearly: Int?
    public var isEmpty: Bool { /* all nil */ }   // engine refuses to forget with empty policy
}

public struct CheckPolicy: Codable, Equatable {
    public var enabled: Bool
    public var readDataSubsetSlices: Int   // t in --read-data-subset=n/t; default 20
}
```

`Schedule` encodes with a `kind` discriminator (custom Codable). Unknown `kind` on decode → throw (config version gates compatibility).

**Encoding conventions.** Optionals are encoded as explicit JSON `null` (never omitted) so the file stays diffable — with two deliberate exceptions, both about *absence being meaningful*: `onboardingCompleted`, and every `machines` key (on sets, on destinations, and on the fields inside an override). Absent `machines` means "runs everywhere", so a config with no per-machine overrides — which is every config written before v2, and most configs after it — is byte-identical apart from its `version` number instead of gaining a `"machines": null` on every set and destination. Inside an override, `"sources": null` would read like "override to no sources" when it means the opposite, so sparse overrides are written sparsely.

### Invariants (enforced by `AppConfig.validate() throws`, called on every save and after load)

1. Each set has **exactly one** destination with `isPrimary == true`.
2. Set and destination UUIDs are unique across the whole config.
3. `sources` non-empty for every set; every source is an absolute path.
4. `Schedule` fields in range (minute 0–59, hour 0–23, weekday 1–7, everyMinutes ≥ 5).
5. `stalenessWarningDays ≥ 1`; `readDataSubsetSlices` in 2...100.
6. Every `machines` key is a valid `machineId` (see §machine.json for the charset), and every value an override supplies gets the same check as the field it replaces: override `sources` entries must be absolute, an override `schedule` must be in range. **Exception:** an override `sources` of `[]` is legal where a top-level `[]` is not — it is how a machine says "nothing to back up here", and resolution drops the set with a recorded reason rather than running a source-less backup.
7. **Per machine:** if a set runs on a machine, exactly one of its destinations must be a primary that is enabled there. Disabling the primary is never a valid way to say "do not run here" — disable the whole set for that machine instead. Checked for every `machineId` the config mentions; machines with no overrides see the shared values, which invariant 1 already covers.

A `machines` key that no `machine.json` in the fleet claims is **not** an error — machines come and go, and the config is shared. It is a warning surfaced by `config validate` (T27).

## machine.json — `MachineConfig`

```json
{ "version": 1, "machineId": "studio-mac", "resticPath": "/usr/bin/restic" }
```

```swift
public struct MachineConfig: Codable, Equatable {
    public static let currentVersion = 1     // versioned independently of AppConfig
    public var version: Int
    public var machineId: String             // the key config.json's `machines` maps use
    public var resticPath: String?           // this host's restic binary; nil = fall back
}
```

**Never copy this file between machines.** Two hosts sharing a `machineId` both claim the same overrides, which means the second one silently backs up the first one's directories. If you rsync a data directory to a new host, delete `machine.json` there and let it regenerate. (`config.json` is the file that is *meant* to be shared.)

- **`machineId`** is generated on first load from the hostname: lowercase, every character outside `[a-z0-9-]` becomes `-`, runs of `-` collapse, leading/trailing `-` are trimmed. `Studio-Mac.local` → `studio-mac-local`. The hostname's dots are not special-cased into a domain strip — that would be a guess, and a `machineId` is a stable key. If the hostname is empty or slugifies to nothing, a fresh lowercased UUID is used instead (itself a valid slug). Rename it by hand whenever you like; it is just a key.
- **Validation:** non-empty and `[a-z0-9-]` only. A file with an invalid `machineId`, or one written by a newer build, is a hard error rather than a silent regeneration — a `machineId` that matches no `machines` key resolves to "no overrides", which is exactly the silent-wrong-backup failure this design exists to prevent.
- **`RESTIC_STATION_MACHINE_ID`**, when set and non-empty, replaces the `machineId` for that process. It is applied after the file is read and is never written back, so it is safe for tests and for a user who wants two profiles on one host.
- **`resticPath`** lives here because a binary path is inherently host-local. `AppConfig.resticPath` remains in the schema as a deprecated fallback (see §Versioning & migration); the helper's full resolution order is `machine.json` → `AppConfig.resticPath` → discovery.
- **Auto-creation** on first load is best-effort: a host whose data directory is not writable still gets a usable identity in memory, and the generated id is a deterministic function of the hostname, so it stays stable across runs anyway.

## Per-machine scoping

One `config.json` describes the whole fleet. Each machine reads it through `AppConfig.resolved(for:)`, which produces a `ResolvedConfig`: an effective, **override-free** `AppConfig` plus the list of things this machine does not act on and why.

**Resolution happens once, at load.** `BackupEngine`, `ScheduleMath`, `RunStore`, the helper subcommands and the app's health derivation all consume the resolved config and never see a `machineId`. Every `machines` map is stripped from the resolved value, so it cannot be resolved twice, and cannot be saved back over the shared file's overrides.

### The algorithm

For each set, in config order:

1. Start from the top-level values.
2. Apply `set.machines[machineId]` if present — **replacing** each field it specifies. An override `sources` array replaces the top-level array wholesale; it is never merged. (Merging produces surprising unions and offers no way to express a removal.)
3. Drop the set if its effective `enabled` is `false`. Nothing about its destinations is even evaluated.
4. For each destination, in config order: apply `destination.machines[machineId]` the same way, and drop the destination if its effective `enabled` is `false`.
5. Drop the set if it ends up with zero enabled destinations, or with zero sources while still enabled.

Every drop in 3–5 is recorded as a `ResolvedOmission` (`disabledForMachine` | `noEnabledDestinations` | `noSources`) so the CLI can *explain* the omission instead of silently doing nothing. `tick` prints one line per omission.

Absent `machines`, or no entry for this machine, means **inherit and run**. That is why an existing single-machine setup behaves exactly as it did before v2, and why adding a second machine is purely additive.

**Resolution depends only on `machineId`, never on the host OS.** There is no platform branch, no filesystem access and no environment lookup in it: `config.resolved(for: "linux-nas")` returns the same bytes whether it runs on macOS or on Linux. A test asserts this on both platforms.

Automatic path rewriting (`/Users/bwh` → `/home/bwh`) was considered and **rejected**: it is implicit, silently wrong at the edges, and backups are the wrong place for magic. Per-machine overrides are explicit.

### Worked example 1 — Linux as a source

The NAS backs up its own directories, on its own schedule, to its own copy of the repository. The Mac's external scratch drive is not something the NAS can see, so it is disabled there.

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
    { "id": "0A1B…0001", "label": "Big Drive", "repoURL": "/Volumes/Big/docs.restic", "isPrimary": true,
      "machines": { "linux-nas": { "repoURL": "/mnt/big/docs.restic" } } },
    { "id": "2C3D…0003", "label": "Scratch HDD", "repoURL": "/Volumes/Scratch/docs", "isPrimary": false,
      "machines": { "linux-nas": { "enabled": false } } }
  ]
}]
```

| | `studio-mac` | `linux-nas` | `old-laptop` |
|---|---|---|---|
| Set runs? | yes | yes | **no** (`disabledForMachine`) |
| `sources` | `/Users/bwh/Documents` | `/srv/data` | — |
| `schedule` | daily 02:30 | daily 04:00 | — |
| Primary `repoURL` | `/Volumes/Big/docs.restic` | `/mnt/big/docs.restic` | — |
| Scratch HDD | used | **dropped** (`disabledForMachine`) | — |

### Worked example 2 — Linux as a mirror/restore target only

A host that stores copies and can restore from them, but has nothing of its own to back up. Every set is disabled there; the machine still reads the same `config.json`, so `restore`, `probe-repo` and `unlock` know every repository — it simply never runs a backup.

```json
"sets": [
  { "id": "…", "name": "Documents", "machines": { "mirror-box": { "enabled": false } }, "…": "…" },
  { "id": "…", "name": "Photos",    "machines": { "mirror-box": { "enabled": false } }, "…": "…" }
]
```

`tick` on `mirror-box` prints one `skipping backup set "…" is disabled on this machine` line per set and exits 0. Note the alternative spelling — disabling every *destination* instead — is rejected by invariant 7: it would leave a set that runs with no primary to write to, which is the silent failure the invariant exists to catch.

## Keychain items (see keychain-and-fda.md for access mechanics)

| Item | Service | Account | Value |
|---|---|---|---|
| Repo password | `restic-station` | `<destination UUID lowercased>` | the restic repository password (UTF-8) |
| Secret env | `restic-station` | `<destination UUID lowercased>-env` | JSON object of secret env vars, e.g. `{"AWS_ACCESS_KEY_ID":"…","AWS_SECRET_ACCESS_KEY":"…"}` |

Secret-env item is optional (absent for local/sftp destinations without credentials). Non-secret env (region names, endpoint hints) lives in `Destination.nonSecretEnv` in config.json. When both define the same key, the keychain value wins.

## runs/index.jsonl — one compact line per finished run

```json
{"runId":"20260726T205704Z-backup-6f9619ff","kind":"backup","setId":"6F9619FF-...","destId":"0A1B2C3D-...","status":"success","start":"2026-07-26T20:57:04Z","end":"2026-07-26T20:58:11Z","trigger":"scheduled","snapshotId":"f391ba97c096...","filesNew":3,"filesChanged":1,"dataAdded":67860,"errorSummary":null}
```

`kind`: `backup` | `copy` | `check` | `prune` | `restore` | `init`. A scheduled set run produces **multiple** index lines: one `backup` (primary), one `copy` per attempted secondary, one `prune` per repo where retention ran. They share a `groupId` field (= the backup's runId) so the UI can nest them.

## runs/<runId>/metadata.json — `RunMetadata`

Superset of the index line, plus: `pid`, `resticExitCode`, `argvRedacted` (argv with env not included), `stats` (full decoded summary message where applicable), `groupId`. Written once at start (`status: "running"`, no `end`) and atomically rewritten on completion.

## state/schedule-state.json

```json
{
  "sets": {
    "6F9619FF-...": {
      "lastBackupStart": "2026-07-26T20:57:04Z",
      "lastCheckStart": "2026-07-20T03:00:00Z",
      "checkSliceCursor": 7
    }
  }
}
```

`lastBackupStart` is the *start* time of the last **attempted** scheduled backup (success or failure) — due-computation keys off attempts, so a failing set retries at its next slot, not every tick. Manual runs also update it (a manual backup satisfies the schedule). `checkSliceCursor` is the `n` most recently used in `--read-data-subset=n/t`.

## state/repo-status-<destId>.json

```json
{
  "destId": "1B2C3D4E-...",
  "reachable": false,
  "probedAt": "2026-07-26T20:57:10Z",
  "lastSyncedAt": "2026-07-12T02:31:00Z",
  "lastError": null
}
```

`lastSyncedAt` for a secondary = end time of the last successful `copy`. For the primary = end of last successful `backup`. Staleness (UI + menubar warning): `now − lastSyncedAt > stalenessWarningDays`.

## state/current-run-<setId>.json (live progress; deleted when the run group finishes)

```json
{
  "runId": "20260726T205704Z-backup-6f9619ff",
  "kind": "backup",
  "phase": "backing-up-primary",
  "percentDone": 0.42,
  "bytesDone": 1234567,
  "totalBytes": 987654321,
  "filesDone": 120,
  "totalFiles": 4000,
  "currentFiles": ["/Users/user/proj/big.dat"],
  "updatedAt": "2026-07-26T20:57:30Z"
}
```

`phase`: `probing` | `backing-up-primary` | `copying-<destId>` | `retention` | `checking`.

## state/fda-check.json

```json
{ "checkedAt": "2026-07-26T20:57:00Z", "hasFullDiskAccess": true, "probedPath": "~/Library/Safari", "context": "launchd" }
```

**macOS only, and absence is meaningful.** The file is written only by the macOS `fda-check` probe; on other platforms the subcommand writes nothing at all. An absent file means "not applicable / not yet known", **never** "denied" — see `keychain-and-fda.md` §2 for the normative rule and `HealthDerivation.fullDiskAccessDenied(from:)` for its single implementation.

## Versioning & migration

`AppConfig.currentVersion` is **2**. Loader behavior: version > current → refuse with a clear error ("config written by a newer Restic Station"); version < current → run the in-code migration chain, then persist. State/run files carry no version field — they are regenerable caches/history; on decode failure, skip the record and log, never crash. `machine.json` versions independently (`MachineConfig.currentVersion`, currently 1).

### v1 → v2

The schema change needs no data change: an absent `machines` key already means "runs everywhere", so a v1 config *is* a valid v2 config once the version number is bumped. Exactly one value moves.

`ConfigStore.load()` of a `version: 1` file:

1. Adds **no** `machines` keys.
2. If `config.json` has a `resticPath` and `machine.json` has none, moves it into `machine.json` and clears the deprecated field. If `machine.json` already has one, that one wins and the deprecated field is still cleared. If the write fails, `resticPath` is left in `config.json`, where it still works as the documented fallback.
3. Copies the untouched v1 bytes to **`config.v1.backup.json`**, beside `config.json`, with `O_EXCL` — **never** overwriting an existing backup, so a second migration cannot clobber the first one's copy (or a copy the user put there by hand).
4. Only if that backup exists, writes the v2 config atomically.
5. Sets `version: 2` and returns.

Migration is **idempotent**: the second load sees `version: 2` and does nothing. Every persistence step is best-effort — a data directory that cannot be written must not stop the helper from running backups, and the migration is a pure function of the file, so an unwritten migration simply reruns next load. What is *not* best-effort is the ordering: **the v1 file is never overwritten unless a backup of it exists.**

A v1 config that fails `validate()` at its own version is a hard error: it produces no backup file and no rewritten `config.json`.

The net effect on an existing single-machine install is that `"version": 1` becomes `"version": 2`, `"resticPath"` becomes `null`, and everything the engine acts on — sources, destinations, schedules, retention, the effective restic binary — is unchanged.
