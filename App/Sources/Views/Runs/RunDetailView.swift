import AppKit
import ResticStationCore
import SwiftUI

/// One run in full (`docs/ui-spec.md` §Runs — Detail): the metadata header
/// (status, trigger, snapshot id, file counts, byte counts, duration) over a
/// monospaced log view that tails while the run is in flight and shows the
/// whole file once it is not.
///
/// Both halves re-read from disk on `StateWatcher` events rather than on a
/// timer: `metadata.json` is rewritten once, when the run finishes, and the
/// log only ever grows — so the appended suffix (`RunLogTail`) plus one
/// metadata re-read is the entire live update.
struct RunDetailView: View {
    let runId: String

    @EnvironmentObject private var model: AppModel
    @StateObject private var log = RunLogTail()
    @State private var metadata: RunMetadata?
    @State private var followTail = true
    @State private var didCopySnapshotId = false

    private static let logBottomAnchor = "run-log-bottom"

    var body: some View {
        VSplitView {
            header
                .frame(minHeight: 180, idealHeight: 320)
            logPane
                .frame(minHeight: 140)
        }
        .navigationTitle("Restic Station")
        .navigationSubtitle(subtitle)
        .onAppear { reload() }
        .onChange(of: runId) { _, _ in reload() }
        // Every filesystem/notification event the watcher coalesces is also
        // our cue to re-read the log tail and (while running) the metadata.
        .onReceive(model.stateWatcher.objectWillChange) { _ in refresh() }
        .onChange(of: model.currentRuns) { _, _ in refresh() }
    }

    // MARK: - Sources

    /// The index line for this run, when it has finished. Used as a fallback
    /// so the header still renders if `metadata.json` is unreadable.
    private var indexEntry: RunIndexEntry? {
        model.recentRuns.first { $0.runId == runId }
    }

    private var kind: RunKind { metadata?.kind ?? indexEntry?.kind ?? .backup }
    private var setId: UUID? { metadata?.setId ?? indexEntry?.setId }
    private var destId: UUID? { metadata?.destId ?? indexEntry?.destId }
    private var status: RunStatus { metadata?.status ?? indexEntry?.status ?? .running }
    private var trigger: RunTrigger? { metadata?.trigger ?? indexEntry?.trigger }
    private var start: Date? { metadata?.start ?? indexEntry?.start }
    private var end: Date? { metadata?.end ?? indexEntry?.end }
    private var errorSummary: String? { metadata?.errorSummary ?? indexEntry?.errorSummary }
    private var snapshotId: String? { metadata?.snapshotId ?? indexEntry?.snapshotId }
    private var stats: BackupSummary? { metadata?.stats }

    /// Live progress, only when the set's in-flight run *is* this run.
    private var live: CurrentRunState? {
        guard let setId, let state = model.currentRuns[setId], state.runId == runId else { return nil }
        return state
    }

    private var isRunning: Bool { status == .running || live != nil }

    private var setName: String {
        guard let setId else { return "Unknown set" }
        return model.setName(for: setId)
    }

    private var subtitle: String {
        "\(kind.label) · \(setName)"
    }

    private var logURL: URL { model.runLogURL(runId: runId) }

    private var logFileExists: Bool {
        FileManager.default.fileExists(atPath: logURL.path)
    }

    // MARK: - Loading

    private func reload() {
        metadata = model.runMetadata(runId: runId)
        followTail = true
        didCopySnapshotId = false
        refresh()
    }

    private func refresh() {
        // Re-read the record only while it can still change: `finish()`
        // rewrites `metadata.json` exactly once.
        if metadata == nil || metadata?.status == .running {
            if let reloaded = model.runMetadata(runId: runId) { metadata = reloaded }
        }
        log.refresh(url: logURL)
        if !isRunning { log.finish() }
    }

    // MARK: - Header

    private var header: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        RunStatusBadge(status: status)
                        if let explanation = status.explanation {
                            Text(explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let reason = errorSummary, !reason.isEmpty {
                    LabeledContent("Reason") {
                        Text(reason)
                            .font(.callout)
                            .textSelection(.enabled)
                            .foregroundStyle(status == .failed ? Color.red : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent("Backup set", value: setName)
                LabeledContent("Destination", value: model.destinationLabel(setId: setId, destId: destId))
                LabeledContent("Kind") {
                    Label(kind.label, systemImage: kind.symbolName)
                }
                if let trigger {
                    LabeledContent("Trigger", value: trigger == .manual ? "Started by you" : "Scheduled")
                }
            }

            Section {
                if let start {
                    LabeledContent("Started") {
                        Text(RunFormat.relative(start)).help(RunFormat.absolute(start))
                    }
                }
                if let end {
                    LabeledContent("Finished") {
                        Text(RunFormat.relative(end)).help(RunFormat.absolute(end))
                    }
                }
                LabeledContent("Duration", value: RunFormat.duration(durationInterval))
            }

            if let live {
                Section("Progress") {
                    liveProgress(live)
                }
            }

            if let snapshotId, !snapshotId.isEmpty {
                Section {
                    LabeledContent("Snapshot") {
                        HStack(spacing: 8) {
                            Text(snapshotId)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                copySnapshotId(snapshotId)
                            } label: {
                                Label(
                                    didCopySnapshotId ? "Copied" : "Copy",
                                    systemImage: didCopySnapshotId ? "checkmark" : "doc.on.doc"
                                )
                            }
                            .buttonStyle(.borderless)
                            .help("Copy the snapshot ID to the clipboard.")
                        }
                    }
                } footer: {
                    Text("A snapshot is one point-in-time copy inside the repository; restic identifies it by this ID.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if hasStatistics {
                Section("Statistics") {
                    LabeledContent("Files") {
                        Text(fileCountsSummary)
                            .monospacedDigit()
                    }
                    LabeledContent("Data added", value: RunFormat.bytes(dataAdded))
                    if let packed = stats?.dataAddedPacked {
                        LabeledContent("Data added (packed)", value: RunFormat.bytes(packed))
                            .help("What was actually written to the repository after compression and packing.")
                    }
                    if let processedBytes = stats?.totalBytesProcessed {
                        LabeledContent("Total processed") {
                            Text(processedSummary(bytes: processedBytes, files: stats?.totalFilesProcessed))
                                .monospacedDigit()
                        }
                    }
                }
            }

            if let argv = metadata?.argvRedacted, !argv.isEmpty {
                Section {
                    DisclosureGroup("Command") {
                        Text(argv.joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } footer: {
                    Text("The command line as run. Passwords and access keys are passed through the environment and never appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var durationInterval: TimeInterval? {
        guard let start else { return nil }
        guard let end else {
            // Still running: report elapsed against the last progress write
            // rather than "now", so the value never ticks without an event.
            return live.map { $0.updatedAt.timeIntervalSince(start) }
        }
        return end.timeIntervalSince(start)
    }

    private var dataAdded: Int? {
        stats?.dataAdded ?? metadata?.dataAdded ?? indexEntry?.dataAdded
    }

    private var hasStatistics: Bool {
        stats != nil || dataAdded != nil || metadata?.filesNew != nil || indexEntry?.filesNew != nil
    }

    /// "3 new · 1 changed · 812 unmodified" — the three counts
    /// `docs/ui-spec.md` §Runs asks the header to show.
    private var fileCountsSummary: String {
        let new = stats?.filesNew ?? metadata?.filesNew ?? indexEntry?.filesNew
        let changed = stats?.filesChanged ?? metadata?.filesChanged ?? indexEntry?.filesChanged
        let unmodified = stats?.filesUnmodified
        return [
            "\(RunFormat.count(new)) new",
            "\(RunFormat.count(changed)) changed",
            "\(RunFormat.count(unmodified)) unmodified"
        ].joined(separator: " · ")
    }

    private func processedSummary(bytes: Int, files: Int?) -> String {
        guard let files else { return RunFormat.bytes(bytes) }
        return "\(RunFormat.bytes(bytes)) in \(RunFormat.count(files)) files"
    }

    /// Determinate whenever restic has reported a total; indeterminate while
    /// it is still scanning (`totalBytes == 0`).
    @ViewBuilder
    private func liveProgress(_ live: CurrentRunState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if live.totalBytes > 0 {
                ProgressView(value: min(max(live.percentDone, 0), 1)) {
                    Text(RunPhase.describe(live.phase).localizedCapitalized)
                } currentValueLabel: {
                    Text("\(RunFormat.bytes(live.bytesDone)) of \(RunFormat.bytes(live.totalBytes)) · "
                        + "\(RunFormat.count(live.filesDone)) of \(RunFormat.count(live.totalFiles)) files")
                        .monospacedDigit()
                }
            } else {
                ProgressView {
                    Text(RunPhase.describe(live.phase).localizedCapitalized)
                }
                .progressViewStyle(.linear)
            }
            if let file = live.currentFiles.first {
                Text(file)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file)
            }
        }
    }

    // MARK: - Log

    private var logPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Log").font(.headline)
                if isRunning {
                    Toggle("Follow", isOn: $followTail)
                        .toggleStyle(.checkbox)
                        .help("Keep scrolling to the newest output while this run is in progress.")
                }
                Spacer(minLength: 0)
                Button {
                    copy(log.text)
                } label: {
                    Label("Copy Log", systemImage: "doc.on.doc")
                }
                .disabled(log.text.isEmpty)
                .help("Copy the log text shown here to the clipboard.")

                Button {
                    model.revealLogInFinder(runId: runId)
                } label: {
                    Label("Reveal log in Finder", systemImage: "folder")
                }
                .disabled(!logFileExists)
                .help(logFileExists
                    ? logURL.path
                    : "This run has no log file — it ended before restic was started.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(logText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(log.text.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.logBottomAnchor)
                    }
                    .padding(12)
                }
                .onChange(of: log.text) { _, _ in
                    guard isRunning, followTail else { return }
                    proxy.scrollTo(Self.logBottomAnchor, anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(Self.logBottomAnchor, anchor: .bottom)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var logText: String {
        if !log.text.isEmpty { return log.text }
        if !log.hasLogFile {
            return "No log file for this run."
        }
        return isRunning ? "Waiting for output…" : "The log for this run is empty."
    }

    // MARK: - Clipboard

    private func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Copies and flips the button to "Copied" briefly — the snapshot ID is
    /// a long hex string, so silent success is hard to trust.
    private func copySnapshotId(_ string: String) {
        copy(string)
        didCopySnapshotId = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            didCopySnapshotId = false
        }
    }
}
