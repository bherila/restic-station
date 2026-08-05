import Testing

@testable import restic_station_helper

/// The root SwiftPM package's test target exists so `swift test` at the repo
/// root has something to run (T21) — SwiftPM does not run a path
/// dependency's test targets, so Core's suite is still invoked separately
/// via `swift test --package-path Core`.
///
/// This asserts the verification the T21 issue asks for — "the helper lists
/// all subcommands" — off the command tree rather than by shelling out to
/// the built binary, so it behaves identically on macOS and Linux.
@Test func exposesEverySubcommand() {
    // Spelled as an explicit closure with an explicit result type: the
    // key-path form `map(\.configuration.commandName)` over an existential
    // metatype crashes SILGen in Swift 6.3.3.
    let names: [String?] = HelperMain.configuration.subcommands.map { subcommand in
        subcommand.configuration.commandName
    }

    // `timer` is Linux-only (T26): scheduling is registered by the app on
    // macOS and by the helper on Linux. Asserted as a full ordered list on
    // both platforms rather than as a `contains` check, so a subcommand
    // silently disappearing from `--help` still fails the build.
    #if os(Linux)
    #expect(
        names == [
            "tick",
            "run-set",
            "init-secondary",
            "restore",
            "probe-repo",
            "unlock",
            "fda-check",
            "secret",
            "print-password",
            "timer",
            "version",
        ]
    )
    #else
    #expect(
        names == [
            "tick",
            "run-set",
            "init-secondary",
            "restore",
            "probe-repo",
            "unlock",
            "fda-check",
            "secret",
            "print-password",
            "version",
        ]
    )
    #expect(!names.contains("timer"))
    #endif
}

/// `print-password` is registered but must stay out of `--help`: it is the
/// machinery behind `RESTIC_PASSWORD_COMMAND`, not a user-facing action.
@Test func printPasswordIsHiddenFromHelp() {
    #expect(PrintPassword.configuration.shouldDisplay == false)
    // Everything else is visible.
    for subcommand in HelperMain.configuration.subcommands
    where subcommand.configuration.commandName != "print-password" {
        #expect(
            subcommand.configuration.shouldDisplay,
            "\(subcommand.configuration.commandName ?? "?") should appear in --help"
        )
    }
}

@Test func secretExposesItsFourSubcommands() {
    let names: [String?] = Secret.configuration.subcommands.map { subcommand in
        subcommand.configuration.commandName
    }
    #expect(names == ["set", "set-env", "rm", "list"])
}
