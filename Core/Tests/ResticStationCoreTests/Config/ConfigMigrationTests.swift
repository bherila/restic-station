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

        #expect(migrated.version == 3)
        // Moved, not copied: the deprecated field is cleared once the value
        // is safely recorded host-locally.
        #expect(migrated.resticPath == nil)
        #expect(try MachineStore(paths: paths, environment: [:]).load().resticPath == "/opt/homebrew/bin/restic")

        // …and it was persisted, so the next load is a plain v2 read.
        let onDisk = try ConfigStore.makeDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile))
        #expect(onDisk.version == 3)
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
        #expect(onDisk.version == 3)
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

        #expect(migrated.version == 3)
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

    /// A v2 config *is* migrated to v3 (only `purgeExcludes` decoding-in as
    /// `[]` changes, per `BackupSet.init(from:)`), and the pre-migration v2
    /// bytes land in `config.v2.backup.json` — keyed by the version being
    /// migrated *from*, not the fixed `config.v1.backup.json`.
    @Test func aV2ConfigIsMigratedToV3AndBacksUpTheV2Bytes() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        let original = try FixtureLoader.data("config-v2.json")
        try original.write(to: paths.configFile)
        let before = try ConfigStore.makeDecoder().decode(AppConfig.self, from: original)

        let loaded = try store.load()

        #expect(loaded.version == 3)
        // Nothing else about the config changed — every set's purgeExcludes
        // decoded to [] and every other field is untouched.
        for set in loaded.sets {
            #expect(set.purgeExcludes == [])
        }
        #expect(loaded.resticPath == before.resticPath)
        #expect(loaded.showMenuBarIcon == before.showMenuBarIcon)
        #expect(loaded.onboardingCompleted == before.onboardingCompleted)
        #expect(loaded.sets.map(\.id) == before.sets.map(\.id))

        // The v2 file is never touched — only its own version-keyed backup.
        #expect(!FileManager.default.fileExists(atPath: paths.configV1BackupFile.path))
        let v2Backup = paths.configBackupFile(fromVersion: 2)
        #expect(v2Backup.lastPathComponent == "config.v2.backup.json")
        #expect(FileManager.default.fileExists(atPath: v2Backup.path))
        #expect(try Data(contentsOf: v2Backup) == original)

        // ...and config.json itself now holds the migrated (v3) content.
        let onDisk = try ConfigStore.makeDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile))
        #expect(onDisk.version == 3)
    }

    // MARK: - The backup-file-per-version fix

    /// The bug the version-keyed backup filename exists to fix: a host that
    /// migrated v1 → v2 long ago already has `config.v1.backup.json` on
    /// disk. A later v2 → v3 migration must not mistake that file for its
    /// own backup — it needs its own `config.v2.backup.json`, and the v1
    /// file must be left exactly as it was.
    @Test func aV2ToV3MigrationWritesItsOwnBackupEvenWhenAV1BackupAlreadyExists() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        let original = try FixtureLoader.data("config-v2.json")
        try original.write(to: paths.configFile)

        let preexistingV1Backup = Data(#"{"this":"is the old v1 backup, from years ago"}"#.utf8)
        try preexistingV1Backup.write(to: paths.configV1BackupFile)

        let loaded = try store.load()

        #expect(loaded.version == 3)
        // The v1 backup is untouched...
        #expect(try Data(contentsOf: paths.configV1BackupFile) == preexistingV1Backup)
        // ...and a *separate*, correct v2 backup was written alongside it,
        // recoverable verbatim.
        let v2Backup = paths.configBackupFile(fromVersion: 2)
        #expect(FileManager.default.fileExists(atPath: v2Backup.path))
        #expect(try Data(contentsOf: v2Backup) == original)
    }

    /// Idempotent the same way the v1 migration is: a second load must not
    /// clobber the v2 backup a first load already wrote.
    @Test func migrationIsIdempotentAndNeverOverwritesAnExistingV2Backup() throws {
        let (store, paths, cleanup) = try makeStore()
        defer { cleanup() }
        let original = try FixtureLoader.data("config-v2.json")
        try original.write(to: paths.configFile)

        let first = try store.load()
        let v2Backup = paths.configBackupFile(fromVersion: 2)
        let backupAfterFirst = try Data(contentsOf: v2Backup)
        let fileAfterFirst = try Data(contentsOf: paths.configFile)

        let second = try store.load()

        #expect(second == first)
        #expect(try Data(contentsOf: v2Backup) == backupAfterFirst)
        #expect(try Data(contentsOf: paths.configFile) == fileAfterFirst)
    }

    /// When the backup write fails, `config.json` must be left alone —
    /// mirroring the v1 guard this suite exercises end-to-end at
    /// `migrateToCurrentVersionPerformsSideEffectsWithoutInstalling`'s
    /// comment. Reproduced without `chmod`, which the note there explains
    /// does not stop a CI container running as root: a plain *file* sits
    /// where `locks/` needs to become a directory, so
    /// `paths.ensureDirectories()` fails for anyone, root included, because
    /// `mkdir` cannot replace an existing file regardless of privilege.
    @Test func whenTheBackupCannotBeWrittenConfigJSONIsLeftAlone() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("restic-station-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root)
        let store = ConfigStore(paths: paths)

        let original = try FixtureLoader.data("config-v2.json")
        try original.write(to: paths.configFile)
        try Data().write(to: paths.locksDir) // a file, not a directory

        let loaded = try store.load()

        // With no usable config lock, the store must not even produce an
        // in-memory migrated value: another process could concurrently write
        // config.json while migration performs its machine and backup side
        // effects. The original version remains readable, but migration waits
        // for a later load that can acquire the lock.
        #expect(loaded.version == 2)
        // Nothing was persisted: no backup, and config.json is unchanged.
        #expect(!FileManager.default.fileExists(atPath: paths.configBackupFile(fromVersion: 2).path))
        #expect(try Data(contentsOf: paths.configFile) == original)
        let onDisk = try ConfigStore.makeDecoder().decode(AppConfig.self, from: Data(contentsOf: paths.configFile))
        #expect(onDisk.version == 2)
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
        #expect(result.config.version == 3)
        #expect(result.config.resticPath == nil)
        // Side effects (v1 backup, machine.json adoption) happened...
        #expect(FileManager.default.fileExists(atPath: paths.configV1BackupFile.path))
        #expect(try MachineStore(paths: paths, environment: [:]).load().resticPath == "/opt/homebrew/bin/restic")
        // ...but config.json itself was never written by this call. This is
        // the property `load()`'s `guard migration.backupWritten else { return … }`
        // depends on: since this call is the *only* way `config.json` could
        // be installed as a side effect of migrating, and it provably never
        // does that, the guard is the only remaining code path that can.
        //
        // (An earlier version of this file also had an end-to-end variant —
        // chmod `root` read-only, call `load()`, assert `config.json` kept
        // its pre-migration bytes — which I dropped after the red-check this
        // task's instructions ask for went two ways: it did not actually
        // isolate the guard, since `writeV1BackupIfAbsent` and `save(_:)`
        // both create a *new* file in the same directory and so fail or
        // succeed together under plain POSIX permissions; and it failed for
        // an unrelated reason in CI, where the Linux job's container runs as
        // root and `chmod` does not stop root from writing at all. Both
        // problems trace to the same root cause — permission-based
        // filesystem tests do not isolate the specific write they intend to
        // deny — so the honest fix was to remove it rather than patch around
        // a fake positive.)
    }

    /// `previewMigration` is a pure version bump: no `machine.json` access,
    /// no `resticPath` relocation, no disk I/O of any kind — the property
    /// `config import --dry-run` depends on.
    @Test func previewMigrationTouchesNothingOnDisk() throws {
        let decoded = try ConfigStore.makeDecoder().decode(AppConfig.self, from: FixtureLoader.data("config-v1.json"))

        let preview = ConfigStore.previewMigration(decoded)

        #expect(preview.version == 3)
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
