import Foundation
import Testing
@testable import ResticStationCore

@Suite("SecretBackend selection")
struct SecretBackendTests {
    static let helperPath = "/opt/restic-station/restic-station-helper"
    static let destId = UUID(uuidString: "A1B2C3D4-E5F6-4789-A012-3456789ABCDE")!

    static func paths() -> AppPaths {
        AppPaths(root: URL(fileURLWithPath: "/tmp/restic-station-secret-backend-tests", isDirectory: true))
    }

    @Test("no override → the platform default (keychain on macOS, file elsewhere)")
    func platformDefault() throws {
        #expect(try SecretBackend.resolve(environment: [:]) == SecretBackend.platformDefault)
        #if os(macOS)
        #expect(SecretBackend.platformDefault == .keychain)
        #else
        #expect(SecretBackend.platformDefault == .file)
        #endif
    }

    @Test("an empty override is treated as unset, like every other env override here")
    func emptyOverrideIsUnset() throws {
        let resolved = try SecretBackend.resolve(environment: [SecretBackend.environmentKey: "  "])
        #expect(resolved == SecretBackend.platformDefault)
    }

    @Test("an explicit override wins, case-insensitively")
    func explicitOverride() throws {
        #expect(try SecretBackend.resolve(environment: [SecretBackend.environmentKey: "file"]) == .file)
        #expect(try SecretBackend.resolve(environment: [SecretBackend.environmentKey: "FILE"]) == .file)
        #expect(try SecretBackend.resolve(environment: [SecretBackend.environmentKey: "keychain"]) == .keychain)
    }

    @Test("an unrecognised value is a hard error, never a silent fallback")
    func unrecognisedValueThrows() throws {
        do {
            _ = try SecretBackend.resolve(environment: [SecretBackend.environmentKey: "gnome-keyring"])
            Issue.record("expected an unrecognised backend to throw")
        } catch let error as SecretStoreError {
            guard case .storeUnusable(let message) = error else {
                Issue.record("expected .storeUnusable, got \(error)")
                return
            }
            #expect(message.contains(SecretBackend.environmentKey))
            #expect(message.contains("gnome-keyring"))
            #expect(message.contains("keychain"))
            #expect(message.contains("file"))
        }
    }

    @Test("the factory builds a FileSecretStore when asked for file, on every platform")
    func factoryBuildsFileBackend() throws {
        let store = try SecretStoreFactory.make(
            paths: Self.paths(),
            runner: FakeProcessRunner(),
            helperExecutablePath: Self.helperPath,
            environment: [SecretBackend.environmentKey: "file"]
        )
        #expect(store is FileSecretStore)
        #expect(store.backend == .file)
    }

    /// Regression test for the review finding that the file backend captured
    /// the *current* executable as its password-command target.
    ///
    /// That default is correct only inside the helper. The app process builds
    /// a store too (restore browsing, `mount`, primary `init`), and there it
    /// would name the SwiftUI app binary — restic would run the app with
    /// `print-password --dest …`, get no password, and possibly try to start
    /// a UI from a background child. The factory therefore *requires* the
    /// path, and this test pins that it is honoured rather than silently
    /// falling back.
    ///
    /// The test process's own executable (the test runner) stands in for
    /// "any wrong binary": it is emphatically not `restic-station-helper`.
    @Test("the file backend uses the helper path it was given, never the current executable")
    func factoryUsesTheGivenHelperPath() throws {
        let store = try SecretStoreFactory.make(
            paths: Self.paths(),
            runner: FakeProcessRunner(),
            helperExecutablePath: Self.helperPath,
            environment: [SecretBackend.environmentKey: "file"]
        )

        let command = store.passwordCommand(destId: Self.destId)
        #expect(command == "\(Self.helperPath) print-password --dest \(Self.destId.uuidString.lowercased())")

        let currentExecutable = FileSecretStore.currentExecutablePath()
        #expect(
            !command.contains(currentExecutable),
            "the password command named this process (\(currentExecutable)) instead of the helper"
        )
    }

    @Test("the factory's default matches the platform default")
    func factoryDefault() throws {
        let store = try SecretStoreFactory.make(
            paths: Self.paths(),
            runner: FakeProcessRunner(),
            helperExecutablePath: Self.helperPath,
            environment: [:]
        )
        #expect(store.backend == SecretBackend.platformDefault)
        #if os(macOS)
        #expect(store is KeychainSecretStore)
        #else
        #expect(store is FileSecretStore)
        #endif
    }

    // MARK: - User-facing wording follows the backend, not the OS

    /// Regression test for the review finding that secret-store messaging
    /// branched on `#if os(macOS)`. On a macOS host running the file backend
    /// — a supported configuration, and the one the CI script exercises — a
    /// widened `secrets.json` mode used to advise "unlock your login
    /// keychain", which is the wrong next step during an incident.
    @Test("each backend describes itself; wording never branches on the host OS")
    func wordingFollowsTheBackend() {
        // The keychain wording is byte-for-byte what shipped before the
        // SecretStore abstraction: macOS users see no change.
        #expect(SecretBackend.keychain.displayName == "the login keychain")
        #expect(
            SecretBackend.keychain.unavailableSummary
                == "The password for this destination could not be read from the keychain."
        )
        #expect(
            SecretBackend.keychain.unavailableAdvice
                == "Unlock your login keychain, then run the backup again."
        )
        // `SetsBadges.offlineOrError` matches this string to classify the
        // failure as environmental rather than as a repository error.
        #expect(SecretBackend.keychain.unavailableProbeReason == "keychain locked")

        // The file backend never mentions the keychain, and points at the
        // thing a user can actually fix.
        #expect(SecretBackend.file.displayName == "the secrets file")
        #expect(SecretBackend.file.unavailableSummary.contains("secrets file"))
        #expect(!SecretBackend.file.unavailableSummary.lowercased().contains("keychain"))
        #expect(SecretBackend.file.unavailableAdvice.contains("permissions"))
        #expect(!SecretBackend.file.unavailableAdvice.lowercased().contains("keychain"))
        #expect(SecretBackend.file.unavailableProbeReason == "secret store unavailable")

        // Each store reports its own backend, which is what the wording is
        // taken from.
        #expect(FileSecretStore(paths: Self.paths(), helperPath: Self.helperPath).backend == .file)
        #if os(macOS)
        #expect(KeychainSecretStore(runner: FakeProcessRunner()).backend == .keychain)
        #endif
    }

    @Test("SecretBackend.configured follows the override, and never throws")
    func configuredFollowsTheOverride() {
        // `configured` reads the process environment, so it is asserted
        // against `resolve` rather than by mutating the environment.
        #expect(SecretBackend.configured == ((try? SecretBackend.resolve()) ?? .platformDefault))
        // A bad value is a hard error when *constructing* a store, but a
        // message must never throw.
        #expect(
            (try? SecretBackend.resolve(environment: [SecretBackend.environmentKey: "nope"])) == nil
        )
    }

    #if !os(macOS)
    @Test("asking for the keychain off macOS fails loudly")
    func keychainOffMacOSThrows() throws {
        #expect(throws: SecretStoreError.self) {
            _ = try SecretStoreFactory.make(
                paths: Self.paths(),
                runner: FakeProcessRunner(),
                helperExecutablePath: Self.helperPath,
                environment: [SecretBackend.environmentKey: "keychain"]
            )
        }
    }
    #endif
}
