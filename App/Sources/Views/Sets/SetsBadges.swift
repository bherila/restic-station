import ResticStationCore
import SwiftUI

// MARK: - KindBadge

/// The destination-kind chip (`docs/ui-spec.md` §Backup Sets: "kind badge").
struct KindBadge: View {
    let kind: DestinationKind

    var body: some View {
        Label(SetsCopy.kindLabel(kind), systemImage: SetsCopy.kindSymbol(kind))
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Destination kind: \(SetsCopy.kindLabel(kind))")
    }
}

// MARK: - PrimaryTag

/// The `PRIMARY` tag in the destination table.
struct PrimaryTag: View {
    var body: some View {
        Text("PRIMARY")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

// MARK: - DestinationStatus

/// What the destination table's status dot says about one destination, in
/// priority order: a repository that is missing entirely outranks staleness,
/// which outranks a plain offline probe.
enum DestinationStatus: Equatable, Sendable {
    /// Probed and answered.
    case reachable
    /// Probed, answered, but has not synced within `stalenessWarningDays`.
    case stale
    /// Probe says the destination cannot be reached right now (unplugged
    /// volume, network down) — expected, not an error.
    case offline
    /// restic reached the location and found no repository there.
    case notInitialized
    /// Any other recorded probe error (wrong password, locked, …).
    case error
    /// Never probed — no `state/repo-status-<destId>.json` yet.
    case unknown

    var color: Color {
        switch self {
        case .reachable: return .green
        case .stale: return .yellow
        case .offline: return .secondary
        case .notInitialized, .error: return .red
        case .unknown: return .secondary
        }
    }

    var label: String {
        switch self {
        case .reachable: return "Reachable"
        case .stale: return "Stale"
        case .offline: return "Offline"
        case .notInitialized: return "Not initialized"
        case .error: return "Error"
        case .unknown: return "Not probed yet"
        }
    }

    /// Derives the status from the on-disk probe record plus the staleness
    /// decision already made by `HealthDerivation` (which owns the rule).
    static func derive(status: RepoStatus?, isStale: Bool) -> DestinationStatus {
        guard let status else {
            return isStale ? .stale : .unknown
        }
        if !status.reachable {
            if let lastError = status.lastError, AppModel.mentionsMissingRepository(lastError) {
                return .notInitialized
            }
            return status.lastError == nil ? .offline : offlineOrError(status.lastError)
        }
        return isStale ? .stale : .reachable
    }

    /// `Reachability` records environmental failures ("volume not mounted",
    /// "timed out", "keychain locked") as offline; anything else it recorded
    /// came from restic itself and needs attention.
    private static func offlineOrError(_ lastError: String?) -> DestinationStatus {
        guard let lastError else { return .offline }
        let environmental = ["volume not mounted", "timed out", "keychain locked", "could not"]
        let lowercased = lastError.lowercased()
        return environmental.contains(where: lowercased.contains) ? .offline : .error
    }
}

// MARK: - StatusDot

struct StatusDot: View {
    let status: DestinationStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(status.label)
    }
}

// MARK: - RunStatusBadge

/// The set list's "last run status badge".
struct RunStatusBadge: View {
    let health: SetHealth

    var body: some View {
        if health.isRunning {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("\(health.progressPercent ?? 0)%")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .help(helpText)
        }
    }

    private var title: String {
        guard let status = health.lastBackupStatus else { return "Never" }
        switch status {
        case .success: return "OK"
        case .warning: return "Warning"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .running: return "Running"
        }
    }

    private var symbol: String {
        guard let status = health.lastBackupStatus else { return "minus.circle" }
        switch status {
        case .success: return "checkmark.circle.fill"
        case .warning, .skipped: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        guard let status = health.lastBackupStatus else { return .secondary }
        switch status {
        case .success: return health.hasStaleDestination ? .yellow : .green
        case .warning, .skipped: return .yellow
        case .failed: return .red
        case .running: return .secondary
        }
    }

    private var helpText: String {
        guard let lastBackupAt = health.lastBackupAt else {
            return "This backup set has never run."
        }
        let formatter = RelativeDateTimeFormatter()
        let relative = formatter.localizedString(for: lastBackupAt, relativeTo: Date())
        if health.hasStaleDestination {
            return "Last backup \(relative). One or more destinations are stale."
        }
        return "Last backup \(relative)."
    }
}

// MARK: - InlineMessage

/// The set editor's inline field message: yellow for warnings (nested source
/// paths, iCloud), red for validation errors.
struct InlineMessage: View {
    enum Level {
        case warning
        case error
        case info

        var symbol: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "exclamationmark.octagon.fill"
            case .info: return "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .warning: return .yellow
            case .error: return .red
            case .info: return .secondary
            }
        }
    }

    let level: Level
    let text: String

    init(_ text: String, level: Level = .error) {
        self.text = text
        self.level = level
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: level.symbol)
                .foregroundStyle(level.tint)
            Text(text)
                .foregroundStyle(level == .error ? Color.primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
