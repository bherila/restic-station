import Foundation

/// Private helper-to-helper protocol. Requests travel on stdin over SSH,
/// not through a configurable shell hook. No repository credentials cross
/// this channel. Only protocol-versioned, typed operations are accepted.
public struct SyncEndpointRequest: Codable, Sendable {
    /// The most the other computer's helper reads from one request (#197).
    /// Raised from 32 MiB, which held about 80,000 files, because requests
    /// were pretty-printed and carried each inventory twice. The coordinator
    /// checks it before sending, so a folder that is still too large fails
    /// with its own message, not as a dropped SSH session.
    public static let maximumEncodedBytes = 64 * 1024 * 1024
    /// What a helper from before #197 reads.
    public static let legacyMaximumEncodedBytes = 32 * 1024 * 1024
    /// Replaced only by tests, which cannot build a 64 MiB request cheaply.
    @TaskLocal static var limitOverride: Int?

    /// Compact and key-sorted. The request is machine-read and neither hashed
    /// nor displayed, so whitespace only costs bytes against the limit.
    public static func encode(_ request: SyncEndpointRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    public enum Action: String, Codable, Sendable { case inventory, prepare, commit, finish, inspect, cancel, cleanup }
    public var version: Int = 1
    public var action: Action
    public var groupId: UUID
    public var coordinatorMachineId: String
    public var root: String
    public var operationId: UUID?
    public var expected: SyncInventory?
    public var operations: [SyncEndpointOperation] = []
    public var protectedItems: [String: SyncItem] = [:]
    public var protectedSnapshotId: String?
    public var protectedRepositoryId: String?
    public var exportPaths: [String] = []
    /// What this sync covers (#202). Absent means everything: a request
    /// from a coordinator older than #202, or for an operation journaled
    /// before it. An older endpoint ignores the field, so the coordinator
    /// requires it echoed in ``SyncEndpointReply/scope``.
    public var scope: SyncScope?

    public init(action: Action, group: SourceSyncGroup, root: String, operationId: UUID? = nil, expected: SyncInventory? = nil) {
        self.action = action
        self.groupId = group.id
        self.coordinatorMachineId = group.coordinatorMachineId
        self.root = root
        self.operationId = operationId
        self.expected = expected
    }
}

public struct SyncEndpointOperation: Codable, Equatable, Sendable {
    public var path: String
    public var before: SyncItem?
    public var after: SyncItem?

    public init(path: String, before: SyncItem?, after: SyncItem?) {
        self.path = path
        self.before = before
        self.after = after
    }
}

public struct SyncEndpointReply: Codable, Sendable {
    public var version: Int = 1
    public var inventory: SyncInventory
    public var stagingPath: String?
    public var recoveryPath: String?
    public var operationId: UUID?
    public var completedPaths: [String]
    public var exportPath: String?
    public var lastCompletedOperation: UUID?
    /// Set by the other computer's helper on inventory and prepare replies.
    public var transfer: SyncTransferTools?
    /// The scope this endpoint applied to `inventory`; absent from a helper
    /// older than #202, which applies none.
    public var scope: SyncScope?
    /// The topmost entries `scope` left out of `inventory`, sorted.
    public var excluded: [String]?
    /// Free bytes on the volume beside this folder, on inventory and inspect
    /// replies (#197). Absent from a helper that predates it, and when the
    /// volume will not say; either reads as unknown, never as full.
    public var freeBytes: UInt64?

    public init(inventory: SyncInventory, stagingPath: String? = nil, recoveryPath: String? = nil, operationId: UUID? = nil, completedPaths: [String] = []) {
        self.inventory = inventory
        self.stagingPath = stagingPath
        self.recoveryPath = recoveryPath
        self.operationId = operationId
        self.completedPaths = completedPaths
    }
}

struct SyncRootRecord: Codable {
    var version: Int = 1
    var groupId: UUID
    var coordinatorMachineId: String
    var rootIdentity: String
    var generation: UUID
    var activeOperation: UUID?
    var lastCompletedOperation: UUID?
}

struct SyncEndpointJournal: Codable {
    enum Phase: String, Codable { case prepared, applying, finished, cancelled, cleaned }
    enum Step: String, Codable { case pending, captured, installed }
    var version: Int = 1
    var operationId: UUID
    var expected: SyncInventory
    var phase: Phase
    var operations: [SyncEndpointOperation]
    var steps: [String: Step]
    var protectedSnapshotId: String?
    var protectedRepositoryId: String?
    /// Bound at prepare: every later request must name the same scope, so
    /// the inventory compared against `expected` never changes meaning.
    var scope: SyncScope?
}
