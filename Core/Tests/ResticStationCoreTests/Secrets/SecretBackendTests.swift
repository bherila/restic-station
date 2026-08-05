import Foundation
import Testing
@testable import ResticStationCore

@Suite("SecretBackend selection")
struct SecretBackendTests {
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
            guard case .backendFailed(let message) = error else {
                Issue.record("expected .backendFailed, got \(error)")
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
            environment: [SecretBackend.environmentKey: "file"]
        )
        #expect(store is FileSecretStore)
    }

    @Test("the factory's default matches the platform default")
    func factoryDefault() throws {
        let store = try SecretStoreFactory.make(
            paths: Self.paths(),
            runner: FakeProcessRunner(),
            environment: [:]
        )
        #if os(macOS)
        #expect(store is KeychainSecretStore)
        #else
        #expect(store is FileSecretStore)
        #endif
    }

    #if !os(macOS)
    @Test("asking for the keychain off macOS fails loudly")
    func keychainOffMacOSThrows() throws {
        #expect(throws: SecretStoreError.self) {
            _ = try SecretStoreFactory.make(
                paths: Self.paths(),
                runner: FakeProcessRunner(),
                environment: [SecretBackend.environmentKey: "keychain"]
            )
        }
    }
    #endif
}
