import Foundation
import Testing
@testable import ResticStationCore

/// The behaviour every ``SecretStore`` backend must share, run against each
/// backend in turn.
///
/// This is the contract `ResticRunner` and `BackupEngine` are written
/// against: `itemNotFound` for a missing password, `[:]` for a missing
/// secret env, idempotent deletes, overwrite-not-append. A backend that
/// diverges here either loses access to a repository or leaks a stale
/// credential into a run, so each rule is asserted for every backend rather
/// than for whichever one the host platform happens to default to.
///
/// ``FileSecretStore`` is exercised on **both** platforms — that is how the
/// Linux code path gets real coverage from a macOS run and from the macOS CI
/// job. ``KeychainSecretStore`` is exercised through `FakeProcessRunner`
/// (its real-`security` coverage lives in `KeychainSmokeTests`).
@Suite("SecretStore conformance")
struct SecretStoreConformanceTests {
    static let destId = UUID(uuidString: "A1B2C3D4-E5F6-4789-A012-3456789ABCDE")!
    static let otherId = UUID(uuidString: "B1B2C3D4-E5F6-4789-A012-3456789ABCDE")!

    // MARK: - Scratch file backend

    /// A `FileSecretStore` over a fresh temp directory, plus its cleanup.
    static func makeFileStore() -> (store: FileSecretStore, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("restic-station-secrets-\(UUID().uuidString)", isDirectory: true)
        return (FileSecretStore(paths: AppPaths(root: root), helperPath: "/opt/restic-station-helper"), root)
    }

    // MARK: - File backend

    @Test("file: round-trips a password, then deletes it")
    func fileRoundTrip() async throws {
        let (store, root) = Self.makeFileStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("hunter2", destId: Self.destId)
        #expect(try await store.password(destId: Self.destId) == "hunter2")

        try await store.deletePassword(destId: Self.destId)
        await #expect(throws: SecretStoreError.itemNotFound) {
            _ = try await store.password(destId: Self.destId)
        }
    }

    @Test("file: a missing password is .itemNotFound, not an empty string")
    func fileMissingPassword() async throws {
        let (store, root) = Self.makeFileStore()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: SecretStoreError.itemNotFound) {
            _ = try await store.password(destId: Self.destId)
        }
    }

    @Test("file: a missing secret env is [:] and does not throw")
    func fileMissingSecretEnv() async throws {
        let (store, root) = Self.makeFileStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try await store.secretEnv(destId: Self.destId).isEmpty)
    }

    @Test("file: secret env round-trips as a JSON blob under the '-env' key")
    func fileSecretEnvRoundTrip() async throws {
        let (store, root) = Self.makeFileStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let env = ["AWS_ACCESS_KEY_ID": "AKIA123", "AWS_SECRET_ACCESS_KEY": "shh"]
        try await store.setSecretEnv(env, destId: Self.destId)
        #expect(try await store.secretEnv(destId: Self.destId) == env)

        // The stored shape mirrors the keychain account naming.
        let document = try store.load()
        #expect(document.secrets[SecretAccount.secretEnv(Self.destId)] != nil)
        #expect(document.secrets[SecretAccount.password(Self.destId)] == nil)

        try await store.deleteSecretEnv(destId: Self.destId)
        #expect(try await store.secretEnv(destId: Self.destId).isEmpty)
    }

    /// The malformed-content half of #96, on the *inner* blob rather than
    /// the outer document. Both backends decode this same JSON, so both
    /// reach the same classification through `SecretEnvBlob.decode`.
    @Test("a corrupt secret-env blob is permanent, not a retryable read failure")
    func corruptSecretEnvBlobIsStoreUnusable() async throws {
        // The shared decoder, exercised directly: it is what both
        // `FileSecretStore.secretEnv` and `KeychainSecretStore.secretEnv`
        // return through, and a keychain item holding this same text is
        // corrupt in exactly the same way.
        do {
            _ = try SecretEnvBlob.decode("{\"A\": ")
            Issue.record("expected a malformed secret-env blob to be refused")
        } catch let error as SecretStoreError {
            guard case .storeUnusable = error else {
                Issue.record("expected .storeUnusable, got \(error)")
                return
            }
            let failure = CLIFailure.classify(error)
            #expect(failure.code == .secretStoreUnusable)
            #expect(!failure.retryable, "decoding the identical bytes cannot start succeeding")
        }

        // And end to end through the file backend, whose outer document is
        // perfectly valid — this is the case a `load()`-level check misses.
        let (store, root) = Self.makeFileStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.setPassword("hunter2", destId: Self.destId)
        var document = try store.load()
        document.secrets[SecretAccount.secretEnv(Self.destId)] = "{\"A\": "
        // Written straight to the file at 0600 rather than through the
        // store's own writer, which is private — and which would have no
        // way to produce this state anyway, since `setSecretEnv` encodes.
        let encoded = try JSONEncoder().encode(document)
        try encoded.write(to: store.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path
        )

        await #expect(throws: SecretStoreError.self) {
            _ = try await store.secretEnv(destId: Self.destId)
        }
        do {
            _ = try await store.secretEnv(destId: Self.destId)
        } catch let error as SecretStoreError {
            guard case .storeUnusable = error else {
                Issue.record("expected .storeUnusable from the file backend, got \(error)")
                return
            }
        }
    }

    @Test("file: deletes are idempotent")
    func fileIdempotentDeletes() async throws {
        let (store, root) = Self.makeFileStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // Deleting from a store that has no file at all must not throw.
        try await store.deletePassword(destId: Self.destId)
        try await store.deleteSecretEnv(destId: Self.destId)

        try await store.setPassword("pw", destId: Self.destId)
        try await store.deletePassword(destId: Self.destId)
        try await store.deletePassword(destId: Self.destId)
    }

    @Test("file: overwriting replaces the value rather than appending")
    func fileOverwriteReplaces() async throws {
        let (store, root) = Self.makeFileStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("first", destId: Self.destId)
        try await store.setPassword("second", destId: Self.destId)
        #expect(try await store.password(destId: Self.destId) == "second")

        try await store.setSecretEnv(["A": "1", "B": "2"], destId: Self.destId)
        try await store.setSecretEnv(["A": "3"], destId: Self.destId)
        #expect(try await store.secretEnv(destId: Self.destId) == ["A": "3"])

        let document = try store.load()
        #expect(document.secrets.count == 2, "one password key and one -env key, not four")
    }

    @Test("file: destinations do not interfere with each other")
    func fileDestinationsAreIndependent() async throws {
        let (store, root) = Self.makeFileStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.setPassword("one", destId: Self.destId)
        try await store.setPassword("two", destId: Self.otherId)
        try await store.deletePassword(destId: Self.destId)

        #expect(try await store.password(destId: Self.otherId) == "two")
    }

    @Test("file: keys are the lowercased UUID, matching the keychain accounts")
    func fileKeysAreLowercasedUUIDs() async throws {
        let (store, root) = Self.makeFileStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(Self.destId.uuidString != Self.destId.uuidString.lowercased())
        try await store.setPassword("pw", destId: Self.destId)

        let document = try store.load()
        #expect(document.secrets.keys.sorted() == [Self.destId.uuidString.lowercased()])
    }

    // MARK: - Keychain backend (macOS)

    #if os(macOS)
    @Test("keychain: a missing password is .itemNotFound (security exit 44)")
    func keychainMissingPassword() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "find-generic-password"], exitCode: 44),
        ])
        let store = KeychainSecretStore(runner: runner)
        await #expect(throws: SecretStoreError.itemNotFound) {
            _ = try await store.password(destId: Self.destId)
        }
    }

    @Test("keychain: a missing secret env is [:] and does not throw")
    func keychainMissingSecretEnv() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "find-generic-password"], exitCode: 44),
        ])
        let store = KeychainSecretStore(runner: runner)
        #expect(try await store.secretEnv(destId: Self.destId).isEmpty)
    }

    @Test("keychain: deletes are idempotent")
    func keychainIdempotentDeletes() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
        ])
        let store = KeychainSecretStore(runner: runner)
        try await store.deletePassword(destId: Self.destId)
        try await store.deleteSecretEnv(destId: Self.destId)
    }

    @Test("keychain: a write replaces (delete-then-add), it never uses -U")
    func keychainOverwriteReplaces() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 0),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password"], exitCode: 0),
        ])
        let store = KeychainSecretStore(runner: runner)
        try await store.setPassword("second", destId: Self.destId)
        #expect(runner.invocations.count == 2)
        #expect(!runner.invocations[1].argv.contains("-U"))
    }
    #endif

    // MARK: - Both backends agree on the storage keys

    @Test("both backends key on the same lowercased-UUID account strings")
    func accountNamingIsShared() {
        #expect(SecretAccount.password(Self.destId) == "a1b2c3d4-e5f6-4789-a012-3456789abcde")
        #expect(SecretAccount.secretEnv(Self.destId) == "a1b2c3d4-e5f6-4789-a012-3456789abcde-env")
    }
}
