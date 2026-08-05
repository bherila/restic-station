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
    private var _failingPasswords: Set<UUID> = []
    private var _failingSecretEnvs: Set<UUID> = []
    private let defaultPassword: String?

    /// - Parameter defaultPassword: returned for any destination with no
    ///   explicitly stored password. `nil` makes the store behave like a real
    ///   empty one (`itemNotFound`).
    init(defaultPassword: String? = FakeSecretStore.standardPassword) {
        self.defaultPassword = defaultPassword
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
    func failPassword(for destId: UUID) {
        withLock { _failingPasswords.insert(destId) }
    }

    /// Makes `secretEnv(destId:)` throw (a *failure*, not "absent": absent is
    /// `[:]` and is the default).
    func failSecretEnv(for destId: UUID) {
        withLock { _failingSecretEnvs.insert(destId) }
    }

    // MARK: - SecretStore

    func setPassword(_ password: String, destId: UUID) async throws {
        withLock { _passwords[destId] = password }
    }

    func password(destId: UUID) async throws -> String {
        let outcome: Result<String, SecretStoreError> = withLock {
            if _failingPasswords.contains(destId) {
                return .failure(.backendFailed("fake: password read failed"))
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
            if _failingSecretEnvs.contains(destId) {
                return .failure(.backendFailed("fake: secret env read failed"))
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
