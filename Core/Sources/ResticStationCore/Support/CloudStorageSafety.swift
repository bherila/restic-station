import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Safety policy for File Provider and iCloud-backed paths.
///
/// Cloud-backed *sources* may contain dataless placeholders. Restic's
/// `--exclude-cloud-files` flag skips those files instead of asking macOS to
/// hydrate them. A cloud-backed *repository* is different: every index and
/// pack is part of one repository, so skipping an evicted file would make the
/// repository incomplete. Repository operations are therefore refused while
/// any dataless entry is present.
public enum CloudStorageSafety {
    /// Whether `path` lies under one of the two standard macOS roots used by
    /// iCloud Drive and File Provider services such as OneDrive, SharePoint,
    /// Google Drive and Dropbox.
    ///
    /// Symlinks are resolved on both sides, so `~/OneDrive/Documents` counts
    /// when `~/OneDrive` points into `~/Library/CloudStorage` — restic follows
    /// intermediate symlinks when it walks a source, and so does a repository
    /// path. On macOS the comparison ignores case, matching the default APFS
    /// volume; a path typed as `~/library/cloudstorage` reaches the same files.
    public static func isCloudSyncedPath(
        _ path: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard !standardized.isEmpty else { return false }

        let candidates = Set([standardized, resolvingSymlinks(standardized)].map(comparable))
        let homes = Set([
            (homeDirectory as NSString).standardizingPath,
            resolvingSymlinks((homeDirectory as NSString).standardizingPath),
        ])
        let roots = homes.flatMap { home in
            ["Library/Mobile Documents", "Library/CloudStorage"].map {
                comparable((home as NSString).appendingPathComponent($0))
            }
        }
        return candidates.contains { candidate in
            roots.contains { candidate == $0 || candidate.hasPrefix($0 + "/") }
        }
    }

    public static func containsCloudBackedSource(
        _ sources: [String],
        homeDirectory: String = NSHomeDirectory()
    ) -> Bool {
        sources.contains { isCloudSyncedPath($0, homeDirectory: homeDirectory) }
    }

    /// Returns the first dataless entry relative to `repositoryPath` (`.` for
    /// the repository directory itself), or nil when every entry is resident
    /// or the repository is not in a cloud-synced folder. Enumerating names
    /// and `lstat` metadata does not open file contents and therefore does
    /// not trigger hydration. Always nil off macOS, where no File Provider
    /// placeholders exist.
    public static func firstDatalessEntry(inRepository repositoryPath: String) -> String? {
        #if canImport(Darwin)
        return firstDatalessEntry(
            inRepository: repositoryPath,
            homeDirectory: NSHomeDirectory(),
            isDataless: { path in
                var info = stat()
                return lstat(path, &info) == 0 && (info.st_flags & UInt32(SF_DATALESS)) != 0
            }
        )
        #else
        return nil
        #endif
    }

    /// The platform-neutral walk behind ``firstDatalessEntry(inRepository:)``,
    /// with the dataless test injected so it can run on any host.
    static func firstDatalessEntry(
        inRepository repositoryPath: String,
        homeDirectory: String,
        isDataless: (String) -> Bool
    ) -> String? {
        guard isCloudSyncedPath(repositoryPath, homeDirectory: homeDirectory) else { return nil }

        // The repository directory itself can be a File Provider placeholder.
        // Check it before enumerating children: listing a dataless directory
        // is exactly the kind of implicit download this guard exists to
        // prevent. Children are checked in pre-order and the walk stops at
        // the first dataless entry, so a dataless subdirectory is reported
        // before it is ever listed.
        if isDataless(repositoryPath) {
            return "."
        }
        guard let enumerator = FileManager.default.enumerator(atPath: repositoryPath) else {
            return nil
        }
        while let relativePath = enumerator.nextObject() as? String {
            if isDataless((repositoryPath as NSString).appendingPathComponent(relativePath)) {
                return relativePath
            }
        }
        return nil
    }

    private static func resolvingSymlinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func comparable(_ path: String) -> String {
        #if canImport(Darwin)
        return path.lowercased()
        #else
        return path
        #endif
    }
}
