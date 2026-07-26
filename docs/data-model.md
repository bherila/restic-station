# Data model

All persisted JSON uses `JSONEncoder` with `.sortedKeys` + `.prettyPrinted` (except JSONL lines: compact, one per line) and ISO 8601 dates (`.iso8601` with fractional seconds encoder/decoder). All writes are atomic: write to a temp file in the same directory, then `rename(2)` over the target.

## config.json — `AppConfig`

```json
{
  "version": 1,
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
    public var version: Int            // = 1; bump on breaking schema change
    public var resticPath: String?     // nil = not yet discovered
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
}

public struct Destination: Codable, Equatable, Identifiable {
    public var id: UUID                    // keychain key — never regenerate
    public var label: String
    public var repoURL: String             // restic -r value, verbatim
    public var isPrimary: Bool
    public var nonSecretEnv: [String: String]  // extra env, non-secret only

    public var kind: DestinationKind { /* derived, not encoded */ }
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

### Invariants (enforced by `AppConfig.validate() throws`, called on every save and after load)

1. Each set has **exactly one** destination with `isPrimary == true`.
2. Set and destination UUIDs are unique across the whole config.
3. `sources` non-empty for every set; every source is an absolute path.
4. `Schedule` fields in range (minute 0–59, hour 0–23, weekday 1–7, everyMinutes ≥ 5).
5. `stalenessWarningDays ≥ 1`; `readDataSubsetSlices` in 2...100.

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

## Versioning & migration

`AppConfig.version` starts at 1. Loader behavior: version > current → refuse with clear error ("config written by a newer Restic Station"); version < current → run in-code migration chain then save. State/run files carry no version field — they are regenerable caches/history; on decode failure, skip the record and log, never crash.
