import ResticStationCore
import SwiftUI

/// Settings → General (`docs/ui-spec.md` §Settings): the menu-bar icon
/// toggle, the launch-at-login note, and the entry point back into the setup
/// assistant.
///
/// The launch-at-login note is the whole point of this pane. "Show menu bar
/// icon" looks like the switch that controls whether backups happen — it is
/// not, and a user who turns it off and assumes their backups stopped (or
/// worse, who quits the app assuming the same) is the failure mode this
/// paragraph exists to prevent.
struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel

    /// Set by the root pane, so "Setup assistant…" presents the sheet over
    /// the whole Settings window rather than inside one tab.
    @Binding var showOnboarding: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Show menu bar icon", isOn: $model.showMenuBarIcon)
            } footer: {
                Text("Scheduled backups run whether or not Restic Station is open — a background "
                    + "agent handles them. This setting only affects the app's own icon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Setup assistant…") {
                    showOnboarding = true
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Re-runs the first-launch checks: restic, the background agent, and Full Disk Access.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = model.configLoadError ?? model.lastConfigError {
                Section("Configuration") {
                    Label {
                        Text(error)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.callout)
                    CopyablePath(text: model.paths.configFile.path, helpText: "Copy the path to config.json")
                }
            }
        }
        .formStyle(.grouped)
    }
}
