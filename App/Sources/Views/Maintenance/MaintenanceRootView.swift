import SwiftUI

/// The Maintenance section's routed entry point — `MainWindow` refers to this
/// name, so it stays put while the screen itself lives in `MaintenanceView`.
///
/// Its only job is to own the screen's `@StateObject`: keeping that one level
/// above `MaintenanceView` means the set picker, the in-flight actions and
/// the loaded size cards survive a re-render of the detail pane. (The size
/// numbers survive longer still — they sit in `MaintenanceStatsCache`, which
/// is per app session, per `docs/ui-spec.md` §Maintenance: "stats are cached
/// in-memory per app session".)
struct MaintenanceRootView: View {
    @StateObject private var maintenance = MaintenanceModel()

    var body: some View {
        MaintenanceView(maintenance: maintenance)
    }
}
