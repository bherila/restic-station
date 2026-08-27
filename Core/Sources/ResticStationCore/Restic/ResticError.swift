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
    /// The secret-store pre-flight failed for this destination: the repo
    /// password could not be read, so restic's `RESTIC_PASSWORD_COMMAND`
    /// would fail too (typically a locked login keychain at a pre-login tick
    /// on macOS, or a `secrets.json` whose mode has been widened on Linux).
    /// **Retryable** per architecture.md — no `.failed` run record.
    ///
    /// Deliberately carries only the destination id: the backend's own
    /// output is not embedded anywhere it could reach a log.
    case secretsUnavailable(destinationId: UUID)
    /// The secret store answered, and the answer was that nothing is stored
    /// for this destination (``SecretStoreError/itemNotFound``).
    ///
    /// Split from ``secretsUnavailable`` because the two need opposite
    /// advice and, before the split, the runner's pre-flight collapsed them:
    /// a locked keychain unlocks by itself, whereas a destination that never
    /// had a password stored stays that way until someone runs `secret set`.
    /// **Terminal**, not retryable — see `docs/architecture.md` §Error
    /// taxonomy.
    ///
    /// Carries only the destination id, for the same reason
    /// ``secretsUnavailable`` does.
    case secretsNotConfigured(destinationId: UUID)
    /// The secret store could not be consulted at all, and repeating the
    /// request cannot change that: a symlinked or group-readable
    /// `secrets.json`, a file owned outside the trust boundary, contents
    /// that do not decode, or a document written by a newer format version
    /// (``SecretStoreError/storeUnusable(_:)``).
    ///
    /// **Terminal**, not retryable. Split from ``secretsUnavailable``
    /// because the pre-flight collapsed the two and published the
    /// pre-login-tick answer — "wait, this clears itself" — for a store
    /// whose refusal had already named the `chmod` a human has to run
    /// (#96).
    ///
    /// Carries only the destination id, for the same reason
    /// ``secretsUnavailable`` does: the backend's own text names a path and
    /// an owner, and this value ends up in run logs. `secret list` prints
    /// the exact refusal on demand.
    case secretsStoreUnusable(destinationId: UUID)
    /// The restic binary could not be spawned (missing/not executable).
    case launchFailed(String)
    /// The caller's timeout elapsed. `ProcessRunning` has already sent
    /// SIGINT and, after a 10 s grace period, SIGKILL.
    case timedOut

    public var description: String {
        switch self {
        case .secretsUnavailable(let destinationId):
            return "secret store unavailable for destination \(destinationId)"
        case .secretsNotConfigured(let destinationId):
            return "no password stored for destination \(destinationId)"
        case .secretsStoreUnusable(let destinationId):
            return "secret store unusable for destination \(destinationId)"
        case .launchFailed(let reason):
            return "failed to launch restic: \(reason)"
        case .timedOut:
            return "restic timed out"
        }
    }

    public var category: ResticErrorCategory {
        switch self {
        case .secretsUnavailable:
            return .retryable
        case .secretsNotConfigured, .secretsStoreUnusable, .launchFailed, .timedOut:
            return .terminal
        }
    }

    /// See ``ResticExitClass/userFacingMessage`` for the "one next step" rule.
    public var userFacingMessage: String {
        switch self {
        case .secretsUnavailable:
            // Worded for the backend actually in use, not for the host OS:
            // macOS with `RESTIC_STATION_SECRET_BACKEND=file` is supported,
            // and "unlock your login keychain" is the wrong next step for a
            // `secrets.json` whose mode was widened.
            //
            // This is the one place that reads the *configured* backend
            // rather than a store's own `backend`: it is a property on an
            // error value, which has no store to ask. In production the two
            // always agree — every store is built by `SecretStoreFactory`
            // from this same environment. Callers that do hold a store
            // (`BackupEngine`, `Reachability`) use the store's backend.
            let backend = SecretBackend.configured
            return "\(backend.unavailableSummary) \(backend.unavailableAdvice)"
        case .secretsNotConfigured:
            // Deliberately not worded per backend: "nothing is stored" is
            // the same fact and the same next step whichever store answered,
            // and naming the store would invite the reader to go looking in
            // it for something that is not there.
            return "No password is stored for this destination. "
                + "Set one in Destinations (or run `restic-station-helper secret set`), then try again."
        case .secretsStoreUnusable:
            // Deliberately not worded per backend, and deliberately without
            // the store's own text: that text names a path, a uid, and a
            // mode, and this string reaches run logs. Point at the command
            // that prints it in full instead of paraphrasing a refusal
            // whose value is its exactness.
            return "The secret store cannot be read as configured, and retrying will not change that. "
                + "Run `restic-station-helper secret list` to see the exact refusal and how to fix it."
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
