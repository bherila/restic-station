import Foundation
import Testing
@testable import ResticStationCore

@Suite("CloudStorageSafety")
struct CloudStorageSafetyTests {
    private let home = "/Users/test"

    @Test("recognizes iCloud Drive and File Provider roots without prefix false positives")
    func cloudRoots() {
        #expect(CloudStorageSafety.isCloudSyncedPath(
            "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Documents",
            homeDirectory: home
        ))
        #expect(CloudStorageSafety.isCloudSyncedPath(
            "/Users/test/Library/CloudStorage/OneDrive-Example/SharePoint",
            homeDirectory: home
        ))
        #expect(CloudStorageSafety.isCloudSyncedPath(
            "/Users/test/Library/CloudStorage",
            homeDirectory: home
        ))
        #expect(!CloudStorageSafety.isCloudSyncedPath(
            "/Users/test/Library/CloudStorage-old/archive",
            homeDirectory: home
        ))
        #expect(!CloudStorageSafety.isCloudSyncedPath(
            "/Users/test/Documents",
            homeDirectory: home
        ))
        #expect(!CloudStorageSafety.isCloudSyncedPath("", homeDirectory: home))
    }

    @Test("a mixed source list enables cloud placeholder exclusion")
    func mixedSources() {
        #expect(CloudStorageSafety.containsCloudBackedSource([
            "/Users/test/proj",
            "/Users/test/Library/CloudStorage/OneDrive/Documents",
        ], homeDirectory: home))
        #expect(!CloudStorageSafety.containsCloudBackedSource([
            "/Users/test/proj",
            "/Users/test/Documents",
        ], homeDirectory: home))
    }

    #if canImport(Darwin)
    @Test("on macOS a differently-cased path to a cloud root still counts")
    func caseInsensitiveOnMac() {
        #expect(CloudStorageSafety.isCloudSyncedPath(
            "/Users/test/library/cloudstorage/Provider/Documents",
            homeDirectory: home
        ))
    }
    #endif

    @Test("a path reaching a cloud root through a symlink counts; one leaving it does not")
    func symlinks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let provider = try fixture.directory("Library/CloudStorage/Provider-Example/Documents")
        let plain = try fixture.directory("plain")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.path("CloudLink"),
            withDestinationPath: (provider as NSString).deletingLastPathComponent
        )
        try FileManager.default.createSymbolicLink(atPath: fixture.path("PlainLink"), withDestinationPath: plain)

        #expect(CloudStorageSafety.isCloudSyncedPath(fixture.path("CloudLink/Documents"), homeDirectory: fixture.root))
        #expect(!CloudStorageSafety.isCloudSyncedPath(fixture.path("PlainLink"), homeDirectory: fixture.root))
    }

    // MARK: - firstDatalessEntry

    @Test("a fully resident cloud repository has no dataless entry")
    func residentRepository() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repo = try fixture.repository()

        var checked: [String] = []
        let found = CloudStorageSafety.firstDatalessEntry(
            inRepository: repo, homeDirectory: fixture.root, isDataless: { checked.append($0); return false }
        )

        #expect(found == nil)
        // The walk really visited the tree — a nil from an empty walk would
        // pass the assertion above for the wrong reason.
        #expect(checked.contains((repo as NSString).appendingPathComponent("data/ab/abcdef")))
    }

    @Test("a dataless repository root is reported as '.' before anything is listed")
    func datalessRoot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repo = try fixture.repository()

        var checked: [String] = []
        let found = CloudStorageSafety.firstDatalessEntry(
            inRepository: repo, homeDirectory: fixture.root,
            isDataless: { checked.append($0); return $0 == repo }
        )

        #expect(found == ".")
        #expect(checked == [repo])
    }

    @Test("a dataless pack is reported by its repository-relative path")
    func datalessPack() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repo = try fixture.repository()
        let pack = (repo as NSString).appendingPathComponent("data/ab/abcdef")

        let found = CloudStorageSafety.firstDatalessEntry(
            inRepository: repo, homeDirectory: fixture.root, isDataless: { $0 == pack }
        )

        #expect(found == "data/ab/abcdef")
    }

    @Test("a dataless subdirectory is reported itself, and nothing inside it is examined")
    func datalessSubdirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repo = try fixture.repository()
        let dataDir = (repo as NSString).appendingPathComponent("data")

        var checked: [String] = []
        let found = CloudStorageSafety.firstDatalessEntry(
            inRepository: repo, homeDirectory: fixture.root,
            isDataless: { checked.append($0); return $0 == dataDir }
        )

        #expect(found == "data")
        #expect(!checked.contains { $0.hasPrefix(dataDir + "/") })
    }

    @Test("a repository outside cloud storage is never walked")
    func nonCloudRepositoryIsNotWalked() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repo = try fixture.directory("backups/repo")

        var checked: [String] = []
        let found = CloudStorageSafety.firstDatalessEntry(
            inRepository: repo, homeDirectory: fixture.root, isDataless: { checked.append($0); return true }
        )

        #expect(found == nil)
        #expect(checked.isEmpty)
    }

    /// A throwaway home directory on the real filesystem.
    private struct Fixture {
        let root: String

        init() throws {
            root = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("cloud-safety-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }

        func path(_ relative: String) -> String {
            (root as NSString).appendingPathComponent(relative)
        }

        func directory(_ relative: String) throws -> String {
            let full = path(relative)
            try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
            return full
        }

        /// A minimal repository layout under the File Provider root.
        func repository() throws -> String {
            let repo = try directory("Library/CloudStorage/Provider-Example/restic-repo")
            for dir in ["data/ab", "index", "snapshots"] {
                _ = try directory("Library/CloudStorage/Provider-Example/restic-repo/\(dir)")
            }
            for file in ["config", "data/ab/abcdef", "index/1234"] {
                FileManager.default.createFile(atPath: (repo as NSString).appendingPathComponent(file), contents: Data())
            }
            return repo
        }

        func cleanUp() {
            try? FileManager.default.removeItem(atPath: root)
        }
    }
}
