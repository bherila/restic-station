import Foundation

/// rsync moves every file payload, so like restic it is a hard requirement
/// on both computers. Each side finds its own copy: package-manager
/// installs first, because a GNU rsync can use the receiver's existing
/// version as a delta basis and macOS's built-in openrsync cannot as a
/// receiver, then the system copy, then `PATH`. A candidate counts only after
/// `--version` ran and reported a supported protocol.
///
/// Which rsync ran is not evidence. Every staged and installed value is
/// verified against the typed inventories, so a different or misbehaving
/// rsync can fail a transfer, never authorize a replacement; the path is
/// therefore not bound into previews.
public struct SyncRsync: Codable, Equatable, Sendable {
    public var path: String
    public var protocolVersion: Int

    /// openrsync's protocol, the oldest the transfer flags are tested with.
    public static let minimumProtocol = 29

    public static var wellKnownPaths: [String] {
        #if os(macOS)
        return ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/opt/local/bin/rsync", "/usr/bin/rsync"]
        #else
        return ["/usr/bin/rsync", "/usr/local/bin/rsync", "/bin/rsync"]
        #endif
    }

    /// Well-known locations first, then each `PATH` entry that holds an
    /// executable `rsync`: on the other computer that is the SSH session's
    /// PATH, which older helpers relied on (a NixOS or Linuxbrew rsync lives
    /// only there). Only entries the coordinator would accept as a reported
    /// path count, so a relative or non-canonical one cannot shadow a later
    /// usable one, and the scan stops at the cap so a pathological PATH
    /// cannot stall a reply.
    static func candidates(wellKnown: [String] = wellKnownPaths, path: String?,
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [String] {
        let limit = 12
        var result: [String] = [], seen = Set<String>()
        for candidate in wellKnown where seen.insert(candidate).inserted { result.append(candidate) }
        for directory in (path ?? "").split(separator: ":") {
            guard result.count < limit else { break }
            let candidate = (directory.hasSuffix("/") ? String(directory) : directory + "/") + "rsync"
            guard isUsableRemotePath(candidate), !seen.contains(candidate), isExecutable(candidate) else { continue }
            seen.insert(candidate); result.append(candidate)
        }
        return Array(result.prefix(limit))
    }

    /// Tests point discovery at their own candidates.
    @TaskLocal static var searched: [String]? = nil

    public static func find(runner: any ProcessRunning) async -> SyncRsync? {
        for path in searched ?? candidates(path: ProcessInfo.processInfo.environment["PATH"]) {
            guard let result = try? await runner.run([path, "--version"], env: ["LC_ALL": "C"], stdin: nil, currentDirectory: nil,
                                                     onStdoutLine: nil, onStderrLine: nil, timeout: 5),
                  result.exitCode == 0,
                  let version = protocolVersion(String(decoding: result.stdout, as: UTF8.self)),
                  version >= minimumProtocol else { continue }
            return SyncRsync(path: path, protocolVersion: version)
        }
        return nil
    }

    /// GNU prints `rsync  version 3.4.0  protocol version 32`; openrsync
    /// prints `openrsync: protocol version 29`.
    static func protocolVersion(_ output: String) -> Int? {
        guard let line = output.split(separator: "\n").first,
              let range = line.range(of: "protocol version ") else { return nil }
        return Int(line[range.upperBound...].prefix { $0.isNumber })
    }

    /// The remote shell runs the peer's reported path as a command, so only
    /// a plain absolute path is accepted before it is quoted.
    static func isUsableRemotePath(_ path: String) -> Bool {
        SourceSyncGroup.isAbsoluteCanonical(path) && path.count <= 4096
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// What an endpoint can move file data with, reported by the other
/// computer's helper. Absent from older helpers' replies, which keep the
/// earlier behavior of running `rsync` from the SSH session's PATH.
public struct SyncTransferTools: Codable, Equatable, Sendable {
    public enum Platform: String, Codable, Sendable {
        case macOS = "macos", linux, other
        /// A platform a newer helper adds reads as `other`, so it changes
        /// only the install hint and never makes the whole reply unreadable.
        public init(from decoder: Decoder) throws {
            self = Platform(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }
    public var platform: Platform
    public var rsync: SyncRsync?

    public static var thisPlatform: Platform {
        #if os(macOS)
        return .macOS
        #elseif os(Linux)
        return .linux
        #else
        return .other
        #endif
    }

    public static func current(runner: any ProcessRunning) async -> SyncTransferTools {
        SyncTransferTools(platform: thisPlatform, rsync: await SyncRsync.find(runner: runner))
    }

    /// The prompt shown when one computer has no usable rsync. A check made
    /// before any operation exists says to preview again; the coordinator
    /// names the way out of a pending operation instead.
    static func missing(on computer: SyncRsyncMissing.Computer, platform: Platform,
                        next: SyncRsyncMissing.NextStep = .previewAgain) -> SourceSyncError {
        .rsyncNotFound(SyncRsyncMissing(computer: computer, platform: platform, next: next))
    }
}

/// Which computer has no usable rsync, and what to do once it is installed.
/// The next step depends on where the check failed, so it is a value the
/// coordinator sets rather than text it rewrites.
public struct SyncRsyncMissing: Equatable, Sendable, CustomStringConvertible {
    public enum Computer: Sendable { case this, other }
    public enum NextStep: Sendable {
        /// No operation exists yet.
        case previewAgain
        /// This computer's rsync is found again on every resume.
        case resume
        /// The other computer's prepare reply is saved in the journal, so a
        /// resume would read it again; only an operation that has not yet
        /// run its protection backup gets this.
        case cancelUnstarted
    }
    public var computer: Computer
    public var platform: SyncTransferTools.Platform
    public var next: NextStep

    public var description: String {
        let install: String
        switch platform {
        case .macOS: install = "Install it with Homebrew (brew install rsync)"
        case .linux: install = "Install it with the system package manager (for example sudo dnf install rsync or sudo apt install rsync)"
        case .other: install = "Install rsync"
        }
        let then: String
        switch next {
        case .previewAgain: then = "preview again"
        case .resume: then = "resume this synchronization with sync recover (Resume in Sync & Back Up)"
        case .cancelUnstarted: then = "cancel this unstarted synchronization with sync recover --cancel-unstarted and preview again"
        }
        let place = computer == .this ? "this computer" : "the other computer"
        return "Sync needs rsync (protocol \(SyncRsync.minimumProtocol) or newer) on \(place), and none was found. \(install), then \(then)."
    }
}
