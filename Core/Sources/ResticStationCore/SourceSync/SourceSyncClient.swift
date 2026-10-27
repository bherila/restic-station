import Foundation

public protocol SourceSyncTransport: Sendable {
    func request(_ request: SyncEndpointRequest, at endpoint: SyncEndpoint) async throws -> SyncEndpointReply
    /// Refuses, before anything is reserved or backed up, when either
    /// computer cannot move file data. `peer` is the other computer's
    /// inventory reply.
    func checkTransfer(peer: SyncEndpointReply, at endpoint: SyncEndpoint) async throws
    func copy(paths: [String], from source: SyncEndpoint, to destination: SyncEndpoint, listFile: URL, options: SyncCopyOptions) async throws
}

public struct SyncCopyOptions: Equatable, Sendable {
    /// The other computer's live folder, when it receives. rsync may use the
    /// current version of each path there as a delta basis, so an edit to a
    /// large file sends only changed blocks. It is only read, and the staged
    /// result is still verified against the typed inventory.
    ///
    /// A receiver sends its basis's block checksums to the sender and
    /// follows symlinks to find it, so only the other computer gets one: it
    /// reads its own folder for the coordinator, which already holds
    /// authority over it. This computer never offers its files as a basis to
    /// a sender (the class of rsync CVE-2024-12086).
    public var basis: String?
    /// The other computer's rsync, as its helper reported it.
    public var remoteRsync: String?
    /// Compress across SSH.
    public var compress: Bool

    public init(basis: String? = nil, remoteRsync: String? = nil, compress: Bool = false) {
        self.basis = basis
        self.remoteRsync = remoteRsync
        self.compress = compress
    }
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
        guard result.outputComplete else {
            throw SourceSyncError.stateInvalid("The other computer's helper did not finish its reply. Check the SSH connection, then preview again.")
        }
        guard result.exitCode == 0 else { throw Self.remoteFailure(exitCode: result.exitCode, stdout: result.stdout, helperPath: endpoint.helperPath) }
        struct Envelope: Decodable { var ok: Bool; var data: SyncEndpointReply? }
        let decoded: Envelope
        do { decoded = try ConfigStore.makeDecoder().decode(Envelope.self, from: result.stdout) }
        catch { throw SourceSyncError.stateInvalid("The other computer returned an unreadable sync response.") }
        guard decoded.ok, let reply = decoded.data, reply.version == 1 else {
            throw SourceSyncError.stateInvalid("The other computer returned an incompatible or incomplete sync response.")
        }
        return reply
    }

    /// A failed peer keeps its own reason: a busy reservation, a refused
    /// folder and a dropped connection need different actions. The peer's
    /// text is untrusted display text, so it is bounded and stripped of
    /// control characters; only its code chooses the error case.
    static func remoteFailure(exitCode: Int32, stdout: Data, helperPath: String) -> SourceSyncError {
        struct Failure: Decodable { struct Detail: Decodable { var code: String; var message: String }; var ok: Bool; var error: Detail }
        if let failure = try? ConfigStore.makeDecoder().decode(Failure.self, from: stdout), !failure.ok {
            let reason = String(String.UnicodeScalarView(failure.error.message.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(300))
            switch failure.error.code {
            case CLIErrorCode.setBusy.rawValue: return .busy
            case CLIErrorCode.configInvalid.rawValue: return .unsafeRoot("The other computer refused its folder: \(reason)")
            default: return .stateInvalid("The other computer could not complete the request: \(reason)")
            }
        }
        switch exitCode {
        // ssh exits 255 for its own failures: connection, authentication, host key.
        case 255: return .stateInvalid("Could not reach the other computer over SSH. Check that the host is up, its key is in known_hosts, and your SSH key is available.")
        // The remote shell's codes for a helper it cannot find or execute.
        case 126, 127: return .invalidConfiguration("The other computer could not run the helper at \(helperPath). Install a compatible Restic Station helper there or correct the folder's helper path.")
        default: return .stateInvalid("The other computer could not complete the helper operation. Check SSH, helper compatibility, and pending recovery.")
        }
    }

    public func checkTransfer(peer: SyncEndpointReply, at endpoint: SyncEndpoint) async throws {
        guard await SyncRsync.find(runner: runner) != nil else {
            throw SyncTransferTools.missing(on: "this computer", platform: SyncTransferTools.thisPlatform)
        }
        // A folder on this computer uses this computer's rsync. An older
        // helper reports nothing and keeps running rsync from its PATH.
        guard endpoint.sshTarget != nil, let tools = peer.transfer else { return }
        guard let rsync = tools.rsync else { throw SyncTransferTools.missing(on: "the other computer", platform: tools.platform) }
        guard SyncRsync.isUsableRemotePath(rsync.path) else {
            throw SourceSyncError.stateInvalid("The other computer reported an rsync location that cannot be used.")
        }
    }

    public func copy(paths: [String], from source: SyncEndpoint, to destination: SyncEndpoint, listFile: URL, options: SyncCopyOptions) async throws {
        guard source.sshTarget == nil || destination.sshTarget == nil else {
            throw SourceSyncError.invalidConfiguration("This version requires the coordinating computer to participate in the transfer.")
        }
        guard paths.allSatisfy(SourceSyncPlanner.isRelativePath) else { throw SourceSyncError.stalePlan }
        if paths.isEmpty { return }
        guard let rsync = await SyncRsync.find(runner: runner) else {
            throw SyncTransferTools.missing(on: "this computer", platform: SyncTransferTools.thisPlatform)
        }
        let list = Data(paths.sorted().flatMap { Array($0.utf8) + [UInt8(0)] })
        try list.write(to: listFile, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: listFile.path)
        let remoteShell = Self.ssh.map(ShellQuote.singleQuote).joined(separator: " ")
        // Exports carry the original modification times, so rsync's default
        // size+mtime check could keep a stale same-size staged file. Always
        // transfer; staging is private and inventories still verify content.
        var argv = [rsync.path, "-rlpt", "--ignore-times", "--from0", "--files-from=\(listFile.path)", "--safe-links"]
        // Compression and delta bases pay off only across the network; a
        // local rsync copies whole files anyway.
        if source.sshTarget != nil || destination.sshTarget != nil {
            if options.compress { argv.append("--compress") }
            if let basis = options.basis, destination.sshTarget != nil {
                guard SourceSyncGroup.isAbsoluteCanonical(basis) else { throw SourceSyncError.stalePlan }
                // The remote receiver's options pass through its shell.
                argv.append("--copy-dest=" + ShellQuote.singleQuote(basis.hasSuffix("/") ? basis : basis + "/"))
            }
            if let remote = options.remoteRsync {
                guard SyncRsync.isUsableRemotePath(remote) else { throw SourceSyncError.stalePlan }
                argv.append("--rsync-path=" + ShellQuote.singleQuote(remote))
            }
        }
        argv += ["-e", remoteShell, "--", try operand(source), try operand(destination)]
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
