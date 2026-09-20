import ArgumentParser
import Foundation
import ResticStationCore

// MARK: - excludes

/// `excludes …` — the host-local global exclusion list.
///
/// **Never touches `config.json`.** The built-in catalogue ships in the
/// binary and the adjustments live in `global-excludes.json` beside
/// `machine.json`, so nothing here travels with a `config export`
/// (`docs/data-model.md` §global-excludes.json). The one fleet-wide half of
/// the feature — a set opting out entirely — is a `config.json` field and is
/// edited in the set editor or by hand, not here.
struct Excludes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "excludes",
        abstract: "Inspect and adjust this machine's global exclusion list — the patterns every "
            + "backup set skips unless it opts out. Host-local: never read or written by "
            + "config export/import. Exit 0 ok, 1 error.",
        subcommands: [
            ExcludesShow.self,
            ExcludesEnable.self,
            ExcludesDisable.self,
            ExcludesAdd.self,
            ExcludesRemove.self,
            ExcludesSet.self,
            ExcludesReset.self,
        ]
    )
}

// MARK: - Shared loading

/// Loads and saves `global-excludes.json` for the subcommands below,
/// classifying a file this build cannot honour as `config_invalid` — the
/// same code an unusable `config.json` produces, because it is the same kind
/// of fault: local state a human has to fix before a backup can be trusted
/// to skip exactly what was intended.
struct ExcludesCLIContext {
    let paths: AppPaths
    let store: GlobalExcludeStore

    static func make() -> ExcludesCLIContext {
        let paths = AppPaths.default()
        return ExcludesCLIContext(paths: paths, store: GlobalExcludeStore(paths: paths))
    }

    func load() throws -> GlobalExcludeSettings {
        do {
            return try store.load()
        } catch {
            throw CLIFailure.configInvalid(underlying: error)
        }
    }

    func save(_ settings: GlobalExcludeSettings) throws {
        do {
            try store.save(settings)
        } catch {
            throw CLIFailure.configInvalid(underlying: error)
        }
    }

    /// Rejects a group id this build does not have, rather than writing it
    /// and failing every later load. The available ids are listed, since a
    /// typo is the overwhelmingly likely cause.
    static func requireKnownGroup(_ id: String) throws {
        guard GlobalExcludeCatalog.group(id: id) != nil else {
            throw CLIFailure.invalidArguments(
                "\"\(id)\" is not an exclusion group in this build — available groups: "
                    + GlobalExcludeCatalog.groupIDs.joined(separator: ", ")
            )
        }
    }
}

// MARK: - excludes show

struct ExcludesShow: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print every exclusion group, whether it applies on this machine, and the "
            + "resolved pattern list. --json for scripting. Exit 0 ok, 1 error."
    )

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    @Flag(name: .long, help: "Also print every individual pattern in the human output.")
    var patterns = false

    func run() async throws {
        let context = ExcludesCLIContext.make()
        let settings = try context.load()
        let report = GlobalExcludeReport.build(
            settings: settings,
            path: context.paths.globalExcludesFile,
            exists: FileManager.default.fileExists(atPath: context.paths.globalExcludesFile.path)
        )

        if json {
            CLIJSON.print(report)
        } else {
            for line in report.humanLines(includePatterns: patterns) {
                print(line)
            }
        }
        HelperExit.code(0)
    }
}

// MARK: - excludes enable / disable

struct ExcludesEnable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Apply these exclusion groups on this machine. Exit 0 ok, 1 error."
    )

    @Argument(help: "Group ids, as `excludes show` prints them.")
    var groups: [String]

    func run() async throws {
        try await ExcludesGroupToggle.apply(groups: groups, enabled: true)
    }
}

struct ExcludesDisable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Stop applying these exclusion groups on this machine, so their paths are "
            + "backed up again. Exit 0 ok, 1 error."
    )

    @Argument(help: "Group ids, as `excludes show` prints them.")
    var groups: [String]

    func run() async throws {
        try await ExcludesGroupToggle.apply(groups: groups, enabled: false)
    }
}

/// The body `enable` and `disable` share, so the two can never drift in how
/// they validate or persist.
enum ExcludesGroupToggle {
    static func apply(groups: [String], enabled: Bool) async throws {
        guard !groups.isEmpty else {
            throw CLIFailure.invalidArguments("name at least one exclusion group")
        }
        for id in groups {
            try ExcludesCLIContext.requireKnownGroup(id)
        }
        let context = ExcludesCLIContext.make()
        var settings = try context.load()
        for id in groups {
            settings.groups[id] = enabled
        }
        try context.save(settings)
        let verb = enabled ? "applied" : "not applied"
        for id in groups {
            print("\(id): \(verb) on this machine")
        }
        HelperExit.code(0)
    }
}

// MARK: - excludes add / remove

struct ExcludesAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add this machine's own --exclude patterns, applied to every set that has not "
            + "opted out. Exit 0 ok, 1 error."
    )

    @Argument(help: "restic --exclude patterns. Unlike the built-in list these may be absolute.")
    var patterns: [String]

    func run() async throws {
        guard !patterns.isEmpty else {
            throw CLIFailure.invalidArguments("name at least one pattern")
        }
        for pattern in patterns where pattern.isEmpty {
            throw CLIFailure.invalidArguments(
                "an exclusion pattern must not be empty — a blank entry silently matches nothing"
            )
        }
        let context = ExcludesCLIContext.make()
        var settings = try context.load()
        var added: [String] = []
        for pattern in patterns where !settings.extraPatterns.contains(pattern) {
            settings.extraPatterns.append(pattern)
            added.append(pattern)
        }
        try context.save(settings)
        if added.isEmpty {
            print("no change — every pattern was already in the list")
        } else {
            for pattern in added {
                print("added \(pattern)")
            }
        }
        HelperExit.code(0)
    }
}

struct ExcludesRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove patterns this machine added. Built-in groups are turned off with "
            + "`excludes disable` instead. Exit 0 ok, 1 error."
    )

    @Argument(help: "Patterns to remove, exactly as `excludes show` prints them.")
    var patterns: [String]

    func run() async throws {
        guard !patterns.isEmpty else {
            throw CLIFailure.invalidArguments("name at least one pattern")
        }
        let context = ExcludesCLIContext.make()
        var settings = try context.load()
        // A pattern that is not there is an error rather than a silent
        // no-op: "I removed it" followed by every run still skipping the
        // directory is the exact confusion this list has to avoid.
        for pattern in patterns where !settings.extraPatterns.contains(pattern) {
            let hint = GlobalExcludeCatalog.groups.first { $0.patterns.contains(pattern) }
            throw CLIFailure.invalidArguments(
                hint.map {
                    "\"\(pattern)\" is part of the built-in group \"\($0.id)\", not a pattern this "
                        + "machine added — turn the group off with `excludes disable \($0.id)`"
                } ?? "\"\(pattern)\" is not one of this machine's own patterns"
            )
        }
        settings.extraPatterns.removeAll { patterns.contains($0) }
        try context.save(settings)
        for pattern in patterns {
            print("removed \(pattern)")
        }
        HelperExit.code(0)
    }
}

// MARK: - excludes set

struct ExcludesSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Turn the whole global list, or its CACHEDIR.TAG handling, on or off. "
            + "Exit 0 ok, 1 error."
    )

    @Option(name: .long, help: "Apply the global exclusion list on this machine at all (true/false).")
    var enabled: Bool?

    @Option(
        name: .customLong("exclude-caches"),
        help: "Pass --exclude-caches, skipping directories their own creator tagged CACHEDIR.TAG (true/false)."
    )
    var excludeCaches: Bool?

    @Option(
        name: .customLong("exclude-larger-than"),
        help: ArgumentHelp(
            "Skip files larger than this (500m, 10G, …), or \"none\" to lift the cap. Off by default.",
            discussion: "Every other rule here names a directory of regenerable things; a size cap "
                + "can drop one irreplaceable file with no pattern to point at afterwards, so it "
                + "is opt-in."
        )
    )
    var excludeLargerThan: String?

    func run() async throws {
        guard enabled != nil || excludeCaches != nil || excludeLargerThan != nil else {
            throw CLIFailure.invalidArguments(
                "pass --enabled, --exclude-caches and/or --exclude-larger-than"
            )
        }
        let context = ExcludesCLIContext.make()
        var settings = try context.load()
        if let enabled {
            settings.enabled = enabled
        }
        if let excludeCaches {
            settings.excludeCaches = excludeCaches
        }
        if let excludeLargerThan {
            // "none" rather than an empty string: an empty `--option ""` is
            // easy to produce by accident from a shell variable, and
            // "silently lifted the size cap" is the wrong thing for that to
            // mean.
            if excludeLargerThan.lowercased() == "none" {
                settings.excludeLargerThan = nil
            } else {
                guard GlobalExcludeSettings.isValidSize(excludeLargerThan) else {
                    throw CLIFailure.invalidArguments(
                        "\"\(excludeLargerThan)\" is not a size — use a number optionally followed "
                            + "by k, m, g or t (for example 500m or 10G), or \"none\" to lift the cap"
                    )
                }
                settings.excludeLargerThan = excludeLargerThan
            }
        }
        try context.save(settings)
        print("global exclusion list: \(settings.enabled ? "on" : "off")")
        print("--exclude-caches: \(settings.excludeCaches ? "on" : "off")")
        print("--exclude-larger-than: \(settings.excludeLargerThan ?? "(no cap)")")
        HelperExit.code(0)
    }
}

// MARK: - excludes reset

struct ExcludesReset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Discard this machine's adjustments and go back to the built-in defaults by "
            + "removing global-excludes.json. Exit 0 ok, 1 error."
    )

    func run() async throws {
        let context = ExcludesCLIContext.make()
        let file = context.paths.globalExcludesFile
        guard FileManager.default.fileExists(atPath: file.path) else {
            print("already at the built-in defaults — \(file.path) does not exist")
            HelperExit.code(0)
        }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw CLIFailure.configInvalid(underlying: error)
        }
        print("removed \(file.path) — back to the built-in defaults")
        HelperExit.code(0)
    }
}

// MARK: - Report

/// `excludes show`'s payload, and the source of its human rendering — one
/// value with two renderings, the same arrangement `EffectiveConfigReport`
/// uses, so the two modes cannot disagree about what applies here.
struct GlobalExcludeReport: Encodable {
    struct GroupEntry: Encodable {
        let id: String
        let title: String
        let summary: String
        /// Applies on this machine.
        let enabled: Bool
        /// What it would be with no `global-excludes.json` at all.
        let enabledByDefault: Bool
        let patterns: [String]
    }

    /// Where the adjustments live — printed because "machine level or user
    /// level" is decided by which data directory this process resolved, and
    /// the honest answer is the path.
    let path: String
    /// `false` means every value below is the built-in default.
    let exists: Bool
    let enabled: Bool
    let excludeCaches: Bool
    /// `restic backup --exclude-larger-than`, or `null` for no cap.
    let excludeLargerThan: String?
    /// The catalogue version this build carries.
    let catalogVersion: Int
    /// The catalogue version the file was last written against; `0` for a
    /// file written before the key existed, and equal to `catalogVersion`
    /// when there is no file.
    let savedCatalogVersion: Int
    let groups: [GroupEntry]
    /// This machine's own additions.
    let extraPatterns: [String]
    /// Exactly what every applying backup set receives, in argv order.
    let patterns: [String]

    private enum CodingKeys: String, CodingKey {
        case path, exists, enabled, excludeCaches, excludeLargerThan, catalogVersion
        case savedCatalogVersion, groups, extraPatterns, patterns
    }

    // Explicit `null` for `excludeLargerThan` — the house convention for a
    // documented `--json` interface (`docs/data-model.md` preamble): the
    // synthesized encoder would omit the key, and a consumer would have to
    // tell "no cap" from "this build has no such field".
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(exists, forKey: .exists)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(excludeCaches, forKey: .excludeCaches)
        try container.encode(excludeLargerThan, forKey: .excludeLargerThan)
        try container.encode(catalogVersion, forKey: .catalogVersion)
        try container.encode(savedCatalogVersion, forKey: .savedCatalogVersion)
        try container.encode(groups, forKey: .groups)
        try container.encode(extraPatterns, forKey: .extraPatterns)
        try container.encode(patterns, forKey: .patterns)
    }

    static func build(settings: GlobalExcludeSettings, path: URL, exists: Bool) -> GlobalExcludeReport {
        let plan = settings.plan
        return GlobalExcludeReport(
            path: path.path,
            exists: exists,
            enabled: settings.enabled,
            excludeCaches: settings.excludeCaches,
            excludeLargerThan: settings.excludeLargerThan,
            catalogVersion: GlobalExcludeCatalog.version,
            savedCatalogVersion: exists ? settings.catalogVersion : GlobalExcludeCatalog.version,
            groups: GlobalExcludeCatalog.groups.map { group in
                GroupEntry(
                    id: group.id,
                    title: group.title,
                    summary: group.summary,
                    enabled: settings.isEnabled(group),
                    enabledByDefault: group.enabledByDefault,
                    patterns: group.patterns
                )
            },
            extraPatterns: settings.extraPatterns,
            patterns: plan.patterns
        )
    }

    func humanLines(includePatterns: Bool) -> [String] {
        var lines: [String] = []
        lines.append("global exclusion list: \(enabled ? "on" : "off")")
        lines.append("settings file: \(path)\(exists ? "" : "  (not present — built-in defaults)")")
        lines.append("--exclude-caches: \(excludeCaches ? "on" : "off")")
        lines.append("--exclude-larger-than: \(excludeLargerThan ?? "(no cap)")")
        lines.append("")
        for group in groups {
            let mark = group.enabled ? "[x]" : "[ ]"
            let drift = group.enabled == group.enabledByDefault
                ? ""
                : "  (changed on this machine)"
            lines.append("\(mark) \(group.id) — \(group.title)\(drift)")
            lines.append("      \(group.summary)")
            lines.append("      \(group.patterns.count) pattern(s)")
            if includePatterns {
                for pattern in group.patterns {
                    lines.append("        \(pattern)")
                }
            }
        }
        lines.append("")
        if extraPatterns.isEmpty {
            lines.append("this machine adds no patterns of its own")
        } else {
            lines.append("this machine also excludes:")
            for pattern in extraPatterns {
                lines.append("    \(pattern)")
            }
        }
        lines.append("")
        lines.append(
            "\(patterns.count) pattern(s) reach every backup set that has not set "
                + "usesGlobalExcludes: false"
        )
        if savedCatalogVersion < catalogVersion {
            lines.append(
                "note: this build carries catalogue version \(catalogVersion); your settings were "
                    + "last written against \(savedCatalogVersion). Groups added since then are on "
                    + "or off by their own default."
            )
        }
        return lines
    }
}
