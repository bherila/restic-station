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
    /// `ConnectTimeout` bounds only the handshake. Once a prune is running,
    /// a silent partition — a NAT or firewall dropping an idle flow — leaves
    /// local ssh blocked on a dead TCP session with no keepalive and no
    /// timeout, and the helper hangs **holding the set lock**, so every
    /// scheduled backup for that set stops until someone kills it by hand.
    /// That is the T19 failure this codebase has already been bitten by, so
    /// the session is kept under active keepalive: three missed 15-second
    /// probes tears it down and prune fails honestly instead of hanging.
    static let sshPrefix = [
        "/usr/bin/ssh",
        "-o", "BatchMode=yes",
        // `yes`, not `accept-new`. This channel carries the repository
        // password on stdin for `restic -p /dev/stdin`, so trust-on-first-use
        // means a MITM present at first contact is handed the password and
        // then answers `restic version` convincingly. The operator has
        // already ssh'd to this host to set the destination up, so the key is
        // normally pinned; when it is not, failing with an actionable message
        // is better than silently trusting whoever answers.
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
    ]

    public let argv: [String]
    public let password: Data?

    public init(sshTarget: String, resticPath: String, repoPath: String, dryRun: Bool, password: String? = nil) {
        var remote = [resticPath, "-r", repoPath]
        if password != nil { remote += ["-p", "/dev/stdin"] }
        remote.append("prune")
        if dryRun { remote.append("--dry-run") }
        self.argv = Self.sshPrefix + ["--", sshTarget] + remote.map(ShellQuote.singleQuote)
        self.password = password.map { Data(($0 + "\n").utf8) }
    }

    public static func version(sshTarget: String, resticPath: String) -> RemoteResticCommand {
        RemoteResticCommand(
            argv: Self.sshPrefix + [
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
