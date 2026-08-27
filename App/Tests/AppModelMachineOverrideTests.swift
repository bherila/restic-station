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

        await model.reloadConfigFromDisk()
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
    func migratingReloadRefreshesMachineState() async throws {
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

        await model.reloadConfigFromDisk()

        #expect(model.config.version == AppConfig.currentVersion)
        #expect(model.config.resticPath == nil)
        #expect(model.machine.resticPath == migratedPath)
        #expect(model.resticPath == migratedPath)
        #expect(model.configLoadError == nil)
    }

    @Test("a contended config reload yields the main actor while waiting for the writer")
    func contendedReloadDoesNotFreezeMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-contended-reload-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        try ConfigStore(paths: paths).save(AppConfig(showMenuBarIcon: false))
        let model = AppModel(paths: paths)
        let heldLock = FileLock(path: paths.configLockFile, trustedRoot: root)
        #expect(heldLock.acquire() == .acquired)
        defer { heldLock.release() }

        var reloadFinished = false
        let reload = Task { @MainActor in
            await model.reloadConfigFromDisk()
            reloadFinished = true
        }
        try await Task.sleep(for: .milliseconds(75))

        #expect(!reloadFinished)
        model.noteConfigChangedOnDisk()
        #expect(model.configChangedOnDisk)

        heldLock.release()
        await reload.value
        #expect(reloadFinished)
        #expect(!model.configChangedOnDisk)
    }

    @Test("app startup never waits on a contended config lock")
    func contendedConfigDoesNotBlockAppModelInitialization() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-contended-startup-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let installed = AppConfig(showMenuBarIcon: false)
        try ConfigStore(paths: paths).save(installed)
        let heldLock = FileLock(path: paths.configLockFile, trustedRoot: root)
        #expect(heldLock.acquire() == .acquired)
        defer { heldLock.release() }

        let startedAt = Date()
        let model = AppModel(paths: paths)

        #expect(Date().timeIntervalSince(startedAt) < 1)
        #expect(model.config == installed)
    }

    @Test("legacy config migration is deferred from startup initialization")
    func legacyConfigMigratesAfterStart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-deferred-migration-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let migratedPath = "/usr/local/bin/restic-from-startup-v1"
        let legacy = AppConfig(version: 1, resticPath: migratedPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ConfigStore.makeEncoder().encode(legacy).write(to: paths.configFile, options: .atomic)

        let model = AppModel(paths: paths)
        #expect(model.config.version == 1)
        model.start()
        defer { model.stop() }
        for _ in 0..<80 {
            if model.config.version == AppConfig.currentVersion { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.config.version == AppConfig.currentVersion)
        #expect(model.machine.resticPath == migratedPath)
        #expect(model.configLoadError == nil)
    }

    @Test("an older reload completion cannot replace a newer published snapshot")
    func concurrentReloadsPublishNewestRequestOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-reload-generation-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        try ConfigStore(paths: paths).save(AppConfig())
        try MachineStore(paths: paths).save(MachineConfig(machineId: "reload-test"))
        let older = AppConfig(showMenuBarIcon: true)
        let newer = AppConfig(showMenuBarIcon: false)
        let snapshots = SequencedConfigSnapshotLoader(
            first: ConfigSnapshot(bytes: Data(), fingerprint: "older", config: older),
            second: ConfigSnapshot(bytes: Data(), fingerprint: "newer", config: newer)
        )
        let model = AppModel(
            paths: paths,
            configSnapshotLoader: { await snapshots.load() },
            configRevisionLoader: { "newer" }
        )

        let first = Task { @MainActor in await model.reloadConfigFromDisk() }
        for _ in 0..<40 {
            if await snapshots.firstRequestIsWaiting() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await snapshots.firstRequestIsWaiting())

        await model.reloadConfigFromDisk()
        #expect(model.config == newer)
        #expect(model.configFingerprint == "newer")

        await snapshots.releaseFirstRequest()
        await first.value
        #expect(model.config == newer)
        #expect(model.configFingerprint == "newer")
    }

    @Test("reload rejects a watcher revision that returns to its starting fingerprint")
    func reloadRejectsWatcherABACycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-reload-aba-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let original = AppConfig(showMenuBarIcon: true)
        let replacement = AppConfig(showMenuBarIcon: false)
        let store = ConfigStore(paths: paths)
        try store.save(original)
        let originalBytes = try Data(contentsOf: paths.configFile)
        let replacementBytes = try ConfigStore.makeEncoder().encode(replacement)
        try replacementBytes.write(to: paths.configFile, options: .atomic)
        let replacementFingerprint = store.fileFingerprint()
        try originalBytes.write(to: paths.configFile, options: .atomic)
        let replacementSnapshot = ConfigSnapshot(
            bytes: replacementBytes,
            fingerprint: replacementFingerprint,
            config: replacement
        )
        let snapshots = SequencedConfigSnapshotLoader(
            first: replacementSnapshot,
            second: replacementSnapshot
        )
        let model = AppModel(
            paths: paths,
            configSnapshotLoader: { await snapshots.load() },
            // Simulates the completed revalidation of B just before the
            // watcher publishes the later replacement back to A.
            configRevisionLoader: { replacementFingerprint }
        )

        let reload = Task { @MainActor in await model.reloadConfigFromDisk() }
        for _ in 0..<40 {
            if await snapshots.firstRequestIsWaiting() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await snapshots.firstRequestIsWaiting())

        try replacementBytes.write(to: paths.configFile, options: .atomic)
        model.stateWatcher.reloadNow()
        try ConfigStore.makeEncoder().encode(original).write(to: paths.configFile, options: .atomic)
        model.stateWatcher.reloadNow()
        await snapshots.releaseFirstRequest()
        await reload.value

        #expect(model.config == original)
        #expect(model.configChangedOnDisk)
        #expect(model.lastConfigError?.contains("changed again") == true)
    }

    @Test("an app save invalidates a reload already off the main actor")
    func appSaveInvalidatesPendingReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-reload-save-race-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let store = ConfigStore(paths: paths)
        let original = AppConfig(showMenuBarIcon: true)
        try store.save(original)
        try MachineStore(paths: paths).save(MachineConfig(machineId: "reload-save-test"))
        let staleSnapshot = try store.snapshot()
        let snapshots = SequencedConfigSnapshotLoader(first: staleSnapshot, second: staleSnapshot)
        let model = AppModel(
            paths: paths,
            configSnapshotLoader: { await snapshots.load() },
            // Deliberately returns the matching stale revision: generation
            // invalidation, not disk revalidation, must reject this reload.
            configRevisionLoader: { staleSnapshot.fingerprint }
        )

        let reload = Task { @MainActor in await model.reloadConfigFromDisk() }
        for _ in 0..<40 {
            if await snapshots.firstRequestIsWaiting() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await snapshots.firstRequestIsWaiting())

        let saved = AppConfig(showMenuBarIcon: false)
        let savedFingerprint = try model.saveConfig(saved)
        await snapshots.releaseFirstRequest()
        await reload.value

        #expect(model.config == saved)
        #expect(model.configFingerprint == savedFingerprint)
    }

    @Test("an unmigrated reload keeps config saves blocked")
    func unmigratedReloadCannotEnableConfigSaves() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-unmigrated-reload-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let legacy = AppConfig(version: 1, resticPath: "/usr/local/bin/restic")
        let snapshot = ConfigSnapshot(bytes: Data(), fingerprint: "legacy", config: legacy)
        let model = AppModel(
            paths: paths,
            configSnapshotLoader: { snapshot },
            configRevisionLoader: { "legacy" }
        )

        await model.reloadConfigFromDisk()

        #expect(model.config.version == 1)
        #expect(model.configChangedOnDisk)
        #expect(model.lastConfigError?.contains("older schema") == true)
        do {
            _ = try model.saveConfig(AppConfig(), ifUnchangedFrom: "legacy")
            Issue.record("expected saving to remain blocked until migration succeeds")
        } catch AppModelError.configUnreadable(let message) {
            #expect(message.contains("still being migrated"))
        }
    }

    @Test("reload keeps the banner when the disk advances after its snapshot")
    func reloadRefusesSnapshotThatIsNoLongerLive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-reload-revalidate-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let original = AppConfig(showMenuBarIcon: true)
        try ConfigStore(paths: paths).save(original)
        let stale = AppConfig(showMenuBarIcon: false)
        let model = AppModel(
            paths: paths,
            configSnapshotLoader: {
                ConfigSnapshot(bytes: Data(), fingerprint: "stale", config: stale)
            },
            configRevisionLoader: { "newer" }
        )

        await model.reloadConfigFromDisk()

        #expect(model.config == original)
        #expect(model.configChangedOnDisk)
        #expect(model.lastConfigError?.contains("changed again") == true)
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
        await model.reloadConfigFromDisk()
        #expect(model.configLoadError != nil)
        #expect(model.configChangedOnDisk)

        try originalBytes.write(to: paths.configFile, options: .atomic)
        model.stateWatcher.reloadNow()
        for _ in 0..<20 {
            if model.configChangedOnDisk { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(model.configChangedOnDisk)

        await model.reloadConfigFromDisk()
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

    @Test("a secret mutation finishing after editor teardown is restored by the model")
    func lateDestinationMutationCannotEscapeDestroyedViewState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-late-editor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let sessionId = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(sessionId)
        model.endSecretEditorSession(sessionId)

        let rollback = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "late-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: sessionId
        )
        #expect(!model.claimEditorSecretRollback(rollback, sessionId: sessionId))
        for _ in 0..<40 {
            if model.pendingSecretRollbackBatches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(model.pendingSecretRollbackError == nil)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
    }

    @Test("overlapping abandoned editor sessions unwind newest first")
    func overlappingAbandonedSessionsRestoreOriginalCredentials() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-session-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let first = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "first-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        await secrets.failNextPasswordWrite()
        model.retainPendingSecretRollbacks([first])
        for _ in 0..<40 {
            if model.pendingSecretRollbackError != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.pendingSecretRollbackError != nil)

        let second = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "second-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        model.retainPendingSecretRollbacks([second])
        for _ in 0..<80 {
            if model.pendingSecretRollbackBatches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(model.pendingSecretRollbackError == nil)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
    }

    @Test("overlapping editors unwind by mutation order rather than teardown order")
    func overlappingEditorsRestoreInGlobalMutationOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-global-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let olderSession = UUID()
        let newerSession = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(olderSession)
        let older = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "older-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: olderSession
        )
        #expect(model.claimEditorSecretRollback(older, sessionId: olderSession))

        model.beginSecretEditorSession(newerSession)
        let newer = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "newer-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: newerSession
        )
        #expect(model.claimEditorSecretRollback(newer, sessionId: newerSession))

        // Close in the opposite order from the mutations. The model must
        // still unwind newer -> older -> original.
        model.endSecretEditorSession(newerSession, claimedRollbacks: [newer])
        model.endSecretEditorSession(olderSession, claimedRollbacks: [older])
        for _ in 0..<80 {
            if model.pendingSecretRollbackBatches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
    }

    @Test("an older explicit revert waits for a newer live editor mutation")
    func explicitRevertDefersToNewerLiveEditor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-live-revert-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let olderSession = UUID()
        let newerSession = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(olderSession)
        let older = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "older-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: olderSession
        )
        #expect(model.claimEditorSecretRollback(older, sessionId: olderSession))

        model.beginSecretEditorSession(newerSession)
        let newer = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "newer-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: newerSession
        )
        #expect(model.claimEditorSecretRollback(newer, sessionId: newerSession))

        var olderRemaining = [older]
        do {
            _ = try await model.restoreDestinationSecrets(
                olderRemaining,
                editorSessionId: olderSession,
                onProgress: { olderRemaining = $0 }
            )
            Issue.record("expected the older revert to defer")
        } catch AppModelError.newerSecretEditorMutation {
            // Expected: no secret I/O and no progress-token loss.
        }
        #expect(olderRemaining.count == 1)
        #expect(olderRemaining.first?.sequence == older.sequence)
        #expect(try await secrets.password(destId: destinationId) == "newer-editor-password")

        var newerRemaining = [newer]
        _ = try await model.restoreDestinationSecrets(
            newerRemaining,
            editorSessionId: newerSession,
            onProgress: { newerRemaining = $0 }
        )
        #expect(newerRemaining.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "older-editor-password")

        _ = try await model.restoreDestinationSecrets(
            olderRemaining,
            editorSessionId: olderSession,
            onProgress: { olderRemaining = $0 }
        )
        #expect(olderRemaining.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
        model.endSecretEditorSession(newerSession)
        model.endSecretEditorSession(olderSession)
    }

    @Test("an older explicit revert waits for a newer in-flight editor mutation")
    func explicitRevertDefersToNewerInFlightEditor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-inflight-revert-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let olderSession = UUID()
        let newerSession = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(olderSession)
        let older = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "older-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: olderSession
        )
        #expect(model.claimEditorSecretRollback(older, sessionId: olderSession))

        model.beginSecretEditorSession(newerSession)
        await secrets.pauseNextPasswordWrite()
        let newerWrite = Task { @MainActor in
            try await model.storeDestinationSecrets(
                destId: destinationId,
                password: "newer-editor-password",
                secretEnv: nil,
                ifConfigUnchangedFrom: model.configFingerprint,
                editorSessionId: newerSession
            )
        }
        for _ in 0..<40 {
            if await secrets.passwordWriteIsPaused() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await secrets.passwordWriteIsPaused())

        var olderRemaining = [older]
        do {
            _ = try await model.restoreDestinationSecrets(
                olderRemaining,
                editorSessionId: olderSession,
                onProgress: { olderRemaining = $0 }
            )
            Issue.record("expected the older revert to wait for the in-flight editor")
        } catch AppModelError.newerSecretEditorMutation {
            // Expected: the older token and installed value remain untouched.
        }
        #expect(olderRemaining.count == 1)
        #expect(try await secrets.password(destId: destinationId) == "older-editor-password")

        await secrets.resumePausedPasswordWrite()
        let newer = try await newerWrite.value
        #expect(model.claimEditorSecretRollback(newer, sessionId: newerSession))
        var newerRemaining = [newer]
        _ = try await model.restoreDestinationSecrets(
            newerRemaining,
            editorSessionId: newerSession,
            onProgress: { newerRemaining = $0 }
        )
        model.endSecretEditorSession(newerSession)
        _ = try await model.restoreDestinationSecrets(
            olderRemaining,
            editorSessionId: olderSession,
            onProgress: { olderRemaining = $0 }
        )

        #expect(newerRemaining.isEmpty)
        #expect(olderRemaining.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
        model.endSecretEditorSession(olderSession)
    }

    @Test("queued retries wait for a torn-down editor's in-flight mutation")
    func queuedRetryWaitsForInFlightMutationAfterEditorTeardown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-inflight-teardown-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let sessionId = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(sessionId)
        let older = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "older-abandoned-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        model.retainPendingSecretRollbacks([older])

        await secrets.pauseNextPasswordWrite()
        let newerWrite = Task { @MainActor in
            try await model.storeDestinationSecrets(
                destId: destinationId,
                password: "newer-in-flight-password",
                secretEnv: nil,
                ifConfigUnchangedFrom: model.configFingerprint,
                editorSessionId: sessionId
            )
        }
        for _ in 0..<40 {
            if await secrets.passwordWriteIsPaused() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await secrets.passwordWriteIsPaused())

        model.endSecretEditorSession(sessionId)
        model.retryPendingSecretRollbacks()
        #expect(model.pendingSecretRollbackTask == nil)
        #expect(model.pendingSecretRollbackBatches.flatMap { $0 }.contains { $0.sequence == older.sequence })

        await secrets.resumePausedPasswordWrite()
        _ = try await newerWrite.value
        for _ in 0..<80 {
            if model.pendingSecretRollbackBatches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(model.pendingSecretRollbackError == nil)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
    }

    @Test("an older explicit revert drains a newer queued mutation")
    func explicitRevertDrainsNewerQueuedMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-queued-revert-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let olderSession = UUID()
        let newerSession = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(olderSession)
        let older = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "older-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: olderSession
        )
        #expect(model.claimEditorSecretRollback(older, sessionId: olderSession))

        model.beginSecretEditorSession(newerSession)
        let newer = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "newer-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: newerSession
        )
        #expect(model.claimEditorSecretRollback(newer, sessionId: newerSession))
        model.endSecretEditorSession(newerSession, claimedRollbacks: [newer])

        var olderRemaining = [older]
        _ = try await model.restoreDestinationSecrets(
            olderRemaining,
            editorSessionId: olderSession,
            onProgress: { olderRemaining = $0 }
        )
        #expect(olderRemaining.isEmpty)
        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
        model.endSecretEditorSession(olderSession)
    }

    @Test("an older explicit revert preserves queued links behind a newer live editor")
    func explicitRevertDoesNotDrainBehindNewerLiveEditor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-live-before-queued-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let olderSession = UUID()
        let queuedSession = UUID()
        let liveSession = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })

        func mutate(_ value: String, session: UUID) async throws -> AppModel.DestinationSecretsRollback {
            model.beginSecretEditorSession(session)
            let rollback = try await model.storeDestinationSecrets(
                destId: destinationId,
                password: value,
                secretEnv: nil,
                ifConfigUnchangedFrom: model.configFingerprint,
                editorSessionId: session
            )
            #expect(model.claimEditorSecretRollback(rollback, sessionId: session))
            return rollback
        }

        let older = try await mutate("older-editor-password", session: olderSession)
        let queued = try await mutate("queued-editor-password", session: queuedSession)
        model.endSecretEditorSession(queuedSession, claimedRollbacks: [queued])
        let live = try await mutate("live-editor-password", session: liveSession)

        var olderRemaining = [older]
        do {
            _ = try await model.restoreDestinationSecrets(
                olderRemaining,
                editorSessionId: olderSession,
                onProgress: { olderRemaining = $0 }
            )
            Issue.record("expected the older revert to wait for the live editor")
        } catch AppModelError.newerSecretEditorMutation {
            // Expected: neither the live nor queued newer link was consumed.
        }
        #expect(model.pendingSecretRollbackBatches.flatMap { $0 }.contains { $0.sequence == queued.sequence })
        #expect(try await secrets.password(destId: destinationId) == "live-editor-password")

        var liveRemaining = [live]
        _ = try await model.restoreDestinationSecrets(
            liveRemaining,
            editorSessionId: liveSession,
            onProgress: { liveRemaining = $0 }
        )
        model.endSecretEditorSession(liveSession)
        _ = try await model.restoreDestinationSecrets(
            olderRemaining,
            editorSessionId: olderSession,
            onProgress: { olderRemaining = $0 }
        )

        #expect(olderRemaining.isEmpty)
        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
        model.endSecretEditorSession(olderSession)
    }

    @Test("an explicit revert preserves every queued field owned by a newer live editor")
    func explicitRevertPreservesMixedQueuedTransactionBehindLiveEditor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-mixed-queued-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let olderSession = UUID()
        let queuedSession = UUID()
        let liveSession = UUID()
        let secrets = CheckpointingSecretStore(
            passwords: [destinationId: "original-password"],
            secretEnvironments: [destinationId: ["TOKEN": "original"]]
        )
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })

        model.beginSecretEditorSession(olderSession)
        let older = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "older-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: olderSession
        )
        #expect(model.claimEditorSecretRollback(older, sessionId: olderSession))

        model.beginSecretEditorSession(queuedSession)
        let queued = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "queued-password",
            secretEnv: ["TOKEN": "queued"],
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: queuedSession
        )
        #expect(model.claimEditorSecretRollback(queued, sessionId: queuedSession))
        model.endSecretEditorSession(queuedSession, claimedRollbacks: [queued])

        model.beginSecretEditorSession(liveSession)
        let live = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: nil,
            secretEnv: ["TOKEN": "live"],
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: liveSession
        )
        #expect(model.claimEditorSecretRollback(live, sessionId: liveSession))

        var olderRemaining = [older]
        do {
            _ = try await model.restoreDestinationSecrets(
                olderRemaining,
                editorSessionId: olderSession,
                onProgress: { olderRemaining = $0 }
            )
            Issue.record("expected the mixed queued transaction to remain behind the live environment edit")
        } catch AppModelError.newerSecretEditorMutation {
            // Expected: neither field in the queued transaction was consumed.
        }
        #expect(model.pendingSecretRollbackBatches.flatMap { $0 }.contains { $0.sequence == queued.sequence })
        #expect(try await secrets.password(destId: destinationId) == "queued-password")
        #expect(try await secrets.secretEnv(destId: destinationId) == ["TOKEN": "live"])

        var liveRemaining = [live]
        _ = try await model.restoreDestinationSecrets(
            liveRemaining,
            editorSessionId: liveSession,
            onProgress: { liveRemaining = $0 }
        )
        model.endSecretEditorSession(liveSession)
        _ = try await model.restoreDestinationSecrets(
            olderRemaining,
            editorSessionId: olderSession,
            onProgress: { olderRemaining = $0 }
        )

        #expect(olderRemaining.isEmpty)
        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
        #expect(try await secrets.secretEnv(destId: destinationId) == ["TOKEN": "original"])
        model.endSecretEditorSession(olderSession)
    }

    @Test("an explicit revert drains transitive queued field dependencies newest-first")
    func explicitRevertDrainsTransitiveQueuedFieldDependencies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-transitive-queued-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let olderSession = UUID()
        let mixedSession = UUID()
        let environmentSession = UUID()
        let secrets = CheckpointingSecretStore(
            passwords: [destinationId: "original-password"],
            secretEnvironments: [destinationId: ["TOKEN": "original"]]
        )
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })

        model.beginSecretEditorSession(olderSession)
        let older = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "older-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: olderSession
        )
        #expect(model.claimEditorSecretRollback(older, sessionId: olderSession))

        model.beginSecretEditorSession(mixedSession)
        let mixed = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "mixed-password",
            secretEnv: ["TOKEN": "mixed"],
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: mixedSession
        )
        #expect(model.claimEditorSecretRollback(mixed, sessionId: mixedSession))
        model.endSecretEditorSession(mixedSession, claimedRollbacks: [mixed])

        model.beginSecretEditorSession(environmentSession)
        let environment = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: nil,
            secretEnv: ["TOKEN": "newest"],
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: environmentSession
        )
        #expect(model.claimEditorSecretRollback(environment, sessionId: environmentSession))
        model.endSecretEditorSession(environmentSession, claimedRollbacks: [environment])

        var remaining = [older]
        _ = try await model.restoreDestinationSecrets(
            remaining,
            editorSessionId: olderSession,
            onProgress: { remaining = $0 }
        )

        #expect(remaining.isEmpty)
        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
        #expect(try await secrets.secretEnv(destId: destinationId) == ["TOKEN": "original"])
        model.endSecretEditorSession(olderSession)
    }

    @Test("an older rollback waits until a live editor registers its newer transaction")
    func abandonedRollbackWaitsForActiveEditor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-active-editor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let sessionId = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let first = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "first-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        await secrets.failNextPasswordWrite()
        model.retainPendingSecretRollbacks([first])
        for _ in 0..<40 {
            if model.pendingSecretRollbackError != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.pendingSecretRollbackError != nil)

        model.beginSecretEditorSession(sessionId)
        let second = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "second-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: sessionId
        )

        model.retryPendingSecretRollbacks()
        #expect(model.pendingSecretRollbackTask == nil)
        #expect(model.pendingSecretRollbackBatches.count == 1)
        #expect(try await secrets.password(destId: destinationId) == "second-editor-password")

        #expect(model.claimEditorSecretRollback(second, sessionId: sessionId))
        model.endSecretEditorSession(sessionId, claimedRollbacks: [second])
        for _ in 0..<80 {
            if model.pendingSecretRollbackBatches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(model.pendingSecretRollbackError == nil)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
    }

    @Test("a new editor waits for an older rollback already in flight")
    func activeEditorWaitsForRunningRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-running-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let sessionId = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let first = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "first-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        await secrets.pauseNextPasswordWrite()
        model.retainPendingSecretRollbacks([first])
        for _ in 0..<40 {
            if await secrets.passwordWriteIsPaused() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await secrets.passwordWriteIsPaused())

        model.beginSecretEditorSession(sessionId)
        var secondFinished = false
        let secondTask = Task { @MainActor in
            let rollback = try await model.storeDestinationSecrets(
                destId: destinationId,
                password: "second-editor-password",
                secretEnv: nil,
                ifConfigUnchangedFrom: model.configFingerprint,
                editorSessionId: sessionId
            )
            secondFinished = true
            return rollback
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!secondFinished)
        #expect(try await secrets.password(destId: destinationId) == "first-editor-password")

        await secrets.resumePausedPasswordWrite()
        let second = try await secondTask.value
        #expect(secondFinished)
        #expect(try await secrets.password(destId: destinationId) == "second-editor-password")

        #expect(model.claimEditorSecretRollback(second, sessionId: sessionId))
        model.endSecretEditorSession(sessionId, claimedRollbacks: [second])
        for _ in 0..<80 {
            if model.pendingSecretRollbackBatches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
    }

    @Test("destination prefill waits for an older rollback already in flight")
    func destinationPrefillWaitsForRunningRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-running-prefill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let sessionId = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let abandoned = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "abandoned-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        await secrets.pauseNextPasswordWrite()
        model.retainPendingSecretRollbacks([abandoned])
        for _ in 0..<40 {
            if await secrets.passwordWriteIsPaused() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await secrets.passwordWriteIsPaused())

        model.beginSecretEditorSession(sessionId)
        var prefillFinished = false
        let prefill = Task { @MainActor in
            let loaded = try await model.loadDestinationSecrets(
                destId: destinationId,
                editorSessionId: sessionId
            )
            prefillFinished = true
            return loaded
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!prefillFinished)

        await secrets.resumePausedPasswordWrite()
        let loaded = try await prefill.value
        #expect(prefillFinished)
        #expect(loaded.password == "original-password")
        model.endSecretEditorSession(sessionId)
    }

    @Test("destination prefill drains an overlapping rollback queued behind another editor")
    func destinationPrefillDrainsQueuedRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-queued-prefill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let survivingSession = UUID()
        let secrets = CheckpointingSecretStore(
            passwords: [destinationId: "original-password"],
            secretEnvironments: [destinationId: ["TOKEN": "original"]]
        )
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(survivingSession)
        let abandoned = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "abandoned-password",
            secretEnv: ["TOKEN": "abandoned"],
            ifConfigUnchangedFrom: model.configFingerprint
        )
        model.retainPendingSecretRollbacks([abandoned])

        #expect(model.pendingSecretRollbackTask == nil)
        #expect(model.pendingSecretRollbackBatches.count == 1)
        let loaded = try await model.loadDestinationSecrets(
            destId: destinationId,
            editorSessionId: survivingSession
        )

        #expect(loaded.password == "original-password")
        #expect(loaded.secretEnv == ["TOKEN": "original"])
        #expect(model.pendingSecretRollbackBatches.isEmpty)
        model.endSecretEditorSession(survivingSession)
    }

    @Test("destination prefill refuses credentials owned by another live editor")
    func destinationPrefillRefusesOtherLiveEditorOwnership() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-live-owner-prefill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let owningSession = UUID()
        let loadingSession = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(owningSession)
        let owned = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "live-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: owningSession
        )
        #expect(model.claimEditorSecretRollback(owned, sessionId: owningSession))
        model.beginSecretEditorSession(loadingSession)

        do {
            _ = try await model.loadDestinationSecrets(
                destId: destinationId,
                editorSessionId: loadingSession
            )
            Issue.record("expected prefill to refuse another editor's live credential")
        } catch AppModelError.newerSecretEditorMutation {
            // Expected: the loading editor cannot adopt another draft's value.
        }

        var remaining = [owned]
        _ = try await model.restoreDestinationSecrets(
            remaining,
            editorSessionId: owningSession,
            onProgress: { remaining = $0 }
        )
        model.endSecretEditorSession(loadingSession)
        model.endSecretEditorSession(owningSession)
    }

    @Test("a dequeued prefill rollback remains visible to older explicit reverts")
    func destinationPrefillDrainStaysVisibleWhileInFlight() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-prefill-inflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let olderSession = UUID()
        let queuedSession = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })

        model.beginSecretEditorSession(olderSession)
        let older = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "older-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: olderSession
        )
        #expect(model.claimEditorSecretRollback(older, sessionId: olderSession))

        model.beginSecretEditorSession(queuedSession)
        let queued = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "queued-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: queuedSession
        )
        #expect(model.claimEditorSecretRollback(queued, sessionId: queuedSession))
        model.endSecretEditorSession(queuedSession, claimedRollbacks: [queued])

        await secrets.pauseNextPasswordWrite()
        let prefill = Task { @MainActor in
            try await model.loadDestinationSecrets(
                destId: destinationId,
                editorSessionId: olderSession
            )
        }
        for _ in 0..<40 {
            if await secrets.passwordWriteIsPaused() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await secrets.passwordWriteIsPaused())
        #expect(model.inFlightSecretRollbackRestorations[queued.sequence] != nil)

        var olderRemaining = [older]
        do {
            _ = try await model.restoreDestinationSecrets(
                olderRemaining,
                editorSessionId: olderSession,
                onProgress: { olderRemaining = $0 }
            )
            Issue.record("expected the older revert to defer to the dequeued rollback")
        } catch AppModelError.newerSecretEditorMutation {
            // Expected: the dequeued link remains globally visible.
        }
        #expect(olderRemaining.count == 1)

        await secrets.resumePausedPasswordWrite()
        let loaded = try await prefill.value
        #expect(loaded.password == "older-password")
        _ = try await model.restoreDestinationSecrets(
            olderRemaining,
            editorSessionId: olderSession,
            onProgress: { olderRemaining = $0 }
        )
        #expect(try await secrets.password(destId: destinationId) == "original-password")
        model.endSecretEditorSession(olderSession)
    }

    @Test("destination prefill propagates queued restoration failures")
    func destinationPrefillRefusesFailedQueuedRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-prefill-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let survivingSession = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(survivingSession)
        let abandoned = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "abandoned-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        model.retainPendingSecretRollbacks([abandoned])
        await secrets.failNextPasswordWrite()

        await #expect(throws: SecretStoreError.backendFailed("injected password failure")) {
            try await model.loadDestinationSecrets(
                destId: destinationId,
                editorSessionId: survivingSession
            )
        }
        #expect(model.pendingSecretRollbackBatches.flatMap { $0 }.contains { $0.sequence == abandoned.sequence })
        #expect(model.pendingSecretRollbackError != nil)
        #expect(try await secrets.password(destId: destinationId) == "abandoned-password")
        model.endSecretEditorSession(survivingSession)
    }

    @Test("committing the same credential retires an older abandoned rollback")
    func committedCredentialRetiresOlderRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-committed-same-value-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let sessionId = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        let abandoned = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "retained-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint
        )
        await secrets.failNextPasswordWrite()
        model.retainPendingSecretRollbacks([abandoned])
        for _ in 0..<40 {
            if model.pendingSecretRollbackError != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.pendingSecretRollbackError != nil)

        model.beginSecretEditorSession(sessionId)
        let committed = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "retained-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: sessionId
        )
        #expect(model.claimEditorSecretRollback(committed, sessionId: sessionId))
        model.retirePendingSecretRollbackFields(committedBy: [committed])

        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(model.pendingSecretRollbackError == nil)
        model.endSecretEditorSession(sessionId)
        #expect(try await secrets.password(destId: destinationId) == "retained-password")
    }

    @Test("a newer commit retires rollback tokens still owned by another editor")
    func committedCredentialRetiresLiveEditorRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-live-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let olderSession = UUID()
        let newerSession = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(olderSession)
        let older = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "committed-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: olderSession
        )
        #expect(model.claimEditorSecretRollback(older, sessionId: olderSession))

        model.beginSecretEditorSession(newerSession)
        let committed = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "committed-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: newerSession
        )
        #expect(model.claimEditorSecretRollback(committed, sessionId: newerSession))
        model.retirePendingSecretRollbackFields(committedBy: [committed])
        model.endSecretEditorSession(newerSession)

        // The older view still hands its stale value token to the model, but
        // the newer commit cutoff makes it ineligible before any secret I/O.
        model.endSecretEditorSession(olderSession, claimedRollbacks: [older])
        for _ in 0..<40 {
            if model.pendingSecretRollbackBatches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "committed-password")
    }

    @Test("credential restoration failure changes process-wide app health")
    func credentialRollbackFailureWarnsInMenuBarHealth() {
        #expect(AppModel.health(.idle, pendingSecretRollbackError: nil) == .idle)
        #expect(AppModel.health(
            .idle,
            pendingSecretRollbackError: "Credential restoration failed"
        ) == .warning)
        #expect(AppModel.health(
            .running,
            pendingSecretRollbackError: "Credential restoration failed"
        ) == .warning)
        #expect(AppModel.health(
            .critical,
            pendingSecretRollbackError: "Credential restoration failed"
        ) == .critical)
    }

    @Test("editor teardown keeps claimed and parked rollbacks in chronological order")
    func editorTeardownOrdersClaimedBeforeParkedRollbacks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-secret-teardown-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destinationId = UUID()
        let sessionId = UUID()
        let secrets = CheckpointingSecretStore(passwords: [destinationId: "original-password"])
        let model = AppModel(paths: AppPaths(root: root), secretStoreFactory: { secrets })
        model.beginSecretEditorSession(sessionId)

        let claimed = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "first-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: sessionId
        )
        #expect(model.claimEditorSecretRollback(claimed, sessionId: sessionId))

        _ = try await model.storeDestinationSecrets(
            destId: destinationId,
            password: "second-editor-password",
            secretEnv: nil,
            ifConfigUnchangedFrom: model.configFingerprint,
            editorSessionId: sessionId
        )
        model.endSecretEditorSession(sessionId, claimedRollbacks: [claimed])
        for _ in 0..<80 {
            if model.pendingSecretRollbackBatches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.pendingSecretRollbackBatches.isEmpty)
        #expect(try await secrets.password(destId: destinationId) == "original-password")
    }

    @Test("a credential-only destination edit makes the parent set saveable")
    func credentialOnlyDestinationEditIsUnsavedWork() {
        let destinationId = UUID()
        let set = BackupSet(
            id: UUID(),
            name: "Projects",
            sources: ["/Users/example/Projects"],
            excludes: [],
            schedule: .daily(hour: 2, minute: 30),
            retention: nil,
            checkPolicy: nil,
            stalenessWarningDays: 14,
            destinations: [
                Destination(
                    id: destinationId,
                    label: "Mirror",
                    repoURL: "/Volumes/mirror/projects.restic",
                    isPrimary: true
                )
            ]
        )
        let credentialChange = AppModel.DestinationSecretsRollback(
            transaction: DestinationSecretRollback(
                destId: destinationId,
                password: SecretRollbackChange(installed: "rotated", previous: "old"),
                secretEnv: nil
            )
        )
        let noSecretChange = AppModel.DestinationSecretsRollback(
            transaction: DestinationSecretRollback(
                destId: destinationId,
                password: nil,
                secretEnv: nil
            )
        )

        #expect(SetEditorSaveState.hasUnsavedChanges(
            persisted: set,
            draft: set,
            pendingSecretRollbacks: [credentialChange]
        ))
        #expect(!SetEditorSaveState.hasUnsavedChanges(
            persisted: set,
            draft: set,
            pendingSecretRollbacks: [noSecretChange]
        ))
    }

    /// `Reachability` writes this reason into `repo-status-<destId>.json`
    /// and `SetsBadges` is the only thing that reads it, so the two halves
    /// of the contract live in different packages and can drift silently.
    /// The Core-side test (`ReachabilityTests`) pins the string; this one
    /// pins what the badge does with it.
    @Test("a store that refuses to be read badges as Error, not Offline")
    func unusableSecretStoreBadgesAsError() {
        let destId = UUID()
        let probedAt = Date(timeIntervalSince1970: 1_760_000_000)

        // The exact string `Reachability.probe` records for
        // `ResticRunnerError.secretsStoreUnusable` (#96).
        let unusable = DestinationStatus.derive(
            status: RepoStatus(
                destId: destId,
                reachable: false,
                probedAt: probedAt,
                lastError: "the secret store is not usable as configured"
            ),
            isStale: false
        )
        // "Offline" reads as "try later", which is exactly wrong for a
        // refusal whose message names the `chmod` to run.
        #expect(unusable == .error)
        #expect(unusable.label == "Error")

        // The transient sibling must still badge as Offline, or the
        // pre-login tick would look like a fault every morning.
        for backend in SecretBackend.allCases {
            let transient = DestinationStatus.derive(
                status: RepoStatus(
                    destId: destId,
                    reachable: false,
                    probedAt: probedAt,
                    lastError: backend.unavailableProbeReason
                ),
                isStale: false
            )
            #expect(transient == .offline, "\(backend) should stay environmental")
        }

        // And so must the third one, for the same reason as the first.
        #expect(DestinationStatus.derive(
            status: RepoStatus(
                destId: destId,
                reachable: false,
                probedAt: probedAt,
                lastError: "no password stored for this destination"
            ),
            isStale: false
        ) == .error)
    }

    @Test("config preflight failures never advise unlocking the keychain")
    func destinationSecretFailureCopyDistinguishesConfigAndKeychain() {
        let configMessage = SetsCopy.destinationSecretFailureMessage(
            for: ConfigStoreError.writeLockBusy(path: "/tmp/config.lock")
        )
        #expect(configMessage.contains("No keychain item was changed"))
        #expect(!configMessage.contains("Unlock your login keychain"))

        let readMessage = SetsCopy.destinationSecretFailureMessage(
            for: ConfigStoreError.readFailed(
                path: "/tmp/config.json",
                reason: "permission denied"
            )
        )
        #expect(readMessage.contains("Settings could not be checked safely"))
        #expect(!readMessage.contains("Unlock your login keychain"))

        let keychainMessage = SetsCopy.destinationSecretFailureMessage(
            for: SecretStoreError.backendFailed("login keychain is locked"),
            backend: .keychain
        )
        #expect(keychainMessage.contains("Unlock your login keychain"))

        let fileMessage = SetsCopy.destinationSecretFailureMessage(
            for: SecretStoreError.backendFailed("unsafe permissions"),
            backend: .file
        )
        #expect(fileMessage.contains("secrets file"))
        #expect(fileMessage.contains("Check the permissions"))
        #expect(!fileMessage.contains("Unlock your login keychain"))

        #expect(SetEditorSaveState.canFinishRevert(
            startingFingerprint: "same-revision",
            currentFingerprint: "same-revision"
        ))
        #expect(!SetEditorSaveState.canFinishRevert(
            startingFingerprint: "stale-revision",
            currentFingerprint: "reloaded-revision"
        ))
    }

    @Test("uncertain config recovery distinguishes a live candidate from another revision")
    func uncertainConfigCommitIsReconciledFromLiveBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-config-reconcile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(paths: AppPaths(root: root))
        let candidate = AppConfig(showMenuBarIcon: false)
        let fingerprint = try model.configStore.save(
            candidate,
            ifUnchangedFrom: model.configFingerprint
        )

        #expect(model.reconcileUncertainConfigCommit(candidate: candidate)
            == .candidateInstalled(fingerprint: fingerprint))
        #expect(model.reconcileUncertainConfigCommit(candidate: AppConfig())
            == .differentRevisionInstalled)
        #expect(ConfigStoreError.replacementRollbackFailed(
            errno: 5,
            candidateMayBeInstalledAt: model.paths.configFile.path
        ).commitMayBeUncertain)
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

private actor SequencedConfigSnapshotLoader {
    private let first: ConfigSnapshot
    private let second: ConfigSnapshot
    private var requestCount = 0
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?

    init(first: ConfigSnapshot, second: ConfigSnapshot) {
        self.first = first
        self.second = second
    }

    func load() async -> ConfigSnapshot {
        requestCount += 1
        guard requestCount == 1 else { return second }
        await withCheckedContinuation { continuation in
            firstRequestContinuation = continuation
        }
        return first
    }

    func firstRequestIsWaiting() -> Bool {
        firstRequestContinuation != nil
    }

    func releaseFirstRequest() {
        let continuation = firstRequestContinuation
        firstRequestContinuation = nil
        continuation?.resume()
    }
}

private actor CheckpointingSecretStore: SecretStore {
    nonisolated let backend: SecretBackend = .keychain
    private var passwords: [UUID: String]
    private var secretEnvironments: [UUID: [String: String]]
    private var passwordWriteShouldFail = false
    private var environmentWriteShouldFail = false
    private var passwordWriteShouldPause = false
    private var passwordWritePauseContinuation: CheckedContinuation<Void, Never>?

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

    func pauseNextPasswordWrite() {
        passwordWriteShouldPause = true
    }

    func passwordWriteIsPaused() -> Bool {
        passwordWritePauseContinuation != nil
    }

    func resumePausedPasswordWrite() {
        let continuation = passwordWritePauseContinuation
        passwordWritePauseContinuation = nil
        continuation?.resume()
    }

    func setPassword(_ password: String, destId: UUID) async throws {
        if passwordWriteShouldPause {
            passwordWriteShouldPause = false
            await withCheckedContinuation { continuation in
                passwordWritePauseContinuation = continuation
            }
        }
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
