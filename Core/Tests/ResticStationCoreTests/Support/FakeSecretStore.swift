import Foundation
@testable import ResticStationCore

/// In-memory ``SecretStore`` double.
///
/// Before T23 every test that exercised `ResticRunner`/`BackupEngine` had to
/// script `/usr/bin/security` invocations through `FakeProcessRunner`, which
/// (a) coupled unrelated tests to the macOS keychain's argv and (b) made the
/// ordered process script three or four entries longer per restic spawn. With
/// the secret store behind a protocol, those tests inject this instead: the
/// process script now contains restic calls and nothing else.
///
/// Defaults to "every destination has a password", because that is the
/// uninteresting precondition of almost every test. Use ``failPassword(for:)``
/// / ``failSecretEnv(for:)`` to reach the retryable-error paths.
final class FakeSecretStore: SecretStore, @unchecked Sendable {
    /// What `password(destId:)` returns for a destination nothing was stored
    /// for, when ``defaultPassword`` is in effect.
    static let standardPassword = "repo-password"

    private let lock = NSLock()
    private var _passwords: [UUID: String] = [:]
    private var _secretEnvs: [UUID: [String: String]] = [:]
    private var _failingPasswords: [UUID: SecretStoreError] = [:]
    private var _failingSecretEnvs: [UUID: SecretStoreError] = [:]
    private var _secretEnvReads: [UUID: Int] = [:]
    private var _passwordReads: [UUID: Int] = [:]
    private var _failingPasswordsAfter: [UUID: (reads: Int, error: SecretStoreError)] = [:]
    private var _failingSecretEnvsAfter: [UUID: (reads: Int, error: SecretStoreError)] = [:]
    /// Password and environment reads together, for ``failReads(for:afterReads:with:onFailure:)``.
    private var _reads: [UUID: Int] = [:]
    private var _failingReadsAfter: [UUID: (reads: Int, error: SecretStoreError, onFailure: (@Sendable () -> Void)?)] = [:]
    private let defaultPassword: String?
    private let onPasswordRead: (@Sendable (UUID) -> Void)?

    /// Which backend this fake stands in for. Defaults to the platform's, so
    /// a test that does not care gets the wording a real host would produce.
    let backend: SecretBackend

    /// - Parameters:
    ///   - defaultPassword: returned for any destination with no explicitly
    ///     stored password. `nil` makes the store behave like a real empty
    ///     one (`itemNotFound`).
    ///   - backend: the backend this fake reports as, for the user-facing
    ///     wording derived from it.
    init(
        defaultPassword: String? = FakeSecretStore.standardPassword,
        backend: SecretBackend = .platformDefault,
        onPasswordRead: (@Sendable (UUID) -> Void)? = nil
    ) {
        self.defaultPassword = defaultPassword
        self.backend = backend
        self.onPasswordRead = onPasswordRead
    }

    // MARK: - Test configuration

    func store(password: String, for destId: UUID) {
        withLock { _passwords[destId] = password }
    }

    func store(secretEnv: [String: String], for destId: UUID) {
        withLock { _secretEnvs[destId] = secretEnv }
    }

    /// Makes `password(destId:)` throw — the "locked keychain / unreadable
    /// secrets file" pre-flight failure.
    ///
    /// `error` defaults to the retryable ``SecretStoreError/backendFailed(_:)``
    /// because that is what most callers mean by "the store failed". Pass
    /// ``SecretStoreError/storeUnusable(_:)`` to reach the permanent arm the
    /// pre-flight must not collapse into the retryable one (#96).
    func failPassword(for destId: UUID, with error: SecretStoreError = .backendFailed("fake: password read failed")) {
        withLock { _failingPasswords[destId] = error }
    }

    /// Makes `secretEnv(destId:)` throw (a *failure*, not "absent": absent is
    /// `[:]` and is the default).
    func failSecretEnv(for destId: UUID, with error: SecretStoreError = .backendFailed("fake: secret env read failed")) {
        withLock { _failingSecretEnvs[destId] = error }
    }

    /// Lets the first `reads` secret-environment reads of `destId` succeed
    /// and fails every later one — a store changed *between* the engine's
    /// pre-flight and the runner's own read just before the spawn (#152).
    func failSecretEnv(for destId: UUID, afterReads reads: Int, with error: SecretStoreError) {
        withLock { _failingSecretEnvsAfter[destId] = (reads, error) }
    }

    /// Lets the first `reads` password reads of `destId` succeed and fails
    /// every later one (#152).
    func failPassword(for destId: UUID, afterReads reads: Int, with error: SecretStoreError) {
        withLock { _failingPasswordsAfter[destId] = (reads, error) }
    }

    /// Lets the first `reads` reads of `destId` — password and environment
    /// counted together — succeed, and fails every later one. `onFailure`
    /// runs on each failing read, before it throws. The sweep in
    /// `PostPreflightSecretSweepTests` uses it to fail every read an
    /// operation makes, one at a time (#152).
    func failReads(
        for destId: UUID,
        afterReads reads: Int,
        with error: SecretStoreError,
        onFailure: (@Sendable () -> Void)? = nil
    ) {
        withLock { _failingReadsAfter[destId] = (reads, error, onFailure) }
    }

    /// How many reads of `destId`, password and environment together, the
    /// store has answered or refused since the last ``clearFailures()``.
    func reads(for destId: UUID) -> Int {
        withLock { _reads[destId] ?? 0 }
    }

    /// Clears every injected failure, as if the user had repaired the store.
    func clearFailures() {
        withLock {
            _failingPasswords.removeAll()
            _failingSecretEnvs.removeAll()
            _failingSecretEnvsAfter.removeAll()
            _secretEnvReads.removeAll()
            _failingPasswordsAfter.removeAll()
            _passwordReads.removeAll()
            _failingReadsAfter.removeAll()
            _reads.removeAll()
        }
    }

    // MARK: - SecretStore

    func setPassword(_ password: String, destId: UUID) async throws {
        withLock { _passwords[destId] = password }
    }

    func password(destId: UUID) async throws -> String {
        onPasswordRead?(destId)
        if let failure = countRead(destId) { throw failure }
        let outcome: Result<String, SecretStoreError> = withLock {
            if let failure = _failingPasswords[destId] {
                return .failure(failure)
            }
            let reads = (_passwordReads[destId] ?? 0) + 1
            _passwordReads[destId] = reads
            if let after = _failingPasswordsAfter[destId], reads > after.reads {
                return .failure(after.error)
            }
            if let stored = _passwords[destId] {
                return .success(stored)
            }
            if let defaultPassword {
                return .success(defaultPassword)
            }
            return .failure(.itemNotFound)
        }
        return try outcome.get()
    }

    func deletePassword(destId: UUID) async throws {
        withLock { _passwords.removeValue(forKey: destId) }
    }

    func setSecretEnv(_ env: [String: String], destId: UUID) async throws {
        withLock { _secretEnvs[destId] = env }
    }

    func secretEnv(destId: UUID) async throws -> [String: String] {
        if let failure = countRead(destId) { throw failure }
        let outcome: Result<[String: String], SecretStoreError> = withLock {
            if let failure = _failingSecretEnvs[destId] {
                return .failure(failure)
            }
            let reads = (_secretEnvReads[destId] ?? 0) + 1
            _secretEnvReads[destId] = reads
            if let after = _failingSecretEnvsAfter[destId], reads > after.reads {
                return .failure(after.error)
            }
            return .success(_secretEnvs[destId] ?? [:])
        }
        return try outcome.get()
    }

    func deleteSecretEnv(destId: UUID) async throws {
        withLock { _secretEnvs.removeValue(forKey: destId) }
    }

    /// Deterministic and obviously fake, so a test asserting env assembly is
    /// asserting *that the store's command was used*, not re-deriving the
    /// keychain's string.
    func passwordCommand(destId: UUID) -> String {
        FakeSecretStore.passwordCommand(destId: destId)
    }

    static func passwordCommand(destId: UUID) -> String {
        "/fake/secret-store print-password --dest \(destId.uuidString.lowercased())"
    }

    // MARK: - Plumbing

    /// Counts one read of `destId` and returns the armed failure, if this
    /// read is past ``failReads(for:afterReads:with:onFailure:)``'s count.
    private func countRead(_ destId: UUID) -> SecretStoreError? {
        let armed: (error: SecretStoreError, onFailure: (@Sendable () -> Void)?)? = withLock {
            let reads = (_reads[destId] ?? 0) + 1
            _reads[destId] = reads
            guard let after = _failingReadsAfter[destId], reads > after.reads else { return nil }
            return (after.error, after.onFailure)
        }
        guard let armed else { return nil }
        armed.onFailure?()
        return armed.error
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
