import Foundation
import Testing

import ResticStationCore
@testable import restic_station_helper

/// T24 regression: **which view does each subcommand read?**
///
/// `HelperContext` deliberately exposes no bare `config`. `tick` and `run-set`
/// read ``HelperContext/scheduled`` — what this machine backs up. The
/// repository utilities (`restore`, `probe-repo`, `unlock`, `init-secondary`)
/// read ``HelperContext/addressable`` — every repository this machine can
/// address, with the same overrides applied but nothing dropped.
///
/// Reading `scheduled` in a utility was a real bug: it broke the milestone's
/// headline case (a host set up as restore/mirror-only by disabling every
/// set could no longer restore or probe) and, where a destination overrode
/// `repoURL`, let a utility address a different repository than the one the
/// scheduler backs up to.
///
/// These tests drive `HelperContext.loadViews` — the single place the helper
/// resolves — against a real `config.json` + `machine.json` in a temp
/// directory, so they cover the loading order as well as the split.
@Suite struct HelperMachineScopeTests {

    private let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let primaryId = UUID(uuidString: "0A1B2C3D-4E5F-4A1B-8C1D-000000000001")!
    private let mirrorId = UUID(uuidString: "1B2C3D4E-5F60-4A1B-8C1D-000000000002")!

    private func makeTempPaths() throws -> (AppPaths, () -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("helper-scope-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        return (paths, { try? FileManager.default.removeItem(at: root) })
    }

    /// A shared config whose single set is disabled on `mirror-box`, and whose
    /// destinations both point somewhere else there. This is the fleet shape
    /// the finding is about: a restore/mirror-only host.
    private func writeFleetConfig(at paths: AppPaths, machineId: String) throws {
        let config = AppConfig(
            resticPath: "/opt/homebrew/bin/restic",
            sets: [BackupSet(
                id: setId,
                name: "Documents",
                sources: ["/Users/bwh/Documents"],
                schedule: .daily(hour: 2, minute: 30),
                destinations: [
                    Destination(
                        id: primaryId,
                        label: "Big Drive",
                        repoURL: "/Volumes/Big/docs.restic",
                        isPrimary: true,
                        machines: ["mirror-box": DestinationMachineOverride(repoURL: "/mnt/big/docs.restic")]
                    ),
                    Destination(
                        id: mirrorId,
                        label: "R2 mirror",
                        repoURL: "s3:https://r2.example/docs",
                        isPrimary: false,
                        machines: ["mirror-box": DestinationMachineOverride(
                            nonSecretEnv: ["AWS_DEFAULT_REGION": "us-east-1"]
                        )]
                    ),
                ],
                machines: ["mirror-box": BackupSetMachineOverride(enabled: false)]
            )]
        )
        try ConfigStore(paths: paths).save(config)
        try MachineStore.persistentIdentity(paths: paths)
            .save(MachineConfig(machineId: machineId, resticPath: "/usr/bin/restic"))
    }

    /// The headline case. A host that backs nothing up must still be able to
    /// address every repository — `restore`, `probe-repo`, `unlock` and
    /// `init-secondary` all resolve their set through `addressable`.
    @Test("a restore-only host backs up nothing but can still address every repository")
    func mirrorOnlyHostKeepsItsRepositories() throws {
        let (paths, cleanup) = try makeTempPaths()
        defer { cleanup() }
        try writeFleetConfig(at: paths, machineId: "mirror-box")

        let views = try HelperContext.loadViews(paths: paths, configStore: ConfigStore(paths: paths))

        // Scheduler: nothing runs here, and it says why.
        #expect(views.scheduled.config.sets.isEmpty)
        #expect(views.scheduled.set(id: setId) == nil)
        #expect(views.scheduled.omissions.map { $0.reason } == [.disabledForMachine])

        // Utilities: every set and destination is still addressable — this is
        // what `restore --set … --dest …` looks up.
        #expect(views.addressable.set(id: setId)?.name == "Documents")
        #expect(views.addressable.destination(id: primaryId) != nil)
        #expect(views.addressable.destination(id: mirrorId) != nil)
        #expect(views.addressable.omissions.isEmpty)
    }

    /// The other half of the finding: the repository a utility addresses must
    /// be **this machine's**, not the shared one.
    @Test("repository utilities see this machine's overridden repoURL and env")
    func addressableViewAppliesDestinationOverrides() throws {
        let (paths, cleanup) = try makeTempPaths()
        defer { cleanup() }
        try writeFleetConfig(at: paths, machineId: "mirror-box")

        let views = try HelperContext.loadViews(paths: paths, configStore: ConfigStore(paths: paths))

        let primary = views.addressable.destination(id: primaryId)?.destination
        #expect(primary?.repoURL == "/mnt/big/docs.restic")
        #expect(primary?.repoURL != "/Volumes/Big/docs.restic")

        let mirror = views.addressable.destination(id: mirrorId)?.destination
        #expect(mirror?.nonSecretEnv == ["AWS_DEFAULT_REGION": "us-east-1"])
        // Overrides replace, so a destination the machine does not override
        // keeps the shared repoURL.
        #expect(mirror?.repoURL == "s3:https://r2.example/docs")
    }

    /// A machine with no overrides sees both views identical to the shared
    /// config — the "nothing changes for existing single-machine setups"
    /// guarantee, asserted through the helper's own loader.
    @Test("a machine with no overrides sees identical scheduling and addressable views")
    func machineWithoutOverridesSeesBothViewsIdentical() throws {
        let (paths, cleanup) = try makeTempPaths()
        defer { cleanup() }
        try writeFleetConfig(at: paths, machineId: "studio-mac")

        let views = try HelperContext.loadViews(paths: paths, configStore: ConfigStore(paths: paths))

        #expect(views.scheduled.config == views.addressable.config)
        #expect(views.scheduled.config.sets.count == 1)
        #expect(views.scheduled.omissions.isEmpty)
        #expect(views.addressable.destination(id: primaryId)?.destination.repoURL == "/Volumes/Big/docs.restic")
    }

    /// Both views are tagged, so a mix-up is visible on the value itself.
    @Test("each view carries its own scope")
    func viewsCarryTheirScope() throws {
        let (paths, cleanup) = try makeTempPaths()
        defer { cleanup() }
        try writeFleetConfig(at: paths, machineId: "mirror-box")

        let views = try HelperContext.loadViews(paths: paths, configStore: ConfigStore(paths: paths))
        #expect(views.scheduled.scope == .scheduling)
        #expect(views.addressable.scope == .addressable)
        #expect(views.scheduled.machineId == "mirror-box")
        #expect(views.addressable.machineId == "mirror-box")
    }

    /// `machine.json`'s restic path reaches both views.
    @Test("both views carry the machine's restic path")
    func bothViewsCarryTheMachineResticPath() throws {
        let (paths, cleanup) = try makeTempPaths()
        defer { cleanup() }
        try writeFleetConfig(at: paths, machineId: "mirror-box")

        let views = try HelperContext.loadViews(paths: paths, configStore: ConfigStore(paths: paths))
        #expect(views.scheduled.config.resticPath == "/usr/bin/restic")
        #expect(views.addressable.config.resticPath == "/usr/bin/restic")
    }

    // MARK: - Load order

    /// `loadViews` must read `machine.json` **after** `config.json`, because
    /// loading a v1 config migrates `resticPath` into `machine.json` and
    /// clears it from the config. Reading the machine first would resolve
    /// `resticPath == nil` on the very first run after an upgrade, and the
    /// helper would report restic as unconfigured until the next invocation.
    @Test("a v1 config's restic path is visible on the same load that migrates it")
    func migratedResticPathIsVisibleImmediately() throws {
        let (paths, cleanup) = try makeTempPaths()
        defer { cleanup() }

        // A v1 config with a restic path, and no machine.json at all — exactly
        // the state an upgrading single-machine install is in.
        let v1 = """
        {"version":1,"resticPath":"/opt/homebrew/bin/restic","showMenuBarIcon":true,"sets":[]}
        """
        try Data(v1.utf8).write(to: paths.configFile)
        #expect(!FileManager.default.fileExists(atPath: paths.machineFile.path))

        let views = try HelperContext.loadViews(paths: paths, configStore: ConfigStore(paths: paths))

        #expect(views.scheduled.config.version == 3)
        #expect(views.scheduled.config.resticPath == "/opt/homebrew/bin/restic")
        #expect(views.addressable.config.resticPath == "/opt/homebrew/bin/restic")
        // …and it came from machine.json, which the same load created.
        #expect(try MachineStore.persistentIdentity(paths: paths).load().resticPath
            == "/opt/homebrew/bin/restic")
    }
}
