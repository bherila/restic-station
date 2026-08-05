import Foundation
import Testing
@testable import ResticStationCore

// T24: v1 → v2 migration, driven by a realistic pre-change `config.json`
// (`Fixtures/config-v1.json` — two sets, three destinations, a Homebrew
// restic path, exactly what the macOS app writes today).
//
// The whole point of these tests is the acceptance criterion "existing v1
// configs load, migrate, and behave identically on the machine that authored
// them", plus the non-destructiveness rules: back up before the first v2
// write, never overwrite an existing backup, idempotent on a second run.

@Suite struct ConfigMigrationTests {

    private func makeStore() throws -> (store: ConfigStore, paths: AppPaths, cleanup: () -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("restic-station-migration-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        return (ConfigStore(paths: paths), paths, { try? FileManager.default.removeItem(at: root) })
    }

    /// Installs the v1 fixture as the store's `config.json`.
    @discardableResult
    private func installV1Fixture(at paths: AppPaths) throws -> Data {
        let data = try FixtureLoader.data("config-v1.json")
        try data.write(to: paths.configFile)
        return data
    }

    /// The machine identity the migrated `resticPath` lands in. Created up
    /// front so the tests do not depend on this host's hostname.
    private func installMachine(at paths: AppPaths, resticPath: String? = nil) throws {
        try MachineStore(paths: paths, environment: [:])
            .save(MachineConfig(machineId: "studio-mac", resticPath: resticPath))
    }

    // MARK: - The happy path

    @Test func loadingAV1ConfigBumpsTheVersionAndMovesResticPathIntoMachineJSON() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installV1Fixture(at: paths)
        try installMachine(at: paths)

        let migrated = try store.load()

        #expect(migrated.version == 2)
        // Moved, not copied: the deprecated field is cleared once the value
        // is safely recorded host-locally.
        #expect(migrated.resticPath == nil)
        #expect(try MachineStore(paths: paths, environment: [:]).load().resticPath == "/opt/homebrew/bin/restic")

        // …and it was persisted, so the next load is a plain v2 read.
        let onDisk = try ConfigStore.makeDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile))
        #expect(onDisk.version == 2)
        #expect(onDisk.resticPath == nil)
    }

    /// No `machines` keys are invented: absence already means "runs
    /// everywhere", so migration is a version bump and nothing else.
    @Test func migrationAddsNoMachinesKeys() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installV1Fixture(at: paths)
        try installMachine(at: paths)

        let migrated = try store.load()

        #expect(migrated.referencedMachineIds.isEmpty)
        for set in migrated.sets {
            #expect(set.machines == nil)
            for destination in set.destinations {
                #expect(destination.machines == nil)
            }
        }
        // Nothing in the file gained a `"machines"` key either.
        let text = try String(contentsOf: paths.configFile, encoding: .utf8)
        #expect(!text.contains("machines"))
    }

    /// The acceptance criterion, stated directly: everything the engine acts
    /// on is unchanged on the machine that authored the config.
    @Test func migratedConfigBehavesIdenticallyOnTheAuthoringMachine() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installV1Fixture(at: paths)
        try installMachine(at: paths)

        let before = try ConfigStore.makeDecoder().decode(AppConfig.self, from: FixtureLoader.data("config-v1.json"))
        let migrated = try store.load()
        let machine = try MachineStore(paths: paths, environment: [:]).load()
        let after = migrated.resolved(for: machine).config

        #expect(after.sets == before.sets)
        #expect(after.showMenuBarIcon == before.showMenuBarIcon)
        #expect(after.onboardingCompleted == before.onboardingCompleted)
        // The effective restic binary is the same one, just read from its new
        // home.
        #expect(after.resticPath == before.resticPath)
    }

    // MARK: - Non-destructiveness

    @Test func theV1FileIsBackedUpVerbatimBeforeTheFirstV2Write() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        let original = try installV1Fixture(at: paths)
        try installMachine(at: paths)

        _ = try store.load()

        #expect(FileManager.default.fileExists(atPath: paths.configV1BackupFile.path))
        #expect(try Data(contentsOf: paths.configV1BackupFile) == original)
        #expect(paths.configV1BackupFile.lastPathComponent == "config.v1.backup.json")
    }

    @Test func migrationIsIdempotentAndNeverOverwritesAnExistingBackup() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installV1Fixture(at: paths)
        try installMachine(at: paths)

        let first = try store.load()
        let backupAfterFirst = try Data(contentsOf: paths.configV1BackupFile)
        let fileAfterFirst = try Data(contentsOf: paths.configFile)

        let second = try store.load()

        #expect(second == first)
        #expect(try Data(contentsOf: paths.configV1BackupFile) == backupAfterFirst)
        #expect(try Data(contentsOf: paths.configFile) == fileAfterFirst)
    }

    /// Even a *hand-made* backup file is sacred: a user who put their own
    /// copy there must get it back untouched.
    @Test func aPreExistingBackupIsLeftAlone() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installV1Fixture(at: paths)
        try installMachine(at: paths)

        let sentinel = Data("{\"this\":\"was here first\"}".utf8)
        try sentinel.write(to: paths.configV1BackupFile)

        _ = try store.load()

        #expect(try Data(contentsOf: paths.configV1BackupFile) == sentinel)
        // The migration still happened.
        let onDisk = try ConfigStore.makeDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile))
        #expect(onDisk.version == 2)
    }

    /// A v1 config that is *invalid* is a hard error at its own version — it
    /// must not produce a backup file or a rewritten config.json.
    @Test func anInvalidV1ConfigThrowsAndMigratesNothing() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }

        let badJSON = """
        {"version":1,"resticPath":"/usr/bin/restic","showMenuBarIcon":true,"sets":[\
        {"id":"\(UUID().uuidString)","name":"x","sources":[],"excludes":[],\
        "schedule":{"kind":"daily","hour":1,"minute":1},"retention":null,"checkPolicy":null,\
        "stalenessWarningDays":14,"destinations":[]}]}
        """
        let original = Data(badJSON.utf8)
        try original.write(to: paths.configFile)

        #expect(throws: ConfigError.self) {
            _ = try store.load()
        }
        #expect(!FileManager.default.fileExists(atPath: paths.configV1BackupFile.path))
        #expect(try Data(contentsOf: paths.configFile) == original)
    }

    // MARK: - resticPath relocation edge cases

    /// `machine.json` already knowing a path wins: migration must not
    /// overwrite this host's own binary with the one the config was authored
    /// against.
    @Test func anExistingMachineResticPathIsNotOverwritten() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installV1Fixture(at: paths)
        try installMachine(at: paths, resticPath: "/usr/local/bin/restic")

        let migrated = try store.load()

        #expect(try MachineStore(paths: paths, environment: [:]).load().resticPath == "/usr/local/bin/restic")
        #expect(migrated.resticPath == nil)
    }

    /// A v1 config with no restic path at all migrates cleanly and leaves
    /// `machine.json` alone.
    @Test func aV1ConfigWithoutAResticPathMigratesWithoutTouchingMachineJSON() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installMachine(at: paths)

        let json = #"{"version":1,"resticPath":null,"showMenuBarIcon":true,"sets":[]}"#
        try Data(json.utf8).write(to: paths.configFile)

        let migrated = try store.load()

        #expect(migrated.version == 2)
        #expect(migrated.resticPath == nil)
        #expect(try MachineStore(paths: paths, environment: [:]).load().resticPath == nil)
    }

    /// `machine.json` is auto-created if the migration is the first thing
    /// that ever needed it.
    @Test func migrationCreatesMachineJSONWhenItDoesNotExistYet() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installV1Fixture(at: paths)

        _ = try store.load()

        #expect(FileManager.default.fileExists(atPath: paths.machineFile.path))
        let machine = try MachineStore(paths: paths, environment: [:]).load()
        #expect(MachineIdentity.isValid(machine.machineId))
        #expect(machine.resticPath == "/opt/homebrew/bin/restic")
    }

    // MARK: - No migration where none is due

    @Test func aV2ConfigIsNotMigratedAndProducesNoBackup() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        let original = try FixtureLoader.data("config-v2.json")
        try original.write(to: paths.configFile)

        let loaded = try store.load()

        #expect(loaded.version == 2)
        #expect(!FileManager.default.fileExists(atPath: paths.configV1BackupFile.path))
        #expect(try Data(contentsOf: paths.configFile) == original)
    }

    @Test func aNewerVersionStillRefusesToLoad() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try Data(#"{"version":999,"resticPath":null,"showMenuBarIcon":true,"sets":[]}"#.utf8)
            .write(to: paths.configFile)

        #expect(throws: ConfigError.newerVersion(found: 999, supported: AppConfig.currentVersion)) {
            _ = try store.load()
        }
        #expect(!FileManager.default.fileExists(atPath: paths.configV1BackupFile.path))
    }
}
