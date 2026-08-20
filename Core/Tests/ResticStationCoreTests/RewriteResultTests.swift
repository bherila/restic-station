import Foundation
import Testing
@testable import ResticStationCore

@Suite("rewrite human-output fixtures")
struct RewriteResultTests {
    @Test("dry-run fixture identifies every snapshot that would change")
    func dryRun() throws {
        let result = parseRewrite(try FixtureLoader.string("rewrite-dry-run.txt"))
        #expect(result.changedShortIDs == ["09b3295c", "b2435423"])
        #expect(result.modifiedCount == 2)
        #expect(result.snapshots.allSatisfy { $0.newSnapshotShortID == nil })
    }

    @Test("forget fixture preserves old-to-new snapshot mapping")
    func forgetOutput() throws {
        let result = parseRewrite(try FixtureLoader.string("rewrite-forget.txt"))
        #expect(result.snapshots == [
            RewriteSnapshot(shortID: "09b3295c", newSnapshotShortID: "14a53542"),
            RewriteSnapshot(shortID: "b2435423", newSnapshotShortID: "3ca2e0a5"),
        ])
        #expect(result.modifiedCount == 2)
    }
}
