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

    // MARK: - SecretStore

    func setPassword(_ password: String, destId: UUID) async throws {
        withLock { _passwords[destId] = password }
    }

    func password(destId: UUID) async throws -> String {
        onPasswordRead?(destId)
        let outcome: Result<String, SecretStoreError> = withLock {
            if let failure = _failingPasswords[destId] {
                return .failure(failure)
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
        let outcome: Result<[String: String], SecretStoreError> = withLock {
            if let failure = _failingSecretEnvs[destId] {
                return .failure(failure)
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

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
