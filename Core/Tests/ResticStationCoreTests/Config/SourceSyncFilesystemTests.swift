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

func syncTemporaryRoot() throws -> URL {
    // Foundation deliberately shortens /private/var back to /var on
    // Darwin, even after resolvingSymlinksInPath(). Use the physical path
    // required by the no-follow source-root contract.
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        throw SourceSyncError.unsafeRoot("Cannot resolve the test's temporary directory.")
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(UUID().uuidString)
}

@Suite("Selected-folder inventory")
struct SourceSyncFilesystemTests {
    @Test("symlink reads preserve exact short, Unicode and long target bytes")
    func linkTargetBytes() throws {
        let root = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try SourceSyncFilesystem.openRoot(root.path)
        for (index, target) in ["note", "資料/記録", String(repeating: "segment/", count: 100) + "資料"].enumerated() {
            let name = "link-\(index)"
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: target)
            #expect(try SourceSyncFilesystem.linkTarget(named: name, in: directory) == target)
        }
    }

    @Test("ordinary child changes preserve the root's creation identity")
    func rootGenerationSurvivesChildEdits() throws {
        let root = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try SourceSyncFilesystem.inventory(at: root.path).rootIdentity
        try Data("new child".utf8).write(to: root.appendingPathComponent("note"))
        #expect(try SourceSyncFilesystem.inventory(at: root.path).rootIdentity == initial)
        try FileManager.default.removeItem(at: root.appendingPathComponent("note"))
        #expect(try SourceSyncFilesystem.inventory(at: root.path).rootIdentity == initial)
    }
    @Test("repositories, their children and parents are never live replicas")
    func repositoryBoundary() throws {
        let root = try syncTemporaryRoot()
        let repo = root.appendingPathComponent("archive")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["data", "index", "keys", "locks", "snapshots"] {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("synthetic repository config".utf8).write(to: repo.appendingPathComponent("config"))
        for folder in [root, repo, repo.appendingPathComponent("data")] {
            #expect(throws: SourceSyncError.self) { try SourceSyncFilesystem.inventory(at: folder.path) }
        }
    }
    @Test("only the selected child is inventoried, not the broader backup root")
    func narrowRoot() throws {
        let root = try syncTemporaryRoot()
        let folder = root.appendingPathComponent("shared-notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("outside".utf8).write(to: root.appendingPathComponent("other-project.txt"))
        try Data("inside".utf8).write(to: folder.appendingPathComponent("note.txt"))
        let inventory = try SourceSyncFilesystem.inventory(at: folder.path)
        #expect(Set(inventory.items.keys) == ["note.txt"])
        #expect(inventory.items["note.txt"]?.digest == SHA256Digest.hex(Data("inside".utf8)))
    }

    @Test("a link to a sibling outside the selected folder is refused")
    func escapedLink() throws {
        let root = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: "../other")
        #expect(throws: SourceSyncError.self) { try SourceSyncFilesystem.inventory(at: root.path) }
    }

    @Test("an internal relative link stays a link in the inventory")
    func internalLink() throws {
        let root = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("data".utf8).write(to: root.appendingPathComponent("target"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "target")
        let inventory = try SourceSyncFilesystem.inventory(at: root.path)
        #expect(inventory.items["link"]?.kind == .symbolicLink)
        #expect(inventory.items["link"]?.digest == SHA256Digest.hex(Data("target".utf8)))
    }

    @Test("an absent root is an error, not a deletion inventory")
    func missingRoot() {
        #expect(throws: SourceSyncError.self) {
            try SourceSyncFilesystem.inventory(at: "/missing-\(UUID().uuidString)")
        }
    }
}
