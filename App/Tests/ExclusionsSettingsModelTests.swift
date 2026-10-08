import Foundation
import ResticStationCore
import Testing
@testable import Restic_Station

#if canImport(Darwin)
import Darwin
#endif

/// Settings → Exclusions' Restore Built-in Defaults. Codex on #158: after a
/// load that failed, the compare-and-swap had no snapshot to compare against,
/// so the one visible way out of an unusable `global-excludes.json` could not
/// remove it.
@Suite("Exclusions pane: restore built-in defaults", .serialized)
@MainActor
struct ExclusionsSettingsModelTests {
    private func makePaths() throws -> (AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-exclusions-pane-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        return (paths, root)
    }

    private func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    @Test("a malformed file the pane could not load is removed")
    func malformedFileIsRemoved() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{ not json".utf8).write(to: paths.globalExcludesFile)

        let pane = ExclusionsSettingsModel()
        pane.load(paths: paths)
        #expect(pane.loadFailure != nil)

        pane.restoreDefaults()
        #expect(!entryExists(paths.globalExcludesFile))
        #expect(pane.loadFailure == nil)
        #expect(pane.saveFailure == nil)
        #expect(pane.settings == .default)
    }

    @Test("a settings path that is not a regular file is removed")
    func nonRegularFileIsRemoved() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(mkfifo(paths.globalExcludesFile.path, 0o600) == 0)

        let pane = ExclusionsSettingsModel()
        pane.load(paths: paths)
        #expect(pane.loadFailure != nil)

        pane.restoreDefaults()
        #expect(!entryExists(paths.globalExcludesFile))
        #expect(pane.loadFailure == nil)
    }

    /// The unconditional removal is only for a pane that never loaded the
    /// file. One that did keeps its compare-and-swap, so an edit made
    /// elsewhere after it loaded is not deleted.
    @Test("a pane that loaded the file still refuses to delete a newer edit")
    func loadedPaneKeepsItsCompareAndSwap() throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlobalExcludeStore(paths: paths)
        var settings = GlobalExcludeSettings()
        settings.extraPatterns = ["/first"]
        try store.save(settings)

        let pane = ExclusionsSettingsModel()
        pane.load(paths: paths)
        #expect(pane.loadFailure == nil)

        settings.extraPatterns = ["/edited-elsewhere"]
        try store.save(settings)

        pane.restoreDefaults()
        #expect(entryExists(paths.globalExcludesFile))
        #expect(try store.load().extraPatterns == ["/edited-elsewhere"])
        #expect(pane.saveFailure == ExclusionsCopy.staleWrite)
    }
}
