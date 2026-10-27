import Foundation

/// Private helper-to-helper protocol. Requests travel on stdin over SSH,
/// not through a configurable shell hook. No repository credentials cross
/// this channel. Only protocol-versioned, typed operations are accepted.
public struct SyncEndpointRequest: Codable, Sendable {
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
}
