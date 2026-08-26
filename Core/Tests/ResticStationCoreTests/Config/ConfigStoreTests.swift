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

    @Test("compare-and-swap creates config only while the expected state is absent")
    func compareAndSwapSaveFromAbsentRevision() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let emptySnapshot = try store.snapshot()
        #expect(emptySnapshot.fingerprint == "absent")
        let config = sampleConfig()
        let installedFingerprint = try store.save(
            config,
            ifUnchangedFrom: emptySnapshot.fingerprint
        )

        #expect(try store.load() == config)
        #expect(installedFingerprint == store.fileFingerprint())
    }

    @Test("compare-and-swap never overwrites a file that appeared after an absent snapshot")
    func compareAndSwapSaveRefusesAnAbsentRevisionThatAppeared() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let emptySnapshot = try store.snapshot()
        var replacement = sampleConfig()
        replacement.sets[0].name = "Fleet replacement"
        try store.save(replacement)

        #expect(throws: ConfigStoreError.changedOnDisk) {
            try store.save(sampleConfig(), ifUnchangedFrom: emptySnapshot.fingerprint)
        }
        #expect(try store.load() == replacement)
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

    #if canImport(Darwin)
    @Test("CAS rollback keeps a raw replacement that landed after the exchange live")
    func rollbackDoesNotDemoteNewerReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-cas-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let displaced = root.appendingPathComponent("config.json.tmp")
        let destination = root.appendingPathComponent("config.json")
        let older = Data("older fleet revision".utf8)
        let candidate = Data("stale app candidate".utf8)
        let newest = Data("newest fleet revision".utf8)
        try older.write(to: displaced)
        // This is the exact state after a raw writer replaces config.json
        // between the initial exchange and the refused-save rollback.
        try newest.write(to: destination)

        let removedCandidate = try AtomicFile.rollbackCandidateIfCurrent(
            displaced: displaced,
            destination: destination,
            candidateFingerprint: SHA256Digest.hex(candidate)
        )

        #expect(!removedCandidate)
        #expect(try Data(contentsOf: destination) == newest)
        #expect(!FileManager.default.fileExists(atPath: displaced.path))
    }

    @Test("CAS rollback preserves a raw deletion that landed after the exchange")
    func rollbackDoesNotResurrectDeletedConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-cas-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let displaced = root.appendingPathComponent("config.json.tmp")
        let destination = root.appendingPathComponent("config.json")
        try Data("older fleet revision".utf8).write(to: displaced)

        let removedCandidate = try AtomicFile.rollbackCandidateIfCurrent(
            displaced: displaced,
            destination: destination,
            candidateFingerprint: SHA256Digest.hex(Data("stale app candidate".utf8))
        )

        #expect(!removedCandidate)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: displaced.path))
    }
    #endif

    @Test("a stale preflight refuses before a related external side effect")
    func unchangedAssertionRefusesAStaleRevision() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.save(sampleConfig())
        let editingSnapshot = try store.snapshot()
        var replacement = editingSnapshot.config
        replacement.sets[0].name = "Fleet replacement"
        try store.save(replacement)

        #expect(throws: ConfigStoreError.changedOnDisk) {
            try store.assertUnchanged(from: editingSnapshot.fingerprint)
        }
        #expect(try store.load() == replacement)
    }

    @Test("config writers refuse contention without touching the installed file")
    func configWriteLockSerializesWriters() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let installed = sampleConfig()
        try store.save(installed)
        let lock = FileLock(path: store.paths.configLockFile, trustedRoot: root)
        #expect(lock.acquire() == .acquired)

        var competing = installed
        competing.showMenuBarIcon.toggle()
        #expect(throws: ConfigStoreError.writeLockBusy(path: store.paths.configLockFile.path)) {
            try store.save(competing)
        }
        lock.release()
        #expect(try store.load() == installed)
    }

    @Test("uncertain recovery reads the live config without waiting on the write lock")
    func reconciliationSnapshotDoesNotWaitForWriter() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = sampleConfig()
        try store.save(config)
        let heldLock = FileLock(path: store.paths.configLockFile, trustedRoot: root)
        #expect(heldLock.acquire() == .acquired)
        defer { heldLock.release() }

        let snapshot = try store.reconciliationSnapshot()

        #expect(snapshot.config == config)
        #expect(snapshot.fingerprint == store.fileFingerprint())
    }

    @Test("rollback artifact preservation failure remains an uncertain commit")
    func rollbackArtifactPreservationFailureIsUncertain() {
        let error = ConfigStoreError.rollbackArtifactPreservationFailed(
            errno: 13,
            artifactMayRemainAt: "/tmp/config.json.tmp"
        )

        #expect(error.commitMayBeUncertain)
        #expect(error.isRevisionConflict)
        #expect(error.description.contains("commit state remains uncertain"))
    }

    @Test("revision preflight classifies raw config read failures")
    func unchangedRevisionWrapsConfigReadFailure() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: store.paths.configFile,
            withIntermediateDirectories: true
        )

        do {
            _ = try await store.withUnchangedRevision(from: "unreadable") { true }
            Issue.record("expected the unreadable config preflight to fail")
        } catch let error as ConfigStoreError {
            guard case .readFailed(let path, _) = error else {
                Issue.record("expected readFailed, got \(error)")
                return
            }
            #expect(path == store.paths.configFile.path)
        }
    }

    @Test("config readers wait for a writer and then read the installed revision")
    func configReadWaitsForTheWriterLock() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let installed = sampleConfig()
        try store.save(installed)
        let lock = FileLock(path: store.paths.configLockFile, trustedRoot: root)
        #expect(lock.acquire() == .acquired)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            lock.release()
        }

        #expect(try store.load() == installed)
        #expect(try store.snapshot().config == installed)
    }

    @Test("an unusable config lock permits no migration side effects")
    func brokenReadLockDisablesMigration() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.paths.ensureDirectories()

        let legacy = AppConfig(version: 1, resticPath: "/usr/local/bin/restic")
        let original = try ConfigStore.makeEncoder().encode(legacy)
        try original.write(to: store.paths.configFile)
        try FileManager.default.removeItem(at: store.paths.locksDir)
        try Data("not a directory".utf8).write(to: store.paths.locksDir)

        #expect(try store.load() == legacy)
        let snapshot = try store.snapshot()
        #expect(snapshot.config == legacy)
        #expect(snapshot.bytes == original)
        #expect(try Data(contentsOf: store.paths.configFile) == original)
        #expect(!FileManager.default.fileExists(atPath: store.paths.machineFile.path))
        #expect(!FileManager.default.fileExists(atPath: store.paths.configV1BackupFile.path))
    }

    @Test("a legacy config creates missing lock infrastructure before migrating")
    func legacyReadCreatesLockDirectoryBeforeMigration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-config-upgrade-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ConfigStore(paths: AppPaths(root: root))
        let legacy = AppConfig(version: 1, resticPath: "/usr/local/bin/restic")
        try ConfigStore.makeEncoder().encode(legacy).write(to: store.paths.configFile)

        let loaded = try store.load()

        #expect(loaded.version == AppConfig.currentVersion)
        #expect(FileManager.default.fileExists(atPath: store.paths.locksDir.path))
        #expect(FileManager.default.fileExists(atPath: store.paths.configV1BackupFile.path))
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
