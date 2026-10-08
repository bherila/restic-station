import Foundation
import Testing
import ResticStationCore
@testable import restic_station_helper

/// #171: `restore` and `init-secondary` refuse a cloud repository with
/// online-only files through the secret-refusal exit, but the message must
/// name the download it needs, not the secret store.
@Suite struct SecretRefusalMessageTests {
    @Test("each attention's refusal leads with its own problem and repair")
    func refusalLeadsWithItsOwnProblem() {
        let id = UUID()
        for attention in DestinationAttention.allCases {
            let message = HelperExit.secretRefusalMessage(
                "restore", attention: attention, destinationId: id, detail: "DETAIL"
            )
            switch attention {
            case .secretNotConfigured:
                #expect(message.hasPrefix("restore refused: no password is stored for destination \(id.uuidString)."))
                #expect(message.contains(DestinationAttention.secretSetCommand(destId: id)))
            case .secretStoreUnusable:
                #expect(message == "restore refused: the secrets for destination \(id.uuidString) cannot be read — DETAIL")
            case .cloudRepositoryNotHydrated:
                #expect(message.hasPrefix(
                    "restore refused: the repository for destination \(id.uuidString) has files that are not downloaded — DETAIL."
                ))
                #expect(message.contains(DestinationAttention.hydrationRepair))
                #expect(!message.contains("secret"))
            }
        }
    }
}
