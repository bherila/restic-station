import Foundation
import Testing
@testable import ResticStationCore

// Pins which saves kick an early tick (`docs/scheduling.md` §What the app
// does) — see `ConfigDiff`.

private let setId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let primaryId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let secondaryId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

private func baseSet() -> BackupSet {
    BackupSet(
        id: setId,
        name: "Projects",
        sources: ["/Users/someone/Projects"],
        excludes: ["*.tmp"],
        schedule: .daily(hour: 2, minute: 30),
        retention: RetentionPolicy(keepDaily: 7),
        checkPolicy: CheckPolicy(enabled: true),
        stalenessWarningDays: 14,
        destinations: [
            Destination(id: primaryId, label: "Primary", repoURL: "/tmp/primary", isPrimary: true)
        ]
    )
}

private func baseConfig() -> AppConfig {
    AppConfig(resticPath: "/opt/homebrew/bin/restic", showMenuBarIcon: true, sets: [baseSet()])
}

@Suite struct ConfigDiffRelevantTests {
    @Test func identicalConfigIsNotAChange() {
        #expect(!ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: baseConfig()))
    }

    @Test func scheduleChangeIsRelevant() {
        var new = baseConfig()
        new.sets[0].schedule = .hourly(minute: 5)
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func sourcesChangeIsRelevant() {
        var new = baseConfig()
        new.sets[0].sources.append("/Users/someone/Documents")
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func excludesChangeIsRelevant() {
        var new = baseConfig()
        new.sets[0].excludes = []
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func destinationChangeIsRelevant() {
        var new = baseConfig()
        new.sets[0].destinations[0].repoURL = "/tmp/other"
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func addingADestinationIsRelevant() {
        var new = baseConfig()
        new.sets[0].destinations.append(
            Destination(id: secondaryId, label: "External", repoURL: "/Volumes/Backup/repo", isPrimary: false)
        )
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func retentionChangeIsRelevant() {
        var new = baseConfig()
        new.sets[0].retention = nil
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func checkPolicyChangeIsRelevant() {
        var new = baseConfig()
        new.sets[0].checkPolicy = CheckPolicy(enabled: false)
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func addingOrRemovingASetIsRelevant() {
        var added = baseConfig()
        var extra = baseSet()
        extra.id = UUID()
        extra.destinations[0].id = UUID()
        added.sets.append(extra)
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: added))

        var removed = baseConfig()
        removed.sets = []
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: removed))
    }

    @Test func resticPathChangeIsRelevant() {
        var new = baseConfig()
        new.resticPath = "/usr/local/bin/restic"
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    // MARK: T24 — per-machine overrides

    @Test func addingASetLevelMachineOverrideIsRelevant() {
        var new = baseConfig()
        new.sets[0].machines = ["linux-nas": BackupSetMachineOverride(sources: ["/srv/data"])]
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func changingASetLevelMachineOverrideIsRelevant() {
        var old = baseConfig()
        old.sets[0].machines = ["linux-nas": BackupSetMachineOverride(sources: ["/srv/data"])]
        var new = old
        new.sets[0].machines = ["linux-nas": BackupSetMachineOverride(sources: ["/srv/other"])]
        #expect(ConfigDiff.isScheduleRelevantChange(from: old, to: new))
    }

    @Test func disablingASetForAMachineIsRelevant() {
        var new = baseConfig()
        new.sets[0].machines = ["linux-nas": BackupSetMachineOverride(enabled: false)]
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func removingASetLevelMachineOverrideIsRelevant() {
        var old = baseConfig()
        old.sets[0].machines = ["linux-nas": BackupSetMachineOverride(enabled: false)]
        var new = old
        new.sets[0].machines = nil
        #expect(ConfigDiff.isScheduleRelevantChange(from: old, to: new))
    }

    @Test func destinationLevelMachineOverridesAreRelevant() {
        var new = baseConfig()
        new.sets[0].destinations[0].machines = ["linux-nas": DestinationMachineOverride(repoURL: "/mnt/big")]
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))

        var disabled = baseConfig()
        disabled.sets[0].destinations[0].machines = ["linux-nas": DestinationMachineOverride(enabled: false)]
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: disabled))
    }

    /// An empty map is not the same as no map: it is a shape change the
    /// summary must not swallow.
    @Test func anEmptyMachinesMapDiffersFromNoMap() {
        var new = baseConfig()
        new.sets[0].machines = [:]
        #expect(ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }
}

@Suite struct ConfigDiffIrrelevantTests {
    @Test func menuBarToggleIsNotRelevant() {
        var new = baseConfig()
        new.showMenuBarIcon = false
        #expect(!ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func renamingASetIsNotRelevant() {
        var new = baseConfig()
        new.sets[0].name = "Work Projects"
        #expect(!ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func stalenessWarningDaysIsNotRelevant() {
        var new = baseConfig()
        new.sets[0].stalenessWarningDays = 3
        #expect(!ConfigDiff.isScheduleRelevantChange(from: baseConfig(), to: new))
    }

    @Test func reorderingSetsIsNotRelevant() {
        var old = baseConfig()
        var second = baseSet()
        second.id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        second.name = "Photos"
        second.destinations[0].id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        old.sets.append(second)

        var reordered = old
        reordered.sets.reverse()
        #expect(!ConfigDiff.isScheduleRelevantChange(from: old, to: reordered))
    }
}
