import Foundation
import Testing
@testable import ResticStationCore

/// Builds a minimal, otherwise-valid `AppConfig` with exactly one set and
/// one primary destination, then lets each test mutate the one field under
/// test so every case isolates a single invariant violation.
private func makeValidConfig() -> AppConfig {
    let setId = UUID()
    let destId = UUID()
    let set = BackupSet(
        id: setId,
        name: "Test set",
        sources: ["/src"],
        excludes: [],
        schedule: .daily(hour: 2, minute: 30),
        retention: nil,
        checkPolicy: CheckPolicy(enabled: true, readDataSubsetSlices: 20),
        stalenessWarningDays: 14,
        destinations: [
            Destination(id: destId, label: "Primary", repoURL: "/repo", isPrimary: true)
        ]
    )
    return AppConfig(sets: [set])
}

@Suite struct ValidateTests {
    @Test func validConfigPasses() throws {
        try makeValidConfig().validate()
    }

    // Invariant 1: exactly one primary.

    @Test func zeroPrimariesThrows() {
        var config = makeValidConfig()
        config.sets[0].destinations[0].isPrimary = false
        #expect(throws: ConfigError.notExactlyOnePrimaryDestination(setId: config.sets[0].id, count: 0)) {
            try config.validate()
        }
    }

    @Test func twoPrimariesThrows() {
        var config = makeValidConfig()
        var second = config.sets[0].destinations[0]
        second.id = UUID()
        second.isPrimary = true
        config.sets[0].destinations.append(second)
        #expect(throws: ConfigError.notExactlyOnePrimaryDestination(setId: config.sets[0].id, count: 2)) {
            try config.validate()
        }
    }

    // Invariant 2: set and destination UUIDs unique across the config.

    @Test func duplicateSetUUIDsThrows() {
        var config = makeValidConfig()
        var duplicateSet = config.sets[0]
        duplicateSet.destinations[0].id = UUID() // keep destination IDs distinct
        config.sets.append(duplicateSet)
        #expect(throws: ConfigError.duplicateIdentifier(config.sets[0].id)) {
            try config.validate()
        }
    }

    @Test func duplicateDestinationUUIDsThrows() {
        var config = makeValidConfig()
        let sharedId = config.sets[0].destinations[0].id
        var secondSet = config.sets[0]
        secondSet.id = UUID()
        secondSet.destinations[0].id = sharedId // collides with set 0's destination
        config.sets.append(secondSet)
        #expect(throws: ConfigError.duplicateIdentifier(sharedId)) {
            try config.validate()
        }
    }

    // Invariant 3: sources non-empty; every source absolute.

    @Test func emptySourcesThrows() {
        var config = makeValidConfig()
        config.sets[0].sources = []
        #expect(throws: ConfigError.emptySources(setId: config.sets[0].id)) {
            try config.validate()
        }
    }

    @Test func relativeSourcePathThrows() {
        var config = makeValidConfig()
        config.sets[0].sources = ["relative/path"]
        #expect(throws: ConfigError.relativeSourcePath(setId: config.sets[0].id, path: "relative/path")) {
            try config.validate()
        }
    }

    // Invariant 4: Schedule fields in range.

    @Test func minute60Throws() {
        var config = makeValidConfig()
        config.sets[0].schedule = .daily(hour: 2, minute: 60)
        do {
            try config.validate()
            Issue.record("expected validate() to throw")
        } catch let error as ConfigError {
            guard case .invalidSchedule = error else {
                Issue.record("expected .invalidSchedule, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ConfigError, got \(error)")
        }
    }

    @Test func everyMinutes4Throws() {
        var config = makeValidConfig()
        config.sets[0].schedule = .everyMinutes(4)
        do {
            try config.validate()
            Issue.record("expected validate() to throw")
        } catch let error as ConfigError {
            guard case .invalidSchedule = error else {
                Issue.record("expected .invalidSchedule, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ConfigError, got \(error)")
        }
    }

    @Test func hour24Throws() {
        var config = makeValidConfig()
        config.sets[0].schedule = .daily(hour: 24, minute: 0)
        do {
            try config.validate()
            Issue.record("expected validate() to throw")
        } catch let error as ConfigError {
            guard case .invalidSchedule = error else {
                Issue.record("expected .invalidSchedule, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ConfigError, got \(error)")
        }
    }

    @Test func weekday0Throws() {
        var config = makeValidConfig()
        config.sets[0].schedule = .weekly(weekday: 0, hour: 0, minute: 0)
        do {
            try config.validate()
            Issue.record("expected validate() to throw")
        } catch let error as ConfigError {
            guard case .invalidSchedule = error else {
                Issue.record("expected .invalidSchedule, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ConfigError, got \(error)")
        }
    }

    @Test func weekday8Throws() {
        var config = makeValidConfig()
        config.sets[0].schedule = .weekly(weekday: 8, hour: 0, minute: 0)
        do {
            try config.validate()
            Issue.record("expected validate() to throw")
        } catch let error as ConfigError {
            guard case .invalidSchedule = error else {
                Issue.record("expected .invalidSchedule, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ConfigError, got \(error)")
        }
    }

    // Invariant 5: stalenessWarningDays >= 1; readDataSubsetSlices in 2...100.

    @Test func stalenessWarningDaysZeroThrows() {
        var config = makeValidConfig()
        config.sets[0].stalenessWarningDays = 0
        #expect(throws: ConfigError.invalidStalenessWarningDays(setId: config.sets[0].id, value: 0)) {
            try config.validate()
        }
    }

    @Test func readDataSubsetSlicesTooLowThrows() {
        var config = makeValidConfig()
        config.sets[0].checkPolicy = CheckPolicy(enabled: true, readDataSubsetSlices: 1)
        #expect(throws: ConfigError.invalidReadDataSubsetSlices(setId: config.sets[0].id, value: 1)) {
            try config.validate()
        }
    }

    @Test func readDataSubsetSlicesTooHighThrows() {
        var config = makeValidConfig()
        config.sets[0].checkPolicy = CheckPolicy(enabled: true, readDataSubsetSlices: 101)
        #expect(throws: ConfigError.invalidReadDataSubsetSlices(setId: config.sets[0].id, value: 101)) {
            try config.validate()
        }
    }

    @Test func readDataSubsetSlicesBoundsAreInclusive() throws {
        var config = makeValidConfig()
        config.sets[0].checkPolicy = CheckPolicy(enabled: true, readDataSubsetSlices: 2)
        try config.validate()
        config.sets[0].checkPolicy = CheckPolicy(enabled: true, readDataSubsetSlices: 100)
        try config.validate()
    }
}

// MARK: - T24: per-machine invariants

/// Invariants 6 (override shape) and 7 (the post-resolution primary rule).
@Suite struct ValidateMachineOverrideTests {

    // Invariant 6: machineId keys.

    @Test(arguments: ["linux-nas", "nas01", "a", "studio-mac"])
    func validMachineIdKeysAreAccepted(machineId: String) throws {
        var config = makeValidConfig()
        config.sets[0].machines = [machineId: BackupSetMachineOverride(sources: ["/srv/data"])]
        try config.validate()
    }

    @Test(arguments: ["", "Linux-NAS", "linux_nas", "linux nas", "linux.nas"])
    func invalidMachineIdKeyOnASetThrows(machineId: String) {
        var config = makeValidConfig()
        config.sets[0].machines = [machineId: BackupSetMachineOverride(enabled: false)]
        #expect(throws: ConfigError.invalidMachineIdKey(setId: config.sets[0].id, machineId: machineId)) {
            try config.validate()
        }
    }

    @Test func invalidMachineIdKeyOnADestinationThrows() {
        var config = makeValidConfig()
        config.sets[0].destinations[0].machines = ["Bad Id": DestinationMachineOverride(repoURL: "/mnt/x")]
        #expect(throws: ConfigError.invalidMachineIdKey(setId: config.sets[0].id, machineId: "Bad Id")) {
            try config.validate()
        }
    }

    /// "Machines come and go, and the config is shared": a key no machine in
    /// the fleet claims is a warning for `config validate` (T27), not an
    /// error here.
    @Test func anUnknownMachineKeyIsAccepted() throws {
        var config = makeValidConfig()
        config.sets[0].machines = ["a-machine-that-never-existed": BackupSetMachineOverride(enabled: false)]
        try config.validate()
        #expect(config.referencedMachineIds == ["a-machine-that-never-existed"])
    }

    // Invariant 6: override values get the same checks as what they replace.

    @Test func relativeOverrideSourcePathThrows() {
        var config = makeValidConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(sources: ["srv/data"])]
        #expect(throws: ConfigError.relativeOverrideSourcePath(
            setId: config.sets[0].id, machineId: "linux-nas", path: "srv/data"
        )) {
            try config.validate()
        }
    }

    /// Deliberately *not* the same as the top-level rule: an empty override
    /// array is legal and means "nothing to back up here". Resolution drops
    /// the set with a recorded reason.
    @Test func emptyOverrideSourcesAreAccepted() throws {
        var config = makeValidConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(sources: [])]
        try config.validate()
        #expect(config.resolved(for: "linux-nas").omissions.map { $0.reason } == [.noSources])
    }

    @Test func outOfRangeOverrideScheduleThrows() {
        var config = makeValidConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(schedule: .daily(hour: 24, minute: 0))]
        do {
            try config.validate()
            Issue.record("expected validate() to throw")
        } catch let error as ConfigError {
            guard case .invalidSchedule = error else {
                Issue.record("expected .invalidSchedule, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ConfigError, got \(error)")
        }
    }

    // Invariant 7: exactly one primary, per machine, after resolution.

    /// The dangerous shape: the machine keeps the set but loses its primary,
    /// so it would resolve to a set with nowhere to back up to.
    @Test func disablingThePrimaryWithoutDisablingTheSetIsRejected() {
        var config = makeValidConfig()
        config.sets[0].destinations[0].machines = ["linux-nas": DestinationMachineOverride(enabled: false)]

        #expect(throws: ConfigError.notExactlyOnePrimaryDestinationForMachine(
            setId: config.sets[0].id, machineId: "linux-nas", count: 0
        )) {
            try config.validate()
        }
    }

    /// The correct way to say "this machine does not run this set".
    @Test func disablingTheWholeSetForThatMachineIsFine() throws {
        var config = makeValidConfig()
        config.sets[0].machines = ["linux-nas": BackupSetMachineOverride(enabled: false)]
        config.sets[0].destinations[0].machines = ["linux-nas": DestinationMachineOverride(enabled: false)]
        try config.validate()
    }

    /// Disabling a *secondary* is exactly the intended use — the Mac-local
    /// external drive that the Linux host must not probe.
    @Test func disablingASecondaryIsFine() throws {
        var config = makeValidConfig()
        config.sets[0].destinations.append(
            Destination(id: UUID(), label: "Mac-only HDD", repoURL: "/Volumes/Big", isPrimary: false)
        )
        config.sets[0].destinations[1].machines = ["linux-nas": DestinationMachineOverride(enabled: false)]
        try config.validate()

        let resolved = config.resolved(for: "linux-nas")
        #expect(resolved.config.sets[0].destinations.count == 1)
        #expect(resolved.config.sets[0].destinations[0].isPrimary)
    }

    /// Every mentioned machine is checked, not just the first one.
    @Test func aBadPrimaryOnTheSecondMachineIsStillCaught() {
        var config = makeValidConfig()
        config.sets[0].destinations[0].machines = [
            "linux-nas": DestinationMachineOverride(repoURL: "/mnt/big"),
            "old-laptop": DestinationMachineOverride(enabled: false),
        ]

        #expect(throws: ConfigError.notExactlyOnePrimaryDestinationForMachine(
            setId: config.sets[0].id, machineId: "old-laptop", count: 0
        )) {
            try config.validate()
        }
    }

    /// A config with no `machines` keys at all must not pay for invariant 7
    /// in behaviour: it is exactly as valid (or invalid) as it was before v2.
    @Test func aConfigWithoutOverridesIsUnaffected() throws {
        try makeValidConfig().validate()

        var broken = makeValidConfig()
        broken.sets[0].destinations[0].isPrimary = false
        #expect(throws: ConfigError.notExactlyOnePrimaryDestination(setId: broken.sets[0].id, count: 0)) {
            try broken.validate()
        }
    }
}
