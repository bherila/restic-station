import Foundation
import Testing

import ResticStationCore
@testable import restic_station_helper

@Suite("status liveness snapshot")
struct StatusLivenessTests {
    @Test("one liveness answer is reused across every health consumer")
    func oneAnswerIsReused() {
        let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let duplicateSetId = UUID(uuidString: "0A1B2C3D-4E5F-4A1B-8C1D-000000000001")!
        let run = CurrentRunState(
            runId: "run-that-finishes-during-the-scheduler-probe",
            kind: .backup,
            phase: "backing-up-primary",
            percentDone: 0.5,
            bytesDone: 1,
            totalBytes: 2,
            filesDone: 1,
            totalFiles: 2,
            currentFiles: [],
            updatedAt: Date()
        )
        var evaluations = 0
        let runLiveness = Status.runLivenessPredicate(
            currentRuns: [setId: run, duplicateSetId: run]
        ) { _ in
            evaluations += 1
            // Model a process that is live at snapshot time and gone on every
            // later query. The old predicate re-ran this check three times.
            return evaluations == 1 ? .live : .abandoned
        }

        #expect(evaluations == 1)
        #expect(runLiveness(run) == .live) // setHealths
        #expect(runLiveness(run) == .live) // appHealth
        #expect(runLiveness(run) == .live) // hasWarningConditions / exit code
        #expect(evaluations == 1)
    }
}
