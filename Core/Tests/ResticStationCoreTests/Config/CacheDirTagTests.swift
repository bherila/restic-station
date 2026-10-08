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
}
