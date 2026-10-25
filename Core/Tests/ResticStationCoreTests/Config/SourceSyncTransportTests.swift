import Foundation
import Testing
@testable import ResticStationCore

@Suite("Source sync process boundaries")
struct SourceSyncTransportTests {
    @Test("SSH uses pinned host keys and typed stdin; helper names cannot become shell code")
    func sshProtocol() async throws {
        let group = SourceSyncGroup(name: "Notes", localPath: "/workspace/notes", peer: .init(path: "/srv/notes", sshTarget: "sync.example.test", helperPath: "/opt/helper's tools/helper"), coordinatorMachineId: "laptop")
        let reply = SyncEndpointReply(inventory: .init(rootIdentity: "1:2", items: [:]))
        struct Envelope: Encodable { let ok = true; let data: SyncEndpointReply }
        let output = String(decoding: try ConfigStore.makeEncoder().encode(Envelope(data: reply)), as: UTF8.self)
        let fake = FakeProcessRunner(script: [.init(argvPrefix: ["/usr/bin/ssh"], stdoutLines: [output])])
        let request = SyncEndpointRequest(action: .inventory, group: group, root: group.peer.path)
        _ = try await SourceSyncClient(runner: fake).request(request, at: group.peer)
        let call = try #require(fake.invocations.first)
        #expect(call.argv.contains("StrictHostKeyChecking=yes"))
        #expect(call.argv.contains("BatchMode=yes"))
        #expect(call.argv.suffix(6) == ["--", "sync.example.test", "'/opt/helper'\"'\"'s tools/helper'", "sync", "endpoint", "--json"])
        let input = try ConfigStore.makeDecoder().decode(SyncEndpointRequest.self, from: #require(call.stdin))
        #expect(input.root == "/srv/notes" && input.action == .inventory)
        #expect(call.env?["RESTIC_PASSWORD"] == nil)
    }

    @Test("rsync gets a NUL list, no delete flag, explicit quoting and no inherited option environment")
    func rsyncBoundary() async throws {
        let base = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let list = base.appendingPathComponent("list")
        let fake = FakeProcessRunner(script: [.init(argvPrefix: ["/usr/bin/rsync"])])
        try await SourceSyncClient(runner: fake).copy(paths: ["a\nb", "space name"], from: .init(path: "/staged"), to: .init(path: "/srv/other copy", sshTarget: "sync.example.test"), listFile: list)
        let call = try #require(fake.invocations.first)
        #expect(call.argv.contains("--from0") && call.argv.contains("--safe-links"))
        #expect(!call.argv.contains { $0.hasPrefix("--delete") })
        #expect(call.argv.suffix(2) == ["/staged/", "sync.example.test:'/srv/other copy/'"])
        #expect(call.env?["RSYNC_OLD_ARGS"] == "1" && call.env?["RSYNC_PROTECT_ARGS"] == "0")
        #expect(try Data(contentsOf: list) == Data("a\nb\0space name\0".utf8))
        #expect(call.stdin == nil)
    }

    @Test("an incomplete remote receipt cannot become an inventory")
    func incompleteRPC() async throws {
        let fake = FakeProcessRunner(script: [.init(argvPrefix: ["/usr/bin/ssh"], stdoutLines: ["{\"ok\":true}"], outputComplete: false)])
        let group = SourceSyncGroup(name: "Notes", localPath: "/workspace/notes", peer: .init(path: "/srv/notes", sshTarget: "sync.example.test"), coordinatorMachineId: "laptop")
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncClient(runner: fake).request(.init(action: .inventory, group: group, root: group.peer.path), at: group.peer)
        }
    }
}
