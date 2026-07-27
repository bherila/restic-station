import ResticStationCore
import SwiftUI

/// Minimal `Settings` scene content — replaced by T18
/// (`Views/Settings/GeneralSettings.swift`, `ResticSettings.swift`,
/// `PermissionsView.swift`).
///
/// It carries only what the shell itself needs to be usable and verifiable:
/// the menu-bar toggle (whose live add/remove of the icon is a T13
/// acceptance criterion) and read-only readouts of the two health inputs
/// that are otherwise invisible — the restic binary and the background
/// agent.
struct SettingsRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var launchd: LaunchdManager

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

            Section("restic") {
                LabeledContent("Binary", value: resticSummary)
            }

            Section("Background agent") {
                LabeledContent("Status", value: launchd.isEnabled ? "Enabled" : "Not running")
                if let diagnostic = launchd.diagnostic {
                    Text(diagnostic)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.configLoadError ?? model.lastConfigError {
                Section("Configuration") {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
    }

    private var resticSummary: String {
        switch model.resticStatus {
        case .unknown:
            return "Checking…"
        case .notConfigured:
            return "Not found — install with `brew install restic`"
        case .ok(let path, let version):
            return "restic \(version) — \(path)"
        case .tooOld(let path, let version, let minimum):
            return "\(version) found — \(minimum)+ required (\(path))"
        case .unavailable(_, let reason):
            return reason
        }
    }
}
