import Foundation
import Testing

import ResticStationCore
@testable import restic_station_helper

/// `EffectiveConfigReport` is the single place `config validate`'s
/// "effective plan" section and `config show` both get their "what runs
/// here, and what's excluded and why" data from — see its doc comment for
/// why sharing this matters (T27, issue #29).
///
/// These tests build it directly from `AppConfig.resolved(for:)`/
/// `addressable(for:)`, the same way `Config.swift`'s subcommands do, rather
/// than shelling out — the end-to-end CLI behavior (stdout content, exit
/// codes, `--json | jq`) is `scripts/headless-cli-test.sh`.
@Suite("EffectiveConfigReport")
struct EffectiveConfigReportTests {

    private let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let primaryId = UUID(uuidString: "0A1B2C3D-4E5F-4A1B-8C1D-000000000001")!
    private let mirrorId = UUID(uuidString: "1B2C3D4E-5F60-4A1B-8C1D-000000000002")!

    /// The milestone's headline shape: a set disabled on `mirror-box`, one
    /// destination also individually disabled there.
    private func fleetConfig() -> AppConfig {
        AppConfig(sets: [BackupSet(
            id: setId,
            name: "Documents",
            sources: ["/Users/bwh/Documents"],
            excludes: [".DS_Store"],
            purgeExcludes: ["node_modules"],
            schedule: .daily(hour: 2, minute: 30),
            destinations: [
                Destination(id: primaryId, label: "Big Drive", repoURL: "/Volumes/Big/docs.restic", isPrimary: true),
                Destination(
                    id: mirrorId, label: "Scratch HDD", repoURL: "/Volumes/Scratch/docs", isPrimary: false,
                    machines: ["mirror-box": DestinationMachineOverride(enabled: false)]
                ),
            ],
            machines: ["mirror-box": BackupSetMachineOverride(enabled: false)]
        )])
    }

    @Test("a machine with no overrides: everything enabled, nothing excluded")
    func plainMachineSeesEverythingEnabled() {
        let config = fleetConfig()
        let report = EffectiveConfigReport.build(
            addressable: config.addressable(for: "studio-mac"),
            scheduled: config.resolved(for: "studio-mac")
        )

        #expect(report.sets.count == 1)
        #expect(report.sets[0].enabledHere)
        // Explicit closure, not `\.enabledHere` — a bare key path here trips
        // a Swift Testing macro-expansion/rethrows ambiguity on this
        // toolchain (the same family of issue this task's instructions flag
        // for `map(\.configuration.commandName)`).
        #expect(report.sets[0].destinations.allSatisfy { $0.enabledHere })
        #expect(report.excludedHere.isEmpty)
        #expect(report.sets[0].excludes == [".DS_Store"])
        #expect(report.sets[0].purgeExcludes == ["node_modules"])
    }

    /// The headline case: a set disabled on `mirror-box` still appears in
    /// the report (from the addressable view), marked excluded, with a
    /// reason — never silently dropped.
    @Test("a machine that disables the set: still listed, marked excluded, with a reason")
    func disabledMachineSeesTheSetMarkedExcluded() throws {
        let config = fleetConfig()
        let report = EffectiveConfigReport.build(
            addressable: config.addressable(for: "mirror-box"),
            scheduled: config.resolved(for: "mirror-box")
        )

        #expect(report.sets.count == 1)
        #expect(!report.sets[0].enabledHere)
        // Every destination is also reported not-enabled-here, since the
        // whole set does not run.
        #expect(report.sets[0].destinations.allSatisfy { !$0.enabledHere })
        // Addressable data survives regardless — this is what `restore`/
        // `probe-repo` still use.
        #expect(report.sets[0].destinations.map(\.repoURL).sorted() == [
            "/Volumes/Big/docs.restic", "/Volumes/Scratch/docs",
        ])

        #expect(report.excludedHere.count == 1)
        let exclusion = try #require(report.excludedHere.first)
        #expect(exclusion.subject == "backupSet")
        #expect(exclusion.id == setId)
        #expect(exclusion.setId == setId)
        #expect(exclusion.reason == "disabledForMachine")
        #expect(exclusion.description.contains("disabled on this machine"))
    }

    /// A set that runs, but with one destination individually disabled:
    /// the set is `enabledHere`, and only that one destination is not.
    @Test("an individually-disabled destination is excluded without excluding its set")
    func perDestinationDisableDoesNotExcludeTheSet() {
        var config = fleetConfig()
        // This machine keeps the set but drops just the mirror.
        config.sets[0].machines = nil
        config.sets[0].destinations[1].machines = ["laptop": DestinationMachineOverride(enabled: false)]

        let report = EffectiveConfigReport.build(
            addressable: config.addressable(for: "laptop"),
            scheduled: config.resolved(for: "laptop")
        )

        #expect(report.sets[0].enabledHere)
        let primary = report.sets[0].destinations.first { $0.id == primaryId }
        let mirror = report.sets[0].destinations.first { $0.id == mirrorId }
        #expect(primary?.enabledHere == true)
        #expect(mirror?.enabledHere == false)

        #expect(report.excludedHere.count == 1)
        #expect(report.excludedHere[0].subject == "destination")
        #expect(report.excludedHere[0].setId == setId)
        #expect(report.excludedHere[0].id == mirrorId)
    }

    @Test("humanLines names every set and marks RUNS HERE vs excluded, plus the excluded-here section")
    func humanLinesRenderBothStates() {
        let config = fleetConfig()
        let report = EffectiveConfigReport.build(
            addressable: config.addressable(for: "mirror-box"),
            scheduled: config.resolved(for: "mirror-box")
        )
        let lines = report.humanLines().joined(separator: "\n")
        #expect(lines.contains("\"Documents\""))
        #expect(lines.contains("does not run here"))
        #expect(lines.contains("excludes: .DS_Store"))
        #expect(lines.contains("purge excludes: node_modules"))
        #expect(lines.contains("excluded here, and why"))
        #expect(lines.contains("disabled on this machine"))
    }

    @Test("describe(_:) renders every Schedule case")
    func describeSchedule() {
        #expect(EffectiveConfigReport.describe(.everyMinutes(30)) == "every 30 minutes")
        #expect(EffectiveConfigReport.describe(.hourly(minute: 5)) == "hourly at :05")
        #expect(EffectiveConfigReport.describe(.daily(hour: 2, minute: 30)) == "daily 02:30")
        #expect(EffectiveConfigReport.describe(.weekly(weekday: 1, hour: 3, minute: 0)) == "weekly Sun 03:00")
    }

    // MARK: - JSON: explicit null, not omitted (house convention)

    @Test("--json encodes absent optionals as explicit null, never omits the key")
    func jsonEncodesExplicitNulls() throws {
        let config = fleetConfig()
        let report = EffectiveConfigReport.build(
            addressable: config.addressable(for: "studio-mac"),
            scheduled: config.resolved(for: "studio-mac")
        )
        let data = try ConfigStore.makeEncoder().encode(report)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"resticPath\" : null"))
        #expect(text.contains("\"retention\" : null"))
        #expect(text.contains("\"checkPolicy\" : null"))
        #expect(text.contains("\"purgeExcludes\" : [\n        \"node_modules\"\n      ]"))
    }
}
