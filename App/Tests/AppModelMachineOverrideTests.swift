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

    @Test("a migrating reload resolves with the newly persisted restic path")
    func migratingReloadRefreshesMachineState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-migrating-reload-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let store = ConfigStore(paths: paths)
        try store.save(AppConfig())
        let model = AppModel(paths: paths)
        #expect(model.resticPath == nil)

        let migratedPath = "/usr/local/bin/restic-from-v1"
        let legacy = AppConfig(version: 1, resticPath: migratedPath)
        let legacyBytes = try ConfigStore.makeEncoder().encode(legacy)
        try legacyBytes.write(to: paths.configFile, options: .atomic)

        model.reloadConfigFromDisk()

        #expect(model.config.version == AppConfig.currentVersion)
        #expect(model.config.resticPath == nil)
        #expect(model.machine.resticPath == migratedPath)
        #expect(model.resticPath == migratedPath)
        #expect(model.configLoadError == nil)
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

    @Test("a machine-only load error does not offer an irrelevant config reload")
    func machineLoadErrorDoesNotClaimConfigChanged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-machine-error-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        try ConfigStore(paths: paths).save(AppConfig(showMenuBarIcon: true))
        try Data("not json".utf8).write(to: paths.machineFile, options: .atomic)

        let model = AppModel(paths: paths)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(model.machineLoadError != nil)
        #expect(model.configLoadError != nil)
        #expect(!model.configChangedOnDisk)
    }

    @Test("a fleet replacement during a keychain write restores the prior secret")
    func configRaceRollsBackDestinationSecrets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-cas-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let destinationId = UUID()
        let set = BackupSet(
            id: UUID(), name: "Documents", sources: ["/tmp/source"],
            schedule: .daily(hour: 2, minute: 30),
            destinations: [
                Destination(id: destinationId, label: "Primary", repoURL: "/tmp/repo", isPrimary: true)
            ]
        )
        let original = AppConfig(sets: [set])
        let store = ConfigStore(paths: paths)
        try store.save(original)
        let editFingerprint = try store.snapshot().fingerprint

        var fleetReplacement = original
        fleetReplacement.sets[0].destinations[0].repoURL = "/tmp/fleet-repo"
        let replacementBytes = try ConfigStore.makeEncoder().encode(fleetReplacement)
        let secrets = RacingSecretStore(
            initialPassword: "old-password",
            replacementBytes: replacementBytes,
            configFile: paths.configFile
        )
        let model = AppModel(paths: paths, secretStoreFactory: { secrets })

        await #expect(throws: ConfigStoreError.changedOnDisk) {
            try await model.storeDestinationSecrets(
                destId: destinationId,
                password: "new-password",
                secretEnv: nil,
                ifConfigUnchangedFrom: editFingerprint
            )
        }

        #expect(try await secrets.password(destId: destinationId) == "old-password")
        #expect(try store.load() == fleetReplacement)
        #expect(model.configChangedOnDisk)
    }

    @Test("stacked destination edits restore the pre-editor secret")
    func stackedDestinationSecretRollbacksRunInReverse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-stack-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let secrets = MemorySecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })

        let first = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "first-edit",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        let second = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "second-edit",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )

        try await model.restoreDestinationSecrets([first, second])

        #expect(try await secrets.password(destId: destinationId) == "original-password")
    }

    @Test("a newer helper secret wins over a stale editor rollback")
    func newerDestinationSecretIsNotRolledBack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-newer-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let secrets = MemorySecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let rollback = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )

        try await secrets.setPassword("newer-helper-password", destId: destinationId)
        let restored = try await model.restoreDestinationSecrets(rollback)

        #expect(!restored)
        #expect(try await secrets.password(destId: destinationId) == "newer-helper-password")
    }

    @Test("a newer password does not prevent restoring the editor environment")
    func destinationSecretFieldsRollBackIndependently() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-fields-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let secrets = MemorySecretStore(
            passwords: [destinationId: "original-password"],
            secretEnvironments: [destinationId: ["TOKEN": "original"]]
        )
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let rollback = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "editor-password",
            secretEnv: ["TOKEN": "editor"],
            ifConfigUnchangedFrom: model.configFingerprint
        )

        try await secrets.setPassword("newer-helper-password", destId: destinationId)
        let restored = try await model.restoreDestinationSecrets(rollback)

        #expect(!restored)
        #expect(try await secrets.password(destId: destinationId) == "newer-helper-password")
        #expect(try await secrets.secretEnv(destId: destinationId) == ["TOKEN": "original"])
    }

    @Test("a conflict on one destination does not strand another destination's edit")
    func destinationRollbackConflictsStayDestinationScoped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-destinations-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstId = UUID()
        let secondId = UUID()
        let secrets = MemorySecretStore(passwords: [
            firstId: "first-original",
            secondId: "second-original",
        ])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let first = try await model.storeDestinationSecrets(
            destId: firstId,
            password: "first-editor",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        let second = try await model.storeDestinationSecrets(
            destId: secondId,
            password: "second-editor",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )

        try await secrets.setPassword("second-helper", destId: secondId)
        try await model.restoreDestinationSecrets([first, second])

        #expect(try await secrets.password(destId: firstId) == "first-original")
        #expect(try await secrets.password(destId: secondId) == "second-helper")
    }

    @Test("a conflict skips older tokens only for the same destination field")
    func destinationRollbackConflictBlocksItsOlderFieldChain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-chain-conflict-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let secrets = MemorySecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let first = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "first-editor",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        let second = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "second-editor",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )

        try await secrets.setPassword("newer-helper-password", destId: destinationId)
        try await model.restoreDestinationSecrets([first, second])

        #expect(try await secrets.password(destId: destinationId) == "newer-helper-password")
    }

    @Test("a multi-field rollback retries from its last completed field")
    func destinationRollbackCheckpointsPartialProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-retry-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let secrets = CheckpointingSecretStore(
            passwords: [destinationId: "original-password"],
            secretEnvironments: [destinationId: ["TOKEN": "original"]]
        )
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let first = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "first-password",
            secretEnv: ["TOKEN": "first"],
            ifConfigUnchangedFrom: model.configFingerprint
        )
        let second = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "second-password",
            secretEnv: ["TOKEN": "second"],
            ifConfigUnchangedFrom: model.configFingerprint
        )
        await secrets.failNextEnvironmentWrite()

        var remaining = [first, second]
        await #expect(throws: SecretStoreError.backendFailed("injected environment failure")) {
            try await model.restoreDestinationSecrets(
                remaining,
                onProgress: { remaining = $0 }
            )
        }

        #expect(try await secrets.password(destId: destinationId) == "first-password")
        #expect(try await secrets.secretEnv(destId: destinationId) == ["TOKEN": "second"])
        #expect(remaining.count == 2)
        #expect(remaining.last?.transaction.password == nil)
        #expect(remaining.last?.transaction.secretEnv != nil)

        try await model.restoreDestinationSecrets(
            remaining,
            onProgress: { remaining = $0 }
        )
        #expect(remaining.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
        #expect(try await secrets.secretEnv(destId: destinationId) == ["TOKEN": "original"])
    }

    @Test("an abandoned editor rollback is retained, surfaced, and retryable")
    func abandonedDestinationRollbackSurvivesViewTeardown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-abandon-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let rollback = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        await secrets.failNextPasswordWrite()

        model.retainPendingSecretRollbacks([rollback])
        for _ in 0..<40 {
            if model.pendingSecretRollbackError != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.pendingSecretRollbackError != nil)
        #expect(model.pendingSecretRollbackBatches.count == 1)
        #expect(try await secrets.password(destId: destinationId) == "editor-password")

        model.retryPendingSecretRollbacks()
        for _ in 0..<40 {
            if model.pendingSecretRollbackBatches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(model.pendingSecretRollbackError == nil)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
    }

    @Test("config preflight failures never advise unlocking the keychain")
    func destinationSecretFailureCopyDistinguishesConfigAndKeychain() {
        let configMessage = SetsCopy.destinationSecretFailureMessage(
            for: ConfigStoreError.writeLockBusy(path: "/tmp/config.lock")
        )
        #expect(configMessage.contains("No keychain item was changed"))
        #expect(!configMessage.contains("Unlock your login keychain"))

        let keychainMessage = SetsCopy.destinationSecretFailureMessage(
            for: SecretStoreError.backendFailed("login keychain is locked")
        )
        #expect(keychainMessage.contains("Unlock your login keychain"))
    }
}

private actor MemorySecretStore: SecretStore {
    nonisolated let backend: SecretBackend = .keychain
    private var passwords: [UUID: String]
    private var secretEnvironments: [UUID: [String: String]] = [:]

    init(
        passwords: [UUID: String] = [:],
        secretEnvironments: [UUID: [String: String]] = [:]
    ) {
        self.passwords = passwords
        self.secretEnvironments = secretEnvironments
    }

    func setPassword(_ password: String, destId: UUID) async throws {
        passwords[destId] = password
    }

    func password(destId: UUID) async throws -> String {
        guard let password = passwords[destId] else { throw SecretStoreError.itemNotFound }
        return password
    }

    func deletePassword(destId: UUID) async throws {
        passwords.removeValue(forKey: destId)
    }

    func setSecretEnv(_ env: [String: String], destId: UUID) async throws {
        secretEnvironments[destId] = env
    }

    func secretEnv(destId: UUID) async throws -> [String: String] {
        secretEnvironments[destId] ?? [:]
    }

    func deleteSecretEnv(destId: UUID) async throws {
        secretEnvironments.removeValue(forKey: destId)
    }

    nonisolated func passwordCommand(destId: UUID) -> String { "test-secret-store" }
}

private actor RacingSecretStore: SecretStore {
    nonisolated let backend: SecretBackend = .keychain
    private var passwords: [UUID: String]
    private var secretEnvironments: [UUID: [String: String]] = [:]
    private let replacementBytes: Data
    private let configFile: URL
    private var installedReplacement = false

    init(initialPassword: String, replacementBytes: Data, configFile: URL) {
        self.passwords = [:]
        self.replacementBytes = replacementBytes
        self.configFile = configFile
        // The test uses one destination and seeds it on first read below.
        self.initialPassword = initialPassword
    }

    private let initialPassword: String

    func setPassword(_ password: String, destId: UUID) async throws {
        if passwords[destId] == nil {
            passwords[destId] = initialPassword
        }
        passwords[destId] = password
        if !installedReplacement {
            installedReplacement = true
            try replacementBytes.write(to: configFile, options: .atomic)
        }
    }

    func password(destId: UUID) async throws -> String {
        if let password = passwords[destId] { return password }
        passwords[destId] = initialPassword
        return initialPassword
    }

    func deletePassword(destId: UUID) async throws {
        passwords.removeValue(forKey: destId)
    }

    func setSecretEnv(_ env: [String: String], destId: UUID) async throws {
        secretEnvironments[destId] = env
    }

    func secretEnv(destId: UUID) async throws -> [String: String] {
        secretEnvironments[destId] ?? [:]
    }

    func deleteSecretEnv(destId: UUID) async throws {
        secretEnvironments.removeValue(forKey: destId)
    }

    nonisolated func passwordCommand(destId: UUID) -> String { "test-secret-store" }
}

private actor CheckpointingSecretStore: SecretStore {
    nonisolated let backend: SecretBackend = .keychain
    private var passwords: [UUID: String]
    private var secretEnvironments: [UUID: [String: String]]
    private var passwordWriteShouldFail = false
    private var environmentWriteShouldFail = false

    init(
        passwords: [UUID: String] = [:],
        secretEnvironments: [UUID: [String: String]] = [:]
    ) {
        self.passwords = passwords
        self.secretEnvironments = secretEnvironments
    }

    func failNextPasswordWrite() {
        passwordWriteShouldFail = true
    }

    func failNextEnvironmentWrite() {
        environmentWriteShouldFail = true
    }

    func setPassword(_ password: String, destId: UUID) async throws {
        if passwordWriteShouldFail {
            passwordWriteShouldFail = false
            throw SecretStoreError.backendFailed("injected password failure")
        }
        passwords[destId] = password
    }

    func password(destId: UUID) async throws -> String {
        guard let password = passwords[destId] else { throw SecretStoreError.itemNotFound }
        return password
    }

    func deletePassword(destId: UUID) async throws {
        if passwordWriteShouldFail {
            passwordWriteShouldFail = false
            throw SecretStoreError.backendFailed("injected password failure")
        }
        passwords.removeValue(forKey: destId)
    }

    func setSecretEnv(_ env: [String: String], destId: UUID) async throws {
        if environmentWriteShouldFail {
            environmentWriteShouldFail = false
            throw SecretStoreError.backendFailed("injected environment failure")
        }
        secretEnvironments[destId] = env
    }

    func secretEnv(destId: UUID) async throws -> [String: String] {
        secretEnvironments[destId] ?? [:]
    }

    func deleteSecretEnv(destId: UUID) async throws {
        if environmentWriteShouldFail {
            environmentWriteShouldFail = false
            throw SecretStoreError.backendFailed("injected environment failure")
        }
        secretEnvironments.removeValue(forKey: destId)
    }

    nonisolated func passwordCommand(destId: UUID) -> String { "test-secret-store" }
}
