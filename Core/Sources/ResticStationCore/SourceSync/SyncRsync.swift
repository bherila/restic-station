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

    /// Well-known locations first, then each absolute `PATH` entry that
    /// holds an executable `rsync`: on the other computer that is the SSH
    /// session's PATH, which older helpers relied on (a NixOS or Linuxbrew
    /// rsync lives only there). Relative entries are skipped, and the list
    /// is bounded so a pathological PATH cannot stall a reply.
    static func candidates(wellKnown: [String] = wellKnownPaths, path: String?,
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [String] {
        var result: [String] = []
        for directory in (path ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let candidate = (directory.hasSuffix("/") ? String(directory) : directory + "/") + "rsync"
            if isExecutable(candidate) { result.append(candidate) }
        }
        var seen = Set<String>()
        return (wellKnown + result).filter { seen.insert($0).inserted }.prefix(12).map { $0 }
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
    public enum Platform: String, Codable, Sendable { case macOS = "macos", linux, other }
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

    /// The prompt shown when one computer has no usable rsync.
    static func missing(on computer: String, platform: Platform) -> SourceSyncError {
        let install: String
        switch platform {
        case .macOS: install = "Install it with Homebrew (brew install rsync)"
        case .linux: install = "Install it with the system package manager (for example sudo dnf install rsync or sudo apt install rsync)"
        case .other: install = "Install rsync"
        }
        return .rsyncNotFound("Sync needs rsync (protocol \(SyncRsync.minimumProtocol) or newer) on \(computer), and none was found. \(install), then preview again.")
    }
}
