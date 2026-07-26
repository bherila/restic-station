import Testing
import Foundation
@testable import ResticStationCore

@Suite("LsNode fixture decoding")
struct LsNodeTests {
    @Test("ls-src.ndjson: snapshot header + node lines")
    func lsSrc() throws {
        let lines = try FixtureLoader.lines("ls-src.ndjson")
        #expect(lines.count == 5)

        let decoder = ResticMessageDecoder()
        guard case .snapshotHeader(let header) = decoder.decodeLine(lines[0]) else {
            Issue.record("expected snapshotHeader for line 0")
            return
        }
        #expect(header.shortId == "f391ba97")

        guard case .node(let src) = decoder.decodeLine(lines[1]) else {
            Issue.record("expected node for line 1")
            return
        }
        #expect(src.name == "src")
        #expect(src.type == .dir)
        #expect(src.path == "/src")
        #expect(src.size == nil)

        guard case .node(let binary) = decoder.decodeLine(lines[2]) else {
            Issue.record("expected node for line 2")
            return
        }
        #expect(binary.name == "binary.dat")
        #expect(binary.type == .file)
        #expect(binary.path == "/src/binary.dat")
        #expect(binary.size == 65536)

        guard case .node(let file1) = decoder.decodeLine(lines[3]) else {
            Issue.record("expected node for line 3")
            return
        }
        #expect(file1.name == "file1.txt")
        #expect(file1.size == 17)

        guard case .node(let subdir) = decoder.decodeLine(lines[4]) else {
            Issue.record("expected node for line 4")
            return
        }
        #expect(subdir.name == "subdir")
        #expect(subdir.type == .dir)
        #expect(subdir.path == "/src/subdir")
    }

    @Test("ls-root.ndjson: root listing returns dir's immediate child")
    func lsRoot() throws {
        let lines = try FixtureLoader.lines("ls-root.ndjson")
        #expect(lines.count == 2)
        let decoder = ResticMessageDecoder()

        guard case .snapshotHeader = decoder.decodeLine(lines[0]) else {
            Issue.record("expected snapshotHeader for line 0")
            return
        }
        guard case .node(let src) = decoder.decodeLine(lines[1]) else {
            Issue.record("expected node for line 1")
            return
        }
        #expect(src.name == "src")
        #expect(src.type == .dir)
        #expect(src.path == "/src")
    }

    @Test("ls-subdir.ndjson: subdir listing")
    func lsSubdir() throws {
        let lines = try FixtureLoader.lines("ls-subdir.ndjson")
        #expect(lines.count == 3)
        let decoder = ResticMessageDecoder()

        guard case .snapshotHeader = decoder.decodeLine(lines[0]) else {
            Issue.record("expected snapshotHeader for line 0")
            return
        }
        guard case .node(let subdir) = decoder.decodeLine(lines[1]) else {
            Issue.record("expected node for line 1")
            return
        }
        #expect(subdir.name == "subdir")
        #expect(subdir.type == .dir)

        guard case .node(let file2) = decoder.decodeLine(lines[2]) else {
            Issue.record("expected node for line 2")
            return
        }
        #expect(file2.name == "file2.txt")
        #expect(file2.path == "/src/subdir/file2.txt")
        #expect(file2.size == 23)
    }

    @Test("node type tolerates unknown raw values")
    func unknownNodeType() throws {
        let json = #"{"name":"weird","type":"blockdev","path":"/x","mtime":"2026-07-26T16:57:01Z"}"#
        let node = try makeResticJSONDecoder().decode(LsNode.self, from: Data(json.utf8))
        #expect(node.type == .other("blockdev"))
    }
}
