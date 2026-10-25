import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Endpoint operations run locally or through the helper's private SSH
/// protocol. A durable reservation spans subprocess boundaries; a short
/// flock serializes each read/modify/write of that reservation. No clock
/// expiry can release a partially applied operation to another writer.
public enum SyncEndpointService {
    @TaskLocal static var beforeInstall: (@Sendable (String) throws -> Void)?
    public static func handle(_ request: SyncEndpointRequest) throws -> SyncEndpointReply {
        guard request.version == 1, MachineIdentity.isValid(request.coordinatorMachineId),
              SourceSyncGroup.isAbsoluteCanonical(request.root) else {
            throw SourceSyncError.invalidConfiguration("The source-sync endpoint protocol or root is not supported.")
        }
        let applicationState = AppPaths.default().root.path
        guard !SourceSyncGroup.contains(request.root, applicationState),
              !SourceSyncGroup.contains(applicationState, request.root) else {
            throw SourceSyncError.unsafeRoot("Restic Station's own configuration and control state cannot be a live sync folder.")
        }
        let physicalRoot = try SourceSyncFilesystem.physicalDirectory(request.root)
        let physicalState = URL(fileURLWithPath: applicationState).resolvingSymlinksInPath().path
        guard !SourceSyncGroup.contains(physicalRoot, physicalState), !SourceSyncGroup.contains(physicalState, physicalRoot) else {
            throw SourceSyncError.unsafeRoot("Restic Station's control state cannot be a live sync folder.")
        }
        let root = try SourceSyncFilesystem.openRoot(physicalRoot)
        let rootIdentity = try SourceSyncFilesystem.rootIdentity(root)
        let parent = try SourceSyncFilesystem.openRoot(root.path.deletingLastPathComponent().path)
        let controlURL = AppPaths.sourceSyncControlDirectory(for: root.path)
        let controlName = controlURL.lastPathComponent
        let created = controlName.withCString { mkdirat(parent.descriptor, $0, 0o700) } == 0
        guard created || errno == EEXIST else { throw SourceSyncFilesystem.changed() }
        let control = try SourceSyncFilesystem.openDirectory(controlName, in: parent)
        guard control.identity?.deviceID == root.identity?.deviceID else {
            throw SourceSyncError.unsafeRoot("Choose a folder inside the volume so recovery can use atomic moves.")
        }
        guard fchmod(control.descriptor, 0o700) == 0, fsync(parent.descriptor) == 0 else {
            throw SourceSyncError.stateInvalid("The endpoint control directory could not be secured durably.")
        }
        let lock = FileLock(name: "endpoint.lock", in: control)
        switch lock.acquire() {
        case .acquired: break
        case .busy: throw SourceSyncError.busy
        case .failed: throw SourceSyncError.stateInvalid("The endpoint lock is unusable.")
        }
        defer { lock.release() }

        var record: SyncRootRecord
        if let existing = try SyncDurability.read(SyncRootRecord.self, named: "root.json", in: control) {
            record = existing
        } else {
            guard created else {
                throw SourceSyncError.stateInvalid("Endpoint state is missing. Inspect recovery before re-enrolling this folder.")
            }
            record = SyncRootRecord(groupId: request.groupId, coordinatorMachineId: request.coordinatorMachineId,
                                    rootIdentity: rootIdentity, generation: UUID())
            try SyncDurability.write(record, named: "root.json", in: control)
        }
        guard record.version == 1, record.groupId == request.groupId,
              record.coordinatorMachineId == request.coordinatorMachineId,
              record.rootIdentity == rootIdentity else {
            throw SourceSyncError.stateInvalid("This folder's identity or coordinating set changed. Reconciliation is required.")
        }

        func inventory() throws -> SyncInventory {
            var result = try SourceSyncFilesystem.inventory(at: root.path.path)
            guard result.rootIdentity == rootIdentity else { throw SourceSyncError.stalePlan }
            result.endpointGeneration = record.generation
            return result
        }

        if request.action == .inventory || request.action == .inspect {
            if request.action == .inventory, record.activeOperation != nil {
                throw SourceSyncError.stateInvalid("This copy has an interrupted synchronization. Recover that operation first.")
            }
            var reply = SyncEndpointReply(inventory: try inventory(), operationId: record.activeOperation)
            reply.lastCompletedOperation = record.lastCompletedOperation
            return reply
        }
        guard let operationId = request.operationId else {
            throw SourceSyncError.invalidConfiguration("The endpoint request has no operation identity.")
        }
        if let active = record.activeOperation, active != operationId { throw SourceSyncError.busy }

        let operation = try child(operationId.uuidString, in: control)
        let staging = try child("incoming", in: operation)
        let recovery = try child("recovery", in: operation)
        let exported = try child("exported", in: operation)
        var journal = try SyncDurability.read(SyncEndpointJournal.self, named: "journal.json", in: operation)
        if let current = journal {
            guard current.version == 1, current.operationId == operationId else {
                throw SourceSyncError.stateInvalid("The endpoint journal is incompatible with this helper or operation.")
            }
        }

        switch request.action {
        case .inventory, .inspect:
            throw SourceSyncError.stateInvalid("Unexpected endpoint operation.")
        case .prepare:
            guard let expected = request.expected else { throw SourceSyncError.stalePlan }
            if journal == nil {
                guard record.activeOperation == nil, expected.endpointGeneration == record.generation,
                      try inventory() == expected else { throw SourceSyncError.stalePlan }
                journal = SyncEndpointJournal(operationId: operationId, expected: expected, phase: .prepared, operations: request.operations, steps: [:])
                // Intent becomes durable before the reservation. If the
                // second write fails, recovery finds this exact journal.
                try SyncDurability.write(journal!, named: "journal.json", in: operation)
                record.activeOperation = operationId
                try SyncDurability.write(record, named: "root.json", in: control)
            } else {
                guard journal?.operationId == operationId, journal?.expected == expected,
                      journal?.operations == request.operations,
                      journal?.phase == .prepared else {
                    throw SourceSyncError.stalePlan
                }
                if record.activeOperation == nil {
                    guard expected.endpointGeneration == record.generation,
                          try inventory() == expected else { throw SourceSyncError.stalePlan }
                    record.activeOperation = operationId
                    try SyncDurability.write(record, named: "root.json", in: control)
                }
                guard record.activeOperation == operationId else { throw SourceSyncError.stalePlan }
            }
            for path in request.exportPaths.sorted() {
                guard SourceSyncPlanner.isRelativePath(path), let item = expected.items[path] else { throw SourceSyncError.stalePlan }
                try SourceSyncFilesystem.exportItem(path, expected: item, from: root, to: exported)
            }
        case .commit:
            guard var current = journal, record.activeOperation == operationId,
                  current.phase == .prepared || current.phase == .applying else { throw SourceSyncError.stalePlan }
            if current.phase == .prepared {
                guard try inventory() == current.expected else { throw SourceSyncError.stalePlan }
                guard current.operations == request.operations else { throw SourceSyncError.stalePlan }
                try validateProtection(request, expected: current.expected)
                for change in current.operations {
                    if let after = change.after, after.kind != .directory {
                        let (parent, name) = try SourceSyncFilesystem.parent(of: change.path, in: staging)
                        guard try SourceSyncFilesystem.item(named: name, in: parent, relative: change.path, synchronize: true) == after else {
                            throw SourceSyncError.stalePlan
                        }
                    }
                }
                current.phase = .applying
                current.protectedSnapshotId = request.protectedSnapshotId
                current.protectedRepositoryId = request.protectedRepositoryId
                try SyncDurability.write(current, named: "journal.json", in: operation)
            } else {
                guard current.operations == request.operations,
                      current.protectedSnapshotId == request.protectedSnapshotId,
                      current.protectedRepositoryId == request.protectedRepositoryId else { throw SourceSyncError.stalePlan }
            }
            for change in current.operations {
                try apply(change, request: request, journal: &current, root: root,
                          staging: staging, recovery: recovery, operation: operation)
            }
            journal = current
        case .finish:
            guard var current = journal else { throw SourceSyncError.stalePlan }
            if record.lastCompletedOperation != operationId {
                guard record.activeOperation == operationId,
                      current.phase == .applying || current.phase == .finished,
                      current.operations.allSatisfy({ current.steps[$0.path] == .installed }) else {
                    throw SourceSyncError.stateInvalid("The endpoint still has incomplete work.")
                }
                current.phase = .finished
                try SyncDurability.write(current, named: "journal.json", in: operation)
                record.activeOperation = nil
                record.lastCompletedOperation = operationId
                record.generation = UUID()
                try SyncDurability.write(record, named: "root.json", in: control)
            }
            journal = current
        case .cancel:
            // The coordinator can cancel only a journal that has never
            // entered commit. No live entries have been displaced here.
            if var current = journal {
                guard current.phase == .prepared || current.phase == .cancelled else {
                    throw SourceSyncError.stateInvalid("This operation has started changing files and must be resumed rather than cancelled.")
                }
                current.phase = .cancelled
                try SyncDurability.write(current, named: "journal.json", in: operation)
                journal = current
            }
            for name in ["incoming", "exported", "recovery"] { try SourceSyncFilesystem.removeTree(name, in: operation) }
            if record.activeOperation == operationId {
                record.activeOperation = nil
                try SyncDurability.write(record, named: "root.json", in: control)
            }
        case .cleanup:
            guard var current = journal, record.lastCompletedOperation == operationId,
                  current.phase == .finished || current.phase == .cleaned else { throw SourceSyncError.stalePlan }
            // Check remaining captures on every retry, including a crash
            // after cleanup authority was published but before deletion.
            for change in current.operations {
                let name = recoveryName(for: change.path)
                let captured = try SourceSyncFilesystem.item(named: name, in: recovery, relative: change.path)
                if let captured, captured != change.before { throw SourceSyncError.stateInvalid("A captured version changed after installation. Recovery storage has been retained.") }
                if captured?.kind == .directory {
                    let directory = try SourceSyncFilesystem.openDirectory(name, in: recovery)
                    guard try SourceSyncFilesystem.inventory(at: directory.path.path).items.isEmpty else {
                        throw SourceSyncError.stateInvalid("A captured directory has new entries. Recovery storage has been retained.")
                    }
                }
            }
            if current.phase != .cleaned {
                // Publish cleanup authority before removing any protected
                // entry; a crash can resume partially completed cleanup.
                current.phase = .cleaned
                try SyncDurability.write(current, named: "journal.json", in: operation)
            }
            for name in ["incoming", "exported", "recovery"] { try SourceSyncFilesystem.removeTree(name, in: operation) }
            journal = current
        }
        var reply = SyncEndpointReply(inventory: try inventory(), stagingPath: staging.path.path,
                                 recoveryPath: recovery.path.path, operationId: operationId,
                                 completedPaths: journal?.steps.filter { $0.value == .installed }.map(\.key).sorted() ?? [])
        reply.exportPath = exported.path.path
        reply.lastCompletedOperation = record.lastCompletedOperation
        return reply
    }

    static func child(_ name: String, in parent: DirectoryHandle) throws -> DirectoryHandle {
        let result = name.withCString { mkdirat(parent.descriptor, $0, 0o700) }
        guard result == 0 || errno == EEXIST else { throw SourceSyncFilesystem.changed() }
        let child = try SourceSyncFilesystem.openDirectory(name, in: parent)
        guard fchmod(child.descriptor, 0o700) == 0, fsync(parent.descriptor) == 0 else {
            throw SourceSyncError.stateInvalid("Recovery storage could not be made private and durable.")
        }
        return child
    }

    private static func validateProtection(_ request: SyncEndpointRequest, expected: SyncInventory) throws {
        var paths: Set<String> = []
        for change in request.operations {
            guard SourceSyncPlanner.isRelativePath(change.path), paths.insert(change.path).inserted,
                  expected.items[change.path] == change.before else { throw SourceSyncError.stalePlan }
            if let after = change.after {
                guard after.mode & ~UInt16(0o777) == 0, after.mode & 0o022 == 0 else { throw SourceSyncError.stalePlan }
            }
            if let before = change.before {
                guard request.protectedItems[change.path] == before,
                      let snapshot = request.protectedSnapshotId, snapshot.count == 64,
                      snapshot.allSatisfy({ $0.isHexDigit }),
                      let repository = request.protectedRepositoryId, repository.count == 64,
                      repository.allSatisfy({ $0.isHexDigit }) else { throw SourceSyncError.protectionFailed }
            }
        }
    }

    private static func apply(
        _ change: SyncEndpointOperation, request: SyncEndpointRequest,
        journal: inout SyncEndpointJournal, root: DirectoryHandle,
        staging: DirectoryHandle, recovery: DirectoryHandle, operation: DirectoryHandle
    ) throws {
        let (targetParent, targetName) = try SourceSyncFilesystem.parent(of: change.path, in: root)
        let recoveryParent = recovery
        let recoveryName = self.recoveryName(for: change.path)
        let stage = journal.steps[change.path] ?? .pending
        if stage == .installed {
            guard try SourceSyncFilesystem.item(named: targetName, in: targetParent, relative: change.path) == change.after else {
                throw SourceSyncError.stateInvalid("An installed entry changed before recovery completed. Both versions are retained.")
            }
            return
        }
        if stage == .pending {
            // Publish intent before displacing an inode. Recovery can tell
            // whether a crash happened before or after the exclusive move.
            journal.steps[change.path] = .pending
            try SyncDurability.write(journal, named: "journal.json", in: operation)
            let captured = try SourceSyncFilesystem.item(named: recoveryName, in: recoveryParent, relative: change.path)
            if change.before != nil && captured == nil {
                try SyncDurability.moveExclusive(targetName, from: targetParent, to: recoveryParent, as: recoveryName)
            }
            let actual = try SourceSyncFilesystem.item(named: recoveryName, in: recoveryParent, relative: change.path)
            guard actual == change.before else {
                // Never overwrite a concurrently recreated live pathname.
                if actual != nil {
                    do { try SyncDurability.moveExclusive(recoveryName, from: recoveryParent, to: targetParent, as: targetName) }
                    catch { throw SourceSyncError.stateInvalid("An unexpected version is retained in recovery storage. Recover this operation before continuing.") }
                }
                throw SourceSyncError.stateInvalid("The displaced version changed. It was restored where possible; recover this operation before continuing.")
            }
            if actual?.kind == .directory {
                let capturedDirectory = try SourceSyncFilesystem.openDirectory(recoveryName, in: recoveryParent)
                let entries = try SourceSyncFilesystem.inventory(at: capturedDirectory.path.path)
                guard entries.items.isEmpty else {
                    do { try SyncDurability.moveExclusive(recoveryName, from: recoveryParent, to: targetParent, as: targetName) }
                    catch { throw SourceSyncError.stateInvalid("An unexpected directory is retained in recovery storage. Recover this operation before continuing.") }
                    throw SourceSyncError.stateInvalid("The directory changed. Recover this operation before continuing.")
                }
            }
            journal.steps[change.path] = .captured
            try SyncDurability.write(journal, named: "journal.json", in: operation)
        }
        if let after = change.after {
            try beforeInstall?(change.path)
            if after.kind == .directory {
                // Install only an empty directory here. Moving an incoming
                // directory wholesale would install its descendants before
                // their own verification and durable intents.
                let candidate = "directory-" + SHA256Digest.hex(Data(change.path.utf8))
                let candidateDirectory = try SourceSyncFilesystem.createDirectory(candidate, in: operation, mode: after.mode)
                guard try SourceSyncFilesystem.inventory(at: candidateDirectory.path.path).items.isEmpty else { throw SourceSyncError.stalePlan }
                let existing = try SourceSyncFilesystem.item(named: targetName, in: targetParent, relative: change.path)
                if existing == nil {
                    try SyncDurability.moveExclusive(candidate, from: operation, to: targetParent, as: targetName)
                } else if existing != after {
                    throw SourceSyncError.stalePlan
                }
                journal.steps[change.path] = .installed
                try SyncDurability.write(journal, named: "journal.json", in: operation)
                return
            }
            let (payloadParent, payloadName) = try SourceSyncFilesystem.parent(of: change.path, in: staging, create: true)
            let staged = try SourceSyncFilesystem.item(named: payloadName, in: payloadParent, relative: change.path)
            let installed = try SourceSyncFilesystem.item(named: targetName, in: targetParent, relative: change.path)
            if installed == after {
                // The original was durably captured before installation.
                // Recovery may replenish staging after a lost receipt; an
                // exact live value already satisfies this operation.
                guard staged == nil || staged == after else { throw SourceSyncError.stalePlan }
            } else {
                guard staged == after else { throw SourceSyncError.stalePlan }
                try SyncDurability.moveExclusive(payloadName, from: payloadParent, to: targetParent, as: targetName)
            }
        } else {
            guard try SourceSyncFilesystem.item(named: targetName, in: targetParent, relative: change.path) == nil else {
                throw SourceSyncError.stalePlan
            }
        }
        journal.steps[change.path] = .installed
        try SyncDurability.write(journal, named: "journal.json", in: operation)
    }

    static func recoveryName(for path: String) -> String { SHA256Digest.hex(Data(path.utf8)) }
}
