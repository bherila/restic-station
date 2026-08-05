import ResticStationCore
import SwiftUI

/// The Maintenance screen (`docs/ui-spec.md` §Maintenance): one backup set at
/// a time, chosen with the header picker, then four sections — repository
/// size, retention, integrity, staleness — and the stale-lock footer utility.
///
/// Layout is a scrolling column of cards rather than a `Form`: three of the
/// four sections carry a table or a per-destination grid, which a `Form`'s
/// label/value column would squeeze. The header stays outside the
/// `ScrollView` so the "which set am I looking at" answer never scrolls away.
struct MaintenanceView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var maintenance: MaintenanceModel

    var body: some View {
        Group {
            if let set = maintenance.resolvedSet(in: model) {
                content(for: set)
            } else {
                ContentUnavailableView {
                    Label("Maintenance", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text("Create a backup set first. Repository size, retention, integrity checks and "
                        + "staleness are all reported per set.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Restic Station")
        .navigationSubtitle("Maintenance")
        .onAppear { model.refresh() }
    }

    // MARK: - Content

    private func content(for set: BackupSet) -> some View {
        VStack(spacing: 0) {
            header(for: set)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let activity = maintenance.activity {
                        MaintenanceBanner(activity: activity) {
                            maintenance.dismissActivity()
                        }
                    }
                    sizeSection(for: set)
                    RetentionSection(backupSet: set, maintenance: maintenance)
                    IntegritySection(backupSet: set, maintenance: maintenance)
                    StalenessSection(backupSet: set)
                    UnlockFooter(backupSet: set, maintenance: maintenance)
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        // Re-read `stats` for whatever set is now on screen, from cache when
        // it is already known (`force: false` never re-runs restic).
        .task(id: set.id) {
            maintenance.loadSizes(for: set, in: model)
        }
    }

    private func header(for set: BackupSet) -> some View {
        HStack(spacing: 12) {
            // The same view `MaintenanceLookup.set` resolves the selection
            // against, so the picker cannot offer a set the screen then
            // fails to find.
            Picker("Backup set", selection: setSelection) {
                ForEach(model.addressableConfig.config.sets) { candidate in
                    Text(candidate.name).tag(candidate.id)
                }
            }
            .fixedSize()
            .disabled(model.addressableConfig.config.sets.count <= 1)

            Spacer(minLength: 0)

            if maintenance.isAnyActionRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// The picker's selection is stored as an optional on the model (nothing
    /// is selected before the first render), but a `Picker` wants a
    /// non-optional tag; this binding resolves the two. The fallback is a
    /// fixed constant rather than a fresh `UUID()`: a getter that returns a
    /// new value each time it is read matches no tag and never settles.
    private var setSelection: Binding<UUID> {
        Binding(
            get: { maintenance.resolvedSet(in: model)?.id ?? Self.noSelection },
            set: { maintenance.selectedSetId = $0 }
        )
    }

    private static let noSelection = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: - Repository size

    private func sizeSection(for set: BackupSet) -> some View {
        MaintenanceSection(
            "Repository size",
            systemImage: "internaldrive",
            caption: "\"On disk\" is what the repository actually occupies after restic deduplicates and "
                + "compresses. \"Protected data\" is the size everything in the snapshots would have if "
                + "restored — normally much larger.",
            accessory: {
                Button {
                    maintenance.loadSizes(for: set, in: model, force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(set.destinations.contains { maintenance.sizes[$0.id]?.isLoading == true })
            },
            content: {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(set.destinations) { destination in
                        RepositorySizeCard(
                            destination: destination,
                            state: maintenance.sizes[destination.id] ?? .idle
                        ) {
                            maintenance.loadSizes(for: destination, in: model, force: true)
                        }
                    }
                }
            }
        )
    }
}

// MARK: - RepositorySizeCard

/// One destination's `stats` card. The two numbers come from the two
/// documented `stats` modes (`docs/restic-cli.md` §stats), run app-direct
/// under the read-only exception in `docs/architecture.md`.
struct RepositorySizeCard: View {
    let destination: Destination
    let state: SizeState
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DestinationTitle(destination: destination)
            Text(destination.repoURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Divider()

            switch state {
            case .idle:
                Text("Not measured yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .loaded(let sizes):
                measurements(sizes)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again", action: onRetry)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func measurements(_ sizes: RepositorySizes) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Labels verbatim from `docs/ui-spec.md` §Maintenance.
            LabeledContent("On disk", value: MaintenanceFormat.bytes(sizes.onDiskBytes))
            LabeledContent("Protected data", value: MaintenanceFormat.bytes(sizes.protectedBytes))
            LabeledContent(
                "Snapshots",
                value: MaintenanceFormat.count(sizes.snapshotCount, singular: "snapshot", plural: "snapshots")
            )
            if let fileCount = sizes.fileCount {
                LabeledContent(
                    "Files",
                    value: MaintenanceFormat.count(fileCount, singular: "file", plural: "files")
                )
            }
            Text("Measured \(MaintenanceFormat.absoluteAndRelative(sizes.measuredAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .monospacedDigit()
    }
}
