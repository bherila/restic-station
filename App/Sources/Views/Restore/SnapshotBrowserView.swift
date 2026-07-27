import ResticStationCore
import SwiftUI

/// The lazy snapshot tree (`docs/ui-spec.md` §Restore: "browser: lazy
/// expandable tree starting at `/` via `ls --json` … multi-select;
/// breadcrumb path").
///
/// **Path discipline.** Every listing this view asks for is addressed by the
/// `path` field of a node restic returned — never by joining names
/// (`docs/restic-cli.md` §ls). The only literal path is the root `/`, which
/// is where the doc says to start. Breadcrumb strings are prefixes of a real
/// node path and are used solely for display and for collapsing the
/// expansion set; they are never sent to restic.
struct SnapshotBrowserView: View {
    @ObservedObject var browser: RestoreBrowser
    let snapshot: Snapshot
    @Binding var selection: Set<String>

    /// In-snapshot paths of the directories currently expanded.
    @State private var expanded: Set<String> = []
    /// The directory the breadcrumb bar describes.
    @State private var focusPath = "/"

    private static let rootPath = "/"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumbs
            Divider()
            content
        }
        .onAppear { load(path: Self.rootPath) }
        .onChange(of: snapshot.id) { _, _ in
            expanded = []
            focusPath = Self.rootPath
            selection = []
            load(path: Self.rootPath)
        }
    }

    // MARK: - Breadcrumbs

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(breadcrumbEntries, id: \.path) { entry in
                    if entry.path != Self.rootPath {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        collapse(to: entry.path)
                    } label: {
                        Label(entry.name, systemImage: entry.path == Self.rootPath ? "externaldrive" : "folder")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(entry.path == focusPath ? Color.primary : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 28)
    }

    private var breadcrumbEntries: [(path: String, name: String)] {
        var entries: [(path: String, name: String)] = [(Self.rootPath, "Snapshot root")]
        var accumulated = ""
        for component in RestorePlan.components(of: focusPath) {
            accumulated += "/" + component
            entries.append((accumulated, component))
        }
        return entries
    }

    // MARK: - Tree

    @ViewBuilder
    private var content: some View {
        if let message = browser.error(snapshotID: snapshot.id, path: Self.rootPath) {
            ContentUnavailableView {
                Label("This snapshot could not be listed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { load(path: Self.rootPath, force: true) }
            }
        } else if browser.children(snapshotID: snapshot.id, path: Self.rootPath) == nil {
            ProgressView("Reading the snapshot…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(rows) { row in
                    rowView(row)
                        .tag(row.id)
                        // "Empty folder" / error rows are annotations, not
                        // things that can be restored.
                        .selectionDisabled(!row.isSelectable)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { _ in
                Button("Deselect All") { selection = [] }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row.kind {
        case .node(let node):
            HStack(spacing: 6) {
                disclosure(for: node)
                Image(systemName: symbolName(for: node))
                    .foregroundStyle(node.type == .dir ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if let size = node.size, node.type != .dir {
                    Text(size.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(node.mtime.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, CGFloat(row.depth) * 14)
        case .empty:
            Text("Empty folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(row.depth) * 14 + 22)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(row.depth) * 14 + 22)
        }
    }

    @ViewBuilder
    private func disclosure(for node: LsNode) -> some View {
        if node.type == .dir {
            if browser.isLoading(snapshotID: snapshot.id, path: node.path) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16)
            } else {
                Button {
                    toggle(node)
                } label: {
                    Image(systemName: expanded.contains(node.path) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded.contains(node.path) ? "Collapse" : "Expand")
            }
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    private func symbolName(for node: LsNode) -> String {
        switch node.type {
        case .dir: return expanded.contains(node.path) ? "folder.fill" : "folder"
        case .symlink: return "arrowshape.turn.up.right"
        case .file, .other: return "doc"
        }
    }

    // MARK: - Row flattening

    private struct Row: Identifiable {
        enum Kind {
            case node(LsNode)
            case empty
            case failed(String)
        }

        let id: String
        let depth: Int
        let kind: Kind

        /// Node rows are identified by the in-snapshot path restic
        /// returned, which is exactly what the selection carries.
        var isSelectable: Bool {
            if case .node = kind { return true }
            return false
        }
    }

    /// Depth-first flattening of the expanded subtree. Only cached listings
    /// contribute rows; an expanded directory whose listing is still in
    /// flight simply shows its spinner and no children yet.
    private var rows: [Row] {
        var result: [Row] = []
        appendRows(of: Self.rootPath, depth: 0, into: &result)
        return result
    }

    private func appendRows(of path: String, depth: Int, into result: inout [Row]) {
        guard let nodes = browser.children(snapshotID: snapshot.id, path: path) else { return }
        if nodes.isEmpty, depth > 0 {
            result.append(Row(id: path + "\u{0}empty", depth: depth, kind: .empty))
            return
        }
        for node in nodes {
            result.append(Row(id: node.path, depth: depth, kind: .node(node)))
            guard node.type == .dir, expanded.contains(node.path) else { continue }
            if let message = browser.error(snapshotID: snapshot.id, path: node.path) {
                result.append(Row(id: node.path + "\u{0}error", depth: depth + 1, kind: .failed(message)))
            } else {
                appendRows(of: node.path, depth: depth + 1, into: &result)
            }
        }
    }

    // MARK: - Actions

    private func toggle(_ node: LsNode) {
        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            expanded.insert(node.path)
            focusPath = node.path
            load(path: node.path)
        }
    }

    private func collapse(to path: String) {
        focusPath = path
        guard path != Self.rootPath else {
            expanded = []
            return
        }
        // Keep only ancestors of (and including) the crumb.
        expanded = expanded.filter { path == $0 || path.hasPrefix($0 + "/") }
        expanded.insert(path)
    }

    private func load(path: String, force: Bool = false) {
        browser.loadChildren(snapshotID: snapshot.id, path: path, force: force)
    }
}
