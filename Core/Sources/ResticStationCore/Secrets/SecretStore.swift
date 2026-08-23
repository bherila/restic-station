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
    /// Any other backend failure, with the backend's own diagnostic text.
    case backendFailed(String)

    public var description: String {
        switch self {
        case .itemNotFound:
            return "no stored secret for this destination"
        case .lockUnusable(let failure):
            return "secrets lock unusable: \(failure)"
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
