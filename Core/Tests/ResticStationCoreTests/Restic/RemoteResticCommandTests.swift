import Foundation
import Testing
@testable import ResticStationCore

@Suite("RemoteResticCommand") struct RemoteResticCommandTests {
    @Test(arguments: [("/repo with space", "'/repo with space'"), ("/repo; touch pwned", "'/repo; touch pwned'")])
    func shellQuoteProtectsRemoteOperands(value: String, expected: String) {
        #expect(ShellQuote.singleQuote(value) == expected)
    }

    @Test("single quotes use the POSIX shell splice")
    func quoteEscapesSingleQuote() {
        let quoted = ShellQuote.singleQuote("/repo'quote")
        #expect(quoted == "'/repo'\"'\"'quote'")
    }

    @Test("remote prune sends password only on stdin")
    func pruneUsesStdinPassword() throws {
        let command = RemoteResticCommand(sshTarget: "backup@example", resticPath: "/usr/local/bin/restic", repoPath: "/repo; nope", dryRun: false, password: "secret")
        #expect(command.argv.contains("secret") == false)
        #expect(command.argv.contains("'/repo; nope'"))
        // Located rather than indexed: the ssh option prefix grows (keepalive
        // was added after a hang analysis) and a hardcoded index only asserts
        // how many options there happen to be today.
        let separator = try #require(command.argv.firstIndex(of: "--"))
        #expect(command.argv[separator + 1] == "backup@example")
        #expect(command.argv.first == "/usr/bin/ssh")
        #expect(command.argv.suffix(6) == ["'/usr/local/bin/restic'", "'-r'", "'/repo; nope'", "'-p'", "'/dev/stdin'", "'prune'"])
        #expect(command.password == Data("secret\n".utf8))
    }

    @Test("remote version has no repository or password operands")
    func versionIsRemoteOnly() throws {
        let command = RemoteResticCommand.version(sshTarget: "user@host", resticPath: "/opt/restic")
        let separator = try #require(command.argv.firstIndex(of: "--"))
        #expect(command.argv[separator + 1] == "user@host")
        #expect(command.argv.suffix(3) == ["'/opt/restic'", "'version'", "'--json'"])
        #expect(command.password == nil)
    }

    /// `ConnectTimeout` bounds only the handshake. Without a keepalive, a
    /// partition during a running prune leaves ssh blocked on a dead session
    /// forever, and the helper hangs holding the set lock — stopping every
    /// scheduled backup for that set until it is killed by hand.
    @Test("every remote invocation bounds a dead session with a keepalive")
    func remoteSessionsAreKeptAlive() {
        for argv in [
            RemoteResticCommand(sshTarget: "backup@example", resticPath: "restic", repoPath: "/repo", dryRun: false).argv,
            RemoteResticCommand.version(sshTarget: "backup@example", resticPath: "restic").argv,
        ] {
            #expect(argv.contains("ServerAliveInterval=15"))
            #expect(argv.contains("ServerAliveCountMax=3"))
            #expect(argv.contains("BatchMode=yes"))
            #expect(argv.contains("ConnectTimeout=15"))
        }
    }
}
