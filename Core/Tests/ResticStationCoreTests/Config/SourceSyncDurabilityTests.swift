import Foundation
import Testing
@testable import ResticStationCore

@Suite("Source-sync durable installation")
struct SourceSyncDurabilityTests {
    @Test("exclusive installation preserves a concurrently created target")
    func noClobber() throws {
        let root = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("candidate".utf8).write(to: root.appendingPathComponent("candidate"))
        try Data("other writer".utf8).write(to: root.appendingPathComponent("target"))
        let directory = try SourceSyncFilesystem.openRoot(root.path)
        #expect(throws: SourceSyncError.self) {
            try SyncDurability.moveExclusive("candidate", from: directory, to: directory, as: "target")
        }
        #expect(try String(contentsOf: root.appendingPathComponent("candidate"), encoding: .utf8) == "candidate")
        #expect(try String(contentsOf: root.appendingPathComponent("target"), encoding: .utf8) == "other writer")
        try SyncDurability.moveExclusive("candidate", from: directory, to: directory, as: "new")
        #expect(try String(contentsOf: root.appendingPathComponent("new"), encoding: .utf8) == "candidate")
    }

    @Test("corrupt existing state refuses instead of becoming an empty baseline")
    func corruptState() throws {
        let root = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try SourceSyncFilesystem.openRoot(root.path)
        try SyncDurability.write(["generation": "old"], named: "state.json", in: directory)
        try Data("{broken".utf8).write(to: root.appendingPathComponent("state.json"))
        #expect(throws: SourceSyncError.self) {
            try SyncDurability.read([String: String].self, named: "state.json", in: directory)
        }
    }

    @Test("an unconfirmed journal write is never reported successful")
    func syncFailure() throws {
        let root = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try SourceSyncFilesystem.openRoot(root.path)
        #expect(throws: SourceSyncError.self) {
            try SyncDurability.$synchronize.withValue({ _ in -1 }) {
                try SyncDurability.write(["generation": "new"], named: "state.json", in: directory)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }
}
