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
    #expect(
        names == [
            "tick",
            "run-set",
            "init-secondary",
            "restore",
            "probe-repo",
            "unlock",
            "fda-check",
            "version",
        ]
    )
}
