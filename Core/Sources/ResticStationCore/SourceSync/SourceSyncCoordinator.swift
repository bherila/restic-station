import Foundation

/// Paths and inventories are deliberately absent from the default report.
/// The CLI/app can request the reviewed changes separately.
public struct SourceSyncPreview: Codable, Sendable {
    public var setId: UUID
    public var groupId: UUID
    public var copies: Int
    public var removals: Int
    public var conflicts: Int
    public var backupSourceCount: Int
    public var previewToken: String?
    public var changes: [SyncChange]?
}

public struct SourceSyncStatus: Codable, Sendable {
    public var groupId: UUID
    public var status: String
    public var operationId: UUID?
    public var lastSynchronizedAt: Date?
    public var canCancel: Bool = false
    public var recovery: SourceSyncRecovery?
}

public struct SourceSyncRecovery: Codable, Sendable {
    public struct Entry: Codable, Sendable, Identifiable {
        public var path: String
        public var localCopy: String?
        public var peerCopy: String?
        public var id: String { path }
    }
    public var protectedSnapshotId: String?
    public var protectedRepositoryId: String?
    public var localDirectory: String?
    public var peerDirectory: String?
    public var entries: [Entry]
}

/// Manual, two-copy reconciliation. The caller holds the shared config and
/// revision lock while applying and supplies a binding covering the exact
/// effective configuration and executable. Journals survive helper exits;
/// endpoint reservations never expire on a timer.
public struct SourceSyncCoordinator: Sendable {
    @TaskLocal static var afterDurablePhase: (@Sendable (String) throws -> Void)?
    public let paths: AppPaths
    public let transport: any SourceSyncTransport
    public let backups: any SourceSyncBackingUp
    private let revalidate: @Sendable () throws -> Void

    public init(paths: AppPaths, transport: any SourceSyncTransport = SourceSyncClient(), backups: any SourceSyncBackingUp, revalidate: @escaping @Sendable () throws -> Void = {}) {
        self.paths = paths
        self.transport = transport
        self.backups = backups
        self.revalidate = revalidate
    }

    public func preview(
        set: BackupSet, group: SourceSyncGroup, machineId: String,
        config: AppConfig, binding: String, includePaths: Bool = false
    ) async throws -> SourceSyncPreview {
        try validate(set: set, group: group, machineId: machineId)
        let store = try SourceSyncStore(paths: paths, setId: set.id, groupId: group.id)
        let lock = try store.lock(leaseToChildren: true)
        defer { lock.release() }
        let record = try store.record()
        guard record.activeOperation == nil else {
            throw SourceSyncError.stateInvalid("An interrupted synchronization needs recovery before another preview.")
        }
        let local = try await transport.request(request(.inventory, group: group, local: true), at: .init(path: group.localPath))
        let peer = try await transport.request(request(.inventory, group: group, local: false), at: group.peer)
        if record.baseline == nil && (record.hasHistory || local.lastCompletedOperation != nil || peer.lastCompletedOperation != nil) {
            throw SourceSyncError.stateInvalid("The previous agreement is missing. Restore synchronization state before continuing.")
        }
        let plan = try SourceSyncPlanner.plan(group: group, local: local.inventory, peer: peer.inventory, baseline: record.baseline)
        let stored = StoredSyncPreview(id: UUID(), setId: set.id, plan: plan, binding: binding, createdAt: Date(), group: group)
        var token: String?
        if plan.conflicts.isEmpty {
            let issued = try PreviewTokenStore(paths: paths).issue(
                machineId: machineId, setId: set.id, destinations: [], config: config,
                patterns: ["source-sync:v1", group.id.uuidString], executableIdentity: try capabilityBinding(stored)
            )
            try store.savePreview(stored, token: issued.value)
            token = issued.value
        }
        return SourceSyncPreview(
            setId: set.id, groupId: group.id,
            copies: plan.changes.filter { $0.action == .copyToLocal || $0.action == .copyToPeer }.count,
            removals: plan.changes.filter { $0.action == .removeLocal || $0.action == .removePeer }.count,
            conflicts: plan.conflicts.count, backupSourceCount: set.sources.count,
            previewToken: token, changes: includePaths ? plan.changes : nil
        )
    }

    public func apply(
        token: String, set: BackupSet, group: SourceSyncGroup,
        machineId: String, config: AppConfig, binding: String
    ) async throws -> SourceSyncStatus {
        try validate(set: set, group: group, machineId: machineId)
        let store = try SourceSyncStore(paths: paths, setId: set.id, groupId: group.id)
        let lock = try store.lock(leaseToChildren: true)
        defer { lock.release() }
        var record = try store.record()
        guard record.activeOperation == nil else { throw SourceSyncError.busy }
        let preview = try store.preview(token: token)
        guard preview.setId == set.id, preview.group.id == group.id,
              preview.plan.groupFingerprint == (try group.bindingFingerprint),
              preview.binding == binding, preview.plan.conflicts.isEmpty,
              preview.plan.baselineGeneration == record.baseline?.generation else { throw SourceSyncError.stalePlan }
        let local = try await transport.request(request(.inventory, group: group, local: true), at: .init(path: group.localPath))
        let peer = try await transport.request(request(.inventory, group: group, local: false), at: group.peer)
        guard local.inventory == preview.plan.local, peer.inventory == preview.plan.peer else { throw SourceSyncError.stalePlan }
        let capability = try PreviewTokenStore(paths: paths).consume(token)
        guard capability.machineId == machineId, capability.setId == set.id,
              capability.patterns == ["source-sync:v1", group.id.uuidString],
              capability.configFingerprint == (try PreviewTokenStore.purgeFingerprint(config, executableIdentity: capabilityBinding(preview))) else {
            throw SourceSyncError.stalePlan
        }
        let operation = try store.operation(preview.id)
        let journal = SourceSyncJournal(preview: preview, phase: .reserved)
        try SyncDurability.write(journal, named: "journal.json", in: operation)
        record.activeOperation = preview.id
        record.status = .running
        try store.save(record)
        return try await run(journal: journal, store: store, set: set, binding: binding)
    }

    public func recover(set: BackupSet, group: SourceSyncGroup, machineId: String, binding: String) async throws -> SourceSyncStatus {
        try validate(set: set, group: group, machineId: machineId)
        let store = try SourceSyncStore(paths: paths, setId: set.id, groupId: group.id)
        let lock = try store.lock(leaseToChildren: true)
        defer { lock.release() }
        let record = try store.record()
        guard let id = record.activeOperation,
              let journal = try SyncDurability.read(SourceSyncJournal.self, named: "journal.json", in: store.operation(id)),
              journal.version == 1, journal.preview.id == id,
              journal.preview.setId == set.id, journal.preview.plan.groupId == group.id,
              journal.preview.plan.groupFingerprint == (try group.bindingFingerprint),
              journal.preview.plan.groupFingerprint == (try journal.preview.group.bindingFingerprint) else {
            throw SourceSyncError.stateInvalid("No compatible interrupted operation is available to resume.")
        }
        return try await run(journal: journal, store: store, set: set, binding: binding)
    }

    public func cancelUnstarted(set: BackupSet, group: SourceSyncGroup, machineId: String) async throws -> SourceSyncStatus {
        try validate(set: set, group: group, machineId: machineId)
        let store = try SourceSyncStore(paths: paths, setId: set.id, groupId: group.id)
        let lock = try store.lock(leaseToChildren: true)
        defer { lock.release() }
        var record = try store.record()
        guard let id = record.activeOperation,
              var journal = try SyncDurability.read(SourceSyncJournal.self, named: "journal.json", in: store.operation(id)),
              journal.version == 1, journal.preview.id == id, journal.preview.setId == set.id,
              journal.preview.plan.groupFingerprint == (try group.bindingFingerprint),
              journal.preview.plan.groupFingerprint == (try journal.preview.group.bindingFingerprint),
              journal.phase == .reserved || journal.phase == .protected || journal.phase == .cancelling else {
            throw SourceSyncError.stateInvalid("Only an operation that has never started installing files can be cancelled.")
        }
        let operation = try store.operation(id)
        journal.phase = .cancelling
        try SyncDurability.write(journal, named: "journal.json", in: operation)
        for local in [true, false] {
            var r = request(.cancel, group: group, local: local); r.operationId = id
            _ = try await transport.request(r, at: local ? .init(path: group.localPath) : group.peer)
        }
        try cleanupVerificationCopies(in: operation)
        for name in ["vault", "local", "peer"] { try SourceSyncFilesystem.removeTree(name, in: operation) }
        journal.phase = .cancelled
        try SyncDurability.write(journal, named: "journal.json", in: operation)
        // Both workers durably released the same, never-applied operation.
        // The last agreed inventory remains the baseline for a fresh plan.
        record.activeOperation = nil
        record.status = record.hasHistory ? .synchronized : .ready
        try store.save(record)
        return report(record)
    }

    private func cleanupVerificationCopies(in operation: DirectoryHandle) throws {
        // Only the backup adapter's random, operation-private restore
        // copies qualify. Keep unrelated names and all live source roots.
        for name in try SourceSyncFilesystem.entryNames(in: operation)
        where name.hasPrefix("restore-") && UUID(uuidString: String(name.dropFirst(8))) != nil {
            try SourceSyncFilesystem.removeTree(name, in: operation)
        }
    }

    public static func status(paths: AppPaths, setId: UUID, groupId: UUID, includePaths: Bool = false) throws -> SourceSyncStatus {
        let store = try SourceSyncStore(paths: paths, setId: setId, groupId: groupId)
        let lock = try store.lock()
        defer { lock.release() }
        let record = try store.record()
        var status = SourceSyncStatus(groupId: record.groupId, status: record.status.rawValue, operationId: record.activeOperation, lastSynchronizedAt: record.lastSynchronizedAt)
        if let id = record.activeOperation {
            guard let journal = try SyncDurability.read(SourceSyncJournal.self, named: "journal.json", in: store.operation(id)), journal.version == 1, journal.preview.id == id else {
                throw SourceSyncError.stateInvalid("The interrupted operation journal is missing or incompatible.")
            }
            status.canCancel = journal.phase == .reserved || journal.phase == .protected || journal.phase == .cancelling
            if includePaths {
                let local = journal.localPrepared?.recoveryPath, peer = journal.peerPrepared?.recoveryPath
                status.recovery = SourceSyncRecovery(
                    protectedSnapshotId: journal.protectedSnapshot, protectedRepositoryId: journal.protectedRepository, localDirectory: local, peerDirectory: peer,
                    entries: journal.preview.plan.changes.map { change in
                        let name = SyncEndpointService.recoveryName(for: change.path)
                        let l = change.local != nil && (change.action == .copyToLocal || change.action == .removeLocal)
                        let p = change.peer != nil && (change.action == .copyToPeer || change.action == .removePeer)
                        return .init(path: change.path, localCopy: l ? local.map { $0 + "/" + name } : nil, peerCopy: p ? peer.map { $0 + "/" + name } : nil)
                    }.filter { $0.localCopy != nil || $0.peerCopy != nil }
                )
            }
        }
        return status
    }

    private func run(journal initial: SourceSyncJournal, store: SourceSyncStore, set: BackupSet, binding: String) async throws -> SourceSyncStatus {
        var journal = initial
        guard journal.preview.binding == binding else { throw SourceSyncError.stalePlan }
        if journal.phase == .complete {
            var record = try store.record()
            record.status = .synchronized; record.activeOperation = nil
            try store.save(record)
            return report(record)
        }
        guard journal.phase != .cancelling && journal.phase != .cancelled else {
            throw SourceSyncError.stateInvalid("Finish cancelling the unstarted operation before making a new plan.")
        }
        let group = journal.preview.group, plan = journal.preview.plan
        let operation = try store.operation(journal.preview.id)
        let vault = try SyncEndpointService.child("vault", in: operation)
        let localVault = try SyncEndpointService.child("local", in: vault)
        let peerVault = try SyncEndpointService.child("peer", in: vault)
        func persist() throws {
            try SyncDurability.write(journal, named: "journal.json", in: operation)
            try Self.afterDurablePhase?(journal.phase.rawValue)
        }
        func endpointRequest(_ action: SyncEndpointRequest.Action, local: Bool) -> SyncEndpointRequest {
            var r = request(action, group: group, local: local)
            r.operationId = journal.preview.id
            r.expected = local ? plan.local : plan.peer
            r.operations = operations(plan, local: local)
            r.exportPaths = exportPaths(plan, local: local)
            r.protectedSnapshotId = journal.protectedSnapshot
            r.protectedRepositoryId = journal.protectedRepository
            r.protectedItems = (local ? plan.local : plan.peer).items
            return r
        }
        do {
            if journal.phase == .reserved {
                try revalidate()
                // A crash after a worker prepared but before its reply was
                // saved repeats the same typed operation, never a new one.
                if journal.localPrepared == nil {
                    journal.localPrepared = try await transport.request(endpointRequest(.prepare, local: true), at: .init(path: group.localPath))
                    try persist()
                }
                if journal.peerPrepared == nil {
                    journal.peerPrepared = try await transport.request(endpointRequest(.prepare, local: false), at: group.peer)
                    try persist()
                }
                guard let l = journal.localPrepared?.exportPath, let p = journal.peerPrepared?.exportPath else { throw SourceSyncError.stalePlan }
                try await transfer(exportPaths(plan, local: true), from: .init(path: l), to: .init(path: localVault.path.path), operation: operation)
                var remoteExport = group.peer; remoteExport.path = p
                try await transfer(exportPaths(plan, local: false), from: remoteExport, to: .init(path: peerVault.path.path), operation: operation)
                try verifyExport(localVault, paths: exportPaths(plan, local: true), inventory: plan.local)
                try verifyExport(peerVault, paths: exportPaths(plan, local: false), inventory: plan.peer)
                // The encrypted snapshot must remain understandable even
                // if the coordinator's local state is later lost.
                try SyncDurability.write(journal.preview, named: "recovery.json", in: vault)
                let inventory = try SourceSyncFilesystem.inventory(at: vault.path.path)
                try revalidate()
                let proof = try await backups.protect(set: set, vault: vault.path, inventory: inventory)
                guard proof.payloadFingerprint == (try inventory.fingerprint) else { throw SourceSyncError.protectionFailed }
                journal.protectedSnapshot = proof.snapshotId
                journal.protectedRepository = proof.repositoryId
                journal.phase = .protected
                try persist()
            }
            if journal.phase == .protected || journal.phase == .installing {
                try revalidate()
                guard let localIncoming = journal.localPrepared?.stagingPath,
                      let peerIncoming = journal.peerPrepared?.stagingPath else { throw SourceSyncError.stalePlan }
                let inbound = operations(plan, local: true).filter { $0.after != nil }.map(\.path)
                let outbound = operations(plan, local: false).filter { $0.after != nil }.map(\.path)
                try await transfer(inbound, from: .init(path: peerVault.path.path), to: .init(path: localIncoming), operation: operation)
                var remoteIncoming = group.peer; remoteIncoming.path = peerIncoming
                try await transfer(outbound, from: .init(path: localVault.path.path), to: remoteIncoming, operation: operation)
                try revalidate()
                if journal.phase == .protected {
                    // Durable installation intent precedes either commit.
                    // Cancellation is no longer permitted past this point.
                    journal.phase = .installing
                    try persist()
                }
                _ = try await transport.request(endpointRequest(.commit, local: true), at: .init(path: group.localPath))
                try revalidate()
                _ = try await transport.request(endpointRequest(.commit, local: false), at: group.peer)
                journal.phase = .installed
                try persist()
            }
            if journal.phase == .installed {
                if journal.localFinished == nil {
                    journal.localFinished = try await transport.request(endpointRequest(.finish, local: true), at: .init(path: group.localPath))
                    try persist()
                }
                if journal.peerFinished == nil {
                    journal.peerFinished = try await transport.request(endpointRequest(.finish, local: false), at: group.peer)
                    try persist()
                }
                guard let local = journal.localFinished?.inventory, let peer = journal.peerFinished?.inventory,
                      local.items == expectedResult(plan), local.items == peer.items else {
                    throw SourceSyncError.stateInvalid("The installed copies do not agree. Both recovery journals have been retained.")
                }
                var record = try store.record()
                record.baseline = SyncBaseline(
                    groupFingerprint: plan.groupFingerprint, localRootIdentity: local.rootIdentity, peerRootIdentity: peer.rootIdentity,
                    agreed: local.items, localEndpointGeneration: local.endpointGeneration, peerEndpointGeneration: peer.endpointGeneration
                )
                record.hasHistory = true
                record.lastSynchronizedAt = Date()
                record.status = .backupNeedsAttention
                try store.save(record)
                // Preserve the completed common inventory and endpoint
                // epochs in the final encrypted backup, outside host-local
                // application state. Losing local metadata still refuses
                // automatic re-enrollment; this supplies recovery evidence.
                try SyncDurability.write(record.baseline, named: "agreement.json", in: vault)
                journal.phase = .agreed
                try persist()
            }
            if journal.phase == .agreed {
                try await backups.backup(set: set, retaining: vault.path)
                journal.phase = .backedUp
                try persist()
            }
            if journal.phase == .backedUp {
                _ = try await transport.request(endpointRequest(.cleanup, local: true), at: .init(path: group.localPath))
                _ = try await transport.request(endpointRequest(.cleanup, local: false), at: group.peer)
                try SourceSyncFilesystem.removeTree("vault", in: operation)
                try cleanupVerificationCopies(in: operation)
                journal.phase = .complete
                try persist()
            }
            guard journal.phase == .complete else {
                throw SourceSyncError.stateInvalid("This operation is being cancelled. Finish cancelling it before making a new plan.")
            }
            var record = try store.record()
            record.status = .synchronized
            record.activeOperation = nil
            try store.save(record)
            return report(record)
        } catch {
            var record = try store.record()
            record.status = journal.phase == .agreed || journal.phase == .complete ? .backupNeedsAttention : .needsRecovery
            try store.save(record)
            throw error
        }
    }

    private func validate(set: BackupSet, group: SourceSyncGroup, machineId: String) throws {
        guard group.coordinatorMachineId == machineId, set.syncFolders.contains(group),
              set.retention == nil, set.purgeExcludes.isEmpty else {
            throw SourceSyncError.invalidConfiguration("Use the coordinating computer and a backup set without retention or purge exclusions for this initial sync version.")
        }
        try group.validate(backupSources: set.sources)
        let root = try SourceSyncFilesystem.physicalDirectory(group.localPath)
        // Lexical backup coverage alone cannot prove coverage through an
        // alias. Fail closed if any selected source cannot be inspected.
        let sources = try set.sources.filter { SourceSyncGroup.contains($0, group.localPath) }.map(SourceSyncFilesystem.physicalDirectory)
        guard sources.contains(where: { SourceSyncGroup.contains($0, root) }) else { throw SourceSyncError.stalePlan }
        if group.peer.sshTarget == nil {
            let peer = try SourceSyncFilesystem.physicalDirectory(group.peer.path)
            guard !SourceSyncGroup.contains(root, peer), !SourceSyncGroup.contains(peer, root) else { throw SourceSyncError.stalePlan }
        }
        let state = try SourceSyncFilesystem.physicalDirectory(paths.root.path)
        guard !SourceSyncGroup.contains(root, state), !SourceSyncGroup.contains(state, root) else { throw SourceSyncError.stalePlan }
        for destination in set.destinations where destination.kind == .localPath {
            let repo = try SourceSyncFilesystem.physicalDirectory(destination.repoURL)
            guard !SourceSyncGroup.contains(root, repo), !SourceSyncGroup.contains(repo, root) else { throw SourceSyncError.stalePlan }
        }
    }

    private func transfer(_ paths: [String], from source: SyncEndpoint, to destination: SyncEndpoint, operation: DirectoryHandle) async throws {
        try await transport.copy(paths: paths, from: source, to: destination, listFile: operation.path.appendingPathComponent("files-\(UUID().uuidString)"))
    }

    private func verifyExport(_ directory: DirectoryHandle, paths: [String], inventory: SyncInventory) throws {
        let actual = try SourceSyncFilesystem.inventory(at: directory.path.path)
        guard actual.items == inventory.items.filter({ paths.contains($0.key) }) else { throw SourceSyncError.stalePlan }
    }

    private func exportPaths(_ plan: SourceSyncPlan, local: Bool) -> [String] {
        let inventory = local ? plan.local : plan.peer
        var result: Set<String> = []
        for change in plan.changes where inventory.items[change.path] != nil {
            var components = change.path.split(separator: "/").map(String.init)
            while !components.isEmpty { result.insert(components.joined(separator: "/")); components.removeLast() }
        }
        return result.sorted()
    }

    private func operations(_ plan: SourceSyncPlan, local: Bool) -> [SyncEndpointOperation] {
        plan.changes.compactMap { change -> SyncEndpointOperation? in
            switch (local, change.action) {
            case (true, .copyToLocal), (true, .removeLocal): return .init(path: change.path, before: change.local, after: change.peer)
            case (false, .copyToPeer), (false, .removePeer): return .init(path: change.path, before: change.peer, after: change.local)
            default: return nil
            }
        }.sorted {
            if ($0.after == nil) != ($1.after == nil) { return $0.after != nil }
            let a = $0.path.split(separator: "/").count, b = $1.path.split(separator: "/").count
            if a != b { return $0.after == nil ? a > b : a < b }
            return $0.path < $1.path
        }
    }

    private func expectedResult(_ plan: SourceSyncPlan) -> [String: SyncItem] {
        var items = plan.local.items
        for change in operations(plan, local: true) { items[change.path] = change.after }
        return items
    }

    private func request(_ action: SyncEndpointRequest.Action, group: SourceSyncGroup, local: Bool) -> SyncEndpointRequest {
        .init(action: action, group: group, root: local ? group.localPath : group.peer.path)
    }

    private func capabilityBinding(_ preview: StoredSyncPreview) throws -> String {
        "source-sync:v1:" + SHA256Digest.hex(try ConfigStore.makeEncoder().encode(preview))
    }

    private func report(_ record: SourceSyncGroupRecord) -> SourceSyncStatus {
        SourceSyncStatus(groupId: record.groupId, status: record.status.rawValue, operationId: record.activeOperation, lastSynchronizedAt: record.lastSynchronizedAt)
    }
}
