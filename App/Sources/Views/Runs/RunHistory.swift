import Foundation
import ResticStationCore
import SwiftUI

// MARK: - RunRow

/// One line in the Runs list: either a finished run (from
/// `runs/index.jsonl`) or an in-flight one (from
/// `state/current-run-<setId>.json`, which has no index line yet).
///
/// `live` is the discriminator: non-`nil` means "this run is happening right
/// now", and carries the progress the row draws.
struct RunRow: Identifiable, Equatable {
    let runId: String
    /// The primary backup's `runId` for a set run; equal to `runId` for a
    /// standalone run (`docs/data-model.md` §runs/index.jsonl).
    let groupId: String
    let kind: RunKind
    let setId: UUID
    /// `nil` only for an in-flight run whose `metadata.json` could not be
    /// read — the destination is then unknown, not absent.
    let destId: UUID?
    let status: RunStatus
    let start: Date
    let end: Date?
    let dataAdded: Int?
    let errorSummary: String?
    /// Live progress while `status == .running`.
    let live: CurrentRunState?

    var id: String { runId }
    var isRunning: Bool { status == .running }
    var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }

    init(entry: RunIndexEntry) {
        self.runId = entry.runId
        self.groupId = entry.groupId
        self.kind = entry.kind
        self.setId = entry.setId
        self.destId = entry.destId
        self.status = entry.status
        self.start = entry.start
        self.end = entry.end
        self.dataAdded = entry.dataAdded
        self.errorSummary = entry.errorSummary
        self.live = nil
    }

    /// An in-flight run. `metadata` is `runs/<runId>/metadata.json`, written
    /// at run start — it is what supplies the `groupId` that nests this row
    /// under the backup it belongs to. Without it (a race with the very
    /// first write, or an unreadable file) the run stands alone as its own
    /// group, which is also how a standalone run is recorded anyway.
    init(live: CurrentRunState, setId: UUID, metadata: RunMetadata?) {
        self.runId = live.runId
        self.groupId = metadata?.groupId ?? live.runId
        self.kind = live.kind
        self.setId = setId
        self.destId = metadata?.destId
        self.status = .running
        self.start = metadata?.start ?? live.updatedAt
        self.end = nil
        self.dataAdded = nil
        self.errorSummary = nil
        self.live = live
    }
}

// MARK: - RunGroup

/// A `groupId` and its rows: the primary `backup` plus the `copy`/`prune`
/// runs it spawned (`docs/ui-spec.md` §Runs — "a scheduled run shows backup
/// + its copies/prunes nested").
struct RunGroup: Identifiable, Equatable {
    /// The `groupId` these rows share.
    let id: String
    /// The row the collapsed list shows — the run whose `runId == groupId`
    /// (the backup) when present.
    let root: RunRow
    /// Nested rows, oldest first (the order they ran in).
    let children: [RunRow]
    /// Newest member start — what the list sorts on.
    let sortDate: Date

    var rows: [RunRow] { [root] + children }
    var isRunning: Bool { rows.contains(where: \.isRunning) }
    var hasChildren: Bool { !children.isEmpty }
}

// MARK: - RunHistory

/// Pure grouping/filtering over the two run sources. Kept free of SwiftUI
/// and of `AppModel` so the rules are readable in one place.
enum RunHistory {

    /// Rows for every in-flight run, one per set with a live progress file.
    ///
    /// - Parameter metadataLookup: `runs/<runId>/metadata.json` reader (see
    ///   `AppModel.runMetadata(runId:)`); called at most once per running
    ///   set, from the list's rebuild step rather than from `body`.
    static func liveRows(
        currentRuns: [UUID: CurrentRunState],
        metadataLookup: (String) -> RunMetadata?
    ) -> [RunRow] {
        currentRuns.map { setId, state in
            RunRow(live: state, setId: setId, metadata: metadataLookup(state.runId))
        }
    }

    /// Newest-first groups built from the index plus the live rows.
    ///
    /// - `indexEntries` is expected newest-first (`RunStore.recentRuns`);
    ///   the first line seen for a `runId` wins, so a re-appended record
    ///   (e.g. crash recovery rewriting a `running` run as `failed`) shows
    ///   its final state.
    /// - A live row whose run has *just* been indexed is dropped in favour
    ///   of the index line: between the index append and the deletion of
    ///   `current-run-<setId>.json` both sources describe the same run, and
    ///   the finished record is the truthful one.
    static func groups(indexEntries: [RunIndexEntry], liveRows: [RunRow]) -> [RunGroup] {
        var rowsByGroup: [String: [RunRow]] = [:]
        var seen: Set<String> = []

        for entry in indexEntries {
            guard seen.insert(entry.runId).inserted else { continue }
            rowsByGroup[entry.groupId, default: []].append(RunRow(entry: entry))
        }
        for row in liveRows where !seen.contains(row.runId) {
            rowsByGroup[row.groupId, default: []].append(row)
        }

        return rowsByGroup.compactMap { groupId, rows -> RunGroup? in
            makeGroup(id: groupId, rows: rows)
        }
        .sorted(by: isNewerFirst)
    }

    /// Applies the composed set/kind/status filter.
    ///
    /// A group survives when *any* of its rows matches. If the backup itself
    /// matches, non-matching children are hidden under it; if only children
    /// match (e.g. filtering by kind = copy), the earliest matching child is
    /// promoted to the visible row so the list never shows a group whose
    /// only visible content contradicts the filter.
    static func filter(_ groups: [RunGroup], with filter: RunFilter) -> [RunGroup] {
        guard filter.isActive else { return groups }
        return groups.compactMap { group in
            let matching = group.rows.filter(filter.matches)
            guard !matching.isEmpty else { return nil }
            return makeGroup(id: group.id, rows: matching, preferredRootId: group.root.runId)
        }
        .sorted(by: isNewerFirst)
    }

    private static func makeGroup(
        id: String,
        rows: [RunRow],
        preferredRootId: String? = nil
    ) -> RunGroup? {
        let sorted = rows.sorted { ($0.start, $0.runId) < ($1.start, $1.runId) }
        guard let fallback = sorted.first else { return nil }
        let root = sorted.first { $0.runId == (preferredRootId ?? id) }
            ?? sorted.first { $0.runId == id }
            ?? fallback
        return RunGroup(
            id: id,
            root: root,
            children: sorted.filter { $0.runId != root.runId },
            sortDate: sorted.map(\.start).max() ?? root.start
        )
    }

    /// Newest first, `runId` descending as a stable tiebreaker (two runs can
    /// share a start second — see `RunStore.allocateRunId`).
    private static func isNewerFirst(_ lhs: RunGroup, _ rhs: RunGroup) -> Bool {
        if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
        return lhs.id > rhs.id
    }
}

// MARK: - RunFilter

/// The Runs filter bar (`docs/ui-spec.md` §Runs: "Filter bar: set, kind,
/// status"). `nil` in a field means "all"; the three compose with AND.
struct RunFilter: Equatable {
    var setId: UUID?
    var kind: RunKind?
    var status: RunStatus?

    var isActive: Bool { setId != nil || kind != nil || status != nil }

    func matches(_ row: RunRow) -> Bool {
        if let setId, row.setId != setId { return false }
        if let kind, row.kind != kind { return false }
        if let status, row.status != status { return false }
        return true
    }
}

// MARK: - Phases

/// Human wording for `CurrentRunState.phase`, which is free-form because
/// `copying-<destId>` embeds a destination id (`docs/data-model.md`
/// §state/current-run).
enum RunPhase {
    static func describe(_ phase: String) -> String {
        if phase.hasPrefix("copying") { return "copying to a mirror" }
        switch phase {
        case "probing": return "checking the repository"
        case "backing-up-primary": return "backing up"
        case "retention": return "applying retention"
        case "checking": return "verifying the repository"
        case "restoring": return "restoring"
        case "initializing": return "initializing the repository"
        default: return phase
        }
    }
}

// MARK: - Presentation of Core enums

extension RunKind {
    var label: String {
        switch self {
        case .backup: return "Backup"
        case .copy: return "Copy"
        case .check: return "Check"
        case .prune: return "Prune"
        case .restore: return "Restore"
        case .`init`: return "Initialize"
        }
    }

    var symbolName: String {
        switch self {
        case .backup: return "externaldrive.badge.timemachine"
        case .copy: return "doc.on.doc"
        case .check: return "checkmark.shield"
        case .prune: return "scissors"
        case .restore: return "arrow.uturn.backward"
        case .`init`: return "sparkles"
        }
    }
}

extension RunStatus {
    var label: String {
        switch self {
        case .success: return "Succeeded"
        case .warning: return "Warning"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .running: return "Running"
        }
    }

    var symbolName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        }
    }

    /// Semantic colours only — they read correctly in both appearances,
    /// which `docs/ui-spec.md` §Shell requires.
    var tint: Color {
        switch self {
        case .success: return .green
        case .warning: return .orange
        case .failed: return .red
        case .skipped: return .secondary
        case .running: return .accentColor
        }
    }

    /// What a run of this status did, one sentence, for the detail header.
    /// `.skipped` and `.warning` are the two that need explaining
    /// (T15 acceptance criteria: they must render distinctly *with reason*).
    var explanation: String? {
        switch self {
        case .skipped:
            return "Nothing ran: another operation for this backup set held the lock, "
                + "or the destination was not available."
        case .warning:
            return "The run finished, but restic reported problems — some files may not be in the snapshot."
        case .failed:
            return "The run did not finish."
        case .success, .running:
            return nil
        }
    }
}

// MARK: - Formatting

/// Formatters for the Runs screen. Built per call rather than cached in
/// statics: a `Formatter` is not `Sendable`, and the alternative
/// (main-actor-isolated statics) buys nothing measurable for a list capped
/// at 200 index entries.
enum RunFormat {

    /// "2 hours ago" (`docs/tasks/T15-runs-ui.md`: relative timestamps).
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The absolute timestamp shown on hover/tooltip next to every relative
    /// one, so "2 hours ago" is never the only thing the user can read.
    static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval, interval.isFinite, interval >= 0 else { return "—" }
        if interval < 1 { return "<1s" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: interval) ?? "—"
    }

    static func bytes(_ count: Int?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func count(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number)
    }
}

// MARK: - Badges

/// The status badge used in both the list and the detail header. Icon +
/// word, so status is never carried by colour alone.
struct RunStatusBadge: View {
    let status: RunStatus
    var compact = false

    var body: some View {
        Label {
            Text(status.label)
        } icon: {
            Image(systemName: status.symbolName)
        }
        .labelStyle(.titleAndIcon)
        .font(compact ? .caption : .callout)
        .foregroundStyle(status.tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(status.tint.opacity(0.12), in: Capsule())
        .accessibilityLabel(Text(status.label))
    }
}

/// Icon-only run-kind marker for the list's "kind icon" column; the word
/// itself is in the tooltip and in the detail header.
struct RunKindIcon: View {
    let kind: RunKind

    var body: some View {
        Image(systemName: kind.symbolName)
            .foregroundStyle(.secondary)
            .help(kind.label)
            .accessibilityLabel(Text(kind.label))
    }
}
