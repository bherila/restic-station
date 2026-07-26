# T05 — restic JSON parsers + fixtures

**Size:** M · **Model:** Sonnet · **Depends on:** T01 (parallel with T04; supplies the real `ResticMessageDecoder` for T04's seam) · **Milestone:** M1

## Goal
Decodable types for every restic JSON format, implemented against the captured fixtures in `docs/fixtures/` (real restic 0.18.1 output — copy them into `Core/Tests/ResticStationCoreTests/Fixtures/`).

## Create (`Core/Sources/ResticStationCore/Restic/Parsers/`)
- `BackupMessages.swift` — `BackupStatus` (`percent_done`, `total_files?`, `files_done?`, `total_bytes?`, `bytes_done?`, `seconds_remaining?`, `current_files?: [String]`, `error_count?`), `BackupSummary` (all fields in fixture `backup.ndjson` summary line), `ExitErrorMessage` (`code`, `message`), `RestoreSummary` (fixture `restore.ndjson`).
- `Snapshot.swift` — matches `snapshots.json` elements: `id`, `shortId`, `time`, `parent?`, `original?`, `paths`, `hostname`, `username`, `programVersion?`, `summary?` (nested struct). Used for both the snapshots array and the `ls` snapshot-header line.
- `LsNode.swift` — fixture `ls-src.ndjson` node lines: `name`, `type` (enum file/dir/symlink/other-raw), `path`, `size?`, `mtime`, `permissions?`.
- `FindResult.swift` — fixture `find.json`: array of `{matches: [FindMatch], hits, snapshot}`.
- `Stats.swift` — both modes (`stats-raw.json`, `stats-restore.json`); all fields optional except `snapshots_count`.
- `ForgetResult.swift` — fixture `forget.json`: array of groups `{keep: [Snapshot]?, remove: [Snapshot]?, reasons?}` (tolerate null remove).
- `VersionInfo.swift` — `version.json`; add `func meetsMinimum(_ v: String) -> Bool` (numeric triple compare; min is "0.17.0").
- `ResticMessageDecoder.swift` (conforms to T04's seam) — dispatch on `message_type`: `status`/`summary`/`exit_error`/`node`/`snapshot` (via `struct_type` too) → typed; unknown → `.unparsed(line)`. Single-object and array documents (`snapshots`, `find`, `forget`, `stats`) get standalone `parse*` functions taking full `Data`.

All types: `Decodable` with `CodingKeys` snake_case mapping, every field optional unless present in ALL fixtures, **never throw on unknown fields**, dates via ISO8601 with fractional seconds (restic emits `2026-07-26T16:57:04.634751-04:00` — use a custom `DateDecodingStrategy` handling both with/without fractional part).

## Tests
One test per fixture file decoding it fully and asserting 3–5 salient values (e.g. backup summary `snapshot_id == "e9ffc5cb…"`, `files_new == 3`; ls node `binary.dat` size 65536; find hit path; forget remove count 1; version 0.18.1 meetsMinimum). NDJSON tolerance: inject `{"message_type":"totally_new"}` line → `.unparsed`, no throw. Date parsing both fractional and non-fractional. Copied-snapshot `original` field (synthesize a line — fixture note: `snapshots.json` from the secondary would carry it; constructing it manually is fine).

## Acceptance criteria
- [ ] `swift test` green (macOS + Linux container).
- [ ] Every file in `docs/fixtures/*.json|ndjson` (except text-only `.txt`) has a decode test.
- [ ] Fixtures copied unmodified (byte-identical) into the test bundle.
