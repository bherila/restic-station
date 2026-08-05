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

    /// Result of the last Install/Uninstall button press, shown until the
    /// next one. `nil` before any button has been pressed this session.
    @State private var cliActionMessage: String?
    @State private var cliActionIsError = false
    /// Bumped after every install/uninstall so `commandLineSection`
    /// re-reads `model.cliInstallStatus` from disk — it is a computed
    /// property, not `@Published`, so nothing else invalidates the view.
    @State private var cliRefreshToken = 0

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

            commandLineSection

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

    // MARK: - Command line (T28, issue #30)

    /// A CLI nobody knows about does not satisfy the product goal: this is
    /// the row that makes `restic-station` on `PATH` discoverable at all,
    /// mirroring `cli install` / `cli uninstall` / `cli status`
    /// (`Helper/Sources/Commands/Cli.swift`) via the same
    /// `ResticStationCore.CLIInstaller` both surfaces call.
    @ViewBuilder
    private var commandLineSection: some View {
        let status = model.cliInstallStatus
        Section {
            StatusRow(
                title: "restic-station",
                tone: cliTone(status),
                badgeLabel: cliBadgeLabel(status),
                detail: cliDetail(status)
            )
            CopyablePath(text: status.linkPath, helpText: "Copy the CLI path")
            HStack {
                Button(status.installed ? "Reinstall" : "Install") { performInstall() }
                if status.installed {
                    Button("Uninstall") { performUninstall() }
                }
            }
            if let cliActionMessage {
                Label {
                    Text(cliActionMessage)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: cliActionIsError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(cliActionIsError ? .red : .green)
                }
                .font(.callout)
            }
        } header: {
            Text("Command line")
        } footer: {
            Text(cliFooter(status))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        // Forces this section's body (and so `model.cliInstallStatus`, a
        // computed property that reads disk state) to be recomputed after
        // an install/uninstall — see `cliRefreshToken`'s doc comment.
        .id(cliRefreshToken)
    }

    private func performInstall() {
        switch model.installCLI() {
        case .success(let outcome):
            cliActionIsError = false
            switch outcome {
            case .created(let linkPath):
                cliActionMessage = "Installed at \(linkPath)."
            case .alreadyInstalled:
                cliActionMessage = "Already installed."
            case .repaired:
                cliActionMessage = "Repointed the existing symlink at this copy of the app."
            }
        case .failure(let error):
            cliActionIsError = true
            cliActionMessage = "\(error)"
        }
        cliRefreshToken += 1
    }

    private func performUninstall() {
        switch model.uninstallCLI() {
        case .success(let outcome):
            cliActionIsError = false
            switch outcome {
            case .removed:
                cliActionMessage = "Removed."
            case .notInstalled:
                cliActionMessage = "Was not installed."
            }
        case .failure(let error):
            cliActionIsError = true
            cliActionMessage = "\(error)"
        }
        cliRefreshToken += 1
    }

    private func cliTone(_ status: CLIInstaller.Status) -> StatusTone {
        guard status.installed else { return .unknown }
        return status.upToDate ? .ok : .warning
    }

    private func cliBadgeLabel(_ status: CLIInstaller.Status) -> String {
        guard status.installed else { return "Not installed" }
        return status.upToDate ? "Installed" : "Installed (stale)"
    }

    private func cliDetail(_ status: CLIInstaller.Status) -> String {
        if status.installed {
            return status.upToDate
                ? "\(status.linkPath) → this app."
                : "\(status.linkPath) points at a different copy of the app — Reinstall to repoint it here."
        }
        if status.foreignEntryPresent {
            return "\(status.linkPath) already exists and is not a restic-station symlink — remove it by hand "
                + "first."
        }
        return "Not installed. Choose Install to add \(status.linkPath)."
    }

    private func cliFooter(_ status: CLIInstaller.Status) -> String {
        var text = "Puts a restic-station command on your PATH, so `restic-station status` (and the other "
            + "helper subcommands — see the README) work from any terminal, without typing this app's bundle "
            + "path."
        if status.installed && !status.onPath {
            let directory = URL(fileURLWithPath: status.linkPath).deletingLastPathComponent().path
            text += " \(directory) is not on your shell's PATH — add it to your shell profile."
        }
        return text
    }
}
