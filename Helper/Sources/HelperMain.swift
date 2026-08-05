import ArgumentParser

@main
struct HelperMain: AsyncParsableCommand {
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
