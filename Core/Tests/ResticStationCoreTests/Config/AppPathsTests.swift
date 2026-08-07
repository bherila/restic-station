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
        #expect(paths.configV1BackupFile.path == "\(rootPath)/config.v1.backup.json")
        #expect(paths.machineFile.path == "\(rootPath)/machine.json")
        #expect(paths.runsDir.path == "\(rootPath)/runs")
        #expect(paths.runsIndexFile.path == "\(rootPath)/runs/index.jsonl")
        #expect(paths.runDir(runId: "r1").path == "\(rootPath)/runs/r1")
        #expect(paths.runMetadataFile(runId: "r1").path == "\(rootPath)/runs/r1/metadata.json")
        #expect(paths.runLogFile(runId: "r1").path == "\(rootPath)/runs/r1/log.txt")
        #expect(paths.stateDir.path == "\(rootPath)/state")
        #expect(paths.scheduleStateFile.path == "\(rootPath)/state/schedule-state.json")
        #expect(paths.currentRunFile(setId: setId).path == "\(rootPath)/state/current-run-\(setId.uuidString).json")
        #expect(paths.repoStatusFile(destId: destId).path == "\(rootPath)/state/repo-status-\(destId.uuidString).json")
        #expect(paths.fdaCheckFile.path == "\(rootPath)/state/fda-check.json")
        #expect(paths.locksDir.path == "\(rootPath)/locks")
        #expect(paths.tickLockFile.path == "\(rootPath)/locks/tick.lock")
        #expect(paths.setLockFile(setId: setId).path == "\(rootPath)/locks/set-\(setId.uuidString).lock")
        #expect(paths.mountsDir(destId: destId).path == "\(rootPath)/mounts/\(destId.uuidString)")
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
                paths.configV1BackupFile.path,
                paths.machineFile.path,
                paths.runsDir.path,
                paths.runsIndexFile.path,
                paths.runDir(runId: "r1").path,
                paths.runMetadataFile(runId: "r1").path,
                paths.runLogFile(runId: "r1").path,
                paths.stateDir.path,
                paths.scheduleStateFile.path,
                paths.currentRunFile(setId: setId).path,
                paths.repoStatusFile(destId: destId).path,
                paths.fdaCheckFile.path,
                paths.locksDir.path,
                paths.tickLockFile.path,
                paths.setLockFile(setId: setId).path,
                paths.mountsDir(destId: destId).path,
            ]
        }

        let relativeA = members(a).map { relative($0, to: rootA) }
        let relativeB = members(b).map { relative($0, to: rootB) }
        #expect(relativeA == relativeB)
        #expect(relativeA == [
            "config.json",
            "config.v1.backup.json",
            "machine.json",
            "runs",
            "runs/index.jsonl",
            "runs/r1",
            "runs/r1/metadata.json",
            "runs/r1/log.txt",
            "state",
            "state/schedule-state.json",
            "state/current-run-\(setId.uuidString).json",
            "state/repo-status-\(destId.uuidString).json",
            "state/fda-check.json",
            "locks",
            "locks/tick.lock",
            "locks/set-\(setId.uuidString).lock",
            "mounts/\(destId.uuidString)",
        ])
    }

    @Test func ensureDirectoriesCreatesRootRunsStateLocks() throws {
        let (paths, root) = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: root) }

        try paths.ensureDirectories()

        for directory in [paths.root, paths.runsDir, paths.stateDir, paths.locksDir] {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            #expect(values.isDirectory == true)
        }
        var info = stat()
        try #require(root.path.withCString { stat($0, &info) } == 0)
        #expect(UInt32(info.st_mode) & 0o777 == 0o700)
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
