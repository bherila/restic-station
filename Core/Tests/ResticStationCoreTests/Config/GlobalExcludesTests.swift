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

    /// No pattern names a directory that is a *project's* scratch under one
    /// reading and a *user home* full of authored configuration under
    /// another.
    ///
    /// `.gradle` was both: a project build directory, and the Gradle user
    /// home whose `gradle.properties` and `init.d/` hold repository
    /// credentials, signing settings and init scripts someone wrote. A bare
    /// rule excluded the second while meaning the first, and no build
    /// recreates what it took.
    ///
    /// The two near-misses left in deliberately are `.expo` and
    /// `.wrangler`: their user-home forms hold a session token that a
    /// re-login reissues, not authored content, so excluding them loses
    /// nothing a person wrote. `.gradle` is the one where that was untrue.
    @Test func noBarePatternNamesADirectoryThatIsAlsoAUserHome() {
        let bare = GlobalExcludeCatalog.groups
            .flatMap(\.patterns)
            .map(\.pattern)
            .filter { !$0.contains("/") }
        // Each of these has an authored file or directory *inside* the
        // user-home form — `.gradle/gradle.properties`, `.m2/settings.xml`,
        // `.cargo/config.toml` and `.cargo/bin`, `.docker/config.json` —
        // so the catalogue names the regenerable subdirectories instead.
        // `.npm` is deliberately absent from this list: it is purely a
        // cache, and npm's authored config is `.npmrc`, a different name.
        for name in [".gradle", ".m2", ".cargo", ".docker", ".config", ".local", ".ssh"] {
            #expect(!bare.contains(name), "\(name) is a user home as well as a project directory")
        }
    }

    /// The catalogue never names a directory whose contents can be a user's
    /// only copy of something, in a group that is on by default.
    ///
    /// Each of these was a real finding, and each was the same shape: a
    /// name that reads as "generated" until you ask who created what is
    /// inside it. `lost+found` holds files `fsck` recovered from a damaged
    /// filesystem — frequently the only surviving copy, and excluded
    /// exactly when it matters most. `xcuserdata` holds a developer's
    /// unshared schemes and breakpoints, which no build reproduces; only
    /// the window-state blob inside it is generated.
    @Test func noDefaultOnGroupNamesADirectoryOfIrreplaceableContent() {
        let defaultOn = GlobalExcludeCatalog.groups
            .filter(\.enabledByDefault)
            .flatMap(\.patterns)
            .map(\.pattern)
        for name in ["lost+found", "xcuserdata", ".git", "Documents", "Desktop"] {
            #expect(!defaultOn.contains(name), "\(name) can hold content nobody can regenerate")
        }
        // The narrowed replacement is still there and still generated.
        #expect(defaultOn.contains("UserInterfaceState.xcuserstate"))
    }

    /// Exactly one pattern is a *cloud placeholder*, and it is the one a
    /// sync client leaves behind for a file it has evicted.
    ///
    /// Pinned as a set rather than checked loosely because the flag changes
    /// who gets the pattern: a set with `onlineOnlyFiles: "download"` does
    /// not. Marking an ordinary pattern by accident would quietly stop
    /// excluding it for those sets; forgetting to mark a new placeholder
    /// pattern would quietly excluded it from them.
    @Test func exactlyTheCloudPlaceholderStubsAreMarkedAsSuch() {
        let marked = GlobalExcludeCatalog.groups
            .flatMap(\.patterns)
            .filter(\.isCloudPlaceholder)
            .map(\.pattern)
        #expect(marked == ["*.icloud"])
    }

    /// The groups that are off by default, and the one reason they are: each
    /// can hold the only copy of something. A VM image and a
    /// no-longer-downloadable installer; a container engine's data root,
    /// which holds named volumes and writable container state as well as
    /// images, so no registry has a copy of the database in a volume; and a
    /// game installation root, where plenty of titles keep saves,
    /// configuration and manually installed mods beside the executable — a
    /// re-download brings the game back without them. A change here is a
    /// change to what an upgrade silently stops backing up, so it must be
    /// deliberate enough to edit a test for.
    @Test func theOffByDefaultGroupsAreTheOnesThatCanHoldAnOnlyCopy() {
        let off = GlobalExcludeCatalog.groups.filter { !$0.enabledByDefault }.map(\.id)
        #expect(
            off == [
                "container-engines", "game-and-media-libraries",
                "virtual-machine-images", "installers-and-disk-images",
            ]
        )
    }

    /// The split that keeps the on-by-default half honest: a launcher's
    /// download staging and a transcoder cache are regenerable and stay on,
    /// while the stores they sit beside — game installation roots, and
    /// Plex's metadata and media — are the opt-in group. Either can hold
    /// something that exists nowhere else: a hand-installed mod, or a poster
    /// uploaded through Plex rather than filed beside the media. One of
    /// those patterns drifting back into the caches group would silently
    /// stop backing it up on every host that upgrades.
    @Test func theCachesGroupNamesNoStoreThatCanHoldAnOnlyCopy() throws {
        let caches = try #require(GlobalExcludeCatalog.group(id: "game-and-media-caches"))
        let libraries = try #require(GlobalExcludeCatalog.group(id: "game-and-media-libraries"))
        #expect(caches.enabledByDefault)
        #expect(!libraries.enabledByDefault)

        let cachePatterns = caches.patterns.map(\.pattern)
        for store in libraries.patterns.map(\.pattern) {
            #expect(!cachePatterns.contains(store))
        }
        // Named explicitly, so the assertion survives a rewrite of either
        // group's contents.
        for store in ["Steam/steamapps/common", "Plex Media Server/Metadata", "Plex Media Server/Media"] {
            #expect(!cachePatterns.contains(store))
            #expect(libraries.patterns.map(\.pattern).contains(store))
        }
        // The one Plex path that really is a cache stays on by default.
        #expect(cachePatterns.contains("Plex Media Server/Cache"))
    }

    /// A host pattern is deduplicated against the other host patterns and
    /// **not** against the catalogue.
    ///
    /// Sharing one `seen` set dropped `excludes add '*.icloud'` because the
    /// catalogue already carried that text — and on a set using
    /// `onlineOnlyFiles: "download"`, where the catalogue's copy is held
    /// back on purpose, that left nothing reaching restic at all.
    @Test func aHostPatternIsNeverDroppedBecauseTheCatalogueSharesItsText() {
        var settings = GlobalExcludeSettings()
        settings.extraPatterns = ["*.icloud", "/srv/scratch", "/srv/scratch"]
        let plan = settings.plan(on: .macOS)

        #expect(plan.hostPatterns == ["*.icloud", "/srv/scratch"])
        #expect(plan.cloudPlaceholderPatterns == ["*.icloud"])

        // The case that made it matter: the catalogue's copy is held back
        // for a downloading set, and the host's copy still gets through.
        let set = BackupSet(
            id: UUID(), name: "Docs", sources: ["/Users/user/Documents"],
            onlineOnlyFiles: .download,
            schedule: .daily(hour: 2, minute: 30),
            destinations: [Destination(id: UUID(), label: "P", repoURL: "/repo", isPrimary: true)]
        )
        #expect(!set.globalBackupExcludes(applying: plan).contains("*.icloud"))
        #expect(set.hostBackupExcludes(applying: plan).contains("*.icloud"))
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

    /// Host-added patterns keep their own list, because provenance decides
    /// the matching rule: the catalogue rides case-insensitive `--iexclude`,
    /// while `excludes add` documents its patterns as ordinary
    /// case-sensitive `--exclude`. Folding `*.TMP` into the catalogue block
    /// would also drop `draft.tmp` — more than the operator asked for.
    @Test func hostPatternsStaySeparateFromTheCatalogue() {
        var settings = GlobalExcludeSettings()
        settings.extraPatterns = ["*.TMP", "node_modules"]
        let plan = settings.plan(on: .macOS)

        #expect(plan.patterns.contains("node_modules"))
        #expect(!plan.patterns.contains("*.TMP"))
        // Both survive on the host list, `node_modules` included. It is
        // **not** dropped for matching a catalogue entry: the catalogue's
        // copy rides `--iexclude` and this one rides `--exclude`, so they
        // are different rules, and the catalogue's copy can be held back for
        // a given set while the host's is not. The visible cost is the same
        // text reaching restic twice under two flags.
        #expect(plan.hostPatterns == ["*.TMP", "node_modules"])
        #expect(plan.allPatterns.filter { $0 == "node_modules" }.count == 2)
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

    @Test func theDefaultPlanSplitsPlaceholdersOutWithoutLosingThem() {
        let plan = GlobalExcludeSettings.default.plan(on: .macOS)
        #expect(plan.cloudPlaceholderPatterns == ["*.icloud"])
        #expect(!plan.patterns.contains("*.icloud"))
        // Still reported, still applied to nearly every set — the split is
        // about *which* sets receive them, not about dropping them.
        #expect(plan.allPatterns.contains("*.icloud"))
        #expect(!plan.isEmpty)
    }

    /// A plan whose only content is a placeholder pattern is not empty —
    /// `isEmpty` decides whether the backup log says "none configured on
    /// this machine", and saying that while patterns were applied is how a
    /// missing file becomes unexplainable.
    @Test func aPlanOfOnlyPlaceholdersIsNotEmpty() {
        let plan = GlobalExcludePlan(
            patterns: [], cloudPlaceholderPatterns: ["*.icloud"], excludeCaches: false
        )
        #expect(!plan.isEmpty)
        #expect(GlobalExcludePlan.none.isEmpty)
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
    /// A FIFO at the settings path must be refused, not waited on.
    ///
    /// `Data(contentsOf:)` opens without `O_NONBLOCK`, so a FIFO parked
    /// there blocks the open until a writer appears — and this read runs
    /// while the helper builds its context for *every* command, so an
    /// emergency `restore` would hang forever. Worse than a decode error,
    /// because the failure could not even be captured as a value.
    ///
    /// The test would hang rather than fail if this regressed, so it is
    /// written to prove the refusal is immediate: a FIFO with no writer, and
    /// a bounded expectation that the call returns at all.
    @Test(.timeLimit(.minutes(1)))
    func aFifoAtTheSettingsPathIsRefusedRatherThanWaitedOn() throws {
        try withPaths { paths in
            try paths.ensureDirectories()
            #expect(mkfifo(paths.globalExcludesFile.path, 0o600) == 0)
            #expect(throws: GlobalExcludeError.self) {
                try GlobalExcludeStore(paths: paths).load()
            }
        }
    }

    @Test func anUnreadableFileRefusesInsteadOfFallingBackToTheDefaults() throws {
        try withPaths { paths in
            try paths.ensureDirectories()
            try Data("{ this is not json".utf8).write(to: paths.globalExcludesFile)
            #expect(throws: GlobalExcludeError.self) {
                try GlobalExcludeStore(paths: paths).load()
            }
        }
    }

    /// A **dangling symlink** at the settings path is a present entry, not
    /// an absent file, and must refuse for the same reason a corrupt file
    /// does.
    ///
    /// `FileManager.fileExists(atPath:)` follows symlinks, so a managed
    /// target that is temporarily away answered "no file here" and the host
    /// silently fell back to the built-in defaults — re-enabling any group
    /// the missing settings had turned off, and skipping paths the operator
    /// had deliberately kept, on every run afterwards.
    @Test func aDanglingSymlinkRefusesInsteadOfReadingAsAbsent() throws {
        try withPaths { paths in
            try paths.ensureDirectories()
            let absent = paths.root.appendingPathComponent("not-there.json", isDirectory: false)
            try FileManager.default.createSymbolicLink(
                at: paths.globalExcludesFile, withDestinationURL: absent
            )
            // The premise: the old check really does read this as absent.
            #expect(!FileManager.default.fileExists(atPath: paths.globalExcludesFile.path))
            #expect(throws: GlobalExcludeError.self) {
                try GlobalExcludeStore(paths: paths).load()
            }
            // And `reset` removes the entry rather than reporting that there
            // was nothing to remove — otherwise the very next load refuses.
            #expect(try GlobalExcludeStore(paths: paths).removeSettings() == true)
            let back = try GlobalExcludeStore(paths: paths).load()
            #expect(back == .default)
        }
    }

    /// The reason for the refusal must survive `CLIFailure`'s 500-character
    /// cap, whatever the decoder put in the underlying string.
    ///
    /// This is a real regression, not a hypothetical: the reason used to sit
    /// *after* the `DecodingError` dump, and macOS spells that error far
    /// more verbosely than Linux does, so the macOS CI job saw a truncated
    /// message with the only explanatory sentence cut off. The underlying
    /// text is foreign and unbounded, so it goes last.
    @Test func theRefusalReasonSurvivesTheMessageCap() {
        let noisy = String(repeating: "NSDebugDescription=the given data was not valid JSON; ", count: 40)
        // BOTH externally sized strings are pathological here: a deeply
        // nested RESTIC_STATION_DATA_DIR can blow the cap on its own, which
        // an earlier fix that only moved the decoder text still allowed.
        let deepPath = "/" + Array(repeating: "deeply-nested-data-directory", count: 30).joined(separator: "/")
            + "/global-excludes.json"
        for (path, underlying) in [(deepPath, noisy), ("/short/x.json", noisy), (deepPath, "boom")] {
            let error = GlobalExcludeError.unreadable(path: path, underlying: underlying)
            let message = CLIFailure.configInvalid(underlying: error).message

            #expect(message.count <= CLIFailure.messageCharacterLimit)
            #expect(
                message.contains("will not fall back to the built-in defaults"),
                "the refusal must still say why it did not use the defaults: \(message)"
            )
        }
    }

    /// A concurrent edit must be refused, not silently overwritten.
    ///
    /// The Settings pane holds this file while it is open; without the
    /// compare-and-swap a `restic-station excludes disable …` run in a
    /// terminal is erased by the pane's next toggle. The decision most
    /// likely to be lost is a *disabled* group, which silently re-enables
    /// it and drops paths the operator meant to keep.
    @Test func aConcurrentEditIsRefusedRatherThanOverwritten() throws {
        try withPaths { paths in
            let store = GlobalExcludeStore(paths: paths)
            var initial = GlobalExcludeSettings()
            initial.extraPatterns = ["/one"]
            try store.save(initial)

            // An editor loads, carrying the fingerprint it saw.
            let editor = try store.loadFingerprinted()

            // Someone else writes in the meantime — here, turning a group
            // off, the edit whose loss actually costs data.
            var other = try store.load()
            other.groups["browser-caches"] = false
            try store.save(other)

            var stale = editor.settings
            stale.extraPatterns = ["/two"]
            #expect(throws: GlobalExcludeError.self) {
                try store.save(stale, ifUnchangedFrom: editor.fingerprint)
            }
            // The other edit survived untouched.
            #expect(try store.load().groups == ["browser-caches": false])
            #expect(try store.load().extraPatterns == ["/one"])
        }
    }

    @Test func aWriteAgainstTheCurrentFingerprintSucceeds() throws {
        try withPaths { paths in
            let store = GlobalExcludeStore(paths: paths)
            let first = try store.loadFingerprinted()
            #expect(first.fingerprint == nil)

            var updated = first.settings
            updated.extraPatterns = ["/one"]
            try store.save(updated, ifUnchangedFrom: first.fingerprint)

            let second = try store.loadFingerprinted()
            #expect(second.fingerprint != nil)
            var again = second.settings
            again.extraPatterns = ["/one", "/two"]
            try store.save(again, ifUnchangedFrom: second.fingerprint)
            #expect(try store.load().extraPatterns == ["/one", "/two"])
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

    /// The compare-and-swap has to be *atomic with the rename*, or it is
    /// not a compare-and-swap: two writers can fingerprint the same bytes,
    /// both pass, and the loser's decision is gone. They also share one
    /// fixed `.tmp` filename, so one can rename the other's half-written
    /// bytes into place.
    ///
    /// `flock()` is per open file description, so a second `FileLock` on the
    /// same path genuinely contends even inside this process — which is what
    /// makes this a valid test of the cross-process behaviour.
    @Test func aSaveWhileAnotherWriterHoldsTheLockIsRefusedNotInterleaved() throws {
        try withPaths { paths in
            let store = GlobalExcludeStore(paths: paths)
            var settings = GlobalExcludeSettings()
            settings.extraPatterns = ["/one"]
            try store.save(settings)

            try paths.ensureDirectories()
            let peer = FileLock(path: paths.globalExcludesLockFile, trustedRoot: paths.root)
            #expect(peer.acquire() == .acquired)

            var blocked = settings
            blocked.extraPatterns = ["/two"]
            #expect(throws: GlobalExcludeError.self) { try store.save(blocked) }
            // Nothing was written behind the holder's back.
            let unchanged = try store.load()
            #expect(unchanged.extraPatterns == ["/one"])

            // And the lock is not left poisoned once the peer lets go.
            peer.release()
            try store.save(blocked)
            let after = try store.load()
            #expect(after.extraPatterns == ["/two"])
        }
    }

    /// An editor that stays open must not re-read the file to learn its own
    /// fingerprint: a writer that got in between the rename and that read
    /// would hand it *their* fingerprint, and its next save would pass the
    /// check and overwrite them. `save` returns what it wrote, from inside
    /// the lock.
    @Test func saveReturnsTheFingerprintItWroteSoAnEditorNeverReReadsTheFile() throws {
        try withPaths { paths in
            let store = GlobalExcludeStore(paths: paths)
            var settings = GlobalExcludeSettings()
            settings.extraPatterns = ["/one"]
            let first = try store.save(settings, ifUnchangedFrom: nil)
            #expect(first == store.currentFingerprint())

            // The returned value is accepted as-is by the next save.
            settings.extraPatterns = ["/one", "/two"]
            let second = try store.save(settings, ifUnchangedFrom: first)
            #expect(second != first)
            #expect(second == store.currentFingerprint())

            // The superseded one is not.
            settings.extraPatterns = ["/three"]
            #expect(throws: GlobalExcludeError.self) {
                try store.save(settings, ifUnchangedFrom: first)
            }
        }
    }

    /// `excludes reset` goes through the store so its existence check and
    /// its unlink share the write lock with every other writer: a save that
    /// landed between them would leave a host carrying an adjustment after
    /// being told it is back on the built-in defaults.
    @Test func removingTheSettingsTakesTheSameWriteLockAsASave() throws {
        try withPaths { paths in
            let store = GlobalExcludeStore(paths: paths)
            #expect(try store.removeSettings() == false)

            var settings = GlobalExcludeSettings()
            settings.extraPatterns = ["/one"]
            try store.save(settings)

            let peer = FileLock(path: paths.globalExcludesLockFile, trustedRoot: paths.root)
            #expect(peer.acquire() == .acquired)
            #expect(throws: GlobalExcludeError.self) { try store.removeSettings() }
            #expect(FileManager.default.fileExists(atPath: paths.globalExcludesFile.path))

            peer.release()
            #expect(try store.removeSettings() == true)
            #expect(!FileManager.default.fileExists(atPath: paths.globalExcludesFile.path))
            let back = try store.load()
            #expect(back == .default)
        }
    }

    /// The compare-and-swap must tell "there is no file" from "there is an
    /// entry I cannot read".
    ///
    /// Both used to fingerprint as `nil`, so a Settings pane whose *load*
    /// failed on a dangling symlink still held its initial `nil` and its
    /// next toggle compared equal — renaming a defaults-based file over the
    /// entry and re-enabling every group the unavailable settings had turned
    /// off. The strict comparison refuses instead.
    @Test func aConditionalSaveRefusesAnEntryItCannotRead() throws {
        try withPaths { paths in
            try paths.ensureDirectories()
            let absent = paths.root.appendingPathComponent("not-there.json", isDirectory: false)
            try FileManager.default.createSymbolicLink(
                at: paths.globalExcludesFile, withDestinationURL: absent
            )
            let store = GlobalExcludeStore(paths: paths)
            // The editor's starting state after a load that threw.
            #expect(throws: GlobalExcludeError.self) {
                try store.save(.default, ifUnchangedFrom: nil)
            }
            // The link is untouched — nothing was renamed over it.
            let attributes = try FileManager.default.attributesOfItem(
                atPath: paths.globalExcludesFile.path
            )
            #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        }
    }

    /// The write is durable, not merely atomic: the temp file is fsynced
    /// before the rename and the containing directory after it, and a
    /// removal syncs the directory too.
    ///
    /// A crash cannot be provoked from a unit test, so what is asserted is
    /// the observable contract the fsyncs exist to serve — a save leaves
    /// exactly the intended bytes and no temp file behind, and a removal
    /// leaves no entry — plus the fact that the durable path is the one
    /// taken. The reasoning for the syncs themselves lives in `DurableFile`.
    @Test func aSaveLeavesTheTargetAndNoTempFileBehind() throws {
        try withPaths { paths in
            let store = GlobalExcludeStore(paths: paths)
            var settings = GlobalExcludeSettings()
            settings.extraPatterns = ["/one"]
            try store.save(settings)

            #expect(FileManager.default.fileExists(atPath: paths.globalExcludesFile.path))
            #expect(!FileManager.default.fileExists(atPath: store.tempFile.path))
            let loaded = try store.load()
            #expect(loaded.extraPatterns == ["/one"])

            // A second save replaces rather than appending, and still
            // leaves no temp file.
            settings.extraPatterns = ["/two"]
            try store.save(settings)
            #expect(!FileManager.default.fileExists(atPath: store.tempFile.path))
            #expect(try store.load().extraPatterns == ["/two"])

            #expect(try store.removeSettings() == true)
            #expect(!FileManager.default.fileExists(atPath: paths.globalExcludesFile.path))
            #expect(try store.removeSettings() == false)
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
        usesGlobalExcludes: Bool = true,
        onlineOnlyFiles: OnlineOnlyFiles = .skip
    ) -> BackupSet {
        BackupSet(
            id: UUID(),
            name: "Projects",
            sources: ["/Users/user/proj"],
            excludes: excludes,
            purgeExcludes: purgeExcludes,
            onlineOnlyFiles: onlineOnlyFiles,
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

    /// Nothing is dropped from the catalogue block as a duplicate, not even
    /// identical text.
    ///
    /// The two blocks are different *rules*: `--exclude node_modules` is
    /// case-sensitive and `--iexclude node_modules` is not. Dropping the
    /// catalogue entry because the set names the common lowercase spelling
    /// would leave `NODE_MODULES` backed up with global exclusions on and
    /// no pattern to point at — which is why an earlier exact-match filter
    /// was removed rather than narrowed. The cost is one redundant match in
    /// the argv.
    @Test func theCatalogueBlockIsNeverThinnedByTheSetsOwnList() {
        for spelling in ["node_modules", "NODE_MODULES"] {
            #expect(
                makeSet(excludes: [spelling]).globalBackupExcludes(applying: plan)
                    == ["node_modules", ".cache"]
            )
        }
    }

    /// The host block *is* deduplicated, because there both lists ride the
    /// same case-sensitive `--exclude` and identical text really is the
    /// same rule.
    @Test func theHostBlockDropsAnExactDuplicateOfTheSetsOwnPattern() {
        let hostPlan = GlobalExcludePlan(
            patterns: [], hostPatterns: ["/srv/scratch", "*.iso"], excludeCaches: false
        )
        #expect(
            makeSet(excludes: ["/srv/scratch"]).hostBackupExcludes(applying: hostPlan) == ["*.iso"]
        )
    }

    @Test func anOptedOutSetGetsNothingFromTheGlobalList() {
        let set = makeSet(excludes: ["*.log"], usesGlobalExcludes: false)
        #expect(set.effectiveBackupExcludes == ["*.log"])
        #expect(set.globalBackupExcludes(applying: plan).isEmpty)
        #expect(!set.excludesCaches(applying: plan))
        #expect(set.excludeLargerThan(applying: plan) == nil)
    }

    /// A set that has asked to *download* its online-only files wants their
    /// real contents in the snapshot. Excluding the placeholder stubs there
    /// would remove the last filesystem trace of those files from a snapshot
    /// the operator has been told is complete — the silent under-backup this
    /// whole feature is built to avoid. Every other set still skips them.
    @Test func aSetThatDownloadsOnlineOnlyFilesKeepsTheCloudPlaceholders() {
        let plan = GlobalExcludePlan(
            patterns: ["node_modules"],
            cloudPlaceholderPatterns: ["*.icloud"],
            excludeCaches: true
        )
        #expect(
            makeSet(onlineOnlyFiles: .skip).globalBackupExcludes(applying: plan)
                == ["node_modules", "*.icloud"]
        )
        #expect(
            makeSet(onlineOnlyFiles: .download).globalBackupExcludes(applying: plan)
                == ["node_modules"]
        )
        // The policy governs the placeholders and nothing else: a
        // downloading set still gets `--exclude-caches`, the size cap and
        // this host's own patterns.
        #expect(makeSet(onlineOnlyFiles: .download).excludesCaches(applying: plan))
    }

    /// Opting out still wins over everything, in either direction.
    @Test func anOptedOutSetGetsNoPlaceholdersEitherWay() {
        let plan = GlobalExcludePlan(
            patterns: ["node_modules"], cloudPlaceholderPatterns: ["*.icloud"], excludeCaches: true
        )
        for policy in OnlineOnlyFiles.allCases {
            let set = makeSet(usesGlobalExcludes: false, onlineOnlyFiles: policy)
            #expect(set.globalBackupExcludes(applying: plan).isEmpty)
        }
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
