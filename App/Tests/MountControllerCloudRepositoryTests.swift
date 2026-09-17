import Foundation
import ResticStationCore
import Testing
@testable import Restic_Station

@Suite("Mount: cloud repository pre-flight")
struct MountControllerCloudRepositoryTests {
    static let local = Destination(
        id: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
        label: "Cloud",
        repoURL: "/Users/user/Library/CloudStorage/Provider-Example/restic-repo",
        isPrimary: true
    )

    @Test("a local repository with an online-only entry is refused with the runner's wording")
    func refusesDatalessLocalRepository() {
        let refusal = MountController.cloudRepositoryRefusal(for: Self.local, datalessEntry: { _ in "data/ab/abcdef" })
        #expect(refusal == ResticRunnerError.cloudRepositoryNotHydrated(
            destinationId: Self.local.id, relativePath: "data/ab/abcdef"
        ).userFacingMessage)
    }

    @Test("a fully downloaded or non-local repository mounts")
    func allowsResidentOrRemoteRepositories() {
        #expect(MountController.cloudRepositoryRefusal(for: Self.local, datalessEntry: { _ in nil }) == nil)
        let remote = Destination(
            id: UUID(), label: "R2", repoURL: "s3:https://example.test/bucket", isPrimary: true
        )
        #expect(MountController.cloudRepositoryRefusal(for: remote, datalessEntry: { _ in "data/ab/abcdef" }) == nil)
    }
}
