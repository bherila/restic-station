import Foundation

// MARK: - SecretStoreError

/// Typed errors surfaced by every ``SecretStore`` backend.
///
/// **Invariant: no case ever carries secret material.** ``itemNotFound`` is
/// data-free by construction, ``lockUnusable(_:)`` carries only path/errno
/// diagnostics, and ``backendFailed(_:)`` may only be constructed from a
/// backend's own diagnostic text (a `security` stderr line, a file path, an
/// errno string) — never from a password, a secret-env value, or a decoded
/// blob. These strings reach run logs and the UI.
public enum SecretStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No stored item for this destination. On the keychain backend this is
    /// `security`'s documented exit code 44; on the file backend it is a
    /// missing key (or a missing `secrets.json`).
    case itemNotFound
    /// The file backend's mutation lock is structurally unusable. Kept out
    /// of `backendFailed` because retrying the identical write cannot repair
    /// a symlink, wrong owner, unsafe parent, or wrong file type.
    case lockUnusable(LockFailure)
    /// The store itself cannot be used until something outside this request
    /// changes: a file's type, mode, or owner; the document's format; or the
    /// build that is reading it. Kept out of ``backendFailed`` for the same
    /// reason ``lockUnusable`` is — repeating the identical read cannot
    /// repair a symlinked `secrets.json`, a group-readable mode, an
    /// untrusted owner, malformed contents, or a document written by a newer
    /// format version.
    ///
    /// The distinction is not cosmetic: ``backendFailed`` publishes
    /// `retryable: true`, which tells an automated caller to repeat a request
    /// that cannot ever succeed (#96). The dividing line is *whether
    /// repeating the identical request can produce a different answer*, not
    /// whether a human would call the condition serious — a bare `errno`
    /// wrapper stays ``backendFailed`` because its errno set includes
    /// transient causes.
    ///
    /// The safe direction is asymmetric. Marking a genuinely transient
    /// failure permanent is the more damaging mistake: it breaks the
    /// pre-login-tick behaviour `docs/keychain-and-fda.md` §2 depends on,
    /// where a tick that fires before the login keychain unlocks must keep
    /// skipping and retrying rather than give up. So the keychain backend's
    /// `security` failures — exit 51 included — stay ``backendFailed``.
    case storeUnusable(String)
    /// Any other backend failure, with the backend's own diagnostic text.
    /// The backend answered badly and may answer well later: a locked login
    /// keychain, a transient I/O error, a lock held by a stuck peer.
    case backendFailed(String)

    public var description: String {
        switch self {
        case .itemNotFound:
            return "no stored secret for this destination"
        case .lockUnusable(let failure):
            return "secrets lock unusable: \(failure)"
        case .storeUnusable(let detail):
            return detail
        case .backendFailed(let detail):
            return detail
        }
    }
}

extension SecretStoreError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - SecretStore

/// Where Restic Station keeps a destination's repository password and its
/// secret environment variables.
///
/// Two backends implement this (see `docs/keychain-and-fda.md`):
/// ``KeychainSecretStore`` (macOS, `/usr/bin/security`) and
/// ``FileSecretStore`` (Linux default, `<AppPaths.root>/secrets.json`).
/// ``SecretStoreFactory/make(paths:runner:helperExecutablePath:environment:)``
/// picks one.
///
/// **Semantics every backend must preserve** — these are load-bearing and
/// each has a shared conformance test in `SecretStoreConformanceTests`:
///
/// - ``password(destId:)`` throws ``SecretStoreError/itemNotFound`` when the
///   destination has no stored password.
/// - ``secretEnv(destId:)`` returns `[:]` — it does **not** throw — when no
///   secret env was ever configured. "Absent" and "empty" are the same thing
///   here; no destination is required to have secret env vars.
/// - Both delete methods are idempotent: deleting an absent item is a no-op,
///   not an error.
/// - Writes replace rather than merge, and are delete-then-add (a macOS
///   keychain item's ACL is fixed at creation and `-U` cannot repair it, so
///   the keychain backend must re-create; the file backend follows the same
///   replace semantics so the two stay behaviourally identical).
///
/// ``passwordCommand(destId:)`` is an instance requirement, not a static one:
/// each backend produces its own `RESTIC_PASSWORD_COMMAND` string, and the
/// file backend's depends on where *this* executable lives.
public protocol SecretStore: Sendable {

    /// Which backend this store is.
    ///
    /// Exists so every user-facing string about secret storage is chosen by
    /// **the store actually in use**, not by the host OS: macOS with
    /// `RESTIC_STATION_SECRET_BACKEND=file` is a supported configuration, and
    /// telling that user to "unlock your login keychain" when their
    /// `secrets.json` has the wrong mode sends them down the wrong path at
    /// exactly the wrong moment. The wording itself lives on
    /// ``SecretBackend`` so the two backends cannot describe themselves
    /// inconsistently.
    var backend: SecretBackend { get }

    // MARK: Repository password

    func setPassword(_ password: String, destId: UUID) async throws
    func password(destId: UUID) async throws -> String
    func deletePassword(destId: UUID) async throws

    // MARK: Secret env (e.g. S3 keys)

    func setSecretEnv(_ env: [String: String], destId: UUID) async throws
    func secretEnv(destId: UUID) async throws -> [String: String]
    func deleteSecretEnv(destId: UUID) async throws

    /// Captures the previous managed fields and installs their replacements.
    /// Production backends do both atomically under their shared mutation
    /// lock. `nil` means that field is outside the update.
    func updateDestinationSecrets(_ update: DestinationSecretUpdate) async throws -> DestinationSecretRollback

    /// Restores editor-written values only while they are still current.
    /// Production backends implement the comparison and restoration under
    /// their shared mutation lock, so a newer CLI write can never be
    /// overwritten by a stale UI rollback.
    @discardableResult
    func restoreDestinationSecretsIfCurrent(
        _ rollback: DestinationSecretRollback
    ) async throws -> DestinationSecretRestoreResult

    // MARK: Password command

    /// The exact command restic is configured to run via
    /// `RESTIC_PASSWORD_COMMAND` / `RESTIC_FROM_PASSWORD_COMMAND` to obtain
    /// this destination's password.
    ///
    /// restic **word-splits this itself** — it does not hand it to `sh -c`
    /// (`docs/restic-cli.md` §General). The returned string must therefore be
    /// splittable by restic's own splitter and must never be built from user
    /// input.
    func passwordCommand(destId: UUID) -> String

    /// Environment variables the ``passwordCommand(destId:)`` child needs in
    /// order to reach *this* store.
    ///
    /// `ResticRunner` replaces restic's environment rather than extending it
    /// (`docs/restic-cli.md` §General), and restic's password-command child
    /// inherits that replaced environment. A backend whose location is
    /// configurable — ``FileSecretStore``, which lives under
    /// `AppPaths.root` — must therefore say so here, or the child would look
    /// in the *default* data directory with the *default* backend and fail
    /// to find the password this process just read successfully.
    ///
    /// Empty for ``KeychainSecretStore``: `/usr/bin/security` needs no
    /// configuration, which is why macOS's assembled environment is
    /// unchanged by this requirement.
    ///
    /// **Never** put a secret in here: these values are passed to restic and
    /// on to its children.
    var passwordCommandEnvironment: [String: String] { get }
}

extension SecretStore {
    /// Most backends need nothing.
    public var passwordCommandEnvironment: [String: String] { [:] }

    public func updateDestinationSecrets(
        _ update: DestinationSecretUpdate
    ) async throws -> DestinationSecretRollback {
        let previousPassword: String?
        if update.password != nil {
            do {
                previousPassword = try await password(destId: update.destId)
            } catch SecretStoreError.itemNotFound {
                previousPassword = nil
            }
        } else {
            previousPassword = nil
        }
        let previousEnv = update.secretEnv == nil
            ? nil
            : try await secretEnv(destId: update.destId)
        let rollback = DestinationSecretRollback(
            destId: update.destId,
            password: update.password.map {
                SecretRollbackChange(installed: Optional($0), previous: previousPassword)
            },
            secretEnv: update.secretEnv.map {
                SecretRollbackChange(installed: $0, previous: previousEnv ?? [:])
            }
        )
        if let password = update.password {
            try await setPassword(password, destId: update.destId)
        }
        if let env = update.secretEnv {
            if env.isEmpty {
                try await deleteSecretEnv(destId: update.destId)
            } else {
                try await setSecretEnv(env, destId: update.destId)
            }
        }
        return rollback
    }

    /// Test/minimal-store fallback. Production stores override this with a
    /// single locked transaction; actors used by clients still get the same
    /// comparison semantics without needing storage-specific plumbing.
    public func restoreDestinationSecretsIfCurrent(
        _ rollback: DestinationSecretRollback
    ) async throws -> DestinationSecretRestoreResult {
        var passwordRestored: Bool?
        if let change = rollback.password {
            let current: String?
            do {
                current = try await password(destId: rollback.destId)
            } catch SecretStoreError.itemNotFound {
                current = nil
            }
            passwordRestored = current == change.installed
        }
        var secretEnvRestored: Bool?
        if let change = rollback.secretEnv {
            secretEnvRestored = try await secretEnv(destId: rollback.destId) == change.installed
        }
        if passwordRestored == true, let change = rollback.password {
            if let previous = change.previous {
                try await setPassword(previous, destId: rollback.destId)
            } else {
                try await deletePassword(destId: rollback.destId)
            }
        }
        if secretEnvRestored == true, let change = rollback.secretEnv {
            if change.previous.isEmpty {
                try await deleteSecretEnv(destId: rollback.destId)
            } else {
                try await setSecretEnv(change.previous, destId: rollback.destId)
            }
        }
        return DestinationSecretRestoreResult(
            passwordRestored: passwordRestored,
            secretEnvRestored: secretEnvRestored
        )
    }
}

public struct SecretRollbackChange<Value: Equatable & Sendable>: Equatable, Sendable {
    public let installed: Value
    public let previous: Value

    public init(installed: Value, previous: Value) {
        self.installed = installed
        self.previous = previous
    }
}

/// Persistent identity for one managed-field mutation. Production stores
/// advance this token even when a writer installs the same value (or deletes
/// an already-absent value), closing the ABA hole that value comparison alone
/// leaves across app/helper processes.
public struct SecretRollbackGeneration: Equatable, Sendable {
    public let installed: String
    public let previous: String?

    public init(installed: String, previous: String?) {
        self.installed = installed
        self.previous = previous
    }
}

public struct DestinationSecretRollback: Equatable, Sendable {
    public let destId: UUID
    public let password: SecretRollbackChange<String?>?
    public let secretEnv: SecretRollbackChange<[String: String]>?
    /// Exact pre-edit blob for production backends. This lets an explicit
    /// valid replacement repair malformed legacy/manual JSON while an
    /// abandoned editor can still restore those original bytes verbatim.
    public let previousSecretEnvRaw: String?
    public let passwordGeneration: SecretRollbackGeneration?
    public let secretEnvGeneration: SecretRollbackGeneration?

    public init(
        destId: UUID,
        password: SecretRollbackChange<String?>?,
        secretEnv: SecretRollbackChange<[String: String]>?,
        previousSecretEnvRaw: String? = nil,
        passwordGeneration: SecretRollbackGeneration? = nil,
        secretEnvGeneration: SecretRollbackGeneration? = nil
    ) {
        self.destId = destId
        self.password = password
        self.secretEnv = secretEnv
        self.previousSecretEnvRaw = previousSecretEnvRaw
        self.passwordGeneration = passwordGeneration
        self.secretEnvGeneration = secretEnvGeneration
    }
}

/// Per-field outcome of a conditional editor rollback. `nil` means the
/// editor did not manage that field; `false` means a newer mutation won and
/// was deliberately preserved. Keeping the fields separate lets an
/// unchanged environment roll back even when a helper replaced the password
/// (and vice versa).
public struct DestinationSecretRestoreResult: Equatable, Sendable {
    public let passwordRestored: Bool?
    public let secretEnvRestored: Bool?

    public init(passwordRestored: Bool?, secretEnvRestored: Bool?) {
        self.passwordRestored = passwordRestored
        self.secretEnvRestored = secretEnvRestored
    }

    public var allRestored: Bool {
        passwordRestored != false && secretEnvRestored != false
    }
}

public struct DestinationSecretUpdate: Equatable, Sendable {
    public let destId: UUID
    public let password: String?
    public let secretEnv: [String: String]?

    public init(destId: UUID, password: String?, secretEnv: [String: String]?) {
        self.destId = destId
        self.password = password
        self.secretEnv = secretEnv
    }
}

// MARK: - Account naming

/// The storage key for a destination's secrets, shared by both backends so
/// the keychain accounts and the `secrets.json` keys stay structurally
/// identical (`docs/data-model.md`).
///
/// Destination UUIDs never change (architecture.md §Identifiers) — the
/// destination UUID *is* the key, lowercased for a stable, predictable
/// string.
public enum SecretAccount {
    public static func password(_ destId: UUID) -> String {
        destId.uuidString.lowercased()
    }

    public static func secretEnv(_ destId: UUID) -> String {
        "\(password(destId))-env"
    }
}

// MARK: - Secret-env blob

/// The secret-env value both backends store: a compact JSON object of
/// `{"VAR": "value"}`.
///
/// restic's password-command mechanism only covers the repository password,
/// not arbitrary environment variables (e.g. `AWS_SECRET_ACCESS_KEY`), so
/// `ResticRunner` reads this blob itself and injects real env vars.
///
/// Shared between the backends deliberately: the encoding is part of the
/// on-disk/on-keychain contract, and one implementation means the two
/// backends can never drift.
enum SecretEnvBlob {
    /// - Note: the thrown message never includes `env` — its values are
    ///   secrets. Only the `Error`'s own type-level description is used.
    static func encode(_ env: [String: String]) throws -> String {
        let data: Data
        do {
            data = try JSONEncoder().encode(env)
        } catch {
            throw SecretStoreError.backendFailed("failed to encode secret env as JSON: \(error)")
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.backendFailed("failed to encode secret env as UTF-8 JSON")
        }
        return json
    }

    static func decode(_ json: String) throws -> [String: String] {
        guard let data = json.data(using: .utf8) else {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw SecretStoreError.backendFailed("failed to decode secret env JSON: \(error)")
        }
    }
}
