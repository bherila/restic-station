import Foundation

/// Shell-safe construction of the remote half of sftp maintenance. SSH
/// concatenates remote operands and hands them to a login shell, so each
/// operand is quoted independently before it crosses the connection.
public enum ShellQuote {
    public static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

public struct RemoteResticCommand: Equatable, Sendable {
    public let argv: [String]
    public let password: Data?

    public init(sshTarget: String, resticPath: String, repoPath: String, dryRun: Bool, password: String? = nil) {
        var remote = [resticPath, "-r", repoPath]
        if password != nil { remote += ["-p", "/dev/stdin"] }
        remote.append("prune")
        if dryRun { remote.append("--dry-run") }
        self.argv = [
            "/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15",
            "--", sshTarget
        ] + remote.map(ShellQuote.singleQuote)
        self.password = password.map { Data(($0 + "\n").utf8) }
    }

    public static func version(sshTarget: String, resticPath: String) -> RemoteResticCommand {
        RemoteResticCommand(
            argv: [
                "/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15",
                "--", sshTarget, ShellQuote.singleQuote(resticPath), "'version'", "'--json'"
            ],
            password: nil
        )
    }

    private init(argv: [String], password: Data?) { self.argv = argv; self.password = password }

    public func withPassword(_ password: String) -> RemoteResticCommand {
        var updated = argv
        guard let pruneIndex = updated.lastIndex(of: "'prune'") else { return self }
        updated.insert(contentsOf: ["'-p'", "'/dev/stdin'"], at: pruneIndex)
        return RemoteResticCommand(argv: updated, password: Data((password + "\n").utf8))
    }
}
