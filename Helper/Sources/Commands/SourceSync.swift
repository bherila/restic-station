import ArgumentParser
import Foundation
import ResticStationCore

struct SourceSyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync", abstract: "Keep selected folders in sync and backed up.",
        subcommands: [SourceSyncPlanCommand.self, SourceSyncApplyCommand.self, SourceSyncStatusCommand.self, SourceSyncRecoverCommand.self, SourceSyncEndpointCommand.self]
    )
}

private struct SyncSession {
    let context: HelperContext
    let set: BackupSet
    let group: SourceSyncGroup
    let config: AppConfig
    let fingerprint: String
    let binding: String
    let coordinator: SourceSyncCoordinator

    static func make(set id: UUID, group groupId: UUID?) async throws -> SyncSession {
        let context = try await HelperContext.make(.inspecting)
        let snapshot = try context.configStore.reconciliationSnapshot()
        let machineBytes = try Data(contentsOf: context.paths.machineFile)
        let machine = try MachineStore(paths: context.paths).load()
        guard let set = snapshot.config.resolved(for: machine).set(id: id),
              set == context.scheduled.set(id: id) else { throw SourceSyncError.stalePlan }
        let group = try selectedGroup(set, id: groupId)
        guard let executable = context.restic.maintenanceExecutable() else { throw SourceSyncError.stalePlan }
        let binding = try SourceSyncBinding.make(configFingerprint: snapshot.fingerprint, machineBytes: machineBytes, set: set, machineId: context.scheduled.machineId, executableIdentity: executable.identity)
        let coordinator = SourceSyncCoordinator(
            paths: context.paths, backups: EngineSourceSyncBackups(engine: context.engine, runs: context.runStore, restic: context.restic),
            revalidate: {
                guard try context.configStore.currentFileFingerprint() == snapshot.fingerprint,
                      try Data(contentsOf: context.paths.machineFile) == machineBytes,
                      context.restic.maintenanceExecutable()?.identity == executable.identity else { throw SourceSyncError.stalePlan }
            }
        )
        return SyncSession(context: context, set: set, group: group, config: snapshot.config, fingerprint: snapshot.fingerprint, binding: binding, coordinator: coordinator)
    }

    static func selectedGroup(_ set: BackupSet, id: UUID?) throws -> SourceSyncGroup {
        if let id, let group = set.syncFolders.first(where: { $0.id == id }) { return group }
        if id == nil, set.syncFolders.count == 1, let group = set.syncFolders.first { return group }
        throw SourceSyncError.invalidConfiguration("Select a configured sync folder with --group. The option can be omitted when the set has one sync folder.")
    }
}

struct SourceSyncPlanCommand: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Preview both directions; no live file or repository changes.")
    @Option(name: .long) var set: UUID
    @Option(name: .long) var group: UUID?
    @Flag(name: .long, help: "Include relative filenames in the report.") var includePaths = false
    @Flag(name: .long) var json = false

    func run() async throws {
        let s = try await SyncSession.make(set: set, group: group)
        let result = try await s.coordinator.preview(set: s.set, group: s.group, machineId: s.context.scheduled.machineId, config: s.config, binding: s.binding, includePaths: includePaths)
        if json { CLIJSON.print(result) }
        else {
            print("Sync: \(result.copies) copies, \(result.removals) removals, \(result.conflicts) conflicts. Backup: all \(result.backupSourceCount) configured sources.")
            if let changes = result.changes { for change in changes { print("\(change.action.rawValue): \(change.path)") } }
            if let token = result.previewToken {
                print("Preview token: \(token)\nApply with: sync apply --set \(set) --group \(result.groupId) --preview-token-stdin")
            } else { print("Resolve conflicts in the original copies and preview again. Ordinary backup is still available.") }
        }
    }
}

struct SourceSyncApplyCommand: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(commandName: "apply", abstract: "Apply a reviewed plan, verify recovery protection, then back up the full set.")
    @Option(name: .long) var set: UUID
    @Option(name: .long) var group: UUID?
    @Flag(name: .long) var previewTokenStdin = false
    @Flag(name: .long) var json = false

    func run() async throws {
        guard previewTokenStdin else { throw CLIFailure.invalidArguments("--preview-token-stdin is required") }
        let token = try CapabilityInput.read(prompt: "Preview token: ")
        let s = try await SyncSession.make(set: set, group: group)
        let result = try await s.context.configStore.withUnchangedRevision(from: s.fingerprint) {
            try await s.coordinator.apply(token: token, set: s.set, group: s.group, machineId: s.context.scheduled.machineId, config: s.config, binding: s.binding)
        }
        if json { CLIJSON.print(result) } else { print("Folders synchronized and the full backup set backed up.") }
    }
}

struct SourceSyncRecoverCommand: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(commandName: "recover", abstract: "Resume the same durable operation; never discard or expire its reservation.")
    @Option(name: .long) var set: UUID
    @Option(name: .long) var group: UUID?
    @Flag(name: .long, help: "Cancel only a plan that has never started installing files, allowing a new preview.") var cancelUnstarted = false
    @Flag(name: .long) var json = false

    func run() async throws {
        let s = try await SyncSession.make(set: set, group: group)
        let result = try await s.context.configStore.withUnchangedRevision(from: s.fingerprint) {
            if cancelUnstarted {
                return try await s.coordinator.cancelUnstarted(set: s.set, group: s.group, machineId: s.context.scheduled.machineId)
            }
            return try await s.coordinator.recover(set: s.set, group: s.group, machineId: s.context.scheduled.machineId, binding: s.binding)
        }
        if json { CLIJSON.print(result) }
        else { print(cancelUnstarted ? "Unstarted plan cancelled; preview the current folders again." : "Interrupted synchronization recovered and backed up.") }
    }
}

struct SourceSyncStatusCommand: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Read local synchronization state; does not contact the peer or require restic.")
    @Option(name: .long) var set: UUID
    @Option(name: .long) var group: UUID?
    @Flag(name: .long, help: "Include recovery locations and original filename mappings.") var includePaths = false
    @Flag(name: .long) var json = false

    func run() async throws {
        let paths = AppPaths.default()
        let config = try ConfigStore(paths: paths).load(.inspecting)
        guard let selected = config.sets.first(where: { $0.id == set }) else { throw CLIFailure.setNotFound(setId: set) }
        let group = try SyncSession.selectedGroup(selected, id: group)
        let status = try SourceSyncCoordinator.status(paths: paths, setId: set, groupId: group.id, includePaths: includePaths)
        if json { CLIJSON.print(status) }
        else {
            print(status.status)
            if let recovery = status.recovery {
                if let snapshot = recovery.protectedSnapshotId { print("Protection snapshot: \(snapshot)") }
                for entry in recovery.entries {
                    print(entry.path)
                    if let local = entry.localCopy { print("  this computer: \(local)") }
                    if let peer = entry.peerCopy { print("  other computer: \(peer)") }
                }
            }
        }
    }
}

/// Authenticated SSH control protocol. This is deliberately separate from
/// HelperContext: the peer needs neither restic nor repository passwords.
struct SourceSyncEndpointCommand: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(commandName: "endpoint", abstract: "Internal SSH endpoint protocol.", shouldDisplay: false)
    @Flag(name: .long) var json = false
    func run() async throws {
        guard json else { throw CLIFailure.invalidArguments("The endpoint protocol requires --json") }
        let limit = 32 * 1024 * 1024
        var bytes = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: min(65536, limit + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= limit else { throw CLIFailure.invalidArguments("Endpoint input is too large") }
        }
        let request: SyncEndpointRequest
        do { request = try ConfigStore.makeDecoder().decode(SyncEndpointRequest.self, from: bytes) }
        catch { throw CLIFailure.invalidArguments("Endpoint input is invalid") }
        CLIJSON.print(try SyncEndpointService.handle(request))
    }
}
