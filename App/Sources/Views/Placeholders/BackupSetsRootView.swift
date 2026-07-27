import ResticStationCore
import SwiftUI

/// Placeholder for the Backup Sets section — replaced by T14's
/// `Views/Sets/SetListView.swift`. `MainWindow` routes to this name, so T14
/// can swap the body without touching the shell.
///
/// It shows the derived per-set health lines so the shell's plumbing
/// (config → `AppModel` → `HealthDerivation`) is visible before the real
/// list exists.
struct BackupSetsRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.setHealths.isEmpty {
            PlaceholderDetailView(
                title: "Backup Sets",
                symbolName: "externaldrive",
                message: "No backup sets yet."
            )
        } else {
            List(model.setHealths) { health in
                VStack(alignment: .leading, spacing: 2) {
                    Text(MenuBarCopy.statusLine(for: health))
                    if health.isRunning {
                        Text(MenuBarCopy.progressLine(for: health))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("Restic Station")
            .navigationSubtitle("Backup Sets")
        }
    }
}
