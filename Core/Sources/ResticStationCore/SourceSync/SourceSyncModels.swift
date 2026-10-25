import Foundation

/// A live copy, not a Restic repository. Remote paths are absolute paths
/// interpreted on the SSH host; the target is an operand, never shell code.
public struct SyncEndpoint: Codable, Equatable, Sendable {
    public var path: String
    public var sshTarget: String?
    public var helperPath: String

    public init(path: String, sshTarget: String? = nil, helperPath: String = "restic-station-helper") {
        self.path = path
        self.sshTarget = sshTarget
        self.helperPath = helperPath
    }

    private enum CodingKeys: String, CodingKey { case path, sshTarget, helperPath }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        sshTarget = try values.decodeIfPresent(String.self, forKey: .sshTarget)
        helperPath = try values.decodeIfPresent(String.self, forKey: .helperPath) ?? "restic-station-helper"
    }
}

/// An explicitly selected child of a backup source. Backup roots never
/// become transfer roots implicitly: a set can back up a workspace while
/// synchronizing only one selected folder within it.
public struct SourceSyncGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var localPath: String
    public var peer: SyncEndpoint
    public var coordinatorMachineId: String

    public init(
        id: UUID = UUID(), name: String, localPath: String,
        peer: SyncEndpoint, coordinatorMachineId: String
    ) {
        self.id = id
        self.name = name
        self.localPath = localPath
        self.peer = peer
        self.coordinatorMachineId = coordinatorMachineId
    }

    public var transferRoots: [String] { [localPath, peer.path] }

    public var bindingFingerprint: String {
        get throws {
            var intent = self
            intent.name = ""
            return SHA256Digest.hex(try ConfigStore.makeEncoder().encode(intent))
        }
    }

    /// Pure configuration validation. Runtime inspection additionally
    /// verifies actual roots, mounts, symlinks, exclusions and identities.
    public func validate(backupSources: [String]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              MachineIdentity.isValid(coordinatorMachineId) else {
            throw SourceSyncError.invalidConfiguration("Give the folder and its coordinating computer a name.")
        }
        guard Self.isAbsoluteCanonical(localPath), Self.isAbsoluteCanonical(peer.path) else {
            throw SourceSyncError.invalidConfiguration("Sync folders must use absolute paths without . or .. components.")
        }
        if let target = peer.sshTarget {
            guard !target.isEmpty, !target.hasPrefix("-"),
                  !target.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }),
                  !target.contains("/") else {
                throw SourceSyncError.invalidConfiguration("Choose a valid SSH host or configured host alias.")
            }
            guard !peer.helperPath.isEmpty, !peer.helperPath.hasPrefix("-"), !peer.helperPath.contains("\0") else {
                throw SourceSyncError.invalidConfiguration("Choose a valid helper executable on the other computer.")
            }
        } else if Self.contains(localPath, peer.path) || Self.contains(peer.path, localPath) {
            throw SourceSyncError.invalidConfiguration("The two local copies must be separate, non-overlapping folders.")
        }
        guard backupSources.contains(where: { Self.isAbsoluteCanonical($0) && Self.contains($0, localPath) }) else {
            throw SourceSyncError.invalidConfiguration("The folder on this computer must be inside a selected backup source.")
        }
    }

    static func contains(_ parent: String, _ child: String) -> Bool {
        let p = normalized(parent), c = normalized(child)
        return p == "/" || c == p || c.hasPrefix(p + "/")
    }

    static func normalized(_ path: String) -> String {
        let components = path.split(separator: "/")
        return "/" + components.joined(separator: "/")
    }

    static func isAbsoluteCanonical(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}

public enum SourceSyncError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    case unsafeRoot(String)
    case stateInvalid(String)
    case conflict(String)
    case stalePlan
    case busy
    case transferFailed
    case protectionFailed

    public var description: String {
        switch self {
        case .invalidConfiguration(let message), .unsafeRoot(let message),
             .stateInvalid(let message), .conflict(let message): return message
        case .stalePlan: return "The folders changed after the preview. Preview the changes again."
        case .busy: return "Another synchronization is already using these folders."
        case .transferFailed: return "The transfer did not complete. Existing copies have been retained."
        case .protectionFailed: return "The versions at risk could not be verified in a backup. No replacement was authorized."
        }
    }
}
