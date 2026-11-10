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
        let parent = await parentSnapshot(for: set, primary: primary)
        let result = await engine.runSet(adding(vault, to: set), trigger: .manual, parent: parent)
        // The primary is the whole proof: its backup and everything else the
        // run did to it must have succeeded. A mirror that is offline or
        // whose copy failed does not weaken it, so it is reported and the
        // sync goes on (#197).
        guard let proven = Self.provenOnPrimary(result, set: set, primary: primary),
              let snapshot = try runs.metadata(runId: proven.backup.runId).snapshotId else { throw SourceSyncError.protectionFailed }
        let warnings = proven.warnings
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
        var receipt = try SyncProtectionReceipt.verify(repositoryId: repositoryId, snapshotId: snapshot, expected: inventory, restoredAt: restored)
        receipt.mirrorWarnings = warnings
        return receipt
    }

    public func scope(for set: BackupSet) async throws -> SyncScope {
        try engine.syncScope(for: set)
    }

    public func checkDestination(set: BackupSet) async throws {
        guard let primary = set.destinations.first(where: \.isPrimary) else { throw SourceSyncError.destinationUnavailable }
        // Bounded like the reachability probe (docs/restic-cli.md §cat
        // config): restic's own retries against a down remote must not hold
        // apply, its locks and the revision hold for minutes. Only "did not
        // answer" becomes destinationUnavailable; a missing secret, a failed
        // launch or cancellation keeps its own error and classification.
        do { _ = try await identity(primary, timeout: Reachability.probeTimeout) }
        catch SourceSyncError.protectionFailed { throw SourceSyncError.destinationUnavailable }
        catch ResticRunnerError.timedOut { throw SourceSyncError.destinationUnavailable }
    }

    public func backup(set: BackupSet, retaining vault: URL?) async throws -> [String] {
        if let vault {
            do {
                let inventory = try SourceSyncFilesystem.inventory(at: SourceSyncFilesystem.physicalDirectory(vault.path))
                return try await protect(set: set, vault: vault, inventory: inventory).mirrorWarnings
            } catch {
                throw SourceSyncError.stateInvalid("The folders synchronized, but the final backup and recovery agreement could not be verified. Inspect Runs, then resume to retry the backup.")
            }
        }
        let result = await engine.runSet(set, trigger: .manual)
        guard let primary = set.destinations.first(where: \.isPrimary),
              let proven = Self.provenOnPrimary(result, set: set, primary: primary) else {
            throw SourceSyncError.stateInvalid("Synchronization finished, but the backup needs attention. Inspect Runs, then resume to retry the backup.")
        }
        return proven.warnings
    }

    private func adding(_ vault: URL, to set: BackupSet) -> BackupSet {
        var scoped = set
        scoped.sources.append(vault.path)
        return scoped
    }

    /// The vault path is unique per operation, so restic's own match on
    /// host and exact paths never finds a parent, and every sync would re-read
    /// the whole backup scope twice. Any snapshot of this host covering every
    /// configured source is a valid parent; the newest one skips the most
    /// reading. A parent only decides which unchanged files are not re-read,
    /// so any doubt falls back to none: slower, never less complete.
    func parentSnapshot(for set: BackupSet, primary: Destination) async -> String? {
        guard let host = MachineIdentity.kernelHostName(),
              let result = try? await restic.run(.snapshots(repo: primary.repoURL), for: ResticInvocation(destination: primary)),
              result.status == .success,
              let snapshots = try? parseSnapshots(Data(result.rawOutput.utf8)) else { return nil }
        return Self.parent(among: snapshots, host: host, sources: set.sources)
    }

    static func parent(among snapshots: [Snapshot], host: String, sources: [String]) -> String? {
        let required = Set(sources)
        return snapshots
            .filter { $0.hostname == host && required.isSubset(of: $0.paths) && $0.id.count == 64 && $0.id.allSatisfy(\.isHexDigit) }
            .max { $0.time < $1.time }?.id
    }

    /// What a set run proved on the primary, and which mirrors missed it.
    /// The one place a run's outcome is read for sync, for protection and
    /// the final backup alike. The group status is deliberately not
    /// consulted: it is the worst of every run, mirrors included, and a
    /// mirror must not decide the primary's proof (#197).
    static func provenOnPrimary(_ outcome: SetRunOutcome, set: BackupSet, primary: Destination) -> (backup: SetRunChild, warnings: [String])? {
        guard case .completed(_, _, let children) = outcome,
              let backup = primaryBackup(children, primary: primary) else { return nil }
        return (backup, mirrorWarnings(set, children: children))
    }

    /// The primary's backup, if the primary is fully proven: that backup and
    /// every other run against the primary succeeded. A mirror's runs are
    /// not consulted; they only produce warnings.
    static func primaryBackup(_ children: [SetRunChild], primary: Destination) -> SetRunChild? {
        let mine = children.filter { $0.destId == primary.id }
        guard mine.allSatisfy({ $0.status == .success }) else { return nil }
        return mine.first { $0.kind == .backup }
    }

    static func warningsForTesting(_ set: BackupSet, children: [SetRunChild]) -> [String] {
        EngineSourceSyncBackups.mirrorWarnings(set, children: children)
    }

    /// One line per mirror that has no successful copy in this run. An
    /// unreachable mirror records no run at all, so absence is the signal.
    static func mirrorWarnings(_ set: BackupSet, children: [SetRunChild]) -> [String] {
        set.destinations.filter { !$0.isPrimary }.compactMap { destination in
            children.contains { $0.kind == .copy && $0.destId == destination.id && $0.status == .success } ? nil
                : "The backup mirror \"\(destination.label)\" did not receive this backup (it is offline, or its copy failed). It catches up at the next ordinary backup."
        }
    }

    private func identity(_ destination: Destination, timeout: TimeInterval? = nil) async throws -> String {
        let result = try await restic.run(.catConfig(repo: destination.repoURL), for: ResticInvocation(destination: destination), timeout: timeout)
        guard result.status == .success else { throw SourceSyncError.protectionFailed }
        let config: RepositoryConfig
        do { config = try parseRepositoryConfig(Data(result.rawOutput.utf8)) }
        catch { throw SourceSyncError.protectionFailed }
        guard config.id.count == 64, config.id.allSatisfy(\.isHexDigit) else { throw SourceSyncError.protectionFailed }
        return config.id
    }
}
