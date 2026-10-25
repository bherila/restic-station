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

@Suite("Reserved source-sync endpoint")
struct SourceSyncEndpointTests {
    struct Fixture {
        let base: URL
        let root: URL
        let group: SourceSyncGroup
        let inventory: SyncInventory
        let before: SyncItem
        var after: SyncItem { SyncItem(digest: SHA256Digest.hex(Data("new".utf8)), bytes: 3, mode: before.mode) }
        let operation = UUID()

        init() throws {
            base = try syncTemporaryRoot()
            root = base.appendingPathComponent("notes")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: root.appendingPathComponent("note"))
            group = SourceSyncGroup(name: "Notes", localPath: root.path, peer: .init(path: base.appendingPathComponent("other").path), coordinatorMachineId: "laptop")
            inventory = try SyncEndpointService.handle(.init(action: .inventory, group: group, root: root.path)).inventory
            before = try #require(inventory.items["note"])
        }

        func request(_ action: SyncEndpointRequest.Action) -> SyncEndpointRequest {
            var r = SyncEndpointRequest(action: action, group: group, root: root.path, operationId: operation, expected: inventory)
            r.operations = [.init(path: "note", before: before, after: after)]
            r.exportPaths = ["note"]
            return r
        }

        func prepare() throws -> SyncEndpointReply {
            let reply = try SyncEndpointService.handle(request(.prepare))
            let incoming = try #require(reply.stagingPath)
            try Data("new".utf8).write(to: URL(fileURLWithPath: incoming).appendingPathComponent("note"))
            return reply
        }

        func protectedRequest() -> SyncEndpointRequest {
            var r = request(.commit)
            // Endpoint tests simulate the trusted coordinator's validated
            // protection receipt. The coordinator integration must prove
            // this with a real disposable repository/restore separately.
            r.protectedItems = ["note": before]
            r.protectedSnapshotId = String(repeating: "a", count: 64)
            r.protectedRepositoryId = String(repeating: "b", count: 64)
            return r
        }
    }

    @Test("the actual displaced version survives successful installation")
    func protectedInstall() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let prepared = try f.prepare()
        let result = try SyncEndpointService.handle(f.protectedRequest())
        #expect(result.inventory.items["note"] == f.after)
        #expect(try String(contentsOf: URL(fileURLWithPath: try #require(prepared.recoveryPath)).appendingPathComponent(SyncEndpointService.recoveryName(for: "note")), encoding: .utf8) == "old")
        let completed = try SyncEndpointService.handle(f.request(.finish))
        #expect(completed.inventory.endpointGeneration != f.inventory.endpointGeneration)
        let repeated = try SyncEndpointService.handle(f.request(.finish))
        #expect(repeated.inventory.endpointGeneration == completed.inventory.endpointGeneration)
    }

    @Test("missing protection refuses before any displacement")
    func noProtection() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try f.prepare()
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.handle(f.request(.commit)) }
        #expect(try String(contentsOf: f.root.appendingPathComponent("note"), encoding: .utf8) == "old")
    }

    @Test("a snapshot-shaped attestation without its repository binding is refused")
    func missingRepositoryBinding() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try f.prepare()
        var request = f.protectedRequest(); request.protectedRepositoryId = nil
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.handle(request) }
        #expect(try String(contentsOf: f.root.appendingPathComponent("note"), encoding: .utf8) == "old")
    }

    @Test("a second operation cannot steal an existing reservation")
    func competingOperation() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try f.prepare()
        var other = f.request(.prepare)
        other.operationId = UUID()
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.handle(other) }
        #expect(try String(contentsOf: f.root.appendingPathComponent("note"), encoding: .utf8) == "old")
    }

    @Test("a concurrent recreation is retained, then the same operation can resume")
    func interruptedInstall() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let prepared = try f.prepare()
        #expect(throws: SourceSyncError.self) {
            try SyncEndpointService.$beforeInstall.withValue({ _ in
                try Data("external".utf8).write(to: f.root.appendingPathComponent("note"))
            }) { try SyncEndpointService.handle(f.protectedRequest()) }
        }
        #expect(try String(contentsOf: f.root.appendingPathComponent("note"), encoding: .utf8) == "external")
        #expect(try String(contentsOf: URL(fileURLWithPath: try #require(prepared.recoveryPath)).appendingPathComponent(SyncEndpointService.recoveryName(for: "note")), encoding: .utf8) == "old")
        // The operator resolves the synthetic conflict; replaying this
        // same reserved operation installs only its verified payload.
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("note"))
        #expect(try SyncEndpointService.handle(f.protectedRequest()).inventory.items["note"] == f.after)
    }

    @Test("a deleted control record is not silently reinitialized")
    func lostState() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try FileManager.default.removeItem(at: AppPaths.sourceSyncControlDirectory(for: f.root).appendingPathComponent("root.json"))
        #expect(throws: SourceSyncError.self) {
            try SyncEndpointService.handle(.init(action: .inventory, group: f.group, root: f.root.path))
        }
    }

    @Test("cleanup retains an unexpectedly edited captured inode")
    func changedCapture() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let prepared = try f.prepare()
        _ = try SyncEndpointService.handle(f.protectedRequest())
        _ = try SyncEndpointService.handle(f.request(.finish))
        let captured = URL(fileURLWithPath: try #require(prepared.recoveryPath)).appendingPathComponent(SyncEndpointService.recoveryName(for: "note"))
        try Data("late editor save".utf8).write(to: captured)
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.handle(f.request(.cleanup)) }
        #expect(try String(contentsOf: captured, encoding: .utf8) == "late editor save")
        #expect(try String(contentsOf: f.root.appendingPathComponent("note"), encoding: .utf8) == "new")
    }

    @Test("incoming bytes must be durable before displacing a protected live file")
    func incomingDurability() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try f.prepare()
        #expect(throws: SourceSyncError.self) {
            try SyncDurability.$synchronize.withValue({ fd in
                var info = stat()
                if fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size == 3 { return -1 }
                return fsync(fd)
            }) {
                try SyncEndpointService.handle(f.protectedRequest())
            }
        }
        #expect(try String(contentsOf: f.root.appendingPathComponent("note"), encoding: .utf8) == "old")
    }

    @Test("cancellation cannot release a worker that has started installing")
    func noCancellationAfterCommit() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let prepared = try f.prepare()
        _ = try SyncEndpointService.handle(f.protectedRequest())
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.handle(f.request(.cancel)) }
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.handle(.init(action: .inventory, group: f.group, root: f.root.path)) }
        #expect(try String(contentsOf: f.root.appendingPathComponent("note"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: URL(fileURLWithPath: #require(prepared.recoveryPath)).appendingPathComponent(SyncEndpointService.recoveryName(for: "note")), encoding: .utf8) == "old")
    }

    @Test("a newer journal version refuses before installing any file")
    func futureJournal() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let reply = try f.prepare()
        let journal = URL(fileURLWithPath: try #require(reply.stagingPath)).deletingLastPathComponent().appendingPathComponent("journal.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        object["version"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: journal)
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.handle(f.protectedRequest()) }
        #expect(try String(contentsOf: f.root.appendingPathComponent("note"), encoding: .utf8) == "old")
    }

    @Test("a recreated folder is refused even if the filesystem reuses its inode number")
    func reusedRootInode() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        #expect(throws: SourceSyncError.self) {
            try SourceSyncFilesystem.$rootCreation.withValue({ _ in "different-creation-generation" }) {
                try SyncEndpointService.handle(.init(action: .inventory, group: f.group, root: f.root.path))
            }
        }
        #expect(try String(contentsOf: f.root.appendingPathComponent("note"), encoding: .utf8) == "old")
    }

    @Test("finish requires durable installation even for an empty change list")
    func cannotFinishPreparedNoop() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        var prepare = f.request(.prepare); prepare.operations = []; prepare.exportPaths = []
        _ = try SyncEndpointService.handle(prepare)
        var finish = prepare; finish.action = .finish
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.handle(finish) }
        #expect(throws: SourceSyncError.self) { try SyncEndpointService.handle(.init(action: .inventory, group: f.group, root: f.root.path)) }
    }
}
