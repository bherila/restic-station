import AppKit
import Foundation
import ResticStationCore

/// The reads the Runs screen (T15, `docs/ui-spec.md` §Runs) needs from
/// `AppModel`, kept out of `AppModel.swift` so the history UI can grow
/// without touching the shell.
///
/// Everything here is either a projection of `StateWatcher`'s published
/// state or a lookup in the loaded config — nothing mutates. SwiftUI sees
/// watcher changes through `AppModel` because `observeCollaborators()`
/// re-derives (and therefore republishes) on every watcher event, so a view
/// that reads `model.recentRuns` is redrawn exactly when the on-disk history
/// changes.
extension AppModel {

    // MARK: - Live state projections

    /// `runs/index.jsonl`, newest first (finished runs only — an in-flight
    /// run has no index line yet; see `currentRuns`).
    var recentRuns: [RunIndexEntry] { stateWatcher.recentRuns }

    /// In-flight run progress keyed by `BackupSet.id`
    /// (`state/current-run-<setId>.json`).
    var currentRuns: [UUID: CurrentRunState] { stateWatcher.currentRuns }

    // MARK: - Naming

    /// The set's configured name, or a short id for a run whose set has
    /// since been deleted from the config (history outlives configuration).
    func setName(for setId: UUID) -> String {
        config.sets.first { $0.id == setId }?.name ?? "Deleted set \(Self.shortId(setId))"
    }

    /// The destination's configured label, or a short id when the run
    /// predates a destination's removal.
    func destinationLabel(setId: UUID?, destId: UUID?) -> String {
        guard let destId else { return "—" }
        if let setId, let label = config.sets.first(where: { $0.id == setId })?
            .destinations.first(where: { $0.id == destId })?.label {
            return label
        }
        // Destinations are unique across the whole config (data-model.md
        // invariant 2), so a set-independent lookup is still unambiguous and
        // recovers the label when a run's set id no longer resolves.
        for set in config.sets {
            if let label = set.destinations.first(where: { $0.id == destId })?.label {
                return label
            }
        }
        return "Deleted destination \(Self.shortId(destId))"
    }

    private static func shortId(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    // MARK: - Run records

    /// `runs/<runId>/metadata.json`, or `nil` when it is missing or
    /// unreadable. Run records are history, not a source of truth the UI may
    /// crash on (`docs/data-model.md` §Versioning), so failures collapse to
    /// `nil` and the caller renders what the index line already told it.
    func runMetadata(runId: String) -> RunMetadata? {
        try? runStore.metadata(runId: runId)
    }

    /// `runs/<runId>/log.txt`. The file may not exist (a run that failed
    /// before restic was spawned writes no log).
    func runLogURL(runId: String) -> URL {
        runStore.logURL(runId: runId)
    }

    /// Selects the log file in Finder (`docs/ui-spec.md` §Runs: "Reveal log
    /// in Finder"). No-op when the file does not exist — callers disable the
    /// button in that case.
    func revealLogInFinder(runId: String) {
        let url = runLogURL(runId: runId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Actions

    /// Why "Back Up Now" is unavailable for this set, or `nil` when it is
    /// available. Every disabled control in the Runs toolbar carries this as
    /// its `help(_:)` — "what failed, why, one next step"
    /// (`docs/ui-spec.md` §Copy/tone rules).
    func backUpNowUnavailableReason(setId: UUID) -> String? {
        guard isBusy(setId: setId) else { return nil }
        let name = setName(for: setId)
        if let phase = currentRuns[setId]?.phase {
            return "\(name) is busy — \(RunPhase.describe(phase)). Wait for it to finish, then try again."
        }
        return "\(name) is already starting. Wait for it to finish, then try again."
    }
}
