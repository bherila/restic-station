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
        let fake = FakeProcessRunner(script: [Self.version("/usr/bin/rsync", "openrsync: protocol version 29"), .init(argvPrefix: ["/usr/bin/rsync"])])
        try await SyncRsync.$searched.withValue(["/usr/bin/rsync"]) {
            try await SourceSyncClient(runner: fake).copy(paths: ["a\nb", "space name"], from: .init(path: "/staged"), to: .init(path: "/srv/other copy", sshTarget: "sync.example.test"), listFile: list, options: .init())
        }
        let call = try #require(fake.invocations.last)
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
        try await SourceSyncClient().copy(paths: ["note"], from: .init(path: source.path), to: .init(path: target.path), listFile: base.appendingPathComponent("list"), options: .init())
        #expect(try String(contentsOf: target.appendingPathComponent("note"), encoding: .utf8) == "planned")
        #expect(try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("note").path)[.modificationDate] as? Date == time)
    }

    static func version(_ path: String, _ line: String, exitCode: Int32 = 0) -> FakeProcessRunner.Expectation {
        .init(argvPrefix: [path, "--version"], stdoutLines: [line], exitCode: exitCode)
    }

    @Test("rsync discovery takes the first candidate that runs and speaks protocol 29 or newer")
    func rsyncDiscovery() async throws {
        #expect(SyncRsync.protocolVersion("rsync  version 3.4.0  protocol version 32\nCopyright") == 32)
        #expect(SyncRsync.protocolVersion("openrsync: protocol version 29\nrsync version 2.6.9 compatible") == 29)
        #expect(SyncRsync.protocolVersion("usage: rsync [options]") == nil)
        #if os(macOS)
        // A package-manager GNU rsync wins over the built-in openrsync.
        #expect(SyncRsync.candidates.first == "/opt/homebrew/bin/rsync" && SyncRsync.candidates.last == "/usr/bin/rsync")
        #endif
        let fake = FakeProcessRunner(script: [
            .init(argvPrefix: ["/missing/rsync", "--version"], failure: .launchFailed("no such file")),
            Self.version("/old/rsync", "rsync  version 2.5.7  protocol version 26"),
            Self.version("/broken/rsync", "rsync  version 3.4.0  protocol version 32", exitCode: 1),
            Self.version("/brew/rsync", "rsync  version 3.4.1  protocol version 32"),
        ])
        let found = await SyncRsync.$searched.withValue(["/missing/rsync", "/old/rsync", "/broken/rsync", "/brew/rsync", "/usr/bin/rsync"]) {
            await SyncRsync.find(runner: fake)
        }
        #expect(found == SyncRsync(path: "/brew/rsync", protocolVersion: 32))
        #expect(fake.invocations.count == 4)
        #expect(fake.invocations.allSatisfy { $0.env == ["LC_ALL": "C"] })
    }

    @Test("a computer without rsync is refused at preview with how to install it")
    func missingRsync() async throws {
        let peer = SyncEndpoint(path: "/srv/notes", sshTarget: "sync.example.test")
        func reply(_ transfer: SyncTransferTools?) -> SyncEndpointReply {
            var reply = SyncEndpointReply(inventory: .init(rootIdentity: "1:2", items: [:])); reply.transfer = transfer; return reply
        }
        func refusal(_ peerReply: SyncEndpointReply, localRsync: Bool = true) async -> String? {
            let fake = FakeProcessRunner(script: localRsync ? [Self.version("/usr/bin/rsync", "openrsync: protocol version 29")] : [])
            do {
                try await SyncRsync.$searched.withValue(localRsync ? ["/usr/bin/rsync"] : []) {
                    try await SourceSyncClient(runner: fake).checkTransfer(peer: peerReply, at: peer)
                }
                return nil
            } catch { return "\(error)" }
        }
        let local = await refusal(reply(nil), localRsync: false)
        #expect(local?.contains("on this computer") == true)
        #if os(macOS)
        #expect(local?.contains("brew install rsync") == true)
        #else
        #expect(local?.contains("sudo apt install rsync") == true)
        #endif
        let linuxPeer = await refusal(reply(.init(platform: .linux, rsync: nil)))
        #expect(linuxPeer?.contains("on the other computer") == true && linuxPeer?.contains("sudo dnf install rsync") == true)
        let macPeer = await refusal(reply(.init(platform: .macOS, rsync: nil)))
        #expect(macPeer?.contains("on the other computer") == true && macPeer?.contains("brew install rsync") == true)
        #expect(await refusal(reply(.init(platform: .linux, rsync: .init(path: "rsync; true", protocolVersion: 32))))?.contains("cannot be used") == true)
        // An older helper reports nothing and keeps using rsync on its PATH.
        #expect(await refusal(reply(nil)) == nil)
        #expect(await refusal(reply(.init(platform: .linux, rsync: .init(path: "/usr/bin/rsync", protocolVersion: 32)))) == nil)
    }

    @Test("transfers across SSH compress and run the peer's own rsync; only the other computer offers a delta basis")
    func deltaOptions() async throws {
        let base = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let remote = SyncEndpoint(path: "/srv/other copy", sshTarget: "sync.example.test")
        func argv(from source: SyncEndpoint, to destination: SyncEndpoint, _ options: SyncCopyOptions) async throws -> [String] {
            let fake = FakeProcessRunner(script: [Self.version("/opt/homebrew/bin/rsync", "rsync  version 3.4.1  protocol version 32"), .init(argvPrefix: ["/opt/homebrew/bin/rsync"])])
            try await SyncRsync.$searched.withValue(["/opt/homebrew/bin/rsync"]) {
                try await SourceSyncClient(runner: fake).copy(paths: ["note"], from: source, to: destination,
                                                              listFile: base.appendingPathComponent(UUID().uuidString), options: options)
            }
            return try #require(fake.invocations.last).argv
        }
        let push = try await argv(from: .init(path: "/staged"), to: remote, .init(basis: "/srv/peer's notes", remoteRsync: "/usr/local/bin/rsync"))
        #expect(push.first == "/opt/homebrew/bin/rsync")
        #expect(push.contains("--compress"))
        #expect(push.contains("--copy-dest='/srv/peer'\"'\"'s notes/'"))
        #expect(push.contains("--rsync-path='/usr/local/bin/rsync'"))
        #expect(push.suffix(2) == ["/staged/", "sync.example.test:'/srv/other copy/'"])
        // This computer never offers its own files as a sender's basis.
        let pull = try await argv(from: remote, to: .init(path: "/staged"), .init(basis: "/workspace/my notes", remoteRsync: "/usr/bin/rsync"))
        #expect(pull.contains("--compress") && pull.contains("--rsync-path='/usr/bin/rsync'"))
        #expect(!pull.contains { $0.hasPrefix("--copy-dest") })
        let local = try await argv(from: .init(path: "/staged"), to: .init(path: "/incoming"), .init(basis: "/workspace/notes", remoteRsync: "/usr/bin/rsync"))
        #expect(!local.contains("--compress") && !local.contains { $0.hasPrefix("--copy-dest") || $0.hasPrefix("--rsync-path") })
        await #expect(throws: SourceSyncError.stalePlan) { _ = try await argv(from: .init(path: "/staged"), to: remote, .init(remoteRsync: "rsync")) }
        await #expect(throws: SourceSyncError.stalePlan) { _ = try await argv(from: .init(path: "/staged"), to: remote, .init(basis: "/srv/../etc")) }
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
