import ArgumentParser
import Foundation
import ResticStationCore

/// Repository maintenance actions that do not belong to the backup schedule.
struct Maintenance: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maintenance",
        abstract: "Maintain one repository without changing snapshot retention.",
        subcommands: [MaintenancePrune.self]
    )
}

/// `maintenance prune` reclaims packs unreferenced by current snapshots.
/// It deliberately does not call `forget`, so it is useful for a set whose
/// retention is nil after a reviewed purge rewrite.
struct MaintenancePrune: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Reclaim unreferenced repository space without changing retention."
    )

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    @Option(name: .long, help: "Destination UUID. Defaults to the primary destination.")
    var dest: UUID?

    @Flag(name: .long, help: "Ask restic what prune would reclaim without modifying the repository.")
    var dryRun = false

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    private struct Report: Encodable {
        let setId: UUID
        let destinationId: UUID
        let label: String
        let dryRun: Bool
        let status: RunStatus
    }

    func run() async throws {
        let context = try await HelperContext.make()
        guard let backupSet = context.addressable.set(id: set) else {
            throw CLIFailure.setNotFound(setId: set)
        }
        let destination: Destination
        if let dest {
            guard let match = backupSet.destinations.first(where: { $0.id == dest }) else {
                throw CLIFailure.destinationNotFound(setId: set, destinationId: dest)
            }
            destination = match
        } else if let primary = backupSet.destinations.first(where: { $0.isPrimary }) {
            destination = primary
        } else {
            throw CLIFailure(
                code: .operationNotAllowed,
                message: "The backup set has no primary destination to prune.",
                details: CLIErrorDetails(setId: set)
            )
        }

        let result = await context.engine.runPruneRepository(
            set: backupSet,
            destination: destination,
            dryRun: dryRun
        )
        let status = try Self.status(
            result,
            setId: set,
            destination: destination,
            context: context
        )

        let report = Report(
            setId: set,
            destinationId: destination.id,
            label: destination.label,
            dryRun: dryRun,
            status: status
        )
        if json {
            CLIJSON.print(report)
        } else {
            let qualifier = dryRun ? "dry run " : ""
            print("\"\(destination.label)\": prune \(qualifier)\(status.rawValue)")
        }
    }

    private static func status(
        _ result: PruneRepositoryResult,
        setId: UUID,
        destination: Destination,
        context: HelperContext
    ) throws -> RunStatus {
        switch result {
        case .completed(let status):
            return status
        case .skipped(.busy):
            throw CLIFailure.setBusy(setId: setId)
        case .skipped(.secretUnavailable):
            throw CLIFailure(
                code: .secretUnavailable,
                message: "Could not read the repository secret. Unlock or repair secret storage, then try again.",
                details: CLIErrorDetails(setId: setId, destinationId: destination.id)
            )
        case .skipped(.staleMirror):
            throw CLIFailure(
                code: .operationNotAllowed,
                message: "Mirror \"\(destination.label)\" is behind its primary; sync it before pruning.",
                details: CLIErrorDetails(setId: setId, destinationId: destination.id)
            )
        case .failed(.offline(let reason)):
            throw CLIFailure(
                code: .repositoryOffline,
                message: "Destination \"\(destination.label)\" is offline: \(reason)",
                details: CLIErrorDetails(setId: setId, destinationId: destination.id)
            )
        case .failed(.restic(let exitClass)):
            throw CLIFailure.classify(
                exitClass: exitClass,
                setId: setId,
                destinationId: destination.id
            )
        case .failed(.didNotRun):
            let diagnosticReference = (try? context.runStore.lastRun(setId: setId, kind: .prune))?
                .runId
            throw CLIFailure(
                code: .resticFailed,
                message: "Prune did not start. Check the run log and try again.",
                details: CLIErrorDetails(
                    setId: setId,
                    destinationId: destination.id,
                    diagnosticReference: diagnosticReference
                )
            )
        }
    }
}
