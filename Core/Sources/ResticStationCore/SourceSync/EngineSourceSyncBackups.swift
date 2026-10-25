import Foundation

/// Uses the same guarded engine as ordinary backups and restores. A small
/// protection vault is an additional internal source; the configured source
/// list and mirror destinations are always retained in both backup passes.
public struct EngineSourceSyncBackups: SourceSyncBackingUp {
    public let engine: BackupEngine
    public let runs: RunStore
    public let restic: ResticRunner

    public init(engine: BackupEngine, runs: RunStore, restic: ResticRunner) { self.engine = engine; self.runs = runs; self.restic = restic }

    public func protect(set: BackupSet, vault: URL, inventory: SyncInventory) async throws -> SyncProtectionReceipt {
        guard let primary = set.destinations.first(where: \.isPrimary) else { throw SourceSyncError.protectionFailed }
        let repositoryId = try await identity(primary)
        let result = await engine.runSet(adding(vault, to: set), trigger: .manual)
        guard case .completed(let status, _, let children) = result,
              status == .success,
              let backup = children.first(where: { $0.kind == .backup && $0.destId == primary.id }),
              backup.status == .success || backup.status == .warning,
              mirrorsComplete(set, children: children),
              let snapshot = try runs.metadata(runId: backup.runId).snapshotId else { throw SourceSyncError.protectionFailed }
        // A fresh target and an exact snapshot subtree keep unrelated live
        // paths out of a recovery proof. Neither a dry-run nor a timestamp
        // can produce this receipt.
        let restored = vault.deletingLastPathComponent().appendingPathComponent("restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let restore = await engine.runRestore(request: RestoreRequest(
            destId: primary.id, snapshotID: snapshot, subpath: vault.path,
            targetPath: restored.path, overwriteMode: .never
        ))
        guard case .completed(.success) = restore else { throw SourceSyncError.protectionFailed }
        guard try await identity(primary) == repositoryId else { throw SourceSyncError.protectionFailed }
        return try SyncProtectionReceipt.verify(repositoryId: repositoryId, snapshotId: snapshot, expected: inventory, restoredAt: restored)
    }

    public func backup(set: BackupSet, retaining vault: URL?) async throws {
        if let vault {
            do {
                let inventory = try SourceSyncFilesystem.inventory(at: SourceSyncFilesystem.physicalDirectory(vault.path))
                _ = try await protect(set: set, vault: vault, inventory: inventory)
                return
            } catch {
                throw SourceSyncError.stateInvalid("The folders synchronized, but the final backup and recovery agreement could not be verified. Inspect Runs, then resume to retry the backup.")
            }
        }
        let result = await engine.runSet(set, trigger: .manual)
        guard case .completed(.success, _, let children) = result,
              children.allSatisfy({ $0.status == .success }), mirrorsComplete(set, children: children) else {
            throw SourceSyncError.stateInvalid("Synchronization finished, but the backup or a backup destination needs attention. Inspect Runs, then resume to retry the backup.")
        }
    }

    private func adding(_ vault: URL, to set: BackupSet) -> BackupSet {
        var scoped = set
        scoped.sources.append(vault.path)
        return scoped
    }

    private func mirrorsComplete(_ set: BackupSet, children: [SetRunChild]) -> Bool {
        set.destinations.filter { !$0.isPrimary }.allSatisfy { destination in
            children.contains { $0.kind == .copy && $0.destId == destination.id && $0.status == .success }
        }
    }

    private func identity(_ destination: Destination) async throws -> String {
        let result = try await restic.run(.catConfig(repo: destination.repoURL), for: ResticInvocation(destination: destination))
        guard result.status == .success else { throw SourceSyncError.protectionFailed }
        let config: RepositoryConfig
        do { config = try parseRepositoryConfig(Data(result.rawOutput.utf8)) }
        catch { throw SourceSyncError.protectionFailed }
        guard config.id.count == 64, config.id.allSatisfy(\.isHexDigit) else { throw SourceSyncError.protectionFailed }
        return config.id
    }
}
