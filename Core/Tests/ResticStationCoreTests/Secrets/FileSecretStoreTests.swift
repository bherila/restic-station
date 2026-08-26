import Foundation
import Testing
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private final class WarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(message)
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// `FileSecretStore` specifics: permissions, atomicity, locking, and the
/// `RESTIC_PASSWORD_COMMAND` string.
///
/// Deliberately **not** gated to Linux. The file backend is Linux's default
/// but works everywhere, and running this suite on macOS (locally and in the
/// macOS CI job) is the only way this repository gets real coverage of the
/// Linux secrets path before T29 adds a Linux integration matrix.
@Suite("FileSecretStore")
struct FileSecretStoreTests {
    static let destId = UUID(uuidString: "A1B2C3D4-E5F6-4789-A012-3456789ABCDE")!
    static let otherId = UUID(uuidString: "B1B2C3D4-E5F6-4789-A012-3456789ABCDE")!

    /// A store over a fresh temp root, and the root so the caller can clean up.
    static func makeStore(helperPath: String = "/opt/restic-station/restic-station-helper")
        -> (store: FileSecretStore, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("restic-station-file-secrets-\(UUID().uuidString)", isDirectory: true)
        return (FileSecretStore(paths: AppPaths(root: root), helperPath: helperPath), root)
    }

    static func permissions(of url: URL) throws -> UInt32 {
        var info = stat()
        let ok = url.path.withCString { stat($0, &info) }
        try #require(ok == 0, "stat failed for \(url.path)")
        return UInt32(info.st_mode) & 0o777
    }

    static func modeBits(of url: URL) throws -> UInt32 {
        var info = stat()
        let ok = url.path.withCString { stat($0, &info) }
        try #require(ok == 0, "stat failed for \(url.path)")
        return UInt32(info.st_mode) & 0o7777
    }

    static func owner(of url: URL) throws -> uid_t {
        var info = stat()
        let ok = url.path.withCString { stat($0, &info) }
        try #require(ok == 0, "stat failed for \(url.path)")
        return info.st_uid
    }

    @Test("conditional rollback preserves a newer password and restores the unchanged environment")
    func conditionalRollbackRestoresFieldsIndependently() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("editor-password", destId: Self.destId)
        try await store.setSecretEnv(["TOKEN": "editor"], destId: Self.destId)
        let rollback = DestinationSecretRollback(
            destId: Self.destId,
            password: SecretRollbackChange(
                installed: "editor-password",
                previous: "original-password"
            ),
            secretEnv: SecretRollbackChange(
                installed: ["TOKEN": "editor"],
                previous: ["TOKEN": "original"]
            )
        )
        try await store.setPassword("newer-helper-password", destId: Self.destId)

        let result = try await store.restoreDestinationSecretsIfCurrent(rollback)

        #expect(result.passwordRestored == false)
        #expect(result.secretEnvRestored == true)
        #expect(!result.allRestored)
        #expect(try await store.password(destId: Self.destId) == "newer-helper-password")
        #expect(try await store.secretEnv(destId: Self.destId) == ["TOKEN": "original"])
    }

    @Test("conditional rollback preserves same-value writes from another process")
    func conditionalRollbackUsesPersistentGenerations() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("original-password", destId: Self.destId)
        try await store.setSecretEnv(["TOKEN": "original"], destId: Self.destId)
        let rollback = try await store.updateDestinationSecrets(
            DestinationSecretUpdate(
                destId: Self.destId,
                password: "editor-password",
                secretEnv: [:]
            )
        )

        // These helper-style mutations are value-identical to the app's
        // installation, including deletion of an already-absent env item.
        try await store.setPassword("editor-password", destId: Self.destId)
        try await store.deleteSecretEnv(destId: Self.destId)

        let result = try await store.restoreDestinationSecretsIfCurrent(rollback)

        #expect(result.passwordRestored == false)
        #expect(result.secretEnvRestored == false)
        #expect(try await store.password(destId: Self.destId) == "editor-password")
        #expect(try await store.secretEnv(destId: Self.destId).isEmpty)
    }

    @Test("a valid environment edit can replace and roll back a malformed secrets-file blob")
    func malformedEnvironmentCanBeRepairedAndRestored() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.setPassword("password", destId: Self.destId)

        let account = SecretAccount.secretEnv(Self.destId)
        let malformedRaw = "{not-json"
        let document: [String: Any] = [
            "version": 1,
            "secrets": [
                SecretAccount.password(Self.destId): "password",
                account: malformedRaw,
            ],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: store.fileURL)

        let rollback = try await store.updateDestinationSecrets(
            DestinationSecretUpdate(
                destId: Self.destId,
                password: nil,
                secretEnv: ["TOKEN": "repaired"]
            )
        )
        #expect(rollback.previousSecretEnvRaw == malformedRaw)
        #expect(try await store.secretEnv(destId: Self.destId) == ["TOKEN": "repaired"])

        let result = try await store.restoreDestinationSecretsIfCurrent(rollback)
        let restoredDocument = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        )
        let restoredSecrets = try #require(restoredDocument["secrets"] as? [String: String])
        #expect(result.secretEnvRestored == true)
        #expect(restoredSecrets[account] == malformedRaw)
    }

    @Test("a version-1 file is readable and upgrades before generation metadata is persisted")
    func legacyFileUpgradesWhenMutationGenerationsAreWritten() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy: [String: Any] = [
            "version": 1,
            "secrets": [SecretAccount.password(Self.destId): "legacy-password"],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)

        try await store.setPassword("current-password", destId: Self.destId)

        let upgraded = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        )
        #expect(upgraded["version"] as? Int == 2)
        let generations = try #require(upgraded["generations"] as? [String: String])
        #expect(generations[SecretAccount.password(Self.destId)] != nil)
    }

    // MARK: - Permissions at creation

    @Test("the secrets file is created 0600 and its directory 0700, at creation time")
    func createsWithTightModes() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!FileManager.default.fileExists(atPath: root.path))

        try await store.setPassword("hunter2", destId: Self.destId)

        #expect(try Self.permissions(of: store.fileURL) == 0o600)
        #expect(try Self.permissions(of: root) == 0o700)
    }

    @Test("an existing data directory is tightened after ensureDirectories then secret set")
    func tightensDataDirectoryCreatedBeforeSecretSet() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)

        try paths.ensureDirectories()
        try #require(root.path.withCString { chmod($0, 0o755) } == 0)
        #expect(try Self.permissions(of: root) == 0o755)

        try await store.setPassword("hunter2", destId: Self.destId)

        #expect(try Self.permissions(of: root) == 0o700)
        #expect(try Self.permissions(of: store.fileURL) == 0o600)
    }

    @Test("a directory that remains group-writable is refused before storing a secret")
    func refusesDirectoryThatRemainsWritable() async throws {
        let (_, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(root.path.withCString { chmod($0, 0o770) } == 0)
        let warnings = WarningRecorder()
        let store = FileSecretStore(
            paths: AppPaths(root: root),
            helperPath: "/opt/restic-station/restic-station-helper",
            directoryModeSetter: { _, _ in },
            warningHandler: { warnings.record($0) }
        )

        do {
            try await store.setPassword("hunter2", destId: Self.destId)
            Issue.record("expected a group-writable secrets directory to be refused")
        } catch let error as SecretStoreError {
            guard case .backendFailed(let message) = error else {
                Issue.record("expected .backendFailed, got \(error)")
                return
            }
            #expect(message.contains(root.path))
            #expect(message.contains("write-and-search"))
            #expect(message.contains("0770"))
            #expect(message.contains("replace secrets.json"))
            // This message is only reachable once our own chmod has failed, so
            // it must name a remedy that isn't the command we just ran — a
            // mode-forcing mount ignores the operator's chmod too. See #60.
            #expect(message.contains("RESTIC_STATION_DATA_DIR"))
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(warnings.messages.isEmpty)
    }

    @Test("a sticky writable directory is accepted because other users cannot replace entries")
    func acceptsStickyWritableDirectory() async throws {
        let (_, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(root.path.withCString { chmod($0, 0o1777) } == 0)
        let warnings = WarningRecorder()
        let store = FileSecretStore(
            paths: AppPaths(root: root),
            helperPath: "/opt/restic-station/restic-station-helper",
            directoryModeSetter: { _, _ in },
            warningHandler: { warnings.record($0) }
        )

        try await store.setPassword("hunter2", destId: Self.destId)

        #expect(try Self.modeBits(of: root) == 0o1777)
        #expect(try Self.permissions(of: store.fileURL) == 0o600)
        #expect(try await store.password(destId: Self.destId) == "hunter2")
        #expect(warnings.messages.count == 1)
    }

    @Test("write without search permission cannot replace entries and is not refused")
    func acceptsWriteWithoutSearchPermission() async throws {
        let modes: [mode_t] = [0o720, 0o702]
        for mode in modes {
            let (_, root) = Self.makeStore()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try #require(root.path.withCString { chmod($0, mode) } == 0)
            let warnings = WarningRecorder()
            let store = FileSecretStore(
                paths: AppPaths(root: root),
                helperPath: "/opt/restic-station/restic-station-helper",
                directoryModeSetter: { _, _ in },
                warningHandler: { warnings.record($0) }
            )

            try await store.setPassword("hunter2", destId: Self.destId)

            #expect(try Self.permissions(of: root) == UInt32(mode))
            #expect(try Self.permissions(of: store.fileURL) == 0o600)
            #expect(warnings.messages.isEmpty)
        }
    }

    @Test("a readable/searchable directory warns once but still stores a 0600 secret")
    func warnsForDirectoryThatRemainsReadable() async throws {
        let (_, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(root.path.withCString { chmod($0, 0o755) } == 0)
        let warnings = WarningRecorder()
        let store = FileSecretStore(
            paths: AppPaths(root: root),
            helperPath: "/opt/restic-station/restic-station-helper",
            directoryModeSetter: { _, _ in },
            warningHandler: { warnings.record($0) }
        )

        try await store.setPassword("hunter2", destId: Self.destId)

        #expect(try Self.permissions(of: root) == 0o755)
        #expect(try Self.permissions(of: store.fileURL) == 0o600)
        #expect(try await store.password(destId: Self.destId) == "hunter2")
        let messages = warnings.messages
        try #require(messages.count == 1)
        #expect(messages[0].contains(root.path))
        #expect(messages[0].contains("group or other users"))
        #expect(messages[0].contains("0755"))
        #expect(messages[0].contains("chmod 700"))
        // Same reachability argument as the refusal above: naming only the
        // chmod we already attempted is advice an operator can act on and
        // watch do nothing.
        #expect(messages[0].contains("RESTIC_STATION_DATA_DIR"))
    }

    @Test("search-only access warns once because fixed-path metadata is visible")
    func warnsOnceForSearchOnlyDirectory() async throws {
        let (_, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(root.path.withCString { chmod($0, 0o711) } == 0)
        let warnings = WarningRecorder()
        let store = FileSecretStore(
            paths: AppPaths(root: root),
            helperPath: "/opt/restic-station/restic-station-helper",
            directoryModeSetter: { _, _ in },
            warningHandler: { warnings.record($0) }
        )

        try await store.setPassword("hunter2", destId: Self.destId)

        #expect(try Self.permissions(of: store.fileURL) == 0o600)
        let messages = warnings.messages
        try #require(messages.count == 1)
        #expect(messages[0].contains("0711"))
        #expect(messages[0].contains("metadata"))
        #expect(!messages[0].contains("destination"))
    }

    @Test("a writable non-sticky immediate parent is refused")
    func refusesWritableImmediateParent() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-parent-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("data", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(base.path.withCString { chmod($0, 0o770) } == 0)
        try #require(root.path.withCString { chmod($0, 0o700) } == 0)
        let store = FileSecretStore(
            paths: AppPaths(root: root),
            helperPath: "/opt/restic-station/restic-station-helper"
        )

        do {
            try await store.setPassword("hunter2", destId: Self.destId)
            Issue.record("expected a writable non-sticky parent to be refused")
        } catch let error as SecretStoreError {
            guard case .backendFailed(let message) = error else {
                Issue.record("expected .backendFailed, got \(error)")
                return
            }
            #expect(message.contains(base.path))
            #expect(message.contains("parent directory"))
            #expect(message.contains("0770"))
            #expect(message.contains("rename or replace"))
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("a sticky writable immediate parent protects the data directory entry")
    func acceptsStickyWritableImmediateParent() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-parent-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("data", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(base.path.withCString { chmod($0, 0o1777) } == 0)
        try #require(root.path.withCString { chmod($0, 0o700) } == 0)
        let store = FileSecretStore(
            paths: AppPaths(root: root),
            helperPath: "/opt/restic-station/restic-station-helper"
        )

        try await store.setPassword("hunter2", destId: Self.destId)

        #expect(try Self.permissions(of: store.fileURL) == 0o600)
    }

    @Test("trusted ownership is self-or-root for users, but root-only for root")
    func trustedOwnershipPolicy() {
        #expect(FileSecretStore.isTrustedOwner(0, effectiveUID: 0))
        #expect(!FileSecretStore.isTrustedOwner(501, effectiveUID: 0))
        #expect(FileSecretStore.isTrustedOwner(501, effectiveUID: 501))
        #expect(FileSecretStore.isTrustedOwner(0, effectiveUID: 501))
        #expect(!FileSecretStore.isTrustedOwner(502, effectiveUID: 501))
    }

    @Test("a root helper refuses a non-root-owned secrets directory")
    func rootRefusesUntrustedSecretsDirectory() async throws {
        let (_, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(root.path.withCString { chmod($0, 0o700) } == 0)

        let untrustedOwner: uid_t
        if geteuid() == 0 {
            untrustedOwner = 65_534
            try #require(root.path.withCString { chown($0, untrustedOwner, gid_t.max) } == 0)
        } else {
            untrustedOwner = geteuid()
        }

        let store = FileSecretStore(
            paths: AppPaths(root: root),
            helperPath: "/opt/restic-station/restic-station-helper",
            directoryModeSetter: { _, _ in },
            warningHandler: { _ in },
            effectiveUserID: { 0 }
        )

        do {
            try await store.setPassword("hunter2", destId: Self.destId)
            Issue.record("expected root to refuse a non-root-owned secrets directory")
        } catch let error as SecretStoreError {
            guard case .backendFailed(let message) = error else {
                Issue.record("expected .backendFailed, got \(error)")
                return
            }
            #expect(message.contains(root.path))
            #expect(message.contains("owned by uid \(untrustedOwner)"))
            #expect(message.contains("root (uid 0)"))
            #expect(message.contains("RESTIC_STATION_DATA_DIR"))
            #expect(!message.contains("hunter2"))
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("the temp file a write goes through is itself created 0600")
    func tempFileIsAlsoTight() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // Pre-create the temp path world-readable, exactly as a crashed write
        // under a permissive umask might have left it. The next write must
        // unlink it and create a fresh 0600 one rather than reuse it (open(2)
        // ignores `mode` for an existing file).
        try store.prepareDirectories()
        FileManager.default.createFile(
            atPath: store.tempFileURL.path,
            contents: Data("stale".utf8),
            attributes: [.posixPermissions: 0o644]
        )
        #expect(try Self.permissions(of: store.tempFileURL) == 0o644)

        try await store.setPassword("hunter2", destId: Self.destId)

        #expect(try Self.permissions(of: store.fileURL) == 0o600)
        #expect(try await store.password(destId: Self.destId) == "hunter2")
    }

    @Test("a temp-file chmod failure cannot report a successful secret write")
    func tempFileChmodFailureIsFatalAndCleanedUp() async throws {
        let (_, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSecretStore(
            paths: AppPaths(root: root),
            helperPath: "/opt/restic-station/restic-station-helper",
            directoryModeSetter: { path, mode in
                _ = path.withCString { chmod($0, mode) }
            },
            warningHandler: { _ in },
            fileModeSetter: { _, _ in EPERM }
        )

        do {
            try await store.setPassword("hunter2", destId: Self.destId)
            Issue.record("expected an unenforceable temp-file mode to fail")
        } catch let error as SecretStoreError {
            guard case .backendFailed(let message) = error else {
                Issue.record("expected .backendFailed, got \(error)")
                return
            }
            #expect(message.contains(store.tempFileURL.path))
            #expect(message.contains("mode 0600"))
            #expect(!message.contains("hunter2"))
        }
        #expect(!FileManager.default.fileExists(atPath: store.tempFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("an unusable secrets mutation lock stays typed and non-retryable")
    func unusableMutationLockIsTyped() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: store.lockFileURL,
            withIntermediateDirectories: true
        )

        do {
            try await store.setPassword("hunter2", destId: Self.destId)
            Issue.record("expected the hostile secrets lock to be refused")
        } catch let error as SecretStoreError {
            guard case .lockUnusable(let failure) = error else {
                Issue.record("expected .lockUnusable, got \(error)")
                return
            }
            #expect(failure.path == store.lockFileURL.path)
            #expect(!CLIFailure.classify(error).retryable)
            #expect(CLIFailure.classify(error).code == .internalError)
        }
    }

    @Test("an unremovable temp entry reports its owner and an actionable recovery")
    func diagnosesSquattedTempEntry() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.prepareDirectories()
        try FileManager.default.createDirectory(
            at: store.tempFileURL,
            withIntermediateDirectories: false
        )
        let owner = try Self.owner(of: store.tempFileURL)

        do {
            try await store.setPassword("hunter2", destId: Self.destId)
            Issue.record("expected an unremovable temporary entry to be refused")
        } catch let error as SecretStoreError {
            guard case .backendFailed(let message) = error else {
                Issue.record("expected .backendFailed, got \(error)")
                return
            }
            #expect(message.contains(store.tempFileURL.path))
            #expect(message.contains("owned by uid \(owner)"))
            #expect(message.contains("Remove that entry"))
            #expect(message.contains("RESTIC_STATION_DATA_DIR"))
            #expect(!message.contains("hunter2"))
        }
        #expect(FileManager.default.fileExists(atPath: store.tempFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: - Permissions on read

    @Test("a 0644 secrets file is refused on read, with the file name and the chmod to run")
    func refusesWorldReadableFile() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("hunter2", destId: Self.destId)
        _ = store.fileURL.path.withCString { chmod($0, 0o644) }

        do {
            _ = try await store.password(destId: Self.destId)
            Issue.record("expected a group/world-readable secrets file to be refused")
        } catch let error as SecretStoreError {
            guard case .backendFailed(let message) = error else {
                Issue.record("expected .backendFailed, got \(error)")
                return
            }
            #expect(message.contains(store.fileURL.path))
            #expect(message.contains("chmod 600"))
            #expect(message.contains("0644"))
            // Never the secret itself.
            #expect(!message.contains("hunter2"))
        }
    }

    @Test("a group-readable (0640) secrets file is refused too")
    func refusesGroupReadableFile() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("hunter2", destId: Self.destId)
        _ = store.fileURL.path.withCString { chmod($0, 0o640) }

        await #expect(throws: SecretStoreError.self) {
            _ = try await store.password(destId: Self.destId)
        }
    }

    @Test("0400 is accepted — the rule is 'no group/other bits', not 'exactly 0600'")
    func acceptsOwnerOnlyReadOnly() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("hunter2", destId: Self.destId)
        _ = store.fileURL.path.withCString { chmod($0, 0o400) }

        #expect(try await store.password(destId: Self.destId) == "hunter2")
    }

    @Test("a root helper refuses a non-root-owned 0600 secrets file")
    func rootRefusesUntrustedSecretsFile() async throws {
        let (writer, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writer.setPassword("hunter2", destId: Self.destId)

        let untrustedOwner: uid_t
        if geteuid() == 0 {
            untrustedOwner = 65_534
            let changed = writer.fileURL.path.withCString {
                chown($0, untrustedOwner, gid_t.max)
            }
            try #require(changed == 0)
        } else {
            untrustedOwner = geteuid()
        }
        try #require(try Self.permissions(of: writer.fileURL) == 0o600)

        let reader = FileSecretStore(
            paths: AppPaths(root: root),
            helperPath: "/opt/restic-station/restic-station-helper",
            directoryModeSetter: { _, _ in },
            warningHandler: { _ in },
            effectiveUserID: { 0 }
        )
        do {
            _ = try await reader.password(destId: Self.destId)
            Issue.record("expected root to refuse a non-root-owned secrets file")
        } catch let error as SecretStoreError {
            guard case .backendFailed(let message) = error else {
                Issue.record("expected .backendFailed, got \(error)")
                return
            }
            #expect(message.contains(reader.fileURL.path))
            #expect(message.contains("owned by uid \(untrustedOwner)"))
            #expect(message.contains("root (uid 0)"))
            #expect(message.contains("chown 0"))
            #expect(!message.contains("hunter2"))
        }
    }

    @Test("a symlink in place of the secrets file is refused, never followed")
    func refusesSymlink() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.prepareDirectories()
        let decoy = root.appendingPathComponent("decoy.json", isDirectory: false)
        try Data(#"{"version":1,"secrets":{}}"#.utf8).write(to: decoy)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: decoy)

        do {
            _ = try await store.password(destId: Self.destId)
            Issue.record("expected a symlinked secrets file to be refused")
        } catch let error as SecretStoreError {
            guard case .backendFailed(let message) = error else {
                Issue.record("expected .backendFailed, got \(error)")
                return
            }
            #expect(message.contains("symbolic link"))
        }
    }

    // MARK: - Atomicity

    @Test("a stale temp file left by a crashed write does not corrupt the real file")
    func staleTempFileIsHarmless() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("original", destId: Self.destId)

        // Simulate a crash between the temp write and the rename: half a JSON
        // document sitting at the temp path.
        try Data(#"{"version":1,"secrets":{"broken"#.utf8).write(to: store.tempFileURL)

        // The previous generation is still intact and readable…
        #expect(try await store.password(destId: Self.destId) == "original")

        // …and the next write overwrites the leftover rather than tripping on it.
        try await store.setPassword("replacement", destId: Self.destId)
        #expect(try await store.password(destId: Self.destId) == "replacement")
        #expect(!FileManager.default.fileExists(atPath: store.tempFileURL.path))
    }

    @Test("a file written by a newer format version is refused rather than overwritten")
    func refusesNewerVersion() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.prepareDirectories()
        try Data(#"{"version":99,"secrets":{}}"#.utf8).write(to: store.fileURL)
        _ = store.fileURL.path.withCString { chmod($0, 0o600) }

        await #expect(throws: SecretStoreError.self) {
            _ = try await store.password(destId: Self.destId)
        }
    }

    // MARK: - Concurrency

    @Test("concurrent writers under FileLock do not lose an entry")
    func concurrentWritesKeepEveryEntry() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let ids = (0..<12).map { _ in UUID() }
        let errors = WarningRecorder()
        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    // Each writer is its own read-modify-write of the whole
                    // file; without the lock the last one in would clobber the
                    // others.
                    do {
                        try await store.setPassword("pw-\(index)", destId: id)
                    } catch {
                        errors.record(String(describing: error))
                    }
                }
            }
        }

        #expect(errors.messages.isEmpty, "writers failed: \(errors.messages)")

        let document = try store.load()
        #expect(document.secrets.count == ids.count)
        for (index, id) in ids.enumerated() {
            #expect(try await store.password(destId: id) == "pw-\(index)")
        }
    }

    @Test("a concurrent delete and set both survive")
    func concurrentDeleteAndSet() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("doomed", destId: Self.destId)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await store.deletePassword(destId: Self.destId) }
            group.addTask { try? await store.setPassword("kept", destId: Self.otherId) }
        }

        #expect(try await store.password(destId: Self.otherId) == "kept")
        await #expect(throws: SecretStoreError.itemNotFound) {
            _ = try await store.password(destId: Self.destId)
        }
    }

    // MARK: - passwordCommand

    @Test("passwordCommand names the helper absolutely and passes the uuid, not the secret")
    func passwordCommandShape() {
        let (store, _) = Self.makeStore(helperPath: "/opt/restic-station/restic-station-helper")
        #expect(
            store.passwordCommand(destId: Self.destId)
                == "/opt/restic-station/restic-station-helper print-password "
                + "--dest a1b2c3d4-e5f6-4789-a012-3456789abcde"
        )
    }

    /// restic splits `RESTIC_PASSWORD_COMMAND` itself with a shell-like
    /// splitter that understands quotes but not backslash escapes (verified
    /// against restic 0.18.1 — see `docs/restic-cli.md` §General).
    @Test("passwordCommand double-quotes a helper path that needs it, and leaves plain paths bare")
    func passwordCommandQuoting() {
        #expect(FileSecretStore.quoteForRestic("/usr/local/bin/restic-station-helper")
            == "/usr/local/bin/restic-station-helper")
        #expect(FileSecretStore.quoteForRestic("/Applications/Restic Station.app/Contents/MacOS/helper")
            == "\"/Applications/Restic Station.app/Contents/MacOS/helper\"")
        #expect(FileSecretStore.quoteForRestic("/opt/it's/helper") == "\"/opt/it's/helper\"")
        #expect(FileSecretStore.quoteForRestic("/opt/$HOME/helper") == "\"/opt/$HOME/helper\"")
    }

    /// The password command spawns another copy of the helper, which
    /// re-resolves the store from *its own* environment — and `ResticRunner`
    /// replaces restic's environment wholesale. Without these two variables
    /// that child reads the default data directory with the platform-default
    /// backend, i.e. the wrong store.
    @Test("passwordCommandEnvironment points the child at this store, and holds no secret")
    func passwordCommandEnvironmentPointsAtThisStore() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("hunter2", destId: Self.destId)
        let env = store.passwordCommandEnvironment
        #expect(env["RESTIC_STATION_DATA_DIR"] == root.path)
        #expect(env[SecretBackend.environmentKey] == "file")
        #expect(env.count == 2)
        #expect(!env.values.contains("hunter2"))
    }

    @Test("the keychain backend needs no password-command environment")
    func keychainNeedsNoPasswordCommandEnvironment() {
        #if os(macOS)
        #expect(KeychainSecretStore(runner: FakeProcessRunner()).passwordCommandEnvironment.isEmpty)
        #endif
    }

    @Test("currentExecutablePath is absolute and is not argv[0]")
    func currentExecutablePathIsAbsolute() {
        let path = FileSecretStore.currentExecutablePath()
        #expect(path.hasPrefix("/"), "expected an absolute path, got \(path)")
    }

    // MARK: - No secret ever leaves except through a read

    @Test("nothing but the password itself carries the password: file bytes are the only copy")
    func errorsAndPathsNeverCarrySecrets() async throws {
        let (store, root) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let secret = "s3cr3t-\(UUID().uuidString)"
        try await store.setPassword(secret, destId: Self.destId)
        try await store.setSecretEnv(["AWS_SECRET_ACCESS_KEY": secret], destId: Self.destId)

        #expect(!store.passwordCommand(destId: Self.destId).contains(secret))
        #expect(!store.fileURL.path.contains(secret))
        #expect(!store.lockFileURL.path.contains(secret))

        // And the failure path: a widened mode reports the problem without
        // quoting the contents it refused to read.
        _ = store.fileURL.path.withCString { chmod($0, 0o644) }
        do {
            _ = try await store.password(destId: Self.destId)
            Issue.record("expected the widened mode to be refused")
        } catch {
            #expect(!"\(error)".contains(secret))
        }
    }
}
