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

/// Sets `variable` to `value` (or unsets it when `value` is nil) for the
/// duration of `body`, restoring the previous value afterwards — including on
/// throw — so environment mutations can never leak into other tests.
private func withEnvironment<T>(
    _ variable: String,
    _ value: String?,
    _ body: () throws -> T
) rethrows -> T {
    let original = ProcessInfo.processInfo.environment[variable]
    func apply(_ newValue: String?) {
        if let newValue {
            setenv(variable, newValue, 1)
        } else {
            unsetenv(variable)
        }
    }
    apply(value)
    defer { apply(original) }
    return try body()
}

/// The platform default `root`, expressed independently of `AppPaths` so the
/// tests assert against the specification rather than against the
/// implementation.
private var expectedDefaultRootSuffix: String {
    #if os(Linux)
    "/.local/state/restic-station"
    #else
    "/Library/Application Support/ResticStation"
    #endif
}

private var expectedResticCacheSuffix: String {
    #if os(Linux)
    "/.cache/restic-station/restic"
    #else
    "/Library/Caches/net.herila.ResticStation/restic"
    #endif
}

/// Tests that mutate the process environment (`RESTIC_STATION_DATA_DIR`,
/// `XDG_*`) must not run concurrently with each other (or with anything else
/// reading those variables), hence `.serialized`.
@Suite(.serialized)
struct AppPathsEnvTests {
    // MARK: - RESTIC_STATION_DATA_DIR (both platforms)

    @Test func envOverrideRespected() {
        let overrideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-test-\(UUID().uuidString)")
        withEnvironment("RESTIC_STATION_DATA_DIR", overrideDir.path) {
            #expect(AppPaths.default().root.path == overrideDir.path)
        }
    }

    @Test func emptyEnvOverrideFallsBackToDefault() {
        withEnvironment("RESTIC_STATION_DATA_DIR", "") {
            #expect(AppPaths.default().root.path.hasSuffix(expectedDefaultRootSuffix))
        }
    }

    @Test func noEnvOverrideFallsBackToPlatformDefault() {
        withEnvironment("RESTIC_STATION_DATA_DIR", nil) {
            #expect(AppPaths.default().root.path.hasSuffix(expectedDefaultRootSuffix))
        }
    }

    /// The data-dir override wins over the XDG variables on Linux too.
    @Test func envOverrideBeatsXDG() {
        let overrideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-test-\(UUID().uuidString)")
        withEnvironment("XDG_STATE_HOME", "/xdg-state-should-be-ignored") {
            withEnvironment("RESTIC_STATION_DATA_DIR", overrideDir.path) {
                #expect(AppPaths.default().root.path == overrideDir.path)
            }
        }
    }

    /// Lives in the serialized suite because on Linux `resticCacheDir` reads
    /// `XDG_CACHE_HOME`, which the tests below mutate.
    @Test func resticCacheDirIsIndependentOfRoot() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/rs-a", isDirectory: true))
        let other = AppPaths(root: URL(fileURLWithPath: "/var/lib/somewhere-else", isDirectory: true))
        withEnvironment("XDG_CACHE_HOME", nil) {
            #expect(paths.resticCacheDir == other.resticCacheDir)
            #expect(paths.resticCacheDir.path.hasSuffix(expectedResticCacheSuffix))
        }
    }

    // MARK: - macOS resolution (must be byte-identical to pre-T22 behaviour)

    #if os(macOS)
    /// Pins the exact macOS strings. `~/Library/Application Support/ResticStation`
    /// and `~/Library/Caches/net.herila.ResticStation/restic` are what shipped
    /// before portable paths landed; any drift breaks existing installs.
    @Test func macOSDefaultRootIsUnchanged() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        withEnvironment("RESTIC_STATION_DATA_DIR", nil) {
            #expect(AppPaths.default().root.path == "\(home)/Library/Application Support/ResticStation")
        }
    }

    @Test func macOSResticCacheDirIsUnchanged() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/anything", isDirectory: true))
        #expect(paths.resticCacheDir.path == "\(home)/Library/Caches/net.herila.ResticStation/restic")
    }

    /// XDG variables must have no effect whatsoever on macOS.
    @Test func macOSIgnoresXDGVariables() {
        withEnvironment("RESTIC_STATION_DATA_DIR", nil) {
            withEnvironment("XDG_STATE_HOME", "/xdg/state") {
                withEnvironment("XDG_CACHE_HOME", "/xdg/cache") {
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    let paths = AppPaths.default()
                    #expect(paths.root.path == "\(home)/Library/Application Support/ResticStation")
                    #expect(paths.resticCacheDir.path == "\(home)/Library/Caches/net.herila.ResticStation/restic")
                }
            }
        }
    }
    #endif

    // MARK: - Linux XDG resolution

    #if os(Linux)
    @Test func linuxUsesXDGStateHomeWhenAbsolute() {
        withEnvironment("RESTIC_STATION_DATA_DIR", nil) {
            withEnvironment("XDG_STATE_HOME", "/var/lib/xdg-state") {
                #expect(AppPaths.default().root.path == "/var/lib/xdg-state/restic-station")
            }
        }
    }

    @Test func linuxFallsBackToLocalStateWhenXDGStateHomeUnset() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        withEnvironment("RESTIC_STATION_DATA_DIR", nil) {
            withEnvironment("XDG_STATE_HOME", nil) {
                #expect(AppPaths.default().root.path == "\(home)/.local/state/restic-station")
            }
        }
    }

    @Test func linuxFallsBackWhenXDGStateHomeIsEmpty() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        withEnvironment("RESTIC_STATION_DATA_DIR", nil) {
            withEnvironment("XDG_STATE_HOME", "") {
                #expect(AppPaths.default().root.path == "\(home)/.local/state/restic-station")
            }
        }
    }

    /// Per the XDG spec a relative value is invalid and must be treated as unset.
    @Test func linuxIgnoresRelativeXDGStateHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        withEnvironment("RESTIC_STATION_DATA_DIR", nil) {
            withEnvironment("XDG_STATE_HOME", "relative/state") {
                #expect(AppPaths.default().root.path == "\(home)/.local/state/restic-station")
            }
        }
    }

    @Test func linuxUsesXDGCacheHomeWhenAbsolute() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/anything", isDirectory: true))
        withEnvironment("XDG_CACHE_HOME", "/var/cache/xdg") {
            #expect(paths.resticCacheDir.path == "/var/cache/xdg/restic-station/restic")
        }
    }

    @Test func linuxFallsBackToDotCacheWhenXDGCacheHomeUnset() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/anything", isDirectory: true))
        withEnvironment("XDG_CACHE_HOME", nil) {
            #expect(paths.resticCacheDir.path == "\(home)/.cache/restic-station/restic")
        }
    }

    @Test func linuxIgnoresRelativeXDGCacheHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/anything", isDirectory: true))
        withEnvironment("XDG_CACHE_HOME", "relative/cache") {
            #expect(paths.resticCacheDir.path == "\(home)/.cache/restic-station/restic")
        }
    }
    #endif
}

@Suite struct AppPathsLayoutTests {
    private func makeTempPaths() -> (paths: AppPaths, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-test-\(UUID().uuidString)")
        return (AppPaths(root: root), root)
    }

    /// Runs on every platform: the layout below `root` is the cross-platform
    /// contract (`config export`/`import`, rsync between hosts).
    @Test func computedPathsMatchArchitectureTable() {
        let (paths, root) = makeTempPaths()
        let setId = UUID()
        let destId = UUID()

        let rootPath = root.path
        #expect(paths.configFile.path == "\(rootPath)/config.json")
        #expect(paths.configLockFile.path == "\(rootPath)/locks/config.lock")
        #expect(paths.configV1BackupFile.path == "\(rootPath)/config.v1.backup.json")
        #expect(paths.configBackupFile(fromVersion: 2).path == "\(rootPath)/config.v2.backup.json")
        #expect(paths.machineFile.path == "\(rootPath)/machine.json")
        #expect(paths.runsDir.path == "\(rootPath)/runs")
        #expect(paths.runsIndexFile.path == "\(rootPath)/runs/index.jsonl")
        #expect(paths.runsHealthLockFile.path == "\(rootPath)/runs/health.lock")
        #expect(paths.runsHealthProbeDir.path == "\(rootPath)/runs/.health")
        #expect(paths.runDir(runId: "r1").path == "\(rootPath)/runs/r1")
        #expect(paths.runMetadataFile(runId: "r1").path == "\(rootPath)/runs/r1/metadata.json")
        #expect(paths.runLogFile(runId: "r1").path == "\(rootPath)/runs/r1/log.txt")
        #expect(paths.stateDir.path == "\(rootPath)/state")
        #expect(paths.scheduleStateFile.path == "\(rootPath)/state/schedule-state.json")
        #expect(paths.scheduleStateVersionMarkerFile.path == "\(rootPath)/state/schedule-state.version-1")
        #expect(paths.currentRunFile(setId: setId).path == "\(rootPath)/state/current-run-\(setId.uuidString).json")
        #expect(paths.repoStatusFile(destId: destId).path == "\(rootPath)/state/repo-status-\(destId.uuidString).json")
        #expect(paths.fdaCheckFile.path == "\(rootPath)/state/fda-check.json")
        #expect(paths.stateHealthLockFile.path == "\(rootPath)/state/health.lock")
        #expect(paths.stateHealthProbeDir.path == "\(rootPath)/state/.health")
        #expect(paths.locksDir.path == "\(rootPath)/locks")
        #expect(paths.lockHealthProbeDir.path == "\(rootPath)/locks/.health")
        #expect(paths.tickLockFile.path == "\(rootPath)/locks/tick.lock")
        #expect(paths.destructiveAuditLockFile.path == "\(rootPath)/locks/destructive-audit.lock")
        #expect(paths.runPublicationLockFile.path == "\(rootPath)/locks/run-publication.lock")
        #expect(paths.setLockFile(setId: setId).path == "\(rootPath)/locks/set-\(setId.uuidString).lock")
        #expect(paths.mountsDir(destId: destId).path == "\(rootPath)/mounts/\(destId.uuidString)")
    }

    @Test func configurationVisibleSinceUsesTheNewestReadableMtimeAndFailsOpen() throws {
        let (paths, root) = makeTempPaths()
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: root) }

        #expect(paths.configurationVisibleSince(fileManager: fileManager) == nil)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: paths.configFile)
        let configDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fileManager.setAttributes([.modificationDate: configDate], ofItemAtPath: paths.configFile.path)
        #expect(paths.configurationVisibleSince(fileManager: fileManager) == configDate)

        try Data("{}".utf8).write(to: paths.machineFile)
        let machineDate = configDate.addingTimeInterval(3_600)
        try fileManager.setAttributes([.modificationDate: machineDate], ofItemAtPath: paths.machineFile.path)
        #expect(paths.configurationVisibleSince(fileManager: fileManager) == machineDate)
    }

    /// Guards requirement 3 against future drift: every member other than
    /// `root` itself must be a pure function of `root`, so two roots yield the
    /// same relative sub-paths. Written as literal relative strings so a
    /// platform branch sneaking into any member below `root` fails here.
    @Test func subPathsAreRelativeToRootAndPlatformIndependent() {
        let setId = UUID()
        let destId = UUID()
        let rootA = URL(fileURLWithPath: "/tmp/rs-a", isDirectory: true)
        let rootB = URL(fileURLWithPath: "/var/lib/rs-b", isDirectory: true)
        let a = AppPaths(root: rootA)
        let b = AppPaths(root: rootB)

        func relative(_ path: String, to root: URL) -> String {
            let prefix = root.path + "/"
            #expect(path.hasPrefix(prefix))
            return String(path.dropFirst(prefix.count))
        }

        func members(_ paths: AppPaths) -> [String] {
            [
                paths.configFile.path,
                paths.configLockFile.path,
                paths.configV1BackupFile.path,
                paths.configBackupFile(fromVersion: 2).path,
                paths.machineFile.path,
                paths.runsDir.path,
                paths.runsIndexFile.path,
                paths.runsHealthLockFile.path,
                paths.runsHealthProbeDir.path,
                paths.runDir(runId: "r1").path,
                paths.runMetadataFile(runId: "r1").path,
                paths.runLogFile(runId: "r1").path,
                paths.stateDir.path,
                paths.scheduleStateFile.path,
                paths.scheduleStateVersionMarkerFile.path,
                paths.currentRunFile(setId: setId).path,
                paths.repoStatusFile(destId: destId).path,
                paths.fdaCheckFile.path,
                paths.stateHealthLockFile.path,
                paths.stateHealthProbeDir.path,
                paths.locksDir.path,
                paths.lockHealthProbeDir.path,
                paths.tickLockFile.path,
                paths.destructiveAuditLockFile.path,
                paths.runPublicationLockFile.path,
                paths.setLockFile(setId: setId).path,
                paths.mountsDir(destId: destId).path,
            ]
        }

        let relativeA = members(a).map { relative($0, to: rootA) }
        let relativeB = members(b).map { relative($0, to: rootB) }
        #expect(relativeA == relativeB)
        #expect(relativeA == [
            "config.json",
            "locks/config.lock",
            "config.v1.backup.json",
            "config.v2.backup.json",
            "machine.json",
            "runs",
            "runs/index.jsonl",
            "runs/health.lock",
            "runs/.health",
            "runs/r1",
            "runs/r1/metadata.json",
            "runs/r1/log.txt",
            "state",
            "state/schedule-state.json",
            "state/schedule-state.version-1",
            "state/current-run-\(setId.uuidString).json",
            "state/repo-status-\(destId.uuidString).json",
            "state/fda-check.json",
            "state/health.lock",
            "state/.health",
            "locks",
            "locks/.health",
            "locks/tick.lock",
            "locks/destructive-audit.lock",
            "locks/run-publication.lock",
            "locks/set-\(setId.uuidString).lock",
            "mounts/\(destId.uuidString)",
        ])
    }

    @Test func ensureDirectoriesCreatesRootRunsStateLocks() throws {
        let (paths, root) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: root) }

        try paths.ensureDirectories()

        for directory in [
            paths.root, paths.runsDir, paths.stateDir, paths.locksDir,
        ] {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            #expect(values.isDirectory == true)
        }
        for scratchDirectory in [
            paths.lockHealthProbeDir,
            paths.stateHealthProbeDir,
            paths.runsHealthProbeDir,
        ] {
            #expect(!FileManager.default.fileExists(atPath: scratchDirectory.path))
        }
        for directory in [paths.root, paths.runsDir, paths.stateDir, paths.locksDir] {
            var info = stat()
            try #require(directory.path.withCString { stat($0, &info) } == 0)
            #expect(UInt32(info.st_mode) & 0o777 == 0o700)
        }
    }

    @Test func ensureDirectoriesIsIdempotent() throws {
        let (paths, root) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: root) }

        try paths.ensureDirectories()
        try paths.ensureDirectories() // must not throw the second time

        let values = try paths.stateDir.resourceValues(forKeys: [.isDirectoryKey])
        #expect(values.isDirectory == true)
    }

    /// Setup runs long before the safety-authoritative schedule-state read —
    /// `Tick` calls `ensureDirectories()` roughly fifty lines earlier — and
    /// `state/` is the one directory here that is re-tightened when it already
    /// exists. Silently repairing a group/world-writable `state/` would erase
    /// the evidence the read fails closed on, leaving a tree that looks
    /// healthy after an exposure another uid could have written through.
    @Test("a pre-existing group- or world-writable state/ refuses setup, evidence intact")
    func ensureDirectoriesRefusesAWritableStateDirectory() throws {
        for mode in [mode_t(0o722), mode_t(0o772), mode_t(0o777)] {
            let (paths, root) = makeTempPaths()
            defer { try? FileManager.default.removeItem(at: root) }
            try paths.ensureDirectories()

            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: paths.stateDir.path
            )

            #expect(throws: (any Error).self) {
                try paths.ensureDirectories()
            }

            // `Tick` exits at this call, so this refusal is the only guidance
            // the operator sees — it must carry what the schedule-state reader
            // would have said, not just the chmod.
            do {
                try paths.ensureDirectories()
                Issue.record("expected a refusal")
            } catch {
                let text = "\(error)"
                #expect(text.contains("chmod 700"))
                #expect(text.contains("against a trusted copy"))
                #expect(text.contains("does not make the contents trustworthy"))
            }

            // The point of refusing rather than repairing: the mode is still
            // there for the operator, and for the read that fails closed on it.
            let after = try FileManager.default.attributesOfItem(
                atPath: paths.stateDir.path
            )[.posixPermissions] as? NSNumber
            #expect(
                after?.uint16Value == UInt16(mode),
                "mode \(String(mode, radix: 8)) must survive the refusal, not be tightened away"
            )
        }
    }

    /// Benign widening is neither refused nor repaired. `0755` is listable but
    /// exposes nothing another uid can act on, so refusing it would strand
    /// installs over a privacy nit — and repairing it is what reintroduces the
    /// window this whole guard closes, since a refusal cannot be atomic with a
    /// later `fchmodat`. `state/` therefore behaves like `runs/` and `locks/`:
    /// left alone and reported by live health.
    @Test("a pre-existing 0755 state/ is left alone, neither refused nor tightened")
    func ensureDirectoriesLeavesABenignStateDirectoryAlone() throws {
        let (paths, root) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try paths.ensureDirectories()

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode_t(0o755))],
            ofItemAtPath: paths.stateDir.path
        )
        try paths.ensureDirectories() // must not throw

        let after = try FileManager.default.attributesOfItem(
            atPath: paths.stateDir.path
        )[.posixPermissions] as? NSNumber
        #expect(after?.uint16Value == 0o755, "no automatic repair means no erase window")
    }

    /// Not repairing an existing mode cuts both ways: a *restrictive* one is
    /// no longer normalised either, and `0500`/`0600` leave the directory
    /// unusable — locks and temp files cannot be created, and valid state
    /// reads as corrupt. Refuse rather than accept a broken tree.
    /// `0500` keeps owner search, so the directory opens on both platforms and
    /// the mode check is what refuses it — the case that pins the guidance.
    @Test("a pre-existing 0500 state/ refuses setup and names the chmod")
    func ensureDirectoriesRefusesASearchOnlyStateDirectory() throws {
        let (paths, root) = makeTempPaths()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode_t(0o700))],
                ofItemAtPath: paths.stateDir.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        try paths.ensureDirectories()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode_t(0o500))],
            ofItemAtPath: paths.stateDir.path
        )

        do {
            try paths.ensureDirectories()
            Issue.record("0500 must refuse, not be accepted")
        } catch {
            let text = "\(error)"
            #expect(text.contains("denies the owner access"))
            #expect(text.contains("chmod 700"))
        }
    }

    /// `0600` and `0400` drop owner search, and which layer refuses them is
    /// platform-dependent: Darwin's `O_SEARCH` needs execute so the open
    /// itself fails, while Linux's `O_PATH` opens regardless and the mode
    /// check refuses. Both are refusals; the test asserts only that, because
    /// asserting the message would encode one platform's syscall semantics.
    @Test("a pre-existing state/ without owner search refuses setup on either platform")
    func ensureDirectoriesRefusesAStateDirectoryWithoutOwnerSearch() throws {
        for mode in [mode_t(0o600), mode_t(0o400)] {
            let (paths, root) = makeTempPaths()
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode_t(0o700))],
                    ofItemAtPath: paths.stateDir.path
                )
                try? FileManager.default.removeItem(at: root)
            }
            try paths.ensureDirectories()
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: paths.stateDir.path
            )

            #expect(throws: (any Error).self, "mode \(String(mode, radix: 8)) must refuse") {
                try paths.ensureDirectories()
            }
        }
    }

    /// A newly created `state/` is still pinned to `0700`; only *existing*
    /// modes are left alone.
    @Test("a freshly created state/ is still pinned to 0700")
    func ensureDirectoriesPinsANewStateDirectory() throws {
        let (paths, root) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try paths.ensureDirectories()

        let mode = try FileManager.default.attributesOfItem(
            atPath: paths.stateDir.path
        )[.posixPermissions] as? NSNumber
        #expect(mode?.uint16Value == 0o700)
    }

    @Test("operation directory setup does not depend on the health scratch path")
    func ensureDirectoriesIgnoresBrokenHealthScratch() throws {
        for scratchPath in [
            { (paths: AppPaths) in paths.lockHealthProbeDir },
            { (paths: AppPaths) in paths.stateHealthProbeDir },
            { (paths: AppPaths) in paths.runsHealthProbeDir },
        ] {
            let (paths, root) = makeTempPaths()
            defer { try? FileManager.default.removeItem(at: root) }
            try paths.ensureDirectories()
            let scratchDirectory = scratchPath(paths)
            FileManager.default.createFile(atPath: scratchDirectory.path, contents: Data())

            try paths.ensureDirectories()
            let failure = try #require(LockingHealth.probe(paths: paths, configuredSetIds: []))
            #expect(failure.path == scratchDirectory.path)
            #expect(failure.scope == .diagnostic)
        }
    }

    @Test("live health never tightens its scratch directory through an unsafe parent")
    func lockingHealthRefusesUnsafeHealthParentBeforeTightening() throws {
        let (paths, root) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: paths.lockHealthProbeDir, withIntermediateDirectories: false)
        try #require(paths.lockHealthProbeDir.path.withCString { chmod($0, 0o755) } == 0)
        try #require(paths.locksDir.path.withCString { chmod($0, 0o777) } == 0)

        let failure = try #require(LockingHealth.probe(paths: paths, configuredSetIds: []))
        #expect(failure.path == paths.locksDir.path)
        #expect(failure.operation == "lock directory permissions")

        var info = stat()
        try #require(paths.lockHealthProbeDir.path.withCString { lstat($0, &info) } == 0)
        #expect(info.st_mode & 0o777 == 0o755)
    }

    @Test func ensureDirectoriesDoesNotTouchMetadataWhenModesAreAlreadyCorrect() throws {
        let (paths, root) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: root) }

        try paths.ensureDirectories()
        var before = stat()
        try #require(paths.stateDir.path.withCString { lstat($0, &before) } == 0)
        usleep(10_000)

        try paths.ensureDirectories()
        var after = stat()
        try #require(paths.stateDir.path.withCString { lstat($0, &after) } == 0)

        #if canImport(Darwin)
        #expect(before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec)
        #expect(before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec)
        #else
        #expect(before.st_ctim.tv_sec == after.st_ctim.tv_sec)
        #expect(before.st_ctim.tv_nsec == after.st_ctim.tv_nsec)
        #endif
    }

    @Test func ensureDirectoriesDoesNotApplyRootModeToMissingAncestors() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("restic-station-ancestor-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        // Record this process's ordinary directory-creation mode so the test
        // remains correct under both permissive and owner-only umasks.
        let probe = base.appendingPathComponent("default-mode-probe", isDirectory: true)
        try fileManager.createDirectory(at: probe, withIntermediateDirectories: true)
        var probeInfo = stat()
        try #require(probe.path.withCString { stat($0, &probeInfo) } == 0)
        let defaultMode = UInt32(probeInfo.st_mode) & 0o777
        try fileManager.removeItem(at: probe)

        let firstAncestor = base.appendingPathComponent("shared", isDirectory: true)
        let secondAncestor = firstAncestor.appendingPathComponent("state", isDirectory: true)
        let root = secondAncestor.appendingPathComponent("restic-station", isDirectory: true)
        try AppPaths(root: root).ensureDirectories()

        for ancestor in [firstAncestor, secondAncestor] {
            var info = stat()
            try #require(ancestor.path.withCString { stat($0, &info) } == 0)
            #expect(UInt32(info.st_mode) & 0o777 == defaultMode)
        }
        var rootInfo = stat()
        try #require(root.path.withCString { stat($0, &rootInfo) } == 0)
        #expect(UInt32(rootInfo.st_mode) & 0o777 == 0o700)
    }

    @Test("directory setup durably publishes every newly created ancestor")
    func ensureDirectoriesSyncsEveryCreatedAncestorAndParent() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("restic-station-durability-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        let firstAncestor = base.appendingPathComponent("shared", isDirectory: true)
        let secondAncestor = firstAncestor.appendingPathComponent("state", isDirectory: true)
        let root = secondAncestor.appendingPathComponent("restic-station", isDirectory: true)
        let paths = AppPaths(root: root)
        var syncedPaths: [String] = []

        try paths.ensureDirectories { syncedPaths.append($0.standardizedFileURL.path) }

        #expect(syncedPaths == [
            base.path,
            base.deletingLastPathComponent().path,
            firstAncestor.path,
            base.path,
            secondAncestor.path,
            firstAncestor.path,
            root.path,
            secondAncestor.path,
            paths.runsDir.path,
            paths.stateDir.path,
            paths.locksDir.path,
            root.path,
        ])
    }

    @Test("directory setup retries durability after mkdir became visible")
    func ensureDirectoriesResyncsVisibleBoundaryAfterFailedParentSync() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("restic-station-durability-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        let firstAncestor = base.appendingPathComponent("shared", isDirectory: true)
        let secondAncestor = firstAncestor.appendingPathComponent("state", isDirectory: true)
        let root = secondAncestor.appendingPathComponent("restic-station", isDirectory: true)
        let paths = AppPaths(root: root)
        var baseSyncCount = 0
        var firstAttemptFailed = false

        do {
            try paths.ensureDirectories { directory in
                if directory.standardizedFileURL.path == base.path {
                    baseSyncCount += 1
                    if baseSyncCount == 2 {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            }
        } catch {
            firstAttemptFailed = true
        }
        #expect(firstAttemptFailed)
        #expect(baseSyncCount == 2)
        #expect(fileManager.fileExists(atPath: firstAncestor.path))
        #expect(!fileManager.fileExists(atPath: secondAncestor.path))

        var retrySyncs: [String] = []
        try paths.ensureDirectories { retrySyncs.append($0.standardizedFileURL.path) }

        #expect(retrySyncs == [
            firstAncestor.path,
            base.path,
            secondAncestor.path,
            firstAncestor.path,
            root.path,
            secondAncestor.path,
            paths.runsDir.path,
            paths.stateDir.path,
            paths.locksDir.path,
            root.path,
        ])
    }
}
