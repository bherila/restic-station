import Foundation
import ResticStationCore
import Testing
@testable import Restic_Station

@Suite("AppModel machine override wiring", .serialized)
@MainActor
struct AppModelMachineOverrideTests {
    @Test("reclaim plan retains its previewed destination and recognizes normalized iCloud paths")
    func reclaimPlanCapturesDestinationIdentity() throws {
        let destination = Destination(
            id: UUID(),
            label: "iCloud repository",
            repoURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Temporary/../Mobile Documents/restic", isDirectory: true)
                .path,
            isPrimary: true
        )
        let plan = PrunePlan(
            setId: UUID(),
            setName: "Documents",
            destination: destination,
            isICloud: MaintenanceModel.isICloudRepository(destination),
            confirmationBinding: "preview-binding"
        )

        guard case .reclaimSpace(let previewedDestination, let isICloud, let binding) = plan.action else {
            Issue.record("expected a reclaim plan")
            return
        }
        #expect(previewedDestination == destination)
        #expect(isICloud)
        #expect(binding == "preview-binding")
    }

    @Test("reclaim plan recognizes repositories reached through an iCloud symlink")
    func reclaimPlanRecognizesICloudSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-icloud-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let iCloudRoot = root.appendingPathComponent("Mobile Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: iCloudRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: iCloudRoot.appendingPathComponent("restic", isDirectory: true),
            withIntermediateDirectories: true
        )
        let alias = root.appendingPathComponent("repository-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: iCloudRoot)
        let destination = Destination(
            id: UUID(),
            label: "iCloud repository",
            repoURL: alias.appendingPathComponent("restic", isDirectory: true).path,
            isPrimary: true
        )

        #expect(MaintenanceModel.isICloudRepository(destination, iCloudRoot: iCloudRoot.path))
    }

    @Test("reclaim plan never treats remote repository URLs as iCloud paths")
    func reclaimPlanDoesNotClassifyRemoteURLAsICloud() {
        let destination = Destination(id: UUID(), label: "Remote", repoURL: "s3:bucket/prefix", isPrimary: true)
        #expect(!MaintenanceModel.isICloudRepository(destination, iCloudRoot: "/tmp"))
    }

    @Test("reclaim preview decodes its JSON envelope without stderr diagnostics")
    func reclaimPreviewUsesStdoutForJSON() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-preview-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper", isDirectory: false)
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"ok":true,"data":{"label":"Primary","dryRun":true,"status":"success","confirmationBinding":"opaque-binding","destinationFingerprint":"public-fingerprint"}}'
        printf '%s\\n' 'diagnostic emitted on stderr' >&2
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        let preview = await HelperInvoker(helperURL: helper).previewReclaimSpace(
            setId: UUID(),
            destId: UUID()
        )

        #expect(preview.result.isSuccess)
        #expect(preview.confirmationBinding == "opaque-binding")
        #expect(preview.destinationFingerprint == "public-fingerprint")
    }

    @Test("reclaim preview decodes its JSON failure envelope without stderr diagnostics")
    func reclaimPreviewUsesStdoutForJSONFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-preview-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper", isDirectory: false)
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"schemaVersion":1,"ok":false,"data":null,"error":{"code":"stale_mirror","message":"Mirror 1 is behind the primary; run a new backup first."}}'
        printf '%s\\n' 'diagnostic emitted on stderr' >&2
        exit 1
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        let preview = await HelperInvoker(helperURL: helper).previewReclaimSpace(
            setId: UUID(),
            destId: UUID()
        )

        #expect(preview.result == .failed(output: "Mirror 1 is behind the primary; run a new backup first."))
        #expect(preview.confirmationBinding == nil)
    }

    @Test("confirmed maintenance capability is stdin-only and never inherited through the environment")
    func confirmedMaintenanceCapabilityUsesRedactedStdin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-capability-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let helper = root.appendingPathComponent("helper", isDirectory: false)
        let argvOutput = root.appendingPathComponent("argv", isDirectory: false)
        let stdinOutput = root.appendingPathComponent("stdin", isDirectory: false)
        let environmentOutput = root.appendingPathComponent("environment", isDirectory: false)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argvOutput.path)"
        cat > "\(stdinOutput.path)"
        env > "\(environmentOutput.path)"
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        let capability = String(repeating: "A", count: 43)
        let result = await HelperInvoker(helperURL: helper).pruneRepository(
            setId: UUID(),
            destId: UUID(),
            dryRun: false,
            expectedDestination: capability
        )

        #expect(result.isSuccess)
        let argv = try String(contentsOf: argvOutput, encoding: .utf8)
        let stdin = try String(contentsOf: stdinOutput, encoding: .utf8)
        let environment = try String(contentsOf: environmentOutput, encoding: .utf8)
        #expect(argv.contains("--expected-destination-stdin"))
        #expect(!argv.contains(capability))
        #expect(stdin == capability)
        #expect(!environment.contains(capability))
    }

    @Test("known machines and effective-plan preview include exclusions and replacements")
    func effectivePlanPreview() throws {
        let setId = UUID()
        let primaryId = UUID()
        let secondaryId = UUID()
        let machineId = "linux-nas"
        let config = AppConfig(sets: [
            BackupSet(
                id: setId,
                name: "Projects",
                sources: ["/Users/shared/Projects"],
                schedule: .daily(hour: 2, minute: 30),
                destinations: [
                    Destination(
                        id: primaryId,
                        label: "Primary",
                        repoURL: "/Volumes/shared/projects.restic",
                        isPrimary: true,
                        machines: [
                            machineId: DestinationMachineOverride(
                                repoURL: "/srv/restic/projects",
                                nonSecretEnv: ["CACHE": "/var/cache/restic"]
                            )
                        ]
                    ),
                    Destination(
                        id: secondaryId,
                        label: "Portable",
                        repoURL: "/Volumes/Portable/projects.restic",
                        isPrimary: false,
                        machines: [machineId: DestinationMachineOverride(enabled: false)]
                    ),
                ],
                machines: [
                    machineId: BackupSetMachineOverride(
                        sources: ["/srv/projects"],
                        schedule: .hourly(minute: 15)
                    )
                ]
            ),
        ])

        #expect(MachineOverrideUI.knownMachineIDs(
            config: config,
            currentMachineID: "studio-mac"
        ) == ["linux-nas", "studio-mac"])

        let plan = MachineOverrideUI.effectivePlan(config: config, machineID: machineId)
        let set = try #require(plan.sets.first)
        #expect(set.enabled)
        #expect(set.sources == ["/srv/projects"])
        #expect(set.schedule == .hourly(minute: 15))
        #expect(set.destinations.first(where: { $0.id == primaryId })?.repoURL == "/srv/restic/projects")
        #expect(set.destinations.first(where: { $0.id == primaryId })?.enabled == true)
        #expect(set.destinations.first(where: { $0.id == secondaryId })?.enabled == false)
        #expect(plan.exclusions.contains { $0.contains("Portable") && $0.contains("disabled") })
    }

    @Test("restore, maintenance, and repository actions use the addressable override")
    func destinationConsumersUseMachineOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-app-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let machineId = "test-mac"
        let setId = UUID()
        let destinationId = UUID()
        let rawURL = "/Volumes/Shared/raw.restic"
        let overriddenURL = "/Volumes/Local/override.restic"
        let rawEnvironment = ["REGION": "shared"]
        let overriddenEnvironment = ["REGION": "local"]

        let destination = Destination(
            id: destinationId,
            label: "Primary",
            repoURL: rawURL,
            isPrimary: true,
            nonSecretEnv: rawEnvironment,
            machines: [
                machineId: DestinationMachineOverride(
                    repoURL: overriddenURL,
                    nonSecretEnv: overriddenEnvironment
                )
            ]
        )
        let set = BackupSet(
            id: setId,
            name: "Documents",
            sources: ["/Users/shared/Documents"],
            schedule: .daily(hour: 2, minute: 30),
            destinations: [destination],
            machines: [
                machineId: BackupSetMachineOverride(
                    enabled: false,
                    sources: ["/Users/local/Documents"]
                )
            ]
        )

        try ConfigStore(paths: paths).save(AppConfig(sets: [set]))
        try MachineStore(paths: paths).save(MachineConfig(machineId: machineId))

        let model = AppModel(paths: paths)

        // A disabled-on-this-host set remains addressable for restore and
        // maintenance, but every consumer must see the host-local repo data.
        #expect(model.resolvedConfig.sets.isEmpty)

        let restoreDestination = try #require(model.restoreRepositories.first?.destination)
        let maintenanceDestination = try #require(
            MaintenanceLookup.set(model, id: setId)?.destinations.first
        )
        let actionDestination = try #require(
            model.repositoryActionDestination(setId: setId, destId: destinationId)
        )

        for resolved in [restoreDestination, maintenanceDestination, actionDestination] {
            #expect(resolved.repoURL == overriddenURL)
            #expect(resolved.nonSecretEnv == overriddenEnvironment)
            #expect(resolved.repoURL != rawURL)
            #expect(resolved.nonSecretEnv != rawEnvironment)
        }
    }

    /// Switching sets while a preview is in flight must discard that
    /// preview's result *and* release the busy state it took.
    ///
    /// The generation check alone caused a regression: a discarded completion
    /// returns before it would clear `isPreparingPrune`, and nothing else
    /// reset it, so every retention and reclaim control stayed disabled until
    /// the model was recreated. This drives the real ownership seams rather
    /// than a copy of the logic.
    @Test("changing sets during a preview releases the busy state it took")
    func selectionChangeReleasesPreviewBusyState() {
        let maintenance = MaintenanceModel()
        maintenance.selectedSetId = UUID()

        let generation = maintenance.beginPreparation()
        #expect(maintenance.isPreparingPrune)
        #expect(maintenance.shouldPublish(generation))

        maintenance.selectedSetId = UUID()

        // The in-flight completion is now stale...
        #expect(!maintenance.shouldPublish(generation))
        // ...and must not have taken the busy flag with it.
        #expect(!maintenance.isPreparingPrune)
        #expect(maintenance.prunePlan == nil)
        #expect(maintenance.activity == nil)
        if case .idle = maintenance.retentionPreview {} else {
            Issue.record("retention preview should be idle after a selection change")
        }

        // A new operation on the newly selected set can still start.
        let next = maintenance.beginPreparation()
        #expect(maintenance.shouldPublish(next))
        #expect(maintenance.isPreparingPrune)
    }

    /// Re-selecting the same set must not discard work in flight for it.
    @Test("re-selecting the same set does not invalidate its preview")
    func reselectingSameSetKeepsPreview() {
        let maintenance = MaintenanceModel()
        let setId = UUID()
        maintenance.selectedSetId = setId

        let generation = maintenance.beginPreparation()
        maintenance.selectedSetId = setId

        #expect(maintenance.shouldPublish(generation))
        #expect(maintenance.isPreparingPrune)
    }

    /// **Apply Retention must use the scheduling view, not the addressable
    /// one.** The Maintenance screen reads addressable — right for sizes,
    /// inspection and restore — but `run-set --kind prune` resolves
    /// scheduling, where a destination disabled here has been dropped.
    ///
    /// Binding the addressable set made the app and helper fingerprint
    /// different `BackupSet` values for a perfectly valid configuration, so
    /// every apply failed closed with `operation_not_allowed`; and the
    /// dialog would have counted snapshots on a destination that was never
    /// going to be touched.
    @Test("Apply Retention resolves the scheduling set, not the addressable one")
    func applyRetentionUsesTheSchedulingSet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-app-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let machineId = "test-mac"
        let setId = UUID()
        let primary = Destination(id: UUID(), label: "Primary", repoURL: "/repos/primary", isPrimary: true)
        let disabledMirror = Destination(
            id: UUID(), label: "Mirror", repoURL: "/repos/mirror", isPrimary: false,
            machines: [machineId: DestinationMachineOverride(enabled: false)]
        )
        let set = BackupSet(
            id: setId, name: "Documents", sources: ["/Users/shared/Documents"],
            schedule: .daily(hour: 2, minute: 30),
            retention: RetentionPolicy(keepLast: 3),
            destinations: [primary, disabledMirror]
        )
        try ConfigStore(paths: paths).save(AppConfig(sets: [set]))
        try MachineStore(paths: paths).save(MachineConfig(machineId: machineId))

        let model = AppModel(paths: paths)

        let addressable = try #require(MaintenanceLookup.set(model, id: setId))
        let scheduled = try #require(MaintenanceModel.scheduledSet(model, id: setId))

        // Addressable still reaches the mirror; scheduling has dropped it.
        #expect(addressable.destinations.count == 2)
        #expect(scheduled.destinations.count == 1)
        #expect(scheduled.destinations.first?.label == "Primary")

        // Which is exactly why binding the addressable set could never match
        // what the helper computes.
        func fingerprint(_ set: BackupSet) -> String {
            MaintenanceBinding.effectiveSetFingerprint(
                machineId: machineId, set: set,
                configFingerprint: "c", machineFingerprint: "m",
                resticExecutableIdentity: "restic"
            )
        }
        #expect(fingerprint(addressable) != fingerprint(scheduled))
        // The helper resolves scheduling, so this is the pair that must agree.
        #expect(fingerprint(scheduled) == fingerprint(scheduled))
    }

    /// A set disabled outright on this machine has no scheduling
    /// representation, so Apply Retention must be refused rather than offered.
    @Test("a set that does not run here has no scheduling set to apply retention to")
    func disabledSetHasNoSchedulingSet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-app-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let machineId = "test-mac"
        let setId = UUID()
        let set = BackupSet(
            id: setId, name: "Documents", sources: ["/Users/shared/Documents"],
            schedule: .daily(hour: 2, minute: 30),
            retention: RetentionPolicy(keepLast: 3),
            destinations: [Destination(id: UUID(), label: "Primary", repoURL: "/repos/p", isPrimary: true)],
            machines: [machineId: BackupSetMachineOverride(enabled: false)]
        )
        try ConfigStore(paths: paths).save(AppConfig(sets: [set]))
        try MachineStore(paths: paths).save(MachineConfig(machineId: machineId))

        let model = AppModel(paths: paths)

        #expect(MaintenanceLookup.set(model, id: setId) != nil)      // still addressable
        #expect(MaintenanceModel.scheduledSet(model, id: setId) == nil)  // but never scheduled
    }

    @Test("an external config replacement is surfaced, preserved, and explicitly reloaded")
    func externalConfigReplacementCannotBeOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-config-cas-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let store = ConfigStore(paths: paths)
        let original = AppConfig(showMenuBarIcon: true)
        try store.save(original)

        let model = AppModel(paths: paths)
        model.stateWatcher.start()
        defer { model.stateWatcher.stop() }
        let editStartFingerprint = model.configFingerprint

        let fleetReplacement = AppConfig(showMenuBarIcon: false)
        try store.save(fleetReplacement)
        for _ in 0..<40 {
            if model.configChangedOnDisk { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(model.configChangedOnDisk)
        #expect(model.config == original)
        #expect(throws: ConfigStoreError.changedOnDisk) {
            try model.saveConfig(original, ifUnchangedFrom: editStartFingerprint)
        }
        #expect(try store.load() == fleetReplacement)

        model.reloadConfigFromDisk()
        #expect(model.config == fleetReplacement)
        #expect(!model.configChangedOnDisk)

        // Reloading the model must not silently bless a draft that was
        // opened against the old bytes.
        #expect(throws: ConfigStoreError.changedOnDisk) {
            try model.saveConfig(original, ifUnchangedFrom: editStartFingerprint)
        }
        #expect(try store.load() == fleetReplacement)
    }

    @Test("a failed reload keeps its reload affordance after the old bytes return")
    func failedConfigReloadCanRecoverWhenTheSameRevisionReturns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-config-reload-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let store = ConfigStore(paths: paths)
        let original = AppConfig(showMenuBarIcon: true)
        try store.save(original)
        let originalBytes = try Data(contentsOf: paths.configFile)

        let model = AppModel(paths: paths)
        model.stateWatcher.start()
        defer { model.stateWatcher.stop() }

        try Data("not json".utf8).write(to: paths.configFile, options: .atomic)
        model.reloadConfigFromDisk()
        #expect(model.configLoadError != nil)
        #expect(model.configChangedOnDisk)

        try originalBytes.write(to: paths.configFile, options: .atomic)
        model.stateWatcher.reloadNow()
        for _ in 0..<20 {
            if model.configChangedOnDisk { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(model.configChangedOnDisk)

        model.reloadConfigFromDisk()
        #expect(model.configLoadError == nil)
        #expect(!model.configChangedOnDisk)
        #expect(model.config == original)
    }
}
