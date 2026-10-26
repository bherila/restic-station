import Foundation
import Testing
@testable import ResticStationCore

@Suite("Sync and backup orchestration")
struct SourceSyncCoordinatorTests {
    struct SSHFixtureRunner: ProcessRunning {
        let config: String
        func run(_ argv: [String], env: [String: String]?, stdin: Data?, currentDirectory: String?, onStdoutLine: (@Sendable (String) -> Void)?, onStderrLine: (@Sendable (String) -> Void)?, timeout: TimeInterval?) async throws -> ProcessResult {
            var args = argv
            if args.first == "/usr/bin/ssh" { args.insert(contentsOf: ["-F", config], at: 1) }
            if args.first == "/usr/bin/rsync", let e = args.firstIndex(of: "-e") {
                args[e + 1] += " -F " + ShellQuote.singleQuote(config)
            }
            return try await DefaultProcessRunner().run(args, env: env, stdin: stdin, currentDirectory: currentDirectory, onStdoutLine: onStdoutLine, onStderrLine: onStderrLine, timeout: timeout)
        }
    }
    struct LocalTransport: SourceSyncTransport {
        func request(_ request: SyncEndpointRequest, at endpoint: SyncEndpoint) async throws -> SyncEndpointReply {
            try SyncEndpointService.handle(request)
        }
        func copy(paths: [String], from source: SyncEndpoint, to destination: SyncEndpoint, listFile: URL) async throws {
            // Like SourceSyncClient, leave a list file for the coordinator to clean.
            try Data(paths.joined(separator: "\0").utf8).write(to: listFile, options: .withoutOverwriting)
            let sourceRoot = try SourceSyncFilesystem.openRoot(source.path)
            let targetRoot = try SourceSyncFilesystem.openRoot(destination.path)
            let inventory = try SourceSyncFilesystem.inventory(at: source.path)
            try SourceSyncFilesystem.exportItems(paths, expected: inventory, from: sourceRoot, to: targetRoot)
        }
    }
    actor Backups: SourceSyncBackingUp {
        var protectionFails = false
        var finalFails = false
        var protectedSets: [BackupSet] = []
        var finalSets: [BackupSet] = []
        var manifests: [SyncInventory] = []
        var finalHasAgreement = false

        func failProtection() { protectionFails = true }
        func failFinal(_ value: Bool) { finalFails = value }
        func counts() -> (Int, Int) { (protectedSets.count, finalSets.count) }
        func protectedSources() -> [[String]] { protectedSets.map(\.sources) }
        func protectedInventories() -> [SyncInventory] { manifests }
        func agreementWasBackedUp() -> Bool { finalHasAgreement }

        func protect(set: BackupSet, vault: URL, inventory: SyncInventory) throws -> SyncProtectionReceipt {
            protectedSets.append(set)
            manifests.append(inventory)
            if protectionFails { throw SourceSyncError.protectionFailed }
            let restored = vault.deletingLastPathComponent().appendingPathComponent("restore-\(UUID())")
            try FileManager.default.copyItem(at: vault, to: restored)
            return try SyncProtectionReceipt.verify(repositoryId: String(repeating: "b", count: 64), snapshotId: String(repeating: "a", count: 64), expected: inventory, restoredAt: restored)
        }
        func backup(set: BackupSet, retaining vault: URL?) throws {
            finalSets.append(set)
            if let vault { finalHasAgreement = try SourceSyncFilesystem.inventory(at: vault.path).items["agreement.json"] != nil }
            if finalFails { throw SourceSyncError.protectionFailed }
        }
    }

    struct Fixture {
        let base: URL
        let workspace: URL
        let local: URL
        let peer: URL
        let paths: AppPaths
        let group: SourceSyncGroup
        let set: BackupSet
        let config: AppConfig
        let backups = Backups()
        var coordinator: SourceSyncCoordinator { .init(paths: paths, transport: LocalTransport(), backups: backups) }

        init() throws {
            base = try syncTemporaryRoot()
            workspace = base.appendingPathComponent("workspace")
            local = workspace.appendingPathComponent("notes")
            peer = base.appendingPathComponent("peer's copy")
            let repo = base.appendingPathComponent("repository")
            for directory in [local, peer, repo] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            paths = AppPaths(root: base.appendingPathComponent("appdata"))
            try paths.ensureDirectories()
            group = SourceSyncGroup(name: "Notes", localPath: local.path, peer: .init(path: peer.path), coordinatorMachineId: "laptop")
            set = BackupSet(id: UUID(), name: "Workspace", sources: [workspace.path], schedule: .daily(hour: 2, minute: 0), destinations: [.init(id: UUID(), label: "Archive", repoURL: repo.path, isPrimary: true)], syncFolders: [group])
            config = AppConfig(sets: [set])
        }

        func write(_ value: String, _ path: String, peer other: Bool = false) throws {
            let file = (other ? peer : local).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: file)
        }
        func setModified(_ date: Date, _ path: String, peer other: Bool = false) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: (other ? peer : local).appendingPathComponent(path).path)
        }
        func modified(_ path: String, peer other: Bool = false) throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: (other ? peer : local).appendingPathComponent(path).path)[.modificationDate] as? Date
        }
        func preview(includePaths: Bool = false) async throws -> SourceSyncPreview {
            try await coordinator.preview(set: set, group: group, machineId: "laptop", config: config, binding: "fixture", includePaths: includePaths)
        }
        func apply(_ preview: SourceSyncPreview) async throws -> SourceSyncStatus {
            try await coordinator.apply(token: #require(preview.previewToken), set: set, group: group, machineId: "laptop", config: config, binding: "fixture")
        }
    }

    @Test("both directions use only the selected folder while backing up the parent")
    func independentScopes() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("local", "nested/from-local")
        try f.write("remote", "from-peer", peer: true)
        try Data("sibling".utf8).write(to: f.workspace.appendingPathComponent("sibling"))
        let preview = try await f.preview()
        #expect(preview.conflicts == 0 && preview.copies == 3)
        #expect(preview.changes == nil)
        #expect(try await f.apply(preview).status == "synchronized")
        #expect(try String(contentsOf: f.peer.appendingPathComponent("nested/from-local"), encoding: .utf8) == "local")
        #expect(try String(contentsOf: f.local.appendingPathComponent("from-peer"), encoding: .utf8) == "remote")
        #expect(!FileManager.default.fileExists(atPath: f.peer.appendingPathComponent("sibling").path))
        // Only new entries: nothing was at risk, so no protection backup.
        #expect(await f.backups.protectedSources() == [])
        #expect(await f.backups.counts().1 == 1)
        #expect(await f.backups.agreementWasBackedUp())
        // Replacing a version puts it at risk: protection covers the whole
        // configured backup scope, not only the sync folder.
        try f.write("remote edit", "from-peer", peer: true)
        #expect(try await f.apply(f.preview()).status == "synchronized")
        #expect(await f.backups.protectedSources() == [[f.workspace.path]])
        #expect(try String(contentsOf: f.local.appendingPathComponent("from-peer"), encoding: .utf8) == "remote edit")
    }

    @Test("synced files keep their source modification time in both directions")
    func modificationTimes() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let earlier = Date(timeIntervalSince1970: 981_173_106), later = Date(timeIntervalSince1970: 1_234_567_890)
        try f.write("local", "nested/from-local"); try f.setModified(earlier, "nested/from-local")
        try f.write("remote", "from-peer", peer: true); try f.setModified(later, "from-peer", peer: true)
        #expect(try await f.apply(f.preview()).status == "synchronized")
        #expect(try f.modified("nested/from-local", peer: true) == earlier)
        #expect(try f.modified("from-peer") == later)
        // A replacement displaces the old value; the new one keeps its time.
        try f.write("edited", "from-peer"); try f.setModified(earlier, "from-peer")
        #expect(try await f.apply(f.preview()).status == "synchronized")
        #expect(try String(contentsOf: f.peer.appendingPathComponent("from-peer"), encoding: .utf8) == "edited")
        #expect(try f.modified("from-peer", peer: true) == earlier)
        // Times are not identity: a time-only change is not a sync change.
        try f.setModified(later, "from-peer")
        #expect(try await f.preview().copies == 0)
    }

    @Test("read-only source directories export and install with their final modes")
    func readOnlyTreeConstruction() async throws {
        let f = try Fixture()
        let nested = f.local.appendingPathComponent("readonly/nested")
        let peerNested = f.peer.appendingPathComponent("readonly/nested")
        defer {
            for root in [f.local, f.peer] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("readonly").path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("readonly/nested").path)
            }
            try? FileManager.default.removeItem(at: f.base)
        }
        try f.write("content", "readonly/nested/note")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: nested.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: nested.deletingLastPathComponent().path)
        #expect(try await f.apply(f.preview()).status == "synchronized")
        #expect(try String(contentsOf: peerNested.appendingPathComponent("note"), encoding: .utf8) == "content")
        let local = try SourceSyncFilesystem.inventory(at: f.local.path)
        let peer = try SourceSyncFilesystem.inventory(at: f.peer.path)
        #expect(local.items == peer.items)
        #expect(local.items["readonly"]?.mode == 0o500 && local.items["readonly/nested"]?.mode == 0o500)
        // A new run can export an already-sealed private tree again.
        #expect(try await f.apply(f.preview()).status == "synchronized")
    }

    @Test("a protection failure cannot displace either live version")
    func protectionGate() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("agreed", "note"); try f.write("agreed", "note", peer: true)
        _ = try await f.apply(f.preview())
        try f.write("new", "note")
        let preview = try await f.preview()
        await f.backups.failProtection()
        await #expect(throws: SourceSyncError.self) { try await f.apply(preview) }
        #expect(try String(contentsOf: f.peer.appendingPathComponent("note"), encoding: .utf8) == "agreed")
        #expect(try String(contentsOf: f.local.appendingPathComponent("note"), encoding: .utf8) == "new")
        #expect(try SourceSyncCoordinator.status(paths: f.paths, setId: f.set.id, groupId: f.group.id).status == "needsRecovery")
        #expect(try SourceSyncCoordinator.status(paths: f.paths, setId: f.set.id, groupId: f.group.id).canCancel)
        _ = try await f.coordinator.cancelUnstarted(set: f.set, group: f.group, machineId: "laptop")
        #expect(try await f.preview().copies == 1)
    }

    @Test("cancelling before installation removes private verification restores only")
    func cancelledVerificationCleanup() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("local", "note")
        _ = try await f.apply(f.preview())
        // A replacement puts the peer's version at risk, so it is protected.
        try f.write("local edit", "note")
        let preview = try await f.preview()
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncCoordinator.$afterDurablePhase.withValue({ phase in
                if phase == "protected" { throw SourceSyncError.transferFailed }
            }) { try await f.apply(preview) }
        }
        let store = try SourceSyncStore(paths: f.paths, setId: f.set.id, groupId: f.group.id)
        let operation = try store.operation(#require(store.record().activeOperation))
        let before = try FileManager.default.contentsOfDirectory(atPath: operation.path.path)
        #expect(before.contains { $0.hasPrefix("restore-") })
        let unrelated = operation.path.appendingPathComponent("restore-not-a-verification")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        _ = try await f.coordinator.cancelUnstarted(set: f.set, group: f.group, machineId: "laptop")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: operation.path.path)
        #expect(!remaining.contains { $0.hasPrefix("restore-") && UUID(uuidString: String($0.dropFirst(8))) != nil })
        #expect(!remaining.contains("vault"))
        #expect(remaining.contains("restore-not-a-verification"))
        #expect(try String(contentsOf: f.local.appendingPathComponent("note"), encoding: .utf8) == "local edit")
        #expect(try String(contentsOf: f.peer.appendingPathComponent("note"), encoding: .utf8) == "local")
        #expect(try store.record().activeOperation == nil)
    }

    @Test("deleting a subtree removes children before their parent")
    func subtreeDeletion() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("a", "nested/a")
        _ = try await f.apply(f.preview())
        try FileManager.default.removeItem(at: f.local.appendingPathComponent("nested"))
        let preview = try await f.preview()
        #expect(preview.removals == 2)
        _ = try await f.apply(preview)
        #expect(!FileManager.default.fileExists(atPath: f.peer.appendingPathComponent("nested").path))
    }

    @Test("a changed finish inventory is retained for attention without poisoning recovery receipts")
    func changedFinishCanRecover() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("first", "note")
        _ = try await f.apply(f.preview())
        try f.write("planned", "note")
        let preview = try await f.preview()
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncCoordinator.$afterDurablePhase.withValue({ phase in
                if phase == "installed" { try f.write("external", "note") }
            }) { try await f.apply(preview) }
        }
        #expect(try String(contentsOf: f.local.appendingPathComponent("note"), encoding: .utf8) == "external")
        #expect(try SourceSyncCoordinator.status(paths: f.paths, setId: f.set.id, groupId: f.group.id).status == "needsRecovery")
        // The operator resolves the editor conflict. Retrying the same
        // operation must inspect this copy again, not reuse a bad receipt.
        try f.write("planned", "note")
        let result = try await f.coordinator.recover(set: f.set, group: f.group, machineId: "laptop", binding: "fixture")
        #expect(result.status == "synchronized" && result.operationId == nil)
        #expect(await f.backups.counts().0 == 1)
    }

    @Test("a failed final backup resumes without replaying synchronization")
    func finalBackupRecovery() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("first", "a")
        _ = try await f.apply(f.preview())
        try f.write("a", "a")
        let preview = try await f.preview()
        await f.backups.failFinal(true)
        await #expect(throws: SourceSyncError.self) { try await f.apply(preview) }
        let status = try SourceSyncCoordinator.status(paths: f.paths, setId: f.set.id, groupId: f.group.id)
        #expect(status.status == "backupNeedsAttention" && status.operationId != nil)
        #expect(!status.canCancel)
        await #expect(throws: SourceSyncError.self) { try await f.coordinator.cancelUnstarted(set: f.set, group: f.group, machineId: "laptop") }
        // An ordinary edit after sync is not overwritten by retrying its
        // post-sync backup. The next preview reconciles it as a new edit.
        try f.write("later", "a")
        await f.backups.failFinal(false)
        let recovered = try await f.coordinator.recover(set: f.set, group: f.group, machineId: "laptop", binding: "fixture")
        #expect(recovered.status == "synchronized" && recovered.operationId == nil)
        #expect(await f.backups.counts().0 == 1)
        #expect(try String(contentsOf: f.local.appendingPathComponent("a"), encoding: .utf8) == "later")
        #expect(try await f.preview().copies == 1)
    }

    @Test("conflicts issue no apply authority and stale previews cannot write")
    func staleAndConflict() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("a", "a")
        let stale = try await f.preview()
        try f.write("changed", "a")
        await #expect(throws: SourceSyncError.self) { try await f.apply(stale) }
        #expect(!FileManager.default.fileExists(atPath: f.peer.appendingPathComponent("a").path))
        #expect(await f.backups.counts().0 == 0)
        let g = try Fixture(); defer { try? FileManager.default.removeItem(at: g.base) }
        try g.write("a", "a"); try g.write("b", "a", peer: true)
        let conflict = try await g.preview()
        #expect(conflict.conflicts == 1 && conflict.previewToken == nil)
    }

    @Test("every durable phase can resume the same operation", arguments: ["reserved", "protected", "installing", "installed", "agreed", "backedUp", "complete"])
    func phaseRecovery(_ phase: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("a", "a")
        let preview = try await f.preview()
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncCoordinator.$afterDurablePhase.withValue({ at in
                if at == phase { throw SourceSyncError.transferFailed }
            }) { try await f.apply(preview) }
        }
        let before = await f.backups.counts()
        let result = try await f.coordinator.recover(set: f.set, group: f.group, machineId: "laptop", binding: "fixture")
        #expect(result.status == "synchronized" && result.operationId == nil)
        #expect(try String(contentsOf: f.peer.appendingPathComponent("a"), encoding: .utf8) == "a")
        if phase == "backedUp" || phase == "complete" { #expect(await f.backups.counts().1 == before.1) }
    }

    @Test("a repository in cloud storage still syncs")
    func cloudRepositorySyncs() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("local", "from-local")
        let repository = try SourceSyncFilesystem.resolvedDirectory(f.set.destinations[0].repoURL)
        // An encrypted repository in iCloud Drive holds no plaintext; only
        // the overlap check reads its path.
        try await SourceSyncFilesystem.$reachesCloudStorage.withValue({ $0 == repository || $0.hasPrefix(repository + "/") }) {
            let preview = try await f.preview()
            #expect(preview.copies == 1 && preview.previewToken != nil)
            #expect(try await f.apply(preview).status == "synchronized")
        }
        #expect(try String(contentsOf: f.peer.appendingPathComponent("from-local"), encoding: .utf8) == "local")
    }

    @Test("a copy that diverges before agreement names the first differing path", arguments: [false, true])
    func divergenceNamesPath(_ onPeer: Bool) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("a", "a"); try f.write("b", "b"); try f.write("c", "c")
        let preview = try await f.preview()
        let error = await #expect(throws: SourceSyncError.self) {
            try await SourceSyncCoordinator.$afterDurablePhase.withValue({ at in
                if at == "installed" { try f.write("edited", "b", peer: onPeer) }
            }) { try await f.apply(preview) }
        }
        #expect(error?.description == "\(onPeer ? "The other copy" : "The local copy") changed before agreement at \"b\". Resolve the change, then resume this operation.")
    }

    @Test("transfer lists and unused directory candidates do not outlive their use")
    func privateLeftoversRemoved() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("local", "made/here/note")
        try f.write("peer", "from-peer", peer: true)
        let preview = try await f.preview()
        // Someone creates the same new directory first, as a retry would
        // find it: the installed value matches and the candidate is unused.
        let status = try await SyncEndpointService.$beforeInstall.withValue({ path in
            if path == "made" { try FileManager.default.createDirectory(at: f.peer.appendingPathComponent("made"), withIntermediateDirectories: false) }
        }) { try await f.apply(preview) }
        #expect(status.status == "synchronized")
        let state = f.paths.root.appendingPathComponent("source-sync")
        let names = (FileManager.default.enumerator(atPath: state.path)?.allObjects as? [String] ?? []).map { ($0 as NSString).lastPathComponent }
        #expect(!names.contains { $0.hasPrefix("files-") })
        let endpointNames = [f.local, f.peer].flatMap { root in
            (FileManager.default.enumerator(atPath: root.deletingLastPathComponent().path)?.allObjects as? [String] ?? []).map { ($0 as NSString).lastPathComponent }
        }
        #expect(!(names + endpointNames).contains { $0.hasPrefix("directory-") })
    }

    @Test("only plans that replace or delete an existing version run a protection backup",
          arguments: ["create", "replace", "delete", "mixed"])
    func protectionOnlyWhenDisplacing(_ kind: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("kept", "kept")
        _ = try await f.apply(f.preview())
        #expect(await f.backups.counts().0 == 0)
        switch kind {
        case "create": try f.write("new", "fresh", peer: true)
        case "replace": try f.write("edited", "kept")
        case "delete": try FileManager.default.removeItem(at: f.local.appendingPathComponent("kept"))
        default: try f.write("new", "fresh", peer: true); try f.write("edited", "kept")
        }
        #expect(try await f.apply(f.preview()).status == "synchronized")
        #expect(await f.backups.counts().0 == (kind == "create" ? 0 : 1))
        #expect(await f.backups.counts().1 == 2)
    }

    @Test("consumed and day-old previews are removed; a fresh unconsumed one is kept")
    func previewsAreRemoved() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let previews = f.paths.root.appendingPathComponent("source-sync/\(f.group.id.uuidString)/previews")
        func saved() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: previews.path).sorted() }
        try f.write("local", "from-local")
        let first = try await f.preview()
        let stale = try #require(saved().first)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: previews.appendingPathComponent(stale).path)
        let second = try await f.preview()
        // The day-old file went; only the new preview remains.
        #expect(try saved().count == 1 && saved().first != stale)
        #expect(first.previewToken != second.previewToken)
        #expect(try await f.apply(second).status == "synchronized")
        #expect(try saved().isEmpty)
    }

    @Test("a repository inside either copy refuses planning, even without locks", arguments: [false, true])
    func repositoryInsideRefuses(_ onPeer: Bool) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("ordinary", "kept", peer: !onPeer)
        let repository = (onPeer ? f.peer : f.local).appendingPathComponent("mirrors/notes.restic")
        for name in ["data", "index", "keys", "snapshots"] {
            try FileManager.default.createDirectory(at: repository.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("synthetic repository config".utf8).write(to: repository.appendingPathComponent("config"))
        await #expect(throws: SourceSyncError.self) { _ = try await f.preview() }
        try FileManager.default.removeItem(at: repository.appendingPathComponent("keys"))
        #expect(try await f.preview().previewToken != nil)
    }

    @Test("either sync folder in cloud storage refuses planning", arguments: [false, true])
    func cloudSyncFolderRefuses(_ onPeer: Bool) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let root = try SourceSyncFilesystem.resolvedDirectory((onPeer ? f.peer : f.local).path)
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncFilesystem.$reachesCloudStorage.withValue({ $0 == root || $0.hasPrefix(root + "/") }) {
                _ = try await f.preview()
            }
        }
    }

    @Test("a folder on another filesystem inside either copy refuses planning", arguments: [false, true])
    func nestedFilesystemRefusesPlanning(_ onPeer: Bool) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("archived", "archive/note", peer: onPeer)
        try f.write("ordinary", "kept", peer: !onPeer)
        let mounted = try #require(FileManager.default.attributesOfItem(atPath: (onPeer ? f.peer : f.local).appendingPathComponent("archive").path)[.systemFileNumber] as? UInt64)
        // A baseline that included a mount's contents would plan its
        // later absence (an empty mount point) as deletion elsewhere.
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncFilesystem.$device.withValue({ UInt64($0.st_ino) == mounted ? -1 : Int64(truncatingIfNeeded: $0.st_dev) }) {
                _ = try await f.preview()
            }
        }
        let preview = try await f.preview()
        #expect(preview.copies == 3 && preview.previewToken != nil)
    }

    @Test("a mount that appears after preview refuses before any reservation")
    func nestedFilesystemAfterPreview() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("archived", "archive/note")
        let preview = try await f.preview()
        let mounted = try #require(FileManager.default.attributesOfItem(atPath: f.local.appendingPathComponent("archive").path)[.systemFileNumber] as? UInt64)
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncFilesystem.$device.withValue({ UInt64($0.st_ino) == mounted ? -1 : Int64(truncatingIfNeeded: $0.st_dev) }) {
                _ = try await f.apply(preview)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: f.peer.appendingPathComponent("archive").path))
        #expect(try SourceSyncCoordinator.status(paths: f.paths, setId: f.set.id, groupId: f.group.id).operationId == nil)
        // The refusal consumed nothing: the reviewed plan is still usable.
        #expect(try await f.apply(preview).status == "synchronized")
    }

    #if os(macOS)
    @Test("a real volume mounted inside the sync folder refuses planning", .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")))
    func realNestedMountRefusesPlanning() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let image = f.base.appendingPathComponent("volume.dmg"), mountPoint = f.local.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        func hdiutil(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try hdiutil(["create", "-quiet", "-size", "4m", "-fs", "HFS+", "-volname", "RSMount", image.path]) == 0)
        #expect(try hdiutil(["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, image.path]) == 0)
        defer { _ = try? hdiutil(["detach", "-quiet", "-force", mountPoint.path]) }
        try Data("archived".utf8).write(to: mountPoint.appendingPathComponent("note"))
        do {
            _ = try await f.preview()
            Issue.record("a mounted volume inside the sync folder was planned")
        } catch let error as SourceSyncError {
            #expect(error.description.contains("separate drive or mount"))
        }
    }
    #endif

    @Test("a partly installed operation resumes after unrelated settings changes", arguments: ["installing", "installed", "agreed", "backedUp"])
    func resumeAfterSettingsChange(_ phase: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("a", "a")
        let preview = try await f.preview()
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncCoordinator.$afterDurablePhase.withValue({ at in
                if at == phase { throw SourceSyncError.transferFailed }
            }) { try await f.apply(preview) }
        }
        // Any config.json, machine.json or restic change alters the session
        // binding. A copy may already be half-installed, so it must finish.
        let result = try await f.coordinator.recover(set: f.set, group: f.group, machineId: "laptop", binding: "settings changed")
        #expect(result.status == "synchronized" && result.operationId == nil)
        #expect(try String(contentsOf: f.peer.appendingPathComponent("a"), encoding: .utf8) == "a")
        #expect(try await f.preview().copies == 0)
    }

    @Test("a change found after the journal points to recovery, never to a preview that would refuse")
    func pendingOperationNamesRecovery() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("a", "a")
        let preview = try await f.preview()
        let error = await #expect(throws: SourceSyncError.self) {
            try await SourceSyncCoordinator.$afterDurablePhase.withValue({ at in
                // An editor saves into the peer during the handoff.
                if at == "protected" { try Data("edited".utf8).write(to: f.peer.appendingPathComponent("a")) }
            }) { try await f.apply(preview) }
        }
        let message = error?.description ?? ""
        #expect(message.contains("sync recover") && !message.contains("Preview the changes again"))
        // The circle the old wording created: preview refuses while pending.
        await #expect(throws: SourceSyncError.self) { _ = try await f.preview() }
        try FileManager.default.removeItem(at: f.peer.appendingPathComponent("a"))
        _ = try? await f.coordinator.recover(set: f.set, group: f.group, machineId: "laptop", binding: "fixture")
    }

    @Test("settings changed before installation require cancelling, then a new preview", arguments: ["reserved", "protected"])
    func settingsChangeBeforeInstallation(_ phase: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("a", "a")
        let preview = try await f.preview()
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncCoordinator.$afterDurablePhase.withValue({ at in
                if at == phase { throw SourceSyncError.transferFailed }
            }) { try await f.apply(preview) }
        }
        await #expect(throws: SourceSyncError.self) {
            try await f.coordinator.recover(set: f.set, group: f.group, machineId: "laptop", binding: "settings changed")
        }
        #expect(!FileManager.default.fileExists(atPath: f.peer.appendingPathComponent("a").path))
        _ = try await f.coordinator.cancelUnstarted(set: f.set, group: f.group, machineId: "laptop")
        #expect(try await f.apply(f.preview()).status == "synchronized")
        #expect(try String(contentsOf: f.peer.appendingPathComponent("a"), encoding: .utf8) == "a")
    }

    @Test("resuming with changed settings still refuses a changed sync policy or folder")
    func resumeStillChecksThisSet() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("a", "a")
        let preview = try await f.preview()
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncCoordinator.$afterDurablePhase.withValue({ at in
                if at == "installing" { throw SourceSyncError.transferFailed }
            }) { try await f.apply(preview) }
        }
        // Retention could forget the protection snapshot mid-operation.
        var retained = f.set; retained.retention = RetentionPolicy(keepDaily: 7)
        await #expect(throws: SourceSyncError.self) {
            try await f.coordinator.recover(set: retained, group: f.group, machineId: "laptop", binding: "settings changed")
        }
        // A different folder is not the operation the journal describes.
        let elsewhere = f.base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        var moved = f.group; moved.peer.path = elsewhere.path
        var repointed = f.set; repointed.syncFolders = [moved]
        await #expect(throws: SourceSyncError.self) {
            try await f.coordinator.recover(set: repointed, group: moved, machineId: "laptop", binding: "settings changed")
        }
        #expect(!FileManager.default.fileExists(atPath: f.peer.appendingPathComponent("a").path))
        let result = try await f.coordinator.recover(set: f.set, group: f.group, machineId: "laptop", binding: "settings changed")
        #expect(result.status == "synchronized")
    }

    @Test("protection includes the displaced values from both copies in one operation")
    func simultaneousDirections() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        for peer in [false, true] { try f.write("original a", "a", peer: peer); try f.write("original b", "b", peer: peer) }
        _ = try await f.apply(f.preview())
        try f.write("new a", "a"); try f.write("new b", "b", peer: true)
        _ = try await f.apply(f.preview())
        let inventory = try #require(await f.backups.protectedInventories().last)
        #expect(inventory.items["peer/a"]?.digest == SHA256Digest.hex(Data("original a".utf8)))
        #expect(inventory.items["local/b"]?.digest == SHA256Digest.hex(Data("original b".utf8)))
        #expect(inventory.items["recovery.json"] != nil)
        for root in [f.local, f.peer] {
            #expect(try String(contentsOf: root.appendingPathComponent("a"), encoding: .utf8) == "new a")
            #expect(try String(contentsOf: root.appendingPathComponent("b"), encoding: .utf8) == "new b")
        }
    }

    @Test("real SSH helper RPC and rsync preserve quoted paths", .enabled(if: ProcessInfo.processInfo.environment["RESTIC_STATION_TEST_SSH_CONFIG"] != nil))
    func realSSHFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let configPath = try #require(environment["RESTIC_STATION_TEST_SSH_CONFIG"])
        let helperPath = try #require(environment["RESTIC_STATION_TEST_SSH_HELPER"])
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        var group = f.group
        group.peer.sshTarget = "fixture-peer"; group.peer.helperPath = helperPath
        var set = f.set; set.syncFolders = [group]
        let config = AppConfig(sets: [set])
        let coordinator = SourceSyncCoordinator(paths: f.paths, transport: SourceSyncClient(runner: SSHFixtureRunner(config: configPath)), backups: f.backups)
        let earlier = Date(timeIntervalSince1970: 981_173_106), later = Date(timeIntervalSince1970: 1_234_567_890)
        try f.write("local", "nested/from local"); try f.setModified(earlier, "nested/from local")
        try f.write("remote", "from peer", peer: true); try f.setModified(later, "from peer", peer: true)
        let preview = try await coordinator.preview(set: set, group: group, machineId: "laptop", config: config, binding: "ssh-fixture")
        let result = try await coordinator.apply(token: #require(preview.previewToken), set: set, group: group, machineId: "laptop", config: config, binding: "ssh-fixture")
        #expect(result.status == "synchronized")
        #expect(try String(contentsOf: f.peer.appendingPathComponent("nested/from local"), encoding: .utf8) == "local")
        #expect(try String(contentsOf: f.local.appendingPathComponent("from peer"), encoding: .utf8) == "remote")
        #expect(try f.modified("nested/from local", peer: true) == earlier)
        #expect(try f.modified("from peer") == later)
    }
}
