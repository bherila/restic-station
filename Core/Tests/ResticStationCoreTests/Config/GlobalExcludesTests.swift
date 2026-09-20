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
            for entry in group.patterns {
                let pattern = entry.pattern
                #expect(!pattern.isEmpty, "\(group.id): empty pattern")
                #expect(!pattern.hasPrefix("/"), "\(group.id): \"\(pattern)\" is anchored")
                #expect(!pattern.hasPrefix("~"), "\(group.id): \"\(pattern)\" relies on ~ expansion")
                #expect(!pattern.contains("$"), "\(group.id): \"\(pattern)\" relies on $VAR expansion")
                #expect(!pattern.hasSuffix("/"), "\(group.id): \"\(pattern)\" has a trailing separator")
                #expect(!entry.platforms.isEmpty, "\(group.id): \"\(pattern)\" applies nowhere")
            }
        }
    }

    /// The `/tmp` lesson, encoded.
    ///
    /// An unanchored pattern is matched against every component of the
    /// **absolute** path, not just the ones below the source — so
    /// `--exclude tmp` against a source under `/tmp/...` excludes the source
    /// itself and produces an empty snapshot (verified against restic
    /// 0.18.1 while this catalogue was written). A single-component pattern
    /// must therefore name something nobody has *above* their data.
    @Test func noSingleComponentPatternCanMatchAnAncestorDirectory() {
        // Names that routinely appear high in a path — a source under any
        // of them would vanish entirely.
        let dangerous: Set<String> = [
            "tmp", "temp", "var", "usr", "opt", "etc", "srv", "home", "users", "root",
            "data", "src", "lib", "bin", "obj", "sbin", "mnt", "media", "volumes",
            "target", "build", "dist", "out", "cache", "caches", "log", "logs",
            "documents", "desktop", "downloads", "library", "backup", "backups",
        ]
        for group in GlobalExcludeCatalog.groups {
            for pattern in group.patterns.map(\.pattern) where !pattern.contains("/") {
                #expect(
                    !dangerous.contains(pattern.lowercased()),
                    "\(group.id): \"\(pattern)\" can match a directory ABOVE the source"
                )
            }
        }
    }

    @Test func noPatternIsListedTwiceAcrossTheCatalogue() {
        var seen: [String: String] = [:]
        for group in GlobalExcludeCatalog.groups {
            for pattern in group.patterns.map(\.pattern) {
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
    @Test func theOffByDefaultGroupsAreTheOnesThatCanHoldAnOnlyCopy() {
        let off = GlobalExcludeCatalog.groups.filter { !$0.enabledByDefault }.map(\.id)
        #expect(off == ["virtual-machine-images", "installers-and-disk-images"])
    }

    /// A VM's disk images are skipped; the few kilobytes that describe the
    /// machine are not. Restoring the images without them is harder, not
    /// easier — Code42's equivalent list drops both.
    @Test func theVirtualMachineGroupKeepsTheMachineDefinitionFiles() {
        let vm = GlobalExcludeCatalog.group(id: "virtual-machine-images")!.patterns.map(\.pattern)
        #expect(vm.contains("*.vmdk"))
        #expect(!vm.contains("*.vmx"))
        #expect(!vm.contains("*.vmxf"))
    }

    /// Lockfiles are the files a rebuild depends on most, and `*.lock`
    /// eats every one of them. Stated as a test because the pattern is an
    /// obvious-looking addition someone will propose again.
    @Test func noPatternSwallowsLockfiles() {
        let lockfiles = ["Cargo.lock", "yarn.lock", "poetry.lock", "flake.lock", "package-lock.json"]
        for group in GlobalExcludeCatalog.groups {
            let patterns = group.patterns.map(\.pattern)
            #expect(!patterns.contains("*.lock"), "\(group.id) would exclude \(lockfiles)")
            #expect(!patterns.contains("*.db"))
            #expect(!patterns.contains("*.sqlite"))
        }
    }

    /// Photos' `originals/` and its `database/` must never be skipped: a
    /// library restored without the database is one the Photos app refuses
    /// to open.
    @Test func thePhotoGroupSkipsOnlyDerivedMedia() {
        let media = GlobalExcludeCatalog.group(id: "media-app-caches")!.patterns.map(\.pattern)
        for pattern in media {
            #expect(!pattern.contains("originals"))
            #expect(!pattern.contains("database"))
        }
        #expect(media.contains("*.photoslibrary/resources/derivatives"))
    }

    /// The scoping rule, stated as a test: a pattern is platform-scoped
    /// only when its *path shape* cannot exist on the other platform.
    /// Anything that is a file or directory **name** stays unscoped,
    /// because it turns up on either host — `.DS_Store` on a Samba share,
    /// `Thumbs.db` on an attached NTFS drive, `node_modules` anywhere.
    @Test func onlyHomeDirectoryLayoutIsPlatformScoped() {
        let both = Set(GlobalExcludePlatform.allCases)
        for group in GlobalExcludeCatalog.groups {
            for entry in group.patterns where entry.platforms != both {
                let isMacLayout = entry.pattern.hasPrefix("Library/")
                // The XDG base directories, which is the whole of what a
                // Linux-only path shape looks like here.
                let isLinuxLayout = entry.pattern.hasPrefix(".cache/")
                    || entry.pattern.hasPrefix(".config/")
                    || entry.pattern.hasPrefix(".local/")
                    || entry.pattern == ".cache"
                let isMacDotfile = entry.platforms == [.macOS]
                    && (entry.pattern.hasPrefix(".orbstack")
                        || entry.pattern == ".colima"
                        || entry.pattern == ".lima")
                let isMacBundleName = entry.platforms == [.macOS]
                    && ["DerivedData", "xcuserdata", "Pods"].contains(entry.pattern)
                #expect(
                    isMacLayout || isLinuxLayout || isMacDotfile || isMacBundleName,
                    "\(group.id): \"\(entry.pattern)\" is scoped but is not a home-directory layout"
                )
            }
        }
    }

    /// Neither platform resolves to an empty catalogue, and each one drops
    /// a meaningful share of the other's — the whole point of scoping.
    @Test func eachPlatformGetsItsOwnListAndNeitherIsEmpty() {
        let mac = GlobalExcludeSettings.default.plan(on: .macOS).patterns
        let linux = GlobalExcludeSettings.default.plan(on: .linux).patterns

        #expect(!mac.isEmpty)
        #expect(!linux.isEmpty)
        #expect(mac != linux)
        #expect(mac.contains("Library/Caches"))
        #expect(!linux.contains("Library/Caches"))
        #expect(linux.contains(".cache"))
        #expect(!mac.contains(".cache"))
        // The unscoped majority is on both.
        for shared in ["node_modules", ".DS_Store", "Thumbs.db", "*.tmp", "target/debug"] {
            #expect(mac.contains(shared), "\(shared) missing on macOS")
            #expect(linux.contains(shared), "\(shared) missing on Linux")
        }
    }

    /// The `*` form reaches the architecture-qualified build layouts
    /// (`bin/x64/Debug`, `target/<triple>/release`) that the two-component
    /// form alone misses — verified against real restic, where `*` matches
    /// exactly one component.
    @Test func buildOutputCoversBothTheFlatAndQualifiedLayouts() {
        let build = GlobalExcludeCatalog.group(id: "developer-build-artifacts")!
            .patterns.map(\.pattern)
        for pattern in ["bin/Debug", "bin/*/Debug", "obj/Release", "obj/*/Release",
                        "target/debug", "target/*/release"] {
            #expect(build.contains(pattern), "\(pattern) missing")
        }
        // Still never the bare names.
        for bare in ["bin", "obj", "target"] {
            #expect(!build.contains(bare))
        }
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
        let plan = GlobalExcludeSettings.default.plan(on: .macOS)
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
        #expect(settings.plan(on: .macOS).patterns.contains("*.vmdk"))
    }

    @Test func theMasterSwitchSuppressesEverythingWithoutLosingTheGroupDecisions() {
        var settings = GlobalExcludeSettings()
        settings.groups = ["virtual-machine-images": true]
        settings.enabled = false

        #expect(settings.plan(on: .macOS) == .none)
        // The decision underneath survives, so turning it back on restores it.
        settings.enabled = true
        #expect(settings.plan(on: .macOS).patterns.contains("*.vmdk"))
    }

    @Test func extraPatternsComeAfterTheCatalogueAndAreDeduped() {
        var settings = GlobalExcludeSettings()
        settings.extraPatterns = ["*.iso", "node_modules"]
        let plan = settings.plan(on: .macOS)
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
        #expect(object?.keys.contains("excludeLargerThan") == true)
        #expect(object?["excludeLargerThan"] is NSNull)
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

    @Test func aSizeCapIsOffUnlessAskedFor() {
        #expect(GlobalExcludeSettings.default.plan(on: .macOS).excludeLargerThan == nil)
        var settings = GlobalExcludeSettings()
        settings.excludeLargerThan = "10G"
        #expect(settings.plan(on: .macOS).excludeLargerThan == "10G")
    }

    @Test(arguments: ["500m", "10G", "1", "42k", "7T"])
    func aWellFormedSizeIsAccepted(size: String) throws {
        var settings = GlobalExcludeSettings()
        settings.excludeLargerThan = size
        try settings.validate()
    }

    /// A typo fails when it is saved, not silently at 3 a.m. when the
    /// backup refuses to start.
    @Test(arguments: ["", "10GB", "big", "10 G", "G", "-5m", "1.5G"])
    func aMalformedSizeIsRefused(size: String) {
        var settings = GlobalExcludeSettings()
        settings.excludeLargerThan = size
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

    private let plan = GlobalExcludePlan(
        patterns: ["node_modules", ".cache"],
        excludeCaches: true,
        excludeLargerThan: "10G"
    )

    @Test func theSetsOwnListAndTheGlobalListStaySeparate() {
        let set = makeSet(excludes: ["*.log"], purgeExcludes: ["secrets/"])
        #expect(set.effectiveBackupExcludes == ["*.log", "secrets/"])
        #expect(set.globalBackupExcludes(applying: plan) == ["node_modules", ".cache"])
        #expect(set.excludesCaches(applying: plan))
        #expect(set.excludeLargerThan(applying: plan) == "10G")
    }

    /// Dropped, not duplicated — and case-insensitively, because the global
    /// half reaches restic as `--iexclude`.
    @Test func aPatternTheSetAlreadyNamesIsNotRepeatedInTheGlobalBlock() {
        #expect(makeSet(excludes: ["node_modules"]).globalBackupExcludes(applying: plan) == [".cache"])
        #expect(makeSet(excludes: ["NODE_MODULES"]).globalBackupExcludes(applying: plan) == [".cache"])
    }

    @Test func anOptedOutSetGetsNothingFromTheGlobalList() {
        let set = makeSet(excludes: ["*.log"], usesGlobalExcludes: false)
        #expect(set.effectiveBackupExcludes == ["*.log"])
        #expect(set.globalBackupExcludes(applying: plan).isEmpty)
        #expect(!set.excludesCaches(applying: plan))
        #expect(set.excludeLargerThan(applying: plan) == nil)
    }

    @Test func anEmptyPlanLeavesTheArgvExactlyAsItWasBeforeTheFeature() {
        let set = makeSet(excludes: ["*.log"], purgeExcludes: ["secrets/"])
        #expect(set.globalBackupExcludes(applying: .none).isEmpty)
        #expect(!set.excludesCaches(applying: .none))
        #expect(set.excludeLargerThan(applying: .none) == nil)
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
