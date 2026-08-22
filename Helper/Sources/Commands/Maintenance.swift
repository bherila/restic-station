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

    /// App confirmations carry an opaque, helper-issued preview binding. The
    /// helper owns the final check, because it reloads config after the app
    /// may have compared an earlier in-memory snapshot.
    @Option(name: .long, parsing: .unconditional, help: "Require this helper-issued preview binding before pruning.")
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
        /// Non-secret identity of the destination the helper actually
        /// previewed. The app compares it with the destination it displays
        /// before offering a destructive confirmation.
        let destinationFingerprint: String
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

        let invocationDestination = destination.pruneInvocationDestination()
        let destinationSecretEnv = try await Self.destinationSecretEnv(
            destination: destination,
            secrets: context.secrets
        )
        guard let executable = context.restic.maintenanceExecutable() else {
            throw CLIFailure(
                code: .resticNotFound,
                message: "The configured restic executable could not be read. Recheck restic, then run a new reclaim preview.",
                details: CLIErrorDetails(setId: set, destinationId: destination.id)
            )
        }
        let effectiveFingerprint = invocationDestination.pruneConfirmationFingerprint(
            secretEnv: destinationSecretEnv,
            executableIdentity: executable.identity
        )

        let authorization = expectedDestination.map {
            MaintenancePruneAuthorization(
                token: $0,
                machineId: context.addressable.machineId,
                effectiveDestinationFingerprint: effectiveFingerprint,
                resticExecutablePath: executable.path,
                resticExecutableIdentity: executable.identity
            )
        }

        let result = await context.engine.runPruneRepository(
            set: backupSet,
            destination: invocationDestination,
            destinationSecretEnv: destinationSecretEnv,
            authorization: authorization,
            resticExecutablePath: executable.path,
            resticExecutableIdentity: executable.identity,
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
            confirmationBinding = try Self.issueBinding(
                store: PreviewTokenStore(paths: context.paths),
                machineId: context.addressable.machineId,
                setId: set,
                destinationId: destination.id,
                fingerprint: effectiveFingerprint
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
            confirmationBinding: confirmationBinding,
            destinationFingerprint: invocationDestination.pruneConfirmationFingerprint(secretEnv: [:])
        )
        if json {
            CLIJSON.print(report)
        } else {
            let qualifier = dryRun ? "dry run " : ""
            print("\"\(destination.label)\": prune \(qualifier)\(status.rawValue)")
        }
    }

    /// Issues the dry run's binding, keeping token-store contention
    /// retryable. The generic catch classified it `internal_error` with the
    /// bare message "unavailable" — telling an agent not to retry a
    /// condition this same file calls `set_busy` when it happens at consume
    /// time, and which clears as soon as the other helper releases the lock.
    private static func issueBinding(
        store: PreviewTokenStore,
        machineId: String,
        setId: UUID,
        destinationId: UUID,
        fingerprint: String
    ) throws -> String {
        do {
            return try store.issueMaintenancePrune(
                machineId: machineId,
                setId: setId,
                destinationId: destinationId,
                effectiveDestinationFingerprint: fingerprint
            )
        } catch PreviewTokenError.unavailable {
            throw CLIFailure(
                code: .setBusy,
                message: "The reclaim confirmation is temporarily unavailable. Run the dry run again.",
                details: CLIErrorDetails(setId: setId, destinationId: destinationId)
            )
        } catch PreviewTokenError.storeUnusable(let detail) {
            // Not `set_busy`: "run the dry run again" is the wrong advice
            // for a token store that no retry will fix (#110).
            throw CLIFailure(
                code: .internalError,
                message: CLIFailure.bounded(
                    "The confirmation store could not be used: \(detail). "
                        + "Check the permissions on the Restic Station data directory."
                ),
                details: CLIErrorDetails(setId: setId, destinationId: destinationId)
            )
        }
    }

    private static func previewChangedFailure(setId: UUID, destinationId: UUID) -> CLIFailure {
        CLIFailure(
            code: .operationNotAllowed,
            message: "Destination configuration changed after the reclaim preview. Run a new dry run before pruning.",
            details: CLIErrorDetails(setId: setId, destinationId: destinationId)
        )
    }

    private static func destinationSecretEnv(
        destination: Destination,
        secrets: any SecretStore
    ) async throws -> [String: String] {
        do {
            return try await secrets.secretEnv(destId: destination.id)
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
        case .skipped(.previewChanged):
            throw previewChangedFailure(setId: setId, destinationId: destination.id)
        case .skipped(.previewExpired):
            // Expiry gets its own code and its own sentence. Reporting it as
            // `operation_not_allowed` / "configuration changed" told the
            // caller something factually untrue about their destination, and
            // disagreed with `purge apply`, which has always said
            // `preview_expired` for the same condition.
            throw CLIFailure(
                code: .previewExpired,
                message: "The reclaim preview has expired. Run a new dry run before pruning.",
                details: CLIErrorDetails(setId: setId, destinationId: destination.id)
            )
        case .skipped(.previewUnavailable):
            throw CLIFailure(
                code: .setBusy,
                message: "The reclaim confirmation is temporarily unavailable. Try confirming again.",
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
