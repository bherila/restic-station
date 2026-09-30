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

    @State private var runsPath: [String] = []

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
            BackupSetsRootView { runId in
                runsPath = [runId]
                selection = .runs
            }
        case .runs:
            RunsRootView(path: $runsPath)
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
            if let problem = model.configFileProblem {
                ConfigProblemBanner(problem: problem)
            } else if let offer = model.pendingSchemaUpgrade {
                SchemaUpgradeBanner(offer: offer)
            } else if model.configChangedOnDisk {
                ConfigChangeBanner()
            }
            if let migration = model.unacknowledgedConfigMigration {
                ConfigMigrationNoticeBanner(migration: migration)
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

/// `config.json` failed its last load or reload (#162). Replaces the
/// generic "changed on disk" banner, which a failed reload also raises,
/// because it says what is wrong: an unreadable file, or one written by a
/// newer Restic Station.
struct ConfigProblemBanner: View {
    @EnvironmentObject private var model: AppModel
    let problem: ConfigFileProblem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            // With no earlier config to show, the set list carries the full
            // explanation; the banner only has to name the problem.
            Text(model.config.sets.isEmpty ? problem.menuBarLine : problem.staleListBanner)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if problem.offersUpdateCheck {
                CheckForUpdatesButton()
            }
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

/// `config.json` is at an older schema and this app will not rewrite it
/// without asking (#161). Settings are read-only meanwhile.
struct SchemaUpgradeBanner: View {
    @EnvironmentObject private var model: AppModel
    let offer: SchemaUpgradeOffer
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.doc.fill")
                .foregroundStyle(.blue)
            Text(offer.bannerText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Upgrade…") { confirming = true }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .alert(offer.confirmationTitle, isPresented: $confirming) {
            Button("Upgrade") {
                Task { await model.upgradeConfigSchema() }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(offer.confirmationMessage)
        }
    }
}

/// This host rewrote the shared `config.json` at a newer schema (#161) —
/// by the app, the helper, or the CLI. Stays until acknowledged, because
/// the machines left behind cannot report that they stopped.
struct ConfigMigrationNoticeBanner: View {
    @EnvironmentObject private var model: AppModel
    let migration: ConfigMigrationRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(ConfigMigrationRecord.fleetWarning(from: migration.fromVersion, to: migration.toVersion))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Upgraded \(migration.migratedAt.formatted(date: .abbreviated, time: .shortened)) "
                    + "by \(migration.process).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("They're Upgraded") {
                model.acknowledgeConfigMigration()
            }
            .help("Clear this warning once every machine sharing config.json runs a version that reads it")
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
