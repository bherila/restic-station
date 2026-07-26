import Foundation

/// Typed errors surfaced by `KeychainClient`.
public enum KeychainError: Error, Sendable, Equatable {
    /// `security`'s documented exit code 44 — no matching item.
    case itemNotFound
    /// Any other nonzero exit from `/usr/bin/security`, with its stderr.
    case securityCommandFailed(String)
}

/// All keychain I/O for Restic Station, exactly per `docs/keychain-and-fda.md` §1:
/// every read AND write goes through the `/usr/bin/security` command-line
/// tool (never `SecItemAdd`/the Security framework), and every item we
/// create is created with `-T /usr/bin/security` so a headless launchd
/// context can read it back without a GUI consent prompt.
///
/// `-U` cannot repair an item that was created without `-T` (ACLs are fixed
/// at creation), so every write here follows a delete-then-add sequence:
/// always `delete-generic-password` first (a not-found there is expected
/// and ignored), then `add-generic-password` *without* `-U`, always with
/// `-T /usr/bin/security`. This guarantees every item this type creates
/// carries the trusted-application ACL, regardless of what existed before.
///
/// Note (documented, not "fixed" — see keychain-and-fda.md): passing
/// `-w <value>` puts the secret in `security`'s argv, momentarily visible
/// to `ps` on the local machine. Accepted tradeoff for a single-user
/// machine; there is no programmatic non-interactive alternative.
public struct KeychainClient: Sendable {
    private static let securityPath = "/usr/bin/security"
    private static let service = "restic-station"

    private let runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    // MARK: - Repo password

    public func setPassword(_ pw: String, destId: UUID) async throws {
        try await setValue(pw, account: Self.account(destId))
    }

    public func password(destId: UUID) async throws -> String {
        try await readValue(account: Self.account(destId))
    }

    public func deletePassword(destId: UUID) async throws {
        try await deleteValueTolerant(account: Self.account(destId))
    }

    // MARK: - Secret env (e.g. S3 keys)

    /// Account `"<uuid>-env"`, value = compact JSON object encoding `env`.
    /// restic's `RESTIC_PASSWORD_COMMAND` mechanism only covers the repo
    /// password, not arbitrary env vars — `ResticRunner` reads this blob
    /// itself and injects the real env vars.
    public func setSecretEnv(_ env: [String: String], destId: UUID) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(env)
        } catch {
            throw KeychainError.securityCommandFailed("failed to encode secret env as JSON: \(error)")
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw KeychainError.securityCommandFailed("failed to encode secret env as UTF-8 JSON")
        }
        try await setValue(json, account: Self.envAccount(destId))
    }

    /// A missing item is not an error here — it just means no secret env
    /// vars were ever configured for this destination.
    public func secretEnv(destId: UUID) async throws -> [String: String] {
        let json: String
        do {
            json = try await readValue(account: Self.envAccount(destId))
        } catch KeychainError.itemNotFound {
            return [:]
        }
        guard let data = json.data(using: .utf8) else {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw KeychainError.securityCommandFailed("failed to decode secret env JSON: \(error)")
        }
    }

    public func deleteSecretEnv(destId: UUID) async throws {
        try await deleteValueTolerant(account: Self.envAccount(destId))
    }

    // MARK: - Documented command string

    /// The exact command restic itself is configured to run via
    /// `RESTIC_PASSWORD_COMMAND` (see restic-cli.md). Our own reads use the
    /// same argv shape (via `readValue`), just invoked through `ProcessRunning`
    /// instead of a shell string.
    public static func passwordCommand(destId: UUID) -> String {
        "\(securityPath) find-generic-password -s \(service) -a \(account(destId)) -w"
    }

    // MARK: - Account naming

    /// Destination UUIDs never change (architecture.md §Identifiers) — the
    /// destination UUID *is* the keychain account key, lowercased for a
    /// stable, predictable account string.
    private static func account(_ destId: UUID) -> String {
        destId.uuidString.lowercased()
    }

    private static func envAccount(_ destId: UUID) -> String {
        "\(account(destId))-env"
    }

    // MARK: - security subprocess plumbing

    private func setValue(_ value: String, account: String) async throws {
        do {
            try await deleteValue(account: account)
        } catch KeychainError.itemNotFound {
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
            throw KeychainError.securityCommandFailed(Self.trimmedStderr(result))
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
            throw KeychainError.itemNotFound
        }
        guard result.exitCode == 0 else {
            throw KeychainError.securityCommandFailed(Self.trimmedStderr(result))
        }
        var raw = String(decoding: result.stdout, as: UTF8.self)
        if raw.hasSuffix("\n") {
            raw.removeLast()
        }
        return raw
    }

    /// Deletes the item, throwing `KeychainError.itemNotFound` (typed) if
    /// there wasn't one. Used both directly and by the tolerant wrapper.
    private func deleteValue(account: String) async throws {
        let argv = [
            Self.securityPath, "delete-generic-password",
            "-s", Self.service,
            "-a", account,
        ]
        let result = try await runSecurity(argv)
        if result.exitCode == 44 {
            throw KeychainError.itemNotFound
        }
        guard result.exitCode == 0 else {
            throw KeychainError.securityCommandFailed(Self.trimmedStderr(result))
        }
    }

    /// Public delete entry points are idempotent: deleting an already-absent
    /// item is a no-op, not an error.
    private func deleteValueTolerant(account: String) async throws {
        do {
            try await deleteValue(account: account)
        } catch KeychainError.itemNotFound {
            // Already gone.
        }
    }

    private func runSecurity(_ argv: [String]) async throws -> ProcessResult {
        try await runner.run(
            argv,
            env: nil,
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: nil
        )
    }

    private static func trimmedStderr(_ result: ProcessResult) -> String {
        String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
