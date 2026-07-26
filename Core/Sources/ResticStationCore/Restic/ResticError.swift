import Foundation

// MARK: - Category

/// The three-way classification from `docs/architecture.md` §Error taxonomy
/// (plus `success`), which drives `RunStatus` and retry behavior.
public enum ResticErrorCategory: String, Equatable, Sendable {
    case success
    /// Completed with caveats — run record `.warning`.
    case warning
    /// Failed; write a `.failed` run record, do not retry until the next
    /// scheduled slot or a manual trigger.
    case terminal
    /// Environmental/transient — do NOT write a `.failed` run record.
    case retryable
}

// MARK: - ResticExitClass

/// restic's exit code, mapped to meaning. Table verified against restic
/// 0.18.1 — see `docs/restic-cli.md` §Exit codes.
///
/// | Code | Case |
/// |---|---|
/// | 0 | ``success`` |
/// | 1, 2 | ``fatal(stderrSummary:)`` (2 = Go runtime error) |
/// | 3 | ``warningIncompleteRead`` — snapshot WAS created |
/// | 10 | ``repoDoesNotExist`` |
/// | 11 | ``repoLocked`` |
/// | 12 | ``wrongPassword`` |
/// | other | ``other(_:)`` |
public enum ResticExitClass: Equatable, Sendable {
    case success
    /// Exit 3: backup finished but some source files could not be read. The
    /// snapshot exists, so mirroring and retention still run.
    case warningIncompleteRead
    /// Exit 1 (fatal error) or 2 (Go runtime error). The summary is a
    /// trimmed, length-capped excerpt of restic's stderr (or of an
    /// `exit_error` NDJSON message) — never environment values.
    case fatal(stderrSummary: String)
    /// Exit 10.
    case repoDoesNotExist
    /// Exit 11.
    case repoLocked
    /// Exit 12.
    case wrongPassword
    /// Any other exit code, kept verbatim.
    case other(Int32)

    /// Longest stderr excerpt carried in ``fatal(stderrSummary:)``. Keeps
    /// error strings bounded when restic dumps a long trace.
    static let summaryCharacterLimit = 500

    /// Maps an exit code (plus optional stderr text) onto this enum.
    public static func classify(exitCode: Int32, stderr: String = "") -> ResticExitClass {
        switch exitCode {
        case 0:
            return .success
        case 3:
            return .warningIncompleteRead
        case 1, 2:
            return .fatal(stderrSummary: summarize(stderr))
        case 10:
            return .repoDoesNotExist
        case 11:
            return .repoLocked
        case 12:
            return .wrongPassword
        default:
            return .other(exitCode)
        }
    }

    /// Trims and caps a stderr blob for embedding in ``fatal(stderrSummary:)``.
    static func summarize(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > summaryCharacterLimit else {
            return trimmed
        }
        return String(trimmed.prefix(summaryCharacterLimit)) + "…"
    }

    public var category: ResticErrorCategory {
        switch self {
        case .success:
            return .success
        case .warningIncompleteRead:
            return .warning
        case .fatal, .repoDoesNotExist, .wrongPassword:
            return .terminal
        case .repoLocked:
            // Retryable exactly once: the engine runs `restic unlock` (which
            // removes only locks held by dead processes) and retries; if the
            // repository is still locked the engine escalates to terminal
            // itself (architecture.md §Error taxonomy, restic-cli.md §Stale
            // locks). The category here describes the *first* occurrence.
            return .retryable
        case .other:
            return .terminal
        }
    }

    public var isSuccess: Bool {
        self == .success
    }

    /// One sentence of "what happened", one sentence of "what to do next" —
    /// the "one next step" rule from `docs/ui-spec.md` §Voice. The caller
    /// prefixes what failed (set / destination); this string never contains
    /// environment values or credentials.
    public var userFacingMessage: String {
        switch self {
        case .success:
            return "Completed successfully."
        case .warningIncompleteRead:
            return "Some files could not be read and are missing from this snapshot; "
                + "everything else was backed up. Open the run log to see which files were skipped."
        case .fatal(let stderrSummary):
            let trimmed = stderrSummary.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            let detail = trimmed.isEmpty ? "restic reported a fatal error" : trimmed
            return "\(detail). Open the run log for the full restic output."
        case .repoDoesNotExist:
            return "No repository was found at this location. "
                + "Check the destination's path, then initialize the repository if it is new."
        case .repoLocked:
            return "The repository is locked by another operation. "
                + "If no other backup is running, remove stale locks in Maintenance and try again."
        case .wrongPassword:
            return "The stored password does not open this repository. "
                + "Update the password in the destination's settings."
        case .other(let code):
            return "restic exited unexpectedly (code \(code)). Open the run log for the full restic output."
        }
    }
}

// MARK: - ResticRunnerError

/// Failures that stop `ResticRunner` from producing a `ResticOutcome` at all
/// — i.e. restic either never ran or did not run to completion.
public enum ResticRunnerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The keychain pre-flight failed for this destination: the repo
    /// password could not be read, so restic's `RESTIC_PASSWORD_COMMAND`
    /// would fail too (typically a locked keychain at a pre-login tick).
    /// **Retryable** per architecture.md — no `.failed` run record.
    ///
    /// Deliberately carries only the destination id: the underlying
    /// `security` output is not embedded anywhere it could reach a log.
    case keychainUnavailable(destinationId: UUID)
    /// The restic binary could not be spawned (missing/not executable).
    case launchFailed(String)
    /// The caller's timeout elapsed. `ProcessRunning` has already sent
    /// SIGINT and, after a 10 s grace period, SIGKILL.
    case timedOut

    public var description: String {
        switch self {
        case .keychainUnavailable(let destinationId):
            return "keychain unavailable for destination \(destinationId)"
        case .launchFailed(let reason):
            return "failed to launch restic: \(reason)"
        case .timedOut:
            return "restic timed out"
        }
    }

    public var category: ResticErrorCategory {
        switch self {
        case .keychainUnavailable:
            return .retryable
        case .launchFailed, .timedOut:
            return .terminal
        }
    }

    /// See ``ResticExitClass/userFacingMessage`` for the "one next step" rule.
    public var userFacingMessage: String {
        switch self {
        case .keychainUnavailable:
            return "The password for this destination could not be read from the keychain. "
                + "Unlock your login keychain, then run the backup again."
        case .launchFailed:
            return "The restic program could not be started. "
                + "Check the restic path in Settings."
        case .timedOut:
            return "restic did not finish in time and was stopped. "
                + "Check that the destination is reachable, then try again."
        }
    }
}

extension ResticRunnerError: LocalizedError {
    public var errorDescription: String? { description }
}
