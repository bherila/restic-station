import Foundation

/// Manages the `restic-station` symlink that makes the embedded helper
/// reachable from an ordinary shell (`docs/tasks/T28`, issue #30).
///
/// The embedded binary itself must never move or be copied:
/// `project.yml` embeds and code-signs it into the app bundle, and both
/// `SMAppService` registration and Full Disk Access attribution bind to
/// that on-disk path (`docs/keychain-and-fda.md` §2/§3). A symlink is
/// transparent to both — the kernel resolves it before anything executes,
/// so the process that actually runs is the bundle binary itself, not a
/// copy. (This is the empirical claim the T28 PR's `fda-check`-through-the-
/// symlink transcript exists to verify; TCC attribution is exactly the kind
/// of behavior that must be checked, never assumed.)
///
/// Pure filesystem logic — no `ArgumentParser`, no process spawning — so it
/// is fully unit-testable here in Core. Both the CLI subcommand
/// (`Helper/Sources/Commands/Cli.swift`) and the Settings row
/// (`App/Sources/ViewModels/AppModel+CLI.swift`) are thin callers of this
/// one type, so "installed" cannot mean something different in the two
/// surfaces — relevant because the App target itself has no test target
/// (issue #40) and must not accumulate logic worth testing.
public enum CLIInstaller {

    /// The symlink's fixed name. Never derived from the target, so the
    /// built product's actual name (`restic-station-helper` — which must
    /// never change: `project.yml`, the embedded bundle path, and the
    /// launchd agent all key on it) still produces a friendly
    /// `restic-station` on `PATH`.
    public static let linkName = "restic-station"

    /// The basename ownership is checked against. Any symlink at the
    /// target path whose destination ends in this name is treated as
    /// "ours" — installed by this feature, possibly stale (pointing at a
    /// bundle that has since moved or been rebuilt) — and is safe to
    /// repair or remove. Anything else (a plain file, a directory, or a
    /// symlink to something differently named) is a foreign entry this
    /// code refuses to touch.
    public static let ownedTargetBasename = "restic-station-helper"

    // MARK: - Prefix

    /// Where the symlink goes. `docs/tasks/T28`: system-wide by default,
    /// `--user` for a location that needs no elevated privileges.
    public enum Prefix: Sendable, Equatable {
        case system
        case user

        public func directory(homeDirectory: URL) -> URL {
            switch self {
            case .system:
                return URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
            case .user:
                return homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
            }
        }
    }

    // MARK: - Foreign entry

    /// Thrown by `install`/`uninstall` when something exists at the link
    /// path that this code did not create — a plain file, a directory, or a
    /// symlink pointing at something other than ``ownedTargetBasename``.
    /// Neither operation ever removes or overwrites such an entry.
    public struct ForeignEntryError: Error, Equatable, CustomStringConvertible {
        public let path: String

        public init(path: String) {
            self.path = path
        }

        public var description: String {
            "refusing to replace \(path): it already exists and is not a restic-station symlink. "
                + "Remove it by hand first if you want the CLI installed there."
        }
    }

    // MARK: - Install

    public enum InstallOutcome: Sendable, Equatable {
        /// Nothing was there before; a fresh symlink now points at `target`.
        case created(linkPath: String)
        /// The symlink already existed and already pointed at `target` — no
        /// filesystem change was made.
        case alreadyInstalled(linkPath: String)
        /// A symlink of ours existed but pointed somewhere else (a moved or
        /// rebuilt bundle) — it has been repointed at `target`.
        case repaired(linkPath: String, previousTarget: String)
    }

    /// Creates or repairs `<directory>/restic-station` → `target`. Always a
    /// symlink, never a copy — moving or copying the embedded binary out of
    /// the bundle would break FDA attribution and the background agent; a
    /// symlink never touches the binary, only a pointer to it.
    ///
    /// - Throws: ``ForeignEntryError`` if the target path exists and is not
    ///   one of our symlinks. Never overwrites in that case. Also
    ///   propagates any underlying filesystem error (e.g. no permission to
    ///   create `directory`).
    @discardableResult
    public static func install(
        target: String,
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> InstallOutcome {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let linkPath = directory.appendingPathComponent(linkName, isDirectory: false).path

        if let existingDestination = symlinkDestination(at: linkPath, fileManager: fileManager) {
            guard isOwned(existingDestination) else {
                throw ForeignEntryError(path: linkPath)
            }
            if existingDestination == target {
                return .alreadyInstalled(linkPath: linkPath)
            }
            try fileManager.removeItem(atPath: linkPath)
            try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
            return .repaired(linkPath: linkPath, previousTarget: existingDestination)
        }

        guard !fileManager.fileExists(atPath: linkPath) else {
            throw ForeignEntryError(path: linkPath)
        }
        try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
        return .created(linkPath: linkPath)
    }

    // MARK: - Uninstall

    public enum UninstallOutcome: Sendable, Equatable {
        case removed(linkPath: String)
        /// Nothing was there — removing an already-absent symlink succeeds.
        case notInstalled(linkPath: String)
    }

    /// Idempotent removal: a target that is not there is success, not an
    /// error.
    ///
    /// - Throws: ``ForeignEntryError`` if something exists there that this
    ///   code did not create. Never removes it.
    @discardableResult
    public static func uninstall(
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> UninstallOutcome {
        let linkPath = directory.appendingPathComponent(linkName, isDirectory: false).path

        if let existingDestination = symlinkDestination(at: linkPath, fileManager: fileManager) {
            guard isOwned(existingDestination) else {
                throw ForeignEntryError(path: linkPath)
            }
            try fileManager.removeItem(atPath: linkPath)
            return .removed(linkPath: linkPath)
        }

        guard !fileManager.fileExists(atPath: linkPath) else {
            throw ForeignEntryError(path: linkPath)
        }
        return .notInstalled(linkPath: linkPath)
    }

    // MARK: - Status

    public struct Status: Sendable, Equatable {
        public let linkPath: String
        /// `true` only for a symlink of ours (owned basename) — a foreign
        /// file at the same path is reported as not installed, since it is
        /// not something this feature put there.
        public let installed: Bool
        /// What the symlink currently resolves to, if anything (ours or
        /// foreign) exists at `linkPath` as a symlink.
        public let resolvedTarget: String?
        /// `installed` AND pointing at the caller's current expected
        /// target. `false` after a bundle move/rebuild, until repaired.
        public let upToDate: Bool
        public let onPath: Bool
        /// `true` when something exists at `linkPath` that is not one of
        /// our symlinks — `install`/`uninstall` will refuse until it is
        /// removed by hand.
        public let foreignEntryPresent: Bool
    }

    /// `currentTarget` is what a fresh `install` would point at right now
    /// (the caller's resolved current-executable path) — used only to
    /// compute ``Status/upToDate``.
    public static func status(
        directory: URL,
        currentTarget: String,
        pathEnvironment: String?,
        fileManager: FileManager = .default
    ) -> Status {
        let linkPath = directory.appendingPathComponent(linkName, isDirectory: false).path
        let existingDestination = symlinkDestination(at: linkPath, fileManager: fileManager)
        let owned = existingDestination.map(isOwned) ?? false
        let foreignEntryPresent = !owned
            && (existingDestination != nil || fileManager.fileExists(atPath: linkPath))
        return Status(
            linkPath: linkPath,
            installed: owned,
            resolvedTarget: existingDestination,
            upToDate: owned && existingDestination == currentTarget,
            onPath: isDirectoryOnPath(directory, pathEnvironment: pathEnvironment),
            foreignEntryPresent: foreignEntryPresent
        )
    }

    // MARK: - PATH

    /// Whether `directory` appears in `pathEnvironment` (`$PATH`,
    /// `:`-separated). Compares standardized paths so a trailing slash does
    /// not produce a false "not on PATH" warning.
    public static func isDirectoryOnPath(_ directory: URL, pathEnvironment: String?) -> Bool {
        guard let pathEnvironment else { return false }
        let target = directory.standardizedFileURL.path
        return pathEnvironment.split(separator: ":").contains { entry in
            URL(fileURLWithPath: String(entry), isDirectory: true).standardizedFileURL.path == target
        }
    }

    // MARK: - Ownership

    private static func isOwned(_ destination: String) -> Bool {
        (destination as NSString).lastPathComponent == ownedTargetBasename
    }

    /// The existing entry's symlink target, or `nil` if the path is absent
    /// or exists but is not a symlink (a plain file/directory — the caller
    /// tells those two apart with `fileManager.fileExists` itself).
    /// Deliberately does **not** follow the link: a dangling symlink (the
    /// "stale, bundle moved" case) must still be seen as a symlink here.
    private static func symlinkDestination(at path: String, fileManager: FileManager) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: path)
    }
}
