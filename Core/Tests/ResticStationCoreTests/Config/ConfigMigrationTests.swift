import Foundation
import Testing
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// T24: v1 → v2 migration, driven by a realistic pre-change `config.json`
// (`Fixtures/config-v1.json` — two sets, three destinations, a Homebrew
// restic path, exactly what the macOS app writes today).
//
// The whole point of these tests is the acceptance criterion "existing v1
// configs load, migrate, and behave identically on the machine that authored
// them", plus the non-destructiveness rules: back up before the first v2
// write, never overwrite an existing backup, idempotent on a second run.

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

/// The machine identity the migrated `resticPath` lands in. Created up front
/// so the tests do not depend on this host's hostname.
private func installMachine(at paths: AppPaths, resticPath: String? = nil) throws {
    try MachineStore(paths: paths, environment: [:])
        .save(MachineConfig(machineId: "studio-mac", resticPath: resticPath))
}

@Suite struct ConfigMigrationTests {

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

    /// The seam the migration path relies on, in isolation.
    @Test func persistentIdentityStoreIgnoresTheEnvironmentOverride() throws {
        let (_, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installMachine(at: paths)

        #expect(try MachineStore.persistentIdentity(paths: paths).load().machineId == "studio-mac")
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

    // MARK: - migrateToCurrentVersion as a standalone, reusable step (T27 `config import`)

    /// The split that T27's `config import` relies on: `migrateToCurrentVersion`
    /// performs the side effects (resticPath adoption, v1 backup) but leaves
    /// installing the result as `config.json` to the caller.
    @Test func migrateToCurrentVersionPerformsSideEffectsWithoutInstalling() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installMachine(at: paths)
        let original = try FixtureLoader.data("config-v1.json")
        let decoded = try ConfigStore.makeDecoder().decode(AppConfig.self, from: original)

        let result = store.migrateToCurrentVersion(decoded, originalBytes: original)

        #expect(result.backupWritten)
        #expect(result.config.version == 2)
        #expect(result.config.resticPath == nil)
        // Side effects (v1 backup, machine.json adoption) happened...
        #expect(FileManager.default.fileExists(atPath: paths.configV1BackupFile.path))
        #expect(try MachineStore(paths: paths, environment: [:]).load().resticPath == "/opt/homebrew/bin/restic")
        // ...but config.json itself was never written by this call.
        #expect(!FileManager.default.fileExists(atPath: paths.configFile.path))
    }

    /// End-to-end guarantee: when the data directory cannot be written at
    /// all, `config.json` keeps its old (pre-migration) bytes rather than
    /// being corrupted or left half-migrated.
    ///
    /// Honest caveat about what this test can and cannot isolate: both the
    /// v1-backup write and the final `save(_:)` write create a *new* file in
    /// the same directory (`root`), so under plain POSIX permissions the two
    /// always fail or succeed *together* — a chmod on `root` cannot fail one
    /// while letting the other through. I attempted the red-check this
    /// task's instructions ask for — temporarily deleting `load()`'s `guard
    /// migration.backupWritten else { return … }` — and this test kept
    /// passing with the bug present, because `save(_:)` fails for the same
    /// permission reason regardless of the guard. It is therefore an
    /// end-to-end regression test for "total write failure never corrupts
    /// config.json", not an isolated pin of that one `guard`. The `guard`
    /// itself is exercised structurally by
    /// `migrateToCurrentVersionPerformsSideEffectsWithoutInstalling` above,
    /// which pins the call boundary the guard depends on: that
    /// `migrateToCurrentVersion(_:originalBytes:)` never installs
    /// `config.json` itself, so `load()`'s explicit guard is the *only* code
    /// path that can.
    @Test func loadNeverInstallsTheMigratedConfigWhenTheV1BackupCannotBeWritten() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installV1Fixture(at: paths)
        try installMachine(at: paths)

        // Make `root` unwritable so `writeV1BackupIfAbsent`'s
        // `original.write(to:...)` fails with EACCES — the file does not
        // already exist, so this genuinely exercises the write failure path
        // rather than the "already backed up" short circuit.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.root.path) }

        let migrated = try store.load()

        // In-memory value is still correct (best-effort semantics)...
        #expect(migrated.version == 2)
        // ...but config.json on disk was NOT overwritten with it, and no v1
        // backup was written either.
        #expect(!FileManager.default.fileExists(atPath: paths.configV1BackupFile.path))
        let onDisk = try ConfigStore.makeDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile))
        #expect(onDisk.version == 1)
    }

    /// `previewMigration` is a pure version bump: no `machine.json` access,
    /// no `resticPath` relocation, no disk I/O of any kind — the property
    /// `config import --dry-run` depends on.
    @Test func previewMigrationTouchesNothingOnDisk() throws {
        let decoded = try ConfigStore.makeDecoder().decode(AppConfig.self, from: FixtureLoader.data("config-v1.json"))

        let preview = ConfigStore.previewMigration(decoded)

        #expect(preview.version == 2)
        // resticPath is left exactly as decoded — previewMigration does not
        // simulate the relocation.
        #expect(preview.resticPath == decoded.resticPath)
    }
}

// MARK: - The environment override must never be persisted

/// `RESTIC_STATION_MACHINE_ID` is documented as non-persistent: it changes the
/// `machineId` a process *uses*, never the one on disk.
///
/// Migration is the one code path that does a load-mutate-save round trip on
/// `machine.json` for a reason unrelated to identity (relocating
/// `resticPath`), so it is the one place that promise can be broken. If it
/// were, the host would be permanently rebound to a temporary test/profile
/// id and would apply the wrong `machines` overrides ever after — the
/// variable does not need to still be set for the damage to persist.
///
/// These tests genuinely set the process variable: injecting it would not
/// reproduce the bug, because the code under test reads `ProcessInfo`.
/// `.serialized` for the usual reason — nothing else may observe the
/// mutation. `MachineStore` is the only reader of this variable, and every
/// other test in the package injects its environment explicitly.
@Suite(.serialized)
struct ConfigMigrationEnvironmentOverrideTests {

    private func withMachineIdOverride<T>(_ value: String, _ body: () throws -> T) rethrows -> T {
        let original = ProcessInfo.processInfo.environment[MachineIdentity.environmentOverrideKey]
        func apply(_ newValue: String?) {
            if let newValue {
                setenv(MachineIdentity.environmentOverrideKey, newValue, 1)
            } else {
                unsetenv(MachineIdentity.environmentOverrideKey)
            }
        }
        apply(value)
        defer { apply(original) }
        return try body()
    }

    /// `machine.json` already exists: its `machineId` must survive migration.
    @Test func migrationKeepsTheOnDiskIdentityWhenTheOverrideIsSet() throws {
        let (_, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installV1Fixture(at: paths)
        try installMachine(at: paths) // machineId "studio-mac", no resticPath

        // The `ConfigStore` is built *inside* the override, because
        // `MachineStore` snapshots the environment at construction. A real
        // helper or app process is launched with the variable already set,
        // so building it beforehand would not reproduce the bug.
        //
        // Assertions live outside the closure: `#expect` cannot carry a `try`
        // across the `rethrows` boundary.
        let idSeenUnderOverride = try withMachineIdOverride("second-profile") { () -> String in
            let seen = try MachineStore(paths: paths).load().machineId
            _ = try ConfigStore(paths: paths).load()
            return seen
        }
        // Precondition: the override really was visible to a normal store.
        #expect(idSeenUnderOverride == "second-profile")

        let onDisk = try MachineStore.persistentIdentity(paths: paths).load()
        #expect(onDisk.machineId == "studio-mac")               // not "second-profile"
        #expect(onDisk.resticPath == "/opt/homebrew/bin/restic") // migration still ran
    }

    /// `machine.json` does not exist yet: the identity created during
    /// migration must be the generated one, not the override.
    @Test func migrationCreatesTheGeneratedIdentityWhenTheOverrideIsSet() throws {
        let (_, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installV1Fixture(at: paths)

        try withMachineIdOverride("second-profile") {
            _ = try ConfigStore(paths: paths).load()
        }

        let onDisk = try MachineStore.persistentIdentity(paths: paths).load()
        #expect(onDisk.machineId != "second-profile")
        #expect(MachineIdentity.isValid(onDisk.machineId))
        #expect(onDisk.resticPath == "/opt/homebrew/bin/restic")
    }

    /// And the override still does what it is for: it changes the id this
    /// process resolves against, without touching the file.
    @Test func theOverrideStillAppliesInMemoryOnly() throws {
        let (_, paths, cleanup) = try makeStore()
        defer { cleanup() }
        try installMachine(at: paths)

        let underOverride = try withMachineIdOverride("second-profile") { () -> (String, String) in
            (
                try MachineStore(paths: paths).load().machineId,
                try MachineStore.persistentIdentity(paths: paths).load().machineId
            )
        }
        #expect(underOverride.0 == "second-profile")
        #expect(underOverride.1 == "studio-mac")
        // Once the variable is gone, the normal store sees the real identity.
        #expect(try MachineStore(paths: paths).load().machineId == "studio-mac")
    }
}
