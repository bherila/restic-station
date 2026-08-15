import Foundation
import ResticStationCore
import Testing
@testable import Restic_Station

@Suite("AppModel machine override wiring", .serialized)
@MainActor
struct AppModelMachineOverrideTests {
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
