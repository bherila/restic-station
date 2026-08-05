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

// MARK: - Summary (config import, T27)

@Suite struct ConfigDiffSummaryTests {
    @Test func identicalConfigsProduceAnEmptySummary() {
        let summary = ConfigDiff.summarize(from: baseConfig(), to: baseConfig())
        #expect(summary.isEmpty)
        #expect(summary.lines.isEmpty)
    }

    @Test func addedAndRemovedSetsAreReported() {
        var new = baseConfig()
        var extra = baseSet()
        extra.id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        extra.name = "Photos"
        extra.destinations[0].id = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        new.sets.append(extra)

        let addedSummary = ConfigDiff.summarize(from: baseConfig(), to: new)
        #expect(addedSummary.added.map(\.name) == ["Photos"])
        #expect(addedSummary.removed.isEmpty)
        #expect(addedSummary.lines.contains { $0.contains("added set \"Photos\"") })

        let removedSummary = ConfigDiff.summarize(from: new, to: baseConfig())
        #expect(removedSummary.removed.map(\.name) == ["Photos"])
        #expect(removedSummary.lines.contains { $0.contains("removed set \"Photos\"") })
    }

    @Test func aChangedSetNamesEveryDifferingField() {
        var new = baseConfig()
        new.sets[0].schedule = .hourly(minute: 5)
        new.sets[0].sources.append("/Users/someone/Documents")

        let summary = ConfigDiff.summarize(from: baseConfig(), to: new)
        #expect(summary.changed.count == 1)
        #expect(summary.changed[0].id == setId)
        #expect(Set(summary.changed[0].changedFields) == ["schedule", "sources"])
    }

    /// Unlike `isScheduleRelevantChange`, a bare rename IS reported here —
    /// this summary is for a human deciding whether an import looks right,
    /// not for the scheduler.
    @Test func aRenameIsReportedAsChanged() {
        var new = baseConfig()
        new.sets[0].name = "Work Projects"
        let summary = ConfigDiff.summarize(from: baseConfig(), to: new)
        #expect(summary.changed.map(\.changedFields) == [["name"]])
    }

    @Test func resticPathChangeIsReportedSeparatelyFromSets() {
        var new = baseConfig()
        new.resticPath = "/usr/local/bin/restic"
        let summary = ConfigDiff.summarize(from: baseConfig(), to: new)
        #expect(summary.resticPathChanged)
        #expect(summary.changed.isEmpty)
        #expect(summary.lines == ["~ resticPath changed"])
    }

    /// `config import`'s `old` is whatever is currently on disk, read
    /// *without* `AppConfig.validate()` (`ConfigImport.loadExistingForDiff`)
    /// — exactly so a broken `config.json` can still be diffed and
    /// replaced. A config with duplicate set ids decodes fine and is
    /// exactly the broken state `config import` exists to recover from;
    /// `Dictionary(uniqueKeysWithValues:)` traps the whole process on a
    /// duplicate key, which would make `summarize` — and therefore `config
    /// import` — unusable against that input. This must not crash.
    @Test func duplicateSetIdsInTheExistingConfigDoNotCrashTheDiff() {
        var duplicated = baseConfig()
        var secondCopy = baseSet()
        secondCopy.name = "Projects (duplicate)"
        duplicated.sets.append(secondCopy) // same id as baseSet(), on purpose

        // Must not trap — `Dictionary(uniqueKeysWithValues:)`'s crash on a
        // duplicate key is the historical bug. `old` and `new` both carry
        // the duplicate, so both dictionary constructions are exercised.
        // The result is well-defined, not incidental: `oldByID`'s
        // last-wins pick is `secondCopy`, so the array's *first* entry
        // (matched against that pick while iterating `new.sets`, which
        // still holds both raw entries) differs by name and is reported
        // changed; the second entry, which IS the last-wins pick, compares
        // equal to itself.
        let summary = ConfigDiff.summarize(from: duplicated, to: duplicated)
        #expect(summary.changed.count == 1)
        #expect(summary.changed[0].changedFields == ["name"])
    }

    /// Last-wins is the documented tie-break: a set matched by id against a
    /// duplicated `old` diffs against the *last* occurrence in `old.sets`.
    @Test func duplicateSetIdsResolveLastWinsForTheDiff() {
        var old = baseConfig()
        var firstCopy = baseSet()
        firstCopy.sources = ["/first"]
        var secondCopy = baseSet()
        secondCopy.sources = ["/second"]
        old.sets = [firstCopy, secondCopy] // same id, both entries

        var new = baseConfig()
        new.sets[0].sources = ["/second"] // matches the LAST copy in old, not the first

        let summary = ConfigDiff.summarize(from: old, to: new)
        // If the diff had matched the first (not last) occurrence, sources
        // would differ ("/first" -> "/second") and this set would be
        // reported changed.
        #expect(summary.changed.isEmpty)
    }

    @Test func machineOverrideChangesAreReportedOnTheSet() {
        var new = baseConfig()
        new.sets[0].machines = ["linux-nas": BackupSetMachineOverride(enabled: false)]
        let summary = ConfigDiff.summarize(from: baseConfig(), to: new)
        #expect(summary.changed.map(\.changedFields) == [["machines"]])
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
