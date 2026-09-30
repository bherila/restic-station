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

    /// The nearest constraint to the fix: the app rolls back paired secret
    /// changes on a failed save. A directory-sync failure comes *after* the
    /// new file is live, so it must read as possibly committed — never as a
    /// failure that leaves the old config in place.
    @Test func aDirectorySyncFailureIsInstalledButUnconfirmed() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigStore(paths: paths)
        try store.save(config(named: "A"))
        let fingerprint = try store.currentFileFingerprint()

        for save in [
            { try store.save(self.config(named: "B")) },
            { _ = try store.save(self.config(named: "C"), ifUnchangedFrom: try store.currentFileFingerprint()) },
        ] as [() throws -> Void] {
            do {
                try DurableFile.$sync.withValue(SyncProbe(failing: [2]).hook) { try save() }
                Issue.record("expected durabilityUnconfirmed")
            } catch let error as ConfigStoreError {
                guard case .durabilityUnconfirmed = error else {
                    Issue.record("unexpected \(error)")
                    continue
                }
                #expect(error.commitMayBeUncertain)
                #expect(!error.isRevisionConflict)
            }
        }
        #expect(try store.load().sets.map(\.name) == ["C"])
        #expect(try store.currentFileFingerprint() != fingerprint)
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
}
