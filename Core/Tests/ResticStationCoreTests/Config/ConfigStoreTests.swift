import Foundation
import Testing
@testable import ResticStationCore

@Suite struct ConfigStoreTests {
    private func makeStore() -> (store: ConfigStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-configstore-test-\(UUID().uuidString)")
        return (ConfigStore(paths: AppPaths(root: root)), root)
    }

    private func sampleConfig() -> AppConfig {
        let set = BackupSet(
            id: UUID(),
            name: "Sample",
            sources: ["/src"],
            excludes: ["*.tmp"],
            schedule: .daily(hour: 3, minute: 0),
            retention: RetentionPolicy(keepDaily: 7),
            checkPolicy: CheckPolicy(enabled: true, readDataSubsetSlices: 20),
            stalenessWarningDays: 14,
            destinations: [
                Destination(id: UUID(), label: "Primary", repoURL: "/repo", isPrimary: true)
            ]
        )
        return AppConfig(resticPath: "/usr/local/bin/restic", sets: [set])
    }

    @Test func loadMissingFileReturnsDefaultEmptyConfig() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = try store.load()
        #expect(config == AppConfig())
        #expect(config.version == AppConfig.currentVersion)
        #expect(config.resticPath == nil)
        #expect(config.showMenuBarIcon == true)
        #expect(config.sets.isEmpty)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = sampleConfig()
        try store.save(config)

        let loaded = try store.load()
        #expect(loaded == config)
    }

    @Test("compare-and-swap save installs the revision it began from")
    func compareAndSwapSaveSucceedsForUnchangedRevision() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.save(sampleConfig())
        let snapshot = try store.snapshot()
        var edited = snapshot.config
        edited.showMenuBarIcon.toggle()

        let installedFingerprint = try store.save(
            edited,
            ifUnchangedFrom: snapshot.fingerprint
        )

        #expect(try store.load() == edited)
        #expect(installedFingerprint == store.fileFingerprint())
    }

    @Test("compare-and-swap save preserves a replacement made after editing began")
    func compareAndSwapSaveRefusesChangedRevision() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.save(sampleConfig())
        let editingSnapshot = try store.snapshot()
        var staleEdit = editingSnapshot.config
        staleEdit.showMenuBarIcon.toggle()

        var externalReplacement = editingSnapshot.config
        externalReplacement.sets[0].name = "Fleet replacement"
        try store.save(externalReplacement)

        #expect(throws: ConfigStoreError.changedOnDisk) {
            try store.save(staleEdit, ifUnchangedFrom: editingSnapshot.fingerprint)
        }
        #expect(try store.load() == externalReplacement)
        #expect(!FileManager.default.fileExists(atPath: store.tempConfigFile.path))
    }

    @Test("config writers refuse contention without touching the installed file")
    func configWriteLockSerializesWriters() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let installed = sampleConfig()
        try store.save(installed)
        let lock = FileLock(path: store.paths.configLockFile, trustedRoot: root)
        #expect(lock.acquire() == .acquired)
        defer { lock.release() }

        var competing = installed
        competing.showMenuBarIcon.toggle()
        #expect(throws: ConfigStoreError.writeLockBusy(path: store.paths.configLockFile.path)) {
            try store.save(competing)
        }
        #expect(try store.load() == installed)
    }

    @Test func saveCreatesDirectoriesIfMissing() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.save(sampleConfig())

        for directory in [store.paths.root, store.paths.runsDir, store.paths.stateDir, store.paths.locksDir] {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            #expect(values.isDirectory == true)
        }
    }

    @Test func saveRejectsInvalidConfigAndDoesNotWriteFile() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var invalid = sampleConfig()
        invalid.sets[0].destinations[0].isPrimary = false // zero primaries

        #expect(throws: ConfigError.self) {
            try store.save(invalid)
        }
        #expect(!FileManager.default.fileExists(atPath: store.paths.configFile.path))
    }

    @Test func loadOfInvalidPersistedConfigThrows() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.paths.ensureDirectories()
        let badJSON = """
        {"version":1,"resticPath":null,"showMenuBarIcon":true,"sets":[{"id":"\(UUID().uuidString)","name":"x","sources":[],"excludes":[],"schedule":{"kind":"daily","hour":1,"minute":1},"retention":null,"checkPolicy":null,"stalenessWarningDays":14,"destinations":[]}]}
        """
        try Data(badJSON.utf8).write(to: store.paths.configFile)

        #expect(throws: ConfigError.self) {
            _ = try store.load()
        }
    }

    @Test func loadOfNewerVersionThrowsNewerVersion() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.paths.ensureDirectories()
        let futureJSON = """
        {"version":999,"resticPath":null,"showMenuBarIcon":true,"sets":[]}
        """
        try Data(futureJSON.utf8).write(to: store.paths.configFile)

        #expect(throws: ConfigError.newerVersion(found: 999, supported: AppConfig.currentVersion)) {
            _ = try store.load()
        }
    }

    // MARK: - Atomicity

    @Test func saveOverwritesPreExistingCorruptTempFile() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.paths.ensureDirectories()
        // Simulate a crash that left a stale/corrupt temp file behind from a
        // previous, interrupted save.
        try Data("not valid json at all {{{".utf8).write(to: store.tempConfigFile)

        let config = sampleConfig()
        try store.save(config)

        // The corrupt temp file must not survive, and the real config must
        // be exactly what was just saved.
        let loaded = try store.load()
        #expect(loaded == config)
    }

    @Test func savedFileNeverObservedPartiallyWritten() throws {
        // The temp file is written first and only rename(2)'d over the
        // destination at the end — the destination config.json must not
        // exist mid-write. We can't observe a genuine race here without a
        // second thread mid-syscall, but we can assert the two-step
        // mechanism directly: after save(), the temp file is gone and the
        // destination holds fully valid, parseable JSON.
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.save(sampleConfig())

        #expect(!FileManager.default.fileExists(atPath: store.tempConfigFile.path))
        #expect(FileManager.default.fileExists(atPath: store.paths.configFile.path))
        let data = try Data(contentsOf: store.paths.configFile)
        _ = try JSONSerialization.jsonObject(with: data) // must not throw
    }

    @Test func encodedFileUsesSortedKeysAndPrettyPrinted() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.save(sampleConfig())
        let contents = try String(contentsOf: store.paths.configFile, encoding: .utf8)

        // .prettyPrinted -> multi-line; .sortedKeys -> "resticPath" (r)
        // appears after "destinations"-less top-level "sets" alphabetically:
        // resticPath, sets, showMenuBarIcon, version.
        #expect(contents.contains("\n"))
        let resticPathRange = contents.range(of: "\"resticPath\"")
        let versionRange = contents.range(of: "\"version\"")
        #expect(resticPathRange != nil)
        #expect(versionRange != nil)
        if let resticPathRange, let versionRange {
            #expect(resticPathRange.lowerBound < versionRange.lowerBound)
        }
    }
}
