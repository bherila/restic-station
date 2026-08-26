import Foundation
import ResticStationCore
import Testing
@testable import Restic_Station

@Suite("App presentation contracts")
struct AppPresentationContractTests {
    @Test("restic probes map every outcome into the Settings vocabulary")
    func resticProbeStatusMappingIsExhaustive() {
        #expect(ResticProbe(path: "/ok", outcome: .ok(version: "0.19.1")).status
            == .ok(path: "/ok", version: "0.19.1"))
        #expect(ResticProbe(path: "/old", outcome: .tooOld(version: "0.16.4")).status
            == .tooOld(path: "/old", version: "0.16.4", minimum: ResticDiscovery.minimumVersion))
        #expect(ResticProbe(path: "/broken", outcome: .unusable(reason: "exit 72")).status
            == .unavailable(path: "/broken", reason: "exit 72"))
    }

    @Test("discovery status preserves candidate preference order")
    func discoveryStatusUsesTheBestAvailableEvidence() {
        let chosen = ResticProbe(path: "/chosen", outcome: .ok(version: "0.19.1"))
        let old = ResticProbe(path: "/old", outcome: .tooOld(version: "0.16.4"))
        let broken = ResticProbe(path: "/broken", outcome: .unusable(reason: "not restic"))

        #expect(ResticDiscoveryResult(chosen: chosen, rejected: [old, broken], searchedDescription: "test").status
            == chosen.status)
        #expect(ResticDiscoveryResult(chosen: nil, rejected: [broken, old], searchedDescription: "test").status
            == old.status)
        #expect(ResticDiscoveryResult(chosen: nil, rejected: [broken], searchedDescription: "test").status
            == broken.status)
        #expect(ResticDiscoveryResult(chosen: nil, rejected: [], searchedDescription: "test").status
            == .notConfigured)
    }

    @Test("agent FDA evidence must be present, launchd-attributed, and fresh")
    func agentFDAVerdictRejectsWeakEvidence() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fresh = FdaCheckResult(
            checkedAt: now.addingTimeInterval(-60),
            hasFullDiskAccess: true,
            probedPath: FullDiskAccessProbe.safariDisplayPath,
            context: "launchd"
        )

        #expect(FullDiskAccessProbe.agentVerdict(from: fresh, now: now)
            == .granted(probedPath: FullDiskAccessProbe.safariDisplayPath, checkedAt: fresh.checkedAt))

        let absent = FullDiskAccessProbe.agentVerdict(from: nil, now: now)
        #expect(absent.label == "Unknown")
        #expect(absent.detail.contains("has not reported"))

        var wrongContext = fresh
        wrongContext.context = "app-spawned"
        #expect(FullDiskAccessProbe.agentVerdict(from: wrongContext, now: now).detail.contains("says nothing"))

        var stale = fresh
        stale.checkedAt = now.addingTimeInterval(-FullDiskAccessProbe.stalenessLimit - 1)
        #expect(FullDiskAccessProbe.agentVerdict(from: stale, now: now).detail.contains("no longer current"))

        var future = fresh
        future.checkedAt = now.addingTimeInterval(1)
        #expect(FullDiskAccessProbe.agentVerdict(from: future, now: now).detail.contains("clock has moved"))
    }

    @Test("a false FDA probe against a missing path is unknown, not denied")
    func absentFDAProbeTargetDoesNotClaimDenial() {
        let now = Date(timeIntervalSince1970: 10_000)
        let record = FdaCheckResult(
            checkedAt: now,
            hasFullDiskAccess: false,
            probedPath: "/definitely-not-a-real-restic-station-fda-path",
            context: "launchd"
        )

        let verdict = FullDiskAccessProbe.agentVerdict(from: record, now: now)
        #expect(verdict.label == "Unknown")
        #expect(verdict.detail.contains("does not exist"))
        #expect(!verdict.isGranted)
    }

    @Test("destination status follows missing, stale, reachability, and error priority")
    func destinationStatusPriority() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        func status(reachable: Bool, error: String? = nil) -> RepoStatus {
            RepoStatus(destId: id, reachable: reachable, probedAt: now, lastError: error)
        }

        #expect(DestinationStatus.derive(status: nil, isStale: false) == .unknown)
        #expect(DestinationStatus.derive(status: nil, isStale: true) == .stale)
        #expect(DestinationStatus.derive(status: status(reachable: true), isStale: false) == .reachable)
        #expect(DestinationStatus.derive(status: status(reachable: true), isStale: true) == .stale)
        #expect(DestinationStatus.derive(status: status(reachable: false), isStale: true) == .offline)
        #expect(DestinationStatus.derive(
            status: status(reachable: false, error: "repository path does not exist"),
            isStale: true
        ) == .notInitialized)
        #expect(DestinationStatus.derive(
            status: status(reachable: false, error: "volume not mounted"),
            isStale: false
        ) == .offline)
        #expect(DestinationStatus.derive(
            status: status(reachable: false, error: "wrong password"),
            isStale: false
        ) == .error)
    }

    @Test("set-list formatters describe every schedule and destination kind")
    func setListFormattingTables() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")

        #expect(SetsCopy.scheduleSummary(.everyMinutes(15)) == "Every 15 minutes")
        #expect(SetsCopy.scheduleSummary(.hourly(minute: 5)) == "Hourly at :05")
        #expect(SetsCopy.scheduleSummary(.daily(hour: 2, minute: 30)) == "Daily 02:30")
        #expect(SetsCopy.scheduleSummary(.weekly(weekday: 2, hour: 3, minute: 7)) == "Weekly Monday 03:07")
        #expect(SetsCopy.weekdayName(0, calendar: calendar) == "?")
        #expect(SetsCopy.timeOfDay(hour: 4, minute: 9) == "04:09")
        #expect(SetsCopy.sourceCountText(1) == "1 source")
        #expect(SetsCopy.sourceCountText(2) == "2 sources")

        let kinds: [(DestinationKind, String, String)] = [
            (.localPath, "LOCAL", "folder"),
            (.sftp, "SFTP", "network"),
            (.rest, "REST", "globe"),
            (.s3, "S3", "cloud"),
            (.otherCloud, "CLOUD", "cloud"),
        ]
        for (kind, label, symbol) in kinds {
            #expect(SetsCopy.kindLabel(kind) == label)
            #expect(SetsCopy.kindSymbol(kind) == symbol)
        }
    }

    @Test("last-sync copy uses exact day boundaries")
    func lastSyncCopyBoundaries() {
        let now = Date(timeIntervalSince1970: 10 * 86_400)
        let id = UUID()
        func status(daysAgo: Double) -> RepoStatus {
            RepoStatus(
                destId: id,
                reachable: true,
                probedAt: now,
                lastSyncedAt: now.addingTimeInterval(-daysAgo * 86_400)
            )
        }

        #expect(SetsCopy.lastSyncedText(nil, now: now) == "never synced")
        #expect(SetsCopy.lastSyncedText(status(daysAgo: 0.99), now: now) == "last synced today")
        #expect(SetsCopy.lastSyncedText(status(daysAgo: 1), now: now) == "last synced 1 day ago")
        #expect(SetsCopy.lastSyncedText(status(daysAgo: 2), now: now) == "last synced 2 days ago")
    }

    @Test("run presentation covers every kind, status, and free-form phase")
    func runPresentationTables() {
        #expect(RunPhase.describe("copying-0000") == "copying to a mirror")
        #expect(RunPhase.describe("purging-0000") == "purging excluded files from history")
        #expect(RunPhase.describe("probing") == "checking the repository")
        #expect(RunPhase.describe("backing-up-primary") == "backing up")
        #expect(RunPhase.describe("retention") == "applying retention")
        #expect(RunPhase.describe("checking") == "verifying the repository")
        #expect(RunPhase.describe("restoring") == "restoring")
        #expect(RunPhase.describe("initializing") == "initializing the repository")
        #expect(RunPhase.describe("future-phase") == "future-phase")

        #expect(RunKind.backup.label == "Backup")
        #expect(RunKind.copy.label == "Copy")
        #expect(RunKind.check.label == "Check")
        #expect(RunKind.prune.label == "Prune")
        #expect(RunKind.purge.label == "Purge exclusions")
        #expect(RunKind.restore.label == "Restore")
        #expect(RunKind.`init`.label == "Initialize")

        #expect(RunStatus.success.label == "Succeeded")
        #expect(RunStatus.warning.label == "Warning")
        #expect(RunStatus.failed.label == "Failed")
        #expect(RunStatus.skipped.label == "Skipped")
        #expect(RunStatus.running.label == "Running")
        #expect(RunStatus.success.explanation == nil)
        #expect(RunStatus.running.explanation == nil)
        #expect(RunStatus.warning.explanation?.contains("some files") == true)
        #expect(RunStatus.skipped.explanation?.contains("Nothing ran") == true)
        #expect(RunStatus.failed.explanation == "The run did not finish.")
    }

    @Test("helper outcomes keep the set name and one next step")
    func helperMessageCopy() {
        let setId = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        func message(_ result: HelperResult) -> HelperMessage {
            HelperMessage(setId: setId, setName: "Projects", result: result, at: now)
        }

        #expect(message(.ok(output: "started")).text == "Projects: backup started.")
        #expect(!message(.ok(output: "started")).isError)
        #expect(message(.busy).text.contains("Wait for it to finish"))
        #expect(message(.offline(output: " volume missing \n")).text == "Projects: volume missing")
        #expect(message(.failed(output: "")).text == "Projects: the backup could not be started. See Runs for the log.")
    }

    @Test("retention copy follows the engine gate, policy, machine scope, and agent state")
    func retentionCopyMatchesEnginePredicates() {
        #expect(!ManualRetentionApplyAvailability.isEnabled)

        let disabledSet = RetentionPresentation.applyHelp(
            hasPolicy: true,
            runsOnThisMachine: false,
            backgroundAgentRunsTicks: true
        )
        #expect(disabledSet.contains("does not run on this machine"))
        #expect(RetentionPresentation.containmentNotice(
            hasPolicy: true,
            runsOnThisMachine: false,
            backgroundAgentRunsTicks: true
        ) == nil)

        let noPolicy = RetentionPresentation.applyHelp(
            hasPolicy: false,
            runsOnThisMachine: true,
            backgroundAgentRunsTicks: true
        )
        #expect(noPolicy.contains("no retention policy"))
        #expect(noPolicy.contains("successful backup run"))
        #expect(RetentionPresentation.containmentNotice(
            hasPolicy: false,
            runsOnThisMachine: true,
            backgroundAgentRunsTicks: true
        ) == nil)

        let agentDisabled = RetentionPresentation.applyHelp(
            hasPolicy: true,
            runsOnThisMachine: true,
            backgroundAgentRunsTicks: false
        )
        #expect(agentDisabled.contains("cleanup will not happen on a schedule"))
        #expect(agentDisabled.contains("enable the background agent"))
        #expect(RetentionPresentation.containmentNotice(
            hasPolicy: true,
            runsOnThisMachine: true,
            backgroundAgentRunsTicks: false
        ) == agentDisabled)

        #expect(RetentionPresentation.applyHelp(
            hasPolicy: true,
            runsOnThisMachine: true,
            backgroundAgentRunsTicks: true
        ) == ManualRetentionApplyAvailability.reason)
        #expect(RetentionPresentation.containmentNotice(
            hasPolicy: true,
            runsOnThisMachine: true,
            backgroundAgentRunsTicks: true
        ) == ManualRetentionApplyAvailability.reason)
    }
}

@Suite("AppModel projections", .serialized)
@MainActor
struct AppModelProjectionTests {
    @Test("onboarding appears only for a readable, empty, never-completed config")
    func onboardingGate() throws {
        let fresh = try fixture(config: AppConfig())
        defer { fresh.cleanup() }
        #expect(fresh.model.shouldPresentOnboarding)

        let completed = try fixture(config: AppConfig(onboardingCompleted: true))
        defer { completed.cleanup() }
        #expect(!completed.model.shouldPresentOnboarding)

        let configured = try fixture(config: AppConfig(sets: [Self.backupSet()]))
        defer { configured.cleanup() }
        #expect(!configured.model.shouldPresentOnboarding)

        let corruptRoot = Self.temporaryRoot("corrupt-onboarding")
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        let corruptPaths = AppPaths(root: corruptRoot)
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corruptPaths.configFile)
        #expect(!AppModel(paths: corruptPaths).shouldPresentOnboarding)
    }

    @Test("run-history names survive removed sets and destinations")
    func historicalNamingFallbacks() throws {
        let set = Self.backupSet()
        let knownDestination = set.destinations[0]
        let fixture = try fixture(config: AppConfig(sets: [set]))
        defer { fixture.cleanup() }

        #expect(fixture.model.setName(for: set.id) == set.name)
        #expect(fixture.model.destinationLabel(setId: set.id, destId: knownDestination.id) == knownDestination.label)
        #expect(fixture.model.destinationLabel(setId: UUID(), destId: knownDestination.id) == knownDestination.label)
        #expect(fixture.model.destinationLabel(setId: nil, destId: nil) == "—")

        let deletedSet = UUID(uuidString: "12345678-0000-4000-8000-000000000001")!
        let deletedDestination = UUID(uuidString: "87654321-0000-4000-8000-000000000001")!
        #expect(fixture.model.setName(for: deletedSet) == "Deleted set 12345678")
        #expect(fixture.model.destinationLabel(setId: deletedSet, destId: deletedDestination)
            == "Deleted destination 87654321")
    }

    @Test("work-in-flight names configured sets and retains unknown deleted work")
    func workInFlightProjection() throws {
        let set = Self.backupSet()
        let fixture = try fixture(config: AppConfig(sets: [set]))
        defer { fixture.cleanup() }

        try fixture.model.stateStore.writeCurrentRun(setId: set.id, Self.currentRun(id: "known"))
        fixture.model.stateWatcher.reloadNow()
        #expect(fixture.model.setsWithWorkInFlight == [set.name])

        try fixture.model.stateStore.clearCurrentRun(setId: set.id)
        let deletedSetId = UUID()
        try fixture.model.stateStore.writeCurrentRun(setId: deletedSetId, Self.currentRun(id: "deleted"))
        fixture.model.stateWatcher.reloadNow()
        #expect(fixture.model.setsWithWorkInFlight == ["a backup"])
    }

    private static func backupSet() -> BackupSet {
        BackupSet(
            id: UUID(),
            name: "Projects",
            sources: ["/tmp/projects"],
            schedule: .daily(hour: 2, minute: 30),
            destinations: [
                Destination(id: UUID(), label: "Primary", repoURL: "/tmp/projects.restic", isPrimary: true),
            ]
        )
    }

    private static func currentRun(id: String) -> CurrentRunState {
        CurrentRunState(
            runId: id,
            kind: .backup,
            phase: "backing-up-primary",
            percentDone: 10,
            bytesDone: 1,
            totalBytes: 10,
            filesDone: 1,
            totalFiles: 10,
            currentFiles: [],
            updatedAt: Date()
        )
    }

    private static func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func fixture(config: AppConfig) throws -> (model: AppModel, cleanup: () -> Void) {
        let root = Self.temporaryRoot("app-projections")
        let paths = AppPaths(root: root)
        try ConfigStore(paths: paths).save(config)
        try MachineStore(paths: paths).save(MachineConfig(machineId: "projection-tests"))
        let model = AppModel(paths: paths)
        return (model, { try? FileManager.default.removeItem(at: root) })
    }
}
