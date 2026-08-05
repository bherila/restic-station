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
    /// - Throws: ``SecretStoreError/backendFailed(_:)`` for an unrecognised
    ///   `RESTIC_STATION_SECRET_BACKEND`, or for `keychain` on a platform
    ///   that has no `/usr/bin/security`.
    public static func make(
        paths: AppPaths,
        runner: ProcessRunning,
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
            return FileSecretStore(paths: paths)
        }
    }
}
