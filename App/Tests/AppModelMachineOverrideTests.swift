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
            isICloud: MaintenanceModel.isICloudRepository(destination)
        )

        guard case .reclaimSpace(let previewedDestination, let isICloud) = plan.action else {
            Issue.record("expected a reclaim plan")
            return
        }
        #expect(previewedDestination == destination)
        #expect(isICloud)
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
