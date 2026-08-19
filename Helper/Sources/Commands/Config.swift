import ArgumentParser
import Foundation
import ResticStationCore

// MARK: - config

/// `config …` — move `config.json` between machines, and inspect what it
/// resolves to for one. The Linux half of "author on the Mac, move the
/// config, verify it, run it" (`docs/tasks/T27` / issue #29).
///
/// **Never touches `machine.json` or a secret.** `config.json` is the file a
/// user syncs or checks into a private repo; `machine.json` is host-local by
/// design (`docs/data-model.md` §machine.json) and no subcommand here reads
/// or writes it except to *display* the current host's identity string.
struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Move the shared config.json between machines, and inspect what it resolves to "
            + "for one. Never reads or writes machine.json or any secret. Exit 0 ok, 1 error.",
        subcommands: [ConfigExport.self, ConfigImport.self, ConfigValidate.self, ConfigShow.self]
    )
}

// MARK: - Shared, lightweight loading

/// The minimal context every `config` subcommand needs: `AppPaths`, a
/// `ConfigStore`, and a `StateStore` (for `validate`'s cached-reachability
/// warnings). Deliberately **not** `HelperContext`: entering a config must
/// work before a restic binary has ever been configured, the same reasoning
/// `SecretContext` already applies to the `secret` subcommands.
struct ConfigCLIContext {
    let paths: AppPaths
    let configStore: ConfigStore
    let stateStore: StateStore

    static func make() -> ConfigCLIContext {
        let paths = AppPaths.default()
        return ConfigCLIContext(paths: paths, configStore: ConfigStore(paths: paths), stateStore: StateStore(paths: paths))
    }

    /// Loads `config.json`, or throws a classified failure (per the
    /// T10/T27 exit-code contract: a config that will not load is a hard
    /// error). Still exit 1; `docs/cli-json.md` covers the envelope a
    /// `--json` caller sees instead of the bare sentence.
    func loadConfig() throws -> AppConfig {
        do {
            return try configStore.load()
        } catch {
            throw CLIFailure.configInvalid(underlying: error)
        }
    }

    /// Resolves the machine id to report/resolve for: `--machine` if given,
    /// else this host's own `machine.json` identity.
    func targetMachineId(machineFlag: String?) throws -> String {
        if let machineFlag {
            try Self.requireValidMachineId(machineFlag)
            return machineFlag
        }
        do {
            return try MachineStore(paths: paths).load().machineId
        } catch {
            throw CLIFailure.machineIdentityUnreadable(
                path: paths.machineFile.path,
                underlying: error
            )
        }
    }

    /// `--machine` accepts any string from ArgumentParser, but a machine id
    /// is a lowercase `[a-z0-9-]` slug (`docs/data-model.md` §machine.json,
    /// pinned by `MachineIdentity.isValid`). An id that is not a well-formed
    /// slug can never equal a `machines` override key, so resolving against
    /// one would silently behave exactly like "no override applies here" —
    /// which for `config validate`/`config show` means a set that is
    /// actually *disabled* on the machine the user meant could be reported
    /// as running, and vice versa. A typo must be a hard error, not a quiet
    /// no-op that happens to fall back to "everywhere" semantics. Every
    /// subcommand accepting `--machine` must call this before resolving.
    static func requireValidMachineId(_ machineId: String) throws {
        guard MachineIdentity.isValid(machineId) else {
            throw CLIFailure.invalidArguments(
                "\"\(machineId)\" is not a valid machine id — machine ids are lowercase [a-z0-9-] slugs "
                    + "(docs/data-model.md §machine.json); check --machine for a typo"
            )
        }
    }
}

// MARK: - config export

struct ConfigExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Print config.json to stdout, or write it to --out. Exports the SHARED config "
            + "only — never machine.json, never a secret. \"export my config\" does not mean "
            + "\"export my password\": destination repo URLs and non-secret env travel; repository "
            + "passwords and secret env vars never do (they live in the keychain / secrets.json, "
            + "keyed by destination id, and stay on the machine that has them — use `secret set` "
            + "on the new machine instead). Exit 0 ok, 1 error."
    )

    @Option(name: .long, help: "Write to this path instead of stdout.")
    var out: String?

    func run() async throws {
        let context = ConfigCLIContext.make()
        let config = try context.loadConfig()

        let data: Data
        do {
            data = try ConfigStore.makeEncoder().encode(config)
        } catch {
            HelperExit.fail("could not encode configuration: \(error)")
        }

        if let out {
            do {
                try data.write(to: URL(fileURLWithPath: out))
            } catch {
                HelperExit.fail("could not write \(out): \(error)")
            }
            // Human confirmation on stdout, same as `config import`'s
            // "installed"/"backed up" lines — there is no `--json` mode to
            // keep stdout clean for here, since `--out` already redirected
            // the actual export payload to a file.
            print("wrote \(out) — schema v\(config.version), \(config.sets.count) set(s), no secrets included")
        } else {
            // No `--out`: stdout IS the export, so nothing else may share
            // it — matches the `--json` convention even though this isn't
            // spelled `--json` (the output *is* config.json's own bytes).
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        HelperExit.code(0)
    }
}

// MARK: - config import

struct ConfigImport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Install a config.json exported from another machine (or re-import this "
            + "machine's own). Validates, migrates an older-schema config if needed (reusing the same "
            + "migration config.json's own loader uses), backs up any config.json already installed "
            + "before overwriting it, and prints a summary of what changed. --dry-run prints the "
            + "summary and installs nothing. Never touches machine.json or a secret. "
            + "Exit 0 ok, 1 error."
    )

    @Argument(help: "Path to the config.json to import.")
    var path: String

    @Flag(name: .long, help: "Print the change summary and exit without writing anything.")
    var dryRun = false

    func run() async throws {
        let context = ConfigCLIContext.make()
        let importURL = URL(fileURLWithPath: path)

        let data: Data
        do {
            data = try Data(contentsOf: importURL)
        } catch {
            HelperExit.fail("could not read \(path): \(error)")
        }

        let decoded: AppConfig
        do {
            decoded = try ConfigStore.makeDecoder().decode(AppConfig.self, from: data)
        } catch {
            HelperExit.fail("\(path) is not a valid config.json: \(error)")
        }

        if decoded.version > AppConfig.currentVersion {
            HelperExit.fail(
                "\(path) was written by a newer Restic Station (version \(decoded.version), "
                    + "this build supports up to \(AppConfig.currentVersion))"
            )
        }

        // A config invalid at its own version is a hard error — matching
        // `ConfigStore.load()`'s rule, it produces no backup and no
        // rewritten config.json (docs/data-model.md §Versioning).
        do {
            try decoded.validate()
        } catch {
            HelperExit.fail("\(path) failed validation: \(error)")
        }

        let needsMigration = decoded.version < AppConfig.currentVersion
        let existing = Self.loadExistingForDiff(paths: context.paths)
        if existing == nil {
            print("note: the existing config.json could not be read for a diff; it will still be backed up "
                + "before import.")
        }

        if dryRun {
            // Pure preview: no machine.json touch, no migration-backup
            // write, no config.json backup or install — --dry-run must not
            // write anything at all.
            let migrated = needsMigration ? ConfigStore.previewMigration(decoded) : decoded
            Self.printSummary(ConfigDiff.summarize(from: existing ?? AppConfig(), to: migrated))
            print("dry run — nothing written (a migration preview does not simulate moving resticPath into "
                + "machine.json; only a real import does that)")
            HelperExit.code(0)
        }

        let result = Self.performImport(
            decoded: decoded, originalBytes: data, needsMigration: needsMigration, existing: existing, context: context
        )
        Self.printSummary(result.summary)
        switch result.outcome {
        case .failed(let message):
            HelperExit.fail(message)
        case .installed(let backupPath):
            if let backupPath {
                print("backed up the existing config to \(backupPath)")
            }
            print("installed \(context.paths.configFile.path)")
            HelperExit.code(0)
        }
    }

    private static func printSummary(_ summary: ConfigDiff.Summary) {
        if summary.isEmpty {
            print("no changes")
        } else {
            for line in summary.lines {
                print(line)
            }
        }
    }

    // MARK: - The real (non-dry-run) commit, extracted for testability

    struct ImportResult {
        let summary: ConfigDiff.Summary
        let outcome: Outcome

        enum Outcome {
            /// `nil` when there was no pre-existing `config.json` to back up.
            case installed(backupPath: String?)
            case failed(String)
        }
    }

    /// Performs the actual install: backs up any existing `config.json`,
    /// migrates if needed, and saves the result — in that order, so that a
    /// failure at any step leaves **no host-local state changed**, matching
    /// the message the caller reports ("Nothing was installed" must be
    /// true).
    ///
    /// The ordering matters. `migrateToCurrentVersion` can adopt a
    /// deprecated `resticPath` into `machine.json` — a host-local mutation
    /// with a real effect on subsequent helper invocations, entirely
    /// separate from whether `config.json` itself ends up installed. Doing
    /// that migration *before* backing up the existing config, or before
    /// confirming the final `save` succeeds, was the bug this function
    /// exists to fix: a later step could fail, the command would print
    /// "Nothing was installed", and `machine.json` would already disagree
    /// with that claim.
    ///
    /// Two defenses, not one:
    /// 1. The existing `config.json` is backed up **first** — a step that
    ///    touches only the config directory, never `machine.json` — so a
    ///    failure there truly precedes any host-local mutation.
    /// 2. `machine.json`'s state is snapshotted before migration runs, and
    ///    restored (via `savePreservingIdentity`, never `save`) if either
    ///    the migration's own backup-write fails or the final `save` does —
    ///    belt and braces for the one mutation (`resticPath` adoption) that
    ///    can happen before `config.json` is confirmed installed.
    static func performImport(
        decoded: AppConfig,
        originalBytes: Data,
        needsMigration: Bool,
        existing: AppConfig?,
        context: ConfigCLIContext
    ) -> ImportResult {
        func summary(to config: AppConfig) -> ConfigDiff.Summary {
            ConfigDiff.summarize(from: existing ?? AppConfig(), to: config)
        }

        var backupPath: String?
        if FileManager.default.fileExists(atPath: context.paths.configFile.path) {
            let candidate = Self.allocateImportBackupURL(paths: context.paths)
            do {
                try FileManager.default.copyItem(at: context.paths.configFile, to: candidate)
            } catch {
                return ImportResult(
                    summary: summary(to: decoded),
                    outcome: .failed(
                        "could not back up the existing config.json before importing: \(error). "
                            + "Nothing was installed."
                    )
                )
            }
            backupPath = candidate.path
        }

        // Snapshotted *before* migration might mutate machine.json, so any
        // failure from here on can restore exactly what was there.
        let identityStore = MachineStore.persistentIdentity(paths: context.paths)
        let priorMachine = try? identityStore.load()
        func restoreMachineIdentity() {
            guard let priorMachine else { return }
            _ = try? identityStore.savePreservingIdentity(priorMachine)
        }

        let migrated: AppConfig
        if needsMigration {
            let migration = context.configStore.migrateToCurrentVersion(decoded, originalBytes: originalBytes)
            guard migration.backupWritten else {
                restoreMachineIdentity()
                return ImportResult(
                    summary: summary(to: decoded),
                    outcome: .failed(
                        "could not write \(context.paths.configBackupFile(fromVersion: decoded.version).path) — refusing to import without a "
                            + "backup of the version \(decoded.version) file being migrated. Nothing was installed."
                    )
                )
            }
            migrated = migration.config
        } else {
            migrated = decoded
        }

        do {
            try context.configStore.save(migrated)
        } catch {
            restoreMachineIdentity()
            return ImportResult(
                summary: summary(to: migrated),
                outcome: .failed("could not install the imported config: \(error). Nothing was installed.")
            )
        }

        return ImportResult(summary: summary(to: migrated), outcome: .installed(backupPath: backupPath))
    }

    /// The config currently installed, read **without** going through
    /// `ConfigStore.load()` — that method migrates and re-persists a v1
    /// file as a side effect, which a read-only diff must not trigger.
    /// `nil` file → a fresh default config (a legitimate "before" state,
    /// not a failure); an unreadable/corrupt file → `nil`, so the caller
    /// can say so rather than silently diffing against nothing.
    static func loadExistingForDiff(paths: AppPaths) -> AppConfig? {
        guard FileManager.default.fileExists(atPath: paths.configFile.path) else {
            return AppConfig()
        }
        guard let data = try? Data(contentsOf: paths.configFile) else { return nil }
        return try? ConfigStore.makeDecoder().decode(AppConfig.self, from: data)
    }

    /// `config.import-backup-<UTC timestamp>.json`, colliding candidates
    /// (two imports within the same wall-clock second) disambiguated with a
    /// `-2`, `-3`, ... suffix — the same collision convention
    /// `RunStore.allocateRunId` uses for `runId`.
    static func allocateImportBackupURL(paths: AppPaths, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = formatter.string(from: now)

        var candidate = paths.configImportBackupFile(suffix: base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = paths.configImportBackupFile(suffix: "\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}

// MARK: - config validate

struct ConfigValidate: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Check config.json and report, for one machine: hard errors (exit 1); warnings "
            + "— machines overrides naming a machine this host cannot confirm exists, and "
            + "destinations enabled here that were last probed unreachable; and the effective "
            + "plan — which sets run, with which sources and destinations, on what schedule, and "
            + "which sets/destinations are excluded here and why. Exit 0 ok (even with warnings), "
            + "1 on a hard error."
    )

    @Option(name: .long, help: "Validate as resolved for this machine id, instead of this host's own.")
    var machine: String?

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    /// `config validate --json`'s shape — see `docs/cli-json.md`.
    ///
    /// `errors` is always empty here: a config that will not load is
    /// reported as a `config_invalid` **error envelope**, not as a success
    /// document with an error list, because that is the same condition every
    /// other `--json` command reports that way. The field exists so the
    /// shape does not change when a future check can find a hard error in a
    /// config that *does* load.
    struct Report: Encodable {
        let machineId: String
        let errors: [String]
        let warnings: [String]
        let effective: EffectiveConfigReport
        /// The machine-readable form of the human "nothing will run on this
        /// machine." line — the anti-silent-failure guarantee (T27), which a
        /// caller would otherwise have to notice by counting enabled sets.
        let nothingRunsHere: Bool
    }

    func run() async throws {
        let context = ConfigCLIContext.make()

        // Hard errors first, per the report order above: an unloadable
        // config has no resolvable plan, so there is nothing else to say.
        let config: AppConfig
        do {
            config = try context.configStore.load()
        } catch {
            // Human mode keeps printing its own `Errors:` block and exiting
            // 1; JSON mode reports the same condition as the shared
            // `config_invalid` envelope so a caller does not need a
            // per-command exception.
            guard !json else { throw CLIFailure.configInvalid(underlying: error) }
            print("Errors:")
            print("  - \(error)")
            HelperExit.code(1)
        }
        if !json {
            print("Errors:")
            print("  (none)")
            print("")
        }

        let localMachineId = try? MachineStore(paths: context.paths).load().machineId
        let targetMachineId: String
        if let machine {
            try ConfigCLIContext.requireValidMachineId(machine)
            targetMachineId = machine
        } else if let localMachineId {
            targetMachineId = localMachineId
        } else {
            HelperExit.fail("could not read this machine's identity (\(context.paths.machineFile.path))")
        }

        let scheduled = config.resolved(for: targetMachineId)
        let addressable = config.addressable(for: targetMachineId)
        let report = EffectiveConfigReport.build(addressable: addressable, scheduled: scheduled)

        var warnings: [String] = []

        // Every `machines` key this config mentions that neither this
        // invocation's target nor this host's own identity can vouch for.
        // Not a fleet-wide check (no such registry exists to query) — see
        // `AppConfig.referencedMachineIds`'s doc comment.
        let confirmable: Set<String> = Set([targetMachineId, localMachineId].compactMap { $0 })
        for referenced in config.referencedMachineIds where !confirmable.contains(referenced) {
            warnings.append(
                "a machines override references \"\(referenced)\", which this host cannot confirm exists — "
                    + "normal in a multi-machine fleet, but if it is a typo, those overrides silently never apply"
            )
        }

        // Destinations enabled here whose last cached probe (state/repo-
        // status-<destId>.json, written by `tick`/`probe-repo`) came back
        // unreachable. Deliberately cached, not a live network probe:
        // `validate` is a fast, offline-safe check.
        for set in report.sets {
            for destination in set.destinations where destination.enabledHere {
                guard let status = context.stateStore.readRepoStatus(destId: destination.id), !status.reachable
                else { continue }
                let detail = status.lastError.map { " (\($0))" } ?? ""
                warnings.append(
                    "destination \"\(destination.label)\" (set \"\(set.name)\") is enabled here but was last "
                        + "probed unreachable\(detail)"
                )
            }
        }

        let nothingRunsHere = report.sets.allSatisfy { !$0.enabledHere }

        if json {
            CLIJSON.print(
                Report(
                    machineId: targetMachineId,
                    errors: [],
                    warnings: warnings,
                    effective: report,
                    nothingRunsHere: nothingRunsHere
                )
            )
            HelperExit.code(0)
        }

        print("Warnings:")
        if warnings.isEmpty {
            print("  (none)")
        } else {
            for warning in warnings {
                print("  - \(warning)")
            }
        }
        print("")

        print("Effective plan for machine \"\(targetMachineId)\":")
        for line in report.humanLines() {
            print(line.isEmpty ? "" : "  \(line)")
        }
        if nothingRunsHere {
            print("")
            print("  nothing will run on this machine.")
        }

        HelperExit.code(0)
    }
}

// MARK: - config show

struct ConfigShow: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the resolved configuration for one machine — every set and destination "
            + "this machine can address, each marked whether it actually runs/is used here — plus "
            + "what is excluded here and why. --json for scripting; human-readable by default. "
            + "Exit 0 ok, 1 error."
    )

    @Option(name: .long, help: "Show as resolved for this machine id, instead of this host's own.")
    var machine: String?

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    func run() async throws {
        let context = ConfigCLIContext.make()
        let config = try context.loadConfig()
        let targetMachineId = try context.targetMachineId(machineFlag: machine)

        let scheduled = config.resolved(for: targetMachineId)
        let addressable = config.addressable(for: targetMachineId)
        let report = EffectiveConfigReport.build(addressable: addressable, scheduled: scheduled)

        if json {
            CLIJSON.print(report)
        } else {
            print("machine: \(targetMachineId)")
            print("")
            for line in report.humanLines() {
                print(line)
            }
        }
        HelperExit.code(0)
    }
}
