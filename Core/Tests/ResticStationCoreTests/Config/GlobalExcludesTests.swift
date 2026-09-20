import Foundation
import Testing
@testable import ResticStationCore

/// The built-in catalogue's shape rules (`docs/data-model.md`
/// §global-excludes.json — Pattern shape).
///
/// These are the rules that make one list correct on both platforms and
/// safe to apply to every source. They are asserted rather than reviewed by
/// eye because the catalogue is edited often and a single anchored or
/// home-relative pattern silently matches nothing.
@Suite struct GlobalExcludeCatalogTests {

    @Test func everyGroupIdIsAUniqueSlug() {
        var seen = Set<String>()
        for group in GlobalExcludeCatalog.groups {
            #expect(!group.id.isEmpty)
            #expect(
                group.id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") },
                "group id \"\(group.id)\" must be a lowercase [a-z0-9-] slug — it is a key in global-excludes.json"
            )
            #expect(seen.insert(group.id).inserted, "duplicate group id \"\(group.id)\"")
            #expect(!group.title.isEmpty)
            #expect(!group.summary.isEmpty, "\"\(group.id)\" needs a sentence a person can decide about")
            #expect(!group.patterns.isEmpty)
        }
    }

    /// Relative, unanchored, no expansion. A leading `/` would anchor the
    /// pattern to a root nobody can predict; `~` and `$VAR` are shell
    /// syntax restic does not expand in an `--exclude` argument, so either
    /// would be matched literally and skip nothing at all — the silent
    /// no-op this rule exists to prevent.
    @Test func everyBuiltInPatternIsRelativeAndUnanchored() {
        for group in GlobalExcludeCatalog.groups {
            for pattern in group.patterns {
                #expect(!pattern.isEmpty, "\(group.id): empty pattern")
                #expect(!pattern.hasPrefix("/"), "\(group.id): \"\(pattern)\" is anchored")
                #expect(!pattern.hasPrefix("~"), "\(group.id): \"\(pattern)\" relies on ~ expansion")
                #expect(!pattern.contains("$"), "\(group.id): \"\(pattern)\" relies on $VAR expansion")
                #expect(!pattern.hasSuffix("/"), "\(group.id): \"\(pattern)\" has a trailing separator")
            }
        }
    }

    @Test func noPatternIsListedTwiceAcrossTheCatalogue() {
        var seen: [String: String] = [:]
        for group in GlobalExcludeCatalog.groups {
            for pattern in group.patterns {
                if let owner = seen[pattern] {
                    Issue.record("\"\(pattern)\" appears in both \(owner) and \(group.id)")
                }
                seen[pattern] = group.id
            }
        }
    }

    /// The one group that is off by default, and the reason it is: a VM
    /// image can be the only copy of something. A change here is a change
    /// to what an upgrade silently stops backing up, so it must be
    /// deliberate enough to edit a test for.
    @Test func onlyVirtualMachineImagesIsOffByDefault() {
        let off = GlobalExcludeCatalog.groups.filter { !$0.enabledByDefault }.map(\.id)
        #expect(off == ["virtual-machine-images"])
    }

    @Test func groupLookupFindsEveryAdvertisedId() {
        for id in GlobalExcludeCatalog.groupIDs {
            #expect(GlobalExcludeCatalog.group(id: id)?.id == id)
        }
        #expect(GlobalExcludeCatalog.group(id: "no-such-group") == nil)
    }
}

// MARK: - Settings

@Suite struct GlobalExcludeSettingsTests {

    @Test func theDefaultAppliesEveryDefaultOnGroupAndNothingElse() {
        let plan = GlobalExcludeSettings.default.plan
        #expect(plan.excludeCaches)
        #expect(plan.patterns.contains("node_modules"))
        #expect(plan.patterns.contains("Library/Caches"))
        // The off-by-default group contributes nothing until asked for.
        #expect(!plan.patterns.contains("*.vmdk"))
    }

    @Test func aGroupTheFileSaysNothingAboutTakesItsBuiltInDefault() {
        var settings = GlobalExcludeSettings()
        settings.groups = ["temporary-files": false]
        #expect(!settings.isEnabled(GlobalExcludeCatalog.group(id: "temporary-files")!))
        #expect(settings.isEnabled(GlobalExcludeCatalog.group(id: "browser-caches")!))
        #expect(!settings.isEnabled(GlobalExcludeCatalog.group(id: "virtual-machine-images")!))
    }

    @Test func anExplicitTrueTurnsOnAGroupThatIsOffByDefault() {
        var settings = GlobalExcludeSettings()
        settings.groups = ["virtual-machine-images": true]
        #expect(settings.plan.patterns.contains("*.vmdk"))
    }

    @Test func theMasterSwitchSuppressesEverythingWithoutLosingTheGroupDecisions() {
        var settings = GlobalExcludeSettings()
        settings.groups = ["virtual-machine-images": true]
        settings.enabled = false

        #expect(settings.plan == .none)
        // The decision underneath survives, so turning it back on restores it.
        settings.enabled = true
        #expect(settings.plan.patterns.contains("*.vmdk"))
    }

    @Test func extraPatternsComeAfterTheCatalogueAndAreDeduped() {
        var settings = GlobalExcludeSettings()
        settings.extraPatterns = ["*.iso", "node_modules"]
        let plan = settings.plan
        #expect(plan.patterns.last == "*.iso")
        #expect(plan.patterns.filter { $0 == "node_modules" }.count == 1)
    }

    @Test func everyKeyIsEncodedExplicitly() throws {
        let data = try ConfigStore.makeEncoder().encode(GlobalExcludeSettings.default)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["version"] as? Int == GlobalExcludeSettings.currentVersion)
        #expect(object?["catalogVersion"] as? Int == GlobalExcludeCatalog.version)
        #expect(object?["enabled"] as? Bool == true)
        #expect(object?["excludeCaches"] as? Bool == true)
        #expect(object?["groups"] as? [String: Bool] == [:])
        #expect(object?["extraPatterns"] as? [String] == [])
    }

    @Test func aFileWithOnlyAVersionDecodesToTheDefaults() throws {
        let json = #"{"version":1}"#
        let settings = try ConfigStore.makeDecoder()
            .decode(GlobalExcludeSettings.self, from: Data(json.utf8))
        #expect(settings.enabled)
        #expect(settings.excludeCaches)
        #expect(settings.groups.isEmpty)
        #expect(settings.extraPatterns.isEmpty)
    }

    @Test func aNewerVersionIsRefused() {
        var settings = GlobalExcludeSettings()
        settings.version = GlobalExcludeSettings.currentVersion + 1
        #expect(throws: GlobalExcludeError.self) { try settings.validate() }
    }

    /// "Disable this group" is a request to back up **more**, so a typo that
    /// is quietly ignored leaves a person believing a directory is protected
    /// while every run keeps skipping it.
    @Test func anUnknownGroupIdIsRefusedRatherThanIgnored() {
        var settings = GlobalExcludeSettings()
        settings.groups = ["browser-cache": false] // singular — a real typo
        #expect(throws: GlobalExcludeError.self) { try settings.validate() }
    }

    @Test func aBlankExtraPatternIsRefused() {
        var settings = GlobalExcludeSettings()
        settings.extraPatterns = ["*.iso", ""]
        #expect(throws: GlobalExcludeError.self) { try settings.validate() }
    }
}

// MARK: - Store

@Suite struct GlobalExcludeStoreTests {

    private func withPaths(_ body: (AppPaths) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-excludes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AppPaths(root: root))
    }

    @Test func anAbsentFileIsTheDocumentedDefaultAndIsNotCreated() throws {
        try withPaths { paths in
            let store = GlobalExcludeStore(paths: paths)
            let loaded = try store.load()
            #expect(loaded == .default)
            #expect(!FileManager.default.fileExists(atPath: paths.globalExcludesFile.path))
        }
    }

    @Test func saveRoundTripsAndStampsTheCatalogueVersion() throws {
        try withPaths { paths in
            let store = GlobalExcludeStore(paths: paths)
            var settings = GlobalExcludeSettings(catalogVersion: 0)
            settings.groups = ["container-engines": false]
            settings.extraPatterns = ["*.iso"]
            try store.save(settings)

            let loaded = try store.load()
            #expect(loaded.groups == ["container-engines": false])
            #expect(loaded.extraPatterns == ["*.iso"])
            #expect(loaded.version == GlobalExcludeSettings.currentVersion)
            #expect(loaded.catalogVersion == GlobalExcludeCatalog.version)
        }
    }

    /// Fail closed. Falling back to the built-in defaults would apply *more*
    /// exclusions than a host that had turned groups off, so every run
    /// afterwards would silently skip directories someone deliberately kept.
    @Test func anUnreadableFileRefusesInsteadOfFallingBackToTheDefaults() throws {
        try withPaths { paths in
            try paths.ensureDirectories()
            try Data("{ this is not json".utf8).write(to: paths.globalExcludesFile)
            #expect(throws: GlobalExcludeError.self) {
                try GlobalExcludeStore(paths: paths).load()
            }
        }
    }

    @Test func aFileNamingAnUnknownGroupRefusesOnLoad() throws {
        try withPaths { paths in
            try paths.ensureDirectories()
            let json = #"{"version":1,"groups":{"browser-cache":false}}"#
            try Data(json.utf8).write(to: paths.globalExcludesFile)
            #expect(throws: GlobalExcludeError.self) {
                try GlobalExcludeStore(paths: paths).load()
            }
        }
    }

    @Test func savingAnInvalidSettingsValueWritesNothing() throws {
        try withPaths { paths in
            let store = GlobalExcludeStore(paths: paths)
            var settings = GlobalExcludeSettings()
            settings.extraPatterns = [""]
            #expect(throws: GlobalExcludeError.self) { try store.save(settings) }
            #expect(!FileManager.default.fileExists(atPath: paths.globalExcludesFile.path))
        }
    }
}

// MARK: - BackupSet interaction

@Suite struct BackupSetGlobalExcludeTests {

    private func makeSet(
        excludes: [String] = [],
        purgeExcludes: [String] = [],
        usesGlobalExcludes: Bool = true
    ) -> BackupSet {
        BackupSet(
            id: UUID(),
            name: "Projects",
            sources: ["/Users/user/proj"],
            excludes: excludes,
            purgeExcludes: purgeExcludes,
            usesGlobalExcludes: usesGlobalExcludes,
            schedule: .daily(hour: 2, minute: 30),
            destinations: [
                Destination(id: UUID(), label: "Primary", repoURL: "/repo", isPrimary: true),
            ]
        )
    }

    private let plan = GlobalExcludePlan(patterns: ["node_modules", ".cache"], excludeCaches: true)

    @Test func theSetsOwnPatternsComeFirstAndTheGlobalBlockIsAppended() {
        let set = makeSet(excludes: ["*.log"], purgeExcludes: ["secrets/"])
        #expect(set.backupExcludes(applying: plan) == ["*.log", "secrets/", "node_modules", ".cache"])
        #expect(set.excludesCaches(applying: plan))
    }

    @Test func aPatternTheSetAlreadyNamesIsNotRepeated() {
        let set = makeSet(excludes: ["node_modules"])
        #expect(set.backupExcludes(applying: plan) == ["node_modules", ".cache"])
    }

    @Test func anOptedOutSetGetsNeitherThePatternsNorExcludeCaches() {
        let set = makeSet(excludes: ["*.log"], usesGlobalExcludes: false)
        #expect(set.backupExcludes(applying: plan) == ["*.log"])
        #expect(!set.excludesCaches(applying: plan))
    }

    @Test func anEmptyPlanLeavesTheArgvExactlyAsItWasBeforeTheFeature() {
        let set = makeSet(excludes: ["*.log"], purgeExcludes: ["secrets/"])
        #expect(set.backupExcludes(applying: .none) == set.effectiveBackupExcludes)
        #expect(!set.excludesCaches(applying: .none))
    }

    /// The v5 decode contract, matching `purgeExcludes` and
    /// `onlineOnlyFiles`: absent and explicit `null` both read as the
    /// default, and the key is always written back.
    @Test func absentAndNullBothDecodeAsOptedIn() throws {
        let decoder = ConfigStore.makeDecoder()
        func json(_ field: String) -> String {
            """
            {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"S","sources":["/a"],\
            "excludes":[],"purgeExcludes":[]\(field),"schedule":{"kind":"hourly","minute":0},\
            "stalenessWarningDays":14,"destinations":[]}
            """
        }
        let absent = try decoder.decode(BackupSet.self, from: Data(json("").utf8))
        let explicitNull = try decoder.decode(
            BackupSet.self, from: Data(json(#","usesGlobalExcludes":null"#).utf8)
        )
        let optedOut = try decoder.decode(
            BackupSet.self, from: Data(json(#","usesGlobalExcludes":false"#).utf8)
        )
        #expect(absent.usesGlobalExcludes)
        #expect(explicitNull.usesGlobalExcludes)
        #expect(!optedOut.usesGlobalExcludes)

        let set = absent
        let object = try JSONSerialization.jsonObject(
            with: try ConfigStore.makeEncoder().encode(set)
        ) as? [String: Any]
        #expect(object?["usesGlobalExcludes"] as? Bool == true)
    }
}
