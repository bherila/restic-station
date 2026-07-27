import ResticStationCore
import SwiftUI

/// The Runs history (`docs/ui-spec.md` §Runs): newest-first, grouped by
/// `groupId` so a set run shows its backup with the copies and prunes it
/// spawned nested underneath; a filter bar that composes set + kind +
/// status; and a live progress bar for whatever is running right now.
///
/// The rows are derived outside `body` — `rebuild()` runs when the watcher
/// publishes, not on every redraw — because building them reads
/// `runs/<runId>/metadata.json` for each in-flight run (that is where an
/// in-flight run's `groupId` lives; it has no index line yet).
struct RunListView: View {
    @EnvironmentObject private var model: AppModel

    /// All groups, unfiltered. `RunFilter` is applied in `body` because it
    /// is pure and cheap; only the disk-reading half is cached here.
    @State private var groups: [RunGroup] = []
    @State private var filter = RunFilter()
    @State private var expandedGroupIds: Set<String> = []
    /// Groups already auto-expanded once because they were running, so a
    /// deliberate collapse is not undone by the next watcher event.
    @State private var autoExpandedGroupIds: Set<String> = []

    var body: some View {
        // Filtering is pure and cheap, but it is needed by three subviews —
        // apply it once per redraw and hand the result down.
        let visibleGroups = RunHistory.filter(groups, with: filter)
        VStack(spacing: 0) {
            filterBar(visibleGroups: visibleGroups)
            Divider()
            helperMessageBanner
            content(visibleGroups: visibleGroups)
        }
        .navigationTitle("Restic Station")
        .navigationSubtitle("Runs")
        .toolbar { backUpNowMenu }
        .onAppear {
            model.start()
            model.refresh()
            rebuild()
        }
        .onChange(of: model.recentRuns) { _, _ in rebuild() }
        .onChange(of: model.currentRuns) { _, _ in rebuild() }
    }

    // MARK: - Derived rows

    /// Groups flattened to one element per rendered row, so every element of
    /// the list's `ForEach` is exactly one row (nesting is expressed by
    /// `indent`, not by nested containers).
    private func visibleRows(in visibleGroups: [RunGroup]) -> [VisibleRow] {
        visibleGroups.flatMap { group -> [VisibleRow] in
            let isExpanded = expandedGroupIds.contains(group.id)
            let root = VisibleRow(
                row: group.root,
                indent: 0,
                childCount: group.children.count,
                isExpanded: isExpanded
            )
            guard isExpanded else { return [root] }
            return [root] + group.children.map {
                VisibleRow(row: $0, indent: RunColumn.indent, childCount: 0, isExpanded: false)
            }
        }
    }

    private func rebuild() {
        let live = RunHistory.liveRows(currentRuns: model.currentRuns) { runId in
            model.runMetadata(runId: runId)
        }
        let rebuilt = RunHistory.groups(indexEntries: model.recentRuns, liveRows: live)
        if rebuilt != groups { groups = rebuilt }

        // A run in flight is the one thing the user is most likely to want
        // opened; expanding it also keeps its children visible as they
        // finish one by one. Only once per group, so collapsing it again
        // sticks.
        for group in rebuilt where group.isRunning && autoExpandedGroupIds.insert(group.id).inserted {
            expandedGroupIds.insert(group.id)
        }
    }

    // MARK: - Filter bar

    private func filterBar(visibleGroups: [RunGroup]) -> some View {
        HStack(spacing: 12) {
            Picker("Set", selection: $filter.setId) {
                Text("All sets").tag(UUID?.none)
                ForEach(model.config.sets) { set in
                    Text(set.name).tag(UUID?.some(set.id))
                }
            }
            .frame(maxWidth: 190)

            Picker("Kind", selection: $filter.kind) {
                Text("All kinds").tag(RunKind?.none)
                ForEach(RunKind.allCases, id: \.self) { kind in
                    Label(kind.label, systemImage: kind.symbolName).tag(RunKind?.some(kind))
                }
            }
            .frame(maxWidth: 165)

            Picker("Status", selection: $filter.status) {
                Text("All statuses").tag(RunStatus?.none)
                ForEach(Self.filterableStatuses, id: \.self) { status in
                    Text(status.label).tag(RunStatus?.some(status))
                }
            }
            .frame(maxWidth: 165)

            if filter.isActive {
                Button("Clear Filters") { filter = RunFilter() }
                    .help("Show every run again.")
            }

            Spacer(minLength: 0)

            Text(runCountSummary(visibleGroups: visibleGroups))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private static let filterableStatuses: [RunStatus] = [.running, .success, .warning, .skipped, .failed]

    private func runCountSummary(visibleGroups: [RunGroup]) -> String {
        let shown = visibleGroups.reduce(0) { $0 + $1.rows.count }
        let total = groups.reduce(0) { $0 + $1.rows.count }
        if shown == total {
            return total == 1 ? "1 run" : "\(total) runs"
        }
        return "\(shown) of \(total) runs"
    }

    // MARK: - Content

    @ViewBuilder
    private func content(visibleGroups: [RunGroup]) -> some View {
        if groups.isEmpty {
            ContentUnavailableView {
                Label("No runs yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Backups you start with Back Up Now — and the ones the background agent runs on schedule — appear here with their logs.")
            }
        } else if visibleGroups.isEmpty {
            ContentUnavailableView {
                Label("No matching runs", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No run matches every filter. Change one, or clear them to see the whole history.")
            } actions: {
                Button("Clear Filters") { filter = RunFilter() }
            }
        } else {
            runList(visibleGroups: visibleGroups)
        }
    }

    private func runList(visibleGroups: [RunGroup]) -> some View {
        List {
            Section {
                ForEach(visibleRows(in: visibleGroups)) { visible in
                    row(for: visible)
                }
            } header: {
                RunColumnHeader()
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private func row(for visible: VisibleRow) -> some View {
        HStack(spacing: 4) {
            disclosureControl(for: visible)
            NavigationLink(value: visible.row.runId) {
                RunRowContent(
                    row: visible.row,
                    indent: visible.indent,
                    setName: model.setName(for: visible.row.setId),
                    destinationLabel: model.destinationLabel(setId: visible.row.setId, destId: visible.row.destId)
                )
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func disclosureControl(for visible: VisibleRow) -> some View {
        if visible.childCount > 0 {
            Button {
                toggle(groupId: visible.row.groupId)
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(visible.isExpanded ? 90 : 0))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: RunColumn.disclosure, height: RunColumn.disclosure)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(visible.isExpanded
                ? "Hide the copies and cleanups that ran with this backup."
                : "Show the \(visible.childCount) run\(visible.childCount == 1 ? "" : "s") that ran with this backup.")
            .accessibilityLabel(Text(visible.isExpanded ? "Collapse group" : "Expand group"))
        } else {
            Color.clear.frame(width: RunColumn.disclosure, height: RunColumn.disclosure)
        }
    }

    private func toggle(groupId: String) {
        if expandedGroupIds.contains(groupId) {
            expandedGroupIds.remove(groupId)
        } else {
            expandedGroupIds.insert(groupId)
        }
    }

    // MARK: - Helper feedback

    @ViewBuilder
    private var helperMessageBanner: some View {
        if let message = model.lastHelperMessage, message.isError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message.text)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Dismiss") { model.clearLastHelperMessage() }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
            Divider()
        }
    }

    // MARK: - Toolbar

    /// "Back Up Now (per-set picker or context), disabled with explanation
    /// while that set is busy" (`docs/ui-spec.md` §Runs). The explanation is
    /// on the item itself, since disabling is per set.
    private var backUpNowMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(model.config.sets) { set in
                    let reason = model.backUpNowUnavailableReason(setId: set.id)
                    Button(set.name) { model.backUpNow(setId: set.id) }
                        .disabled(reason != nil)
                        .help(reason ?? "Back up \(set.name) now.")
                }
            } label: {
                Label("Back Up Now", systemImage: "externaldrive.badge.timemachine")
            }
            .menuStyle(.borderlessButton)
            .disabled(model.config.sets.isEmpty)
            .help(model.config.sets.isEmpty
                ? "There are no backup sets yet. Create one in Backup Sets first."
                : "Run a backup set now. Scheduled runs are unaffected.")
        }
    }
}

// MARK: - VisibleRow

/// One rendered line: a run plus how it should be indented and whether it
/// owns an expandable group.
private struct VisibleRow: Identifiable {
    let row: RunRow
    let indent: CGFloat
    let childCount: Int
    let isExpanded: Bool

    var id: String { row.runId }
}

// MARK: - Columns

/// Shared column widths, so the header and every row (nested or not) line
/// up. Nesting eats into the first column only — see `RunRowContent`.
private enum RunColumn {
    static let disclosure: CGFloat = 16
    static let time: CGFloat = 124
    static let set: CGFloat = 112
    static let kind: CGFloat = 22
    static let status: CGFloat = 104
    static let duration: CGFloat = 62
    static let dataAdded: CGFloat = 82
    static let spacing: CGFloat = 8
    static let indent: CGFloat = 22

    /// The progress bar replaces the duration + data-added columns while a
    /// run is in flight — neither is known yet.
    static var progress: CGFloat { duration + dataAdded + spacing }
}

private struct RunColumnHeader: View {
    var body: some View {
        HStack(spacing: RunColumn.spacing) {
            Color.clear.frame(width: RunColumn.disclosure + 4, height: 1)
            Text("Time").frame(width: RunColumn.time, alignment: .leading)
            Text("Set").frame(width: RunColumn.set, alignment: .leading)
            Text("Kind").frame(width: RunColumn.kind, alignment: .leading)
            Text("Destination").frame(maxWidth: .infinity, alignment: .leading)
            Text("Status").frame(width: RunColumn.status, alignment: .leading)
            Text("Duration").frame(width: RunColumn.duration, alignment: .trailing)
            Text("Data added").frame(width: RunColumn.dataAdded, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Row content

/// The columns of one run row. Everything except the first column keeps a
/// fixed width regardless of nesting, so a child row stays aligned with its
/// parent's columns while still reading as nested.
private struct RunRowContent: View {
    let row: RunRow
    let indent: CGFloat
    let setName: String
    let destinationLabel: String

    var body: some View {
        HStack(spacing: RunColumn.spacing) {
            timeCell
            Text(setName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: RunColumn.set, alignment: .leading)
            RunKindIcon(kind: row.kind)
                .frame(width: RunColumn.kind, alignment: .leading)
            Text(destinationLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            RunStatusBadge(status: row.status, compact: true)
                .frame(width: RunColumn.status, alignment: .leading)
                // Why a run was skipped, warned, or failed is one hover away
                // in the list, and spelled out in the detail header.
                .help(statusHelp)
            if let live = row.live {
                progressCell(live)
            } else {
                Text(RunFormat.duration(row.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: RunColumn.duration, alignment: .trailing)
                Text(RunFormat.bytes(row.dataAdded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: RunColumn.dataAdded, alignment: .trailing)
            }
        }
        .font(.callout)
        .contentShape(Rectangle())
    }

    private var statusHelp: String {
        if let reason = row.errorSummary, !reason.isEmpty {
            return "\(row.status.label): \(reason)"
        }
        if let explanation = row.status.explanation {
            return "\(row.status.label). \(explanation)"
        }
        return row.status.label
    }

    private var timeCell: some View {
        Text(RunFormat.relative(row.start))
            .lineLimit(1)
            .help(RunFormat.absolute(row.start))
            .padding(.leading, indent)
            .frame(width: RunColumn.time, alignment: .leading)
    }

    /// Determinate while restic knows the total size; indeterminate before
    /// the scan has produced one (`totalBytes == 0`), because a bar pinned
    /// at 0 % would read as "stuck" rather than "still measuring".
    @ViewBuilder
    private func progressCell(_ live: CurrentRunState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if live.totalBytes > 0 {
                ProgressView(value: min(max(live.percentDone, 0), 1))
                    .progressViewStyle(.linear)
                Text("\(RunFormat.bytes(live.bytesDone)) of \(RunFormat.bytes(live.totalBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                Text(RunPhase.describe(live.phase))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: RunColumn.progress)
        .help(liveHelp(live))
    }

    private func liveHelp(_ live: CurrentRunState) -> String {
        var parts = ["Running — \(RunPhase.describe(live.phase))"]
        if live.totalFiles > 0 {
            parts.append("\(RunFormat.count(live.filesDone)) of \(RunFormat.count(live.totalFiles)) files")
        }
        if let file = live.currentFiles.first {
            parts.append(file)
        }
        return parts.joined(separator: " · ")
    }
}
