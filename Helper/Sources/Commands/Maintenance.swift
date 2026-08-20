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

    /// App confirmations carry a fingerprint of the complete effective
    /// destination their dry run inspected. The helper owns the final check,
    /// because it reloads config after the app may have compared an earlier
    /// in-memory snapshot.
    @Option(name: .long, help: "Require the resolved destination to match this preview fingerprint.")
    var expectedDestination: String?

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
        /// Opaque and emitted only by a successful dry run. The app sends it
        /// back on confirmation; the helper recomputes it from freshly loaded
        /// config plus secret storage before it allows a destructive prune.
        let confirmationBinding: String?
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

        if let expectedDestination {
            try Self.validateExpectedDestination(
                expectedDestination,
                destination: destination,
                setId: set,
                secretEnv: try await context.secrets.secretEnv(destId: destination.id)
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
        let confirmationBinding: String?
        if dryRun {
            confirmationBinding = try await Self.confirmationBinding(
                destination: destination,
                secrets: context.secrets
            )
        } else {
            confirmationBinding = nil
        }

        let report = Report(
            setId: set,
            destinationId: destination.id,
            label: destination.label,
            dryRun: dryRun,
            status: status,
            confirmationBinding: confirmationBinding
        )
        if json {
            CLIJSON.print(report)
        } else {
            let qualifier = dryRun ? "dry run " : ""
            print("\"\(destination.label)\": prune \(qualifier)\(status.rawValue)")
        }
    }

    /// The destructive command must validate against the helper's freshly
    /// loaded config, not only against the app's earlier in-memory view. Kept
    /// separate for a focused regression that proves the check happens before
    /// an engine/restic invocation can be reached.
    static func validateExpectedDestination(
        _ expectedDestination: String?,
        destination: Destination,
        setId: UUID,
        secretEnv: [String: String]
    ) throws {
        guard let expectedDestination,
              destination.pruneConfirmationFingerprint(secretEnv: secretEnv) != expectedDestination else { return }
        throw CLIFailure(
            code: .operationNotAllowed,
            message: "Destination configuration changed after the reclaim preview. Run a new dry run before pruning.",
            details: CLIErrorDetails(setId: setId, destinationId: destination.id)
        )
    }

    private static func confirmationBinding(
        destination: Destination,
        secrets: any SecretStore
    ) async throws -> String {
        do {
            return destination.pruneConfirmationFingerprint(
                secretEnv: try await secrets.secretEnv(destId: destination.id)
            )
        } catch {
            throw CLIFailure.classify(error)
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
