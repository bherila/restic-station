import AppKit
import ResticStationCore
import SwiftUI

/// The restore sheet (`docs/ui-spec.md` §Restore → "Restore action").
///
/// The restore itself is the one thing on this screen that **writes**, so it
/// goes through `restic-station-helper restore` and nothing else
/// (`docs/architecture.md` §The single-code-path rule): same locking, same
/// run record, same state files as a scheduled operation. Progress therefore
/// comes from `state/current-run-<setId>.json` via `StateWatcher`, and the
/// completion summary from the run's own log.
struct RestoreSheet: View {
    let repository: RestoreRepository
    let snapshotID: String
    let snapshotDescription: String
    let items: [RestoreItem]

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var stateWatcher: StateWatcher
    @Environment(\.dismiss) private var dismiss

    @State private var targetKind: TargetKind = .chooseFolder
    @State private var chosenFolder: URL?
    @State private var overwriteMode: ResticCommand.OverwriteMode = .always
    @State private var phase: Phase = .configuring
    @State private var startedAt = Date()

    private enum TargetKind: String, CaseIterable, Identifiable {
        case originalLocation
        case chooseFolder

        var id: String { rawValue }
        var title: String {
            switch self {
            case .originalLocation: return "Original location"
            case .chooseFolder: return "Choose folder…"
            }
        }
    }

    private enum Phase: Equatable {
        case configuring
        case running
        case finished(RestoreOutcome)
    }

    private struct RestoreOutcome: Equatable {
        let isError: Bool
        let message: String
        let filesRestored: Int?
        let bytesRestored: Int?
        let revealURL: URL?
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .configuring:
                        configuration
                    case .running:
                        progress
                    case .finished(let outcome):
                        completion(outcome)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Restore from \(repository.displayName)")
                .font(.headline)
            Text(snapshotDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: - Configuration

    @ViewBuilder
    private var configuration: some View {
        selectionSummary

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Restore to", selection: $targetKind) {
                    ForEach(TargetKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)

                if targetKind == .chooseFolder {
                    HStack(spacing: 8) {
                        Text(chosenFolder?.path ?? "No folder chosen")
                            .font(.callout)
                            .foregroundStyle(chosenFolder == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 8)
                        Button("Choose…") { chooseFolder() }
                    }
                }

                Divider()

                Picker("If a file already exists", selection: $overwriteMode) {
                    ForEach(ResticCommand.OverwriteMode.allCases, id: \.self) { mode in
                        Text(mode.pickerLabel).tag(mode)
                    }
                }
                .frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }

        if targetKind == .originalLocation {
            originalLocationWarning
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(itemsSummary)
                .font(.callout)
            ForEach(items.prefix(6)) { item in
                Label(item.path, systemImage: item.isDirectory ? "folder" : "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if items.count > 6 {
                Text("…and \(items.count - 6) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var itemsSummary: String {
        let files = items.filter { !$0.isDirectory }.count
        let folders = items.count - files
        var parts: [String] = []
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        return "Restoring " + parts.joined(separator: " and ") + " from this snapshot."
    }

    /// `docs/ui-spec.md` §Restore, verbatim: the banner and the inline
    /// suggestion. A restore into a chosen folder shows neither.
    private var originalLocationWarning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Files at the original location will be overwritten.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Text("Consider backing up first —")
                    .font(.callout)
                let backupUnavailableReason = model.backUpNowUnavailableReason(setId: repository.setId)
                Button("Back Up Now") {
                    model.backUpNow(setId: repository.setId)
                }
                .disabled(backupUnavailableReason != nil)
                .help(backupUnavailableReason ?? "Back up this set before restoring.")
            }
            if let message = model.lastHelperMessage, message.setId == repository.setId {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? Color.orange : Color.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let run = stateWatcher.currentRuns[repository.setId], run.kind == .restore, run.totalBytes > 0 {
                ProgressView(value: min(max(run.percentDone, 0), 1)) {
                    Text("Restoring…")
                } currentValueLabel: {
                    Text("\(run.bytesDone.formatted(.byteCount(style: .file))) of "
                        + "\(run.totalBytes.formatted(.byteCount(style: .file)))")
                }
            } else {
                ProgressView {
                    Text("Restoring…")
                }
                .progressViewStyle(.linear)
            }
            Text("Restic Station is running the restore through its background helper, "
                + "so it keeps going even if you close this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Completion

    @ViewBuilder
    private func completion(_ outcome: RestoreOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                outcome.isError ? "Restore failed" : "Restore complete",
                systemImage: outcome.isError ? "xmark.circle.fill" : "checkmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(outcome.isError ? Color.red : Color.green)

            if let files = outcome.filesRestored {
                let bytes = outcome.bytesRestored ?? 0
                Text("\(files == 1 ? "1 file" : "\(files) files") · \(bytes.formatted(.byteCount(style: .file)))")
                    .font(.callout)
                    .monospacedDigit()
            }
            Text(outcome.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let revealURL = outcome.revealURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if case .finished = phase {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase == .running)
                Spacer()
                Button("Restore") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(16)
    }

    private var canStart: Bool {
        guard phase == .configuring, !items.isEmpty else { return false }
        switch targetKind {
        case .originalLocation: return true
        case .chooseFolder: return chosenFolder != nil
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Restore Here"
        panel.message = "Choose a folder to restore into."
        if panel.runModal() == .OK {
            chosenFolder = panel.url
        }
    }

    private var target: RestoreTarget {
        switch targetKind {
        case .originalLocation: return .originalLocation
        case .chooseFolder: return chosenFolder.map { RestoreTarget.folder($0) } ?? .originalLocation
        }
    }

    private func start() {
        guard canStart else { return }
        let plan = RestorePlan.make(items: items, target: target)
        let args = HelperRestoreArgs(
            setId: repository.setId,
            destId: repository.destination.id,
            snapshotID: snapshotID,
            targetPath: plan.targetPath,
            subpath: plan.subpath,
            includes: plan.includes,
            overwriteMode: overwriteMode
        )
        let revealURL = revealTarget(for: plan)
        startedAt = Date()
        phase = .running

        Task {
            let result = await model.performRestore(args)
            let summary = await restoreSummary()
            phase = .finished(
                RestoreOutcome(
                    isError: !result.isSuccess,
                    message: message(for: result),
                    filesRestored: summary?.filesRestored,
                    bytesRestored: summary?.bytesRestored,
                    revealURL: result.isSuccess ? revealURL : nil
                )
            )
        }
    }

    /// Where "Reveal in Finder" should point: the chosen folder, or — for an
    /// original-location restore — the directory the restored items live in.
    private func revealTarget(for plan: RestorePlan) -> URL {
        if let folder = chosenFolder, targetKind == .chooseFolder {
            return folder
        }
        let parent = RestorePlan.commonParentDirectory(of: items.map(\.path))
        return URL(fileURLWithPath: parent, isDirectory: true)
    }

    private func message(for result: HelperResult) -> String {
        switch result {
        case .ok:
            return result.message.isEmpty ? "The restore finished." : result.message
        case .busy:
            return "Another operation for “\(repository.setName)” is already running. "
                + "Wait for it to finish, then restore again."
        case .offline(let output), .failed(let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "The restore could not be completed. Open Runs for the full log."
                : detail + "\nOpen Runs for the full log."
        }
    }

    /// The `restore` NDJSON summary (`files_restored` / `bytes_restored`),
    /// read back from the run log the helper wrote. The run record itself
    /// only carries a *backup* summary, so the numbers `docs/ui-spec.md`
    /// asks for come from the log.
    private func restoreSummary() async -> RestoreSummary? {
        guard let entry = model.latestRestoreRun(setId: repository.setId, since: startedAt) else { return nil }
        let logURL = model.runStore.logURL(runId: entry.runId)
        return await Task.detached(priority: .utility) {
            Self.parseRestoreSummary(at: logURL)
        }.value
    }

    /// `nonisolated` so it can run off the main actor: reading and decoding
    /// a run log is file I/O, and the sheet is on screen while it happens.
    nonisolated private static func parseRestoreSummary(at url: URL) -> RestoreSummary? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let decoder = ResticMessageDecoder()
        for line in text.split(separator: "\n").reversed() {
            if case .restoreSummary(let summary) = decoder.decodeLine(String(line)) {
                return summary
            }
        }
        return nil
    }
}
