import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Whether `restic backup --exclude-caches` would leave a whole source out.
///
/// The flag skips the contents of any directory holding a valid
/// `CACHEDIR.TAG`. restic 0.18.1 also honours a tag in a directory **above**
/// a source: a source at `~/.cache/project` under `~/.cache/CACHEDIR.TAG`
/// processes zero files (verified against 0.18.1; 0.19.1 backs it up). A tag
/// in the source directory itself leaves only the tag behind on every
/// version. In both cases the operator named that directory as a source, so
/// the host-wide default must not silently empty it. It is the
/// `--exclude-caches` form of the hazard ``GlobalExcludeAncestorSafety``
/// guards for patterns, and it is handled the same way: the flag is held
/// back for the set and the run log says why.
enum CacheDirTag {
    /// The prefix a tag must start with to count (bford.info/cachedir).
    /// restic compares exactly these bytes.
    static let signature = Array("Signature: 8a477f597d28d172789f06886806bc55".utf8)

    enum Finding: Equatable, Sendable {
        /// `directory/CACHEDIR.TAG` carries the signature.
        case tagged(directory: String)
        /// `directory/CACHEDIR.TAG` may exist but could not be read. Counted
        /// as tagged: holding the flag back only backs up more.
        case unverifiable(directory: String, errno: Int32)
    }

    /// The first directory, from the source itself upward, whose tag would
    /// make restic leave the source out. Checks the path as configured and,
    /// when they differ, with symlinks resolved.
    static func finding(atOrAbove sourcePath: String) -> Finding? {
        let url = URL(fileURLWithPath: sourcePath)
        var paths = [url.standardizedFileURL.path]
        let resolved = url.resolvingSymlinksInPath().path
        if resolved != paths[0] { paths.append(resolved) }
        for path in paths {
            var directory = path
            while true {
                if let finding = check(directory) { return finding }
                let parent = (directory as NSString).deletingLastPathComponent
                if parent.isEmpty || parent == directory { break }
                directory = parent
            }
        }
        return nil
    }

    /// One directory. `O_NONBLOCK` so a FIFO named `CACHEDIR.TAG` cannot
    /// hang the backup that is about to start.
    static func check(_ directory: String) -> Finding? {
        let tag = (directory as NSString).appendingPathComponent("CACHEDIR.TAG")
        let descriptor = tag.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        if descriptor < 0 {
            let code = errno
            return code == ENOENT || code == ENOTDIR ? nil : .unverifiable(directory: directory, errno: code)
        }
        defer { close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: signature.count)
        var filled = 0
        while filled < buffer.count {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress!.advanced(by: filled), raw.count - filled)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .unverifiable(directory: directory, errno: errno)
            }
            if count == 0 { break }
            filled += count
        }
        return filled == buffer.count && buffer == signature ? .tagged(directory: directory) : nil
    }
}
