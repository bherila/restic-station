import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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

    /// The basename a symlink's destination must have before it is even
    /// *considered* ours — necessary but never sufficient. See `isOwned`
    /// for the full ownership rule: basename alone is not enough to tell
    /// "our symlink, bundle moved" apart from "a foreign binary that
    /// happens to share our helper's name."
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

    /// The prefix a GUI install button should default to.
    ///
    /// `cli install` at the command line defaults to `.system`
    /// (`/usr/local/bin`) because that is what most users on a
    /// Homebrew-provisioned Mac expect and it happens to already be
    /// user-writable there — Homebrew itself takes ownership of
    /// `/usr/local` on Intel Macs. But a Settings button is clicked from
    /// Finder/launchd, not a Homebrew shell, and on a clean or
    /// non-Homebrew Mac `/usr/local/bin` is root-owned or does not exist
    /// at all: the one-click install would silently fail every time. `.user`
    /// (`~/.local/bin`) never needs elevated privileges on any Mac, so it is
    /// the default that actually works out of the box. The Settings row
    /// still lets a user pick `.system` explicitly if they know their
    /// machine supports it.
    public static func recommendedGUIPrefix() -> Prefix { .user }

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
            // Deliberately operation-neutral wording ("touch", not "replace"
            // or "remove"): this same error is thrown by both `install`
            // (which would otherwise overwrite the entry) and `uninstall`
            // (which would otherwise delete it), and "refusing to replace"
            // read as nonsensical from `uninstall`, which never replaces
            // anything.
            "refusing to touch \(path): it already exists and is not a restic-station symlink we manage. "
                + "Remove it by hand first if you want restic-station's CLI symlink there instead."
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
            guard isOwned(existingDestination, expectedTarget: target, fileManager: fileManager) else {
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
    /// - Parameter target: the caller's current expected target (same value
    ///   `install` would use right now) — required so ownership can be
    ///   verified against a real path, not just a basename. See `isOwned`.
    /// - Throws: ``ForeignEntryError`` if something exists there that this
    ///   code did not create. Never removes it.
    @discardableResult
    public static func uninstall(
        target: String,
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> UninstallOutcome {
        let linkPath = directory.appendingPathComponent(linkName, isDirectory: false).path

        if let existingDestination = symlinkDestination(at: linkPath, fileManager: fileManager) {
            guard isOwned(existingDestination, expectedTarget: target, fileManager: fileManager) else {
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
        let owned = existingDestination.map {
            isOwned($0, expectedTarget: currentTarget, fileManager: fileManager)
        } ?? false
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

    // MARK: - Failure advice

    /// A user-facing explanation for an error thrown by `install`/
    /// `uninstall`, for the GUI (`App/Sources/ViewModels/AppModel+CLI.swift`)
    /// to show instead of a bare `"\(error)"`. Lives in Core, not the App
    /// target, so it is unit-testable — the App target has no test target
    /// of its own (issue #40).
    ///
    /// The case this exists for: `.system` (`/usr/local/bin`) is root-owned
    /// or absent on a clean Mac, so a Finder-launched app's install button
    /// fails there with a raw permission error that does not say what to
    /// do. `recommendedGUIPrefix()` already defaults the button away from
    /// that prefix, but a user can still pick `.system` explicitly (or a
    /// `--user` home directory can itself be unwritable in unusual setups),
    /// so the failure path still needs to explain itself rather than just
    /// print the underlying `NSError`.
    public static func installFailureAdvice(error: Error, directory: URL, prefix: Prefix) -> String {
        if let foreign = error as? ForeignEntryError {
            return foreign.description
        }
        let description = (error as NSError).localizedDescription
        let looksLikePermissionError = description.localizedCaseInsensitiveContains("permission")
            || description.localizedCaseInsensitiveContains("not permitted")
        guard looksLikePermissionError else {
            return "Couldn't install to \(directory.path): \(description)"
        }
        switch prefix {
        case .system:
            let userPrefixHint = Prefix.user.directory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            return "Couldn't write to \(directory.path) — it needs administrator privileges on this Mac. "
                + "Switch to the \"Just me\" location (\(userPrefixHint.path)) instead, which never needs "
                + "elevated permissions."
        case .user:
            return "Couldn't write to \(directory.path): \(description). Check that your home directory is "
                + "writable, or install from Terminal instead."
        }
    }

    // MARK: - Ownership

    /// Whether the symlink whose destination is `destination` is "ours" —
    /// safe for `install`/`uninstall` to repoint or remove without asking.
    ///
    /// A basename match alone is **not** enough: a `restic-station` entry
    /// pointing at *any* other executable named `restic-station-helper` —
    /// a second checkout, a duplicate app bundle, an unrelated tool that
    /// happens to share the name — would incorrectly be judged ours, and
    /// `install`/`uninstall` would then repoint or delete a symlink that
    /// belongs to something else entirely. That was the bug: basename is
    /// attacker- and coincidence-controlled, so it cannot be the whole
    /// story for a check that gates deleting or overwriting someone else's
    /// entry.
    ///
    /// The rule, in order:
    ///   1. The basename must match `ownedTargetBasename` at all — this is
    ///      the cheap pre-filter, still necessary, just not sufficient.
    ///   2. If `destination` is exactly `expectedTarget` (the caller's
    ///      current, real, in-bundle path), it is unambiguously ours: this
    ///      is precisely what a fresh `install` from *this* bundle would
    ///      have written.
    ///   3. Otherwise, it is ours only if `destination` does not currently
    ///      exist on disk at all (a dangling symlink).
    ///
    /// Step 3 is what makes repair possible: `install`/`uninstall` are
    /// always called with *today's* target, but a stale symlink of ours
    /// points at *yesterday's* bundle path, which by definition is not
    /// `expectedTarget` anymore. When a `.app` bundle moves or is deleted
    /// out from under a symlink, the old path stops existing — nothing
    /// else could be depending on a path with nothing at the end of it, so
    /// repairing or removing that symlink is safe. A foreign symlink from
    /// a live, distinct install is never in this state: something real is
    /// still sitting at its destination, by construction of "distinct and
    /// live."
    ///
    /// This does leave one case genuinely ambiguous, and it is called out
    /// here rather than silently guessed: if the *same* app is present at
    /// two live locations (e.g. a duplicate `.app` bundle, or a second
    /// build left behind after a move-and-rebuild) and the symlink points
    /// at the other, still-existing copy, this rule cannot distinguish
    /// "our own stale symlink, pointing at another real copy of
    /// ourselves" from "a genuinely foreign live binary that happens to
    /// share our helper's basename" — both present as a basename match, a
    /// real file at the other end, and a destination that is not
    /// `expectedTarget`. We resolve that ambiguity in favor of the
    /// non-destructive answer: such a symlink is treated as foreign, and
    /// `install`/`uninstall` refuse and explain rather than guess. A user
    /// in that situation removes the old copy (or the symlink) by hand.
    ///
    /// **Absolute destinations only.** `expectedTarget` — and therefore
    /// every `destination` a symlink of ours could ever hold — is always
    /// the caller's `FileSecretStore.currentExecutablePath()`, which is
    /// `realpath`-resolved (Darwin: `_NSGetExecutablePath` + `realpath`;
    /// Linux: `readlink /proc/self/exe`) before it ever reaches `install`.
    /// It is never a relative string. So a relative `destination`
    /// (`vendor/restic-station-helper`, the ordinary shape of a GNU-stow,
    /// nix/home-manager, or hand-`ln -s`-managed symlink) is definitionally
    /// not one of ours, independent of anything step 3 would otherwise
    /// conclude about it — this is checked and rejected before step 3 runs
    /// at all.
    ///
    /// This is not pedantry: step 3's existence check resolves a relative
    /// path against the *process* current working directory, not the
    /// symlink's own parent directory (`destinationOfSymbolicLink` returns
    /// the stored string verbatim; nothing here is symlink-relative-aware).
    /// Without this guard, a live, working *foreign* relative symlink —
    /// exactly the stow/home-manager case above — would almost always
    /// resolve to "does not exist at this CWD" and be misread as our own
    /// dangling stale link, making `install`/`uninstall` repoint or delete
    /// someone else's live entry. Worse, the verdict would depend on the
    /// invoking process's CWD, which is disqualifying for a check gating
    /// destructive filesystem operations. Refusing outright for any
    /// non-absolute destination removes that dependency entirely.
    private static func isOwned(
        _ destination: String,
        expectedTarget: String,
        fileManager: FileManager
    ) -> Bool {
        guard (destination as NSString).lastPathComponent == ownedTargetBasename else {
            return false
        }
        if destination == expectedTarget {
            return true
        }
        guard destination.hasPrefix("/") else {
            return false
        }
        // Step 3: ours only if nothing is there. `pathIsDefinitelyAbsent`
        // is used instead of `fileManager.fileExists(atPath:)` for the same
        // "don't misread an inconclusive answer as absence" reason as the
        // guard above: a same-basename symlink chain that loops back on
        // itself (`restic-station -> x/restic-station-helper ->
        // restic-station`) makes `stat` fail with `ELOOP`, which
        // `fileExists` also collapses to `false` ("not there") — so,
        // pre-fix, a loop was judged dangling-and-ours and got "repaired"
        // or removed. A loop is inert (nothing is actually reachable
        // through it, so nothing of value is destroyed by touching it) but
        // it is still not evidence of absence, so it is deliberately kept
        // out of the "definitely absent" verdict rather than special-cased
        // into it. In practice a loop's first hop is also relative in the
        // realistic construction above, so the guard right above this
        // already refuses it; `pathIsDefinitelyAbsent` is the second,
        // independent layer for a hypothetical all-absolute loop.
        return pathIsDefinitelyAbsent(destination)
    }

    /// Whether `path` is provably *absent* — `stat` fails with `ENOENT`
    /// ("no such file") or `ENOTDIR` (a nonexistent path component along
    /// the way). Deliberately stricter than `FileManager.fileExists`,
    /// which collapses every `stat` failure into the same `false`,
    /// including `ELOOP` (a symlink cycle) and `EACCES` (a permission-
    /// denied intermediate directory) — neither of which means "nothing is
    /// there." `isOwned`'s repair path uses "absent" as its proof that
    /// nothing else can be depending on the old destination, so an
    /// inconclusive `stat` failure must not be read as that proof.
    private static func pathIsDefinitelyAbsent(_ path: String) -> Bool {
        var info = stat()
        if path.withCString({ stat($0, &info) }) == 0 {
            return false
        }
        return errno == ENOENT || errno == ENOTDIR
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
