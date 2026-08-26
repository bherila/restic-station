import ResticStationCore
import SwiftUI

/// The `Settings` scene's content (`docs/ui-spec.md` §Settings): three panes
/// in the standard macOS tabbed shape — General, restic binary, Permissions
/// & background — plus the setup assistant.
///
/// Settings is a single surface reachable two ways (⌘, and the sidebar's
/// `SettingsLink`), and it is where every "this looks fine but nothing is
/// actually running" condition becomes visible: a missing or too-old restic,
/// an agent that was never registered or is waiting for approval, and Full
/// Disk Access that macOS granted to the app but not to the agent. The panes
/// deliberately re-read their inputs whenever the window appears or the app
/// is activated — all three can be changed behind the app's back in System
/// Settings.
struct SettingsRootView: View {
    @EnvironmentObject private var model: AppModel

    @State private var selection: Pane = .general
    @State private var showOnboarding = false

    private enum Pane: String, CaseIterable, Identifiable {
        case general, restic, permissions
        var id: String { rawValue }
    }

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettings(showOnboarding: $showOnboarding)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pane.general)

            ResticSettings()
                .tabItem { Label("restic", systemImage: "terminal") }
                .tag(Pane.restic)

            PermissionsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(Pane.permissions)
        }
        // Sized for the Permissions pane, which carries the longest
        // explanatory copy; the others simply get room to breathe.
        .frame(width: 620, height: 520)
        .safeAreaInset(edge: .top, spacing: 0) {
            AppAlertBanners()
        }
        // The `Settings` scene injects only `AppModel` and `LaunchdManager`
        // (`ResticStationApp.swift`); panes that render live on-disk state
        // take the watcher from the model that already owns it.
        .environmentObject(model.stateWatcher)
        .onboardingSheet(isPresented: $showOnboarding)
        .onAppear { model.refresh() }
    }
}
