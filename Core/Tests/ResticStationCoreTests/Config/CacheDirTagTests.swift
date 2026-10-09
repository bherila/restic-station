import Foundation
import Testing
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A `CACHEDIR.TAG` in a source, or in a directory above one, makes
/// `--exclude-caches` leave that source out (restic 0.18.1 processes zero
/// files), so the engine holds the flag back. Codex on #158.
@Suite struct CacheDirTagTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-cachedir-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cache/project/inner"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plain/project"), withIntermediateDirectories: true
        )
        return root
    }

    private func tag(_ directory: URL, contents: String = "Signature: 8a477f597d28d172789f06886806bc55\n") throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent("CACHEDIR.TAG"))
    }

    @Test func aTagAboveTheSourceIsFound() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try tag(cache)
        #expect(CacheDirTag.finding(atOrAbove: cache.appendingPathComponent("project/inner").path)
            == .tagged(directory: cache.path))
    }

    @Test func aTagInTheSourceItselfIsFound() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain/project")
        try tag(source)
        #expect(CacheDirTag.finding(atOrAbove: source.path) == .tagged(directory: source.path))
    }

    /// The nearest independent constraint: a tag *below* the source is
    /// exactly what `--exclude-caches` is for, so it must not hold the flag
    /// back. Neither does a file restic would not honour.
    @Test func aTagBelowTheSourceOrWithoutTheSignatureIsIgnored() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try tag(root.appendingPathComponent("cache/project/inner"))
        #expect(CacheDirTag.finding(atOrAbove: root.appendingPathComponent("cache").path) == nil)

        try tag(root.appendingPathComponent("plain"), contents: "Signature: not the real one\n")
        #expect(CacheDirTag.finding(atOrAbove: root.appendingPathComponent("plain/project").path) == nil)
    }

    @Test func aSourceReachedThroughASymlinkIsCheckedWhereItResolves() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        try tag(cache)
        let link = root.appendingPathComponent("plain/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cache.appendingPathComponent("project"))
        #expect(CacheDirTag.finding(atOrAbove: link.path) == .tagged(directory: cache.path))
    }

    /// A FIFO named `CACHEDIR.TAG` must not hang this check, and must hold
    /// the flag back: restic 0.18.1 opens a tag blocking and would wait for
    /// a writer forever. Same for a symlink to one. Codex on #158.
    @Test(.timeLimit(.minutes(1))) func aFIFONamedLikeATagHoldsTheFlagBackWithoutBlocking() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain/project")
        #expect(mkfifo(source.appendingPathComponent("CACHEDIR.TAG").path, 0o600) == 0)
        #expect(CacheDirTag.finding(atOrAbove: source.path)
            == .unverifiable(directory: source.path, reason: "not a regular file"))

        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let linked = root.appendingPathComponent("cache/project")
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("CACHEDIR.TAG"), withDestinationURL: fifo
        )
        #expect(CacheDirTag.finding(atOrAbove: linked.path)
            == .unverifiable(directory: linked.path, reason: "not a regular file"))
    }

    /// The nearest independent constraint for that change: a *directory*
    /// named `CACHEDIR.TAG` is not a regular file either, and restic cannot
    /// read it as a tag, but it is treated the same way (held back), which
    /// is the safe direction. A plain file without the signature is still
    /// ignored, as `aTagBelowTheSourceOrWithoutTheSignatureIsIgnored` pins.
    @Test func aDirectoryNamedLikeATagIsNotRuledOut() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain/project")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("CACHEDIR.TAG"), withIntermediateDirectories: false
        )
        #expect(CacheDirTag.finding(atOrAbove: source.path)
            == .unverifiable(directory: source.path, reason: "not a regular file"))
    }

    /// An online-only tag is held back without its contents being read:
    /// reading it in the helper would download it, and the #156 policy only
    /// covers restic's children (#181). `SF_DATALESS` cannot be set from user
    /// space, so the test decides which inode is online-only. The tag carries
    /// a valid signature, so reading it would have answered `.tagged`.
    @Test func anOnlineOnlyTagIsNotRead() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain/project")
        try tag(source)
        let online = try inode(of: source.appendingPathComponent("CACHEDIR.TAG"))
        #expect(CacheDirTag.finding(atOrAbove: source.path, isDataless: { $0.st_ino == online })
            == .unverifiable(directory: source.path, reason: CacheDirTag.onlineOnlyReason))
    }

    /// The nearest independent constraint: a symlinked tag is judged by its
    /// target before anything is opened, which `lstat` would not do. The
    /// target is unreadable, so a pre-check that stopped at the link would
    /// report the `open` failure instead. Root can open it regardless.
    @Test(.enabled(if: geteuid() != 0)) func aSymlinkToAnOnlineOnlyTagIsNotOpened() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appendingPathComponent("cache")
        try tag(elsewhere)
        let source = root.appendingPathComponent("plain/project")
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("CACHEDIR.TAG"),
            withDestinationURL: elsewhere.appendingPathComponent("CACHEDIR.TAG")
        )
        let target = elsewhere.appendingPathComponent("CACHEDIR.TAG")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: target.path)
        let online = try inode(of: target)
        #expect(CacheDirTag.check(source.path, isDataless: { $0.st_ino == online })
            == .unverifiable(directory: source.path, reason: CacheDirTag.onlineOnlyReason))
    }

    /// Not even opened: an unreadable online-only tag reports as online-only,
    /// not as the `open` failure. Root can open a mode-000 file, so this
    /// cannot tell the two apart there.
    @Test(.enabled(if: geteuid() != 0)) func anOnlineOnlyTagIsNotOpened() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain/project")
        try tag(source)
        let file = source.appendingPathComponent("CACHEDIR.TAG")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        #expect(CacheDirTag.check(source.path, isDataless: { _ in false })
            == .unverifiable(directory: source.path, reason: "errno \(EACCES)"))
        #expect(CacheDirTag.check(source.path, isDataless: { _ in true })
            == .unverifiable(directory: source.path, reason: CacheDirTag.onlineOnlyReason))
    }

    /// A tag evicted between the `stat` and the `open` is caught on the
    /// descriptor, before the read.
    @Test func aTagEvictedAfterTheFirstLookIsNotRead() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("plain/project")
        try tag(source)
        var looks = 0
        #expect(CacheDirTag.check(source.path, isDataless: { _ in looks += 1; return looks > 1 })
            == .unverifiable(directory: source.path, reason: CacheDirTag.onlineOnlyReason))
        #expect(looks == 2)
    }

    private func inode(of file: URL) throws -> ino_t {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return info.st_ino
    }
}
