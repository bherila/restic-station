import Foundation
import Testing
@testable import restic_station_helper
import ResticStationCore

/// `probe-repo`'s envelope for a probe that needs a human: each attention
/// publishes its own non-retryable code and names the remedy, rather than
/// the sanitized repo-status reason alone.
@Suite struct ProbeRepoAttentionTests {
    static let setId = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    static let destination = Destination(
        id: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
        label: "Cloud",
        repoURL: "/Users/user/Library/CloudStorage/Provider-Example/restic-repo",
        isPrimary: true
    )

    @Test("a cloud repository with online-only files publishes cloud_repository_not_hydrated with the remedy")
    func cloudRepositoryNotHydrated() async {
        let failure = await ProbeRepo.attentionFailure(
            .cloudRepositoryNotHydrated,
            reason: "repository is not fully downloaded (data/ab/abcdef is online-only)",
            setId: Self.setId,
            destination: Self.destination,
            // An empty store in a directory that does not exist: the cloud
            // arm has no reason to read a secret, and the message below
            // would carry a store refusal if it did.
            store: FileSecretStore(
                paths: AppPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("probe-repo-attention-\(UUID().uuidString)")),
                helperPath: "/usr/local/bin/restic-station-helper"
            )
        )
        #expect(failure.code == .cloudRepositoryNotHydrated)
        #expect(!failure.retryable)
        #expect(failure.details.destinationId == Self.destination.id)
        #expect(failure.message.contains("data/ab/abcdef is online-only"))
        #expect(failure.message.contains("available offline"))
    }
}
