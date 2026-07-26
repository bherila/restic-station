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
