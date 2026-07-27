import Foundation

/// Which config edits the *scheduler* cares about.
///
/// The app kicks an early tick (`launchctl kickstart`, see
/// `docs/scheduling.md` §What the app does) after a save, so a schedule the
/// user just changed takes effect now instead of up to `StartInterval`
/// (120 s) later. Doing that on *every* save would spawn a helper process
/// for cosmetic edits like renaming a set or toggling the menu bar icon.
///
/// Pure and testable so the rule is pinned rather than buried in the view
/// model. False positives are cheap (an extra tick that finds nothing due
/// exits immediately); false negatives just mean the user waits for the next
/// `StartInterval` fire — so the projection below errs towards "relevant".
public enum ConfigDiff {

    /// `true` when the change between `old` and `new` can affect what the
    /// next tick does: sets added/removed, or any set's schedule, sources,
    /// excludes, destinations, retention or check policy changed — plus the
    /// restic path, since a config that just gained a usable restic binary
    /// should start backing up immediately rather than in two minutes.
    ///
    /// Deliberately **not** relevant: `showMenuBarIcon`, a set's `name`,
    /// `stalenessWarningDays` (display-only warning threshold), and pure
    /// reordering of sets (order only decides *sequence* within a tick, not
    /// whether anything is due).
    public static func isScheduleRelevantChange(from old: AppConfig, to new: AppConfig) -> Bool {
        projection(old) != projection(new)
    }

    // MARK: - Projection

    private static func projection(_ config: AppConfig) -> Projection {
        var sets: [UUID: SetProjection] = [:]
        for set in config.sets {
            sets[set.id] = SetProjection(
                schedule: set.schedule,
                sources: set.sources,
                excludes: set.excludes,
                retention: set.retention,
                checkPolicy: set.checkPolicy,
                destinations: set.destinations
            )
        }
        return Projection(resticPath: config.resticPath, sets: sets)
    }

    private struct Projection: Equatable {
        let resticPath: String?
        /// Keyed by set id, so reordering the sets array is not a change.
        let sets: [UUID: SetProjection]
    }

    private struct SetProjection: Equatable {
        let schedule: Schedule
        let sources: [String]
        let excludes: [String]
        let retention: RetentionPolicy?
        let checkPolicy: CheckPolicy?
        /// Whole destinations, not just ids: a changed `repoURL` or a moved
        /// PRIMARY flag changes what the tick backs up to.
        let destinations: [Destination]
    }
}
