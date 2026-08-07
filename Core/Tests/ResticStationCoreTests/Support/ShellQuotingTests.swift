import Foundation
import Testing
@testable import ResticStationCore

/// Every "run this" line this project prints embeds a user-chosen path — the
/// cron fallback, the `rm` that clears an abandoned run. A line printed for
/// someone to paste is a line that *will* be pasted, so the quoting is a
/// correctness property, not cosmetics.
@Suite struct ShellQuotingTests {

    @Test("an ordinary path is left bare, so the common case stays readable")
    func ordinaryPathsAreNotQuoted() {
        #expect(ShellQuoting.quoteIfNeeded("/srv/state/restic-station") == "/srv/state/restic-station")
        #expect(ShellQuoting.quoteIfNeeded("/home/ben/.local/state/restic-station")
            == "/home/ben/.local/state/restic-station")
        #expect(ShellQuoting.quoteIfNeeded("/opt/restic-station_2/bin") == "/opt/restic-station_2/bin")
    }

    @Test("a space is quoted rather than word-split")
    func spacesAreQuoted() {
        #expect(ShellQuoting.quoteIfNeeded("/srv/my state") == "'/srv/my state'")
    }

    @Test("shell metacharacters are neutralised, not executed")
    func metacharactersAreNeutralised() {
        // The failure this prevents: `rm /srv/x; rm -rf /` pasted verbatim.
        #expect(ShellQuoting.quoteIfNeeded("/srv/x; rm -rf /") == "'/srv/x; rm -rf /'")
        // Inside single quotes `$` and backtick are literal to sh, so no
        // command substitution survives.
        #expect(ShellQuoting.quoteIfNeeded("/srv/$(whoami)") == "'/srv/$(whoami)'")
        #expect(ShellQuoting.quoteIfNeeded("/srv/`id`") == "'/srv/`id`'")
        #expect(ShellQuoting.quoteIfNeeded("/srv/a$b") == "'/srv/a$b'")
    }

    @Test("an embedded single quote uses the '\\'' dance and stays balanced")
    func embeddedSingleQuote() {
        // close, escaped literal quote, reopen — the only way to get a
        // single quote through single quoting.
        #expect(ShellQuoting.quoteIfNeeded("/srv/it's") == "'/srv/it'\\''s'")
    }

    @Test("a leading tilde is quoted, so it is a path and not the home directory")
    func tildeIsQuoted() {
        #expect(ShellQuoting.quoteIfNeeded("~/state") == "'~/state'")
    }

    @Test("a percent sign is quoted — a printed command may also pass through crontab")
    func percentIsQuoted() {
        #expect(ShellQuoting.quoteIfNeeded("/srv/100%full") == "'/srv/100%full'")
    }

    @Test("an empty string becomes an explicit empty word, not nothing at all")
    func emptyStringIsQuoted() {
        // Bare, an empty value would vanish from the command line and shift
        // every argument after it.
        #expect(ShellQuoting.quoteIfNeeded("") == "''")
    }
}
