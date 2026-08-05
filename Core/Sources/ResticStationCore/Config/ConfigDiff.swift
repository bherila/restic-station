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
    /// excludes, destinations, retention, check policy or **per-machine
    /// overrides** changed — plus the restic path, since a config that just
    /// gained a usable restic binary should start backing up immediately
    /// rather than in two minutes.
    ///
    /// Per-machine overrides count even when they belong to *another*
    /// machine. This projection compares the shared config, not the resolved
    /// one, and it does not know which machine it is running on; treating a
    /// `machines` edit as relevant errs the way the rest of this type errs —
    /// towards an extra tick that finds nothing due, rather than towards a
    /// missed one. It also means the app's change summary can never silently
    /// omit a per-machine edit.
    ///
    /// Deliberately **not** relevant: `showMenuBarIcon`, a set's `name`,
    /// `stalenessWarningDays` (display-only warning threshold), and pure
    /// reordering of sets (order only decides *sequence* within a tick, not
    /// whether anything is due).
    public static func isScheduleRelevantChange(from old: AppConfig, to new: AppConfig) -> Bool {
        projection(old) != projection(new)
    }

    // MARK: - Summary (config import)

    /// A human-readable summary of what changed between two configs — sets
    /// added, removed, or changed, and whether the deprecated `resticPath`
    /// moved. For `config import` (T27), which must show what it is about to
    /// overwrite *before* it does, and for `--dry-run`, which shows the same
    /// summary and stops.
    ///
    /// Deliberately coarser than ``isScheduleRelevantChange(from:to:)``:
    /// that projection exists to answer one yes/no question (does the
    /// scheduler need an early tick?) and does not care what changed, only
    /// whether something schedule-relevant did. This type names *which*
    /// fields differ, for a person to read.
    public struct Summary: Equatable, Sendable {
        public struct SetSummary: Equatable, Sendable {
            public let id: UUID
            public let name: String
        }

        public struct ChangedSet: Equatable, Sendable {
            public let id: UUID
            /// The set's name in the *new* config — the one about to be
            /// installed, which is what a reader deciding whether to
            /// proceed cares about.
            public let name: String
            /// Which top-level `BackupSet` fields differ, in a fixed,
            /// deterministic order (declaration order below) — never a
            /// dictionary/set, so output is stable across runs.
            public let changedFields: [String]
        }

        public let added: [SetSummary]
        public let removed: [SetSummary]
        public let changed: [ChangedSet]
        /// The deprecated top-level `resticPath` differs. Surfaced
        /// separately from `changed` because it is a config-wide field, not
        /// a per-set one, and because a v1→v2 import always trips this (the
        /// migration clears it) — worth naming explicitly rather than
        /// leaving a reader to wonder why no set explains it.
        public let resticPathChanged: Bool

        public var isEmpty: Bool {
            added.isEmpty && removed.isEmpty && changed.isEmpty && !resticPathChanged
        }

        /// One line per change, in the order: added, removed, changed,
        /// `resticPath`. Empty when ``isEmpty``.
        public var lines: [String] {
            var result: [String] = []
            for set in added {
                result.append("+ added set \"\(set.name)\" (\(set.id.uuidString.lowercased()))")
            }
            for set in removed {
                result.append("- removed set \"\(set.name)\" (\(set.id.uuidString.lowercased()))")
            }
            for set in changed {
                result.append("~ changed set \"\(set.name)\": \(set.changedFields.joined(separator: ", "))")
            }
            if resticPathChanged {
                result.append("~ resticPath changed")
            }
            return result
        }
    }

    /// Computes ``Summary`` between `old` and `new`. Sets are matched by
    /// `id`; a name change alone is reported as a `changed` entry (unlike
    /// ``isScheduleRelevantChange(from:to:)``, which ignores renames — that
    /// projection only cares whether the *scheduler* needs to notice, and a
    /// rename never affects what runs).
    public static func summarize(from old: AppConfig, to new: AppConfig) -> Summary {
        let oldByID = Dictionary(uniqueKeysWithValues: old.sets.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.sets.map { ($0.id, $0) })

        let added = new.sets
            .filter { oldByID[$0.id] == nil }
            .map { Summary.SetSummary(id: $0.id, name: $0.name) }
        let removed = old.sets
            .filter { newByID[$0.id] == nil }
            .map { Summary.SetSummary(id: $0.id, name: $0.name) }

        var changed: [Summary.ChangedSet] = []
        for newSet in new.sets {
            guard let oldSet = oldByID[newSet.id] else { continue }
            var fields: [String] = []
            if oldSet.name != newSet.name { fields.append("name") }
            if oldSet.sources != newSet.sources { fields.append("sources") }
            if oldSet.excludes != newSet.excludes { fields.append("excludes") }
            if oldSet.schedule != newSet.schedule { fields.append("schedule") }
            if oldSet.retention != newSet.retention { fields.append("retention") }
            if oldSet.checkPolicy != newSet.checkPolicy { fields.append("checkPolicy") }
            if oldSet.stalenessWarningDays != newSet.stalenessWarningDays { fields.append("stalenessWarningDays") }
            if oldSet.destinations != newSet.destinations { fields.append("destinations") }
            if oldSet.machines != newSet.machines { fields.append("machines") }
            if !fields.isEmpty {
                changed.append(Summary.ChangedSet(id: newSet.id, name: newSet.name, changedFields: fields))
            }
        }

        return Summary(added: added, removed: removed, changed: changed, resticPathChanged: old.resticPath != new.resticPath)
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
                destinations: set.destinations,
                machines: set.machines
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
        /// PRIMARY flag changes what the tick backs up to. `Destination`
        /// carries its own `machines` map, so destination-level per-machine
        /// edits are covered by this field.
        let destinations: [Destination]
        /// Set-level per-machine overrides — an `enabled`, `sources` or
        /// `schedule` override changes what this machine's tick does.
        let machines: [String: BackupSetMachineOverride]?
    }
}
