import Foundation
import Testing

@testable import restic_station_helper

@Suite("purge preview human guidance")
struct PurgePreviewOutputTests {
    @Test("a multi-destination session prints its shared token once")
    func printsSharedTokenOnce() {
        let token = String(repeating: "A", count: 43)
        let lines = PurgePreview.humanApplyGuidance(
            setId: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
            previewToken: token,
            hasChanges: true
        )

        #expect(lines.count == 2)
        #expect(lines.filter { $0.contains(token) }.count == 1)
        #expect(lines[1].contains("--preview-token-stdin"))
        #expect(!lines[1].contains(token))
    }

    @Test("an unchanged session prints no live capability")
    func unchangedSessionPrintsNoGuidance() {
        #expect(PurgePreview.humanApplyGuidance(
            setId: UUID(),
            previewToken: String(repeating: "A", count: 43),
            hasChanges: false
        ).isEmpty)
    }
}
