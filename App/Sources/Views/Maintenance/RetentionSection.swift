import ResticStationCore
import SwiftUI

/// Retention (`docs/ui-spec.md` §Maintenance): the set's policy, a
/// **Preview cleanup** that renders `forget --dry-run` as a keep/remove
/// table, **Apply retention now**, and a retention-independent **Reclaim
/// space** action for packs left behind by a purge rewrite.
///
/// The two halves are deliberately asymmetric, because only one of them
/// deletes anything:
///
/// - The preview is an app-direct `forget --json --dry-run`
///   (`docs/architecture.md`'s read-only exception). It writes nothing and
///   produces no run record.
/// - Apply runs a **fresh** dry-run of its own, quotes those counts in the
///   confirmation, and then hands the real work to the helper
///   (`run-set --kind prune`). The numbers the user agrees to are therefore
///   never the ones from a preview taken minutes ago against a repository
///   that has since gained snapshots.
struct RetentionSection: View {
    @EnvironmentObject private var model: AppModel
    let backupSet: BackupSet
    @ObservedObject var maintenance: MaintenanceModel

    private var hasPolicy: Bool {
        guard let retention = backupSet.retention else { return false }
        return !retention.isEmpty
    }

    /// **Apply retention now** goes through `run-set --kind prune`, which
    /// resolves the *scheduling* view. A set disabled on this machine is not
    /// in that view at all, so the helper would refuse — better to say so
    /// than to offer a destructive button that cannot work.
    private var runsOnThisMachine: Bool {
        MaintenanceModel.scheduledSet(model, id: backupSet.id) != nil
    }

    private var isPruning: Bool {
        maintenance.isBusy(.prune(setId: backupSet.id))
    }

    /// Manual retention apply is contained — see
    /// ``ManualRetentionApplyAvailability``. The helper and Core both refuse
    /// independently, so this only spares the operator a dialog that would
    /// end in a refusal; it is not what enforces the posture.
    private var canApplyRetention: Bool {
        ManualRetentionApplyAvailability.isEnabled
    }

    private var applyRetentionHelp: String {
        // Machine scope first. Containment's explanation promises that
        // scheduled retention will do the work instead, and for a set this
        // machine does not run, no tick here ever will — so the more
        // fundamental fact has to win.
        if !runsOnThisMachine {
            return "This backup set does not run on this machine, so retention cannot be applied here."
        }
        if !hasPolicy {
            return "This backup set has no retention policy, so nothing is ever removed — "
                + "scheduled runs included. Add one in Backup Sets to enable cleanup."
        }
        if !canApplyRetention { return ManualRetentionApplyAvailability.reason }
        return "Runs the retention policy. It permanently deletes snapshots the policy no longer keeps."
    }

    private var hasICloudRepository: Bool {
        backupSet.destinations.contains(where: MaintenanceModel.isICloudRepository)
    }

    var body: some View {
        MaintenanceSection(
            "Retention",
            systemImage: "calendar.badge.clock",
            caption: "Retention decides which snapshots are kept. Cleaning up applies the policy and then "
                + "prunes the repository, which is what actually frees space. It is applied to the primary "
                + "after each backup, and mirrored to each secondary after it syncs."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                policySummary
                actions
                previewResult
                purgePlan
            }
        }
        .alert(
            maintenance.prunePlan?.confirmationTitle ?? "Confirm maintenance?",
            isPresented: confirmationBinding,
            presenting: maintenance.prunePlan
        ) { plan in
            Button(plan.confirmationButton, role: .destructive) {
                maintenance.confirmApplyRetention(plan, in: model)
            }
            .disabled(!plan.canConfirm)
            Button("Cancel", role: .cancel) {
                maintenance.cancelApplyRetention()
            }
        } message: { plan in
            Text(plan.confirmationMessage)
        }
    }

    // MARK: - Policy

    private var policySummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: hasPolicy ? "checklist" : "infinity")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(MaintenanceFormat.retentionSummary(backupSet.retention))
                    .font(.body)
            }
            // "edit jumps to set editor" — named rather than linked: the
            // sidebar's selection is `MainWindow`'s private state, and the
            // Backup Sets screen owns its own routing.
            Text("Edit this policy in Backup Sets ▸ \(backupSet.name) ▸ Retention.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    maintenance.previewCleanup(for: backupSet, in: model)
                } label: {
                    if case .loading = maintenance.retentionPreview {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Preview cleanup")
                        }
                    } else {
                        Label("Preview cleanup", systemImage: "eye")
                    }
                }
                .disabled(!hasPolicy || isPreviewing || maintenance.isPreparingPrune)
                .help("Preview is read-only. It does not change snapshots or pack storage.")

                Button {
                    maintenance.prepareApplyRetention(for: backupSet, in: model)
                } label: {
                    if maintenance.isPreparingPrune || isPruning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(isPruning ? "Cleaning up…" : "Checking…")
                        }
                    } else {
                        Label("Apply retention now", systemImage: "trash")
                    }
                }
                .disabled(!hasPolicy || !runsOnThisMachine || !canApplyRetention || isPruning
                    || maintenance.isPreparingPrune || isPreviewing)
                .help(applyRetentionHelp)

                Menu {
                    ForEach(backupSet.destinations) { destination in
                        Button {
                            maintenance.prepareReclaimSpace(for: backupSet, destination: destination, in: model)
                        } label: {
                            Text(destination.isPrimary ? "\(destination.label) (Primary)" : destination.label)
                        }
                    }
                } label: {
                    if maintenance.isPreparingPrune || isPruning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(isPruning ? "Reclaiming…" : "Checking…")
                        }
                    } else {
                        Label("Reclaim space", systemImage: "externaldrive.badge.minus")
                    }
                }
                .disabled(backupSet.destinations.isEmpty || isPruning || maintenance.isPreparingPrune || isPreviewing)
                .help("Checks and prunes the selected repository. It frees unreferenced pack data without changing retention.")

                Spacer(minLength: 0)
            }
            // Only claim scheduled cleanup where a scheduled run will
            // actually do it: this machine must run the set, and there must
            // be a policy for `forgetChild` to apply.
            if !canApplyRetention, hasPolicy, runsOnThisMachine {
                // Visible, not just a tooltip on a disabled button: the
                // operator needs to know retention is still happening on
                // schedule, or they will reasonably assume it stopped.
                Label(
                    ManualRetentionApplyAvailability.reason,
                    systemImage: "clock.badge.checkmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if hasICloudRepository {
                Label(
                    "This repository is in iCloud Drive. Before reclaiming space, fully download every repository file; evicted Optimize Mac Storage placeholders can make restic stall or fail while it rewrites pack files.",
                    systemImage: "icloud.and.arrow.down"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isPreviewing: Bool {
        if case .loading = maintenance.retentionPreview { return true }
        return false
    }

    /// `.alert(_:isPresented:presenting:)` needs a `Bool` binding; the plan
    /// itself is the source of truth, and dismissing it (Escape, clicking
    /// away) must cancel rather than silently leave a stale plan armed.
    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { maintenance.prunePlan != nil },
            set: { isPresented in
                if !isPresented { maintenance.cancelApplyRetention() }
            }
        )
    }

    // MARK: - Preview result

    @ViewBuilder
    private var previewResult: some View {
        switch maintenance.retentionPreview {
        case .idle:
            EmptyView()
        case .loading:
            Text("Asking each destination which snapshots the policy would remove…")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .ready(let previews, let at):
            VStack(alignment: .leading, spacing: 12) {
                Text("Dry run at \(MaintenanceFormat.absolute(at)) — nothing has been deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(previews) { preview in
                    ForgetPreviewTable(preview: preview)
                }
            }
        }
    }

    @ViewBuilder
    private var purgePlan: some View {
        if backupSet.purgeExcludes.isEmpty {
            EmptyView()
        } else {
            let applied = model.stateWatcher.scheduleState?.sets[backupSet.id]?.appliedPurgeExcludes ?? [:]
            let pendingDestinations = backupSet.destinations.filter { destination in
                Set(applied[destination.id] ?? []).isSuperset(of: Set(backupSet.purgeExcludes)) == false
            }
            if pendingDestinations.isEmpty {
                EmptyView()
            } else {
                let destinationLabels = pendingDestinations.map(\.label).joined(separator: ", ")
                VStack(alignment: .leading, spacing: 6) {
                    Label("Purge exclusions", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(
                        "\(backupSet.purgeExcludes.count) purge exclusion\(backupSet.purgeExcludes.count == 1 ? "" : "s") "
                            + "remain pending for \(destinationLabels). "
                            + "The next safe purge rewrites matching historical snapshots before a mirror copy. Rewriting removes their file data; run Reclaim space afterwards to free unused pack storage."
                    )
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - ForgetPreviewTable

/// One destination's keep/remove table, built from `ForgetResult` (T05).
struct ForgetPreviewTable: View {
    let preview: DestinationForgetPreview

    /// Enough rows to see the shape of the policy without turning the
    /// section into an endless list; the counts above always describe the
    /// full result.
    private static let rowLimit = 25

    private var rows: [ForgetPreviewRow] {
        let keepRows = preview.keep.map { ForgetPreviewRow(snapshot: $0, isRemoved: false) }
        let removeRows = preview.remove.map { ForgetPreviewRow(snapshot: $0, isRemoved: true) }
        return (keepRows + removeRows)
            .sorted { $0.time > $1.time }
            .prefix(Self.rowLimit)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(preview.label)
                    .font(.subheadline.weight(.semibold))
                if preview.isPrimary {
                    Text("PRIMARY")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if preview.failure == nil {
                    Text("\(preview.keepCount) keep · \(preview.removeCount) remove")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let failure = preview.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if rows.isEmpty {
                Text("This repository has no snapshots yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                grid
                if preview.keepCount + preview.removeCount > Self.rowLimit {
                    Text("Showing the \(Self.rowLimit) newest snapshots of "
                        + "\(preview.keepCount + preview.removeCount).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// A `Grid`, not a `Table`: this sits inside the screen's `ScrollView`,
    /// and a `Table` brings its own scroller — nesting the two means a
    /// two-finger scroll over the snapshot list stops moving the page, which
    /// is exactly the kind of thing that feels broken. A grid is a plain
    /// laid-out block, so the outer scroll view stays in charge.
    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Snapshot")
                Text("Taken")
                Text("Paths")
                Text("Action")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider().gridCellUnsizedAxes(.horizontal)

            ForEach(rows) { row in
                GridRow {
                    Text(row.shortId)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Text(MaintenanceFormat.absolute(row.time))
                        .font(.callout)
                        .monospacedDigit()
                    Text(row.paths)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.paths)
                    Label(
                        row.isRemoved ? "Remove" : "Keep",
                        systemImage: row.isRemoved ? "trash" : "checkmark"
                    )
                    .font(.callout)
                    .foregroundStyle(row.isRemoved ? Color.orange : Color.secondary)
                }
            }
        }
    }
}

/// A row in the keep/remove table. `Snapshot` (Core) is `Decodable` but not
/// `Identifiable`; this wrapper adds the identity `ForEach` needs and
/// flattens the fields it shows.
struct ForgetPreviewRow: Identifiable {
    let id: String
    let shortId: String
    let time: Date
    let paths: String
    let isRemoved: Bool

    init(snapshot: Snapshot, isRemoved: Bool) {
        // A snapshot can legitimately appear in both a `keep` and a `remove`
        // group of different policy groups, so the disposition is part of
        // the identity.
        self.id = "\(snapshot.id)-\(isRemoved ? "remove" : "keep")"
        self.shortId = snapshot.shortId
        self.time = snapshot.time
        self.paths = snapshot.paths.joined(separator: ", ")
        self.isRemoved = isRemoved
    }
}
