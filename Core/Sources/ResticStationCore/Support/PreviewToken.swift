import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One destination's exact, attributed snapshot ids in a destructive preview.
public struct PreviewTokenDestination: Codable, Equatable, Sendable {
    public let destinationId: UUID
    public let snapshotIDs: [String]

    public init(destinationId: UUID, snapshotIDs: [String]) {
        self.destinationId = destinationId
        self.snapshotIDs = snapshotIDs.sorted()
    }
}

/// Helper-private evidence required to consume a standalone-prune preview.
/// The secret-sensitive fingerprint stays in helper/engine memory and is
/// never serialized into the app's command line or JSON response.
public struct MaintenancePruneAuthorization: Sendable {
    public let token: String
    public let machineId: String
    public let effectiveDestinationFingerprint: String
    /// Canonical executable selected and hashed for this helper invocation.
    /// It stays helper-private and is never emitted in CLI JSON or logs.
    public let resticExecutablePath: String?
    public let resticExecutableIdentity: String?

    public init(
        token: String,
        machineId: String,
        effectiveDestinationFingerprint: String,
        resticExecutablePath: String? = nil,
        resticExecutableIdentity: String? = nil
    ) {
        self.token = token
        self.machineId = machineId
        self.effectiveDestinationFingerprint = effectiveDestinationFingerprint
        self.resticExecutablePath = resticExecutablePath
        self.resticExecutableIdentity = resticExecutableIdentity
    }
}

/// The persisted capability behind a destructive purge, retention, or
/// standalone-prune action.
///
/// The opaque `value` is intentionally only ever written to the owner-only
/// ``PreviewTokenStore`` index and returned by a successful preview.  It
/// never belongs in a run record, run log, or error envelope.
public struct PreviewToken: Codable, Equatable, Sendable {
    public let value: String
    public let machineId: String
    public let setId: UUID
    public let destinations: [PreviewTokenDestination]
    public let configFingerprint: String
    public let patterns: [String]
    public let createdAt: Date
    public let expiresAt: Date
    public var usedAt: Date?

    public init(
        value: String,
        machineId: String,
        setId: UUID,
        destinations: [PreviewTokenDestination],
        configFingerprint: String,
        patterns: [String],
        createdAt: Date,
        expiresAt: Date,
        usedAt: Date? = nil
    ) {
        self.value = value
        self.machineId = machineId
        self.setId = setId
        self.destinations = destinations.sorted { $0.destinationId.uuidString < $1.destinationId.uuidString }
        self.configFingerprint = configFingerprint
        self.patterns = patterns
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.usedAt = usedAt
    }
}

/// Fail-closed failures while looking up or consuming a destructive preview.
/// None carries the token value: an error can safely reach a bounded CLI
/// message without leaking a live capability.
public enum PreviewTokenError: Error, Equatable, Sendable {
    /// The store could not be reached right now — including its lock being
    /// held by another process, which is transient and worth retrying.
    case unavailable
    /// The store itself is unusable: its lock file is unopenable, owned by
    /// another user, or its directory cannot be created. Kept apart from
    /// ``unavailable`` because retrying never clears it (#110).
    case storeUnusable(String)
    case unknown
    case expired
    case alreadyUsed
}

/// Owner-only on-disk store for short-lived destructive-operation previews.
///
/// The token value is a 256-bit CSPRNG capability.  Entries are retained
/// briefly after use/expiry so a replay gets a deliberate refusal rather than
/// looking like a missing token; old entries are swept during every write.
public struct PreviewTokenStore: Sendable {
    public static let defaultLifetime: TimeInterval = 15 * 60
    private static let retentionAfterExpiry: TimeInterval = 24 * 60 * 60

    public let paths: AppPaths
    private let now: @Sendable () -> Date

    public init(paths: AppPaths, now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.now = now
    }

    public func issue(
        machineId: String,
        setId: UUID,
        destinations: [PreviewTokenDestination],
        config: AppConfig,
        patterns: [String],
        executableIdentity: String,
        lifetime: TimeInterval = defaultLifetime
    ) throws -> PreviewToken {
        try withStoreLock {
            let createdAt = now()
            var index = try readIndex()
            discardExpiredEntries(from: &index, at: createdAt)
            let token = PreviewToken(
                value: Self.randomValue(),
                machineId: machineId,
                setId: setId,
                destinations: destinations,
                configFingerprint: try Self.purgeFingerprint(config, executableIdentity: executableIdentity),
                patterns: patterns,
                createdAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(lifetime)
            )
            index.tokens[token.value] = token
            try writeIndex(index)
            return token
        }
    }

    /// Issues the opaque capability for a standalone prune dry run. Unlike a
    /// purge token, the fingerprint is supplied by the helper after it has
    /// included the destination's secret environment; only the owner-only
    /// token index ever contains that fingerprint.
    public func issueMaintenancePrune(
        machineId: String,
        setId: UUID,
        destinationId: UUID,
        effectiveDestinationFingerprint: String,
        lifetime: TimeInterval = defaultLifetime
    ) throws -> String {
        try withStoreLock {
            let createdAt = now()
            var index = try readIndex()
            discardExpiredEntries(from: &index, at: createdAt)
            let token = PreviewToken(
                value: Self.randomValue(),
                machineId: machineId,
                setId: setId,
                destinations: [PreviewTokenDestination(destinationId: destinationId, snapshotIDs: [])],
                configFingerprint: effectiveDestinationFingerprint,
                patterns: ["maintenance-prune"],
                createdAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(lifetime)
            )
            index.tokens[token.value] = token
            try writeIndex(index)
            return token.value
        }
    }

    /// Consumes a standalone-prune capability only when this helper's freshly
    /// loaded effective destination is identical to the one its dry run used.
    /// A mismatch is deliberately `unknown`: callers get one fail-closed
    /// message without learning whether a token is valid or how it differed.
    public func consumeMaintenancePrune(
        _ value: String,
        machineId: String,
        setId: UUID,
        destinationId: UUID,
        effectiveDestinationFingerprint: String
    ) throws {
        try withStoreLock {
            var index = try readIndex()
            guard var token = index.tokens[value] else { throw PreviewTokenError.unknown }
            let consumedAt = now()
            if token.expiresAt <= consumedAt { throw PreviewTokenError.expired }
            if token.usedAt != nil { throw PreviewTokenError.alreadyUsed }
            guard token.machineId == machineId,
                  token.setId == setId,
                  token.destinations == [PreviewTokenDestination(destinationId: destinationId, snapshotIDs: [])],
                  token.configFingerprint == effectiveDestinationFingerprint,
                  token.patterns == ["maintenance-prune"] else {
                throw PreviewTokenError.unknown
            }
            token.usedAt = consumedAt
            index.tokens[value] = token
            discardExpiredEntries(from: &index, at: consumedAt)
            try writeIndex(index)
        }
    }

    /// Restores a standalone-prune capability after a confirmed process
    /// launch failure. The caller may invoke this only when the process
    /// runner guarantees that no child was started; a failed restoration
    /// leaves the token consumed, which is the safer failure mode.
    public func restoreMaintenancePrune(
        _ value: String,
        machineId: String,
        setId: UUID,
        destinationId: UUID,
        effectiveDestinationFingerprint: String
    ) throws {
        try withStoreLock {
            var index = try readIndex()
            guard var token = index.tokens[value] else { throw PreviewTokenError.unknown }
            guard token.usedAt != nil,
                  token.machineId == machineId,
                  token.setId == setId,
                  token.destinations == [PreviewTokenDestination(destinationId: destinationId, snapshotIDs: [])],
                  token.configFingerprint == effectiveDestinationFingerprint,
                  token.patterns == ["maintenance-prune"] else {
                throw PreviewTokenError.unknown
            }
            token.usedAt = nil
            index.tokens[value] = token
            try writeIndex(index)
        }
    }

    /// Reads a token without consuming it.  Callers must perform every
    /// repository/config check before invoking ``consume(_:)``.
    public func token(_ value: String) throws -> PreviewToken {
        try withStoreLock {
            let index = try readIndex()
            guard let token = index.tokens[value] else { throw PreviewTokenError.unknown }
            if token.expiresAt <= now() { throw PreviewTokenError.expired }
            if token.usedAt != nil { throw PreviewTokenError.alreadyUsed }
            return token
        }
    }

    /// Atomically-ish records consumption after the caller has revalidated
    /// the plan, making any later replay fail closed.  The set lock held by
    /// the engine serializes competing applies for the same set.
    public func consume(_ value: String) throws -> PreviewToken {
        try withStoreLock {
            var index = try readIndex()
            guard var token = index.tokens[value] else { throw PreviewTokenError.unknown }
            let consumedAt = now()
            if token.expiresAt <= consumedAt { throw PreviewTokenError.expired }
            if token.usedAt != nil { throw PreviewTokenError.alreadyUsed }
            token.usedAt = consumedAt
            index.tokens[value] = token
            discardExpiredEntries(from: &index, at: consumedAt)
            try writeIndex(index)
            return token
        }
    }

    /// Restores a purge capability after the caller proves that no child
    /// received the destructive argv. The complete issued token is matched,
    /// not just its opaque value, so this cannot revive a replaced or
    /// otherwise changed capability. Failure deliberately leaves it spent.
    public func restore(_ value: String, matching expected: PreviewToken) throws {
        try withStoreLock {
            var index = try readIndex()
            guard var token = index.tokens[value], token.usedAt != nil else {
                throw PreviewTokenError.unknown
            }
            token.usedAt = nil
            guard token == expected else { throw PreviewTokenError.unknown }
            index.tokens[value] = token
            try writeIndex(index)
        }
    }

    /// SHA-256 of the canonical persisted configuration bytes.  A full
    /// config change invalidates a destructive preview rather than trying to
    /// guess whether the changed field was relevant to an operation.
    public static func configFingerprint(_ config: AppConfig) throws -> String {
        let data = try ConfigStore.makeEncoder().encode(config)
        return SHA256Digest.hex(data)
    }

    /// What a **purge** token binds. Config alone left a gap the maintenance
    /// binding did not have: `pruneConfirmationFingerprint` also covers the
    /// restic executable's identity, so an in-place binary swap between
    /// preview and apply invalidates a reclaim confirmation but did not
    /// invalidate a purge one — even though purge is the operation that
    /// rewrites snapshot history.
    ///
    /// `executableIdentity` is **nonoptional**, and that is the point rather
    /// than tidiness. It used to accept `nil` and fold it to the literal
    /// `"none"`, so a token minted while restic was missing bound no
    /// executable at all — and an apply that also saw no restic recomputed
    /// the same `"none"` fingerprint and matched. Both halves agreeing on
    /// "no binary" authorized a `rewrite --forget` by whatever binary turned
    /// up in between. Making the parameter nonoptional means an unbound
    /// destructive capability cannot be expressed, instead of every caller
    /// having to remember a guard (#109 exact-head review).
    public static func purgeFingerprint(
        _ config: AppConfig,
        executableIdentity: String
    ) throws -> String {
        let base = try configFingerprint(config)
        return SHA256Digest.hex(Data("\(base):\(executableIdentity)".utf8))
    }

    private struct Index: Codable, Sendable {
        var tokens: [String: PreviewToken] = [:]
    }

    /// The token index is global to the local machine, while set locks are
    /// per backup set. This separate lock prevents two previews for different
    /// sets from losing one another's entries, and makes consume/replay
    /// behavior single-use even across helper processes.
    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        do {
            do {
                try paths.ensureDirectories()
            } catch {
                throw PreviewTokenError.storeUnusable(
                    "could not create the data directories under \(paths.root.path): \(error)"
                )
            }
            let lock = FileLock(path: paths.previewTokensLockFile, trustedRoot: paths.root)
            // Owner-only is now enforced by `FileLock` itself, on the open
            // descriptor rather than by a `chmod` on the path after the fact
            // — the same check, without the window between them, and it
            // refuses a lock file belonging to another user instead of
            // trying to take it over.
            switch lock.acquire() {
            case .acquired:
                break
            case .busy:
                throw PreviewTokenError.unavailable
            case .failed(let failure):
                throw PreviewTokenError.storeUnusable(String(describing: failure))
            }
            defer { lock.release() }
            return try body()
        } catch let error as PreviewTokenError {
            throw error
        } catch {
            throw PreviewTokenError.unavailable
        }
    }

    private func readIndex() throws -> Index {
        let url = paths.previewTokensFile
        guard FileManager.default.fileExists(atPath: url.path) else { return Index() }
        guard Self.isOwnerOnly(url) else { throw PreviewTokenError.unavailable }
        do {
            return try ConfigStore.makeDecoder().decode(Index.self, from: Data(contentsOf: url))
        } catch {
            throw PreviewTokenError.unavailable
        }
    }

    private func writeIndex(_ index: Index) throws {
        do {
            try paths.ensureDirectories()
            let target = paths.previewTokensFile
            let temp = target.deletingLastPathComponent()
                .appendingPathComponent(target.lastPathComponent + ".tmp", isDirectory: false)
            let data = try ConfigStore.makeEncoder().encode(index)
            try Self.writeOwnerOnly(data, to: temp)
            try AtomicFile.rename(from: temp, to: target)
            _ = chmod(target.path, 0o600)
        } catch {
            throw PreviewTokenError.unavailable
        }
    }

    private func discardExpiredEntries(from index: inout Index, at date: Date) {
        index.tokens = index.tokens.filter { _, token in
            token.expiresAt.addingTimeInterval(Self.retentionAfterExpiry) > date
        }
    }

    private static func randomValue() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isOwnerOnly(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return mode.intValue & 0o077 == 0
    }

    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        let path = url.path
        _ = unlink(path)
        // O_EXCL|O_NOFOLLOW: refuse to write through a symlink or into a file
        // someone else recreated between the unlink and the open. The 0700
        // root makes that unreachable cross-user today, which is exactly why
        // it should stay unreachable if the root is ever loosened.
        let fd = path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { throw PreviewTokenError.unavailable }
        defer {
            #if canImport(Darwin)
            _ = Darwin.close(fd)
            #elseif canImport(Glibc)
            _ = Glibc.close(fd)
            #elseif canImport(Musl)
            _ = Musl.close(fd)
            #endif
        }
        let wroteAll = data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return data.isEmpty }
            var remaining = data.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written <= 0 { return false }
                pointer += written
                remaining -= written
            }
            return true
        }
        guard wroteAll, chmod(path, 0o600) == 0 else { throw PreviewTokenError.unavailable }
    }
}
