import Testing
import Foundation
@testable import ResticStationCore

@Suite("Snapshot fixture decoding")
struct SnapshotTests {
    @Test("snapshots.json: two-element array")
    func snapshotsJson() throws {
        let data = try FixtureLoader.data("snapshots.json")
        let snapshots = try parseSnapshots(data)
        #expect(snapshots.count == 2)

        let first = snapshots[0]
        #expect(first.id == "e9ffc5cb64395ad443fd14f432751a9823181224978d6b25bf2af1a99ad367fd")
        #expect(first.shortId == "e9ffc5cb")
        #expect(first.hostname == "example-mac.local")
        #expect(first.username == "user")
        #expect(first.paths == ["/Users/user/example/src"])
        #expect(first.parent == nil)
        #expect(first.original == nil)
        #expect(first.programVersion == "restic 0.18.1")
        #expect(first.summary?.filesNew == 3)
        #expect(first.summary?.dataAdded == 67860)

        let second = snapshots[1]
        #expect(second.shortId == "f391ba97")
        #expect(second.parent == first.id)
        #expect(second.summary?.filesChanged == 1)
    }

    @Test("copied snapshot carries a synthesized original field")
    func copiedSnapshotOriginal() throws {
        // restic stamps `original` (the source-repo snapshot id) only on
        // snapshots produced by `restic copy`; none of our captured
        // fixtures happen to be a copy target, so we synthesize one by
        // taking a real snapshot object and adding the field, per the
        // task's fixture note.
        let json = """
        {
            "id": "f391ba97c0968db507509e12d467de87753929ae749cbc2b1cfd81743eb19f52",
            "short_id": "f391ba97",
            "time": "2026-07-26T16:57:05.440731-04:00",
            "paths": ["/Users/user/example/src"],
            "hostname": "example-mac.local",
            "username": "user",
            "original": "e9ffc5cb64395ad443fd14f432751a9823181224978d6b25bf2af1a99ad367fd"
        }
        """
        let snapshot = try makeResticJSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.original == "e9ffc5cb64395ad443fd14f432751a9823181224978d6b25bf2af1a99ad367fd")
        #expect(snapshot.id == "f391ba97c0968db507509e12d467de87753929ae749cbc2b1cfd81743eb19f52")
    }
}
