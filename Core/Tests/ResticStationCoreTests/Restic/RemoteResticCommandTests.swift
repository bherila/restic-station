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
    func pruneUsesStdinPassword() {
        let command = RemoteResticCommand(sshTarget: "backup@example", resticPath: "/usr/local/bin/restic", repoPath: "/repo; nope", dryRun: false, password: "secret")
        #expect(command.argv.contains("secret") == false)
        #expect(command.argv.contains("'/repo; nope'"))
        #expect(command.argv[7...8] == ["--", "backup@example"])
        #expect(command.argv.suffix(6) == ["'/usr/local/bin/restic'", "'-r'", "'/repo; nope'", "'-p'", "'/dev/stdin'", "'prune'"])
        #expect(command.password == Data("secret\n".utf8))
    }

    @Test("remote version has no repository or password operands")
    func versionIsRemoteOnly() {
        let command = RemoteResticCommand.version(sshTarget: "user@host", resticPath: "/opt/restic")
        #expect(command.argv[7...8] == ["--", "user@host"])
        #expect(command.argv.suffix(3) == ["'/opt/restic'", "'version'", "'--json'"])
        #expect(command.password == nil)
    }
}
