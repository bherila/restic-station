import Foundation
import Testing

import ResticStationCore
@testable import restic_station_helper

/// Unit coverage for `StatusReport`'s pure pieces — `RunSummary`/
/// `CurrentRunSummary`'s derivation from Core types, `Exclusion`'s mapping
/// from `ResolvedOmission`, and `humanLines()` rendering. The end-to-end
/// behavior against real fixture state directories (healthy / in-flight /
/// failed / stale-mirror, and their exit codes) is
/// `scripts/headless-cli-test.sh`.
@Suite("StatusReport")
struct StatusReportTests {

    private let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let destId = UUID(uuidString: "0A1B2C3D-4E5F-4A1B-8C1D-000000000001")!

    // MARK: - RunSummary

    @Test("RunSummary is nil for a nil entry")
    func runSummaryNilForNilEntry() {
        #expect(StatusReport.RunSummary(nil, now: Date()) == nil)
    }

    @Test("RunSummary computes ageSeconds from end, falling back to start")
    func runSummaryComputesAge() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = Date(timeIntervalSince1970: 1_000_100)
        let now = Date(timeIntervalSince1970: 1_000_500)

        let finished = RunIndexEntry(
            runId: "r1", kind: .backup, setId: setId, destId: destId, groupId: "r1",
            status: .success, start: start, end: end, trigger: .scheduled,
            snapshotId: nil, filesNew: nil, filesChanged: nil, dataAdded: nil, errorSummary: nil
        )
        let summary = try #require(StatusReport.RunSummary(finished, now: now))
        #expect(summary.ageSeconds == 400) // now - end

        let stillRecordedAsRunning = RunIndexEntry(
            runId: "r2", kind: .backup, setId: setId, destId: destId, groupId: "r2",
            status: .running, start: start, end: nil, trigger: .scheduled,
            snapshotId: nil, filesNew: nil, filesChanged: nil, dataAdded: nil, errorSummary: nil
        )
        let runningSummary = try #require(StatusReport.RunSummary(stillRecordedAsRunning, now: now))
        #expect(runningSummary.ageSeconds == 500) // now - start (no end yet)
    }

    // MARK: - CurrentRunSummary

    @Test("CurrentRunSummary is nil for nil state, and clamps percentDone to 0...100")
    func currentRunSummaryClampsPercent() {
        #expect(StatusReport.CurrentRunSummary(nil) == nil)

        let over = CurrentRunState(
            runId: "r", kind: .backup, phase: "backing-up-primary", percentDone: 1.4,
            bytesDone: 1, totalBytes: 2, filesDone: 1, totalFiles: 2, currentFiles: [], updatedAt: Date()
        )
        #expect(StatusReport.CurrentRunSummary(over)?.percentDone == 100)

        let negative = CurrentRunState(
            runId: "r", kind: .backup, phase: "probing", percentDone: -0.5,
            bytesDone: 0, totalBytes: 0, filesDone: 0, totalFiles: 0, currentFiles: [], updatedAt: Date()
        )
        #expect(StatusReport.CurrentRunSummary(negative)?.percentDone == 0)
    }

    // MARK: - Exclusion

    @Test("Exclusion mirrors ResolvedOmission's subject/reason/description")
    func exclusionMapsFromOmission() {
        let omission = ResolvedOmission(
            subject: .backupSet, id: setId, name: "Documents", reason: .disabledForMachine
        )
        let exclusion = StatusReport.Exclusion(omission: omission)
        #expect(exclusion.subject == "backupSet")
        #expect(exclusion.setId == setId)
        #expect(exclusion.id == setId)
        #expect(exclusion.reason == "disabledForMachine")
        #expect(exclusion.description.contains("disabled on this machine"))

        let destOmission = ResolvedOmission(
            subject: .destination(setId: setId), id: destId, name: "Mirror", reason: .noEnabledDestinations
        )
        let destExclusion = StatusReport.Exclusion(omission: destOmission)
        #expect(destExclusion.subject == "destination")
        #expect(destExclusion.setId == setId)
        #expect(destExclusion.id == destId)
        #expect(destExclusion.reason == "noEnabledDestinations")
    }

    // MARK: - humanLines

    private func makeSetStatus(
        needsAttention: Bool,
        isRunning: Bool,
        firstBackupOverdue: Bool = false
    ) -> StatusReport.SetStatus {
        StatusReport.SetStatus(
            id: setId, name: "Projects", needsAttention: needsAttention, isRunning: isRunning,
            firstBackupOverdue: firstBackupOverdue,
            abandonedRun: nil, abandonedRunFile: nil,
            lastBackup: nil, lastCheck: nil, lastPrune: nil, currentRun: nil,
            nextDue: Date(timeIntervalSince1970: 0),
            destinations: [
                StatusReport.DestinationStatus(
                    id: destId, label: "Primary", isPrimary: true, reachable: false, stale: true,
                    lastSyncedAt: nil, lastError: "volume not mounted"
                ),
            ]
        )
    }

    @Test("a healthy report names no attention-needed flags")
    func healthyReportHasNoFlags() {
        let report = StatusReport(
            machineId: "studio-mac", generatedAt: Date(), health: "idle", fullDiskAccessDenied: false, scheduler: nil,
            sets: [makeSetStatus(needsAttention: false, isRunning: false)], unattributedRuns: [], excludedHere: []
        )
        let lines = report.humanLines().joined(separator: "\n")
        #expect(!lines.contains("NEEDS ATTENTION"))
    }

    @Test("a warning report flags the set, and shows the destination's unreachable+stale state")
    func warningReportFlagsTheSet() {
        let report = StatusReport(
            machineId: "studio-mac", generatedAt: Date(), health: "warning", fullDiskAccessDenied: false, scheduler: nil,
            sets: [makeSetStatus(needsAttention: true, isRunning: false)], unattributedRuns: [], excludedHere: []
        )
        let lines = report.humanLines().joined(separator: "\n")
        #expect(lines.contains("NEEDS ATTENTION"))
        #expect(lines.contains("UNREACHABLE"))
        #expect(lines.contains("STALE"))
        #expect(lines.contains("volume not mounted"))
    }

    @Test("an overdue first backup is explicit next to the never-backed-up status")
    func overdueFirstBackupIsExplicit() {
        let report = StatusReport(
            machineId: "studio-mac", generatedAt: Date(), health: "warning",
            fullDiskAccessDenied: false, scheduler: nil,
            sets: [makeSetStatus(needsAttention: true, isRunning: false, firstBackupOverdue: true)],
            unattributedRuns: [], excludedHere: []
        )
        let lines = report.humanLines().joined(separator: "\n")
        #expect(lines.contains("last backup: never"))
        #expect(lines.contains("FIRST BACKUP OVERDUE"))
    }

    @Test("excludedHere renders its own section")
    func excludedHereSection() {
        let omission = ResolvedOmission(subject: .backupSet, id: setId, name: "Photos", reason: .disabledForMachine)
        let report = StatusReport(
            machineId: "mirror-box", generatedAt: Date(), health: "idle", fullDiskAccessDenied: false, scheduler: nil,
            sets: [], unattributedRuns: [], excludedHere: [StatusReport.Exclusion(omission: omission)]
        )
        let lines = report.humanLines().joined(separator: "\n")
        #expect(lines.contains("excluded here, and why"))
        #expect(lines.contains("\"Photos\""))
    }

    // MARK: - JSON: explicit null, not omitted (house convention)

    @Test("--json encodes absent optionals as explicit null, never omits the key")
    func jsonEncodesExplicitNulls() throws {
        let report = StatusReport(
            machineId: "studio-mac", generatedAt: Date(timeIntervalSince1970: 0), health: "idle",
            fullDiskAccessDenied: false, scheduler: nil, sets: [makeSetStatus(needsAttention: false, isRunning: false)],
            unattributedRuns: [], excludedHere: []
        )
        let data = try ConfigStore.makeEncoder().encode(report)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"lastBackup\" : null"))
        #expect(text.contains("\"lastCheck\" : null"))
        #expect(text.contains("\"lastPrune\" : null"))
        #expect(text.contains("\"currentRun\" : null"))
        #expect(text.contains("\"firstBackupOverdue\" : false"))
        #expect(text.contains("\"lastSyncedAt\" : null"))
        #expect(text.contains("\"unattributedRuns\" : ["))
        // `reachable: false` is a real, known value here — not null — but
        // "not yet probed" (nil) must still round-trip as explicit null
        // elsewhere; covered by encoding a destination with no repo-status.
    }

    @Test("an unattributed abandoned run renders with a named, shell-quoted cleanup path")
    func unattributedRunsRender() {
        let run = CurrentRunState(
            runId: "orphaned-run", kind: .backup, phase: "backing-up-primary", percentDone: 0.5,
            bytesDone: 1, totalBytes: 2, filesDone: 1, totalFiles: 2, currentFiles: [], updatedAt: Date()
        )
        let path = "/tmp/status state;safe/current-run.json"
        let report = StatusReport(
            machineId: "studio-mac", generatedAt: Date(), health: "warning",
            fullDiskAccessDenied: false, scheduler: nil, sets: [],
            unattributedRuns: [
                StatusReport.UnattributedRun(
                    setId: setId, liveness: .abandoned,
                    currentRun: StatusReport.CurrentRunSummary(run), currentRunFile: path
                ),
            ],
            excludedHere: []
        )

        let lines = report.humanLines().joined(separator: "\n")
        #expect(lines.contains("current runs for sets no longer configured"))
        #expect(lines.contains("ABANDONED: backup run orphaned-run"))
        #expect(lines.contains("rm '/tmp/status state;safe/current-run.json'"))
    }

    @Test("a never-probed destination's reachable/lastSyncedAt/lastError all encode null, not false/omitted")
    func neverProbedDestinationEncodesExplicitNulls() throws {
        let destination = StatusReport.DestinationStatus(
            id: destId, label: "Primary", isPrimary: true, reachable: nil, stale: false,
            lastSyncedAt: nil, lastError: nil
        )
        let data = try ConfigStore.makeEncoder().encode(destination)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"reachable\" : null"))
        #expect(text.contains("\"lastSyncedAt\" : null"))
        #expect(text.contains("\"lastError\" : null"))
    }
}
