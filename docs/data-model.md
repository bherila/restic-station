# Data model

All persisted JSON uses `JSONEncoder` with `.sortedKeys` + `.prettyPrinted` (except JSONL lines: compact, one per line) and ISO 8601 dates (`.iso8601` with fractional seconds encoder/decoder). All writes are atomic: write to a temp file in the same directory, then `rename(2)` over the target. Safety-authoritative schedule state additionally completes the temp write, `fsync`s it, renames through a held directory descriptor, and `fsync`s the directory before reporting success.

Two files hold configuration, and the split matters:

| File | Scope | Shared? |
|---|---|---|
| `config.json` | every backup set, destination, schedule and retention policy | **Yes** — one file, the same on every machine |
| `machine.json` | this host's identity and its restic binary path | **No — never copy it between machines** |

`config.json` is the file a user syncs, exports, or checks into a private repo. `machine.json` is what tells a given host *which* of that shared config applies to it. See §machine.json and §Per-machine scoping.

Every Restic Station writer serializes `config.json` through `locks/config.lock`. The app also saves with compare-and-swap semantics: an editor carries the byte fingerprint it loaded, and the save is refused if the on-disk fingerprint has changed. A fleet-sync replacement therefore remains intact and is surfaced in the UI for explicit reload; it is never silently overwritten by a stale draft.

## config.json — `AppConfig`

The example below is a schema-v3 config with **no** `machines` keys — the shape most installs have, and the one the compatibility guarantee is about: absent `machines` means inherit and run everywhere. `resticPath` is shown for completeness; it is deprecated (see §machine.json) and migration clears it.

```json
{
  "version": 3,
  "resticPath": "/opt/homebrew/bin/restic",
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "Projects",
      "sources": ["/Users/user/proj", "/Users/user/.gitconfig"],
      "excludes": ["node_modules", ".build", "*.tmp"],
      "purgeExcludes": ["DerivedData"],
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
    public var version: Int            // = 3; bump on breaking schema change
    public var resticPath: String?     // DEPRECATED — see machine.json; nil = not set
    public var showMenuBarIcon: Bool   // default true
    public var sets: [BackupSet]
}

public struct BackupSet: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var sources: [String]           // absolute paths
    public var excludes: [String]          // restic --exclude patterns
    public var purgeExcludes: [String]     // history-affecting restic --exclude patterns (v3)
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
    public var remoteMaintenance: RemoteMaintenance? // sftp-only remote prune settings

    public var kind: DestinationKind { /* derived, not encoded */ }
}

public struct RemoteMaintenance: Codable, Equatable {
    public var enabled: Bool
    public var sshTarget: String?       // default: target parsed from sftp URL
    public var remoteRepoPath: String?  // default: path parsed from sftp URL
    public var remoteResticPath: String? // default: "restic"
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

**Encoding conventions.** Optionals are encoded as explicit JSON `null` (never omitted) so the file stays diffable — with two deliberate exceptions, both about *absence being meaningful*: `onboardingCompleted`, and every `machines` key (on sets, on destinations, and on the fields inside an override). `purgeExcludes` is non-optional and always encoded, including as `[]`; missing or explicit `null` decodes as `[]` solely for pre-v3 compatibility. Absent `machines` means "runs everywhere", so a config with no per-machine overrides — which is every config written before v2, and most configs after it — is byte-identical apart from its `version` number instead of gaining a `"machines": null` on every set and destination. Inside an override, `"sources": null` would read like "override to no sources" when it means the opposite, so sparse overrides are written sparsely.

### Invariants (enforced by `AppConfig.validate() throws`, called on every save and after load)

1. Each set has **exactly one** destination with `isPrimary == true`.
2. Set and destination UUIDs are unique across the whole config.
3. `sources` non-empty for every set; every source is an absolute path.
4. `Schedule` fields in range (minute 0–59, hour 0–23, weekday 1–7, everyMinutes ≥ 5).
5. Every `purgeExcludes` pattern is non-empty. A blank plain `excludes` entry is harmless noise, but a blank pattern must never become a history-changing purge rule.
6. `stalenessWarningDays ≥ 1`; `readDataSubsetSlices` in 2...100.
7. Every `machines` key is a valid `machineId` (see §machine.json for the charset), and every value an override supplies gets the same check as the field it replaces: override `sources` entries must be absolute, an override `schedule` must be in range. **Exception:** an override `sources` of `[]` is legal where a top-level `[]` is not — it is how a machine says "nothing to back up here", and resolution drops the set with a recorded reason rather than running a source-less backup.
8. **Per machine:** if a set runs on a machine, exactly one of its destinations must be a primary that is enabled there. Disabling the primary is never a valid way to say "do not run here" — disable the whole set for that machine instead. Checked for every `machineId` the config mentions; machines with no overrides see the shared values, which invariant 1 already covers.

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
- **`RESTIC_STATION_MACHINE_ID`**, when set and non-empty, replaces the `machineId` for that process. It is applied after the file is read and **is never written back**, so it is safe for tests and for a user who wants two profiles on one host.

  Every write to `machine.json` that is not *creating or deliberately renaming* an identity must go through **`MachineStore.savePreservingIdentity(_:)`**, which re-reads the on-disk `machineId` and keeps it whatever the value it is handed says. `MachineStore.save(_:)` writes its argument verbatim and is only for those two identity cases; `MachineStore.persistentIdentity(paths:)` is the override-blind store the former builds on.

  The rule matters because the damage outlives the variable: a load-mutate-save round trip through the override-aware store bakes a temporary profile id into the file, and the host then keeps resolving that profile's `machines` overrides forever after — silently backing up the wrong sources, or nothing at all, unattended. It is also reached without anyone asking to save: restic discovery fires from the Settings pane's `.task` and persists whatever it finds.
- **`resticPath`** lives here because a binary path is inherently host-local. `AppConfig.resticPath` remains in the schema as a deprecated fallback (see §Versioning & migration); the helper's full resolution order is `machine.json` → `AppConfig.resticPath` → discovery.
- **Auto-creation** on first load is best-effort: a host whose data directory is not writable still gets a usable identity in memory, and the generated id is a deterministic function of the hostname, so it stays stable across runs anyway.

## Per-machine scoping

One `config.json` describes the whole fleet. Each machine reads it through `AppConfig.resolved(for:)`, which produces a `ResolvedConfig`: an effective, **override-free** `AppConfig` plus the list of things this machine does not act on and why.

**Resolution happens once, at load.** `BackupEngine`, `ScheduleMath`, `RunStore`, the helper subcommands and the app's health derivation all consume the resolved config and never see a `machineId`. Every `machines` map is stripped from the resolved value, so it cannot be resolved twice, and cannot be saved back over the shared file's overrides.

### Two views

"What do I back up here?" and "which repositories can I address from here?" are different questions, and answering the second with the first is a real bug — so there are two named accessors, and `ResolvedConfig.scope` says which one a value is.

| | `AppConfig.resolved(for:)` — `.scheduling` | `AppConfig.addressable(for:)` — `.addressable` |
|---|---|---|
| Overrides applied | yes | yes |
| `enabled: false` drops things | **yes** | **no** |
| `omissions` | populated | always empty |
| Used by | `tick`, `run-set` (backup/check/prune), health/staleness derivation | `restore`, `probe-repo`, `unlock`, `init-secondary`, the restore browser, maintenance sizes and `forget --dry-run`, "Initialize repository" |

`enabled: false` means "do not back this up here". It does not mean "pretend this repository does not exist": a host set up as a restore/mirror target by disabling every set must still be able to restore from, probe, and unlock every repository in the shared config — that is the whole point of the arrangement. Both views apply *identical* overrides, so they can never disagree about what a repository **is**, only about which ones this machine backs up.

Anything that builds a restic invocation must go through one of these two views. Reading the raw `AppConfig` there would address the *shared* `repoURL` rather than this machine's — browsing, measuring, or initialising a different repository than the one the scheduler writes to.

### The algorithm

For each set, in config order:

1. Start from the top-level values.
2. Apply `set.machines[machineId]` if present — **replacing** each field it specifies. An override `sources` array replaces the top-level array wholesale; it is never merged. (Merging produces surprising unions and offers no way to express a removal.)
3. Drop the set if its effective `enabled` is `false`. Nothing about its destinations is even evaluated.
4. For each destination, in config order: apply `destination.machines[machineId]` the same way, and drop the destination if its effective `enabled` is `false`.
5. Drop the set if it ends up with zero enabled destinations, or with zero sources while still enabled.

Steps 3–5 are the `.scheduling` view only; `.addressable` stops after step 2 (plus the destination-override half of step 4).

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

`tick` on `mirror-box` prints one `skipping backup set "…" is disabled on this machine` line per set and exits 0.

**Everything else still works there**, because every repository utility reads the `.addressable` view: `restore --set … --dest …` finds its repository, `probe-repo` reports reachability, `unlock` clears a stale lock, and the app's Restore and Maintenance screens list and measure all of it. Only backing up is off. A host whose `machines` entries also override `repoURL` gets those overrides in both views, so what the Restore browser lists is the same repository the scheduler writes to.

Note the alternative spelling — disabling every *destination* instead — is rejected by invariant 7: it would leave a set that runs with no primary to write to, which is the silent failure the invariant exists to catch.

## Keychain items (see keychain-and-fda.md for access mechanics)

| Item | Service | Account | Value |
|---|---|---|---|
| Repo password | `restic-station` | `<destination UUID lowercased>` | the restic repository password (UTF-8) |
| Secret env | `restic-station` | `<destination UUID lowercased>-env` | JSON object of secret env vars, e.g. `{"AWS_ACCESS_KEY_ID":"…","AWS_SECRET_ACCESS_KEY":"…"}` |

Secret-env item is optional (absent for local/sftp destinations without credentials). Non-secret env (region names, endpoint hints) lives in `Destination.nonSecretEnv` in config.json. When both define the same key, the keychain value wins.

## runs/index.jsonl — one compact line per finished run

```json
{"runId":"20260726T205704Z-backup-6f9619ff","kind":"backup","setId":"6F9619FF-...","destId":"0A1B2C3D-...","status":"success","start":"2026-07-26T20:57:04Z","end":"2026-07-26T20:58:11Z","trigger":"scheduled","snapshotId":"f391ba97c096...","filesNew":3,"filesChanged":1,"dataAdded":67860,"errorSummary":null,"purgeEvidenceDigest":null}
```

`kind`: `backup` | `copy` | `check` | `prune` | `purge` | `restore` | `init`.
A scheduled set run produces **multiple** index lines: one `backup` (primary),
one `purge` per applicable destination whenever active `purgeExcludes` exist
(one per destination whose watermark still has that pattern pending), one
`copy` per attempted secondary,
and one `prune` per repo where retention ran. They share a `groupId` field (=
the backup's runId) so the UI can nest them. A purge whose launch carries
recovery evidence also projects `purgeEvidenceDigest`, a SHA-256 binding over
a versioned, length-framed sequence of its repository config id, exact purge
patterns, and sorted terminal old-to-new snapshot mapping; other and legacy
records encode it as `null`. Audit verification recomputes this digest from
canonical metadata, so changing any recovery field without the independently
published index line is an audit mismatch and cannot authorize a watermark
shortcut. Each append uses a complete-write loop that retries `EINTR`, then
`fsync`s the index (also retrying `EINTR`) before releasing `index.jsonl.lock`;
creation of the first index also syncs the `runs/` directory entry. Before
appending, the writer reads only the final byte in the normal newline-terminated
case. An unterminated corrupt tail triggers a bounded backward scan and is
truncated to the last complete line (or a complete newline-less JSON record is
terminated), so a recovery line cannot be concatenated onto corrupt JSON
without making every normal append reread the full history. Recovery performs
that repair before decoding its index snapshot, so a torn multibyte UTF-8
scalar cannot hide or duplicate the valid prefix. Decoding happens
independently at byte-line boundaries, preserving valid records on either side
of a newline-terminated line with invalid UTF-8. History readers take the last
decodable projection for each run and order runs by canonical start time; an
older repaired record therefore cannot masquerade as the latest run.

## runs/<runId>/metadata.json — `RunMetadata`

Canonical superset of the index data, plus: `pid`, `resticExitCode`, `argvRedacted` (argv with env not included), `stats` (full decoded summary message where applicable), `destructiveAuditContractVersion`, `destructiveLaunchAuthorizedAt`, `auditFailureReason`, the optional two-phase marker `indexPublicationPending`, and `publicationDurabilityContractVersion`. The index's `purgeEvidenceDigest` is recomputed from the canonical source fields rather than duplicated here. A purge launch additionally binds its exact `purgePatterns` and the live restic config id as `purgeRepositoryId`; a successful purge carries `purgeSnapshotRewrites`, a complete launch-time repository generation mapping from every old full snapshot id to its resulting short id. Restic omits per-snapshot output for a selected snapshot that is already a no-op, so that entry maps the old full id to its own unchanged short id; unattributed snapshots receive the same identity representation without entering the destructive argv. An exit-0 rewrite whose modified count and changed mappings cannot establish this complete result is recorded as `repository_outcome_unknown` and blocks another destructive launch. The mapping is an audit record of what a destructive rewrite actually did. It is **not** consumed as authority to advance a watermark: a lost watermark heals by re-running the pending rewrite, which restic reports as a no-op. The recovery fields remain bound into `purgeEvidenceDigest` so terminal evidence stays tamper-evident. Metadata is written once at start (`status: "running"`, no `end`) and atomically rewritten on completion. The temp file is completely written, `fsync`ed, and renamed with `renameat(2)` against a held directory descriptor; the containing directory is then `fsync`ed before success is reported. A newly created run directory is likewise made durable in `runs/` before `begin` returns. On a fresh hierarchy, every newly created `runs/`/data-root ancestor entry and the first pre-existing parent are synced bottom-up before initial run publication, so a later crash cannot lose the entire canonical history path. `begin` also confirms `runs/`, the data root, and its parent when a scheduler setup path created them first. If initial publication fails, removing its fresh directory and discarding a safely unstarted run both sync `runs/` before reporting success; a cleanup sync failure is surfaced as indeterminate instead of claiming a durable rollback.

Purge result prefixes must be unique across the complete mapping. A duplicate
cannot become terminal recovery authority: current output is classified as
`repository_outcome_unknown`, and recovery ignores ambiguous legacy history
and executes the live purge plan.

### Normative destructive-operation audit contract

`runs/<runId>/metadata.json` is the canonical record. `runs/index.jsonl` is a
derived, append-only projection used for history queries; it never overrides
metadata. Reconciliation therefore proceeds **from metadata toward the
index**, never the reverse.

For `prune` (retention or standalone pack reclamation) and `purge`,
"operation started" means the helper has passed secret, executable and
confirmation preflights, persisted `destructiveLaunchAuthorizedAt`, and is
about to hand the exact argv to the process runner. Before that boundary the
run is safely unstarted. The run directory and initial metadata must exist,
`log.txt` must be open, and the exact redacted argv must be persisted in the
same metadata rewrite as the marker before the marker may be written. Failure
of any of those prerequisites refuses process creation. Every successful
metadata publication crosses the crash-durability boundary described above;
those mechanics do not weaken this ordering or the fail-closed launch rule.

New destructive records persist `destructiveAuditContractVersion: 1` in their
initial metadata, making a markerless current-version record affirmative
evidence that launch has not yet been authorized. A markerless `running`
record with a missing or unknown contract version predates that guarantee and
fails closed as an unknown repository outcome until an operator reconciles it.

One machine-wide `locks/destructive-audit.lock` serializes verification,
launch, and terminal audit commit across every set. The helper acquires it
before checking for unresolved evidence and holds it until terminal metadata
and its index projection are committed. This closes the cross-set race in
which two helpers could both pass verification before either recorded an
audit failure. A single manual retention request holds the gate across its
primary and every eligible mirror, so contention cannot turn a partially
applied multi-repository request into an apparent success. A separate
`locks/run-publication.lock` serializes audit scans
with the directory-plus-initial-metadata publication performed by every run,
so a verifier cannot mistake the writer's own mkdir-to-metadata interval for
corruption. It also serializes read-only verifiers; contention between two
scans therefore cannot be mistaken for ownership of the destructive gate. A
terminal metadata rewrite and its index append, including crash recovery,
hold that same publication lock as one verifier-visible transaction. A scan
therefore cannot observe the canonical half of an ordinary finish without
its derived projection. Audit readers snapshot the index bytes and canonical
metadata bytes under the lock, then release it before decoding and comparing
the full history. Publishers wait for that finite snapshot without timing
out; a read-only health scan must never cause a post-operation terminal audit
commit to fail. A failed first metadata write removes the unpublished run
directory before releasing the lock, so it cannot leave permanent
directory-shaped audit wreckage. A running launch marker is considered live
only while the kernel-released
destructive gate is held and its helper PID exists; PID existence alone is
never trusted because PIDs are reusable. For run directories using the current
documented runId format, the operation kind encoded in metadata must match the
independently encoded kind in the directory name before a non-destructive
record may be excluded from this audit scan. Older directories without an
encoded kind remain readable; their fully decoded destructive metadata is
still subject to the same audit rules.

Repository outcome and audit outcome are independent axes:

| Repository outcome | Audit complete | Audit incomplete |
|---|---|---|
| Not started | terminal failed/skipped evidence may be recorded; retry follows the ordinary typed error | infrastructure failure, but no destructive work may have run |
| Known success, warning, or failure | terminal metadata plus exactly one matching index projection; normal policy applies | `operation_completed_audit_failed`; nonzero helper exit, critical health, never automatic retry |
| Unknown after the launch boundary | terminal `auditFailureReason: repository_outcome_unknown` preserves that uncertainty | `operation_completed_audit_failed`; nonzero helper exit, critical health, never automatic retry |

`operationMayHaveRun == false` permits a caller to correct the stated local
prerequisite and submit a fresh request. `operationMayHaveRun == true`
requires the caller to stop: it must not advise or perform an identical
destructive retry. It must surface `operation_completed_audit_failed`, name
the diagnostic run id when available, and require repository inspection plus
run-history reconciliation first. A timeout or lost child after the launch
boundary is conservative: absence of a reported outcome is not proof that no
repository mutation occurred, so terminal metadata retains
`repository_outcome_unknown` even when that terminal record and index append
both succeed.

Reconciliation runs on helper recovery and explicit history repair. It first
requires each decoded metadata `runId` to match the directory being scanned,
before constructing any write path, so misplaced evidence cannot overwrite a
different run's canonical record. It is
idempotent. It may append one missing index projection for terminal canonical
metadata and may convert a dead, still-running non-destructive record to the
existing `failed/interrupted` outcome. If a non-destructive run already has a
stale divergent projection, recovery appends one corrective canonical
projection; logical history takes that last projection without displaying a
duplicate. A dead destructive record carrying a
launch marker must instead retain
`auditFailureReason: launched_without_terminal_metadata`; reconciliation may
index that condition but must not invent a repository result or clear the
critical condition. Only an explicit repair after human inspection may clear
that uncertainty. Repeated reconciliation must neither append duplicates nor
alter an already terminal repository outcome.

Terminal publication is a durable two-phase transaction. Canonical metadata
first commits `indexPublicationPending: true`, the derived line is completely
written and synced under `index.jsonl.lock`, and canonical metadata is then
rewritten with the marker cleared. A crash or surfaced sync error at any point
therefore leaves either running launch evidence, a terminal record whose index
is absent, or a terminal pending marker. Verification treats the pending marker
as `terminal_metadata_missing_index` even when a full but not-yet-confirmed line
is visible. Recovery first commits the pending marker even for legacy terminal
records, repairs an incomplete physical tail before appending, and clears the
marker only after the canonical projection has been synced. Recovery also
fsyncs its existing index snapshot once before accepting matching legacy
projections whose metadata predates the pending marker. A legacy canonical
record without `publicationDurabilityContractVersion` is atomically
republished before a matching pair is accepted; destructive verification
fails closed on that missing marker until recovery completes the upgrade.
Destructive duplicates or divergence remain critical; non-destructive divergence receives
one idempotent corrective projection as described above.

Verification requires every run directory's canonical `metadata.json` to be
readable and decodable. It fails closed on missing or corrupt canonical
evidence instead of skipping the directory. A terminal destructive record is
complete only when the index contains exactly one projection equal to
`metadata.indexEntry`; an absent, duplicate, or divergent projection remains
critical until reconciliation repairs an absent projection. Conversely, a destructive
index projection whose entire canonical run directory is missing reports
`canonical_metadata_missing`; a directory-driven scan must never silently
authorize another destructive launch after that loss.

`status --json` exposes unresolved entries in `auditFailures`, each with
`code: "operation_completed_audit_failed"` and `retryable: false`, and reports
global `health: "critical"`. New destructive launches are refused while any
such entry remains unresolved; read-only inspection and non-destructive
backups remain available. The app re-runs this liveness-sensitive audit check
on its 30-second health cadence because process death releases a flock without
creating a filesystem event.

## state/schedule-state.json

```json
{
  "version": 1,
  "checksum": "<64 lowercase hex SHA-256>",
  "sets": {
    "6F9619FF-...": {
      "lastBackupStart": "2026-07-26T20:57:04Z",
      "lastCheckStart": "2026-07-20T03:00:00Z",
      "checkSliceCursor": 7,
      "appliedPurgeExcludes": {
        "0A1B2C3D-...": ["DerivedData"]
      }
    }
  }
}
```

The checksum covers the canonical sorted-key encoding of the logical
`{"sets": ...}` payload, not the envelope's textual field order. The UUIDs
and checksum above are abbreviated for readability. A successful mutation is
acknowledged only after the new file and its directory entry cross the crash-
durability boundary.

`state/schedule-state.version-1` is the owner-only monotonic migration marker.
It is durably published before the first version-1 envelope. While the
canonical file exists, the marker makes an unversioned document a detected
downgrade rather than legacy input; conversely, a versioned document without
the marker fails closed. Both marker and canonical temp inodes are descriptor-
`fchmod`ed and verified as owner-owned regular files with mode `0600` before
publication, independent of the invoking process's umask. The marker is
validated even when the canonical file is absent: a missing or valid marker
with no envelope is the recoverable pre-publication state, while an unsafe or
unreadable marker is corrupt state and fails health/mutations closed. A
lock-free reader that observes the marker/document mismatch possible during the first migration
reacquires `schedule-state.lock` and rereads both files as one stable
generation; it never quarantines that healthy publication window. A crash
between marker and envelope publication can require explicit recovery, but
cannot silently discard checksum protection.

`lastBackupStart` is the *start* time of the last **attempted** scheduled backup (success or failure) — due-computation keys off attempts, so a failing set retries at its next slot, not every tick. Manual runs also update it (a manual backup satisfies the schedule). `checkSliceCursor` is the `n` most recently used in `--read-data-subset=n/t`. `appliedPurgeExcludes` records, per destination UUID, only patterns whose `rewrite --forget` child succeeded — or, for a destination whose repository is observed empty during the all-destination planning pass, whose plan had nothing to rewrite. Removing a pattern never removes it from this historical watermark. It narrows **both** manual and scheduled apply: a scheduled backup purges only the patterns this destination's watermark does not already record, and skips the purge phase once every active pattern is recorded. That is sound because a purge pattern is also a forward backup exclude (`BackupSet.effectiveBackupExcludes`), so an applied rule cannot reappear in a snapshot this host writes later; see `docs/scheduling.md` §Purge-exclusion ordering for the multi-host case it deliberately does not chase. The watermark is never inferred from historical run records — a lost one is re-established by re-running the pending rewrite, which restic reports as a no-op. Reads and prospective writes share the same 64 MiB encoded-document limit. The complete v1 envelope is encoded and size-checked before either the monotonic migration marker or canonical document is published, so upgrading a near-limit legacy document cannot strand it behind a marker that makes the unchanged legacy bytes look downgraded.

An absent file is a new, empty schedule. Before the monotonic marker exists, a
legacy unversioned document remains readable and is upgraded to version 1 on
its next mutation. After migration, stripping `version` and `checksum` is a
recovery failure rather than a route back to unchecked legacy decoding. Everything else
fails closed: malformed JSON or UUID keys, a checksum mismatch, an unsupported
version, missing/unsafe migration evidence, an oversized document, an I/O
error, a symlink, FIFO, or another non-regular or
foreign-owned canonical file. Readable untrusted bytes are copied exactly to
`schedule-state.corrupt-<sha256>.json`; the canonical file remains untouched
as the sentinel that prevents an accidental empty-state rewrite. Repeated
reads reuse the same content-addressed recovery copy. If recovery-copy
publication fails, a long-lived watcher remembers the canonical byte
fingerprint and does not retry that write for events generated by its own temp
inode; changed canonical bytes receive a new fingerprint and a fresh attempt.
An explicit app reload clears only this event-feedback suppression and retries
the same content-addressed recovery copy, so repaired permissions, quota, or
free space take effect without an app restart.

Recovery is deliberately an operator action: stop Restic Station's scheduler
and any manual run, inspect the canonical and recovery-copy bytes, then replace
the canonical path with a valid document that preserves every trustworthy
timestamp, cursor, and purge watermark. Run `restic-station-helper status
--json` before restarting scheduling. Deleting the canonical file is accepted
only as an explicit decision to discard all of that bookkeeping; it is never
performed automatically. A missing or unsafe migration marker is a two-file
recovery: after verifying the v1 envelope and checksum, recreate the owner-only
marker with exact bytes `1\n` and mode `0600`, or restore both files from a
trusted copy. Replacing only the canonical JSON cannot repair marker damage.
Marker safety is classified before canonical version compatibility, so a
newer-version document cannot hide a missing or unsafe marker that also needs
operator repair.

A **permission** defect is classified separately. `state/`, the canonical
document, and the marker each fail closed when another uid could write them —
the marker also when another uid could merely read it — and the refusal names
the offending path and the shell-quoted `chmod` that repairs it (`700` for the
directory, `600` for either file).

Repairing the mode is not the same as trusting the bytes, and the guidance
splits on which path was exposed. The **marker** holds only `1\n`: it carries no
schedule or purge state and cannot alter any, so a widened marker — writable or
merely readable — is repaired on its own and never implicates the canonical
document. Sending an operator to replace that document for a two-byte file
would discard trustworthy bookkeeping. The **canonical document** and **`state/`**
are refused only for *write* exposure, so reaching that refusal means another
uid could have written the document, directly or by swapping it through the
directory. There `chmod` closes the exposure but proves nothing about what is
already on disk: the envelope checksum is unkeyed, so a forged
`appliedPurgeExcludes` verifies, and a fabricated watermark suppresses a
required rewrite. That case keeps the inspect-and-replace guidance.

That refusal is also reached before it can be erased: `AppPaths.ensureDirectories()`
re-tightens a pre-existing `state/` only when the widening is benign (`0755`),
and refuses outright when the directory is group/world-writable, because setup
runs before the safety-authoritative read and would otherwise repair away the
evidence.

A `state/` that others can write but this user cannot read (`0333`) fails the
`O_RDONLY` open before the mode check runs, so it is diagnosed by pathname and
still reported as the directory-mode refusal rather than a bare I/O error —
unless it is also foreign-owned, which outranks mode exactly as it does on the
descriptor path, since `chmod` is not advice that user can act on. The
directory descriptor cannot instead be opened `O_PATH`/`O_SEARCH` as lock
parents are: it is also the fsync target for durable publication, and Linux
rejects `fsync(2)` on an `O_PATH` descriptor.

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
  "heartbeatAt": "2026-07-26T20:57:29Z",
  "heartbeatUptime": 84721.4,
  "updatedAt": "2026-07-26T20:57:30Z"
}
```

`phase`: `probing` | `backing-up-primary` | `purging-<destId>` | `copying-<destId>` | `retention` | `checking`.

**Presence does not mean "running".** The file is deleted by a `defer` at the
end of every run, so a `SIGKILL`, an OOM kill or a power cut leaves it behind
permanently. Because `AppHealth.running` outranks `.warning`, an
unconditionally-trusted leftover pins a machine green forever: menu bar blue,
`status` exit 0, no backups. Every reader therefore checks whether the run is
still alive before treating it as in flight —
`RunStore.liveness(ofCurrentRun:)`, which reads the run's own
`runs/<runId>/metadata.json`, verifies the pid with `kill(pid, 0)`, and checks
the independent heartbeat. A missing process is **abandoned**; a present
process whose heartbeat is more than five minutes old is **stalled**. Both
report `needsAttention` and `isRunning: false`. An abandoned file can be
cleared; a stalled run still owns the set lock, so status names its log for
diagnosis instead of suggesting deletion.

**The pid alone decides it — deliberately not the recorded `status` as well.**
A set run is several child runs under one `current-run` file: `performChild`
calls `RunStore.finish` (moving that child's metadata off `running`) while the
file is cleared only by the set-level `defer`, and the next child's phase
marker rewrites it moments later. Requiring `status == running` reported that
entirely normal interval as wreckage and exited 1 on a healthy host mid-backup.
A missing run directory is still abandonment: `begin(...)` writes
`metadata.json` before the first progress write, so a `current-run` pointing at
a run this data directory has no record of describes nothing.

Liveness is deliberately **not** a staleness rule on `updatedAt`. Progress is written only
when restic emits a `status` line (throttled), and some phases legitimately
emit nothing for hours — a `check --read-data` on a large repository writes
one phase marker and then goes quiet. The helper therefore writes
`heartbeatAt` and `heartbeatUptime` every 30 seconds independently of progress.
The uptime value ages only while the machine is awake, so normal sleep cannot
create a false stall; `updatedAt` remains the timestamp of visible progress.
Files written by older releases have no heartbeat and retain pid-only behavior.

The tick clears it: `recoverInterrupted()` returns the `setId` alongside the
`runId` precisely so step 3 can delete the matching progress file, guarded on
`runId` so a *newer* run for the same set is never touched.

## state/fda-check.json

```json
{ "checkedAt": "2026-07-26T20:57:00Z", "hasFullDiskAccess": true, "probedPath": "~/Library/Safari", "context": "launchd" }
```

**macOS only, and absence is meaningful.** The file is written only by the macOS `fda-check` probe; on other platforms the subcommand writes nothing at all. An absent file means "not applicable / not yet known", **never** "denied" — see `keychain-and-fda.md` §2 for the normative rule and `HealthDerivation.fullDiskAccessDenied(from:)` for its single implementation.

## Versioning & migration

`AppConfig.currentVersion` is **3**. Loader behavior: version > current → refuse with a clear error ("config written by a newer Restic Station"); version < current → run the in-code migration chain, then persist. Regenerable state/run caches carry no version field and tolerate decode failure. The exception is `state/schedule-state.json`, whose current envelope version is **1** and whose checksum protects destructive purge bookkeeping. Legacy unversioned schedule state is accepted only before `state/schedule-state.version-1` is durably published and is upgraded on mutation; malformed, downgraded, tampered, or newer-version state is preserved and makes schedule mutations, `status`, and the app fail unhealthy until explicit recovery. `machine.json` versions independently (`MachineConfig.currentVersion`, currently 1).

### v1 → v2

The schema change needs no data change: an absent `machines` key already means "runs everywhere", so a v1 config *is* a valid v2 config once the version number is bumped. Exactly one value moves.

### v2 → v3

`purgeExcludes` is a second exclusion list. An absent or explicit `null` key decodes as `[]`, preserving the pre-v3 behavior of not marking anything for purge. Every saved v3 config writes the key, including when empty.

### Persistence and backups

`ConfigStore` performs a **single jump** from the file's source version to the current version; it does not write one intermediate config or backup per version crossed. A v1 file loaded by a v3 build therefore produces only `config.v1.backup.json`, because no v2 file ever existed on that host.

For a file below the current version, `ConfigStore.load()`:

1. Adds **no** `machines` keys.
2. If `config.json` has a `resticPath` and `machine.json` has none, moves it into `machine.json` and clears the deprecated field. If `machine.json` already has one, that one wins and the deprecated field is still cleared. If the write fails, `resticPath` is left in `config.json`, where it still works as the documented fallback.
3. Copies the untouched source bytes to **`config.v<source-version>.backup.json`**, beside `config.json`, with `O_EXCL` — **never** overwriting an existing backup, so a second migration cannot clobber the source's copy (or a copy the user put there by hand).
4. Only if that backup exists, writes the current-version config atomically.
5. Sets `version: 3` and returns.

Migration is **idempotent**: the second load sees `version: 3` and does nothing. Every persistence step is best-effort — a data directory that cannot be written must not stop the helper from running backups, and the migration is a pure function of the file, so an unwritten migration simply reruns next load. What is *not* best-effort is the ordering: **the source file is never overwritten unless a backup of it exists.**

A v1 config that fails `validate()` at its own version is a hard error: it produces no backup file and no rewritten `config.json`.

The net effect on an existing single-machine install is that `"version": 1` becomes `"version": 3`, `"resticPath"` becomes `null`, `"purgeExcludes"` becomes `[]`, and everything the engine acts on — sources, destinations, schedules, retention, the effective restic binary — is unchanged.

## Headless CLI `--json` shapes (T27)

Eleven commands accept `--json`; **`cli-json.md` holds the command matrix, the envelope, the error taxonomy and the versioning policy**, and is the normative document for all of it. This section documents the *payload shapes* those commands put in `data`, because they are made of the same types the state files are.

This is documented **as an interface**, not as debug output: a script that pipes one of these into `jq` today must keep working across releases the same way `runs/index.jsonl` does. The conventions from the preamble apply identically — `.sortedKeys` + `.prettyPrinted`, ISO 8601 dates with fractional seconds, every optional field encoded as explicit `null` rather than omitted (`ConfigStore.makeEncoder()`, reused verbatim by the CLI's `CLIJSON.print(_:)`).

**Every payload below is the `data` value, not the whole document.** `CLIJSON.print` wraps it:

```json
{ "schemaVersion": 1, "ok": true, "data": { … the shapes in this section … } }
```

So `status --json | jq '.data.health'`, not `.health`. See `cli-json.md` §Migrating from the unwrapped shape — this changed, and the old bare form is gone.

Every `--json` mode writes *only* JSON to stdout; diagnostics go to stderr. `runs list --json` and `runs show --json` reuse `RunIndexEntry` and `RunMetadata` verbatim (§runs/index.jsonl, §runs/\<runId\>/metadata.json above) — no separate shape to document.

### `config show --json` / the "effective plan" section of `config validate`

Both commands build the identical report (`EffectiveConfigReport`, `Helper/Sources/EffectiveConfigReport.swift`) from **both** resolution views: `.addressable` supplies every set and destination this machine can address (nothing dropped), `.scheduling` supplies `enabledHere` and the `excludedHere` list with reasons. Building the report from the addressable view is what guarantees a set excluded here is still *shown*, marked as excluded, rather than silently missing — reading only the scheduling view would defeat the entire anti-silent-failure point of `config validate`.

```json
{
  "machineId": "studio-mac",
  "version": 3,
  "resticPath": null,
  "sets": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "Projects",
      "enabledHere": true,
      "sources": ["/Users/user/proj"],
      "excludes": ["node_modules"],
      "purgeExcludes": [],
      "schedule": { "kind": "daily", "hour": 2, "minute": 30 },
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 14,
      "destinations": [
        {
          "id": "0A1B2C3D-...-PRIMARY",
          "label": "iCloud",
          "repoURL": "/Users/user/.../proj.restic",
          "isPrimary": true,
          "nonSecretEnv": {},
          "enabledHere": true
        }
      ]
    }
  ],
  "excludedHere": [
    {
      "subject": "backupSet",
      "setId": "6F9619FF-...",
      "id": "6F9619FF-...",
      "name": "Photos",
      "reason": "disabledForMachine",
      "description": "backup set \"Photos\" is disabled on this machine"
    }
  ]
}
```

`excludedHere[].reason` is one of `ResolvedOmission.Reason`'s three raw cases (`disabledForMachine` | `noEnabledDestinations` | `noSources`); `description` is the same one-line prose `tick` prints for the same omission, included so a `--json` consumer never has to re-derive it from `reason` + `name`. `excludedHere[].subject` is `"backupSet"` or `"destination"`; for a destination, `setId` names the owning set and `id` the destination.

Never a secret: `nonSecretEnv` is exactly `Destination.nonSecretEnv` (never the keychain/secrets.json value), and no field here can hold a repository password.

### `status --json`

Reads recorded state (`state/schedule-state.json`, `state/current-run-*.json`, `state/repo-status-*.json`, `runs/index.jsonl`) and performs the same live locking probe as the app — no restic invocation. A corrupt or unreadable existing schedule-state file is not treated as an empty schedule: `status` returns a structured state-unreadable failure, identifies any exact-byte recovery copy, and leaves the canonical file in place. The lock probe may create dedicated owner-only `health.lock` inodes in `locks/`, `state/`, and `runs/` so it exercises `flock(2)` on each possibly distinct filesystem, and creates then removes a uniquely named scratch inode inside health-only `.health/` directories on all three filesystems to catch quota or full-filesystem failures; it never creates operation locks. Normal operation setup does not create or depend on any health scratch directory. It inspects set locks only for sets in this machine's resolved configuration, so persistent orphaned names do not create false outages. When readable state is available, `health` reuses `HealthDerivation.appHealth` verbatim (`Core/Sources/ResticStationCore/Support/HealthDerivation.swift`), so the CLI and the app's menu bar use the same warning derivation.

It also inspects the platform scheduler: the same `SystemdTimerManager` used by `timer status` on Linux, and `launchctl print gui/$UID/net.herila.ResticStation.helper` on macOS. See `scheduling.md` §`status` and the scheduler. Only a definite `false` contributes a warning; a failed probe reports `healthy: null`.

Five things `status` will **not** do quietly, all of which would make it report healthy for the wrong reason:

- An **unreadable `runs/index.jsonl`** (wrong owner, wrong mode, I/O error) exits non-zero naming the file, instead of reading as "no runs recorded" — which derives to idle, which exits 0. A corrupt or truncated *line* stays survivable: `RunStore.recentRuns` skips it with a warning, as documented above.
- An **unresolved destructive audit failure** reports `critical`, populates `auditFailures`, exits non-zero, and prevents any later destructive launch. It is never flattened into an ordinary failed run whose retry policy is ambiguous.
- An **abandoned `current-run-*.json`** (see §state/current-run) reports `warning` with `abandonedRun` populated and `isRunning: false`, instead of `running`.
- A **stalled run** whose process still exists but has stopped heartbeating reports `warning` with `stalledRun` and `stalledRunLog` populated. It is never offered as safe-to-delete wreckage.
- **Locking that does not work** — `locks/` uncreatable, uninspectable, or unsafe; unsupported `flock(2)`; inability to allocate a fresh lock inode; a production lock file owned by another user; a symlink where one should be — reports `locking.usable: false` and exits non-zero. `locking.scope` is `"set"` with the first detected affected `setId` for damaged set locks, `"administrative"` when only a mutation-only `config.lock` or `secrets.lock` is damaged, and otherwise `"machine"` for a shared operation lock, directory, or filesystem-capability failure. Intrinsic damage confined to a dedicated `health.lock` or `.health/` scratch artifact instead reports `locking.usable: null`, `locking.scope: "diagnostic"`, and exits non-zero: monitoring is inconclusive, but production locks were not proven unusable. A failed `flock(2)` check or fresh-inode allocation remains machine-scoped even when its path is health-only, because production acquisition relies on the same capability. Human output preserves those distinctions and says either configuration changes or one or more sets may be affected rather than understating a simultaneous broader outage. This is probed *live* rather than read from recorded state: the fault it describes is usually the reason nothing could be recorded. Machine-wide faults outrank `running`, because a stale `current-run-*.json` is exactly what such a machine tends to be left holding. See `scheduling.md` §Locking.
- A set whose **first backup was never attempted** reports `firstBackupOverdue: true` after the larger of one schedule period and 24 hours from the later `config.json`/`machine.json` mtime. Missing mtimes disable this condition; a live run, any run history, or `lastBackupStart` proves setup progressed and disables it.

```json
{
  "machineId": "studio-mac",
  "generatedAt": "2026-07-26T20:57:30.000Z",
  "health": "warning",
  "fullDiskAccessDenied": false,
  "locking": {"usable": true, "dataDirectory": "/Users/me/Library/Application Support/ResticStation", "problem": null, "scope": null, "setId": null},
  "scheduler": {"kind": "launchd-agent", "healthy": true, "problems": [], "summaries": []},
  "sets": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "Projects",
      "needsAttention": true,
      "isRunning": false,
      "firstBackupOverdue": false,
      "abandonedRun": null,
      "abandonedRunFile": null,
      "stalledRun": null,
      "stalledRunLog": null,
      "lastBackup": {
        "runId": "20260726T205704Z-backup-6f9619ff",
        "status": "failed",
        "start": "2026-07-26T20:57:04.000Z",
        "end": "2026-07-26T20:58:11.000Z",
        "ageSeconds": 19
      },
      "lastCheck": null,
      "lastPrune": null,
      "currentRun": null,
      "nextDue": "2026-07-27T02:30:00.000Z",
      "destinations": [
        {
          "id": "0A1B2C3D-...-PRIMARY",
          "label": "iCloud",
          "isPrimary": true,
          "reachable": true,
          "stale": false,
          "lastSyncedAt": "2026-07-25T02:31:00.000Z",
          "lastError": null
        }
      ]
    }
  ],
  "auditFailures": [],
  "unattributedRuns": [],
  "excludedHere": []
}
```

`health`: `"idle"` | `"running"` | `"warning"` | `"critical"` (`AppHealth.rawValue`). Exit code: **0** for `idle`/`running`, **1** for `warning`/`critical` — usable directly as a Nagios/Icinga-style check. `critical` is reserved for unresolved destructive audit failures and outranks a concurrently running backup. `auditFailures` is always present; each entry carries `code: "operation_completed_audit_failed"`, the run/set/destination identifiers, the bounded reason enum, and `retryable: false`. `lastBackup`/`lastCheck`/`lastPrune` are `null` before any attempt of that kind; `reachable` is `null` — never `false` — for a destination that has not been probed yet (`state/repo-status-<destId>.json` absent), the same "absent means not yet known, never a definite negative" rule `fda-check.json` uses. `firstBackupOverdue` explains the otherwise-empty warning for a never-attempted set. `excludedHere` has the same shape as `config show`'s.

`unattributedRuns` contains any `current-run-<setId>.json` whose set is no longer in this machine's resolved configuration. Each entry carries the missing `setId`, `liveness` (`"live"`, `"stalled"`, or `"abandoned"`), the usual `currentRun` summary, and the exact `currentRunFile`. These runs still determine top-level health and the exit code, so an empty `sets` array never leaves their effect unexplained. Human output names the same run; abandoned entries print a shell-quoted cleanup command, while stalled entries direct the operator to the run log.

### `sets list --json`

One entry per backup set, from the `.addressable` view (an inventory command must list every set this machine knows about, marking each `enabledHere` — never silently omitting an excluded one).

```json
[
  {
    "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
    "name": "Projects",
    "enabledHere": true,
    "sources": ["/Users/user/proj"],
    "destinationCount": 2,
    "schedule": { "kind": "daily", "hour": 2, "minute": 30 }
  }
]
```
