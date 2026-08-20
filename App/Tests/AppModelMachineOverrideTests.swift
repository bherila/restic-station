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
}
