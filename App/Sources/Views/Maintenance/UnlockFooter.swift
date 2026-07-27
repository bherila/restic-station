import ResticStationCore
import SwiftUI

/// The footer utility from `docs/ui-spec.md` §Maintenance:
///
/// > **Unlock**: small footer utility "Repository reports locked? Remove
/// > stale locks" → helper runs `restic unlock` (safe: only removes locks of
/// > dead processes).
///
/// Deliberately quiet — small type, no card, below everything else. It is the
/// answer to a specific error message (`ResticExitClass.repoLocked`'s next
/// step is literally "remove stale locks in Maintenance"), not something to
/// invite people to click.
///
/// A repository lock belongs to one repository, so the action is
/// per-destination. With one destination it is a plain button; with several
/// it is a menu, so the user never has to guess which repository the button
/// meant.
struct UnlockFooter: View {
    @EnvironmentObject private var model: AppModel
    let backupSet: BackupSet
    @ObservedObject var maintenance: MaintenanceModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Copy verbatim from the spec.
            Text("Repository reports locked? Remove stale locks")
                .font(.callout)
                .foregroundStyle(.secondary)

            if backupSet.destinations.count == 1, let destination = backupSet.destinations.first {
                Button {
                    maintenance.removeStaleLocks(set: backupSet, destination: destination, in: model)
                } label: {
                    label(for: destination, title: "Remove stale locks")
                }
                .controlSize(.small)
                .disabled(isUnlocking(destination))
            } else {
                Menu("Remove stale locks") {
                    ForEach(backupSet.destinations) { destination in
                        Button(destination.label) {
                            maintenance.removeStaleLocks(set: backupSet, destination: destination, in: model)
                        }
                        .disabled(isUnlocking(destination))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
            }

            if let destination = unlockingDestination {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Unlocking \(destination.label)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        // The reassurance the spec puts in parentheses, made visible rather
        // than hidden in a tooltip: this is the one destructive-*sounding*
        // control on the screen that is in fact safe.
        .help("restic only removes locks whose owning process is no longer running. "
            + "A backup that is genuinely in progress keeps its lock.")
        .accessibilityElement(children: .contain)
    }

    private func isUnlocking(_ destination: Destination) -> Bool {
        maintenance.isBusy(.unlock(destId: destination.id))
    }

    private var unlockingDestination: Destination? {
        backupSet.destinations.first { isUnlocking($0) }
    }

    private func label(for destination: Destination, title: String) -> some View {
        Text(title)
            .help("Runs restic unlock against \(destination.label).")
    }
}
