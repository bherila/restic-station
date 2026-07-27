import Foundation
import ResticStationCore

// MARK: - RestoreItem

/// One thing the user picked in the browser or the search results: an
/// **in-snapshot** path (always the `path` restic itself returned — see
/// `docs/restic-cli.md` §ls) plus whether it is a directory.
struct RestoreItem: Hashable, Sendable, Identifiable {
    let path: String
    let isDirectory: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

// MARK: - RestoreTarget

/// `docs/ui-spec.md` §Restore: "Target: 'Original location' or 'Choose
/// folder…'".
enum RestoreTarget: Equatable {
    case originalLocation
    case folder(URL)

    var folderURL: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    var isOriginalLocation: Bool { self == .originalLocation }
}

// MARK: - RestorePlan

/// Turns a selection plus a target into the three restic arguments that
/// actually decide what lands where: `--target`, the `<id>:<sub>` suffix,
/// and the `--include` patterns.
///
/// Two shapes, because "original location" and "some folder" mean different
/// things to restic:
///
/// - **Original location** — `--target /` and *absolute* include patterns.
///   restic recreates the full path under the target, so `/Users/me/a.txt`
///   is rewritten in place. No `--sub`: a sub-path would re-root the
///   restore and drop the leading directories.
/// - **Chosen folder** — `--sub <common parent directory>` and include
///   patterns *relative to it*, so the selection appears directly inside
///   the folder the user picked instead of buried under a recreated
///   `/Users/me/…` hierarchy. Include patterns are matched against paths
///   relative to the sub-root, which is exactly what `--sub` establishes.
///
/// A selected directory contributes two patterns — the directory itself and
/// `<dir>/**` — because restic's include patterns match paths, not subtrees:
/// without the second pattern the folder would be restored empty.
struct RestorePlan: Equatable {
    let targetPath: String
    /// In-snapshot `--sub`; `nil` restores from the snapshot root.
    let subpath: String?
    let includes: [String]

    static func make(items: [RestoreItem], target: RestoreTarget) -> RestorePlan {
        let normalized = items
            .map { RestoreItem(path: normalize($0.path), isDirectory: $0.isDirectory) }
            .reduce(into: [RestoreItem]()) { unique, item in
                if !unique.contains(item) { unique.append(item) }
            }

        switch target {
        case .originalLocation:
            return RestorePlan(
                targetPath: "/",
                subpath: nil,
                includes: normalized.flatMap { patterns(for: $0.path, isDirectory: $0.isDirectory) }
            )
        case .folder(let url):
            let root = commonParentDirectory(of: normalized.map(\.path))
            let includes = normalized.flatMap { item in
                patterns(for: relativePath(of: item.path, under: root), isDirectory: item.isDirectory)
            }
            return RestorePlan(
                targetPath: url.path,
                subpath: root == "/" ? nil : root,
                includes: includes
            )
        }
    }

    private static func patterns(for path: String, isDirectory: Bool) -> [String] {
        isDirectory ? [path, path + "/**"] : [path]
    }

    // MARK: - Path math

    /// Strips a trailing slash (except from the root) so component
    /// arithmetic below is exact.
    static func normalize(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// The deepest in-snapshot directory that *contains* every selected
    /// path. When a selected path is itself the common prefix (a lone
    /// selection, or a folder plus things inside it), its parent is used —
    /// the item has to be nameable *within* the root for an `--include`
    /// pattern to address it.
    static func commonParentDirectory(of paths: [String]) -> String {
        guard let first = paths.first else { return "/" }
        var prefix = components(of: first)
        for path in paths.dropFirst() {
            let other = components(of: path)
            var shared: [String] = []
            for (lhs, rhs) in zip(prefix, other) where lhs == rhs {
                shared.append(lhs)
            }
            prefix = shared
            if prefix.isEmpty { break }
        }
        if paths.contains(where: { components(of: $0) == prefix }) {
            prefix = Array(prefix.dropLast())
        }
        return prefix.isEmpty ? "/" : "/" + prefix.joined(separator: "/")
    }

    /// `("/src/sub/f.txt", under: "/src")` → `"/sub/f.txt"`.
    static func relativePath(of path: String, under root: String) -> String {
        guard root != "/" else { return path }
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count))
    }
}

// MARK: - Overwrite mode copy

extension ResticCommand.OverwriteMode {
    /// The four labels `docs/ui-spec.md` §Restore fixes for the picker.
    var pickerLabel: String {
        switch self {
        case .always: return "Always"
        case .ifChanged: return "Only if changed"
        case .ifNewer: return "Only if newer"
        case .never: return "Never overwrite"
        }
    }
}
