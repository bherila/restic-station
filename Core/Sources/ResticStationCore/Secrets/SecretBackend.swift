import Foundation

/// Which ``SecretStore`` implementation this process uses.
///
/// The default follows the platform — macOS gets the keychain, everything
/// else gets the file backend — and is overridable with
/// `RESTIC_STATION_SECRET_BACKEND=keychain|file`.
///
/// The override is not a convenience knob: it is how the Linux file backend
/// gets exercised on macOS (developer runs, `swift test`, and the macOS CI
/// job), which is the only way this repository can test that code path
/// without a Linux host. It is also the escape hatch for a macOS user who
/// prefers a file to the login keychain.
///
/// An unrecognised value is a **hard error**, never a silent fallback:
/// quietly falling back to the wrong backend would look like "all my
/// passwords disappeared".
public enum SecretBackend: String, Sendable, CaseIterable {
    case keychain
    case file

    public static let environmentKey = "RESTIC_STATION_SECRET_BACKEND"

    public static var platformDefault: SecretBackend {
        #if os(macOS)
        return .keychain
        #else
        return .file
        #endif
    }

    /// - Throws: ``SecretStoreError/backendFailed(_:)`` naming the variable,
    ///   the bad value, and the accepted values.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SecretBackend {
        guard let raw = environment[environmentKey] else {
            return platformDefault
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // An empty value is "unset" everywhere else in this codebase
            // (`AppPaths.default()` treats it the same way).
            return platformDefault
        }
        guard let backend = SecretBackend(rawValue: trimmed.lowercased()) else {
            throw SecretStoreError.backendFailed(
                "\(environmentKey)=\"\(raw)\" is not a known secret backend — "
                    + "expected \"keychain\" or \"file\""
            )
        }
        return backend
    }

    /// The backend this process is configured to use, for **user-facing text
    /// only**.
    ///
    /// Falls back to the platform default when the override is unrecognised,
    /// because a message must never throw — the *construction* path already
    /// treats that same value as a hard error, so a process that got far
    /// enough to render an error message resolved successfully here too.
    ///
    /// Prefer a `SecretStore`'s own ``SecretStore/backend`` wherever a store
    /// is in hand: that is the store actually in use. This exists for the one
    /// place that has no store — ``ResticRunnerError/userFacingMessage``,
    /// which is a property on an error value.
    public static var configured: SecretBackend {
        (try? resolve()) ?? platformDefault
    }

    // MARK: - User-facing wording
    //
    // All secret-store wording lives here, so it is chosen by the backend in
    // use rather than by the host OS. The pre-T23 macOS strings are
    // reproduced verbatim by the `.keychain` cases: on macOS without an
    // override nothing a user sees has changed.

    /// A noun phrase naming this store, e.g. "the login keychain could not be
    /// read for destination …".
    public var displayName: String {
        switch self {
        case .keychain: return "the login keychain"
        case .file: return "the secrets file"
        }
    }

    /// One sentence of "what happened", for
    /// ``ResticRunnerError/secretsUnavailable(destinationId:)``.
    public var unavailableSummary: String {
        switch self {
        case .keychain: return "The password for this destination could not be read from the keychain."
        case .file: return "The password for this destination could not be read from the secrets file."
        }
    }

    /// One sentence of "what to do next" (`docs/ui-spec.md` §Voice).
    public var unavailableAdvice: String {
        switch self {
        case .keychain: return "Unlock your login keychain, then run the backup again."
        case .file: return "Check the permissions on the secrets file, then run the backup again."
        }
    }

    /// What `Reachability` records in `state/repo-status-<destId>.json` when
    /// the secret pre-flight fails.
    ///
    /// The `.keychain` string is matched by the app's badge heuristic
    /// (`SetsBadges.offlineOrError`) to classify the failure as environmental
    /// rather than as a repository error — changing it would silently turn an
    /// "offline" badge into an "error" badge. `SetsBadges` knows both.
    public var unavailableProbeReason: String {
        switch self {
        case .keychain: return "keychain locked"
        case .file: return "secret store unavailable"
        }
    }
}

/// Builds the ``SecretStore`` this process should use.
///
/// Every entry point that touches secrets goes through here — the helper's
/// `HelperContext`, the `secret` subcommands, and the app — so backend
/// selection happens in exactly one place.
public enum SecretStoreFactory {

    /// - Parameters:
    ///   - paths: the file backend's data directory.
    ///   - runner: the keychain backend's `/usr/bin/security` subprocess
    ///     runner. Unused by the file backend.
    ///   - helperExecutablePath: absolute path of the
    ///     **`restic-station-helper` binary**, which the file backend bakes
    ///     into `RESTIC_PASSWORD_COMMAND`.
    ///
    ///     Deliberately required, with no default. The obvious default —
    ///     "this executable" — is right only inside the helper: the app
    ///     process also builds a store (restore browsing, `mount`, primary
    ///     `init`), and defaulting there would point
    ///     `RESTIC_PASSWORD_COMMAND` at the SwiftUI app binary, which cannot
    ///     print a password and would try to start a UI from restic's child
    ///     process. Making every caller name the binary turns that into a
    ///     compile error instead of a runtime hang. The helper passes
    ///     ``FileSecretStore/currentExecutablePath()``; the app passes its
    ///     embedded helper's path.
    /// - Throws: ``SecretStoreError/backendFailed(_:)`` for an unrecognised
    ///   `RESTIC_STATION_SECRET_BACKEND`, or for `keychain` on a platform
    ///   that has no `/usr/bin/security`.
    public static func make(
        paths: AppPaths,
        runner: ProcessRunning,
        helperExecutablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any SecretStore {
        switch try SecretBackend.resolve(environment: environment) {
        case .keychain:
            #if os(macOS)
            return KeychainSecretStore(runner: runner)
            #else
            throw SecretStoreError.backendFailed(
                "\(SecretBackend.environmentKey)=keychain is only available on macOS — "
                    + "/usr/bin/security does not exist on this platform. "
                    + "Use \(SecretBackend.environmentKey)=file, or leave it unset."
            )
            #endif
        case .file:
            return FileSecretStore(paths: paths, helperPath: helperExecutablePath)
        }
    }
}
