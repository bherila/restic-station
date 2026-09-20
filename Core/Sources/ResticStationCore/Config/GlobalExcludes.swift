import Foundation

// MARK: - GlobalExcludeGroup

/// One named block of built-in `--exclude` patterns.
///
/// Groups exist so the list is *reviewable*: "browser caches" is something a
/// person can decide about, where eighty individual glob patterns are not.
/// A group is the unit the host-local settings file turns on and off, and
/// the unit `excludes show` prints.
public struct GlobalExcludeGroup: Equatable, Sendable, Identifiable {
    /// Stable key written into `global-excludes.json`. Lowercase
    /// `[a-z0-9-]`; renaming one is a breaking change to that file, so it
    /// never happens without a settings-schema bump.
    public let id: String
    /// One-line name for the UI and for `excludes show`.
    public let title: String
    /// One sentence saying what is skipped and why it is safe to skip —
    /// shown verbatim, so it has to answer "would I lose anything?".
    public let summary: String
    /// Whether a host with no `global-excludes.json`, or one that says
    /// nothing about this group, applies it.
    ///
    /// `false` is for groups whose contents can be the *only* copy of
    /// something (a virtual machine someone built by hand). Those are
    /// offered, never assumed.
    public let enabledByDefault: Bool
    /// restic `--exclude` patterns, in the order they reach argv.
    public let patterns: [String]

    public init(
        id: String,
        title: String,
        summary: String,
        enabledByDefault: Bool = true,
        patterns: [String]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.enabledByDefault = enabledByDefault
        self.patterns = patterns
    }
}

// MARK: - GlobalExcludeCatalog

/// The built-in exclusion list, compiled into the binary rather than seeded
/// into a file on first run.
///
/// **Why compiled in.** A seeded file goes stale the moment a build learns
/// about a new build system, and every host would then need a migration to
/// pick the improvement up. Shipping the catalog in code means an upgrade
/// improves the defaults everywhere, and `global-excludes.json` stays what
/// it should be: the short list of decisions *this host* made that differ
/// from the defaults.
///
/// **Every pattern here is relative and unanchored.** No leading `/`, no
/// `~`, no `$VAR`. restic matches a relative pattern against the trailing
/// path components, so `Library/Caches` skips `~/Library/Caches` wherever
/// the home directory is and on whichever platform, and `node_modules`
/// skips one at any depth. A `*` inside a component works
/// (`*.photoslibrary/resources/derivatives`), as does `**` between them
/// (`*.imovielibrary/**/Render Files`). That is also why there is **no
/// platform branch**: a macOS-shaped pattern simply matches nothing on
/// Linux, and keeping one list means `config show` on either OS describes
/// the same rules.
///
/// **The hazard that shapes the whole list: an unanchored pattern matches
/// any component of the *absolute* path, including directories above the
/// source.** `--exclude tmp` against a source under `/tmp/...` excludes the
/// source itself and produces an empty snapshot. So a single-component
/// pattern must name something nobody has above their data — `node_modules`
/// is safe, `tmp`, `var`, `data` and `bin` are not.
/// ``GlobalExcludeCatalogTests`` pins both that denylist and the shape rule.
///
/// Patterns reach restic as **`--iexclude`**, not `--exclude`: this list is
/// a set of well-known names rather than something a person typed, and
/// `Library/Caches` should skip `library/caches` too. Code42's equivalent
/// list is likewise entirely case-insensitive. A backup set's own
/// ``BackupSet/excludes`` keep the case-sensitive `--exclude` they have
/// always had.
///
/// See `docs/data-model.md` §global-excludes.json for the normative
/// description of this list and of the file that adjusts it.
public enum GlobalExcludeCatalog {
    /// Bumped whenever ``groups`` gains, loses or edits a pattern.
    ///
    /// Recorded in `global-excludes.json` so `excludes show` can say "this
    /// build knows a newer catalog than the one you last saved against",
    /// and so a support question about a surprising exclusion has a version
    /// to quote. It is **not** a compatibility gate: a group this build has
    /// never heard of is an error (see ``GlobalExcludeError/unknownGroup``),
    /// and a group added after the file was written takes its built-in
    /// default.
    public static let version = 2

    /// The catalog, in the order its patterns reach argv.
    public static let groups: [GlobalExcludeGroup] = [
        GlobalExcludeGroup(
            id: "browser-caches",
            title: "Browser caches",
            summary: "Cached pages, images, compiled scripts and GPU shaders that every browser "
                + "refetches or rebuilds on demand. Bookmarks, history, passwords and profile "
                + "settings are not here and are still backed up.",
            patterns: [
                // Per-user cache roots, where the Chromium and Gecko families
                // keep the bulk of it.
                "Library/Caches/Google/Chrome",
                "Library/Caches/Chromium",
                "Library/Caches/BraveSoftware",
                "Library/Caches/Microsoft Edge",
                "Library/Caches/com.microsoft.edgemac",
                "Library/Caches/com.apple.Safari",
                "Library/Caches/Firefox",
                "Library/Caches/com.operasoftware.Opera",
                ".cache/google-chrome",
                ".cache/chromium",
                ".cache/microsoft-edge",
                ".cache/BraveSoftware",
                ".cache/mozilla",
                ".cache/opera",
                ".cache/vivaldi",
                // Caches that live *inside* the profile directory, so they
                // are not covered by the roots above. These names are also
                // what every Electron app uses, which is deliberate.
                "Code Cache",
                "GPUCache",
                "ShaderCache",
                "GrShaderCache",
                "DawnCache",
                "DawnGraphiteCache",
                "DawnWebGPUCache",
                "component_crx_cache",
                "Service Worker/CacheStorage",
                "Service Worker/ScriptCache",
                // Firefox/Gecko per-profile cache.
                "cache2",
                "startupCache",
                "safebrowsing",
            ]
        ),
        GlobalExcludeGroup(
            id: "system-caches",
            title: "System and application caches",
            summary: "Per-user cache, log and trash directories, plus the index and metadata "
                + "sidecars the OS maintains. All of it is rebuilt automatically.",
            patterns: [
                "Library/Caches",
                "Library/Logs",
                "Library/Saved Application State",
                "Library/Application Support/CrashReporter",
                "Library/Metadata/CoreSpotlight",
                ".cache",
                ".local/share/Trash",
                ".Trash",
                ".Trashes",
                ".Spotlight-V100",
                ".DocumentRevisions-V100",
                ".fseventsd",
                ".TemporaryItems",
                ".apdisk",
                "lost+found",
                ".DS_Store",
                "Thumbs.db",
                "desktop.ini",
                // Sync clients' own scratch, which is re-downloaded.
                ".dropbox.cache",
                "Library/Application Support/Google/DriveFS",
                // Zero-byte iCloud placeholders. `--exclude-cloud-files`
                // (restic 0.19+) is the real answer; this catches the same
                // files on an older restic, where they would otherwise be
                // backed up as empty stubs.
                "*.icloud",
                // Backing up a backup: Time Machine's destination and its
                // local snapshots, and the Finder/system sidecars that
                // regenerate on sight.
                "backups.backupdb",
                ".MobileBackups",
                "Network Trash Folder",
                ".hotfiles.btree",
                ".PKInstallSandboxManager-SystemSoftware",
                "Desktop DB",
                "Desktop DF",
                ".adobeTemp",
                // Present on an external drive that has also been used on
                // Windows, where it is pure filesystem bookkeeping.
                "System Volume Information",
            ]
        ),
        GlobalExcludeGroup(
            id: "temporary-files",
            title: "Temporary and partial files",
            summary: "Editor swap files, half-finished downloads and anything already named as "
                + "scratch. A partial download is never worth a snapshot.",
            patterns: [
                "*.tmp",
                "*.temp",
                "*~",
                "*.swp",
                "*.swo",
                "*.part",
                "*.partial",
                "*.crdownload",
                "*.download",
                "Temporary Items",
                // Runtime scratch a process recreates. Deliberately **not**
                // `*.lock`, which Code42's equivalent list does exclude:
                // that pattern also eats `Cargo.lock`, `yarn.lock`,
                // `poetry.lock` and `flake.lock` — the files a rebuild
                // depends on most.
                "*.pid",
                "*.crash",
            ]
        ),
        GlobalExcludeGroup(
            id: "developer-build-artifacts",
            title: "Build output",
            summary: "Directories a build recreates from source that is itself backed up: Swift, "
                + "Xcode, Rust, .NET, Node, Python, JVM and CMake output trees.",
            patterns: [
                // Swift / Xcode.
                ".build",
                "DerivedData",
                "Library/Developer/Xcode/DerivedData",
                "Library/Developer/Xcode/iOS DeviceSupport",
                "Library/Developer/CoreSimulator/Caches",
                "xcuserdata",
                "Pods",
                // Rust and .NET. Deliberately two components: a bare
                // `target`, `bin` or `obj` would also skip a directory of
                // 3-D models or a folder someone named "target", so the
                // patterns name the build configuration underneath them.
                "target/debug",
                "target/release",
                "target/classes",
                "bin/Debug",
                "bin/Release",
                "obj/Debug",
                "obj/Release",
                ".vs",
                // Node and the hidden framework output directories.
                "node_modules",
                ".next",
                ".nuxt",
                ".svelte-kit",
                ".astro",
                ".angular",
                ".docusaurus",
                ".turbo",
                ".parcel-cache",
                ".vercel",
                ".netlify",
                ".wrangler",
                // Python.
                "__pycache__",
                "*.pyc",
                "*.pyo",
                ".venv",
                ".tox",
                ".nox",
                ".mypy_cache",
                ".pytest_cache",
                ".ruff_cache",
                ".ipynb_checkpoints",
                "*.egg-info",
                // JVM, CMake, Go, Dart, Haskell, Terraform, C/C++ tooling.
                ".gradle",
                "cmake-build-debug",
                "cmake-build-release",
                "CMakeFiles",
                ".dart_tool",
                ".expo",
                ".stack-work",
                "dist-newstyle",
                ".terraform",
                ".ccls-cache",
                "*.class",
                ".sonarlint",
                // The editor's downloaded extensions, not its settings:
                // `.vscode` itself holds a workspace's committed config.
                ".vscode/extensions",
            ]
        ),
        GlobalExcludeGroup(
            id: "package-manager-caches",
            title: "Package manager caches",
            summary: "Downloaded packages and compiler caches. Every one of them is refetched "
                + "from a lockfile or registry, and they are among the largest things in a "
                + "home directory.",
            patterns: [
                ".npm",
                ".yarn/cache",
                ".yarn/berry/cache",
                ".pnpm-store",
                ".bun/install/cache",
                ".cargo/registry",
                ".cargo/git",
                "go/pkg/mod",
                ".cache/go-build",
                ".gradle/caches",
                ".m2/repository",
                ".ivy2/cache",
                ".nuget/packages",
                ".pub-cache",
                ".composer/cache",
                ".gem/cache",
                "Library/Caches/Homebrew",
                ".cache/Homebrew",
                "Library/Caches/pip",
                ".cache/pip",
                "Library/Caches/CocoaPods",
                "vendor/bundle",
                ".nvm/.cache",
                ".cache/ms-playwright",
                "Library/Caches/ms-playwright",
                ".cache/huggingface",
            ]
        ),
        GlobalExcludeGroup(
            id: "media-app-caches",
            title: "Photo and video app caches",
            summary: "Thumbnails, previews, render and analysis files that Photos, Lightroom, "
                + "Final Cut and iTunes rebuild from the originals. The originals themselves, and "
                + "each library's own database, are still backed up.",
            patterns: [
                // Photos: the rendered derivatives, never `originals/` and
                // never `database/`. Code42 excludes the database too, which
                // it can afford because it restores files rather than a
                // working library; a restic snapshot missing that database
                // restores a library the Photos app refuses to open.
                "*.photoslibrary/resources/derivatives",
                "*.photoslibrary/Thumbnails",
                "*.photolibrary/Thumbnails",
                "iPod Photo Cache",
                "Album Artwork/Cache",
                // Lightroom previews, Final Cut's cache, iMovie's generated
                // media. `**` matches the per-event directories between the
                // library and the generated folder.
                "*.lrprev",
                "*Previews.lrdata",
                "*.fcpcache",
                "*.imovielibrary/**/Render Files",
                "*.imovielibrary/**/Analysis Files",
                "*.theater/**/Render Files",
            ]
        ),
        GlobalExcludeGroup(
            id: "container-engines",
            title: "Container engine storage",
            summary: "Docker, OrbStack, colima and podman machine data. Images come back from a "
                + "registry and the engine rebuilds its store; the disk images here are "
                + "routinely tens of gigabytes.",
            patterns: [
                "Library/Containers/com.docker.docker/Data",
                "Library/Group Containers/group.com.docker",
                ".docker/desktop",
                ".docker/machine",
                ".orbstack/data",
                ".colima",
                ".local/share/containers",
                ".local/share/docker",
                ".lima",
            ]
        ),
        GlobalExcludeGroup(
            id: "virtual-machine-images",
            title: "Virtual machine disk images",
            summary: "Parallels, VMware, VirtualBox, UTM, QEMU and Vagrant disk images. Off by "
                + "default: unlike a container image, a VM someone built by hand may exist "
                + "nowhere else.",
            enabledByDefault: false,
            patterns: [
                "*.vmdk",
                "*.vdi",
                "*.vhd",
                "*.vhdx",
                "*.qcow2",
                "*.pvm",
                "*.utm",
                "Virtual Machines.localized",
                "Library/Application Support/VirtualBox",
                ".vagrant",
                ".vagrant.d/boxes",
                // Suspended-VM state and firmware scratch: large, and
                // meaningless without the machine it belongs to.
                "*.vmem",
                "*.vmsn",
                "*.vmss",
                "*.vmsd",
                "*.vmtm",
                "*.nvram",
                "*.avhdx",
                "*.vfd",
                "*.vsv",
                "*.hds",
                "*.pvs",
                "*.vmwarevm",
                "*.xva",
                "*.ova",
                // Deliberately **not** `*.vmx` or `*.vmxf`: those are the
                // few kilobytes that describe the machine, and a disk image
                // restored without them is harder to revive, not easier.
            ]
        ),
        GlobalExcludeGroup(
            id: "installers-and-disk-images",
            title: "Installers and disk images",
            summary: "Downloaded installers and mountable images — .dmg, .iso, .pkg, .msi, and "
                + "sparse/Time Machine bundles. Off by default: most are a re-download away, but "
                + "an image you built yourself may exist nowhere else.",
            enabledByDefault: false,
            patterns: [
                "*.dmg",
                "*.iso",
                "*.pkg",
                "*.msi",
                "*.msix",
                "*.exe",
                "*.cab",
                "*.sparsebundle",
                "*.sparseimage",
                "*.backupbundle",
                "*.mrimg",
            ]
        ),
        GlobalExcludeGroup(
            id: "game-and-media-libraries",
            title: "Game installs and media server data",
            summary: "Installed Steam/Epic/GOG games and a Plex server's generated metadata — "
                + "hundreds of gigabytes that a re-download or a re-scan rebuilds. Off by "
                + "default: rebuilding is cheap in effort and expensive in time, so it is your "
                + "call. Save data is not in here.",
            enabledByDefault: false,
            patterns: [
                "Steam/steamapps/common",
                "Steam/steamapps/downloading",
                "Steam/steamapps/shadercache",
                "Steam/appcache",
                "Epic Games",
                "GOG Galaxy/Games",
                "Battle.net",
                "Plex Media Server/Cache",
                "Plex Media Server/Media",
                "Plex Media Server/Metadata",
            ]
        ),
    ]

    /// Catalog lookup by ``GlobalExcludeGroup/id``.
    public static func group(id: String) -> GlobalExcludeGroup? {
        groups.first { $0.id == id }
    }

    /// Every known group id, in catalog order.
    public static var groupIDs: [String] {
        groups.map(\.id)
    }
}

// MARK: - GlobalExcludePlan

/// The resolved answer to "what does this host add to every backup?", handed
/// to `BackupEngine` as a value.
///
/// Resolving happens once, where the host-local file is read, for the same
/// reason per-machine config resolution does: nothing downstream should be
/// able to re-resolve it, disagree about it, or read the file a second time
/// mid-run.
public struct GlobalExcludePlan: Equatable, Sendable {
    /// Patterns handed to every applying set as `--iexclude`, in catalogue
    /// order followed by the host's own extra patterns.
    public let patterns: [String]
    /// Whether `backup` also carries `--exclude-caches`, which skips any
    /// directory tagged `CACHEDIR.TAG` by the tool that created it.
    public let excludeCaches: Bool
    /// `restic backup --exclude-larger-than <size>`, or `nil` for no cap.
    ///
    /// Off unless asked for. Code42 caps at 10 GB by default; here a size
    /// cap is the one setting in this whole file that can silently drop a
    /// single *named* file someone cared about rather than a directory full
    /// of regenerable ones, so it is opt-in.
    public let excludeLargerThan: String?

    public init(patterns: [String], excludeCaches: Bool, excludeLargerThan: String? = nil) {
        self.patterns = patterns
        self.excludeCaches = excludeCaches
        self.excludeLargerThan = excludeLargerThan
    }

    /// Adds nothing to any backup — the value every construction site that
    /// has not loaded settings uses, so forgetting to wire the plan through
    /// can only ever back up *more* than intended, never less.
    public static let none = GlobalExcludePlan(patterns: [], excludeCaches: false)

    public var isEmpty: Bool {
        patterns.isEmpty && !excludeCaches && excludeLargerThan == nil
    }
}

// MARK: - GlobalExcludeSettings

/// `global-excludes.json` — the host-local adjustments to
/// ``GlobalExcludeCatalog``.
///
/// **Host-local on purpose.** `config.json` is one shared file describing a
/// whole fleet (`docs/data-model.md` §config.json); a cache path is a
/// property of a *machine*, and of how Restic Station was installed on it.
/// The file therefore lives beside `machine.json` in the data directory, so
/// a per-user install adjusts one user's backups and a system-wide install
/// (a data directory under `/var/lib`, selected with
/// `RESTIC_STATION_DATA_DIR`) adjusts the machine's. Nothing here is ever
/// exported by `config export`.
///
/// ```json
/// {
///   "version": 1,
///   "catalogVersion": 1,
///   "enabled": true,
///   "excludeCaches": true,
///   "groups": { "virtual-machine-images": true },
///   "extraPatterns": ["*.iso"]
/// }
/// ```
///
/// `groups` holds **only the decisions that differ from the built-in
/// default**, which is what lets a later build add a group and have it take
/// effect without rewriting anyone's file.
public struct GlobalExcludeSettings: Codable, Equatable, Sendable {
    /// Current `global-excludes.json` schema version. Independent of
    /// `AppConfig.currentVersion` and of ``GlobalExcludeCatalog/version`` —
    /// the file's *shape* and the list's *contents* change for different
    /// reasons.
    public static let currentVersion = 1

    public var version: Int
    /// The ``GlobalExcludeCatalog/version`` this file was last written
    /// against. Diagnostic only; see that property.
    public var catalogVersion: Int
    /// Master switch. `false` means this host contributes no global
    /// patterns at all, whatever the rest of the file says — one obvious
    /// place to turn the feature off without losing the group decisions
    /// underneath it.
    public var enabled: Bool
    /// Pass `--exclude-caches` to `restic backup`, skipping any directory
    /// its own creator tagged with `CACHEDIR.TAG` (the Cache Directory
    /// Tagging Specification). Cargo, Go and others write that tag, so it
    /// catches build caches no pattern list knows about.
    public var excludeCaches: Bool
    /// `restic backup --exclude-larger-than <size>` (`500M`, `10G`, …), or
    /// `nil` — the default — for no cap.
    ///
    /// Opt-in, unlike Code42's 10 GB default: every other rule in this file
    /// names a directory of regenerable things, while a size cap can drop
    /// one irreplaceable file (a video, a disk image, a dataset) with no
    /// pattern anyone could point at afterwards.
    public var excludeLargerThan: String?
    /// Group decisions that differ from ``GlobalExcludeGroup/enabledByDefault``.
    /// Absent group = built-in default.
    public var groups: [String: Bool]
    /// This host's own additional `--exclude` patterns, applied to every set
    /// that has not opted out. Unlike the catalog these may be absolute.
    public var extraPatterns: [String]

    public init(
        version: Int = GlobalExcludeSettings.currentVersion,
        catalogVersion: Int = GlobalExcludeCatalog.version,
        enabled: Bool = true,
        excludeCaches: Bool = true,
        excludeLargerThan: String? = nil,
        groups: [String: Bool] = [:],
        extraPatterns: [String] = []
    ) {
        self.version = version
        self.catalogVersion = catalogVersion
        self.enabled = enabled
        self.excludeCaches = excludeCaches
        self.excludeLargerThan = excludeLargerThan
        self.groups = groups
        self.extraPatterns = extraPatterns
    }

    /// What a host with no `global-excludes.json` applies: the catalog's own
    /// defaults.
    public static let `default` = GlobalExcludeSettings()

    private enum CodingKeys: String, CodingKey {
        case version, catalogVersion, enabled, excludeCaches, excludeLargerThan
        case groups, extraPatterns
    }

    /// Hand-written for the same reason `BackupSet`'s is: a key added by a
    /// later settings version must decode out of an older file, and every
    /// absent key here has a defined meaning.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        catalogVersion = try container.decodeIfPresent(Int.self, forKey: .catalogVersion) ?? 0
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        excludeCaches = try container.decodeIfPresent(Bool.self, forKey: .excludeCaches) ?? true
        excludeLargerThan = try container.decodeIfPresent(String.self, forKey: .excludeLargerThan)
        groups = try container.decodeIfPresent([String: Bool].self, forKey: .groups) ?? [:]
        extraPatterns = try container.decodeIfPresent([String].self, forKey: .extraPatterns) ?? []
    }

    /// Whether this group applies here: the host's explicit decision, or the
    /// catalog's default when it has none.
    public func isEnabled(_ group: GlobalExcludeGroup) -> Bool {
        groups[group.id] ?? group.enabledByDefault
    }

    /// The enabled groups, in catalog order.
    public var enabledGroups: [GlobalExcludeGroup] {
        GlobalExcludeCatalog.groups.filter(isEnabled)
    }

    /// Resolves to the value the engine consumes. Deduplicated with
    /// first-occurrence order preserved, the same rule
    /// ``BackupSet/effectiveBackupExcludes`` uses.
    public var plan: GlobalExcludePlan {
        guard enabled else { return .none }
        var seen = Set<String>()
        let patterns = (enabledGroups.flatMap(\.patterns) + extraPatterns)
            .filter { seen.insert($0).inserted }
        return GlobalExcludePlan(
            patterns: patterns,
            excludeCaches: excludeCaches,
            excludeLargerThan: excludeLargerThan
        )
    }

    /// Rejects a file this build cannot honour exactly as written.
    ///
    /// Deliberately strict about an unknown group id. "Disable this group"
    /// is a request to back up *more*, so quietly ignoring a typo leaves a
    /// person believing a directory is protected while every run keeps
    /// skipping it — the silent under-backup this whole file exists to make
    /// visible. A newer-version file is refused for the same reason.
    public func validate() throws {
        guard version <= Self.currentVersion else {
            throw GlobalExcludeError.newerVersion(found: version, supported: Self.currentVersion)
        }
        let known = Set(GlobalExcludeCatalog.groupIDs)
        for id in groups.keys.sorted() where !known.contains(id) {
            throw GlobalExcludeError.unknownGroup(id, known: GlobalExcludeCatalog.groupIDs)
        }
        for (index, pattern) in extraPatterns.enumerated() where pattern.isEmpty {
            throw GlobalExcludeError.emptyExtraPattern(index: index)
        }
        if let excludeLargerThan, !Self.isValidSize(excludeLargerThan) {
            throw GlobalExcludeError.invalidSize(excludeLargerThan)
        }
    }

    /// restic's `--exclude-larger-than` grammar: digits, optionally followed
    /// by one of `k/K m/M g/G t/T`. Checked here rather than left to restic
    /// so a typo fails when it is saved, not silently at 3 a.m. when the
    /// backup refuses to start.
    public static func isValidSize(_ size: String) -> Bool {
        guard !size.isEmpty else { return false }
        var digits = Substring(size)
        if let last = digits.last, "kKmMgGtT".contains(last) {
            digits = digits.dropLast()
        }
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // Explicit values for every key — same convention (and reasoning) as
    // `AppConfig.encode(to:)`: the file stays diffable and matches the
    // documented example modulo key order.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(catalogVersion, forKey: .catalogVersion)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(excludeCaches, forKey: .excludeCaches)
        try container.encode(excludeLargerThan, forKey: .excludeLargerThan)
        try container.encode(groups, forKey: .groups)
        try container.encode(extraPatterns, forKey: .extraPatterns)
    }
}

// MARK: - GlobalExcludeError

public enum GlobalExcludeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `global-excludes.json` was written by a newer build.
    case newerVersion(found: Int, supported: Int)
    /// `groups` names a group this build does not have.
    case unknownGroup(String, known: [String])
    /// An empty string in `extraPatterns`.
    case emptyExtraPattern(index: Int)
    /// `excludeLargerThan` is not restic's `<digits>[kKmMgGtT]` size form.
    case invalidSize(String)
    /// The file exists but could not be read or decoded. Deliberately fatal
    /// rather than "fall back to the defaults": the defaults exclude *more*
    /// than a host that had turned groups off, so guessing here silently
    /// stops backing up directories someone had deliberately kept.
    case unreadable(path: String, underlying: String)

    public var description: String {
        switch self {
        case .newerVersion(let found, let supported):
            return "global-excludes.json was written by a newer Restic Station (version \(found), "
                + "this build supports up to \(supported))"
        case .unknownGroup(let id, let known):
            return "global-excludes.json refers to an unknown exclusion group \"\(id)\" — "
                + "this build knows: \(known.joined(separator: ", "))"
        case .emptyExtraPattern(let index):
            return "global-excludes.json has an empty extraPatterns entry at position \(index) — "
                + "remove it or give it a real path or glob"
        case .invalidSize(let size):
            return "global-excludes.json has an invalid excludeLargerThan \"\(size)\" — it must be "
                + "a number optionally followed by k, m, g or t (for example \"500m\" or \"10G\")"
        case .unreadable(let path, let underlying):
            return "could not read \(path): \(underlying). Refusing to fall back to the built-in "
                + "defaults, which may exclude more than this host had configured"
        }
    }
}

extension GlobalExcludeError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - GlobalExcludeStore

/// Loads and atomically persists `global-excludes.json`, the third file in
/// the data directory after `config.json` and `machine.json`. Same
/// conventions as both: no caching, `.sortedKeys` + `.prettyPrinted`, temp
/// file + `rename(2)`.
///
/// Two behavioural notes:
///
/// - **An absent file is not an error**, it is the documented default
///   (``GlobalExcludeSettings/default``). Unlike `machine.json` the file is
///   *not* auto-created: there is nothing host-specific to generate, and a
///   host that never customises anything should not accumulate a file whose
///   contents are already in the binary.
/// - **A present but unusable file is fatal.** See
///   ``GlobalExcludeError/unreadable(path:underlying:)``.
///
/// It is deliberately a separate file from `machine.json` rather than more
/// keys in it. `machine.json` holds the host's *identity*, and every write
/// to it has to go through `MachineStore.savePreservingIdentity(_:)` or it
/// can rebind the machine to the wrong set of overrides
/// (`docs/data-model.md` §machine.json). Routine settings edits do not
/// belong anywhere near that hazard.
public struct GlobalExcludeStore: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// Temp file for the atomic write — fixed, not randomized, for the same
    /// reason as `ConfigStore.tempConfigFile`.
    var tempFile: URL {
        paths.globalExcludesFile.deletingLastPathComponent()
            .appendingPathComponent(
                paths.globalExcludesFile.lastPathComponent + ".tmp",
                isDirectory: false
            )
    }

    /// Reads `global-excludes.json`, or returns
    /// ``GlobalExcludeSettings/default`` when it does not exist.
    ///
    /// - Throws: ``GlobalExcludeError`` for a file that exists and cannot be
    ///   honoured exactly as written.
    public func load() throws -> GlobalExcludeSettings {
        guard FileManager.default.fileExists(atPath: paths.globalExcludesFile.path) else {
            return .default
        }
        let settings: GlobalExcludeSettings
        do {
            let data = try Data(contentsOf: paths.globalExcludesFile)
            settings = try ConfigStore.makeDecoder().decode(GlobalExcludeSettings.self, from: data)
        } catch {
            throw GlobalExcludeError.unreadable(
                path: paths.globalExcludesFile.path,
                underlying: "\(error)"
            )
        }
        try settings.validate()
        return settings
    }

    /// Validates, then writes atomically (temp file + `rename(2)`), creating
    /// the data directory if needed. `catalogVersion` is stamped with the
    /// catalog this build carries, since that is what the decisions in the
    /// written file were made against.
    public func save(_ settings: GlobalExcludeSettings) throws {
        var updated = settings
        updated.version = GlobalExcludeSettings.currentVersion
        updated.catalogVersion = GlobalExcludeCatalog.version
        try updated.validate()
        try paths.ensureDirectories()
        let data = try ConfigStore.makeEncoder().encode(updated)
        try data.write(to: tempFile)
        try AtomicFile.rename(from: tempFile, to: paths.globalExcludesFile)
    }
}
