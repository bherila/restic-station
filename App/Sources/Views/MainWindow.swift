import ResticStationCore
import SwiftUI

/// The app shell (`docs/ui-spec.md` §Shell): a `NavigationSplitView` whose
/// sidebar routes to one root view per section. Each root view lives in its
/// own file under `Views/` and is replaced wholesale by T14–T17 — this file
/// should not need to change again.
///
/// Settings is a sidebar row like the others but opens the standard
/// `Settings` scene (⌘,) via `SettingsLink`, rather than being a fifth
/// detail pane: one settings surface, reachable two ways.
struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @SceneStorage("sidebarSelection") private var storedSelection: String?
    /// Optional because that is the shape `List` single-selection takes;
    /// the detail pane falls back to Backup Sets if it is ever cleared.
    @State private var selection: SidebarSection? = .backupSets

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarSection.allCases) { section in
                        Label(section.title, systemImage: section.symbolName)
                            .tag(section)
                    }
                }
                Section {
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 320)
        } detail: {
            detail
                .frame(minWidth: 640, minHeight: 480)
        }
        .navigationTitle("Restic Station")
        .safeAreaInset(edge: .top, spacing: 0) {
            AppAlertBanners()
        }
        // ui-spec: min size ~900×560.
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            if let storedSelection, let restored = SidebarSection(rawValue: storedSelection) {
                selection = restored
            }
        }
        .onChange(of: selection) { _, newValue in
            storedSelection = newValue?.rawValue
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .backupSets {
        case .backupSets:
            BackupSetsRootView()
        case .runs:
            RunsRootView()
        case .restore:
            RestoreRootView()
        case .maintenance:
            MaintenanceRootView()
        }
    }
}

/// Process-wide safety alerts shared by every window scene. Keeping this as
/// one view prevents Settings from silently losing a warning merely because
/// the main window was closed.
struct AppAlertBanners: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.configChangedOnDisk {
                ConfigChangeBanner()
            }
            if let error = model.pendingSecretRollbackError {
                SecretRollbackBanner(message: error)
            }
            if let failure = model.scheduleStateFailure {
                ScheduleStateIntegrityBanner(failure: failure)
            }
        }
    }
}

struct ScheduleStateIntegrityBanner: View {
    let failure: ScheduleStateReadFailure

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Schedule state needs recovery")
                    .fontWeight(.semibold)
                Text("Scheduled work is paused to protect purge history. Inspect the preserved file before replacing or deleting it.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
        }
        .help(failure.recoveryMessage)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct SecretRollbackBanner: View {
    @EnvironmentObject private var model: AppModel
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(.red)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Retry Restoration") {
                model.retryPendingSecretRollbacks()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A fleet-sync or CLI replacement is never silently folded into an open
/// editor. The operator chooses when to reload; stale drafts retain their
/// original fingerprint and will still be refused if saved afterward.
struct ConfigChangeBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Settings changed on disk. Reload before saving to avoid overwriting those changes.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Reload Settings") {
                Task { await model.reloadConfigFromDisk() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - SidebarSection

/// The four routed sections. "Settings" is deliberately not a case: it is a
/// `SettingsLink`, not a detail pane.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case backupSets
    case runs
    case restore
    case maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backupSets: return "Backup Sets"
        case .runs: return "Runs"
        case .restore: return "Restore"
        case .maintenance: return "Maintenance"
        }
    }

    var symbolName: String {
        switch self {
        case .backupSets: return "externaldrive"
        case .runs: return "clock.arrow.circlepath"
        case .restore: return "arrow.uturn.backward.circle"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}
