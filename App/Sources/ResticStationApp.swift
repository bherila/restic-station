import SwiftUI

/// Window identifiers, so `openWindow(id:)` from the menu bar and the
/// `WindowGroup` declaration can never drift apart.
enum AppWindowID {
    static let main = "main"
}

@main
struct ResticStationApp: App {
    /// Owned here and injected everywhere: one `AppModel` per app launch,
    /// alive for as long as the process is (the menu bar extra keeps working
    /// after the last window closes).
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Restic Station", id: AppWindowID.main) {
            MainWindow()
                .environmentObject(model)
                // `StateWatcher` and `LaunchdManager` are separate
                // `ObservableObject`s; views that render raw live state
                // (runs list, progress bars, agent status) observe them
                // directly rather than through `AppModel`.
                .environmentObject(model.stateWatcher)
                .environmentObject(model.launchd)
                .onAppear {
                    model.start()
                    model.refresh()
                }
        }
        .defaultSize(width: 1_000, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            // A single-window utility: "New Window" would open a second,
            // equally authoritative view of the same config.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsRootView()
                .environmentObject(model)
                .environmentObject(model.launchd)
        }

        // `docs/ui-spec.md` §Menu bar. `isInserted` is bound straight through
        // to `config.showMenuBarIcon`, so toggling the setting adds/removes
        // the icon live and the change is persisted by `AppModel.saveConfig`.
        MenuBarExtra(
            "Restic Station",
            systemImage: model.appHealth.menuBarSymbolName,
            isInserted: $model.showMenuBarIcon
        ) {
            MenuBarView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.menu)
    }
}
