import Foundation
import Testing
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// #159: `config.json`, `machine.json` and the migration backup are written
/// crash-durably — the file is synced before it becomes visible and its
/// directory after — and a failure on either side of the rename is reported
/// for what it is.
///
/// A power cut cannot be staged in a unit test, so these observe the
/// `fsync(2)` calls through `DurableFile.sync` (task-local, so an injected
/// failure never reaches another test) and fail chosen ones.
@Suite struct DurableFileTests {
    /// Counts sync calls and fails the ones listed in `failing` (1-based).
    final class SyncProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let failing: Set<Int>
        init(failing: Set<Int> = []) { self.failing = failing }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        private func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }

        var hook: @Sendable (Int32) -> Int32 {
            { [self] descriptor in
                let call = next()
                if failing.contains(call) {
                    errno = EIO
                    return -1
                }
                return fsync(descriptor)
            }
        }
    }

    private func makePaths() throws -> (AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-durable-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        return (paths, root)
    }

    private func config(named name: String) -> AppConfig {
        AppConfig(sets: [
            BackupSet(
                id: UUID(), name: name, sources: ["/src"], schedule: .daily(hour: 3, minute: 0),
                destinations: [Destination(id: UUID(), label: "Primary", repoURL: "/repo", isPrimary: true)]
            ),
        ])
    }

    @Test func saveSyncsTheFileAndThenItsDirectory() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = SyncProbe()

        try DurableFile.$sync.withValue(probe.hook) {
            try ConfigStore(paths: paths).save(config(named: "A"))
        }

        #expect(probe.calls == 2)
        #expect(try ConfigStore(paths: paths).load().sets.map(\.name) == ["A"])
    }

    @Test func compareAndSwapSaveSyncsTheFileAndThenItsDirectory() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(paths: paths)
        try store.save(config(named: "A"))
        let fingerprint = try store.currentFileFingerprint()
        let probe = SyncProbe()

        try DurableFile.$sync.withValue(probe.hook) {
            _ = try store.save(config(named: "B"), ifUnchangedFrom: fingerprint)
        }

        #expect(probe.calls == 2)
        #expect(try store.load().sets.map(\.name) == ["B"])
    }

    @Test func aFileSyncFailureInstallsNothing() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(paths: paths)
        try store.save(config(named: "A"))
        let before = try Data(contentsOf: paths.configFile)

        #expect(throws: LockFailure.self) {
            try DurableFile.$sync.withValue(SyncProbe(failing: [1]).hook) {
                try store.save(config(named: "B"))
            }
        }

        #expect(try Data(contentsOf: paths.configFile) == before)
        #expect(!FileManager.default.fileExists(atPath: store.tempConfigFile.path))
    }

    /// The #165 restructure: once the rename has happened the new file is
    /// live, and every caller's "the write failed" means "the old file is
    /// still there". A directory sync that fails afterwards must therefore
    /// not throw — for config.json (both save paths) and machine.json — or a
    /// caller rolls back state paired with a write that took effect.
    @Test func aDirectorySyncFailureAfterTheRenameStillCountsAsSaved() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(paths: paths)
        try store.save(config(named: "A"))

        try DurableFile.$sync.withValue(SyncProbe(failing: [2]).hook) {
            try store.save(config(named: "B"))
        }
        #expect(try store.load().sets.map(\.name) == ["B"])

        let fingerprint = try store.currentFileFingerprint()
        let installed = try DurableFile.$sync.withValue(SyncProbe(failing: [2]).hook) {
            try store.save(config(named: "C"), ifUnchangedFrom: fingerprint)
        }
        #expect(installed == (try store.currentFileFingerprint()))
        #expect(try store.load().sets.map(\.name) == ["C"])

        let machines = MachineStore(paths: paths, environment: [:])
        try DurableFile.$sync.withValue(SyncProbe(failing: [2]).hook) {
            try machines.save(MachineConfig(machineId: "after-rename"))
        }
        #expect(try machines.load().machineId == "after-rename")
    }

    /// The migration backup is the exception: it licenses overwriting the
    /// source, so an entry whose directory did not sync is removed and the
    /// source stays at its old version.
    @Test func aBackupWhoseDirectoryDidNotSyncIsNotTrusted() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = AppConfig.currentVersion - 1
        let legacy = try ConfigStore.makeEncoder().encode(AppConfig(version: from))
        try legacy.write(to: paths.configFile)
        try MachineStore(paths: paths, environment: [:]).save(MachineConfig(machineId: "studio-mac"))

        // backup file, then backup directory ← fails
        _ = try DurableFile.$sync.withValue(SyncProbe(failing: [2]).hook) {
            try ConfigStore(paths: paths).load()
        }

        #expect(try Data(contentsOf: paths.configFile) == legacy)
        #expect(!FileManager.default.fileExists(atPath: paths.configBackupFile(fromVersion: from).path))
    }

    /// An interrupted earlier run may have left a backup whose directory
    /// entry never synced; it is confirmed before it is relied on.
    @Test func anExistingBackupIsConfirmedBeforeItIsTrusted() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = AppConfig.currentVersion - 1
        let legacy = try ConfigStore.makeEncoder().encode(AppConfig(version: from))
        try legacy.write(to: paths.configFile)
        try legacy.write(to: paths.configBackupFile(fromVersion: from))
        try MachineStore(paths: paths, environment: [:]).save(MachineConfig(machineId: "studio-mac"))

        _ = try DurableFile.$sync.withValue(SyncProbe(failing: [1]).hook) {
            try ConfigStore(paths: paths).load()
        }
        #expect(try Data(contentsOf: paths.configFile) == legacy, "an unconfirmable backup must not license the overwrite")

        let probe = SyncProbe()
        _ = try DurableFile.$sync.withValue(probe.hook) { try ConfigStore(paths: paths).load() }
        #expect(try ConfigStore(paths: paths).reconciliationSnapshot().config.version == AppConfig.currentVersion)
        #expect(probe.calls >= 3, "existing backup's directory, then the config temp and its directory")
    }

    @Test func machineJSONIsWrittenDurably() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = SyncProbe()

        try DurableFile.$sync.withValue(probe.hook) {
            try MachineStore(paths: paths, environment: [:]).save(MachineConfig(machineId: "studio-mac"))
        }

        #expect(probe.calls == 2)
        #expect(try MachineStore(paths: paths, environment: [:]).load().machineId == "studio-mac")
    }

    /// The migration's one rule — never overwrite the source unless its
    /// backup exists — now includes "exists on disk": if the backup cannot
    /// be synced, config.json is left at its old version.
    @Test func anUnsyncedMigrationBackupLeavesTheSourceAlone() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try ConfigStore.makeEncoder().encode(AppConfig(version: AppConfig.currentVersion - 1))
        try legacy.write(to: paths.configFile)
        try MachineStore(paths: paths, environment: [:]).save(MachineConfig(machineId: "studio-mac"))

        let migrated = try DurableFile.$sync.withValue(SyncProbe(failing: [1]).hook) {
            try ConfigStore(paths: paths).load()
        }

        #expect(migrated.version == AppConfig.currentVersion)   // in memory, as before
        #expect(try Data(contentsOf: paths.configFile) == legacy)
        let backup = paths.configBackupFile(fromVersion: AppConfig.currentVersion - 1)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func aMigrationSyncsItsBackupBeforeTheConfig() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try ConfigStore.makeEncoder().encode(AppConfig(version: AppConfig.currentVersion - 1))
            .write(to: paths.configFile)
        try MachineStore(paths: paths, environment: [:]).save(MachineConfig(machineId: "studio-mac"))
        let probe = SyncProbe()

        _ = try DurableFile.$sync.withValue(probe.hook) { try ConfigStore(paths: paths).load() }

        // backup file + its directory, then config temp + its directory
        // (the migration record in state/ has its own durable writer).
        #expect(probe.calls >= 4)
        #expect(FileManager.default.fileExists(
            atPath: paths.configBackupFile(fromVersion: AppConfig.currentVersion - 1).path
        ))
    }

    @Test func existingPermissionsConventionIsKept() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try ConfigStore(paths: paths).save(AppConfig())
        let mask = umask(0)
        umask(mask)
        let mode = try FileManager.default.attributesOfItem(atPath: paths.configFile.path)[.posixPermissions] as? Int
        #expect(mode == Int(0o644 & ~mask))
    }

    @Test func aSymlinkAtTheTempPathIsNotFollowed() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(paths: paths)
        let decoy = root.appendingPathComponent("decoy.json")
        try Data("untouched".utf8).write(to: decoy)
        try FileManager.default.createSymbolicLink(at: store.tempConfigFile, withDestinationURL: decoy)

        #expect(throws: LockFailure.self) { try store.save(AppConfig()) }
        #expect(try String(contentsOf: decoy, encoding: .utf8) == "untouched")
    }

    /// Codex on #165: a migration whose directory sync fails has still
    /// replaced config.json, and no later load will migrate again — so the
    /// fleet warning must be recorded now or never.
    @Test func aMigrationWithUnconfirmedDurabilityIsStillRecorded() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let from = AppConfig.currentVersion - 1
        try ConfigStore.makeEncoder().encode(AppConfig(version: from)).write(to: paths.configFile)
        try MachineStore(paths: paths, environment: [:]).save(MachineConfig(machineId: "studio-mac"))

        // backup file, backup directory, config temp, config directory ← fails
        _ = try DurableFile.$sync.withValue(SyncProbe(failing: [4]).hook) {
            try ConfigStore(paths: paths).load()
        }

        #expect(try ConfigStore(paths: paths).reconciliationSnapshot().config.version == AppConfig.currentVersion)
        let record = try #require(StateStore(paths: paths).readConfigMigration())
        #expect(record.fromVersion == from)
    }

    // MARK: global-excludes.json

    /// Losing an exclusion-settings write to a power cut restores the
    /// built-in defaults, re-enabling a group the operator disabled, so the
    /// save, its compare-and-swap form and the removal all take the durable
    /// path — and, since #165, follow the same "nothing throws after the
    /// rename" rule as `config.json`.
    @Test func exclusionSettingsSavesSyncTheFileThenItsDirectory() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlobalExcludeStore(paths: paths)
        var settings = GlobalExcludeSettings()
        settings.extraPatterns = ["/one"]

        let probe = SyncProbe()
        try DurableFile.$sync.withValue(probe.hook) { try store.save(settings) }
        #expect(probe.calls == 2)

        let fingerprint = try #require(try store.loadFingerprinted().fingerprint)
        settings.extraPatterns = ["/two"]
        let casProbe = SyncProbe()
        try DurableFile.$sync.withValue(casProbe.hook) {
            _ = try store.save(settings, ifUnchangedFrom: fingerprint)
        }
        #expect(casProbe.calls == 2)
        #expect(try store.load().extraPatterns == ["/two"])

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.globalExcludesFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func exclusionSettingsRemovalSyncsTheDirectory() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlobalExcludeStore(paths: paths)
        try store.save(GlobalExcludeSettings())

        let probe = SyncProbe()
        let removed = try DurableFile.$sync.withValue(probe.hook) { try store.removeSettings() }
        #expect(removed)
        #expect(probe.calls == 1)
        #expect(!FileManager.default.fileExists(atPath: paths.globalExcludesFile.path))
    }

    @Test func anExclusionSettingsFileSyncFailureInstallsNothing() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlobalExcludeStore(paths: paths)
        var settings = GlobalExcludeSettings()
        settings.extraPatterns = ["/kept"]
        try store.save(settings)
        let before = try Data(contentsOf: paths.globalExcludesFile)

        settings.extraPatterns = ["/lost"]
        #expect(throws: LockFailure.self) {
            try DurableFile.$sync.withValue(SyncProbe(failing: [1]).hook) { try store.save(settings) }
        }
        #expect(try Data(contentsOf: paths.globalExcludesFile) == before)
        #expect(!FileManager.default.fileExists(atPath: store.tempFile.path))
    }

    /// After the rename (or the unlink) the change is live, so a failed
    /// directory sync must not report the save or removal as failed — an
    /// editor that believed it would reload stale state over a file that
    /// actually changed.
    @Test func exclusionSettingsDirectorySyncFailureAfterCommitStillCounts() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlobalExcludeStore(paths: paths)
        var settings = GlobalExcludeSettings()
        settings.extraPatterns = ["/after-rename"]

        try DurableFile.$sync.withValue(SyncProbe(failing: [2]).hook) { try store.save(settings) }
        #expect(try store.load().extraPatterns == ["/after-rename"])

        let removed = try DurableFile.$sync.withValue(SyncProbe(failing: [1]).hook) { try store.removeSettings() }
        #expect(removed)
        #expect(!FileManager.default.fileExists(atPath: paths.globalExcludesFile.path))
    }
}
