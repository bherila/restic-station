import Foundation

// MARK: - BackupDryRunReport

/// What `backup dry-run` found (#78): the work a backup of one set would do
/// right now, measured by restic itself with `backup --dry-run`, and nothing
/// written anywhere.
///
/// Produced only by ``BackupEngine/backupDryRun(_:)``, which builds the
/// command with the same builder as a real backup, so the two cannot drift
/// apart on sources, exclusions or the online-only-file flag.
///
/// **No paths in the machine-readable half.** ``warnings`` and every other
/// field except ``logNotes`` are free of source paths and file names, which
/// can reveal private structure; `docs/cli-json.md` publishes them.
/// ``logNotes`` are the lines a real backup's run log would carry and can
/// name a directory, so only the human output prints them.
public struct BackupDryRunReport: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        /// restic read everything it was asked to.
        case success
        /// restic finished and some sources could not be read (exit 3).
        /// The figures leave those files out.
        case warning
    }

    public let setId: UUID
    public let setName: String
    public let primary: Destination
    public let outcome: Outcome
    /// restic's own `summary` line. Its `snapshotId` names a snapshot that
    /// was never saved, so no surface may publish it.
    public let summary: BackupSummary
    /// `--exclude-cloud-files` was passed.
    public let cloudFilesExcluded: Bool
    /// `--exclude-caches` was passed.
    public let excludeCaches: Bool
    /// How many `--exclude` and `--iexclude` patterns were passed.
    public let excludePatternCount: Int
    public let resticExitCode: Int32
    /// Path-free conditions a caller should know about.
    public let warnings: [String]
    /// The lines a real backup writes to its run log before restic starts.
    /// May name a directory; for human output only.
    public let logNotes: [String]

    public init(
        setId: UUID,
        setName: String,
        primary: Destination,
        outcome: Outcome,
        summary: BackupSummary,
        cloudFilesExcluded: Bool,
        excludeCaches: Bool,
        excludePatternCount: Int,
        resticExitCode: Int32,
        warnings: [String],
        logNotes: [String]
    ) {
        self.setId = setId
        self.setName = setName
        self.primary = primary
        self.outcome = outcome
        self.summary = summary
        self.cloudFilesExcluded = cloudFilesExcluded
        self.excludeCaches = excludeCaches
        self.excludePatternCount = excludePatternCount
        self.resticExitCode = resticExitCode
        self.warnings = warnings
        self.logNotes = logNotes
    }
}

// MARK: - BackupDryRunError

/// Why `backup dry-run` produced no report. Each case maps to exactly one
/// `docs/cli-json.md` code through ``CLIFailure/classifyBackupDryRun(_:setId:)``.
///
/// Typed rather than a ready-made `CLIFailure` so the app, or any other
/// caller of ``BackupEngine/backupDryRun(_:)``, can word it for itself.
public enum BackupDryRunError: Error, Sendable, Equatable {
    /// The set has no primary destination.
    case noPrimary
    /// Another operation holds the set lock.
    case busy
    /// The set lock could not be used at all.
    case lockUnusable(String)
    /// The set uses this host's global exclusion list, and it cannot be
    /// read. A real backup refuses for the same reason.
    case globalExcludesUnusable(String)
    /// A permanent secret or hydration refusal: someone has to act.
    case attention(DestinationAttention, destinationId: UUID, message: String)
    /// The secret store answered badly and may answer well later.
    case secretUnavailable(destinationId: UUID, message: String)
    /// The primary did not answer.
    case offline(destinationId: UUID, reason: String)
    /// The reachability probe ran restic and restic failed.
    case probeFailed(destinationId: UUID, ResticExitClass)
    /// restic was never started, or produced no outcome.
    case resticDidNotRun(destinationId: UUID, ResticRunnerError)
    /// restic ran the dry run and failed.
    case resticFailed(destinationId: UUID, ResticExitClass)
    /// The command about to launch did not carry `--dry-run`. Unreachable
    /// through ``BackupEngine/backupDryRun(_:)``'s own builder; checked
    /// anyway, because the alternative is a real backup.
    case notADryRun
    /// restic exited without the `summary` line that marks a finished dry
    /// run (`"dry_run": true`). Nothing can be reported from that, and the
    /// caller is told to look at the repository rather than assume.
    case unconfirmed(destinationId: UUID, reason: String)
}
