import Foundation
import ResticStationCore
import Testing
@testable import Restic_Station

@Suite("StateWatcher lock health", .serialized)
@MainActor
struct StateWatcherTests {
    @Test("a replaced locks directory is reopened and refreshes lock health")
    func replacedLocksDirectoryRefreshesHealth() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-lock-watcher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.lockingFailure == nil)

        // Exercise the delete/reopen path, not just a write delivered by the
        // source installed during start().
        try FileManager.default.removeItem(at: paths.locksDir)
        try FileManager.default.createDirectory(
            at: paths.locksDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        let setId = UUID()
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
}
