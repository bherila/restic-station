import ResticStationCore
import SwiftUI

/// The set list (`docs/ui-spec.md` §Backup Sets, **List**): name, source
/// count, primary destination label + kind icon, schedule summary, last run
/// status badge, next due time. Toolbar: add set, delete set. Empty state:
/// short explainer + "Create your first backup set".
///
/// `Table` rather than a hand-rolled `List` of `HStack`s: it gives real
/// column headers, resizing and keyboard selection for free, which is what
/// "table/list of sets" means on macOS.
struct SetListView: View {
    @EnvironmentObject private var model: AppModel

    @Binding var selection: UUID?
    let onCreate: () -> Void
    let onEdit: (UUID) -> Void

    /// The set the delete confirmation is about (`nil` = not shown).
    @State private var pendingDeletion: BackupSet?
    @State private var showingEffectivePlan = false

    var body: some View {
        Group {
            if model.config.sets.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .navigationTitle("Restic Station")
        .navigationSubtitle("Backup Sets")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    onCreate()
                } label: {
                    Label("Add Backup Set", systemImage: "plus")
                }
                .help("Create a backup set")

                Button {
                    if let selected = selectedSet {
                        pendingDeletion = selected
                    }
                } label: {
                    Label("Delete Backup Set", systemImage: "trash")
                }
                .disabled(selectedSet == nil)
                .help("Delete the selected backup set")

                Button {
                    showingEffectivePlan = true
                } label: {
                    Label("Effective Plan", systemImage: "desktopcomputer.and.macbook")
                }
                .help("Preview what each configured machine will back up")
            }
        }
        .sheet(isPresented: $showingEffectivePlan) {
            MachineEffectivePlanView(
                config: model.config,
                currentMachineID: model.machine.machineId
            )
        }
        .alert(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { set in
            Button("Delete", role: .destructive) { delete(set) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(SetsCopy.deleteSetConfirmation)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label(SetsCopy.emptyStateTitle, systemImage: "externaldrive.badge.plus")
        } description: {
            Text(SetsCopy.emptyStateExplainer)
        } actions: {
            Button(SetsCopy.createFirstSet) { onCreate() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(model.config.sets, selection: $selection) {
            TableColumn("Name") { set in
                Text(set.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Sources") { set in
                Text(SetsCopy.sourceCountText(set.sources.count))
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Primary destination") { set in
                primaryDestinationCell(set)
            }
            .width(min: 140, ideal: 200)

            TableColumn("Schedule") { set in
                Text(SetsCopy.scheduleSummary(set.schedule))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 140)

            TableColumn("Last backup") { set in
                if let health = model.setHealth(for: set.id) {
                    SetHealthBadge(health: health)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 110)

            TableColumn("Next due") { set in
                Text(nextDueText(for: set))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("When the background agent will next consider this set. "
                        + "Restic Station never runs backups itself.")
            }
            .width(min: 90, ideal: 120)

            TableColumn("") { set in
                Button {
                    onEdit(set.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Edit this backup set")
            }
            .width(28)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click opens the editor.
            if let id = ids.first { onEdit(id) }
        }
    }

    @ViewBuilder
    private func primaryDestinationCell(_ set: BackupSet) -> some View {
        if let primary = set.destinations.first(where: \.isPrimary) {
            HStack(spacing: 6) {
                Image(systemName: SetsCopy.kindSymbol(primary.kind))
                    .foregroundStyle(.secondary)
                Text(primary.label)
                    .lineLimit(1)
                StatusDot(status: model.destinationStatus(setId: set.id, destId: primary.id))
            }
        } else {
            Text("No primary destination")
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        if let id = ids.first, let set = model.config.sets.first(where: { $0.id == id }) {
            let backupUnavailableReason = model.backUpNowUnavailableReason(setId: id)
            Button("Edit…") { onEdit(id) }
            Button("Back Up Now") { model.backUpNow(setId: id) }
                .disabled(backupUnavailableReason != nil)
                .help(backupUnavailableReason ?? "Back up \(set.name) now.")
            Divider()
            Button("Delete…", role: .destructive) { pendingDeletion = set }
        }
    }

    // MARK: - Helpers

    private var selectedSet: BackupSet? {
        guard let selection else { return nil }
        return model.config.sets.first { $0.id == selection }
    }

    private func nextDueText(for set: BackupSet) -> String {
        guard let health = model.setHealth(for: set.id) else { return "—" }
        if health.isRunning { return "Running now" }
        return SetsCopy.nextDueText(health.nextDue)
    }

    private func delete(_ set: BackupSet) {
        pendingDeletion = nil
        if selection == set.id {
            selection = nil
        }
        // A failure here can only be an unreadable on-disk config, which
        // `AppModel` already surfaces through `lastConfigError`.
        try? model.deleteSet(id: set.id)
    }
}
