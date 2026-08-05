import AppKit
import ResticStationCore
import SwiftUI

/// Settings → restic binary (`docs/ui-spec.md` §Settings): the discovered
/// path, a status chip in one of three states, and a manual override.
///
/// The chip is the only place a user ever learns that the binary every
/// backup depends on is missing or too old — a scheduled backup with no
/// restic simply does nothing (the tick prints "restic not configured" to a
/// log nobody reads), so this pane is a silent-failure surface, not a
/// convenience.
struct ResticSettings: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var pane = ResticSettingsModel()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Status")
                        Spacer(minLength: 12)
                        StatusBadge(
                            tone: chip.tone,
                            label: chip.label,
                            isBusy: pane.isSearching
                        )
                    }
                    Text(chip.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if case .notConfigured = pane.effectiveStatus(model: model), !pane.isSearching {
                        CopyablePath(text: "brew install restic", helpText: "Copy the install command")
                    }
                }
            } header: {
                Text("restic binary")
            } footer: {
                Text("Restic Station never bundles restic — it runs the copy you installed, so you can "
                    + "update it yourself and read your repositories with plain restic at any time. "
                    + "Version \(AppModel.minimumResticVersion) or newer is required.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Path") {
                    if let path = model.resticPath, !path.isEmpty {
                        Text(path)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("Not set")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Search again") {
                        Task { await pane.search(model: model) }
                    }
                    .disabled(pane.isSearching)

                    Button("Locate manually…") {
                        Task { await pane.locateManually(model: model) }
                    }
                    .disabled(pane.isSearching)
                }
            } footer: {
                if let rejection = pane.manualRejection {
                    Label {
                        Text(rejectionText(rejection))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .font(.callout)
                } else if let searched = pane.searchSummary {
                    Text(searched)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Validate what is configured; only search when it is not usable.
            await pane.refreshIfNeeded(model: model)
        }
    }

    /// The three ui-spec states — plus "checking", which is what the pane
    /// shows for the fraction of a second before the first probe returns
    /// (never a green "OK" we have not earned yet).
    private var chip: (tone: StatusTone, label: String, detail: String) {
        if pane.isSearching {
            return (.inProgress, "Checking…", "Running restic version on each candidate.")
        }
        switch pane.effectiveStatus(model: model) {
        case .unknown:
            return (.inProgress, "Checking…", "Looking for the restic binary.")
        case .notConfigured:
            return (
                .problem,
                "Missing",
                "No restic binary was found. Install it with Homebrew, then choose Search again — "
                    + "or point Restic Station at an existing copy with Locate manually."
            )
        case .ok(let path, let version):
            return (.ok, "restic \(version)", path)
        case .tooOld(let path, let version, let minimum):
            return (
                .warning,
                "\(version) found — \(minimum)+ required",
                "\(path) is too old for Restic Station. Update restic (brew upgrade restic), then "
                    + "choose Search again."
            )
        case .unavailable(let path, let reason):
            return (.problem, "Not usable", "\(path): \(reason)")
        }
    }

    private func rejectionText(_ probe: ResticProbe) -> String {
        switch probe.outcome {
        case .ok:
            return ""
        case .tooOld(let version):
            return "\(probe.path) is restic \(version); Restic Station requires "
                + "\(AppModel.minimumResticVersion) or newer, so it was not saved. "
                + "Scheduled backups run without anyone watching — a binary we know is too old is "
                + "not worth the risk of a run that fails silently."
        case .unusable(let reason):
            return "\(reason) It was not saved."
        }
    }
}

// MARK: - ResticSettingsModel

/// Transient state for the pane: whether a search is running and what the
/// last one/last manual pick concluded. Nothing here is persisted —
/// `AppModel.resticPath` and `AppModel.resticStatus` remain the truth.
@MainActor
final class ResticSettingsModel: ObservableObject {
    @Published private(set) var isSearching = false
    @Published private(set) var searchSummary: String?
    /// Set when the user picked a binary by hand that we refused to save.
    @Published private(set) var manualRejection: ResticProbe?
    /// What the last search/manual pick concluded about binaries we found
    /// but did **not** persist.
    @Published private(set) var discoveryStatus: ResticStatus?

    /// `AppModel.resticStatus` only ever describes `AppModel.resticPath`, and
    /// discovery deliberately refuses to persist a too-old binary — so
    /// without this, "restic 0.16.4 is installed but unsupported" would
    /// render as the same red "Missing" chip as "no restic at all", losing
    /// the distinction (and the fix) the ui-spec asks for.
    func effectiveStatus(model: AppModel) -> ResticStatus {
        if case .notConfigured = model.resticStatus, let discoveryStatus {
            return discoveryStatus
        }
        return model.resticStatus
    }

    /// Validate what is configured; search only if it is not usable, so an
    /// already-working setup costs one `restic version` and no `PATH` walk.
    func refreshIfNeeded(model: AppModel) async {
        await model.refreshResticInfo()
        if case .ok = model.resticStatus {
            discoveryStatus = nil
            return
        }
        await search(model: model)
    }

    func search(model: AppModel) async {
        guard !isSearching else { return }
        isSearching = true
        manualRejection = nil
        searchSummary = nil
        defer { isSearching = false }

        let result = await model.discoverResticBinary()
        searchSummary = Self.summarize(result)
        discoveryStatus = result.chosen == nil ? result.status : nil
    }

    func locateManually(model: AppModel) async {
        guard !isSearching else { return }
        guard let url = Self.presentOpenPanel() else { return }

        isSearching = true
        searchSummary = nil
        defer { isSearching = false }

        let probe = await model.useResticBinary(at: url.path)
        manualRejection = probe.isUsable ? nil : probe
        discoveryStatus = probe.isUsable ? nil : probe.status
    }

    private static func summarize(_ result: ResticDiscoveryResult) -> String {
        if let chosen = result.chosen {
            return "Found \(chosen.path)."
        }
        if result.rejected.isEmpty {
            return "Searched /opt/homebrew/bin, /usr/local/bin, /opt/local/bin and PATH — no restic binary found."
        }
        let listed = result.rejected.map { probe -> String in
            switch probe.outcome {
            case .ok(let version): return "\(probe.path) (restic \(version))"
            case .tooOld(let version): return "\(probe.path) (restic \(version) — too old)"
            case .unusable(let reason): return "\(probe.path) (\(reason))"
            }
        }
        return "No usable restic found. Checked: " + listed.joined(separator: "; ")
    }

    /// A file picker rather than a text field: the path is persisted and
    /// handed to a headless helper, so it had better be a real file the user
    /// actually has. `showsHiddenFiles` is on because the interesting
    /// locations (`/usr/local/bin`, `/opt/...`) are hidden in the Finder's
    /// default view.
    private static func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Locate restic"
        panel.message = "Choose the restic binary Restic Station should run."
        panel.prompt = "Use restic"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        for candidate in ResticDiscovery.wellKnownPaths {
            let directory = (candidate as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: directory) {
                panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
                break
            }
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
