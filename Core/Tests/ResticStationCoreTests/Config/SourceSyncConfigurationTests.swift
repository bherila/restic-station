import Foundation
import Testing
@testable import ResticStationCore

@Test("a sync folder round trip never narrows the parent backup set")
func independentSyncConfiguration() throws {
    let group = SourceSyncGroup(name: "Notes", localPath: "/workspace/shared-notes", peer: .init(path: "/srv/shared-notes", sshTarget: "sync.example.test"), coordinatorMachineId: "laptop")
    let set = BackupSet(id: UUID(), name: "Workspace", sources: ["/workspace"], schedule: .daily(hour: 2, minute: 0), destinations: [.init(id: UUID(), label: "Backup", repoURL: "/backup", isPrimary: true)], syncFolders: [group])
    let config = AppConfig(sets: [set])
    try config.validate()
    let decoded = try ConfigStore.makeDecoder().decode(AppConfig.self, from: ConfigStore.makeEncoder().encode(config))
    #expect(decoded.sets[0].sources == ["/workspace"])
    #expect(decoded.sets[0].syncFolders[0].localPath == "/workspace/shared-notes")
    #expect(decoded.sets[0].syncFolders[0].peer.path == "/srv/shared-notes")
}

@Test("a backup-only set has no implicit sync selection")
func backupOnlyNeverSyncs() throws {
    let set = BackupSet(id: UUID(), name: "Workspace", sources: ["/workspace"], schedule: .daily(hour: 2, minute: 0), destinations: [.init(id: UUID(), label: "Backup", repoURL: "/backup", isPrimary: true)])
    #expect(set.syncFolders.isEmpty)
    let encoded = try ConfigStore.makeEncoder().encode(set)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["syncFolders"] == nil)
    #expect(try ConfigStore.makeDecoder().decode(BackupSet.self, from: encoded).syncFolders.isEmpty)
}

@Test("a v5 upgrade preserves backup-only sources and the original config bytes")
func syncSchemaMigrationIsOptIn() throws {
    let root = try syncTemporaryRoot()
    let paths = AppPaths(root: root)
    try paths.ensureDirectories()
    defer { try? FileManager.default.removeItem(at: root) }
    let set = BackupSet(id: UUID(), name: "Workspace", sources: ["/workspace"], schedule: .daily(hour: 2, minute: 0), destinations: [.init(id: UUID(), label: "Archive", repoURL: "/archive", isPrimary: true)])
    let old = AppConfig(version: 5, sets: [set])
    let bytes = try ConfigStore.makeEncoder().encode(old)
    try bytes.write(to: paths.configFile)
    let store = ConfigStore(paths: paths)
    #expect(try store.load(.inspecting).sets == [set])
    #expect(try Data(contentsOf: paths.configFile) == bytes)
    let migrated = try store.load(.migrating)
    #expect(migrated.version == 6 && migrated.sets == [set])
    #expect(migrated.sets.allSatisfy { $0.syncFolders.isEmpty })
    #expect(try Data(contentsOf: paths.configBackupFile(fromVersion: 5)) == bytes)
}

@Test("initial sync refuses retention, purge rules and a shared repository")
func syncRecoveryHistoryCannotBePrunedByAnotherSet() throws {
    let group = SourceSyncGroup(name: "Notes", localPath: "/workspace/notes", peer: .init(path: "/other"), coordinatorMachineId: "laptop")
    var set = BackupSet(id: UUID(), name: "Workspace", sources: ["/workspace"], schedule: .daily(hour: 2, minute: 0), destinations: [.init(id: UUID(), label: "Archive", repoURL: "/archive", isPrimary: true)], syncFolders: [group])
    set.retention = .init(keepLast: 7)
    #expect(throws: ConfigError.self) { try AppConfig(sets: [set]).validate() }
    set.retention = nil; set.purgeExcludes = ["cache"]
    #expect(throws: ConfigError.self) { try AppConfig(sets: [set]).validate() }
    set.purgeExcludes = []
    var other = set
    other.id = UUID(); other.syncFolders = []; other.destinations[0].id = UUID()
    #expect(throws: ConfigError.self) { try AppConfig(sets: [set, other]).validate() }
    try AppConfig(sets: [set]).validate()
}
