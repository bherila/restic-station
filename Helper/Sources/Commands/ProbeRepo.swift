import ArgumentParser
import Foundation
import ResticStationCore

/// `probe-repo --set <uuid> --dest <uuid>` — an on-demand reachability
/// probe (the app's manual "check now" action; also what `tick` does for
/// every destination every 30 minutes, inline).
struct ProbeRepo: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "probe-repo",
        abstract: "Probe one destination's reachability and record the result. "
            + "--json for scripting. Exit 0 reachable, 3 offline, 1 error."
    )

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    @Option(name: .long, help: "The destination UUID to probe.")
    var dest: UUID

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    /// `probe-repo --json`'s shape — see `docs/cli-json.md`.
    ///
    /// **Offline is reported as a success, not as an error envelope.** An
    /// unplugged drive is the expected state of a destination, not a fault,
    /// and the exit code (3) already says so. Wrapping it as a failure would
    /// make a caller treat "your NAS is asleep" the same as "your config is
    /// broken". `outcome` is the field to branch on.
    struct Report: Encodable {
        enum Outcome: String, Encodable {
            case reachable
            case offline
            case error
        }
        let setId: UUID
        let destinationId: UUID
        let label: String
        let outcome: Outcome
        let reachable: Bool
        /// Why, when `outcome` is not `reachable`. Never a repository URL
        /// or a credential — it is `Reachability`'s own bounded reason.
        let reason: String?

        // Explicit `null`, never an omitted key: that is the convention
        // every other `--json` shape follows (`docs/data-model.md`
        // §Encoding conventions), and the synthesized encoder would use
        // `encodeIfPresent` and drop it.
        private enum CodingKeys: String, CodingKey {
            case setId, destinationId, label, outcome, reachable, reason
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(setId, forKey: .setId)
            try container.encode(destinationId, forKey: .destinationId)
            try container.encode(label, forKey: .label)
            try container.encode(outcome, forKey: .outcome)
            try container.encode(reachable, forKey: .reachable)
            try container.encode(reason, forKey: .reason)
        }
    }

    func run() async throws {
        let context = try await HelperContext.make()
        // Repository utilities address every repository in the shared config,
        // including sets this machine does not back up (T24): `addressable`,
        // not `scheduled`.
        guard let backupSet = context.addressable.set(id: set) else {
            throw CLIFailure.setNotFound(setId: set)
        }
        guard let destination = backupSet.destinations.first(where: { $0.id == dest }) else {
            throw CLIFailure.destinationNotFound(setId: set, destinationId: dest)
        }

        let probe = await context.reachability.probe(destination)
        let now = Date()
        do {
            try context.stateStore.updateRepoStatus(destId: destination.id) { status in
                status.probedAt = now
                switch probe {
                case .reachable:
                    status.reachable = true
                    status.lastError = nil
                case .offline(let reason):
                    status.reachable = false
                    status.lastError = reason
                case .error(let exitClass):
                    status.reachable = false
                    status.lastError = exitClass.userFacingMessage
                case .needsAttention(_, let reason):
                    status.reachable = false
                    status.lastError = reason
                }
            }
        } catch {
            StandardStream.write(Data("probe-repo: could not write repo-status: \(error)\n".utf8), to: .standardError)
        }

        let outcome: Report.Outcome
        let reason: String?
        let exitCode: Int32
        switch probe {
        case .reachable:
            (outcome, reason, exitCode) = (.reachable, nil, HelperExitCode.ok.rawValue)
        case .offline(let text):
            (outcome, reason, exitCode) = (.offline, text, HelperExitCode.offline.rawValue)
        case .error(let exitClass):
            (outcome, reason, exitCode) = (.error, exitClass.userFacingMessage, HelperExitCode.error.rawValue)
        case .needsAttention(let attention, let text):
            // The one probe outcome that is neither a success nor a restic
            // result. `outcome: "offline"` here would be published as
            // `ok: true` at exit 3 — the documented "an unplugged drive is
            // expected, try later" answer — which is exactly wrong for a
            // refusal that names the `chmod` or the `secret set` to run. It
            // gets the error envelope, non-retryable, at exit 1 (#96).
            throw CLIFailure(
                code: attention.code,
                message: CLIFailure.bounded(text),
                details: CLIErrorDetails(setId: set, destinationId: destination.id)
            )
        }

        if json {
            CLIJSON.print(
                Report(
                    setId: set,
                    destinationId: destination.id,
                    label: destination.label,
                    outcome: outcome,
                    reachable: outcome == .reachable,
                    reason: reason
                )
            )
        } else {
            switch outcome {
            case .reachable:
                print("\"\(destination.label)\": reachable")
            case .offline:
                print("\"\(destination.label)\": offline — \(reason ?? "")")
            case .error:
                print("\"\(destination.label)\": error — \(reason ?? "")")
            }
        }
        HelperExit.code(exitCode)
    }
}
