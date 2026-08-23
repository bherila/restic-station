import Foundation
import Combine
import ResticStationCore
import Testing
@testable import Restic_Station

@Suite("StateWatcher lock health", .serialized)
@MainActor
struct StateWatcherTests {
    @Test("lock permission changes and directory renames refresh lock health")
    func lockMetadataAndRenameRefreshHealth() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-lock-watcher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        let tickLock = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(tickLock.acquire() == .acquired)
        tickLock.release()
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.lockingFailure == nil)

        // Child metadata does not mutate the parent directory vnode. The
        // direct lock-file source must still refresh live health.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: paths.tickLockFile.path
        )
        for _ in 0..<40 {
            if watcher.lockingFailure?.path == paths.tickLockFile.path { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.path == paths.tickLockFile.path)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: paths.tickLockFile.path
        )
        for _ in 0..<40 {
            if watcher.lockingFailure == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure == nil)

        // A metadata-only permission change must make the app unhealthy even
        // though no file in state/ or runs/ changed.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770], ofItemAtPath: paths.locksDir.path
        )
        for _ in 0..<40 {
            if watcher.lockingFailure?.scope == .machine { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.scope == .machine)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: paths.locksDir.path
        )
        for _ in 0..<40 {
            if watcher.lockingFailure == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure == nil)

        // Exercise the rename/reopen path, not just a write delivered by the
        // source installed during start().
        let movedLocks = root.appendingPathComponent("locks-old", isDirectory: true)
        try FileManager.default.moveItem(at: paths.locksDir, to: movedLocks)
        try FileManager.default.createDirectory(
            at: paths.locksDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        let setId = UUID()
        watcher.updateConfiguredSetIds([setId])
        try FileManager.default.createDirectory(
            at: paths.setLockFile(setId: setId),
            withIntermediateDirectories: true
        )

        for _ in 0..<40 {
            if watcher.lockingFailure?.scope == .set(setId) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.scope == .set(setId))
        #expect(watcher.lockingFailure?.path.contains(setId.uuidString) == true)
    }

    @Test("a settled lock-health reload does not trigger another reload")
    func lockHealthDoesNotTriggerItself() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-lock-watcher-idle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        var changes = 0
        let subscription = watcher.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 750_000_000)
        changes = 0
        try await Task.sleep(nanoseconds: 750_000_000)

        #expect(changes == 0)
    }
}
