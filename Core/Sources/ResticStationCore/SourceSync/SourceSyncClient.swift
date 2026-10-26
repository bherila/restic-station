import Foundation

public protocol SourceSyncTransport: Sendable {
    func request(_ request: SyncEndpointRequest, at endpoint: SyncEndpoint) async throws -> SyncEndpointReply
    func copy(paths: [String], from source: SyncEndpoint, to destination: SyncEndpoint, listFile: URL) async throws
}

/// File data moves with rsync; inventories, reservations and commit receipts
/// use typed helper RPC over pinned SSH. Human rsync output is never parsed
/// into reconciliation truth.
public struct SourceSyncClient: SourceSyncTransport {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = DefaultProcessRunner()) { self.runner = runner }

    private static let ssh = [
        "/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
    ]

    public func request(_ request: SyncEndpointRequest, at endpoint: SyncEndpoint) async throws -> SyncEndpointReply {
        guard let target = endpoint.sshTarget else { return try SyncEndpointService.handle(request) }
        let bytes = try ConfigStore.makeEncoder().encode(request)
        let argv = Self.ssh + ["--", target, ShellQuote.singleQuote(endpoint.helperPath), "sync", "endpoint", "--json"]
        let result = try await runner.run(argv, env: Self.environment, stdin: bytes, currentDirectory: nil,
                                          onStdoutLine: nil, onStderrLine: nil, timeout: 30 * 60)
        guard result.exitCode == 0, result.outputComplete else {
            throw SourceSyncError.stateInvalid("The other computer could not complete the helper operation. Check SSH, helper compatibility, and pending recovery.")
        }
        struct Envelope: Decodable { var ok: Bool; var data: SyncEndpointReply? }
        let decoded: Envelope
        do { decoded = try ConfigStore.makeDecoder().decode(Envelope.self, from: result.stdout) }
        catch { throw SourceSyncError.stateInvalid("The other computer returned an unreadable sync response.") }
        guard decoded.ok, let reply = decoded.data, reply.version == 1 else {
            throw SourceSyncError.stateInvalid("The other computer returned an incompatible or incomplete sync response.")
        }
        return reply
    }

    public func copy(paths: [String], from source: SyncEndpoint, to destination: SyncEndpoint, listFile: URL) async throws {
        guard source.sshTarget == nil || destination.sshTarget == nil else {
            throw SourceSyncError.invalidConfiguration("This version requires the coordinating computer to participate in the transfer.")
        }
        guard paths.allSatisfy(SourceSyncPlanner.isRelativePath) else { throw SourceSyncError.stalePlan }
        if paths.isEmpty { return }
        let list = Data(paths.sorted().flatMap { Array($0.utf8) + [UInt8(0)] })
        try list.write(to: listFile, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: listFile.path)
        let remoteShell = Self.ssh.map(ShellQuote.singleQuote).joined(separator: " ")
        // Exports carry the original modification times, so rsync's default
        // size+mtime check could keep a stale same-size staged file. Always
        // transfer; staging is private and inventories still verify content.
        let argv = ["/usr/bin/rsync", "-rlpt", "--ignore-times", "--from0", "--files-from=\(listFile.path)", "--safe-links",
                    "-e", remoteShell, "--", try operand(source), try operand(destination)]
        // Keep one explicit remote-shell quoting contract across openrsync
        // and GNU rsync >=3.2.4, whose default added another escaping pass.
        // Typed inventories still verify every installed value; an rsync
        // file list or exit code never authorizes a live replacement.
        var environment = Self.environment
        environment["RSYNC_OLD_ARGS"] = "1"
        environment["RSYNC_PROTECT_ARGS"] = "0"
        let result = try await runner.run(argv, env: environment, stdin: nil, currentDirectory: nil,
                                          onStdoutLine: nil, onStderrLine: nil, timeout: 60 * 60)
        guard result.exitCode == 0, result.outputComplete else { throw SourceSyncError.transferFailed }
    }

    private func operand(_ endpoint: SyncEndpoint) throws -> String {
        guard SourceSyncGroup.isAbsoluteCanonical(endpoint.path) else { throw SourceSyncError.stalePlan }
        let path = endpoint.path.hasSuffix("/") ? endpoint.path : endpoint.path + "/"
        if let target = endpoint.sshTarget {
            guard !target.isEmpty, !target.hasPrefix("-"), !target.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw SourceSyncError.stalePlan
            }
            return target + ":" + ShellQuote.singleQuote(path)
        }
        return path
    }

    private static var environment: [String: String] {
        let current = ProcessInfo.processInfo.environment
        var result = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        for key in ["USER", "SSH_AUTH_SOCK"] { if let value = current[key] { result[key] = value } }
        return result
    }
}

/// Produced only after an actual restore matches the staged manifest.
/// Endpoint workers trust the coordinating helper's protection attestation;
/// they do not receive repository passwords or independently query a repo.
public struct SyncProtectionReceipt: Sendable {
    public let repositoryId: String
    public let snapshotId: String
    public let payloadFingerprint: String

    private init(repositoryId: String, snapshotId: String, payloadFingerprint: String) {
        self.repositoryId = repositoryId
        self.snapshotId = snapshotId
        self.payloadFingerprint = payloadFingerprint
    }

    public static func verify(
        repositoryId: String, snapshotId: String, expected: SyncInventory, restoredAt directory: URL
    ) throws -> SyncProtectionReceipt {
        guard snapshotId.count == 64, snapshotId.allSatisfy(\.isHexDigit) else { throw SourceSyncError.protectionFailed }
        guard repositoryId.count == 64, repositoryId.allSatisfy(\.isHexDigit) else { throw SourceSyncError.protectionFailed }
        let actual = try SourceSyncFilesystem.inventory(at: SourceSyncFilesystem.physicalDirectory(directory.path))
        guard actual.items == expected.items else { throw SourceSyncError.protectionFailed }
        return SyncProtectionReceipt(repositoryId: repositoryId, snapshotId: snapshotId, payloadFingerprint: try expected.fingerprint)
    }
}

public protocol SourceSyncBackingUp: Sendable {
    /// Back up every configured source plus this operation's private vault,
    /// restore the vault into an empty directory, and validate its contents.
    func protect(set: BackupSet, vault: URL, inventory: SyncInventory) async throws -> SyncProtectionReceipt
    /// Preserve the configured backup scope and existing mirror policy.
    func backup(set: BackupSet, retaining vault: URL?) async throws
}
