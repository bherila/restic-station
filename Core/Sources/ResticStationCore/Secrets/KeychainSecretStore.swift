#if os(macOS)
import Foundation

/// The macOS ``SecretStore`` backend: all keychain I/O for Restic Station,
/// exactly per `docs/keychain-and-fda.md` §1.
///
/// Every read AND write goes through the `/usr/bin/security` command-line
/// tool (never `SecItemAdd`/the Security framework), and every item we
/// create is created with `-T /usr/bin/security` so a headless launchd
/// context can read it back without a GUI consent prompt.
///
/// `-U` cannot repair an item that was created without `-T` (ACLs are fixed
/// at creation), so every ordinary write here follows a delete-then-add sequence:
/// always `delete-generic-password` first (a not-found there is expected
/// and ignored), then `add-generic-password` *without* `-U`, always with
/// `-T /usr/bin/security`. This guarantees every item this type creates
/// carries the trusted-application ACL, regardless of what existed before.
/// Conditional editor rollback is the narrow exception: it has just verified
/// that the current item's non-secret companion generation is the one this
/// type installed, so `-U` atomically restores the previous value without a
/// delete/add failure window. Helper writes advance that companion even for
/// same-value writes and idempotent deletes.
///
/// Note (documented, not "fixed" — see keychain-and-fda.md): passing
/// `-w <value>` puts the secret in `security`'s argv, momentarily visible
/// to `ps` on the local machine. Accepted tradeoff for a single-user
/// machine; there is no programmatic non-interactive alternative. It is
/// specific to `security(1)` and is deliberately **not** reproduced by
/// ``FileSecretStore``, which never puts a secret in any argv.
///
/// Gated to macOS: `/usr/bin/security` does not exist elsewhere, and offering
/// a backend that can only fail is worse than not offering it at all.
public struct KeychainSecretStore: SecretStore {
    private static let securityPath = "/usr/bin/security"
    private static let service = "restic-station"

    public let backend = SecretBackend.keychain

    private let runner: ProcessRunning
    private let paths: AppPaths?
    private static let lockTimeout: Duration = .seconds(30)
    private static let lockPollNanoseconds: UInt64 = 25_000_000

    public init(runner: ProcessRunning, paths: AppPaths) {
        self.runner = runner
        self.paths = paths
    }

    /// Lock-free construction is internal for argv-focused test doubles.
    /// Production callers must supply `paths` and therefore participate in
    /// the cross-process mutation lock.
    init(runner: ProcessRunning) {
        self.runner = runner
        self.paths = nil
    }

    // MARK: - Repo password

    public func setPassword(_ password: String, destId: UUID) async throws {
        try await withMutationLock {
            let account = SecretAccount.password(destId)
            try await mutateTrackedValue(account: account) {
                try await setValue(password, account: account)
            }
        }
    }

    public func password(destId: UUID) async throws -> String {
        try await readValue(account: SecretAccount.password(destId))
    }

    public func deletePassword(destId: UUID) async throws {
        try await withMutationLock {
            let account = SecretAccount.password(destId)
            try await mutateTrackedValue(account: account) {
                try await deleteValueTolerant(account: account)
            }
        }
    }

    // MARK: - Secret env (e.g. S3 keys)

    /// Account `"<uuid>-env"`, value = compact JSON object encoding `env`.
    /// restic's `RESTIC_PASSWORD_COMMAND` mechanism only covers the repo
    /// password, not arbitrary env vars — `ResticRunner` reads this blob
    /// itself and injects the real env vars.
    public func setSecretEnv(_ env: [String: String], destId: UUID) async throws {
        let json = try SecretEnvBlob.encode(env)
        try await withMutationLock {
            let account = SecretAccount.secretEnv(destId)
            try await mutateTrackedValue(account: account) {
                try await setValue(json, account: account)
            }
        }
    }

    /// A missing item is not an error here — it just means no secret env
    /// vars were ever configured for this destination.
    public func secretEnv(destId: UUID) async throws -> [String: String] {
        let json: String
        do {
            json = try await readValue(account: SecretAccount.secretEnv(destId))
        } catch SecretStoreError.itemNotFound {
            return [:]
        }
        return try SecretEnvBlob.decode(json)
    }

    public func deleteSecretEnv(destId: UUID) async throws {
        try await withMutationLock {
            let account = SecretAccount.secretEnv(destId)
            try await mutateTrackedValue(account: account) {
                try await deleteValueTolerant(account: account)
            }
        }
    }

    public func updateDestinationSecrets(
        _ update: DestinationSecretUpdate
    ) async throws -> DestinationSecretRollback {
        try await withMutationLock {
            let passwordAccount = SecretAccount.password(update.destId)
            let envAccount = SecretAccount.secretEnv(update.destId)
            let previousPassword = update.password == nil
                ? nil
                : try await readOptionalValue(account: passwordAccount)
            let previousEnvRaw = update.secretEnv == nil
                ? nil
                : try await readOptionalValue(account: envAccount)
            let previousPasswordGeneration = update.password == nil || paths == nil
                ? nil
                : try await readOptionalValue(account: generationAccount(for: passwordAccount))
            let previousEnvGeneration = update.secretEnv == nil || paths == nil
                ? nil
                : try await readOptionalValue(account: generationAccount(for: envAccount))
            let installedPasswordGeneration = update.password == nil || paths == nil
                ? nil
                : UUID().uuidString
            let installedEnvGeneration = update.secretEnv == nil || paths == nil
                ? nil
                : UUID().uuidString
            let previousEnv: [String: String]? = if update.secretEnv == nil {
                nil
            } else if let previousEnvRaw {
                (try? SecretEnvBlob.decode(previousEnvRaw)) ?? [:]
            } else {
                [:]
            }
            let rollback = DestinationSecretRollback(
                destId: update.destId,
                password: update.password.map {
                    SecretRollbackChange(installed: Optional($0), previous: previousPassword)
                },
                secretEnv: update.secretEnv.map {
                    SecretRollbackChange(installed: $0, previous: previousEnv ?? [:])
                },
                previousSecretEnvRaw: previousEnvRaw,
                passwordGeneration: installedPasswordGeneration.map {
                    SecretRollbackGeneration(installed: $0, previous: previousPasswordGeneration)
                },
                secretEnvGeneration: installedEnvGeneration.map {
                    SecretRollbackGeneration(installed: $0, previous: previousEnvGeneration)
                }
            )
            var passwordMutationBegan = false
            var environmentMutationBegan = false
            do {
                if let password = update.password {
                    passwordMutationBegan = true
                    if let installedPasswordGeneration {
                        try await setValue(
                            installedPasswordGeneration,
                            account: generationAccount(for: passwordAccount)
                        )
                    }
                    try await setValue(password, account: passwordAccount)
                }
                if let env = update.secretEnv {
                    environmentMutationBegan = true
                    if let installedEnvGeneration {
                        try await setValue(
                            installedEnvGeneration,
                            account: generationAccount(for: envAccount)
                        )
                    }
                    if env.isEmpty {
                        try await deleteValueTolerant(account: envAccount)
                    } else {
                        try await setValue(try SecretEnvBlob.encode(env), account: envAccount)
                    }
                }
            } catch {
                // The lock excludes newer writers, so restoring the captured
                // values here repairs a partial delete/add sequence without
                // risking an external mutation.
                do {
                    if passwordMutationBegan {
                        if let previousPassword {
                            try await setValue(previousPassword, account: passwordAccount)
                        } else {
                            try await deleteValueTolerant(account: passwordAccount)
                        }
                        try await restoreGeneration(
                            previousPasswordGeneration,
                            account: passwordAccount
                        )
                    }
                    if environmentMutationBegan {
                        if let previousEnvRaw {
                            try await setValue(previousEnvRaw, account: envAccount)
                        } else if let previousEnv, !previousEnv.isEmpty {
                            try await setValue(try SecretEnvBlob.encode(previousEnv), account: envAccount)
                        } else {
                            try await deleteValueTolerant(account: envAccount)
                        }
                        try await restoreGeneration(previousEnvGeneration, account: envAccount)
                    }
                } catch {
                    throw SecretStoreError.backendFailed(
                        "keychain update failed and restoring the prior values also failed; "
                            + "verify this destination's credentials before running a backup"
                    )
                }
                throw error
            }
            return rollback
        }
    }

    public func restoreDestinationSecretsIfCurrent(
        _ rollback: DestinationSecretRollback
    ) async throws -> DestinationSecretRestoreResult {
        try await withMutationLock {
            let passwordAccount = SecretAccount.password(rollback.destId)
            let envAccount = SecretAccount.secretEnv(rollback.destId)
            var passwordRestored: Bool?
            if let change = rollback.password {
                if let generation = rollback.passwordGeneration {
                    let current = try await readOptionalValue(account: generationAccount(for: passwordAccount))
                    passwordRestored = current == generation.installed
                } else {
                    let current = try await readOptionalValue(account: passwordAccount)
                    passwordRestored = current == change.installed
                }
            }
            var secretEnvRestored: Bool?
            if let change = rollback.secretEnv {
                if let generation = rollback.secretEnvGeneration {
                    let current = try await readOptionalValue(account: generationAccount(for: envAccount))
                    secretEnvRestored = current == generation.installed
                } else if let currentRaw = try await readOptionalValue(account: envAccount) {
                    secretEnvRestored = (try? SecretEnvBlob.decode(currentRaw)) == change.installed
                } else {
                    secretEnvRestored = change.installed.isEmpty
                }
            }
            if passwordRestored == true, let change = rollback.password {
                if let previous = change.previous {
                    try await updateExistingValue(previous, account: passwordAccount)
                } else {
                    try await deleteValueTolerant(account: passwordAccount)
                }
                if let generation = rollback.passwordGeneration {
                    try await restoreGeneration(generation.previous, account: passwordAccount)
                }
            }
            if secretEnvRestored == true, let change = rollback.secretEnv {
                if let previousRaw = rollback.previousSecretEnvRaw {
                    if change.installed.isEmpty {
                        // Clearing removed the item, so this is creation and
                        // must re-establish the trusted `/usr/bin/security`
                        // ACL rather than using update-only `-U`.
                        try await setValue(previousRaw, account: envAccount)
                    } else {
                        try await updateExistingValue(previousRaw, account: envAccount)
                    }
                } else if change.previous.isEmpty {
                    try await deleteValueTolerant(account: envAccount)
                } else {
                    try await updateExistingValue(
                        try SecretEnvBlob.encode(change.previous),
                        account: envAccount
                    )
                }
                if let generation = rollback.secretEnvGeneration {
                    try await restoreGeneration(generation.previous, account: envAccount)
                }
            }
            return DestinationSecretRestoreResult(
                passwordRestored: passwordRestored,
                secretEnvRestored: secretEnvRestored
            )
        }
    }

    // MARK: - Documented command string

    /// The exact command restic itself is configured to run via
    /// `RESTIC_PASSWORD_COMMAND` (see restic-cli.md). Our own reads use the
    /// same argv shape (via `readValue`), just invoked through `ProcessRunning`
    /// instead of a shell string. Contains no character needing quoting.
    public func passwordCommand(destId: UUID) -> String {
        "\(Self.securityPath) find-generic-password -s \(Self.service) -a \(SecretAccount.password(destId)) -w"
    }

    // MARK: - security subprocess plumbing

    private func generationAccount(for account: String) -> String {
        "\(account)-generation"
    }

    /// Advances the non-secret mutation identity and the credential under the
    /// same cross-process lock. If any security(1) step fails, restore the
    /// prior identity before returning the original error so a still-current
    /// app rollback is not falsely classified as externally superseded.
    private func mutateTrackedValue(
        account: String,
        mutation: () async throws -> Void
    ) async throws {
        guard paths != nil else {
            try await mutation()
            return
        }
        let previousGeneration = try await readOptionalValue(
            account: generationAccount(for: account)
        )
        do {
            try await setValue(UUID().uuidString, account: generationAccount(for: account))
            try await mutation()
        } catch let mutationError {
            do {
                try await restoreGeneration(previousGeneration, account: account)
            } catch {
                throw SecretStoreError.backendFailed(
                    "keychain mutation failed and restoring its generation marker also failed; "
                        + "verify this destination's credentials before running a backup"
                )
            }
            throw mutationError
        }
    }

    private func restoreGeneration(_ generation: String?, account: String) async throws {
        guard paths != nil else { return }
        let markerAccount = generationAccount(for: account)
        if let generation {
            try await setValue(generation, account: markerAccount)
        } else {
            try await deleteValueTolerant(account: markerAccount)
        }
    }

    private func setValue(_ value: String, account: String) async throws {
        do {
            try await deleteValue(account: account)
        } catch SecretStoreError.itemNotFound {
            // Nothing to delete — proceed straight to add.
        }

        let argv = [
            Self.securityPath, "add-generic-password",
            "-s", Self.service,
            "-a", account,
            "-w", value,
            "-T", Self.securityPath,
        ]
        let result = try await runSecurity(argv)
        guard result.exitCode == 0 else {
            throw SecretStoreError.backendFailed(Self.trimmedStderr(result))
        }
    }

    /// Atomically changes an item whose Restic Station ACL was established by
    /// `setValue`. Used only after conditional rollback verified that exact
    /// editor-installed value is still current.
    private func updateExistingValue(_ value: String, account: String) async throws {
        let argv = [
            Self.securityPath, "add-generic-password",
            "-U",
            "-s", Self.service,
            "-a", account,
            "-w", value,
        ]
        let result = try await runSecurity(argv)
        guard result.exitCode == 0 else {
            throw SecretStoreError.backendFailed(Self.trimmedStderr(result))
        }
    }

    private func readValue(account: String) async throws -> String {
        let argv = [
            Self.securityPath, "find-generic-password",
            "-s", Self.service,
            "-a", account,
            "-w",
        ]
        let result = try await runSecurity(argv)
        if result.exitCode == 44 {
            throw SecretStoreError.itemNotFound
        }
        guard result.exitCode == 0 else {
            throw SecretStoreError.backendFailed(Self.trimmedStderr(result))
        }
        var raw = String(decoding: result.stdout, as: UTF8.self)
        if raw.hasSuffix("\n") {
            raw.removeLast()
        }
        return raw
    }

    private func readOptionalValue(account: String) async throws -> String? {
        do {
            return try await readValue(account: account)
        } catch SecretStoreError.itemNotFound {
            return nil
        }
    }

    /// Deletes the item, throwing `SecretStoreError.itemNotFound` (typed) if
    /// there wasn't one. Used both directly and by the tolerant wrapper.
    private func deleteValue(account: String) async throws {
        let argv = [
            Self.securityPath, "delete-generic-password",
            "-s", Self.service,
            "-a", account,
        ]
        let result = try await runSecurity(argv)
        if result.exitCode == 44 {
            throw SecretStoreError.itemNotFound
        }
        guard result.exitCode == 0 else {
            throw SecretStoreError.backendFailed(Self.trimmedStderr(result))
        }
    }

    /// Public delete entry points are idempotent: deleting an already-absent
    /// item is a no-op, not an error.
    private func deleteValueTolerant(account: String) async throws {
        do {
            try await deleteValue(account: account)
        } catch SecretStoreError.itemNotFound {
            // Already gone.
        }
    }

    private func runSecurity(_ argv: [String]) async throws -> ProcessResult {
        try await runner.run(
            argv,
            env: nil,
            stdin: nil,
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: nil
        )
    }

    /// Keychain operations are individually atomic, but an editor rollback
    /// needs compare-and-restore atomicity across several `security`
    /// subprocesses. Production construction supplies `paths`, placing app
    /// and helper CLI mutations under the same cross-process lock. Tests
    /// that exercise argv construction can omit it.
    private func withMutationLock<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        guard let paths else { return try await body() }
        try paths.ensureDirectories()
        let lock = FileLock(path: paths.secretsLockFile, trustedRoot: paths.root)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.lockTimeout)
        while true {
            switch lock.acquire() {
            case .acquired:
                defer { lock.release() }
                return try await body()
            case .busy:
                guard clock.now < deadline else {
                    throw SecretStoreError.backendFailed(
                        "timed out waiting for the secrets lock at \(paths.secretsLockFile.path)"
                    )
                }
                try await Task.sleep(nanoseconds: Self.lockPollNanoseconds)
            case .failed(let failure):
                throw SecretStoreError.lockUnusable(failure)
            }
        }
    }

    private static func trimmedStderr(_ result: ProcessResult) -> String {
        String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
