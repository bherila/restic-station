import Foundation
import ResticStationCore
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
            "purge",
            "maintenance",
            "init-secondary",
            "restore",
            "probe-repo",
            "unlock",
            "fda-check",
            "secret",
            "config",
            "status",
            "sets",
            "runs",
            "cli",
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
            "purge",
            "maintenance",
            "init-secondary",
            "restore",
            "probe-repo",
            "unlock",
            "fda-check",
            "secret",
            "config",
            "status",
            "sets",
            "runs",
            "cli",
            "print-password",
            "version",
        ]
    )
    #expect(!names.contains("timer"))
    #endif
}

/// T27 (issue #29): the headless CLI surface is available and identical on
/// both platforms — this is the "identical CLI surface on macOS and Linux"
/// acceptance criterion, pinned as a registration-list assertion the same
/// way `exposesEverySubcommand()` above pins `timer`'s asymmetry. Unlike
/// `timer`, none of these four are platform-conditional.
@Test func headlessCLICommandsAreRegisteredOnEveryPlatform() {
    let names: [String?] = HelperMain.configuration.subcommands.map { subcommand in
        subcommand.configuration.commandName
    }
    for name in ["config", "status", "sets", "runs"] {
        #expect(names.contains(name), "\(name) should be registered on every platform")
    }
}

@Test func configExposesItsFourSubcommands() {
    let names: [String?] = Config.configuration.subcommands.map { subcommand in
        subcommand.configuration.commandName
    }
    #expect(names == ["export", "import", "validate", "show"])
}

@Test func setsExposesListOnly() {
    let names: [String?] = Sets.configuration.subcommands.map { subcommand in
        subcommand.configuration.commandName
    }
    #expect(names == ["list"])
}

@Test func runsExposesListAndShow() {
    let names: [String?] = Runs.configuration.subcommands.map { subcommand in
        subcommand.configuration.commandName
    }
    #expect(names == ["list", "show"])
}

@Test func purgeExposesPreviewAndTokenGatedApply() {
    let names: [String?] = Purge.configuration.subcommands.map { subcommand in
        subcommand.configuration.commandName
    }
    #expect(names == ["preview", "apply"])
}

@Test func maintenanceExposesStandalonePrune() {
    let names: [String?] = Maintenance.configuration.subcommands.map { subcommand in
        subcommand.configuration.commandName
    }
    #expect(names == ["prune"])
}

@Test func maintenancePruneBindsConfirmedRepositoryToItsPreview() throws {
    let setId = UUID()
    let destination = Destination(
        id: UUID(),
        label: "Primary",
        repoURL: "/Volumes/current.restic",
        isPrimary: true
    )
    let parsed = try #require(HelperMain.parseAsRoot([
        "maintenance", "prune", "--set", setId.uuidString,
        "--dest", destination.id.uuidString,
        "--expected-repo", "/Volumes/previewed.restic",
    ]) as? MaintenancePrune)
    #expect(parsed.expectedRepo == "/Volumes/previewed.restic")

    do {
        try MaintenancePrune.validateExpectedRepository(
            parsed.expectedRepo,
            destination: destination,
            setId: setId
        )
        Issue.record("expected the helper to reject a destination changed after preview")
    } catch let failure as CLIFailure {
        #expect(failure.code == .operationNotAllowed)
        #expect(failure.details.setId == setId)
        #expect(failure.details.destinationId == destination.id)
    }
}

/// T28 (issue #30): the `restic-station` PATH symlink manager.
@Test func cliExposesItsThreeSubcommands() {
    let names: [String?] = Cli.configuration.subcommands.map { subcommand in
        subcommand.configuration.commandName
    }
    #expect(names == ["install", "uninstall", "status"])
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
