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
        #expect(report.sets[0].onlineOnlyFiles == .skip)
    }

    @Test("the online-only files line appears only for a set with a cloud-synced source")
    func onlineOnlyFilesLineOnlyForCloudSources() throws {
        var config = fleetConfig()
        config.sets[0].machines = nil
        let plain = EffectiveConfigReport.build(
            addressable: config.addressable(for: "studio-mac"),
            scheduled: config.resolved(for: "studio-mac")
        )
        #expect(!plain.humanLines().contains { $0.contains("online-only files") })

        config.sets[0].sources = [
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/CloudStorage/Provider-Example/Documents"),
        ]
        config.sets[0].onlineOnlyFiles = .download
        let cloud = EffectiveConfigReport.build(
            addressable: config.addressable(for: "studio-mac"),
            scheduled: config.resolved(for: "studio-mac")
        )
        #expect(cloud.humanLines().contains("    online-only files: download"))
        #expect(cloud.sets[0].onlineOnlyFiles == .download)
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

// MARK: - Global exclusions

/// `config show`/`config validate` report the **fleet-wide** half of the
/// global exclusion list — whether a set applies it — and deliberately not
/// the host-local list itself (`docs/data-model.md` §global-excludes.json).
/// `excludes show` is the command for the list, and `GlobalExcludeReport`
/// below is its payload.
@Suite("Global exclusions in the effective plan")
struct EffectiveConfigReportGlobalExcludesTests {

    private let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-000000000001")!
    private let primaryId = UUID(uuidString: "0A1B2C3D-4E5F-4A1B-8C1D-000000000011")!

    private func config(usesGlobalExcludes: Bool) -> AppConfig {
        AppConfig(sets: [BackupSet(
            id: setId,
            name: "Build archive",
            sources: ["/srv/artifacts"],
            usesGlobalExcludes: usesGlobalExcludes,
            schedule: .daily(hour: 2, minute: 30),
            destinations: [
                Destination(id: primaryId, label: "NAS", repoURL: "/mnt/nas/archive.restic", isPrimary: true),
            ]
        )])
    }

    private func report(usesGlobalExcludes: Bool) -> EffectiveConfigReport {
        let config = config(usesGlobalExcludes: usesGlobalExcludes)
        return EffectiveConfigReport.build(
            addressable: config.addressable(for: "linux-nas"),
            scheduled: config.resolved(for: "linux-nas")
        )
    }

    @Test("usesGlobalExcludes is always in the --json payload, both ways round")
    func theFlagIsAlwaysEncoded() throws {
        for expected in [true, false] {
            let data = try ConfigStore.makeEncoder().encode(report(usesGlobalExcludes: expected))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let sets = object?["sets"] as? [[String: Any]] ?? []
            #expect(sets.count == 1)
            #expect(sets.first?["usesGlobalExcludes"] as? Bool == expected)
        }
    }

    /// The list applies everywhere by default, so saying so on every set
    /// would be noise — but saying nothing when a set has opted out would
    /// hide the one case where someone is surprised by what was backed up.
    @Test("human output names the opt-out, and stays silent when the list applies")
    func humanOutputOnlyMentionsTheOptOut() {
        let optedIn = report(usesGlobalExcludes: true).humanLines().joined(separator: "\n")
        #expect(!optedIn.contains("global excludes"))

        let optedOut = report(usesGlobalExcludes: false).humanLines().joined(separator: "\n")
        #expect(optedOut.contains("global excludes: opted out (usesGlobalExcludes: false)"))
    }
}

// MARK: - excludes show

@Suite("GlobalExcludeReport")
struct GlobalExcludeReportTests {

    private let path = URL(fileURLWithPath: "/data/global-excludes.json")

    @Test("with no settings file, the report is the built-in defaults and says so")
    func defaultsAreReportedAsSuch() {
        let report = GlobalExcludeReport.build(settings: .default, path: path, exists: false)

        #expect(!report.exists)
        #expect(report.enabled)
        #expect(report.excludeCaches)
        #expect(report.groups.count == GlobalExcludeCatalog.groups.count)
        #expect(report.patterns == GlobalExcludeSettings.default.plan.patterns)
        // Not "written against catalogue 0" — there is no file to have been
        // written against an older one.
        #expect(report.savedCatalogVersion == GlobalExcludeCatalog.version)

        let lines = report.humanLines(includePatterns: false).joined(separator: "\n")
        #expect(lines.contains("(not present — built-in defaults)"))
        #expect(!lines.contains("note: this build carries catalogue version"))
    }

    @Test("a group changed on this machine is marked, and its state is the one that applies")
    func aChangedGroupIsMarked() {
        var settings = GlobalExcludeSettings()
        settings.groups = ["browser-caches": false]
        let report = GlobalExcludeReport.build(settings: settings, path: path, exists: true)

        let browser = try? #require(report.groups.first { $0.id == "browser-caches" })
        #expect(browser?.enabled == false)
        #expect(browser?.enabledByDefault == true)
        #expect(!report.patterns.contains("Library/Caches/Google/Chrome"))

        let lines = report.humanLines(includePatterns: false).joined(separator: "\n")
        #expect(lines.contains("[ ] browser-caches"))
        #expect(lines.contains("(changed on this machine)"))
    }

    /// A build that added groups since the file was written must say so:
    /// those groups are already applying, and a surprise exclusion with no
    /// explanation is the failure this line exists to prevent.
    @Test("an older saved catalogue version is called out")
    func anOlderCatalogueVersionIsCalledOut() {
        var settings = GlobalExcludeSettings()
        settings.catalogVersion = 0
        let report = GlobalExcludeReport.build(settings: settings, path: path, exists: true)

        let lines = report.humanLines(includePatterns: false).joined(separator: "\n")
        #expect(lines.contains("note: this build carries catalogue version"))
    }

    @Test("--patterns prints every individual pattern")
    func patternsFlagPrintsThem() {
        let report = GlobalExcludeReport.build(settings: .default, path: path, exists: false)
        let terse = report.humanLines(includePatterns: false).joined(separator: "\n")
        let verbose = report.humanLines(includePatterns: true).joined(separator: "\n")

        #expect(!terse.contains("node_modules"))
        #expect(verbose.contains("node_modules"))
    }

    @Test("the master switch off reports no patterns at all")
    func masterSwitchOffReportsNothing() {
        var settings = GlobalExcludeSettings()
        settings.enabled = false
        let report = GlobalExcludeReport.build(settings: settings, path: path, exists: true)

        #expect(report.patterns.isEmpty)
        #expect(report.humanLines(includePatterns: false).first == "global exclusion list: off")
    }
}
