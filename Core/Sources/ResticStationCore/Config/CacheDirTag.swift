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
        /// `directory/CACHEDIR.TAG` exists but could not be read as a plain
        /// file. Counted as tagged: holding the flag back only backs up
        /// more. A FIFO lands here too, because restic opens a tag without
        /// `O_NONBLOCK` and would wait forever for a writer. So does an
        /// online-only tag, which is never read: reading it here would
        /// download it in the helper, which the set's `onlineOnlyFiles`
        /// policy does not cover (#181).
        case unverifiable(directory: String, reason: String)
    }

    /// The first directory, from the source itself upward, whose tag would
    /// make restic leave the source out. Checks the path as configured and,
    /// when they differ, with symlinks resolved.
    static func finding(
        atOrAbove sourcePath: String,
        isDataless: (stat) -> Bool = CacheDirTag.isDataless
    ) -> Finding? {
        let url = URL(fileURLWithPath: sourcePath)
        var paths = [url.standardizedFileURL.path]
        let resolved = url.resolvingSymlinksInPath().path
        if resolved != paths[0] { paths.append(resolved) }
        for path in paths {
            var directory = path
            while true {
                if let finding = check(directory, isDataless: isDataless) { return finding }
                let parent = (directory as NSString).deletingLastPathComponent
                if parent.isEmpty || parent == directory { break }
                directory = parent
            }
        }
        return nil
    }

    /// One directory. `O_NONBLOCK` so a FIFO named `CACHEDIR.TAG` cannot
    /// hang this check, and anything that is not a regular file is
    /// unverifiable rather than "no tag": restic 0.18.1 opens the tag
    /// *blocking* and `io.ReadFull`s it, so passing `--exclude-caches` with a
    /// FIFO there would leave the backup waiting forever, set lock held.
    ///
    /// An online-only (dataless) tag is unverifiable without being read:
    /// `stat` follows a symlinked tag to its target so it is not even
    /// opened, and `fstat` repeats the test on what was actually opened, for
    /// a tag evicted in between.
    static func check(_ directory: String, isDataless: (stat) -> Bool = CacheDirTag.isDataless) -> Finding? {
        let tag = (directory as NSString).appendingPathComponent("CACHEDIR.TAG")
        var target = stat()
        if stat(tag, &target) == 0, isDataless(target) {
            return .unverifiable(directory: directory, reason: onlineOnlyReason)
        }
        let descriptor = tag.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        if descriptor < 0 {
            let code = errno
            return code == ENOENT || code == ENOTDIR
                ? nil
                : .unverifiable(directory: directory, reason: "errno \(code)")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            return .unverifiable(directory: directory, reason: "fstat errno \(errno)")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return .unverifiable(directory: directory, reason: "not a regular file")
        }
        if isDataless(info) {
            return .unverifiable(directory: directory, reason: onlineOnlyReason)
        }
        var buffer = [UInt8](repeating: 0, count: signature.count)
        var filled = 0
        while filled < buffer.count {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress!.advanced(by: filled), raw.count - filled)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .unverifiable(directory: directory, reason: "read errno \(errno)")
            }
            if count == 0 { break }
            filled += count
        }
        return filled == buffer.count && buffer == signature ? .tagged(directory: directory) : nil
    }

    static let onlineOnlyReason = "online-only, not downloaded"

    /// Whether a file's contents are not on this machine. Only macOS File
    /// Provider placeholders are; elsewhere nothing is.
    static func isDataless(_ info: stat) -> Bool {
        #if canImport(Darwin)
        return (info.st_flags & UInt32(SF_DATALESS)) != 0
        #else
        return false
        #endif
    }
}
