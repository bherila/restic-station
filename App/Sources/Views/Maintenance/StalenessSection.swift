import ResticStationCore
import SwiftUI

/// Staleness (`docs/ui-spec.md` §Maintenance): per-destination "last synced"
/// with stale highlighting.
///
/// The stale decision itself is **not** made here. It comes from the
/// already-derived `SetHealth.staleDestinationIds`
/// (`HealthDerivation.isDestinationStale`, which implements
/// `docs/scheduling.md` §Staleness: `stale ⟺ now − lastSyncedAt >
/// stalenessWarningDays`, and treats a never-synced destination as stale once
/// the set has backed up successfully at least once). Recomputing the rule in
/// the view would let this screen, the destinations table and the menu bar
/// icon disagree about the same destination.
struct StalenessSection: View {
    @EnvironmentObject private var model: AppModel
    let backupSet: BackupSet

    var body: some View {
        MaintenanceSection(
            "Staleness",
            systemImage: "clock.badge.exclamationmark",
            caption: "\"Last synced\" is the end of the last successful backup for the primary, and of the "
                + "last successful copy for each mirror. A destination is flagged after "
                + "\(backupSet.stalenessWarningDays) day\(backupSet.stalenessWarningDays == 1 ? "" : "s") without one — "
                + "for an external drive that usually just means it has not been plugged in."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(backupSet.destinations) { destination in
                    StalenessRow(
                        destination: destination,
                        status: MaintenanceLookup.repoStatus(model, destId: destination.id),
                        isStale: MaintenanceLookup.isStale(model, setId: backupSet.id, destId: destination.id)
                    )
                }
            }
        }
    }
}

// MARK: - StalenessRow

struct StalenessRow: View {
    let destination: Destination
    let status: RepoStatus?
    let isStale: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            DestinationTitle(destination: destination)
                .frame(minWidth: 160, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(syncedText)
                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if isStale {
                Text("STALE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(.callout)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var symbolName: String {
        if isStale { return "exclamationmark.triangle.fill" }
        if status?.reachable == true { return "checkmark.circle.fill" }
        if status == nil { return "questionmark.circle" }
        return "bolt.horizontal.circle"
    }

    private var tint: Color {
        if isStale { return .orange }
        if status?.reachable == true { return .green }
        return .secondary
    }

    private var syncedText: String {
        guard let lastSyncedAt = status?.lastSyncedAt else {
            return "Never synced"
        }
        return "Last synced \(MaintenanceFormat.absoluteAndRelative(lastSyncedAt))"
    }

    /// Reachability is a different question from staleness — an unplugged
    /// drive is offline *and* (eventually) stale, and the fix differs — so
    /// the probe's own result gets its own line.
    private var detailText: String? {
        guard let status else {
            return "Not probed yet. Restic Station checks each destination at least every 30 minutes."
        }
        var parts: [String] = []
        parts.append(status.reachable
            ? "Reachable as of \(MaintenanceFormat.absoluteAndRelative(status.probedAt))"
            : "Offline as of \(MaintenanceFormat.absoluteAndRelative(status.probedAt))")
        if let lastError = status.lastError, !lastError.isEmpty {
            parts.append(lastError)
        }
        return parts.joined(separator: " — ")
    }
}
