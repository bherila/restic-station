import Foundation
import Testing
@testable import ResticStationCore

@Suite("rewrite human-output fixtures")
struct RewriteResultTests {
    @Test("dry-run fixture identifies every snapshot that would change")
    func dryRun() throws {
        let result = parseRewrite(try FixtureLoader.string("rewrite-dry-run.txt"))
        #expect(result.changedShortIDs == ["09b3295c", "b2435423"])
        #expect(result.summary == .modified(2))
        #expect(result.snapshots.allSatisfy { $0.newSnapshotShortID == nil })
    }

    @Test("forget fixture preserves old-to-new snapshot mapping")
    func forgetOutput() throws {
        let result = parseRewrite(try FixtureLoader.string("rewrite-forget.txt"))
        #expect(result.snapshots == [
            RewriteSnapshot(shortID: "09b3295c", newSnapshotShortID: "14a53542"),
            RewriteSnapshot(shortID: "b2435423", newSnapshotShortID: "3ca2e0a5"),
        ])
        #expect(result.summary == .modified(2))
    }

    /// The ordinary second run of any purge rule. restic prints the snapshot
    /// headers it examined, no `saved new snapshot` lines, and a summary that
    /// shares no wording with the counted form — which is why matching only
    /// `modified N snapshots` read a *successful* run as an unusable
    /// transcript and failed the purge.
    @Test("no-op forget fixture reports an explicit nothing, not an unreadable transcript")
    func noOpForget() throws {
        let result = parseRewrite(try FixtureLoader.string("rewrite-noop.txt"))
        #expect(result.summary == .nothingModified)
        #expect(result.summary != .unrecognized)
        #expect(result.snapshots.isEmpty)
        #expect(result.changedShortIDs.isEmpty)
    }

    @Test("no-op dry-run fixture reports an explicit nothing")
    func noOpDryRun() throws {
        let result = parseRewrite(try FixtureLoader.string("rewrite-dry-run-noop.txt"))
        #expect(result.summary == .nothingModified)
        #expect(result.snapshots.isEmpty)
    }

    /// Both no-op fixtures still name the snapshots restic examined, so a
    /// transcript that lost its snapshot headers is distinguishable from one
    /// that legitimately changed nothing.
    @Test("no-op fixtures still name the examined snapshots in raw output")
    func noOpNamesExaminedSnapshots() throws {
        for fixture in ["rewrite-noop.txt", "rewrite-dry-run-noop.txt"] {
            let raw = try FixtureLoader.string(fixture)
            #expect(raw.contains("48b4d340"), "\(fixture) should name the examined snapshots")
            #expect(raw.contains("f489f83e"), "\(fixture) should name the examined snapshots")
        }
    }

    @Test("a transcript with no summary line is unrecognized, never zero")
    func missingSummaryIsUnrecognized() {
        let truncated = """
        create exclusive lock for repository

        snapshot 09b3295c of [/tmp/src] at 2026-08-19 23:32:12 -0700 PDT by bwh@Bens-Laptop
        """
        #expect(parseRewrite(truncated).summary == .unrecognized)
        #expect(parseRewrite("").summary == .unrecognized)
    }

    @Test("disagreeing summary lines are unrecognized rather than last-one-wins")
    func conflictingSummariesAreUnrecognized() {
        #expect(parseRewrite("modified 2 snapshots\nno snapshots were modified").summary == .unrecognized)
        #expect(parseRewrite("modified 2 snapshots\nmodified 3 snapshots").summary == .unrecognized)
        // A repeated *identical* summary is not a disagreement.
        #expect(parseRewrite("modified 2 snapshots\nmodified 2 snapshots").summary == .modified(2))
    }

    @Test("the no-op phrase only counts as a summary on its own line")
    func noOpPhraseMustBeWholeLine() {
        let mentioned = "warning: no snapshots were modified by a previous run\nmodified 2 snapshots"
        #expect(parseRewrite(mentioned).summary == .modified(2))
    }
}
