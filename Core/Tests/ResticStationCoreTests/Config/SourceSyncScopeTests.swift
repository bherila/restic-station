import Foundation
import Testing
@testable import ResticStationCore

@Suite("Synchronization scope is independent of backup scope")
struct SourceSyncScopeTests {
    @Test("a narrow child sync keeps its parent's backup selection intact")
    func childOfBackupRoot() throws {
        let group = SourceSyncGroup(
            name: "Shared notes",
            localPath: "/workspace/shared-notes",
            peer: .init(path: "/srv/shared-notes", sshTarget: "sync.example.test"),
            coordinatorMachineId: "laptop"
        )
        let backupSources = ["/workspace", "/settings"]
        try group.validate(backupSources: backupSources)
        #expect(group.localPath == "/workspace/shared-notes")
        #expect(group.transferRoots == ["/workspace/shared-notes", "/srv/shared-notes"])
        #expect(!group.transferRoots.contains("/workspace"))
        #expect(backupSources == ["/workspace", "/settings"])
    }

    @Test("a similar string prefix is not backup coverage")
    func componentBoundaries() {
        let group = SourceSyncGroup(
            name: "Notes", localPath: "/workspace-other/notes",
            peer: .init(path: "/replica/notes"), coordinatorMachineId: "laptop"
        )
        #expect(throws: SourceSyncError.self) {
            try group.validate(backupSources: ["/workspace"])
        }
    }

    @Test("backup root equality and the filesystem root have explicit semantics")
    func exactRootCoverage() throws {
        let group = SourceSyncGroup(
            name: "Notes", localPath: "/workspace/notes",
            peer: .init(path: "/replica/notes"), coordinatorMachineId: "laptop"
        )
        try group.validate(backupSources: ["/workspace/notes"])
        try group.validate(backupSources: ["/"])
    }

    @Test("local copies cannot overlap each other")
    func overlappingCopies() {
        for peer in ["/workspace/notes", "/workspace/notes/nested", "/workspace"] {
            let group = SourceSyncGroup(
                name: "Notes", localPath: "/workspace/notes",
                peer: .init(path: peer), coordinatorMachineId: "laptop"
            )
            #expect(throws: SourceSyncError.self) {
                try group.validate(backupSources: ["/workspace"])
            }
        }
    }

    @Test("remote operands cannot be options and roots cannot traverse")
    func invalidEndpoints() {
        for endpoint in [
            SyncEndpoint(path: "/replica/../notes"),
            SyncEndpoint(path: "relative"),
            SyncEndpoint(path: "/replica", sshTarget: "-oProxyCommand=anything"),
            SyncEndpoint(path: "/replica", sshTarget: "host\nother"),
        ] {
            let group = SourceSyncGroup(
                name: "Notes", localPath: "/workspace/notes",
                peer: endpoint, coordinatorMachineId: "laptop"
            )
            #expect(throws: SourceSyncError.self) {
                try group.validate(backupSources: ["/workspace"])
            }
        }
    }
}
