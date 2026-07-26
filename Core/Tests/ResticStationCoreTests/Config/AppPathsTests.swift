import Foundation
import Testing
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Tests that mutate the `RESTIC_STATION_DATA_DIR` process environment
/// variable must not run concurrently with each other (or with anything
/// else reading it), hence `.serialized`.
@Suite(.serialized)
struct AppPathsEnvTests {
    @Test func envOverrideRespected() throws {
        let originalValue = ProcessInfo.processInfo.environment["RESTIC_STATION_DATA_DIR"]
        defer { Self.restore(originalValue) }

        let overrideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-test-\(UUID().uuidString)")
        setenv("RESTIC_STATION_DATA_DIR", overrideDir.path, 1)

        let paths = AppPaths.default()
        #expect(paths.root.path == overrideDir.path)
    }

    @Test func emptyEnvOverrideFallsBackToDefault() throws {
        let originalValue = ProcessInfo.processInfo.environment["RESTIC_STATION_DATA_DIR"]
        defer { Self.restore(originalValue) }

        setenv("RESTIC_STATION_DATA_DIR", "", 1)

        let paths = AppPaths.default()
        #expect(paths.root.path.hasSuffix("Library/Application Support/ResticStation"))
    }

    @Test func noEnvOverrideFallsBackToApplicationSupport() throws {
        let originalValue = ProcessInfo.processInfo.environment["RESTIC_STATION_DATA_DIR"]
        defer { Self.restore(originalValue) }

        unsetenv("RESTIC_STATION_DATA_DIR")

        let paths = AppPaths.default()
        #expect(paths.root.path.hasSuffix("Library/Application Support/ResticStation"))
    }

    private static func restore(_ originalValue: String?) {
        if let originalValue {
            setenv("RESTIC_STATION_DATA_DIR", originalValue, 1)
        } else {
            unsetenv("RESTIC_STATION_DATA_DIR")
        }
    }
}

@Suite struct AppPathsLayoutTests {
    private func makeTempPaths() -> (paths: AppPaths, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-test-\(UUID().uuidString)")
        return (AppPaths(root: root), root)
    }

    @Test func computedPathsMatchArchitectureTable() {
        let (paths, root) = makeTempPaths()
        let setId = UUID()
        let destId = UUID()

        let rootPath = root.path
        #expect(paths.configFile.path == "\(rootPath)/config.json")
        #expect(paths.runsIndexFile.path == "\(rootPath)/runs/index.jsonl")
        #expect(paths.runMetadataFile(runId: "r1").path == "\(rootPath)/runs/r1/metadata.json")
        #expect(paths.runLogFile(runId: "r1").path == "\(rootPath)/runs/r1/log.txt")
        #expect(paths.scheduleStateFile.path == "\(rootPath)/state/schedule-state.json")
        #expect(paths.currentRunFile(setId: setId).path == "\(rootPath)/state/current-run-\(setId.uuidString).json")
        #expect(paths.repoStatusFile(destId: destId).path == "\(rootPath)/state/repo-status-\(destId.uuidString).json")
        #expect(paths.fdaCheckFile.path == "\(rootPath)/state/fda-check.json")
        #expect(paths.tickLockFile.path == "\(rootPath)/locks/tick.lock")
        #expect(paths.setLockFile(setId: setId).path == "\(rootPath)/locks/set-\(setId.uuidString).lock")
        #expect(paths.mountsDir(destId: destId).path == "\(rootPath)/mounts/\(destId.uuidString)")
    }

    @Test func resticCacheDirIsFixedRegardlessOfRoot() {
        let (paths, _) = makeTempPaths()
        #expect(paths.resticCacheDir.path.hasSuffix("Library/Caches/net.herila.ResticStation/restic"))
    }

    @Test func ensureDirectoriesCreatesRootRunsStateLocks() throws {
        let (paths, root) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: root) }

        try paths.ensureDirectories()

        for directory in [paths.root, paths.runsDir, paths.stateDir, paths.locksDir] {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            #expect(values.isDirectory == true)
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
}
