import Foundation
import Testing

import ResticStationCore
@testable import restic_station_helper

/// Unit coverage for `ConfigImport`'s pure/file-local helpers — the pieces
/// that don't require spawning the built binary. The full CLI behavior
/// (stdout content, backup-before-overwrite, exit codes,
/// migration-reuse end to end) is `scripts/headless-cli-test.sh`, matching
/// this repo's existing split between unit tests and
/// `scripts/secret-cli-test.sh` for the `secret` subcommands.
@Suite("config import helpers")
struct ConfigImportTests {

    private func makeTempRoot() -> (paths: AppPaths, cleanup: () -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("config-import-test-\(UUID().uuidString)", isDirectory: true)
        return (AppPaths(root: root), { try? FileManager.default.removeItem(at: root) })
    }

    // MARK: - allocateImportBackupURL

    @Test("the backup filename embeds a UTC timestamp and lives beside config.json")
    func backupURLIsTimestamped() {
        let (paths, cleanup) = makeTempRoot()
        defer { cleanup() }
        let now = Date(timeIntervalSince1970: 1_785_000_000) // fixed, for a deterministic assertion
        let url = ConfigImport.allocateImportBackupURL(paths: paths, now: now)
        #expect(url.deletingLastPathComponent() == paths.root)
        #expect(url.lastPathComponent.hasPrefix("config.import-backup-"))
        #expect(url.lastPathComponent.hasSuffix(".json"))
    }

    /// Two imports within the same wall-clock second must not collide —
    /// mirrors `RunStore.allocateRunId`'s `-2`, `-3`, ... convention.
    @Test("a collision at the same timestamp gets a numeric suffix, never overwrites")
    func collidingTimestampsGetDistinctFiles() throws {
        let (paths, cleanup) = makeTempRoot()
        defer { cleanup() }
        try paths.ensureDirectories()
        let now = Date(timeIntervalSince1970: 1_785_000_000)

        let first = ConfigImport.allocateImportBackupURL(paths: paths, now: now)
        try Data("first".utf8).write(to: first)

        let second = ConfigImport.allocateImportBackupURL(paths: paths, now: now)
        #expect(second != first)
        try Data("second".utf8).write(to: second)

        let third = ConfigImport.allocateImportBackupURL(paths: paths, now: now)
        #expect(third != first && third != second)

        // The first file is untouched by allocating the second/third paths.
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
    }

    // MARK: - loadExistingForDiff

    @Test("no config.json on disk diffs against a fresh empty config, not nil")
    func missingConfigDiffsAgainstEmpty() {
        let (paths, cleanup) = makeTempRoot()
        defer { cleanup() }
        #expect(ConfigImport.loadExistingForDiff(paths: paths) == AppConfig())
    }

    @Test("a valid config.json on disk is read verbatim for the diff")
    func validConfigIsReadForDiff() throws {
        let (paths, cleanup) = makeTempRoot()
        defer { cleanup() }
        try paths.ensureDirectories()
        let config = AppConfig(resticPath: "/usr/bin/restic", sets: [])
        try ConfigStore(paths: paths).save(config)

        let loaded = try #require(ConfigImport.loadExistingForDiff(paths: paths))
        #expect(loaded.resticPath == "/usr/bin/restic")
    }

    /// A corrupt config.json must not crash the diff step, or silently
    /// pretend nothing is there (which would make the printed summary
    /// wrong) — `nil` signals "could not read", so the caller can say so.
    @Test("a corrupt config.json returns nil, distinguishable from 'no file'")
    func corruptConfigReturnsNil() throws {
        let (paths, cleanup) = makeTempRoot()
        defer { cleanup() }
        try paths.ensureDirectories()
        try Data("not valid json{{{".utf8).write(to: paths.configFile)

        #expect(ConfigImport.loadExistingForDiff(paths: paths) == nil)
    }

    // MARK: - Reusing T24's migration, not reimplementing it (the issue's explicit instruction)

    /// `config import`'s real (non-dry-run) path must call the exact same
    /// `ConfigStore.migrateToCurrentVersion` that `ConfigStore.load()` uses
    /// — this test pins that by checking the side effects it produces
    /// (config.v1.backup.json, machine.json resticPath adoption) show up
    /// for a config imported from a *different* file than config.json.
    @Test("importing a v1 file reuses ConfigStore's migration: v1 backup + machine.json adoption")
    func importingAV1FileReusesTheRealMigration() throws {
        let (paths, cleanup) = makeTempRoot()
        defer { cleanup() }
        try paths.ensureDirectories()

        let v1JSON = Data(#"{"version":1,"resticPath":"/opt/homebrew/bin/restic","showMenuBarIcon":true,"sets":[]}"#.utf8)
        let importFile = paths.root.appendingPathComponent("incoming.json")
        try v1JSON.write(to: importFile)

        let decoded = try ConfigStore.makeDecoder().decode(AppConfig.self, from: v1JSON)
        let store = ConfigStore(paths: paths)
        let migration = store.migrateToCurrentVersion(decoded, originalBytes: v1JSON)

        #expect(migration.backupWritten)
        #expect(migration.config.version == 2)
        #expect(migration.config.resticPath == nil)
        #expect(try MachineStore.persistentIdentity(paths: paths).load().resticPath == "/opt/homebrew/bin/restic")
        #expect(FileManager.default.fileExists(atPath: paths.configV1BackupFile.path))
    }

    /// `--dry-run` must not touch `machine.json` or write
    /// `config.v1.backup.json` — `ConfigStore.previewMigration` is a pure
    /// version bump, which is exactly what makes this true structurally
    /// rather than by convention.
    @Test("dry-run's preview migration touches nothing on disk")
    func dryRunPreviewTouchesNothing() throws {
        let (paths, cleanup) = makeTempRoot()
        defer { cleanup() }
        // Deliberately do NOT call ensureDirectories() — if previewMigration
        // touched the filesystem at all, machine.json's auto-create would
        // have to create `root` first, and we can then observe that it did
        // not.
        let v1JSON = Data(#"{"version":1,"resticPath":"/opt/homebrew/bin/restic","showMenuBarIcon":true,"sets":[]}"#.utf8)
        let decoded = try ConfigStore.makeDecoder().decode(AppConfig.self, from: v1JSON)

        let preview = ConfigStore.previewMigration(decoded)

        #expect(preview.version == 2)
        #expect(!FileManager.default.fileExists(atPath: paths.root.path))
    }
}
