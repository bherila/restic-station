import Testing

@testable import restic_station_helper

/// T28 (issue #30): `--help`/usage strings must print whatever the user
/// actually typed to invoke this binary — `restic-station` when invoked
/// through the `cli install` symlink, `restic-station-helper` when run
/// directly — derived from `argv[0]`'s basename. Exercised as a pure
/// function of an injected `arguments` array (never `CommandLine.arguments`
/// itself), which is what makes it testable without actually re-execing the
/// binary under a different name.
@Suite struct CommandNameTests {

    @Test func derivesTheBasenameOfAnAbsolutePath() {
        #expect(HelperMain.resolvedCommandName(arguments: ["/usr/local/bin/restic-station"]) == "restic-station")
    }

    @Test func derivesTheBasenameOfTheEmbeddedBundlePath() {
        let argv0 = "/Applications/Restic Station.app/Contents/MacOS/restic-station-helper"
        #expect(HelperMain.resolvedCommandName(arguments: [argv0]) == "restic-station-helper")
    }

    /// A bare name with no `/` at all (e.g. invoked as `./restic-station` is
    /// *not* this case — the shell still passes the leading `./`; this is
    /// the case where argv[0] was set to a bare name directly, which a
    /// `PATH`-based `execvp` can produce) is already just the basename.
    @Test func aBareNameWithNoSlashIsReturnedAsIs() {
        #expect(HelperMain.resolvedCommandName(arguments: ["restic-station"]) == "restic-station")
    }

    @Test func aRelativeInvocationKeepsOnlyTheFinalComponent() {
        #expect(HelperMain.resolvedCommandName(arguments: ["./restic-station-helper"]) == "restic-station-helper")
    }

    @Test func fallsBackToTheBuiltProductNameWhenArgumentsAreEmpty() {
        #expect(HelperMain.resolvedCommandName(arguments: []) == HelperMain.fallbackCommandName)
    }

    @Test func fallsBackToTheBuiltProductNameWhenArgv0IsEmpty() {
        #expect(HelperMain.resolvedCommandName(arguments: [""]) == HelperMain.fallbackCommandName)
    }

    /// A path that ends in `/` (degenerate, but not impossible for a
    /// spoofed or misconstructed argv[0]) has no basename to extract —
    /// falls back rather than printing an empty command name.
    @Test func fallsBackWhenThePathEndsInASlash() {
        #expect(HelperMain.resolvedCommandName(arguments: ["/usr/local/bin/"]) == HelperMain.fallbackCommandName)
    }

    @Test func theFallbackNameIsTheBuiltProductName() {
        #expect(HelperMain.fallbackCommandName == "restic-station-helper")
    }
}
