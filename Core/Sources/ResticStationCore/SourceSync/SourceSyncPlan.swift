import Foundation

public struct SyncItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, directory, symbolicLink }
    public var kind: Kind
    public var digest: String
    public var bytes: UInt64
    public var mode: UInt16

    public init(kind: Kind = .file, digest: String, bytes: UInt64 = 0, mode: UInt16 = 0o600) {
        self.kind = kind
        self.digest = digest
        self.bytes = bytes
        self.mode = mode
    }
}

public struct SyncInventory: Codable, Equatable, Sendable {
    public var rootIdentity: String
    public var items: [String: SyncItem]
    public var endpointGeneration: UUID?

    public init(rootIdentity: String, items: [String: SyncItem], endpointGeneration: UUID? = nil) {
        self.rootIdentity = rootIdentity
        self.items = items
        self.endpointGeneration = endpointGeneration
    }

    public var fingerprint: String {
        // ConfigStore's sorted-key encoder makes this independent of
        // filesystem enumeration order on either platform.
        get throws { SHA256Digest.hex(try ConfigStore.makeEncoder().encode(self)) }
    }
}

/// The last state verified at both copies. A missing baseline is explicitly
/// first-run reconciliation, not permission to pick a winner.
public struct SyncBaseline: Codable, Equatable, Sendable {
    public var generation: UUID
    public var groupFingerprint: String
    public var localRootIdentity: String
    public var peerRootIdentity: String
    public var agreed: [String: SyncItem]
    public var localEndpointGeneration: UUID?
    public var peerEndpointGeneration: UUID?

    public init(
        generation: UUID = UUID(), groupFingerprint: String,
        localRootIdentity: String, peerRootIdentity: String,
        agreed: [String: SyncItem], localEndpointGeneration: UUID? = nil,
        peerEndpointGeneration: UUID? = nil
    ) {
        self.generation = generation
        self.groupFingerprint = groupFingerprint
        self.localRootIdentity = localRootIdentity
        self.peerRootIdentity = peerRootIdentity
        self.agreed = agreed
        self.localEndpointGeneration = localEndpointGeneration
        self.peerEndpointGeneration = peerEndpointGeneration
    }
}

public struct SyncChange: Codable, Equatable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable {
        case copyToLocal, copyToPeer, removeLocal, removePeer, conflict
    }
    public var path: String
    public var action: Action
    public var local: SyncItem?
    public var peer: SyncItem?
    public var id: String { path }
}

public struct SourceSyncPlan: Codable, Equatable, Sendable {
    public var groupId: UUID
    public var groupFingerprint: String
    public var local: SyncInventory
    public var peer: SyncInventory
    public var baselineGeneration: UUID?
    public var changes: [SyncChange]

    public var conflicts: [SyncChange] { changes.filter { $0.action == .conflict } }
    public var requiresProtection: Bool {
        changes.contains {
            ($0.action == .copyToLocal && $0.local != nil)
                || ($0.action == .copyToPeer && $0.peer != nil)
                || $0.action == .removeLocal || $0.action == .removePeer
        }
    }
}

public enum SourceSyncPlanner {
    public static func plan(
        group: SourceSyncGroup, local: SyncInventory, peer: SyncInventory,
        baseline: SyncBaseline?
    ) throws -> SourceSyncPlan {
        let fingerprint = try group.bindingFingerprint
        if let baseline {
            guard baseline.groupFingerprint == fingerprint,
                  baseline.localRootIdentity == local.rootIdentity,
                  baseline.peerRootIdentity == peer.rootIdentity,
                  baseline.localEndpointGeneration == local.endpointGeneration,
                  baseline.peerEndpointGeneration == peer.endpointGeneration else {
                throw SourceSyncError.stateInvalid("A folder or its settings changed. Reconcile the copies before continuing.")
            }
        }
        let paths = Set(local.items.keys).union(peer.items.keys).union(baseline?.agreed.keys.map { $0 } ?? [])
        // Each tree can be unambiguous by itself while their union is not
        // ("Notes" on one copy, "notes" on the other). Refuse before either
        // value is installed on a case-insensitive filesystem.
        let folded = Dictionary(grouping: paths) { $0.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX")) }
        let ambiguous = Set(folded.values.filter { $0.count > 1 }.flatMap { $0 })
        var changes: [SyncChange] = []
        for path in paths.sorted() {
            guard isRelativePath(path) else {
                throw SourceSyncError.stateInvalid("An inventory contains an unsafe relative path.")
            }
            let l = local.items[path], r = peer.items[path]
            if l == r { continue }
            let b = baseline?.agreed[path]
            var action: SyncChange.Action
            if l == b {
                action = r == nil ? .removeLocal : .copyToLocal
            } else if r == b {
                action = l == nil ? .removePeer : .copyToPeer
            } else {
                action = .conflict
            }
            if ambiguous.contains(path) || (l != nil && r != nil && (l?.kind != r?.kind || l?.kind == .directory)) {
                action = .conflict
            }
            changes.append(.init(path: path, action: action, local: l, peer: r))
        }
        // A conflict or structural change at a directory governs its whole
        // subtree. Never execute a child's transfer through an ancestor
        // whose identity/type is changing or awaiting a decision.
        // A newly created child or a conflicting edit blocks deleting its
        // ancestor. Straight one-sided subtree deletion stays executable,
        // with children removed before their empty parent.
        for index in changes.indices {
            let change = changes[index]
            if (change.action == .removeLocal && change.local?.kind == .directory)
                || (change.action == .removePeer && change.peer?.kind == .directory) {
                if changes.contains(where: { $0.path.hasPrefix(change.path + "/") && $0.action != change.action }) {
                    changes[index].action = .conflict
                }
            }
        }
        let barriers = changes.filter { $0.action == .conflict }.map(\.path)
        for index in changes.indices {
            if barriers.contains(where: { changes[index].path.hasPrefix($0 + "/") }) {
                changes[index].action = .conflict
            }
        }
        return SourceSyncPlan(
            groupId: group.id, groupFingerprint: fingerprint, local: local, peer: peer,
            baselineGeneration: baseline?.generation, changes: changes
        )
    }

    static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}
