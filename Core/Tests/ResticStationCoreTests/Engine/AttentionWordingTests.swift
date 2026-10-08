import Foundation
import Testing
@testable import ResticStationCore

/// #171: a cloud repository with online-only files is refused through the
/// same attention path as the two secret problems, but its repair is a
/// download. Each case's wording leads with its own problem.
@Suite struct AttentionWordingTests {
    @Test("each attention's refusal reason leads with its own problem")
    func reasonLeadsWithItsOwnProblem() {
        let destination = Destination(
            id: UUID(), label: "Cloud",
            repoURL: "/Users/user/Library/CloudStorage/Provider/repo", isPrimary: true
        )
        for attention in DestinationAttention.allCases {
            let reason = BackupEngine.secretRefusalReason(
                attention: attention, destination: destination, error: .storeUnusable("DETAIL")
            )
            switch attention {
            case .secretNotConfigured:
                #expect(reason.hasPrefix("no password is stored for destination \"Cloud\""))
            case .secretStoreUnusable:
                #expect(reason.hasPrefix("the secrets for destination \"Cloud\" cannot be read"))
            case .cloudRepositoryNotHydrated:
                #expect(reason.hasPrefix("the repository for destination \"Cloud\" has files that are not downloaded"))
                #expect(reason.contains(DestinationAttention.hydrationRepair))
            }
        }
    }
}
