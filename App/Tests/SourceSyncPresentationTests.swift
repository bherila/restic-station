import Foundation
import ResticStationCore
import Testing
@testable import Restic_Station

@Suite("Source sync presentation", .serialized)
@MainActor
struct SourceSyncPresentationTests {
    @Test("the primary action opens review without launching a backup or narrowing its sources")
    func actionReviewsIndependentScopes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-presentation-\(UUID())")
        let paths = AppPaths(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let group = SourceSyncGroup(name: "Notes", localPath: "/workspace/notes", peer: .init(path: "/srv/notes", sshTarget: "sync.example.test"), coordinatorMachineId: "laptop")
        let set = BackupSet(id: UUID(), name: "Workspace", sources: ["/workspace"], schedule: .daily(hour: 2, minute: 0), destinations: [.init(id: UUID(), label: "Archive", repoURL: "/archive", isPrimary: true)], syncFolders: [group])
        try ConfigStore(paths: paths).save(AppConfig(sets: [set]))
        try MachineStore(paths: paths).save(.init(machineId: "laptop"))
        let model = AppModel(paths: paths, helper: .init(helperURL: root.appendingPathComponent("must-not-launch")))
        model.backUpNow(setId: set.id)
        #expect(model.pendingSourceSync?.sources == ["/workspace"])
        #expect(model.pendingSourceSync?.syncFolders == [group])
        #expect(model.pendingActionSetIds.isEmpty)
        #expect(model.sourceSyncSummaries[set.id]?.title == "Not run yet")
        #expect(try ConfigStore(paths: paths).load(.inspecting).sets[0].sources == ["/workspace"])
        let record = paths.sourceSyncDir.appendingPathComponent(group.id.uuidString).appendingPathComponent("group.json")
        try Data("{broken".utf8).write(to: record)
        model.refresh()
        #expect(model.sourceSyncSummaries[set.id]?.needsAttention == true)
        #expect(model.sourceSyncSummaries[set.id]?.title == "Needs attention")
    }
}
