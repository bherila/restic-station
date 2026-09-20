import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - GlobalExcludePlatform

/// The platforms a catalogue pattern can apply on.
///
/// Code42's published list is organised the same way — its patterns carry
/// `mac:`, `linux:` and `win:` prefixes, or none for "everywhere" — and for
/// the same reason: `Library/Caches` is meaningless on a Linux host and
/// `.local/share/Trash` is meaningless on a Mac, so carrying either into
/// the other's argv is noise in the run log and in `excludes show`.
///
/// There is no `windows` case because Restic Station has no Windows build,
/// and a scope that can never activate is dead weight. The *useful* half of
/// Code42's `win:` rules is the debris Windows leaves on removable and
/// network media — `Thumbs.db`, `desktop.ini`, `System Volume Information`
/// — and that is scoped ``any`` precisely because it turns up on a Mac or
/// Linux host with an NTFS drive attached.
public enum GlobalExcludePlatform: String, Equatable, Sendable, CaseIterable, Codable {
    case macOS
    case linux

    /// The platform this process is running on, which is the one whose
    /// patterns the catalogue resolves to.
    ///
    /// This is the **only** OS branch in the exclusion machinery, and it is
    /// legitimate where config resolution's would not be: the catalogue is
    /// host-local by construction (`docs/data-model.md`
    /// §global-excludes.json), unlike `AppConfig.resolved(for:)`, which must
    /// return the same bytes for a given `machineId` on either OS.
    public static var current: GlobalExcludePlatform {
        #if os(macOS)
        return .macOS
        #else
        return .linux
        #endif
    }
}

// MARK: - GlobalExcludePattern

/// One catalogue pattern and the platforms it applies on.
///
/// Written as a bare string literal in the catalogue when it applies
/// everywhere, and as ``mac(_:)`` or ``linux(_:)`` when it does not — which
/// keeps the catalogue readable as a list of patterns rather than a list of
/// structs.
public struct GlobalExcludePattern: Equatable, Sendable, ExpressibleByStringLiteral {
    public let pattern: String
    public let platforms: Set<GlobalExcludePlatform>
    /// Whether this pattern names a *cloud placeholder* rather than a file
    /// with contents — a stub a sync client leaves behind for something it
    /// has evicted.
    ///
    /// Such a pattern is skipped for a set whose
    /// ``BackupSet/onlineOnlyFiles`` is ``BackupSet/OnlineOnlyFiles/download``.
    /// That policy exists to say "materialise the evicted files, I want the
    /// real contents in the snapshot"; dropping the placeholders under it
    /// would remove the only filesystem record those files exist while the
    /// operator believes the snapshot is complete. Every other set still
    /// skips them, which is the whole point of the pattern.
    public let isCloudPlaceholder: Bool

    public init(
        _ pattern: String,
        platforms: Set<GlobalExcludePlatform> = Set(GlobalExcludePlatform.allCases),
        isCloudPlaceholder: Bool = false
    ) {
        self.pattern = pattern
        self.platforms = platforms
        self.isCloudPlaceholder = isCloudPlaceholder
    }

    /// A bare string in the catalogue means "every platform".
    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// A path shape that only exists on macOS — `Library/…`, an Apple media
    /// bundle's internals, an Xcode directory.
    public static func mac(_ pattern: String) -> GlobalExcludePattern {
        GlobalExcludePattern(pattern, platforms: [.macOS])
    }

    /// A path shape that only exists on Linux — XDG directories, the
    /// Linux-only spellings of the browser and container profile roots.
    public static func linux(_ pattern: String) -> GlobalExcludePattern {
        GlobalExcludePattern(pattern, platforms: [.linux])
    }

    /// A stub left behind for an evicted cloud file, which a set that has
    /// asked to download online-only files must keep. See
    /// ``isCloudPlaceholder``.
    public static func cloudPlaceholder(_ pattern: String) -> GlobalExcludePattern {
        GlobalExcludePattern(pattern, isCloudPlaceholder: true)
    }

    public func applies(on platform: GlobalExcludePlatform) -> Bool {
        platforms.contains(platform)
    }
}

// MARK: - GlobalExcludeGroup

/// One named block of built-in exclusion patterns.
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
    /// Every pattern in the group, across all platforms, in the order they
    /// reach argv. Use ``patterns(on:)`` for the ones that apply here.
    public let patterns: [GlobalExcludePattern]

    public init(
        id: String,
        title: String,
        summary: String,
        enabledByDefault: Bool = true,
        patterns: [GlobalExcludePattern]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.enabledByDefault = enabledByDefault
        self.patterns = patterns
    }

    /// The group's patterns for one platform, in catalogue order.
    public func patterns(on platform: GlobalExcludePlatform) -> [String] {
        patterns.filter { $0.applies(on: platform) }.map(\.pattern)
    }
}

// MARK: - GlobalExcludeCatalog

/// The built-in exclusion list, compiled into the binary rather than seeded
/// into a file on first run.
///
/// **Why compiled in.** A seeded file goes stale the moment a build learns
/// about a new build system, and every host would then need a migration to
/// pick the improvement up. Shipping the catalogue in code means an upgrade
/// improves the defaults everywhere, and `global-excludes.json` stays what
/// it should be: the short list of decisions *this host* made that differ
/// from the defaults.
///
/// **Every pattern here is relative and unanchored.** No leading `/`, no
/// `~`, no `$VAR`. restic matches a relative pattern against the trailing
/// path components, so `Library/Caches` skips `~/Library/Caches` wherever
/// the home directory is, and `node_modules` skips one at any depth. A `*`
/// inside a component matches exactly one component
/// (`bin/*/Debug` reaches `bin/x64/Debug` but not `bin/Debug`), and `**`
/// spans several (`*.imovielibrary/**/Render Files`).
///
/// **The hazard that shapes the whole list: an unanchored pattern matches
/// any component of the *absolute* path, including directories above the
/// source.** `--exclude tmp` against a source under `/tmp/...` excludes the
/// source itself and produces an empty snapshot. So a single-component
/// pattern must name something nobody has above their data — `node_modules`
/// is safe, `tmp`, `var`, `data` and `bin` are not.
/// ``GlobalExcludeCatalogTests`` pins both that denylist and the shape rule.
///
/// **Patterns are scoped by platform** (``GlobalExcludePattern``), the way
/// Code42's `mac:`/`linux:` prefixes are. The rule applied here is narrow:
/// a pattern is scoped only when its *path shape* cannot exist on the other
/// platform — `Library/…` and Apple bundle internals are `.mac`, XDG
/// directories and the Linux browser roots are `.linux`. Anything that is a
/// *file or directory name* rather than a home-directory layout stays
/// unscoped, because it can turn up on either host: `.DS_Store` on a Samba
/// share, `Thumbs.db` on an attached NTFS drive, `node_modules` anywhere.
///
/// The residual cost is stated plainly: a Linux host backing up a *Mac's*
/// home directory over a mount does not get the `.mac` patterns. That is
/// rare, visible in `excludes show`, and fixable with `excludes add`.
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
    /// build knows a newer catalogue than the one you last saved against",
    /// and so a support question about a surprising exclusion has a version
    /// to quote. It is **not** a compatibility gate: a group this build has
    /// never heard of is an error (see ``GlobalExcludeError/unknownGroup``),
    /// and a group added after the file was written takes its built-in
    /// default.
    public static let version = 11

    /// The catalogue, in the order its patterns reach argv.
    public static let groups: [GlobalExcludeGroup] = [
        GlobalExcludeGroup(
            id: "browser-caches",
            title: "Browser caches",
            summary: "Cached pages, images, compiled scripts and GPU shaders that every browser "
                + "refetches or rebuilds on demand. Bookmarks, history, passwords and profile "
                + "settings are not here and are still backed up.",
            patterns: [
                // Per-user cache roots. Same browsers, different layouts.
                .mac("Library/Caches/Google/Chrome"),
                .mac("Library/Caches/Chromium"),
                .mac("Library/Caches/BraveSoftware"),
                .mac("Library/Caches/Microsoft Edge"),
                .mac("Library/Caches/com.microsoft.edgemac"),
                .mac("Library/Caches/com.apple.Safari"),
                .mac("Library/Caches/Firefox"),
                .mac("Library/Caches/com.operasoftware.Opera"),
                .linux(".cache/google-chrome"),
                .linux(".cache/chromium"),
                .linux(".cache/microsoft-edge"),
                .linux(".cache/BraveSoftware"),
                .linux(".cache/mozilla"),
                .linux(".cache/opera"),
                .linux(".cache/vivaldi"),
                // Caches that live *inside* the profile directory, so they
                // are not covered by the roots above. These names are also
                // what every Electron app uses, which is deliberate — and
                // they are identical on both platforms.
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
                .mac("Library/Caches"),
                .mac("Library/Logs"),
                .mac("Library/Saved Application State"),
                .mac("Library/Application Support/CrashReporter"),
                .mac("Library/Metadata/CoreSpotlight"),
                .mac("Library/Application Support/Google/DriveFS"),
                .linux(".cache"),
                .linux(".local/share/Trash"),
                // Volume-level debris, deliberately unscoped: all of it
                // travels on removable and network media, so a Linux host
                // backing up a Mac-formatted drive still wants it gone, and
                // a Mac with an NTFS drive attached wants the Windows half.
                ".Trash",
                ".Trashes",
                ".Spotlight-V100",
                ".fseventsd",
                ".TemporaryItems",
                ".apdisk",
                ".hotfiles.btree",
                ".PKInstallSandboxManager-SystemSoftware",
                "Network Trash Folder",
                "Desktop DB",
                "Desktop DF",
                ".DS_Store",
                "Thumbs.db",
                "desktop.ini",
                "System Volume Information",
                // Zero-byte iCloud placeholders. `--exclude-cloud-files`
                // (restic 0.19+) is the real answer; this catches the same
                // files on an older restic, where they would otherwise be
                // backed up as empty stubs. Marked as a placeholder so a set
                // that has asked to *download* its online-only files keeps
                // them: under that policy the stub is the only record the
                // file exists at all.
                .cloudPlaceholder("*.icloud"),
                // Backing up a backup.
                "backups.backupdb",
                ".MobileBackups",
                // Sync clients' own scratch, which is re-downloaded.
                ".dropbox.cache",
                ".adobeTemp",
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
                // Swift / Xcode. `.build` is SwiftPM and exists on Linux
                // too; the rest are Xcode-shaped.
                ".build",
                .mac("DerivedData"),
                .mac("Library/Developer/Xcode/DerivedData"),
                .mac("Library/Developer/Xcode/iOS DeviceSupport"),
                .mac("Library/Developer/CoreSimulator/Caches"),
                // **Not** a bare `xcuserdata`. That directory holds a
                // developer's own schemes and breakpoint lists — unshared,
                // authored, and not reproducible from the source tree. Only
                // the window-state blob inside it is generated.
                // Unscoped, unlike the `Library/…` Xcode paths above: this
                // is a file *name*, not a macOS home-directory layout, so it
                // turns up on a Linux host with a Mac project mounted. The
                // platform-scoping test enforces that distinction.
                "UserInterfaceState.xcuserstate",
                // **Not** a bare `Pods`. A single-component pattern is
                // matched against every component of the absolute path, and
                // "Pods" is an ordinary English word — a folder of podcast
                // assets, or Kubernetes material, sitting above a source
                // would empty that source's snapshot entirely. Only the
                // parts CocoaPods generates are named; the vendored pod
                // sources come back from `pod install` but are left in the
                // snapshot rather than risking the ancestor match.
                .mac("Pods/Pods.xcodeproj"),
                .mac("Pods/Target Support Files"),
                .mac("Pods/Headers"),
                // Rust and .NET. Deliberately never a bare `target`, `bin`
                // or `obj` — those would also skip a directory of 3-D
                // models, or a folder someone named "target", or (worse) a
                // directory *above* the source. The configuration name
                // underneath them is what makes the pattern safe, and the
                // `*/` variants reach the architecture-qualified layouts
                // (`bin/x64/Debug`, `target/<triple>/release`) that the
                // two-component form alone misses.
                "target/debug",
                "target/release",
                "target/*/debug",
                "target/*/release",
                "target/classes",
                "bin/Debug",
                "bin/Release",
                "bin/*/Debug",
                "bin/*/Release",
                "obj/Debug",
                "obj/Release",
                "obj/*/Debug",
                "obj/*/Release",
                // **Not** a bare `.vs`. For Open Folder and CMake
                // workspaces that directory also holds `launch.vs.json` and
                // `tasks.vs.json` — authored debugging and task settings no
                // build reproduces. Only the generated databases and
                // indexes are named.
                // Only the two genuinely generated stores. The version
                // directories (`.vs/<solution>/v17/…`) hold `.suo`, which is
                // a developer's breakpoints, watch windows and debugging
                // options — user state, not a build product — so neither
                // they nor a bare `*.suo` belong in a default-on group.
                ".vs/ProjectEvaluation",
                ".vs/FileContentIndex",
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
                // **Not** a bare `.wrangler`. `.wrangler/state` holds local
                // D1 databases and KV/R2 development data, which can be the
                // only copy of something someone built by hand.
                ".wrangler/tmp",
                ".wrangler/deploy",
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
                //
                // **Not a bare `.gradle`.** That name is a project's build
                // directory *and* the Gradle user home, where
                // `gradle.properties` and `init.d/` hold repository
                // credentials, signing settings and init scripts someone
                // wrote by hand. No build recreates those. The per-project
                // scratch is named directly instead, and the user home's
                // genuinely regenerable halves live in
                // `package-manager-caches`.
                ".gradle/buildOutputCleanup",
                ".gradle/configuration-cache",
                ".gradle/checksums",
                ".gradle/vcs-1",
                "cmake-build-debug",
                "cmake-build-release",
                "CMakeFiles",
                ".dart_tool",
                ".expo",
                ".stack-work",
                "dist-newstyle",
                // **Not** a bare `.terraform`. `.terraform/environment`
                // records the selected workspace and
                // `.terraform/terraform.tfstate` the local backend metadata;
                // neither is derivable from the checked-in configuration
                // when the backend was configured from outside it. Only the
                // downloads are named.
                ".terraform/providers",
                ".terraform/modules",
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
                ".gradle/caches",
                // The rest of the Gradle user home that a re-download or a
                // re-run rebuilds. `gradle.properties`, `init.d/` and
                // `init.gradle` are deliberately absent: see the note in
                // `developer-build-artifacts`.
                ".gradle/daemon",
                ".gradle/native",
                ".gradle/jdks",
                ".gradle/wrapper/dists",
                ".m2/repository",
                ".ivy2/cache",
                ".nuget/packages",
                ".pub-cache",
                ".composer/cache",
                ".gem/cache",
                "vendor/bundle",
                // Tools that use XDG on both platforms stay unscoped; the
                // ones macOS relocates under `Library/Caches` are paired.
                ".cache/huggingface",
                .mac("Library/Caches/Homebrew"),
                .linux(".cache/Homebrew"),
                .mac("Library/Caches/pip"),
                .linux(".cache/pip"),
                .mac("Library/Caches/go-build"),
                .linux(".cache/go-build"),
                .mac("Library/Caches/ms-playwright"),
                .linux(".cache/ms-playwright"),
                .mac("Library/Caches/CocoaPods"),
            ]
        ),
        GlobalExcludeGroup(
            id: "media-app-caches",
            title: "Photo and video app caches",
            summary: "Thumbnails, previews, render and analysis files that Photos, Lightroom, "
                + "Final Cut and iTunes rebuild from the originals. The originals themselves, and "
                + "each library's own database, are still backed up.",
            patterns: [
                // Bundle-internal paths, not home-directory layout, so they
                // stay unscoped: a Linux host may well be backing up the
                // library from a NAS share.
                //
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
            summary: "Docker, OrbStack, colima and podman machine data — routinely tens of "
                + "gigabytes. Off by default: these roots hold named volumes and writable "
                + "container state as well as images, and a database living in a volume exists "
                + "nowhere else. Turn it on with `excludes enable container-engines` once you "
                + "know your volumes are backed up another way.",
            enabledByDefault: false,
            patterns: [
                .mac("Library/Containers/com.docker.docker/Data"),
                .mac("Library/Group Containers/group.com.docker"),
                .mac(".orbstack/data"),
                .mac(".colima"),
                .mac(".lima"),
                .linux(".local/share/containers"),
                .linux(".local/share/docker"),
                ".docker/desktop",
                ".docker/machine",
            ]
        ),
        GlobalExcludeGroup(
            id: "game-and-media-caches",
            title: "Game and media server caches",
            summary: "A game launcher's download staging and shader caches, and a media server's "
                + "transcoder cache. Every byte is re-downloaded or regenerated on demand, and "
                + "nothing here is an installed game, a save, a mod or artwork anyone uploaded.",
            patterns: [
                "Steam/steamapps/downloading",
                "Steam/steamapps/shadercache",
                "Steam/appcache",
                "Plex Media Server/Cache",
            ]
        ),
        GlobalExcludeGroup(
            id: "game-and-media-libraries",
            title: "Game installs and media server libraries",
            summary: "Steam, Epic, GOG and Battle.net installation roots, and a Plex server's "
                + "metadata and media stores — routinely the largest thing on the disk. Off by "
                + "default: games keep saves, configuration and hand-installed mods beside the "
                + "executable, and a poster or background uploaded through Plex lives in its "
                + "metadata store and exists nowhere else. Neither comes back from a re-download "
                + "or a re-scan. Turn it on with `excludes enable game-and-media-libraries`.",
            enabledByDefault: false,
            patterns: [
                "Steam/steamapps/common",
                "Epic Games",
                "GOG Galaxy/Games",
                "Battle.net",
                // Plex's own stores, not caches. `Metadata` holds the bundle
                // for every library item, including artwork an operator
                // uploaded through Plex rather than filing beside the media;
                // `Media` holds the binary blobs those bundles point at. A
                // re-scan rebuilds what it derived from the media files and
                // silently cannot rebuild the rest.
                "Plex Media Server/Media",
                "Plex Media Server/Metadata",
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
                .mac("Library/Application Support/VirtualBox"),
                .linux(".config/VirtualBox"),
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
    ]

    /// Catalogue lookup by ``GlobalExcludeGroup/id``.
    public static func group(id: String) -> GlobalExcludeGroup? {
        groups.first { $0.id == id }
    }

    /// Every known group id, in catalogue order.
    public static var groupIDs: [String] {
        groups.map(\.id)
    }
}

// MARK: - Ancestor safety

/// Whether an unanchored catalogue pattern would match a backup source
/// itself, or any directory *above* it.
///
/// **The hazard this closes, once, for every pattern.** restic matches a
/// relative pattern against the trailing components of each item's
/// *absolute* path, and it applies that test to the source root too. A
/// source at `/srv/project.tmp/work` backed up with `--iexclude '*.tmp'`
/// therefore produces an empty snapshot — verified against restic 0.18.1:
/// `total_files_processed: 0`, with the listing stopping at `project.tmp`.
///
/// The catalogue used to guard this by *naming* — first a denylist of
/// dangerous words, then an allowlist that exempted anything containing a
/// glob. Both were judgements about which names a person might give a
/// directory, and both were wrong: the denylist missed `Pods`, and the
/// allowlist missed that `*.tmp` matches a directory called `project.tmp`
/// just as happily as a file called `draft.tmp`. A judgement about
/// third-party directory layouts cannot be made exhaustive, so this stops
/// being a judgement: the engine checks each source's own path and drops
/// any pattern that would swallow it.
///
/// Dropping is the safe direction — the set backs up *more* than the
/// catalogue intended, never less — and the run log names every pattern
/// held back, so a surprisingly large backup is explainable.
enum GlobalExcludeAncestorSafety {
    /// - Parameter caseInsensitive: `true` for the catalogue, which reaches
    ///   restic as `--iexclude`; `false` for this host's own patterns,
    ///   which ride the case-sensitive `--exclude`.
    static func matchesSourceOrAncestor(
        pattern: String,
        sourcePath: String,
        caseInsensitive: Bool
    ) -> Bool {
        let patternParts = pattern.split(separator: "/").map(String.init)
        guard !patternParts.isEmpty else { return false }
        let sourceParts = sourcePath.split(separator: "/").map(String.init)
        guard !sourceParts.isEmpty else { return false }

        // Every ancestor of the source, and the source itself — `/srv`,
        // `/srv/project.tmp`, `/srv/project.tmp/work` — against every
        // trailing run of components, because a relative pattern is matched
        // against the trailing components of a path.
        for end in 1...sourceParts.count {
            for start in 0..<end {
                if consumes(
                    patternParts, Array(sourceParts[start..<end]),
                    caseInsensitive: caseInsensitive
                ) {
                    return true
                }
            }
        }
        return false
    }

    /// Whether `patternParts` matches `pathParts` exactly, with `**`
    /// spanning **zero or more** components.
    ///
    /// The first version of this guard split the pattern into a fixed
    /// number of parts and matched each against exactly one component,
    /// which quietly treated `**` as `*`. The catalogue really does use
    /// `**` — `*.imovielibrary/**/Render Files` — so a source below
    /// `…/Movie.imovielibrary/Event/Sub/Render Files/work` was not detected
    /// and the pattern still reached restic, which would have emptied that
    /// snapshot: precisely the hazard this guard exists to remove.
    private static func consumes(
        _ patternParts: [String],
        _ pathParts: [String],
        caseInsensitive: Bool
    ) -> Bool {
        guard let head = patternParts.first else { return pathParts.isEmpty }
        let restPattern = Array(patternParts.dropFirst())
        if head == "**" {
            // Zero components, then one, then two…
            for consumed in 0...pathParts.count {
                if consumes(
                    restPattern, Array(pathParts.dropFirst(consumed)),
                    caseInsensitive: caseInsensitive
                ) {
                    return true
                }
            }
            return false
        }
        guard let first = pathParts.first,
              glob(head, matches: first, caseInsensitive: caseInsensitive)
        else { return false }
        return consumes(
            restPattern, Array(pathParts.dropFirst()), caseInsensitive: caseInsensitive
        )
    }

    /// One path component against one pattern component. `*` and `?` do not
    /// cross a separator, which is already true here because both sides are
    /// single components, and `FNM_PATHNAME` keeps it true for a `*` that
    /// would otherwise span one.
    private static func glob(_ pattern: String, matches value: String, caseInsensitive: Bool) -> Bool {
        let left = caseInsensitive ? pattern.lowercased() : pattern
        let right = caseInsensitive ? value.lowercased() : value
        return left.withCString { patternC in
            right.withCString { valueC in
                fnmatch(patternC, valueC, FNM_PATHNAME) == 0
            }
        }
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
    /// Catalogue patterns, handed to every applying set as **`--iexclude`**,
    /// in catalogue order.
    ///
    /// Case-insensitive because this list is a set of well-known names
    /// rather than something a person typed: `Library/Caches` should also
    /// skip `library/caches`.
    public let patterns: [String]
    /// Catalogue patterns that name a *cloud placeholder* rather than a file
    /// with contents, also handed over as **`--iexclude`** — but only to a
    /// set that is not downloading its online-only files.
    ///
    /// Kept out of ``patterns`` rather than filtered back out of it at the
    /// call site, so a set's policy decides whether they apply and no caller
    /// can apply them by forgetting to ask. See
    /// ``GlobalExcludePattern/isCloudPlaceholder``.
    public let cloudPlaceholderPatterns: [String]
    /// This host's own ``GlobalExcludeSettings/extraPatterns``, handed over
    /// as **`--exclude`** — case-sensitive.
    ///
    /// Kept separate from ``patterns`` rather than merged into it, because
    /// provenance decides the matching rule. `excludes add` documents these
    /// as ordinary restic `--exclude` patterns, so folding them into the
    /// catalogue's `--iexclude` block would make `*.TMP` also drop
    /// `draft.tmp` — silently excluding more than the operator asked for,
    /// which is the direction that loses data.
    public let hostPatterns: [String]
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

    public init(
        patterns: [String],
        cloudPlaceholderPatterns: [String] = [],
        hostPatterns: [String] = [],
        excludeCaches: Bool,
        excludeLargerThan: String? = nil
    ) {
        self.patterns = patterns
        self.cloudPlaceholderPatterns = cloudPlaceholderPatterns
        self.hostPatterns = hostPatterns
        self.excludeCaches = excludeCaches
        self.excludeLargerThan = excludeLargerThan
    }

    /// Adds nothing to any backup — the value every construction site that
    /// has not loaded settings uses, so forgetting to wire the plan through
    /// can only ever back up *more* than intended, never less.
    public static let none = GlobalExcludePlan(patterns: [], excludeCaches: false)

    public var isEmpty: Bool {
        patterns.isEmpty && cloudPlaceholderPatterns.isEmpty && hostPatterns.isEmpty
            && !excludeCaches && excludeLargerThan == nil
    }

    /// Every pattern the plan contributes, in argv order, for logging and
    /// for reports that do not care which flag carries which.
    ///
    /// Includes ``cloudPlaceholderPatterns``, which most sets do apply; the
    /// one that has opted into downloading its online-only files gets a
    /// shorter list, and its run log says so.
    public var allPatterns: [String] {
        patterns + cloudPlaceholderPatterns + hostPatterns
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

    /// The enabled groups, in catalogue order.
    public var enabledGroups: [GlobalExcludeGroup] {
        GlobalExcludeCatalog.groups.filter(isEnabled)
    }

    /// Resolves to the value the engine consumes, for one platform.
    /// Deduplicated with first-occurrence order preserved, the same rule
    /// ``BackupSet/effectiveBackupExcludes`` uses.
    ///
    /// The platform is a parameter rather than a lookup so the resolution
    /// is testable for both from either, and defaults to
    /// ``GlobalExcludePlatform/current`` because the only caller that
    /// matters — the helper, about to run a backup — is resolving for the
    /// host it is running on. `extraPatterns` are never platform-scoped:
    /// this host typed them, on this host.
    public func plan(on platform: GlobalExcludePlatform = .current) -> GlobalExcludePlan {
        guard enabled else { return .none }
        var seen = Set<String>()
        let applicable = enabledGroups
            .flatMap { $0.patterns }
            .filter { $0.applies(on: platform) && seen.insert($0.pattern).inserted }
        let catalogue = applicable.filter { !$0.isCloudPlaceholder }.map(\.pattern)
        let placeholders = applicable.filter(\.isCloudPlaceholder).map(\.pattern)
        // `extraPatterns` are deduplicated **only against each other**, in
        // their own `seen` set.
        //
        // Sharing the catalogue's set silently dropped a host pattern whose
        // text a catalogue entry already used — and the two are not the same
        // rule, because they ride different flags. The case that makes it
        // concrete: `excludes add '*.icloud'` on a host with a set using
        // `onlineOnlyFiles: "download"`. The catalogue's copy is held back
        // for that set on purpose, and if the host's copy had been dropped
        // as a duplicate, *nothing* would reach restic — an operator's
        // explicit instruction quietly lost.
        var hostSeen = Set<String>()
        let host = extraPatterns.filter { hostSeen.insert($0).inserted }
        return GlobalExcludePlan(
            patterns: catalogue,
            cloudPlaceholderPatterns: placeholders,
            hostPatterns: host,
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
    /// The file changed underneath an editor that had already loaded it.
    ///
    /// Refused rather than overwritten because the losing write is silently
    /// destructive in the dangerous direction: the edit most worth keeping
    /// is a *disabled* group, and clobbering it re-enables that group, so
    /// every later backup skips paths the operator had deliberately
    /// protected.
    case staleWrite(path: String)
    /// The file exists but could not be read or decoded. Deliberately fatal
    /// rather than "fall back to the defaults": the defaults exclude *more*
    /// than a host that had turned groups off, so guessing here silently
    /// stops backing up directories someone had deliberately kept.
    ///
    /// ``underlying`` is a foreign, unbounded string — a `DecodingError`'s
    /// description, whose macOS spelling is far longer than Linux's — so it
    /// goes **last** in the rendered message. `CLIFailure` caps a message at
    /// 500 characters, and the reason for the refusal has to be the part
    /// that survives the cap; putting it after the dump meant macOS
    /// truncated away the only sentence that explained the failure.
    case unreadable(path: String, underlying: String)
    /// Another process holds the write lock. Refused rather than waited out
    /// for the same reason `config.json` refuses: the caller is a person at
    /// a terminal or a Settings pane, and "try that again" is a better
    /// answer than an edit that blocks for an unbounded time.
    case writeLockBusy(path: String)
    /// The write lock itself could not be taken — an unwritable `locks/`,
    /// a symlink planted at the lock path, a lock file owned by someone
    /// else. Never treated as "no contention, go ahead": without the lock
    /// the compare-and-swap below is not atomic with the rename it guards.
    case writeLockUnusable(String)

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
        case .staleWrite(let path):
            return "refusing to overwrite \(path): it changed since this editor loaded it, and "
                + "saving now would silently discard that change — reload and reapply your edit"
        case .unreadable(let path, let underlying):
            // Reason first, then BOTH externally sized strings. `path` is
            // unbounded too — a deeply nested `RESTIC_STATION_DATA_DIR` can
            // blow the 500-character `CLIFailure` cap on its own — so it
            // cannot sit between the reason and the start of the message.
            return "global-excludes.json is unreadable and this build will not fall back to the "
                + "built-in defaults, which may exclude more than this host had configured — fix "
                + "or remove the file. Path: \(path). Underlying error: \(underlying)"
        case .writeLockBusy(let path):
            return "another Restic Station process is editing the global exclusion list right now "
                + "(\(path)) — try again"
        case .writeLockUnusable(let failure):
            return "refusing to write global-excludes.json: its write lock is unusable, so a "
                + "concurrent edit could not be detected — \(failure)"
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
        try loadFingerprinted().settings
    }

    /// The settings plus the fingerprint of the bytes they were decoded
    /// from, for an editor that intends to write them back.
    ///
    /// `nil` fingerprint means "no file was there". Pass the whole thing to
    /// ``save(_:ifUnchangedFrom:)`` and a concurrent edit is refused rather
    /// than silently overwritten.
    public func loadFingerprinted() throws -> (settings: GlobalExcludeSettings, fingerprint: String?) {
        do {
            guard try Self.entryExists(at: paths.globalExcludesFile) else {
                return (.default, nil)
            }
        } catch {
            throw GlobalExcludeError.unreadable(
                path: paths.globalExcludesFile.path,
                underlying: "\(error)"
            )
        }
        let settings: GlobalExcludeSettings
        let data: Data
        do {
            data = try Self.readRegularFile(at: paths.globalExcludesFile)
            settings = try ConfigStore.makeDecoder().decode(GlobalExcludeSettings.self, from: data)
        } catch {
            throw GlobalExcludeError.unreadable(
                path: paths.globalExcludesFile.path,
                underlying: "\(error)"
            )
        }
        try settings.validate()
        return (settings, Self.fingerprint(of: data))
    }

    /// Reads the settings file, refusing anything that is not a plain
    /// regular file **without ever blocking on it**.
    ///
    /// `Data(contentsOf:)` opens the path with no `O_NONBLOCK`, so a FIFO —
    /// or a symlink to one — parked at `global-excludes.json` blocks the
    /// open until some writer appears. That is worse than any decode error:
    /// this read happens while the helper builds its context for *every*
    /// command, so an emergency `restore` would hang indefinitely, and the
    /// failure could not even be captured as a value because control never
    /// returns. The backup-only contract has to survive a hostile file
    /// type, not just malformed contents.
    ///
    /// `O_NONBLOCK` makes the open return immediately for a FIFO, and
    /// `fstat` on the descriptor we hold — not a second look at the path —
    /// rejects everything that is not `S_IFREG`, so there is no window in
    /// which the thing checked and the thing read could differ.
    /// The largest `global-excludes.json` this build will read. Generous
    /// beyond any real file — the default settings encode to a few hundred
    /// bytes, and a host with a thousand extra patterns would not reach
    /// 100 KB — and present only so an accident cannot become an
    /// out-of-memory on a command that never consumes the file.
    static let maximumSettingsFileSize: off_t = 4 * 1024 * 1024

    static func readRegularFile(at url: URL) throws -> Data {
        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        let descriptor = url.path.withCString { open($0, flags) }
        guard descriptor >= 0 else {
            throw LockFailure(path: url.path, operation: "open", errnoValue: errno)
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw LockFailure(path: url.path, operation: "fstat", errnoValue: errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw LockFailure(path: url.path, operation: "regular-file check", errnoValue: 0)
        }
        // `O_NONBLOCK` does nothing for a regular file, so a settings path
        // accidentally replaced by a multi-gigabyte file would be read into
        // memory in full — by every command, before any of them dispatches.
        // The size is already in hand from the `fstat` above, so the refusal
        // costs nothing. A settings file is a few hundred bytes; the cap is
        // four orders of magnitude above anything legitimate.
        guard info.st_size <= Self.maximumSettingsFileSize else {
            throw LockFailure(path: url.path, operation: "size check", errnoValue: 0)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw LockFailure(path: url.path, operation: "read", errnoValue: errno)
            }
            if count == 0 { break }
            // Enforced as the bytes arrive, not only by the `fstat` above:
            // another process can append after that check, and a fast
            // enough writer would otherwise keep this loop — and every
            // command waiting behind it — going indefinitely.
            guard data.count + count <= Int(Self.maximumSettingsFileSize) else {
                throw LockFailure(path: url.path, operation: "size check", errnoValue: 0)
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// Whether the settings path has a directory entry of its own.
    ///
    /// `lstat`, not `FileManager.fileExists(atPath:)`, because that follows
    /// symlinks: a **dangling** symlink at `global-excludes.json` — a
    /// managed target that is temporarily absent, a broken deployment — has
    /// an entry but no target, so `fileExists` answers `false` and the
    /// settings silently read as ``GlobalExcludeSettings/default``.
    ///
    /// That is the fail-closed hole this whole file exists to avoid, in its
    /// most dangerous direction: a host whose unavailable settings had a
    /// group *disabled* would pick the built-in default back up, and the
    /// next backup would skip paths the operator had deliberately kept.
    /// With the entry seen, the read that follows fails and the error says
    /// so (`docs/data-model.md` §global-excludes.json).
    /// - Throws: when the probe itself fails for any reason other than the
    ///   two that genuinely mean "nothing is there". `EACCES` on a parent
    ///   directory, `EIO` from failing storage or `ELOOP` from a symlink
    ///   cycle all used to answer `false`, which is the documented *absent*
    ///   state — so the host silently fell back to the built-in defaults and
    ///   re-enabled every group its unreadable settings had turned off. Only
    ///   `ENOENT` and `ENOTDIR` mean absent; everything else fails closed.
    static func entryExists(at url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) != 0 else { return true }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return false }
        throw LockFailure(path: url.path, operation: "lstat", errnoValue: code)
    }

    /// The byte fingerprint of whatever is on disk right now, or `nil` when
    /// the file is absent. Deliberately over the raw bytes rather than the
    /// decoded value: a rewrite that decodes identically still means another
    /// writer was here.
    ///
    /// **Not** the value to pass to ``save(_:ifUnchangedFrom:)``. That has
    /// to be the fingerprint the caller *loaded*, from
    /// ``loadFingerprinted()`` or from the previous save's return value;
    /// reading it here instead compares the file against itself and lets
    /// the save overwrite whatever landed since. This exists for a caller
    /// that wants to observe the file, and for the check inside the lock.
    public func currentFingerprint() -> String? {
        try? strictFingerprint()
    }

    /// The same answer, but with "there is no file" and "there is an entry I
    /// cannot read" kept apart.
    ///
    /// The lenient version collapses both to `nil`, which is safe to *read*
    /// and unsafe to compare against: a pane that failed to load a dangling
    /// symlink holds the `nil` fingerprint it started with, and a `nil ==
    /// nil` comparison would let its defaults-based value rename itself over
    /// that entry — re-enabling every group the unavailable settings had
    /// turned off. The compare-and-swap uses this one, so an unreadable
    /// entry refuses instead of matching.
    private func strictFingerprint() throws -> String? {
        let present: Bool
        do {
            present = try Self.entryExists(at: paths.globalExcludesFile)
        } catch {
            throw GlobalExcludeError.unreadable(
                path: paths.globalExcludesFile.path,
                underlying: "\(error)"
            )
        }
        guard present else { return nil }
        let data: Data
        do {
            data = try Self.readRegularFile(at: paths.globalExcludesFile)
        } catch {
            throw GlobalExcludeError.unreadable(
                path: paths.globalExcludesFile.path,
                underlying: "\(error)"
            )
        }
        return Self.fingerprint(of: data)
    }

    static func fingerprint(of data: Data) -> String {
        // Length plus a cheap order-dependent rolling hash. This only has to
        // detect "someone else wrote here", not resist forgery: the file is
        // owner-only host-local state, not a security boundary.
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "\(data.count)-\(String(hash, radix: 16))"
    }

    /// Validates, then writes atomically (temp file + `rename(2)`), creating
    /// the data directory if needed. `catalogVersion` is stamped with the
    /// catalog this build carries, since that is what the decisions in the
    /// written file were made against.
    ///
    /// This overload replaces whatever is already there — still atomically
    /// and still under the write lock, but with **no** compare-and-swap.
    ///
    /// For a caller that is *declaring* the contents rather than editing a
    /// value it loaded: a test fixture, a first-run seed, an import.
    /// Anything that read the file first must call
    /// ``save(_:ifUnchangedFrom:)`` with the fingerprint
    /// ``loadFingerprinted()`` returned. Re-reading the file here to supply
    /// its own "expected" value would make the check vacuous — it would
    /// compare the file against itself as of this instant and happily
    /// overwrite an edit made since the load, which is the lost update the
    /// compare-and-swap exists to prevent.
    @discardableResult
    public func save(_ settings: GlobalExcludeSettings) throws -> String {
        try withWriteLock { try writeLocked(settings, precondition: .overwrite) }
    }

    /// Compare-and-swap: writes only if the on-disk bytes still fingerprint
    /// to `expected`, the value ``loadFingerprinted()`` returned.
    ///
    /// The same rule `config.json` saves already follow, and for a sharper
    /// reason. The Settings pane holds this file in memory while it is open;
    /// without this, a `restic-station excludes disable …` run from a
    /// terminal is erased by the pane's next toggle — and the decision most
    /// likely to be lost is a *disabled* group, which silently re-enables
    /// it and drops paths the operator meant to keep.
    /// - Returns: the fingerprint of the bytes just written, so an editor
    ///   that stays open can hold it for its *next* save. Reading it back
    ///   from the file afterwards would be a second race: a writer that got
    ///   in between the rename and that read would hand this editor the
    ///   other process's fingerprint, and its next save would pass the check
    ///   and overwrite them.
    @discardableResult
    public func save(_ settings: GlobalExcludeSettings, ifUnchangedFrom expected: String?) throws -> String {
        try withWriteLock { try writeLocked(settings, precondition: .unchangedFrom(expected)) }
    }

    /// What ``writeLocked(_:precondition:)`` requires of the file it is
    /// about to replace. Spelled as a type rather than an optional
    /// fingerprint because `nil` already means something here — "there was
    /// no file when I loaded" — and an unconditional write must not be
    /// confused with that.
    private enum WritePrecondition {
        case overwrite
        case unchangedFrom(String?)
    }

    /// The compare-and-swap and the write it guards, both inside the lock.
    ///
    /// `.unchangedFrom(nil)` means "there was no file when I loaded", and an
    /// intervening writer is still caught: a file that exists now does not
    /// fingerprint to `nil`.
    private func writeLocked(
        _ settings: GlobalExcludeSettings,
        precondition: WritePrecondition
    ) throws -> String {
        var updated = settings
        updated.version = GlobalExcludeSettings.currentVersion
        updated.catalogVersion = GlobalExcludeCatalog.version
        try updated.validate()
        // `strictFingerprint()`, not `currentFingerprint()`: an entry that
        // exists but cannot be read throws here rather than comparing equal
        // to the `nil` an editor carries when its own load failed.
        if case .unchangedFrom(let expected) = precondition, try strictFingerprint() != expected {
            throw GlobalExcludeError.staleWrite(path: paths.globalExcludesFile.path)
        }
        let data = try ConfigStore.makeEncoder().encode(updated)
        // Durable, not merely atomic. `rename(2)` is atomic for *readers*
        // and says nothing about a power cut: without the two `fsync`s the
        // file can come back empty, come back as its previous bytes, or
        // come back as if the write never happened — and each of those
        // restores the built-in defaults, re-enabling a group the operator
        // had disabled.
        try DurableFile.write(data, to: paths.globalExcludesFile, via: tempFile)
        return Self.fingerprint(of: data)
    }

    /// Deletes `global-excludes.json`, returning to the built-in defaults.
    ///
    /// Under the same write lock as a save, for the same reason: without it
    /// a concurrent `excludes add` can rename its file into place between
    /// the existence check and the unlink, leaving a host that was told it
    /// is back on the defaults carrying an adjustment nobody meant to keep.
    ///
    /// - Returns: `false` when there was nothing to remove, which is not an
    ///   error — an absent file is the documented default state.
    @discardableResult
    public func removeSettings() throws -> Bool {
        try removeSettings(ifUnchangedFrom: nil, compare: false)
    }

    /// Removes the file only if it still fingerprints to `expected`.
    ///
    /// The lock keeps two writers from interleaving; it does not stop a
    /// *lost update*. An editor that loaded, then sat open while
    /// `excludes disable …` wrote a newly disabled group, would delete that
    /// edit outright — silently re-enabling the group and dropping the paths
    /// the other editor meant to protect. Same reasoning as
    /// ``save(_:ifUnchangedFrom:)``, and the comparison happens under the
    /// same lock as the unlink.
    @discardableResult
    public func removeSettings(ifUnchangedFrom expected: String?) throws -> Bool {
        try removeSettings(ifUnchangedFrom: expected, compare: true)
    }

    private func removeSettings(ifUnchangedFrom expected: String?, compare: Bool) throws -> Bool {
        try withWriteLock {
            if compare, try strictFingerprint() != expected {
                throw GlobalExcludeError.staleWrite(path: paths.globalExcludesFile.path)
            }
            // `entryExists`, for the same reason `loadFingerprinted()` uses
            // it: a dangling symlink is something to remove, not an absent
            // file. Reporting "already at the built-in defaults" and leaving
            // the entry there would mean the very next load refuses.
            guard try Self.entryExists(at: paths.globalExcludesFile) else {
                return false
            }
            // Durably, for the mirror-image reason: an unlink that has not
            // reached the disk lets a reboot resurrect the file this command
            // just reported removing, extra patterns and size cap included.
            try DurableFile.remove(paths.globalExcludesFile)
            return true
        }
    }

    /// Serialises the whole read-compare-write-rename sequence across
    /// processes, the way `ConfigStore` serialises a config save.
    ///
    /// Without it the compare-and-swap is not a compare-and-swap: two
    /// `excludes disable` runs can both fingerprint the same bytes, both
    /// pass, and the loser's decision is gone — and since the decision most
    /// worth keeping is a *disabled* group, losing it silently re-enables
    /// that group and every later backup skips paths someone meant to keep.
    /// The fixed `.tmp` filename is a second reason: two unsynchronised
    /// writers share it, so one can rename the other's half-written bytes
    /// into place.
    private func withWriteLock<T>(_ body: () throws -> T) throws -> T {
        try paths.ensureDirectories()
        let lock = FileLock(path: paths.globalExcludesLockFile, trustedRoot: paths.root)
        switch lock.acquire() {
        case .acquired:
            defer { lock.release() }
            return try body()
        case .busy:
            throw GlobalExcludeError.writeLockBusy(path: paths.globalExcludesLockFile.path)
        case .failed(let failure):
            throw GlobalExcludeError.writeLockUnusable("\(failure)")
        }
    }
}
