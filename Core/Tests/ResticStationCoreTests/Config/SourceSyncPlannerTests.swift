import Foundation
import Testing
@testable import ResticStationCore

@Suite("Two-copy reconciliation")
struct SourceSyncPlannerTests {
    let group = SourceSyncGroup(name: "Notes", localPath: "/workspace/notes", peer: .init(path: "/copy/notes"), coordinatorMachineId: "laptop")
    let old = SyncItem(digest: "old"), newer = SyncItem(digest: "new"), other = SyncItem(digest: "other")

    @Test("the merged namespace must be portable even when each copy is unambiguous")
    func crossReplicaCaseCollision() throws {
        let local = SyncInventory(rootIdentity: "left", items: ["Notes": old])
        let peer = SyncInventory(rootIdentity: "right", items: ["notes": newer])
        let result = try SourceSyncPlanner.plan(group: group, local: local, peer: peer, baseline: nil)
        #expect(result.changes.count == 2 && result.conflicts.count == 2)
        #expect(result.changes.allSatisfy { $0.action == .conflict })
    }

    func plan(_ left: SyncItem?, _ right: SyncItem?, baseline: SyncItem?) throws -> SourceSyncPlan {
        let l = SyncInventory(rootIdentity: "left", items: left.map { ["note": $0] } ?? [:])
        let r = SyncInventory(rootIdentity: "right", items: right.map { ["note": $0] } ?? [:])
        let b = SyncBaseline(groupFingerprint: try group.bindingFingerprint, localRootIdentity: "left", peerRootIdentity: "right", agreed: baseline.map { ["note": $0] } ?? [:])
        return try SourceSyncPlanner.plan(group: group, local: l, peer: r, baseline: b)
    }

    @Test("the last agreed content determines direction symmetrically")
    func directions() throws {
        #expect(try plan(newer, old, baseline: old).changes.first?.action == .copyToPeer)
        #expect(try plan(old, newer, baseline: old).changes.first?.action == .copyToLocal)
        #expect(try plan(nil, old, baseline: old).changes.first?.action == .removePeer)
        #expect(try plan(old, nil, baseline: old).changes.first?.action == .removeLocal)
        #expect(try plan(newer, other, baseline: old).changes.first?.action == .conflict)
        #expect(try plan(nil, newer, baseline: old).changes.first?.action == .conflict)
        #expect(try plan(newer, nil, baseline: old).changes.first?.action == .conflict)
        #expect(try plan(newer, newer, baseline: old).changes.isEmpty)
    }

    @Test("first-run divergence has no timestamp winner")
    func firstRun() throws {
        let l = SyncInventory(rootIdentity: "left", items: ["note": old])
        let r = SyncInventory(rootIdentity: "right", items: ["note": newer])
        let p = try SourceSyncPlanner.plan(group: group, local: l, peer: r, baseline: nil)
        #expect(p.conflicts.count == 1)
    }

    @Test("a changed root refuses instead of treating a mount replacement as deletions")
    func replacedRoot() throws {
        let p = try plan(old, old, baseline: old)
        let b = SyncBaseline(groupFingerprint: p.groupFingerprint, localRootIdentity: "former", peerRootIdentity: "right", agreed: ["note": old])
        #expect(throws: SourceSyncError.self) {
            try SourceSyncPlanner.plan(group: group, local: p.local, peer: p.peer, baseline: b)
        }
    }

    @Test("directory conflicts prevent descendant transfers")
    func ancestorBarrier() throws {
        let directory = SyncItem(kind: .directory, digest: "", mode: 0o700)
        let l = SyncInventory(rootIdentity: "left", items: ["folder": old])
        let r = SyncInventory(rootIdentity: "right", items: ["folder": directory, "folder/child": newer])
        let p = try SourceSyncPlanner.plan(group: group, local: l, peer: r, baseline: nil)
        #expect(p.changes.count == 2)
        #expect(p.changes.allSatisfy { $0.action == .conflict })
    }

    @Test("a new directory does not turn its new children into conflicts")
    func newDirectory() throws {
        let directory = SyncItem(kind: .directory, digest: "", mode: 0o700)
        let l = SyncInventory(rootIdentity: "left", items: [:])
        let r = SyncInventory(rootIdentity: "right", items: ["folder": directory, "folder/child": newer])
        let p = try SourceSyncPlanner.plan(group: group, local: l, peer: r, baseline: nil)
        #expect(p.changes.count == 2)
        #expect(p.changes.allSatisfy { $0.action == .copyToLocal })
    }
}
