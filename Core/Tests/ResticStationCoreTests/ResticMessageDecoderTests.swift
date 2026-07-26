import Testing
import Foundation
@testable import ResticStationCore

@Suite("ResticMessageDecoder dispatch + tolerance")
struct ResticMessageDecoderTests {
    @Test("unknown message_type becomes .unparsed, never throws")
    func unknownMessageType() {
        let decoder = ResticMessageDecoder()
        let message = decoder.decodeLine(#"{"message_type":"totally_new","foo":"bar"}"#)
        guard case .unparsed(let line) = message else {
            Issue.record("expected .unparsed, got \(message)")
            return
        }
        #expect(line.contains("totally_new"))
    }

    @Test("verbose_status and error message types are tolerated")
    func otherKnownButIgnoredTypes() {
        let decoder = ResticMessageDecoder()
        for line in [
            #"{"message_type":"verbose_status","action":"scan"}"#,
            #"{"message_type":"error","error":{"message":"boom"},"during":"archival","item":"/x"}"#,
        ] {
            guard case .unparsed = decoder.decodeLine(line) else {
                Issue.record("expected .unparsed for \(line)")
                return
            }
        }
    }

    @Test("empty line and non-JSON line become .unparsed")
    func malformedLines() {
        let decoder = ResticMessageDecoder()
        guard case .unparsed = decoder.decodeLine("") else {
            Issue.record("expected .unparsed for empty line")
            return
        }
        guard case .unparsed = decoder.decodeLine("not json at all") else {
            Issue.record("expected .unparsed for non-JSON line")
            return
        }
    }

    @Test("status line dispatches to .status")
    func statusDispatch() throws {
        let lines = try FixtureLoader.lines("backup.ndjson")
        let decoder = ResticMessageDecoder()
        guard case .status(let status) = decoder.decodeLine(lines[0]) else {
            Issue.record("expected .status")
            return
        }
        #expect(status.percentDone == 1)
    }

    @Test("backup summary line dispatches to .summary, not .restoreSummary")
    func backupSummaryDispatch() throws {
        let lines = try FixtureLoader.lines("backup.ndjson")
        let decoder = ResticMessageDecoder()
        guard case .summary(let summary) = decoder.decodeLine(lines[2]) else {
            Issue.record("expected .summary")
            return
        }
        #expect(summary.snapshotId == "e9ffc5cb64395ad443fd14f432751a9823181224978d6b25bf2af1a99ad367fd")
    }

    @Test("restore summary line dispatches to .restoreSummary, not .summary")
    func restoreSummaryDispatch() throws {
        let lines = try FixtureLoader.lines("restore.ndjson")
        let decoder = ResticMessageDecoder()
        guard case .restoreSummary(let summary) = decoder.decodeLine(lines[0]) else {
            Issue.record("expected .restoreSummary")
            return
        }
        #expect(summary.filesRestored == 4)
    }

    @Test("exit_error line dispatches to .exitError with code and message")
    func exitErrorDispatch() throws {
        let data = try FixtureLoader.data("locked-error.json")
        let line = String(decoding: data, as: UTF8.self)
        let decoder = ResticMessageDecoder()
        guard case .exitError(let code, let message) = decoder.decodeLine(line) else {
            Issue.record("expected .exitError")
            return
        }
        #expect(code == 11)
        #expect(message.contains("already locked"))
    }

    @Test("node and snapshot lines dispatch correctly")
    func lsDispatch() throws {
        let lines = try FixtureLoader.lines("ls-src.ndjson")
        let decoder = ResticMessageDecoder()
        guard case .snapshotHeader = decoder.decodeLine(lines[0]) else {
            Issue.record("expected .snapshotHeader")
            return
        }
        guard case .node(let node) = decoder.decodeLine(lines[1]) else {
            Issue.record("expected .node")
            return
        }
        #expect(node.name == "src")
    }
}
