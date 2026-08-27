import Foundation
import ResticStationCore

/// Every user-visible string the Backup Sets surface pins verbatim from
/// `docs/ui-spec.md` §Backup Sets, plus the formatters the list, the editor
/// and the destination table share.
///
/// The copy lives in one file on purpose: the spec's exact wording is a
/// review artifact ("All ui-spec.md copy strings used verbatim" is a T14
/// acceptance criterion), and a single file is greppable against the spec.
/// These are plain `String`s handed to `Text(_: S)`, i.e. the *non*-markdown,
/// non-localized initializer — so backticks and em dashes render exactly as
/// written.
enum SetsCopy {

    // MARK: - Verbatim (docs/ui-spec.md §Backup Sets)

    /// Delete-set confirmation.
    static let deleteSetConfirmation =
        "Deletes the backup set configuration. Repositories and snapshots are NOT touched."

    /// Remove-destination confirmation.
    static let removeDestinationConfirmation =
        "Removes the destination and its saved password from your keychain. "
        + "The repository itself is not touched."

    /// Empty-state action.
    static let createFirstSet = "Create your first backup set"

    /// Retention footnote.
    static let retentionFootnote =
        "Applied to the primary after each backup, and mirrored to each secondary after it syncs."

    /// Integrity-check footnote.
    static let checkFootnote =
        "Weekly `restic check`; over 20 weeks the entire repository's data is read and verified."

    /// Local destination under `~/Library/Mobile Documents`.
    static let iCloudWarning =
        "iCloud may evict repository files with Optimize Mac Storage — this can corrupt reads; "
        + "consider a non-synced location. Sync folders replicate deletions — treat this as a "
        + "convenience copy, not your only backup."

    /// Local destination under `/Volumes`.
    static let removableVolumeNote = "Removable volume — will be skipped when not mounted"

    /// The prominent password warning in the destination editor.
    static let passwordSafety =
        "Store this password somewhere safe outside this Mac. Without it the backup is unreadable. "
        + "Restic Station keeps it in your login keychain only."

    /// Caption under the raw repository URL field (SFTP / REST / Other).
    static let rawRepoCaption = "Anything restic accepts after `-r`."

    /// Placeholder for the S3 endpoint field ("empty = AWS").
    static let s3EndpointPlaceholder = "https://<accountid>.r2.cloudflarestorage.com"

    /// restic's exclude-pattern documentation (linked from the Excludes section).
    static let excludeSyntaxURL = URL(
        string: "https://restic.readthedocs.io/en/stable/040_backup.html#excluding-files"
    )!
    static let excludeSyntaxLinkText = "restic exclude-pattern syntax"

    /// Purge excludes are deliberately a separate list: their patterns are
    /// also excluded from future backups, but are reserved to remove matching
    /// files from existing snapshots when the purge workflow runs.
    static let purgeExcludesTitle = "Purge Excludes"
    static let purgeExcludesEmptyState = "Nothing is marked for removal from existing snapshots."
    static let purgeExcludesPatternField = "Pattern"
    static let purgeExcludesPatternPlaceholder = "node_modules"
    static let purgeExcludesAddPattern = "Add Pattern"
    static let purgeExcludesRemovePatternHelp = "Remove this purge pattern"
    static let purgeExcludesFootnote =
        "Purge excludes are reserved to remove matching files from existing snapshots. "
        + "They are also excluded from new backups. Space is not reclaimed until a prune runs."

    // MARK: - Written for this screen

    static let emptyStateTitle = "No backup sets yet"
    static let emptyStateExplainer =
        "A backup set is what to back up (folders and files), when to back it up, "
        + "and the repositories it is backed up to."

    /// Shown when the user tries to remove the primary while secondaries exist.
    static let primaryRemovalBlocked =
        "The primary destination is where backups are written and what every secondary is "
        + "mirrored from. Make another destination the primary first, then remove this one."

    /// Explanatory confirmation for a primary change (ui-spec: "new primary
    /// must already contain the data or the next backup re-uploads everything").
    static let primaryChangeExplanation =
        "The new primary must already contain this set's snapshots. If it does not, the next "
        + "backup re-uploads everything from scratch. Secondaries are mirrored from the primary, "
        + "so this also changes what they copy from."

    /// Known v1 limitation (docs/restic-cli.md §init secondary).
    static let sharedS3CredentialsNote =
        "Two S3 destinations in one set must use the same credentials."

    /// Shown on a newly added secondary.
    static let secondaryNeedsInit =
        "A new secondary must be initialized from the primary before the first mirror copy — "
        + "that is what keeps deduplication working between the two repositories."

    // MARK: - Formatters

    /// "Daily 02:30" — the ui-spec's own example.
    static func scheduleSummary(_ schedule: Schedule) -> String {
        switch schedule {
        case .everyMinutes(let minutes):
            return "Every \(minutes) minutes"
        case .hourly(let minute):
            return String(format: "Hourly at :%02d", minute)
        case .daily(let hour, let minute):
            return String(format: "Daily %02d:%02d", hour, minute)
        case .weekly(let weekday, let hour, let minute):
            return String(format: "Weekly %@ %02d:%02d", weekdayName(weekday), hour, minute)
        }
    }

    /// `weekday` follows the `Calendar` convention (1 = Sunday).
    static func weekdayName(_ weekday: Int, calendar: Calendar = .autoupdatingCurrent) -> String {
        let symbols = calendar.weekdaySymbols
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "?"
    }

    static func timeOfDay(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// Display-only next fire time. `.distantPast` (never run) and any past
    /// grid point both read as "Due now" — the helper's tick is what actually
    /// decides (`docs/scheduling.md` §What the app does).
    static func nextDueText(_ date: Date, now: Date = Date()) -> String {
        guard date > now else { return "Due now" }
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func sourceCountText(_ count: Int) -> String {
        count == 1 ? "1 source" : "\(count) sources"
    }

    /// "last synced N days ago" (ui-spec §Backup Sets, destination table).
    static func lastSyncedText(_ status: RepoStatus?, now: Date = Date()) -> String {
        guard let lastSyncedAt = status?.lastSyncedAt else {
            return "never synced"
        }
        let days = Int(now.timeIntervalSince(lastSyncedAt) / 86_400)
        switch days {
        case ..<1:
            return "last synced today"
        case 1:
            return "last synced 1 day ago"
        default:
            return "last synced \(days) days ago"
        }
    }

    static func kindLabel(_ kind: DestinationKind) -> String {
        switch kind {
        case .localPath: return "LOCAL"
        case .sftp: return "SFTP"
        case .rest: return "REST"
        case .s3: return "S3"
        case .otherCloud: return "CLOUD"
        }
    }

    static func kindSymbol(_ kind: DestinationKind) -> String {
        switch kind {
        case .localPath: return "folder"
        case .sftp: return "network"
        case .rest: return "globe"
        case .s3: return "cloud"
        case .otherCloud: return "cloud"
        }
    }

    // MARK: - Validation messages

    /// Maps a `ConfigError` from `AppConfig.validate()` onto the field whose
    /// editor should show it, in this screen's voice (T14: "validation errors
    /// surface inline (map `ConfigError` cases to field-level messages)").
    static func fieldMessage(for error: ConfigError) -> (field: SetEditorField, message: String) {
        switch error {
        case .remoteMaintenanceRequiresSFTP:
            return (.destinations, "Remote maintenance is available only for SFTP destinations.")
        case .newerVersion:
            return (.general, error.description)
        case .notExactlyOnePrimaryDestination(_, let count):
            if count == 0 {
                return (.destinations, "Add a destination and mark it the primary.")
            }
            return (
                .destinations,
                "Exactly one destination must be the primary — \(count) are marked primary right now."
            )
        case .duplicateIdentifier:
            return (
                .general,
                "Another backup set or destination already uses this identifier. "
                    + "Reopen Restic Station and try again."
            )
        case .emptySources:
            return (.sources, "Add at least one folder or file to back up.")
        case .relativeSourcePath(_, let path):
            return (.sources, "Sources must be absolute paths — “\(path)” is not.")
        case .nonCanonicalSourcePath(_, let path):
            return (
                .sources,
                "“\(path)” contains “.” or “..”. Use the folder's real path instead — restic "
                    + "stores the resolved path, so backups from this source could not be matched "
                    + "back to it."
            )
        case .emptyPurgeExcludePattern:
            return (
                .purgeExcludes,
                "Remove the blank pattern — every entry here must be a real path or glob."
            )
        case .invalidSchedule(_, let reason):
            return (.schedule, "This schedule is out of range: \(reason).")
        case .invalidStalenessWarningDays:
            return (.staleness, "The staleness warning must be at least 1 day.")
        case .invalidReadDataSubsetSlices:
            return (.checks, "The number of check slices must be between 2 and 100.")

        // Per-machine overrides (schema v2). There is no per-machine editing
        // UI yet — these keys are hand-written in `config.json` — so the
        // messages name the file and the fix rather than pointing at a field
        // that does not exist. They are mapped explicitly, not defaulted, so
        // adding a future override field forces this decision again.
        case .invalidMachineIdKey(_, let machineId):
            return (
                .general,
                "“\(machineId)” is not a valid machine name in this set's per-machine settings. "
                    + "Machine names use lowercase letters, digits and hyphens only. "
                    + "Edit config.json to fix it."
            )
        case .relativeOverrideSourcePath(_, let machineId, let path):
            return (
                .sources,
                "Sources must be absolute paths — “\(path)”, set for machine “\(machineId)” in config.json, is not."
            )
        case .nonCanonicalOverrideSourcePath(_, let machineId, let path):
            return (
                .sources,
                "“\(path)”, set for machine “\(machineId)” in config.json, contains “.” or “..”. "
                    + "Use the folder's real path instead — restic stores the resolved path, so "
                    + "backups from this source could not be matched back to it."
            )
        case .notExactlyOnePrimaryDestinationForMachine(_, let machineId, let count):
            if count == 0 {
                return (
                    .destinations,
                    "This set's primary destination is turned off for machine “\(machineId)” in config.json. "
                        + "Turn the whole set off for that machine instead, or re-enable the primary."
                )
            }
            return (
                .destinations,
                "Machine “\(machineId)” ends up with \(count) primary destinations for this set. "
                    + "Exactly one destination must be the primary on every machine."
            )
        }
    }

    /// Any error thrown by `AppModel.saveSet` mapped onto a field.
    static func fieldMessage(for error: Error) -> (field: SetEditorField, message: String) {
        if let configError = error as? ConfigError {
            return fieldMessage(for: configError)
        }
        return (.general, (error as? LocalizedError)?.errorDescription ?? "\(error)")
    }

    /// Destination-secret persistence spans a config preflight and the
    /// selected secret backend. Keep those failures distinct: unlocking the
    /// login keychain cannot repair an unreadable config or broken lock.
    static func destinationSecretFailureMessage(
        for error: Error,
        backend: SecretBackend = .configured
    ) -> String {
        if let configError = error as? ConfigStoreError {
            if configError.isRevisionConflict {
                return "Settings changed on disk while this destination was open. "
                    + "Reload Settings, then apply the edit again; no keychain item was changed."
            }
            return "Settings could not be checked safely before writing this destination "
                + "(\(configError)). No keychain item was changed. Resolve the configuration or "
                + "locking error, then try again."
        }
        if let appError = error as? AppModelError {
            switch appError {
            case .configUnreadable:
                return (appError.errorDescription ?? "The configuration is unreadable.")
                    + "\n\nNo keychain item was changed."
            case .machineUnreadable, .secretRollbackFailed, .newerSecretEditorMutation:
                return appError.errorDescription ?? "\(appError)"
            }
        }
        if error is LockFailure {
            return "Settings could not be checked safely before writing this destination "
                + "(\(error)). No keychain item was changed. Resolve the configuration or "
                + "locking error, then try again."
        }
        return "The credentials for this destination could not be written to \(backend.displayName) "
            + "(\(error)). \(backend.unavailableAdvice)"
    }

    // MARK: - Passwords

    /// 32 random characters from a 64-symbol alphabet (192 bits). Generated
    /// with `SystemRandomNumberGenerator`, which is `arc4random_buf` on
    /// Darwin — never a seeded/deterministic RNG.
    static func generatePassword(length: Int = 32) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).compactMap { _ in alphabet.randomElement(using: &generator) })
    }
}

// MARK: - SetEditorField

/// The set editor's inline-error slots. One per section that can fail
/// validation, plus `.general` for anything that is not field-specific.
enum SetEditorField: Hashable, Sendable {
    case name
    case sources
    /// The purging-exclusion list (schema v3). There is no `excludes` case:
    /// plain excludes are deliberately unvalidated, so nothing can ever
    /// point an error at them.
    case purgeExcludes
    case schedule
    case staleness
    case retention
    case checks
    case destinations
    case general
}
