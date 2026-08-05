import Foundation
import Testing
@testable import ResticStationCore

// T24: `AppConfig.resolved(for:)` — the single place a shared `config.json`
// becomes the effective, override-free config one machine acts on. A bug
// here silently backs up the wrong directories, or silently backs up
// nothing, so the cases below are exhaustive over the override surface.

private let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
private let otherSetId = UUID(uuidString: "7A8B9C0D-1E2F-4A3B-8C4D-000000000010")!
private let primaryId = UUID(uuidString: "0A1B2C3D-4E5F-4A1B-8C1D-000000000001")!
private let mirrorId = UUID(uuidString: "1B2C3D4E-5F60-4A1B-8C1D-000000000002")!
private let localOnlyId = UUID(uuidString: "2C3D4E5F-6061-4A1B-8C1D-000000000003")!

/// A single set with a primary and two secondaries, no overrides anywhere.
/// Each test adds exactly the override it is about.
private func baseSet() -> BackupSet {
    BackupSet(
        id: setId,
        name: "Documents",
        sources: ["/Users/bwh/Documents"],
        excludes: ["*.tmp"],
        schedule: .daily(hour: 2, minute: 30),
        retention: RetentionPolicy(keepDaily: 7),
        checkPolicy: CheckPolicy(enabled: true),
        stalenessWarningDays: 14,
        destinations: [
            Destination(id: primaryId, label: "Big Drive", repoURL: "/Volumes/Big/docs.restic", isPrimary: true),
            Destination(id: mirrorId, label: "R2 mirror", repoURL: "s3:https://r2.example/docs", isPrimary: false),
            Destination(id: localOnlyId, label: "Scratch HDD", repoURL: "/Volumes/Scratch/docs", isPrimary: false),
        ]
    )
}

private func baseConfig() -> AppConfig {
    AppConfig(resticPath: "/opt/homebrew/bin/restic", sets: [baseSet()])
}

// MARK: - Inheritance (the existing single-machine behaviour)

@Suite struct ResolutionInheritanceTests {

    /// The headline compatibility guarantee: no `machines` key anywhere means
    /// every machine inherits and runs, so a config authored before schema v2
    /// resolves to itself.
    @Test(arguments: ["mac-a", "linux-nas", "some-host-nobody-has-heard-of"])
    func noMachinesKeyResolvesToTheConfigItself(machineId: String) throws {
        let config = baseConfig()
        let resolved = config.resolved(for: machineId)

        #expect(resolved.config == config)
        #expect(resolved.omissions.isEmpty)
        #expect(resolved.machineId == machineId)
    }

    /// A `machines` map that names only *other* machines is the same as no
    /// map at all for this one — except that the (now meaningless) map is
    /// stripped from the resolved value.
    @Test func entryForAnotherMachineOnlyIsInherited() {
        var config = baseConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(enabled: false)]
        config.sets[0].destinations[2].machines = ["linux-nas": DestinationMachineOverride(enabled: false)]

        let resolved = config.resolved(for: "mac-a")

        #expect(resolved.config.sets.count == 1)
        #expect(resolved.config.sets[0].sources == ["/Users/bwh/Documents"])
        #expect(resolved.config.sets[0].destinations.count == 3)
        #expect(resolved.omissions.isEmpty)
    }

    /// The resolved value must be un-resolvable a second time: every
    /// `machines` map is gone, so it can never be saved back over the shared
    /// config's overrides, and no consumer can accidentally re-apply them.
    @Test func resolvedConfigCarriesNoMachinesKeys() {
        var config = baseConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(sources: ["/srv/data"])]
        config.sets[0].destinations[0].machines = [
            "linux-nas": DestinationMachineOverride(repoURL: "/mnt/big/docs.restic")
        ]

        for machineId in ["mac-a", "linux-nas"] {
            let resolved = config.resolved(for: machineId)
            for set in resolved.config.sets {
                #expect(set.machines == nil)
                for destination in set.destinations {
                    #expect(destination.machines == nil)
                }
            }
        }
    }

    /// An empty override — `{}` — is not the same as `enabled: false`; it
    /// changes nothing.
    @Test func emptyOverrideChangesNothing() {
        var config = baseConfig()
        config.sets[0].machines = ["mac-a": BackupSetMachineOverride()]

        let resolved = config.resolved(for: "mac-a")
        #expect(resolved.config.sets.count == 1)
        #expect(resolved.config.sets[0].sources == baseSet().sources)
        #expect(resolved.config.sets[0].schedule == baseSet().schedule)
        #expect(resolved.omissions.isEmpty)
    }
}

// MARK: - Overrides (table-driven over the whole surface)

@Suite struct ResolutionOverrideTests {

    @Test func disabledSetIsDroppedWithAReason() {
        var config = baseConfig()
        config.sets[0].machines = ["old-laptop": BackupSetMachineOverride(enabled: false)]

        let resolved = config.resolved(for: "old-laptop")

        #expect(resolved.config.sets.isEmpty)
        #expect(resolved.omissions == [
            ResolvedOmission(subject: .backupSet, id: setId, name: "Documents", reason: .disabledForMachine)
        ])
        #expect(resolved.omissions[0].description == "backup set \"Documents\" is disabled on this machine")
    }

    /// `enabled: true` is the default, spelled out — it must not drop anything.
    @Test func explicitlyEnabledSetRuns() {
        var config = baseConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(enabled: true, sources: ["/srv/data"])]

        let resolved = config.resolved(for: "linux-nas")
        #expect(resolved.config.sets.count == 1)
        #expect(resolved.config.sets[0].sources == ["/srv/data"])
    }

    @Test func disabledDestinationIsDroppedWithAReason() {
        var config = baseConfig()
        config.sets[0].destinations[2].machines = ["linux-nas": DestinationMachineOverride(enabled: false)]

        let resolved = config.resolved(for: "linux-nas")

        #expect(resolved.config.sets.count == 1)
        let destinationIds = resolved.config.sets[0].destinations.map { $0.id }
        #expect(destinationIds == [primaryId, mirrorId])
        #expect(resolved.omissions == [
            ResolvedOmission(
                subject: .destination(setId: setId),
                id: localOnlyId,
                name: "Scratch HDD",
                reason: .disabledForMachine
            )
        ])
    }

    /// Replace, never merge: the override array *is* the effective array.
    @Test func sourcesOverrideReplacesRatherThanMerges() {
        var config = baseConfig()
        config.sets[0].sources = ["/Users/bwh/Documents", "/Users/bwh/.gitconfig"]
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(sources: ["/srv/data"])]

        let resolved = config.resolved(for: "linux-nas")
        #expect(resolved.config.sets[0].sources == ["/srv/data"])
    }

    @Test func repoURLOverrideReplaces() {
        var config = baseConfig()
        config.sets[0].destinations[0].machines = [
            "linux-nas": DestinationMachineOverride(repoURL: "/mnt/big/docs.restic")
        ]

        let resolved = config.resolved(for: "linux-nas")
        #expect(resolved.config.sets[0].destinations[0].repoURL == "/mnt/big/docs.restic")
        // …and the destination id is untouched: it is the keychain key.
        #expect(resolved.config.sets[0].destinations[0].id == primaryId)
        #expect(resolved.config.sets[0].destinations[0].isPrimary)
        // The other machine still sees the shared value.
        #expect(config.resolved(for: "mac-a").config.sets[0].destinations[0].repoURL == "/Volumes/Big/docs.restic")
    }

    @Test func scheduleOverrideReplaces() {
        var config = baseConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(schedule: .everyMinutes(30))]

        #expect(config.resolved(for: "linux-nas").config.sets[0].schedule == .everyMinutes(30))
        #expect(config.resolved(for: "mac-a").config.sets[0].schedule == .daily(hour: 2, minute: 30))
    }

    @Test func nonSecretEnvOverrideReplacesWholesale() {
        var config = baseConfig()
        config.sets[0].destinations[1].nonSecretEnv = ["AWS_DEFAULT_REGION": "auto", "KEEP": "me"]
        config.sets[0].destinations[1].machines = [
            "linux-nas": DestinationMachineOverride(nonSecretEnv: ["AWS_DEFAULT_REGION": "us-east-1"])
        ]

        let resolved = config.resolved(for: "linux-nas")
        #expect(resolved.config.sets[0].destinations[1].nonSecretEnv == ["AWS_DEFAULT_REGION": "us-east-1"])
    }

    /// Rule 4a: with every destination disabled here, the set has nowhere to
    /// back up to — dropped, and said so.
    @Test func setWithZeroEnabledDestinationsIsDropped() {
        var config = baseConfig()
        let off = DestinationMachineOverride(enabled: false)
        for index in config.sets[0].destinations.indices {
            config.sets[0].destinations[index].machines = ["linux-nas": off]
        }

        let resolved = config.resolved(for: "linux-nas")

        #expect(resolved.config.sets.isEmpty)
        // Three destination omissions, then the set itself.
        #expect(resolved.omissions.count == 4)
        #expect(resolved.omissions.last == ResolvedOmission(
            subject: .backupSet, id: setId, name: "Documents", reason: .noEnabledDestinations
        ))
        #expect(resolved.omissions.last?.description
            == "backup set \"Documents\" has no destinations enabled on this machine")
    }

    /// Rule 4b: an override that replaces `sources` with `[]` says "nothing
    /// to back up here". The set is dropped rather than run source-less —
    /// a `restic backup` with no paths is not a no-op, it is a mistake.
    @Test func setWithEmptyOverrideSourcesIsDropped() {
        var config = baseConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(sources: [])]

        let resolved = config.resolved(for: "linux-nas")

        #expect(resolved.config.sets.isEmpty)
        #expect(resolved.omissions == [
            ResolvedOmission(subject: .backupSet, id: setId, name: "Documents", reason: .noSources)
        ])
    }

    /// Order matters: a disabled set is dropped before its destinations are
    /// even considered, so it produces exactly one omission, not four.
    @Test func disabledSetDoesNotAlsoReportItsDestinations() {
        var config = baseConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(enabled: false)]
        config.sets[0].destinations[0].machines = ["linux-nas": DestinationMachineOverride(enabled: false)]

        #expect(config.resolved(for: "linux-nas").omissions.count == 1)
    }

    /// Config order is the tick's execution order; resolution must preserve it.
    @Test func survivingSetsAndDestinationsKeepConfigOrder() {
        var config = baseConfig()
        var second = baseSet()
        second.id = otherSetId
        second.name = "Photos"
        second.destinations = [Destination(
            id: UUID(uuidString: "3D4E5F60-6162-4A1B-8C1D-000000000004")!,
            label: "Big Drive",
            repoURL: "/Volumes/Big/photos.restic",
            isPrimary: true
        )]
        config.sets.append(second)
        config.sets[0].destinations[1].machines = ["linux-nas": DestinationMachineOverride(enabled: false)]

        let resolved = config.resolved(for: "linux-nas")
        #expect(resolved.config.sets.map { $0.id } == [setId, otherSetId])
        #expect(resolved.config.sets[0].destinations.map { $0.id } == [primaryId, localOnlyId])
    }
}

// MARK: - resticPath

@Suite struct ResolutionResticPathTests {

    @Test func machineResticPathWinsOverTheDeprecatedConfigField() {
        let config = baseConfig()
        let machine = MachineConfig(machineId: "linux-nas", resticPath: "/usr/bin/restic")
        #expect(config.resolved(for: machine).config.resticPath == "/usr/bin/restic")
    }

    @Test(arguments: [nil, ""] as [String?])
    func absentOrEmptyMachineResticPathFallsBackToTheConfigField(machinePath: String?) {
        let config = baseConfig()
        let machine = MachineConfig(machineId: "mac-a", resticPath: machinePath)
        #expect(config.resolved(for: machine).config.resticPath == "/opt/homebrew/bin/restic")
    }

    @Test func machineOverloadResolvesTheSameSetsAsTheMachineIdOverload() {
        var config = baseConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(sources: ["/srv/data"])]

        let byId = config.resolved(for: "linux-nas")
        let byMachine = config.resolved(for: MachineConfig(machineId: "linux-nas"))
        #expect(byId == byMachine)
    }
}

// MARK: - referencedMachineIds

@Suite struct ReferencedMachineIdsTests {
    @Test func collectsSetAndDestinationKeysSortedAndDeduplicated() {
        var config = baseConfig()
        config.sets[0].machines = [
            "linux-nas": BackupSetMachineOverride(sources: ["/srv/data"]),
            "old-laptop": BackupSetMachineOverride(enabled: false),
        ]
        config.sets[0].destinations[0].machines = [
            "linux-nas": DestinationMachineOverride(repoURL: "/mnt/big"),
            "mac-a": DestinationMachineOverride(repoURL: "/Volumes/Big"),
        ]

        #expect(config.referencedMachineIds == ["linux-nas", "mac-a", "old-laptop"])
    }

    @Test func isEmptyForAConfigWithNoOverrides() {
        #expect(baseConfig().referencedMachineIds.isEmpty)
    }
}

// MARK: - Cross-platform invariant

/// The invariant the whole design rests on: **resolution depends only on
/// `machineId`, never on the host OS.**
///
/// This suite runs on macOS *and* on Linux CI (`swift test --package-path
/// Core` in both jobs). The expected JSON below is a literal in the test
/// source, so if resolution ever grew a platform branch — an `#if os(...)`,
/// a `FileManager` existence check, an environment lookup — one of the two
/// platforms would stop matching it.
@Suite struct CrossPlatformResolutionInvarianceTests {

    /// A Mac laptop that is a backup *source*, and a Linux NAS that is both a
    /// source of its own directories and a mirror target — the two headline
    /// cases from `docs/data-model.md` §Per-machine scoping.
    private func fleetConfig() -> AppConfig {
        var config = baseConfig()
        config.resticPath = nil
        config.sets[0].machines = [
            "linux-nas": BackupSetMachineOverride(sources: ["/srv/data"], schedule: .daily(hour: 4, minute: 0))
        ]
        config.sets[0].destinations[0].machines = [
            "linux-nas": DestinationMachineOverride(repoURL: "/mnt/big/docs.restic")
        ]
        config.sets[0].destinations[2].machines = [
            "linux-nas": DestinationMachineOverride(enabled: false)
        ]
        return config
    }

    private func encoded(_ config: AppConfig) throws -> NSDictionary? {
        let data = try ConfigStore.makeEncoder().encode(config)
        return try JSONSerialization.jsonObject(with: data) as? NSDictionary
    }

    private func parsed(_ json: String) throws -> NSDictionary? {
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
    }

    @Test func macResolutionIsIdenticalOnEveryHostOS() throws {
        let expected = """
        {
          "version": 2,
          "resticPath": null,
          "showMenuBarIcon": true,
          "sets": [
            {
              "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
              "name": "Documents",
              "sources": ["/Users/bwh/Documents"],
              "excludes": ["*.tmp"],
              "schedule": { "kind": "daily", "hour": 2, "minute": 30 },
              "retention": {
                "keepLast": null, "keepHourly": null, "keepDaily": 7,
                "keepWeekly": null, "keepMonthly": null, "keepYearly": null
              },
              "checkPolicy": { "enabled": true, "readDataSubsetSlices": 20 },
              "stalenessWarningDays": 14,
              "destinations": [
                {
                  "id": "0A1B2C3D-4E5F-4A1B-8C1D-000000000001",
                  "label": "Big Drive",
                  "repoURL": "/Volumes/Big/docs.restic",
                  "isPrimary": true,
                  "nonSecretEnv": {}
                },
                {
                  "id": "1B2C3D4E-5F60-4A1B-8C1D-000000000002",
                  "label": "R2 mirror",
                  "repoURL": "s3:https://r2.example/docs",
                  "isPrimary": false,
                  "nonSecretEnv": {}
                },
                {
                  "id": "2C3D4E5F-6061-4A1B-8C1D-000000000003",
                  "label": "Scratch HDD",
                  "repoURL": "/Volumes/Scratch/docs",
                  "isPrimary": false,
                  "nonSecretEnv": {}
                }
              ]
            }
          ]
        }
        """
        let resolved = fleetConfig().resolved(for: "mac-a")
        #expect(try encoded(resolved.config) == (try parsed(expected)))
        #expect(resolved.omissions.isEmpty)
    }

    @Test func linuxResolutionIsIdenticalOnEveryHostOS() throws {
        let expected = """
        {
          "version": 2,
          "resticPath": null,
          "showMenuBarIcon": true,
          "sets": [
            {
              "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
              "name": "Documents",
              "sources": ["/srv/data"],
              "excludes": ["*.tmp"],
              "schedule": { "kind": "daily", "hour": 4, "minute": 0 },
              "retention": {
                "keepLast": null, "keepHourly": null, "keepDaily": 7,
                "keepWeekly": null, "keepMonthly": null, "keepYearly": null
              },
              "checkPolicy": { "enabled": true, "readDataSubsetSlices": 20 },
              "stalenessWarningDays": 14,
              "destinations": [
                {
                  "id": "0A1B2C3D-4E5F-4A1B-8C1D-000000000001",
                  "label": "Big Drive",
                  "repoURL": "/mnt/big/docs.restic",
                  "isPrimary": true,
                  "nonSecretEnv": {}
                },
                {
                  "id": "1B2C3D4E-5F60-4A1B-8C1D-000000000002",
                  "label": "R2 mirror",
                  "repoURL": "s3:https://r2.example/docs",
                  "isPrimary": false,
                  "nonSecretEnv": {}
                }
              ]
            }
          ]
        }
        """
        let resolved = fleetConfig().resolved(for: "linux-nas")
        #expect(try encoded(resolved.config) == (try parsed(expected)))
        #expect(resolved.omissions.map { $0.reason } == [.disabledForMachine])
        #expect(resolved.omissions.map { $0.id } == [localOnlyId])
    }

    /// The same claim stated as a property rather than as a table: resolving
    /// the same config for the same `machineId` twice, and encoding both,
    /// must produce identical bytes — and the two machines must genuinely
    /// differ, so the test cannot pass by resolving to nothing.
    @Test func resolutionIsDeterministicAndTheTwoMachinesDiffer() throws {
        let config = fleetConfig()
        let encoder = ConfigStore.makeEncoder()

        for machineId in ["mac-a", "linux-nas"] {
            let first = try encoder.encode(config.resolved(for: machineId).config)
            let second = try encoder.encode(config.resolved(for: machineId).config)
            #expect(first == second)
        }

        let mac = try encoder.encode(config.resolved(for: "mac-a").config)
        let linux = try encoder.encode(config.resolved(for: "linux-nas").config)
        #expect(mac != linux)
    }
}

// MARK: - The addressable view

/// The second view (`ResolvedConfig.Scope.addressable`): same overrides, but
/// `enabled` drops nothing.
///
/// This suite exists because of a real bug: every repository *utility* —
/// restore, probe, unlock, init, the app's size and retention-preview
/// queries — was reading the scheduling view, which meant a host configured
/// as restore/mirror-only (every set disabled) could not address any of its
/// own repositories, and a host with a `repoURL` override could browse,
/// measure and initialize a *different* repository than the one the helper
/// backs up to.
@Suite struct AddressableResolutionTests {

    /// The headline case for the whole milestone: a mirror/restore-only host
    /// disables every set, and must still see every repository.
    @Test func disabledSetsSurviveInTheAddressableView() {
        var config = baseConfig()
        config.sets[0].machines = ["mirror-box": BackupSetMachineOverride(enabled: false)]

        let scheduled = config.resolved(for: "mirror-box")
        let addressable = config.addressable(for: "mirror-box")

        #expect(scheduled.config.sets.isEmpty)
        #expect(addressable.config.sets.count == 1)
        #expect(addressable.config.sets[0].destinations.count == 3)
        #expect(addressable.omissions.isEmpty)
        #expect(addressable.scope == .addressable)
        #expect(scheduled.scope == .scheduling)
    }

    @Test func disabledDestinationsSurviveInTheAddressableView() {
        var config = baseConfig()
        config.sets[0].destinations[2].machines = ["linux-nas": DestinationMachineOverride(enabled: false)]

        #expect(config.resolved(for: "linux-nas").config.sets[0].destinations.count == 2)
        #expect(config.addressable(for: "linux-nas").config.sets[0].destinations.count == 3)
    }

    /// A set that would be dropped for having no sources here is still
    /// addressable — you restore *into* a machine that has nothing to back up.
    @Test func setsWithNoSourcesHereSurviveInTheAddressableView() {
        var config = baseConfig()
        config.sets[0].machines = ["mirror-box": BackupSetMachineOverride(sources: [])]

        #expect(config.resolved(for: "mirror-box").config.sets.isEmpty)
        #expect(config.addressable(for: "mirror-box").config.sets.count == 1)
    }

    /// The two views must never disagree about what a repository *is* — only
    /// about which ones are backed up here.
    @Test func bothViewsApplyTheSameOverrides() {
        var config = baseConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(
            sources: ["/srv/data"], schedule: .everyMinutes(30)
        )]
        config.sets[0].destinations[0].machines = ["linux-nas": DestinationMachineOverride(
            repoURL: "/mnt/big/docs.restic", nonSecretEnv: ["AWS_DEFAULT_REGION": "us-east-1"]
        )]

        let scheduled = config.resolved(for: "linux-nas").config.sets[0]
        let addressable = config.addressable(for: "linux-nas").config.sets[0]

        #expect(scheduled.sources == ["/srv/data"])
        #expect(addressable.sources == ["/srv/data"])
        #expect(scheduled.schedule == .everyMinutes(30))
        #expect(addressable.schedule == .everyMinutes(30))
        #expect(scheduled.destinations[0].repoURL == "/mnt/big/docs.restic")
        #expect(addressable.destinations[0].repoURL == "/mnt/big/docs.restic")
        #expect(addressable.destinations[0].nonSecretEnv == ["AWS_DEFAULT_REGION": "us-east-1"])
    }

    /// The class-of-bug guard: with every destination overridden, **no raw
    /// `repoURL` or `nonSecretEnv` may survive into either view**. Anything
    /// that builds a restic invocation from a `ResolvedConfig` therefore
    /// cannot reach a shared value by accident; the only remaining way to
    /// get one is to read the raw `AppConfig`, which is what the consumers
    /// were fixed to stop doing.
    @Test func noRawDestinationValueSurvivesInEitherView() {
        var config = baseConfig()
        for index in config.sets[0].destinations.indices {
            config.sets[0].destinations[index].machines = [
                "linux-nas": DestinationMachineOverride(
                    repoURL: "/mnt/overridden/\(index)",
                    nonSecretEnv: ["OVERRIDDEN": "\(index)"]
                )
            ]
        }
        let rawRepoURLs = Set(config.sets[0].destinations.map { $0.repoURL })

        for view in [config.resolved(for: "linux-nas"), config.addressable(for: "linux-nas")] {
            #expect(!view.config.sets.isEmpty)
            for (_, destination) in view.destinations {
                #expect(!rawRepoURLs.contains(destination.repoURL))
                #expect(destination.repoURL.hasPrefix("/mnt/overridden/"))
                #expect(destination.nonSecretEnv["OVERRIDDEN"] != nil)
                #expect(destination.machines == nil)
            }
        }
    }

    // MARK: Lookup helpers — the one sanctioned way consumers find a repo

    @Test func lookupsReturnOverriddenValues() {
        var config = baseConfig()
        config.sets[0].destinations[0].machines = [
            "linux-nas": DestinationMachineOverride(repoURL: "/mnt/big/docs.restic")
        ]
        let view = config.addressable(for: "linux-nas")

        #expect(view.set(id: setId)?.name == "Documents")
        #expect(view.set(id: UUID()) == nil)

        let found = view.destination(id: primaryId)
        #expect(found?.set.id == setId)
        #expect(found?.destination.repoURL == "/mnt/big/docs.restic")
        #expect(view.destination(id: UUID()) == nil)
    }

    @Test func lookupsSeeDisabledSetsInTheAddressableViewOnly() {
        var config = baseConfig()
        config.sets[0].machines = ["mirror-box": BackupSetMachineOverride(enabled: false)]

        #expect(config.addressable(for: "mirror-box").set(id: setId) != nil)
        #expect(config.addressable(for: "mirror-box").destination(id: primaryId) != nil)
        #expect(config.resolved(for: "mirror-box").set(id: setId) == nil)
        #expect(config.resolved(for: "mirror-box").destination(id: primaryId) == nil)
    }

    @Test func destinationsEnumeratesEveryRepositoryWithItsOwningSet() {
        let view = baseConfig().addressable(for: "mac-a")
        #expect(view.destinations.map { $0.destination.id } == [primaryId, mirrorId, localOnlyId])
        #expect(view.destinations.allSatisfy { $0.set.id == setId })
    }

    // MARK: resticPath and platform independence carry over

    @Test func addressableViewAlsoTakesTheMachineResticPath() {
        let machine = MachineConfig(machineId: "linux-nas", resticPath: "/usr/bin/restic")
        #expect(baseConfig().addressable(for: machine).config.resticPath == "/usr/bin/restic")
    }

    /// Same invariant as the scheduling view, asserted on both platforms.
    @Test func addressableResolutionIsDeterministicAndMachineDependentOnly() throws {
        var config = baseConfig()
        config.sets[0].destinations[0].machines = [
            "linux-nas": DestinationMachineOverride(repoURL: "/mnt/big/docs.restic")
        ]
        let encoder = ConfigStore.makeEncoder()

        for machineId in ["mac-a", "linux-nas"] {
            let first = try encoder.encode(config.addressable(for: machineId).config)
            let second = try encoder.encode(config.addressable(for: machineId).config)
            #expect(first == second)
        }
        #expect(try encoder.encode(config.addressable(for: "mac-a").config)
            != (try encoder.encode(config.addressable(for: "linux-nas").config)))
    }

    /// A config with no overrides at all: both views are the config itself,
    /// so nothing about the existing single-machine behaviour changes.
    @Test func withoutOverridesBothViewsAreTheConfigItself() {
        let config = baseConfig()
        #expect(config.resolved(for: "anything").config == config)
        #expect(config.addressable(for: "anything").config == config)
    }
}

// MARK: - Fixtures

@Suite struct ResolutionFixtureTests {

    /// The v2 fixture is the shipped worked example: a Mac source, a Linux
    /// NAS that backs up its own directories to a local repo path, and a set
    /// the NAS does not run at all.
    @Test func v2FixtureResolvesAsDocumented() throws {
        let config = try ConfigStore.makeDecoder().decode(AppConfig.self, from: FixtureLoader.data("config-v2.json"))
        try config.validate()
        #expect(config.version == 2)
        #expect(config.referencedMachineIds == ["linux-nas", "old-laptop"])

        // The Mac: everything inherited, nothing omitted.
        let mac = config.resolved(for: "studio-mac")
        #expect(mac.omissions.isEmpty)
        #expect(mac.config.sets.count == 2)
        #expect(mac.config.sets[0].sources == ["/Users/bwh/Documents"])
        #expect(mac.config.sets[0].destinations.count == 3)
        #expect(mac.config.sets[1].name == "Photos")

        // The Linux NAS: its own sources, its own repo paths, no Mac-local
        // external drive, and no Photos set at all.
        let nas = config.resolved(for: "linux-nas")
        #expect(nas.config.sets.count == 1)
        #expect(nas.config.sets[0].sources == ["/srv/data"])
        #expect(nas.config.sets[0].schedule == .daily(hour: 4, minute: 0))
        #expect(nas.config.sets[0].destinations.map { $0.repoURL } == [
            "/mnt/big/documents.restic",
            "s3:https://accountid.r2.cloudflarestorage.com/backups/documents",
        ])
        #expect(nas.omissions.map { $0.reason } == [.disabledForMachine, .disabledForMachine])

        // The retired laptop: the first set is off, the second still runs.
        let laptop = config.resolved(for: "old-laptop")
        #expect(laptop.config.sets.map { $0.name } == ["Photos"])
    }

    /// Round-trip: the v2 fixture, with all its overrides, encodes and
    /// decodes back to itself.
    @Test func v2FixtureRoundTrips() throws {
        let decoder = ConfigStore.makeDecoder()
        let config = try decoder.decode(AppConfig.self, from: FixtureLoader.data("config-v2.json"))
        let reencoded = try ConfigStore.makeEncoder().encode(config)
        #expect(try decoder.decode(AppConfig.self, from: reencoded) == config)

        // Structural equality against the fixture bytes: no key gained, none
        // lost — in particular no `"machines": null` sprayed over every set
        // and destination that has no overrides.
        let actual = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: FixtureLoader.data("config-v2.json")) as? NSDictionary
        #expect(actual == expected)
    }

    /// The pre-change fixture, resolved on the machine that authored it,
    /// must be the config itself — byte for byte, once the version bump is
    /// accounted for. This is the "existing configs behave exactly as they
    /// do today" guarantee, stated against a realistic file.
    @Test func v1FixtureResolvesToItselfOnAnyMachine() throws {
        let config = try ConfigStore.makeDecoder().decode(AppConfig.self, from: FixtureLoader.data("config-v1.json"))
        try config.validate()

        for machineId in ["studio-mac", "linux-nas", "anything-at-all"] {
            let resolved = config.resolved(for: machineId)
            #expect(resolved.config == config)
            #expect(resolved.omissions.isEmpty)
        }
    }
}
