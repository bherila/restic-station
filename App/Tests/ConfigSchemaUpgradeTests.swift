import Foundation
import ResticStationCore
import Testing
@testable import Restic_Station

/// #161: the app never rewrites an older-schema `config.json` without the
/// user confirming it, and any migration this host writes stays visible
/// until acknowledged.
@Suite("Config schema upgrade is explicit in the app", .serialized)
@MainActor
struct ConfigSchemaUpgradeTests {
    private func legacyPaths(version: Int) throws -> (AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-schema-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root)
        try ConfigStore.makeEncoder().encode(AppConfig(version: version))
            .write(to: paths.configFile, options: .atomic)
        return (paths, root)
    }

    @Test("an older schema is read-only, and a plain reload does not rewrite it")
    func legacyIsReadOnlyUntilConfirmed() async throws {
        let (paths, root) = try legacyPaths(version: AppConfig.currentVersion - 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: paths.configFile)

        let model = AppModel(paths: paths)
        await model.reloadConfigFromDisk()

        let offer = try #require(model.pendingSchemaUpgrade)
        #expect(offer.fromVersion == AppConfig.currentVersion - 1)
        #expect(offer.toVersion == AppConfig.currentVersion)
        #expect(try Data(contentsOf: paths.configFile) == before)
        #expect(!model.configChangedOnDisk)
        do {
            _ = try model.saveConfig(AppConfig(), ifUnchangedFrom: model.configFingerprint)
            Issue.record("saving an older-schema config must wait for the upgrade")
        } catch AppModelError.configUnreadable(let message) {
            #expect(message == offer.readOnlyReason)
        }
    }

    @Test("confirming upgrades the file, records it, and acknowledging clears the warning")
    func confirmRecordsAndAcknowledges() async throws {
        let from = AppConfig.currentVersion - 1
        let (paths, root) = try legacyPaths(version: from)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(paths: paths)
        await model.upgradeConfigSchema()

        #expect(model.pendingSchemaUpgrade == nil)
        #expect(try ConfigStore(paths: paths).reconciliationSnapshot().config.version == AppConfig.currentVersion)
        #expect(FileManager.default.fileExists(atPath: paths.configBackupFile(fromVersion: from).path))
        let record = try #require(StateStore(paths: paths).readConfigMigration())
        #expect(record.fromVersion == from)
        #expect(record.toVersion == AppConfig.currentVersion)
        #expect(record.needsAcknowledgement)

        model.stateWatcher.reloadNow()
        model.refresh()
        #expect(model.unacknowledgedConfigMigration?.fromVersion == from)
        #expect(model.appHealth == .warning || model.appHealth == .critical)

        model.acknowledgeConfigMigration()
        #expect(model.unacknowledgedConfigMigration == nil)
        #expect(StateStore(paths: paths).readConfigMigration()?.needsAcknowledgement == false)
    }

    @Test("a migration written by another process on this host is picked up")
    func helperMigrationIsNoticed() async throws {
        let (paths, root) = try legacyPaths(version: AppConfig.currentVersion - 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: paths)
        #expect(model.unacknowledgedConfigMigration == nil)

        // What a scheduled tick does: ConfigStore.load() migrates and records.
        _ = try ConfigStore(paths: paths).load()
        // The model follows the file on its own while an upgrade is pending.
        for _ in 0..<200 where model.pendingSchemaUpgrade != nil || model.unacknowledgedConfigMigration == nil {
            model.refresh()
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(model.unacknowledgedConfigMigration != nil)
        #expect(model.pendingSchemaUpgrade == nil)
        #expect(model.config.version == AppConfig.currentVersion)
    }

    @Test("a pending offer follows the file when the helper migrates it in the background")
    func pendingOfferFollowsBackgroundMigration() async throws {
        let (paths, root) = try legacyPaths(version: AppConfig.currentVersion - 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: paths)
        model.start()
        defer { model.stop() }
        // Let start()'s own reload finish first, so only following the file
        // can clear the offer below.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.pendingSchemaUpgrade != nil)

        _ = try ConfigStore(paths: paths).load()   // what a scheduled tick does
        for _ in 0..<200 where model.pendingSchemaUpgrade != nil {
            model.refresh()
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(model.pendingSchemaUpgrade == nil)
        #expect(model.config.version == AppConfig.currentVersion)
        #expect(!model.configChangedOnDisk)
        #expect(model.unacknowledgedConfigMigration != nil)
    }

    @Test("the offer only exists for an older schema")
    func offerOnlyForOlderSchema() {
        #expect(SchemaUpgradeOffer(fileVersion: AppConfig.currentVersion) == nil)
        #expect(SchemaUpgradeOffer(fileVersion: AppConfig.currentVersion + 1) == nil)
        let offer = SchemaUpgradeOffer(fileVersion: 3, current: 4)
        #expect(offer?.confirmationMessage.contains("backups stop") == true)
        #expect(offer?.confirmationMessage.contains("config.v3.backup.json") == true)
    }
}
