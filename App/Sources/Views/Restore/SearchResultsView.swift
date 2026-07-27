import ResticStationCore
import SwiftUI

// MARK: - SearchRow

/// One `find` match, flattened out of the per-snapshot groups restic
/// returns (`docs/restic-cli.md` §find: the JSON array has one element per
/// snapshot with hits).
struct SearchRow: Identifiable, Hashable {
    /// Snapshot + path: the same file can match in several snapshots.
    let id: String
    let snapshotID: String
    let path: String
    let isDirectory: Bool
    let size: Int?
    let mtime: Date?

    var name: String { (path as NSString).lastPathComponent }
    var item: RestoreItem { RestoreItem(path: path, isDirectory: isDirectory) }

    static func rows(from results: [FindResult]) -> [SearchRow] {
        results.flatMap { result in
            result.matches.map { match in
                SearchRow(
                    id: "\(result.snapshot)\u{0}\(match.path)",
                    snapshotID: result.snapshot,
                    path: match.path,
                    isDirectory: match.type == .dir,
                    size: match.size,
                    mtime: match.mtime
                )
            }
        }
    }
}

// MARK: - SearchResultsView

/// `docs/ui-spec.md` §Restore: "results list (path, size, snapshot) →
/// select for restore".
struct SearchResultsView: View {
    let rows: [SearchRow]
    let state: RestoreBrowser.SearchState
    /// Full snapshot id → the short id and time shown in the row.
    let snapshotLabel: (String) -> String
    @Binding var selection: Set<String>

    var body: some View {
        switch state {
        case .searching:
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Search failed", systemImage: "exclamationmark.magnifyingglass")
            } description: {
                Text(message)
            }
        case .done(let pattern) where rows.isEmpty:
            ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing in this repository matches “\(pattern)”. "
                    + "Patterns are shell globs matched against path components — try `*\(pattern)*`.")
            }
        case .done, .idle:
            List(selection: $selection) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.isDirectory ? "folder" : "doc")
                            .foregroundStyle(row.isDirectory ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                                .lineLimit(1)
                            Text(row.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 12)
                        if let size = row.size, !row.isDirectory {
                            Text(size.formatted(.byteCount(style: .file)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(snapshotLabel(row.snapshotID))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospaced()
                    }
                    .tag(row.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}
