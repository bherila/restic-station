import ResticStationCore
import SwiftUI

/// The Restore screen (`docs/ui-spec.md` §Restore).
///
/// Flow, left to right: pick a repository (grouped "Set ▸ Destination",
/// secondaries included) → pick a snapshot → browse the lazy tree or search
/// it → select files/folders → Restore.
///
/// Browsing (`snapshots`, `ls`, `find`) runs restic directly from the app —
/// the read-only exception in `docs/architecture.md`. The restore itself
/// goes through the helper (`RestoreSheet`).
struct RestoreView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var browser = RestoreBrowser()
    @StateObject private var mounts = MountController()

    @State private var selectedRepositoryID: UUID?
    @State private var selectedSnapshotID: String?
    @State private var searchText = ""
    @State private var searchAllSnapshots = false
    @State private var browserSelection: Set<String> = []
    @State private var searchSelection: Set<String> = []
    @State private var isShowingRestoreSheet = false

    var body: some View {
        Group {
            if model.restoreRepositories.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to restore from yet", systemImage: "arrow.uturn.backward.circle")
                } description: {
                    Text("Create a backup set with a destination first — every repository you back up to "
                        + "can be browsed and restored from here.")
                }
            } else if model.resticPath == nil {
                ContentUnavailableView {
                    Label("restic is not configured", systemImage: "terminal")
                } description: {
                    Text("Restic Station needs the restic binary to read your snapshots. "
                        + "Set its location in Settings.")
                }
            } else {
                content
            }
        }
        .navigationTitle("Restic Station")
        .navigationSubtitle("Restore")
        .onAppear(perform: activateSelection)
        .onChange(of: model.config) { _, _ in activateSelection() }
        .onChange(of: selectedRepositoryID) { _, _ in repositoryChanged() }
        .onChange(of: browser.snapshots) { _, snapshots in
            // Newest first — land on the most recent snapshot, which is
            // what a restore almost always wants.
            if selectedSnapshotID == nil || !snapshots.contains(where: { $0.id == selectedSnapshotID }) {
                selectedSnapshotID = snapshots.first?.id
            }
        }
        .sheet(isPresented: $isShowingRestoreSheet) {
            if let repository, let snapshotID = restoreSnapshotID {
                RestoreSheet(
                    repository: repository,
                    snapshotID: snapshotID,
                    snapshotDescription: snapshotDescription(for: snapshotID),
                    items: selectedItems
                )
                // Re-injected explicitly rather than relying on the sheet
                // inheriting the presenter's environment.
                .environmentObject(model)
                .environmentObject(model.stateWatcher)
            }
        }
    }

    // MARK: - Layout

    private var content: some View {
        VStack(spacing: 0) {
            repositoryPicker
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    snapshotList
                    Divider()
                    MountSection(repository: repository, mounts: mounts)
                        .padding(12)
                }
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 460)

                VStack(spacing: 0) {
                    searchBar
                    Divider()
                    browserPane
                    Divider()
                    selectionBar
                }
                .frame(minWidth: 360)
            }
        }
    }

    // MARK: - Repository picker

    private var repositoryPicker: some View {
        HStack(spacing: 12) {
            Picker("Restore from", selection: $selectedRepositoryID) {
                // Section headers only, but taken from the same view the
                // repositories themselves come from, so the two can never
                // disagree about which sets exist here.
                ForEach(model.addressableConfig.config.sets) { set in
                    Section(set.name) {
                        ForEach(repositories(in: set)) { repository in
                            Text(repository.destination.label
                                + (repository.isPrimary ? " (primary)" : ""))
                                .tag(Optional(repository.id))
                        }
                    }
                }
            }
            .frame(maxWidth: 420)

            // The picker groups by set; this spells out the full
            // "Set ▸ Destination" identity of the current choice, which the
            // closed menu alone does not show.
            if let repository {
                Text(repository.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if browser.isLoadingSnapshots {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                browser.loadSnapshots(force: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-read the snapshot list from this repository.")
        }
        .padding(12)
    }

    private func repositories(in set: BackupSet) -> [RestoreRepository] {
        model.restoreRepositories.filter { $0.setId == set.id }
    }

    // MARK: - Snapshots

    @ViewBuilder
    private var snapshotList: some View {
        if let message = browser.snapshotsError {
            ContentUnavailableView {
                Label("Snapshots could not be read", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { browser.loadSnapshots(force: true) }
            }
            .frame(maxHeight: .infinity)
        } else if browser.snapshots.isEmpty {
            ContentUnavailableView {
                Label(browser.isLoadingSnapshots ? "Reading snapshots…" : "No snapshots", systemImage: "clock")
            } description: {
                Text(browser.isLoadingSnapshots
                    ? "Asking restic for this repository's snapshots."
                    : "This repository has no snapshots yet.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List(browser.snapshots, id: \.id, selection: $selectedSnapshotID) { snapshot in
                snapshotRow(snapshot)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func snapshotRow(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(snapshot.time.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                Text(snapshot.shortId)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                if snapshot.original != nil {
                    // `original` is stamped by `restic copy` on a mirrored
                    // snapshot (docs/restic-cli.md §snapshots).
                    Text("mirrored")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .help("Copied here from another repository in the same backup set.")
                }
            }
            Text(snapshot.paths.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            if let dataAdded = snapshot.summary?.dataAdded {
                Text("\(dataAdded.formatted(.byteCount(style: .file))) added")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search this snapshot (e.g. report*.pdf)", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit(runSearch)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchSelection = []
                        browser.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Toggle("Search all snapshots", isOn: $searchAllSnapshots)
                .toggleStyle(.checkbox)
                .onChange(of: searchAllSnapshots) { _, _ in
                    if !searchText.isEmpty { runSearch() }
                }
            Button("Search", action: runSearch)
                .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    private func runSearch() {
        searchSelection = []
        browser.search(
            pattern: searchText,
            snapshotID: selectedSnapshotID,
            allSnapshots: searchAllSnapshots
        )
    }

    // MARK: - Browser / results

    @ViewBuilder
    private var browserPane: some View {
        if isSearching {
            SearchResultsView(
                rows: searchRows,
                state: browser.searchState,
                snapshotLabel: snapshotLabel,
                selection: $searchSelection
            )
            .frame(maxHeight: .infinity)
        } else if let snapshot = selectedSnapshot {
            SnapshotBrowserView(
                browser: browser,
                snapshot: snapshot,
                selection: $browserSelection
            )
            .frame(maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Choose a snapshot", systemImage: "sidebar.left")
            } description: {
                Text("Pick a snapshot on the left to browse the files it contains.")
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Selection bar

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(selectionDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let warning = selectionWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Restore…") { isShowingRestoreSheet = true }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedItems.isEmpty || restoreSnapshotID == nil || selectionWarning != nil)
        }
        .padding(12)
    }

    private var selectionDescription: String {
        let count = selectedItems.count
        switch count {
        case 0: return "Select files or folders to restore."
        case 1: return "1 item selected"
        default: return "\(count) items selected"
        }
    }

    /// Search can span snapshots; one restore call names exactly one
    /// snapshot, so a mixed selection is refused with an explanation rather
    /// than silently restoring from one of them.
    private var selectionWarning: String? {
        guard isSearching, !searchSelection.isEmpty else { return nil }
        let snapshotIDs = Set(searchRows.filter { searchSelection.contains($0.id) }.map(\.snapshotID))
        return snapshotIDs.count > 1
            ? "Select results from a single snapshot — a restore reads one snapshot at a time."
            : nil
    }

    // MARK: - Derived state

    private var repository: RestoreRepository? {
        model.restoreRepository(id: selectedRepositoryID)
    }

    private var selectedSnapshot: Snapshot? {
        browser.snapshots.first { $0.id == selectedSnapshotID }
    }

    private var isSearching: Bool {
        browser.searchState != .idle
    }

    private var searchRows: [SearchRow] {
        SearchRow.rows(from: browser.searchResults)
    }

    private var selectedItems: [RestoreItem] {
        if isSearching {
            return searchRows
                .filter { searchSelection.contains($0.id) }
                .map(\.item)
        }
        guard let snapshotID = selectedSnapshotID else { return [] }
        return browserSelection
            .compactMap { browser.node(snapshotID: snapshotID, path: $0) }
            .map { RestoreItem(path: $0.path, isDirectory: $0.type == .dir) }
            .sorted { $0.path < $1.path }
    }

    /// The snapshot a restore would read: the selected one when browsing,
    /// the results' own snapshot when restoring from a search.
    private var restoreSnapshotID: String? {
        if isSearching {
            let ids = Set(searchRows.filter { searchSelection.contains($0.id) }.map(\.snapshotID))
            return ids.count == 1 ? ids.first : nil
        }
        return selectedSnapshotID
    }

    private func snapshotLabel(_ snapshotID: String) -> String {
        guard let snapshot = browser.snapshots.first(where: { $0.id == snapshotID }) else {
            return String(snapshotID.prefix(8))
        }
        return snapshot.shortId
    }

    private func snapshotDescription(for snapshotID: String) -> String {
        guard let snapshot = browser.snapshots.first(where: { $0.id == snapshotID }) else {
            return "Snapshot \(String(snapshotID.prefix(8)))"
        }
        return "Snapshot \(snapshot.shortId) · \(snapshot.time.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Selection lifecycle

    private func activateSelection() {
        if selectedRepositoryID == nil || model.restoreRepository(id: selectedRepositoryID) == nil {
            selectedRepositoryID = model.restoreRepositories.first?.id
        }
        configureBrowser()
    }

    private func repositoryChanged() {
        selectedSnapshotID = nil
        browserSelection = []
        searchSelection = []
        searchText = ""
        configureBrowser()
    }

    private func configureBrowser() {
        do {
            browser.configure(repository: repository, runner: try model.makeBrowsingRunner())
        } catch {
            // Secret storage is misconfigured (a mistyped
            // RESTIC_STATION_SECRET_BACKEND). Say so here rather than letting
            // the pane fall through to "No snapshots", which would look like
            // an empty repository.
            browser.configure(
                repository: repository,
                runner: nil,
                unavailableReason: "Secret storage is misconfigured, so this repository's password "
                    + "cannot be read: \(error). Fix \(SecretBackend.environmentKey), then try again."
            )
        }
        browser.loadSnapshots()
    }
}
