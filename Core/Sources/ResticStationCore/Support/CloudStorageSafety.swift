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
    /// The two standard macOS roots used by iCloud Drive and File Provider
    /// services such as OneDrive, SharePoint, Google Drive and Dropbox.
    public static func isCloudSyncedPath(
        _ path: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard !standardized.isEmpty else { return false }

        let home = (homeDirectory as NSString).standardizingPath
        let roots = [
            (home as NSString).appendingPathComponent("Library/Mobile Documents"),
            (home as NSString).appendingPathComponent("Library/CloudStorage"),
        ]
        return roots.contains { standardized == $0 || standardized.hasPrefix($0 + "/") }
    }

    public static func containsCloudBackedSource(
        _ sources: [String],
        homeDirectory: String = NSHomeDirectory()
    ) -> Bool {
        sources.contains { isCloudSyncedPath($0, homeDirectory: homeDirectory) }
    }

    /// Returns the first dataless file relative to `repositoryPath`, or nil
    /// when every file is resident. Enumerating names and `lstat` metadata
    /// does not open file contents and therefore does not trigger hydration.
    public static func firstDatalessEntry(inRepository repositoryPath: String) -> String? {
        #if canImport(Darwin)
        guard isCloudSyncedPath(repositoryPath) else { return nil }

        // The repository directory itself can be a File Provider placeholder.
        // Check it before asking FileManager to enumerate children: walking a
        // dataless root is exactly the kind of implicit hydration this guard
        // exists to prevent.
        var rootInfo = stat()
        if lstat(repositoryPath, &rootInfo) == 0,
           (rootInfo.st_flags & UInt32(SF_DATALESS)) != 0 {
            return "."
        }

        guard let enumerator = FileManager.default.enumerator(atPath: repositoryPath) else {
            return nil
        }

        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = (repositoryPath as NSString).appendingPathComponent(relativePath)
            var info = stat()
            guard lstat(fullPath, &info) == 0 else { continue }
            if (info.st_flags & UInt32(SF_DATALESS)) != 0 {
                return relativePath
            }
        }
        #endif
        return nil
    }
}
