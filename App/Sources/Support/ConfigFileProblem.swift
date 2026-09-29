import Foundation
import ResticStationCore

/// Why `config.json` itself could not be loaded, kept apart from the
/// operator-facing `AppModel.configLoadError` text (which can also carry a
/// `machine.json` failure) so the screens that list backup sets can say
/// *why* they are empty instead of showing the first-run state.
///
/// The common case is `newerSchema`: a newer Restic Station on another
/// machine migrated the shared config. Nothing is lost — this copy just
/// cannot read it — and the first-run screen ("No backup sets yet", "Create
/// your first set") reads as data loss and offers a write that is refused.
enum ConfigFileProblem: Equatable {
    case newerSchema(found: Int, supported: Int)
    case unreadable(detail: String)

    init(_ error: Error) {
        if case ConfigError.newerVersion(let found, let supported) = error {
            self = .newerSchema(found: found, supported: supported)
        } else {
            self = .unreadable(detail: String(describing: error))
        }
    }

    var title: String {
        switch self {
        case .newerSchema:
            return "Backup sets are in a newer format"
        case .unreadable:
            return "Backup sets couldn't be loaded"
        }
    }

    /// Used by the Sets screen when no earlier config is being shown.
    var explanation: String {
        switch self {
        case .newerSchema(let found, let supported):
            return "config.json uses schema v\(found), and this copy of Restic Station reads up to "
                + "v\(supported). It was probably upgraded by a newer Restic Station on another machine. "
                + "Your backup sets and backups are unchanged — update this copy to see and run them. "
                + "Nothing is written to config.json until then."
        case .unreadable(let detail):
            return "Restic Station could not read config.json (\(detail)). Your backup sets are not "
                + "shown and nothing is written to the file until it can be read again. Fix or move it, "
                + "then choose Reload Settings or reopen Restic Station."
        }
    }

    /// Used above a set list that is still showing the last config this
    /// session could read (a reload failed after a good load).
    var staleListBanner: String {
        switch self {
        case .newerSchema(let found, _):
            return "config.json was changed to schema v\(found), which this copy can't read. Showing the "
                + "last settings it could read; editing is disabled until Restic Station is updated."
        case .unreadable:
            return "config.json can no longer be read. Showing the last settings that could be read; "
                + "editing is disabled until the file is fixed."
        }
    }

    /// One line for the menu bar extra.
    var menuBarLine: String {
        switch self {
        case .newerSchema:
            return "Backup sets need a newer Restic Station"
        case .unreadable:
            return "Backup sets couldn't be loaded"
        }
    }

    var offersUpdateCheck: Bool {
        if case .newerSchema = self { return true }
        return false
    }
}
