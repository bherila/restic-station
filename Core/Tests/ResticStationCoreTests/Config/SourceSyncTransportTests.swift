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

    @Test("a failed peer keeps its reason", arguments: [
        (Int32(2), #"{"ok":false,"error":{"code":"set_busy","message":"Another synchronization is already using these folders."}}"#, "busy"),
        (Int32(1), #"{"ok":false,"error":{"code":"config_invalid","message":"Backup repositories cannot be live sync folders.\u001b[2J"}}"#, "refused"),
        (Int32(1), #"{"ok":false,"error":{"code":"operation_not_allowed","message":"The folders changed after the preview."}}"#, "request"),
        (Int32(255), "", "ssh"),
        (Int32(127), "", "helper"),
        (Int32(1), "not json", "generic"),
    ])
    func remoteFailureReason(exitCode: Int32, stdout: String, kind: String) async throws {
        let group = SourceSyncGroup(name: "Notes", localPath: "/workspace/notes", peer: .init(path: "/srv/notes", sshTarget: "sync.example.test", helperPath: "/opt/rs/helper"), coordinatorMachineId: "laptop")
        let fake = FakeProcessRunner(script: [.init(argvPrefix: ["/usr/bin/ssh"], stdoutLines: stdout.isEmpty ? [] : [stdout], exitCode: exitCode)])
        let request = SyncEndpointRequest(action: .inventory, group: group, root: group.peer.path)
        let error = await #expect(throws: SourceSyncError.self) { _ = try await SourceSyncClient(runner: fake).request(request, at: group.peer) }
        let message = error?.description ?? ""
        switch kind {
        case "busy": #expect(error == .busy)
        case "refused":
            #expect(message == "The other computer refused its folder: Backup repositories cannot be live sync folders.[2J")
            if case .unsafeRoot = error {} else { Issue.record("expected unsafeRoot, got \(String(describing: error))") }
        case "request": #expect(message.hasSuffix("The folders changed after the preview."))
        case "ssh": #expect(message.contains("over SSH"))
        case "helper": #expect(message.contains("/opt/rs/helper"))
        default: #expect(message.contains("could not complete the helper operation"))
        }
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
        #expect(call.argv.contains("--from0") && call.argv.contains("--safe-links") && call.argv.contains("--ignore-times"))
        #expect(!call.argv.contains { $0.hasPrefix("--delete") })
        #expect(call.argv.suffix(2) == ["/staged/", "sync.example.test:'/srv/other copy/'"])
        #expect(call.env?["RSYNC_OLD_ARGS"] == "1" && call.env?["RSYNC_PROTECT_ARGS"] == "0")
        #expect(try Data(contentsOf: list) == Data("a\nb\0space name\0".utf8))
        #expect(call.stdin == nil)
    }

    @Test("a stale staged file with the same size and time is still replaced", .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync")))
    func staleStagedFileIsReplaced() async throws {
        let base = try syncTemporaryRoot()
        let source = base.appendingPathComponent("export"), target = base.appendingPathComponent("incoming")
        for directory in [source, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        // Exports preserve modification times, so rsync's default quick
        // check alone would treat this differing staged value as current.
        let time = Date(timeIntervalSince1970: 981_173_106)
        try Data("planned".utf8).write(to: source.appendingPathComponent("note"))
        try Data("stale!!".utf8).write(to: target.appendingPathComponent("note"))
        for directory in [source, target] {
            try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: directory.appendingPathComponent("note").path)
        }
        try await SourceSyncClient().copy(paths: ["note"], from: .init(path: source.path), to: .init(path: target.path), listFile: base.appendingPathComponent("list"))
        #expect(try String(contentsOf: target.appendingPathComponent("note"), encoding: .utf8) == "planned")
        #expect(try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("note").path)[.modificationDate] as? Date == time)
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
