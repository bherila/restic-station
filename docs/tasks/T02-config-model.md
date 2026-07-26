# T02 — Config models, ConfigStore, AppPaths

**Size:** M · **Model:** Sonnet · **Depends on:** T01 · **Milestone:** M1

## Goal
All Codable config types from `docs/data-model.md` exactly as specified; atomic persistence; `AppPaths` as the single source of runtime paths with test/env override.

## Create
- `Core/Sources/ResticStationCore/Config/Models.swift` — `AppConfig`, `BackupSet`, `Destination`, `DestinationKind` (derived from `repoURL` prefix: `sftp:`→sftp, `rest:`→rest, `s3:`→s3, `b2:`/`azure:`/`gs:`/`swift:`/`rclone:`→otherCloud, else localPath), `Schedule` (custom Codable with `kind` discriminator — encode/decode exactly the JSON shapes in data-model.md), `RetentionPolicy` (+`isEmpty`), `CheckPolicy`. `AppConfig.validate() throws` implementing the five invariants in data-model.md (throw a `ConfigError` enum with associated descriptions).
- `Core/Sources/ResticStationCore/Config/AppPaths.swift` — struct with `root: URL`; `init(root:)` and `static func `default`()` resolving: env `RESTIC_STATION_DATA_DIR` if set, else `~/Library/Application Support/ResticStation`. Computed properties for every path in the architecture.md AppPaths table + `resticCacheDir` + `mountsDir(destId:)`. `ensureDirectories() throws` creates root/runs/state/locks.
- `Core/Sources/ResticStationCore/Config/ConfigStore.swift` — `load() throws -> AppConfig` (missing file → default empty config, version too new → `ConfigError.newerVersion`), `save(_:) throws` (validate → encode sortedKeys+prettyPrinted+iso8601 → write temp file same dir → `rename`). No caching; callers hold the value.

## Tests (`Core/Tests/ResticStationCoreTests/`)
- Round-trip encode/decode of a config exercising every Schedule case and destination kind; compare against a checked-in JSON string matching data-model.md's example (field-for-field).
- `validate()`: zero primaries / two primaries / duplicate UUIDs / relative source path / minute 60 / everyMinutes 4 — each throws the right case.
- Atomicity: save into temp dir, corrupt-write simulation (pre-existing temp file), reload equals saved.
- AppPaths: env override respected (use `setenv` in test), directory creation idempotent.

## Acceptance criteria
- [ ] `swift test --package-path Core` green on macOS and in `swift:6.1` Linux container.
- [ ] Example config from data-model.md decodes without error (include it verbatim as a fixture string).
- [ ] No Darwin-only imports in these files.
