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
            if args.first?.hasSuffix("/rsync") == true, let e = args.firstIndex(of: "-e") {
                args[e + 1] += " -F " + ShellQuote.singleQuote(config)
            }
            return try await DefaultProcessRunner().run(args, env: env, stdin: stdin, currentDirectory: currentDirectory, onStdoutLine: onStdoutLine, onStderrLine: onStderrLine, timeout: timeout)
        }
    }
    final class CopyLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(destination: String, options: SyncCopyOptions)] = []
        func add(_ destination: String, _ options: SyncCopyOptions) { lock.lock(); entries.append((destination, options)); lock.unlock() }
        var all: [(destination: String, options: SyncCopyOptions)] { lock.lock(); defer { lock.unlock() }; return entries }
    }
    struct LocalTransport: SourceSyncTransport {
        var transferRefusal: SourceSyncError?
        /// Refuses only a prepare reply's tools (prepare replies name an export).
        var preparedRefusal: SourceSyncError?
        /// Stands in for a current helper's report on inventory and prepare.
        var reportedTools: SyncTransferTools?
        var copies: CopyLog?
        func request(_ request: SyncEndpointRequest, at endpoint: SyncEndpoint) async throws -> SyncEndpointReply {
            var reply = try SyncEndpointService.handle(request)
            if request.action == .inventory || request.action == .prepare { reply.transfer = reportedTools }
            return reply
        }
        func checkTransfer(peer: SyncEndpointReply, at endpoint: SyncEndpoint) async throws {
            if let transferRefusal { throw transferRefusal }
            if let preparedRefusal, peer.exportPath != nil { throw preparedRefusal }
        }
        func copy(paths: [String], from source: SyncEndpoint, to destination: SyncEndpoint, listFile: URL, options: SyncCopyOptions) async throws {
            copies?.add(destination.path, options)
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

    final class HashLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        func take() -> [String] { lock.lock(); defer { paths = []; lock.unlock() }; return paths.sorted() }
    }

    @Test("an unchanged live file is not read again; any edit, even keeping size and mtime, is")
    func hashCacheReuse() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let log = HashLog()
        try f.write("aaaa", "same-size"); try f.write("other", "nested/other")
        let then = Date(timeIntervalSince1970: 1_600_000_000)
        try f.setModified(then, "same-size")
        try await SyncHashCache.$settleSeconds.withValue(-3600) {
            try await SourceSyncFilesystem.$hashed.withValue({ log.add($0) }) {
                _ = try await f.preview()
                #expect(log.take() == ["nested/other", "same-size"])
                let cache = AppPaths.sourceSyncControlDirectory(for: URL(fileURLWithPath: try SourceSyncFilesystem.physicalDirectory(f.local.path)))
                    .appendingPathComponent("hashes.json").path
                func cacheInode() -> UInt64 { var info = stat(); return stat(cache, &info) == 0 ? UInt64(info.st_ino) : 0 }
                let written = cacheInode()
                _ = try await f.preview()
                #expect(log.take() == [])
                // Nothing changed, so the cache file was not replaced.
                #expect(written != 0 && cacheInode() == written)
                // Same size, modification time set back: only ctime moved.
                try f.write("bbbb", "same-size"); try f.setModified(then, "same-size")
                let preview = try await f.preview(includePaths: true)
                #expect(log.take() == ["same-size"])
                let change = try #require(preview.changes?.first { $0.path == "same-size" })
                #expect(change.local?.digest == SHA256Digest.hex(Data("bbbb".utf8)))
                // Proof inventories never use the cache.
                _ = try SourceSyncFilesystem.inventory(at: f.local.path)
                #expect(log.take() == ["nested/other", "same-size"])
            }
        }
    }

    @Test("files changed within the settle window, and an unreadable cache, are hashed again")
    func hashCacheFallsBack() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let log = HashLog()
        try f.write("fresh", "note")
        try await SourceSyncFilesystem.$hashed.withValue({ log.add($0) }) {
            // Within the settle window, so not recorded. The window is
            // widened rather than relying on this test running within the
            // default two seconds of the write.
            try await SyncHashCache.$settleSeconds.withValue(3600) {
                _ = try await f.preview(); _ = log.take()
                _ = try await f.preview()
                #expect(log.take() == ["note"])
            }
            try await SyncHashCache.$settleSeconds.withValue(-3600) {
                _ = try await f.preview(); _ = log.take()
                let control = AppPaths.sourceSyncControlDirectory(for: URL(fileURLWithPath: try SourceSyncFilesystem.physicalDirectory(f.local.path)))
                try Data("not json".utf8).write(to: control.appendingPathComponent("hashes.json"))
                _ = try await f.preview()
                #expect(log.take() == ["note"])
            }
        }
    }

    @Test("a cache forged to hide a real local edit cannot let the peer's version replace it")
    func poisonedCacheFailsClosed() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("original", "kept")
        try await SyncHashCache.$settleSeconds.withValue(-3600) {
            _ = try await f.apply(f.preview())
            // Same size as the original, so a forged digest makes the item
            // identical to the agreed one.
            try f.write("tampered", "kept")
            _ = try await f.preview()   // records the edit's real stamp and digest
            // Forge the entry: keep the edit's real stamp, claim the old digest.
            let control = AppPaths.sourceSyncControlDirectory(for: URL(fileURLWithPath: try SourceSyncFilesystem.physicalDirectory(f.local.path)))
            let url = control.appendingPathComponent("hashes.json")
            var cache = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var entries = try #require(cache["entries"] as? [String: Any])
            var entry = try #require(entries["kept"] as? [String: Any])
            entry["digest"] = SHA256Digest.hex(Data("original".utf8))
            entries["kept"] = entry; cache["entries"] = entries
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: JSONSerialization.data(withJSONObject: cache)); try handle.close()
            try f.write("peer edit", "kept", peer: true)
            // The forged digest makes the local copy look unchanged, so the
            // plan would replace the real local edit with the peer's.
            let preview = try await f.preview(includePaths: true)
            #expect(preview.changes?.first { $0.path == "kept" }?.action == .copyToLocal)
            await #expect(throws: SourceSyncError.self) { try await f.apply(preview) }
        }
        #expect(try String(contentsOf: f.local.appendingPathComponent("kept"), encoding: .utf8) == "tampered")
        #expect(try String(contentsOf: f.peer.appendingPathComponent("kept"), encoding: .utf8) == "peer edit")
    }

    @Test("an interrupted create-only sync with no protection receipt resumes from protected")
    func unprotectedResume() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("a", "a")
        let preview = try await f.preview()
        await #expect(throws: SourceSyncError.self) {
            try await SourceSyncCoordinator.$afterDurablePhase.withValue({ at in
                if at == "protected" { throw SourceSyncError.transferFailed }
            }) { try await f.apply(preview) }
        }
        let resumed = try await f.coordinator.recover(set: f.set, group: f.group, machineId: "laptop", binding: "fixture")
        #expect(resumed.status == "synchronized")
        #expect(try String(contentsOf: f.peer.appendingPathComponent("a"), encoding: .utf8) == "a")
        #expect(await f.backups.counts().0 == 0)
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

    @Test("a computer that cannot transfer refuses at preview and at apply, before anything is reserved or backed up")
    func transferPreflight() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("local", "from-local")
        let missing = SyncTransferTools.missing(on: "the other computer", platform: .linux)
        let refusing = SourceSyncCoordinator(paths: f.paths, transport: LocalTransport(transferRefusal: missing), backups: f.backups)
        await #expect(throws: missing) {
            _ = try await refusing.preview(set: f.set, group: f.group, machineId: "laptop", config: f.config, binding: "fixture")
        }
        let preview = try await f.preview()
        await #expect(throws: missing) {
            _ = try await refusing.apply(token: #require(preview.previewToken), set: f.set, group: f.group, machineId: "laptop", config: f.config, binding: "fixture")
        }
        let store = try SourceSyncStore(paths: f.paths, setId: f.set.id, groupId: f.group.id)
        #expect(try store.record().activeOperation == nil)
        #expect(await f.backups.counts() == (0, 0))
        // Once rsync is installed, the same reviewed plan still applies.
        #expect(try await f.apply(preview).status == "synchronized")
    }

    @Test("the rsync a prepare reply names is checked before any transfer or protection, and the operation stays cancellable")
    func preparedTransferChecked() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try f.write("local", "note"); _ = try await f.apply(f.preview())
        try f.write("edited", "note")
        let missing = SyncTransferTools.missing(on: "the other computer", platform: .macOS)
        let refusing = SourceSyncCoordinator(paths: f.paths, transport: LocalTransport(preparedRefusal: missing), backups: f.backups)
        let preview = try await refusing.preview(set: f.set, group: f.group, machineId: "laptop", config: f.config, binding: "fixture")
        let error = await #expect(throws: SourceSyncError.self) {
            _ = try await refusing.apply(token: #require(preview.previewToken), set: f.set, group: f.group, machineId: "laptop", config: f.config, binding: "fixture")
        }
        guard case .rsyncNotFound(let message) = error else { Issue.record("expected rsyncNotFound, got \(String(describing: error))"); return }
        #expect(message.contains("brew install rsync") && message.contains("sync recover --cancel-unstarted"))
        #expect(await f.backups.counts().0 == 0)
        #expect(try String(contentsOf: f.peer.appendingPathComponent("note"), encoding: .utf8) == "local")
        _ = try await f.coordinator.cancelUnstarted(set: f.set, group: f.group, machineId: "laptop")
        #expect(try await f.apply(f.preview()).status == "synchronized")
        #expect(try String(contentsOf: f.peer.appendingPathComponent("note"), encoding: .utf8) == "edited")
    }

    @Test("only a peer that reports its tools gets compression, its own rsync and a delta basis for what it receives", arguments: [false, true])
    func copyOptionsFollowPeerReport(reported: Bool) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let log = CopyLog()
        let tools = SyncTransferTools(platform: .linux, rsync: .init(path: "/usr/local/bin/rsync", protocolVersion: 32))
        let coordinator = SourceSyncCoordinator(paths: f.paths, transport: LocalTransport(reportedTools: reported ? tools : nil, copies: log), backups: f.backups)
        func sync() async throws {
            let preview = try await coordinator.preview(set: f.set, group: f.group, machineId: "laptop", config: f.config, binding: "fixture")
            _ = try await coordinator.apply(token: #require(preview.previewToken), set: f.set, group: f.group, machineId: "laptop", config: f.config, binding: "fixture")
        }
        try f.write("first", "note"); try await sync()
        let firstCount = log.all.count
        try f.write("second", "note"); try await sync()
        let replacement = log.all.dropFirst(firstCount)
        #expect(try String(contentsOf: f.peer.appendingPathComponent("note"), encoding: .utf8) == "second")
        // Exports to the vault: local, then the peer's; installs: inbound, then outbound.
        let options = replacement.map(\.options)
        #expect(options.count == 4)
        let peer = reported ? SyncCopyOptions(remoteRsync: "/usr/local/bin/rsync", compress: true) : SyncCopyOptions()
        let outbound = reported ? SyncCopyOptions(basis: f.group.peer.path, remoteRsync: "/usr/local/bin/rsync", compress: true) : SyncCopyOptions()
        #expect(options == [SyncCopyOptions(), peer, SyncCopyOptions(), outbound])
    }

    @Test("the SSH endpoint reports its rsync on the replies that start a preview or an operation")
    func endpointReportsTransfer() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let fake = FakeProcessRunner(script: [SourceSyncTransportTests.version("/usr/local/bin/rsync", "rsync  version 3.4.1  protocol version 32")])
        let reply = try await SyncRsync.$searched.withValue(["/usr/local/bin/rsync"]) {
            try await SyncEndpointService.serve(.init(action: .inventory, group: f.group, root: f.peer.path), runner: fake)
        }
        #expect(reply.transfer == SyncTransferTools(platform: SyncTransferTools.thisPlatform, rsync: .init(path: "/usr/local/bin/rsync", protocolVersion: 32)))
        let inspected = try await SyncEndpointService.serve(.init(action: .inspect, group: f.group, root: f.peer.path), runner: FakeProcessRunner())
        #expect(inspected.transfer == nil)
        // A newer helper's platform reads as other, not as an unreadable reply.
        let future = try ConfigStore.makeDecoder().decode(SyncTransferTools.self, from: Data(#"{"platform":"freebsd","rsync":null}"#.utf8))
        #expect(future == SyncTransferTools(platform: .other, rsync: nil))
        // Older coordinators ignore the field; older helpers omit it.
        let decoded = try ConfigStore.makeDecoder().decode(SyncEndpointReply.self, from: ConfigStore.makeEncoder().encode(SyncEndpointReply(inventory: reply.inventory)))
        #expect(decoded.transfer == nil)
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
        // The peer's helper reports its own rsync, which the transfers run.
        let inventory = try await SourceSyncClient(runner: SSHFixtureRunner(config: configPath)).request(.init(action: .inventory, group: group, root: group.peer.path), at: group.peer)
        #expect(inventory.transfer?.rsync != nil)
        // Replacements in both directions; the other computer receives with
        // its live folder as the delta basis, through a quoted path
        // ("peer's copy").
        let large = String(repeating: "line of shared text\n", count: 20_000)
        try f.write(large + "local edit", "nested/from local"); try f.write(large + "peer edit", "from peer", peer: true)
        let edits = try await coordinator.preview(set: set, group: group, machineId: "laptop", config: config, binding: "ssh-fixture")
        #expect(edits.copies == 2 && edits.conflicts == 0)
        #expect(try await coordinator.apply(token: #require(edits.previewToken), set: set, group: group, machineId: "laptop", config: config, binding: "ssh-fixture").status == "synchronized")
        #expect(try String(contentsOf: f.peer.appendingPathComponent("nested/from local"), encoding: .utf8) == large + "local edit")
        #expect(try String(contentsOf: f.local.appendingPathComponent("from peer"), encoding: .utf8) == large + "peer edit")
    }
}
