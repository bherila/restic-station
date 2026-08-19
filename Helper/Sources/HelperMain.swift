import ArgumentParser
import ResticStationCore

@main
struct HelperMain: AsyncParsableCommand {

    /// Replaces the `main()` `AsyncParsableCommand` synthesizes, which is
    /// reproduced verbatim below apart from the two `catch` clauses.
    ///
    /// Taking it over is what makes an **argument-parser failure**
    /// classifiable at all: `run()` is never reached for one, so a command
    /// cannot report it no matter how it is written. It is also what keeps
    /// human mode byte-identical — anything this does not deliberately own
    /// is handed straight back to `exit(withError:)`, which is what prints
    /// usage text, exits `--help` cleanly with 0, and exits usage errors
    /// with `EX_USAGE`.
    ///
    /// `parsed` is captured so the failure path can ask the command the user
    /// actually invoked whether it wanted JSON, instead of guessing.
    static func main() async {
        var parsed: ParsableCommand?
        do {
            var command = try await asyncParseAsRoot()
            parsed = command
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let failure as CLIFailure {
            // Rendered here in **both** modes, never handed to
            // `exit(withError:)`: that would print ArgumentParser's
            // `Error: <the struct>` rather than the sentence these commands
            // have always written to stderr.
            HelperOutput.renderFailure(failure, json: Self.wantsJSON(parsed))
        } catch {
            // `--help` and other clean exits are not failures, whatever mode
            // the caller asked for. Checked first so `status --json --help`
            // still prints help rather than an envelope claiming success is
            // an error.
            let exitCode = Self.exitCode(for: error)
            guard exitCode != ExitCode.success, Self.wantsJSON(parsed) else {
                Self.exit(withError: error)
            }

            if parsed == nil {
                // Parsing itself failed. `message(for:)` is the one-line
                // reason without the usage block, which is what belongs in
                // a JSON `message`; the exit code stays whatever
                // ArgumentParser would have used, so both modes agree on it.
                HelperOutput.renderFailure(
                    .invalidArguments(Self.message(for: error)),
                    json: true,
                    exitCode: exitCode.rawValue
                )
            }
            HelperOutput.renderFailure(CLIFailure.classify(error), json: true)
        }
    }

    /// Whether the caller asked for JSON: the parsed command is the
    /// authority, and argv is only consulted when parsing never produced
    /// one. See ``HelperOutput/argvRequestsJSON(_:)``.
    private static func wantsJSON(_ parsed: ParsableCommand?) -> Bool {
        parsed.map(HelperOutput.wantsJSON) ?? HelperOutput.argvRequestsJSON()
    }

    /// A computed property, not `static let`: the printed name depends on
    /// `CommandLine.arguments`, which is not available until the process
    /// has actually started.
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: resolvedCommandName(),
            abstract: "Restic Station background helper. "
                + "Exit codes (per-subcommand, see each --help): 0 ok, 1 error, 2 busy, 3 offline (probe-repo only).",
            subcommands: subcommandList
        )
    }

    /// The built product is always named `restic-station-helper`
    /// (`project.yml`, the embedded bundle path, and the launchd agent all
    /// key on that name — it is never renamed). But a user who ran `cli
    /// install` (T28, issue #30) invokes this same binary through a
    /// `restic-station` symlink, and `--help`/usage strings printing
    /// `restic-station-helper` at someone who typed `restic-station` would
    /// be exactly the kind of confusing surface this task exists to fix.
    ///
    /// So: derive the printed name from `argv[0]`'s basename (whatever the
    /// caller actually typed or the symlink resolved through), falling back
    /// to the built product's real name if `argv[0]` is empty or somehow
    /// unusable. Deliberately **not** `Bundle.main`/`currentExecutablePath`
    /// (`FileSecretStore.currentExecutablePath()`): those resolve symlinks
    /// away and would always print `restic-station-helper` regardless of
    /// how the user actually invoked the tool — the opposite of what this
    /// is for.
    static func resolvedCommandName(arguments: [String] = CommandLine.arguments) -> String {
        guard let first = arguments.first, !first.isEmpty else {
            return fallbackCommandName
        }
        guard let lastSlash = first.lastIndex(of: "/") else {
            return first
        }
        let base = String(first[first.index(after: lastSlash)...])
        return base.isEmpty ? fallbackCommandName : base
    }

    static let fallbackCommandName = "restic-station-helper"

    /// Every subcommand, in the order `--help` lists them.
    ///
    /// `timer` is the one platform-conditional entry: scheduling is
    /// registered by the app on macOS (`SMAppService`) and by the helper
    /// itself on Linux (a systemd `--user` timer), so on macOS the
    /// subcommand is not merely inert — it is absent. A command that exists
    /// and always errors is a worse `--help` than one that is honestly not
    /// there. `fda-check` goes the other way for the opposite reason: it
    /// exists everywhere so scripts stay uniform, and reports "not
    /// applicable" off-macOS.
    private static var subcommandList: [any ParsableCommand.Type] {
        var subcommands: [any ParsableCommand.Type] = [
            Tick.self,
            RunSet.self,
            InitSecondary.self,
            Restore.self,
            ProbeRepo.self,
            Unlock.self,
            FdaCheck.self,
            Secret.self,
            // T27 — headless CLI ergonomics: move config.json between
            // machines and inspect what happens on this one, without the
            // app. Available on every platform (`docs/tasks/T27`'s
            // acceptance criteria: identical CLI surface on macOS and
            // Linux) — T28 is what makes them reachable from the macOS app.
            Config.self,
            Status.self,
            Sets.self,
            Runs.self,
            // T28 (issue #30): the `restic-station` PATH symlink itself —
            // install/uninstall/status. Available on every platform for the
            // same "identical CLI surface" reason as the four above it, even
            // though the symlink-vs-bundle problem it solves is sharpest on
            // macOS.
            Cli.self,
            // Hidden from --help (`shouldDisplay: false`): it exists for
            // RESTIC_PASSWORD_COMMAND, not for people.
            PrintPassword.self,
        ]
        #if os(Linux)
        subcommands.append(TimerCommand.self)
        #endif
        subcommands.append(Version.self)
        return subcommands
    }
}
