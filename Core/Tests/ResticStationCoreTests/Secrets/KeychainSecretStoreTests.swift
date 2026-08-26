#if os(macOS)
import Foundation
import Testing
@testable import ResticStationCore

@Suite("KeychainSecretStore")
struct KeychainSecretStoreTests {
    private static let destId = UUID(uuidString: "A1B2C3D4-E5F6-4789-A012-3456789ABCDE")!
    private static let account = "a1b2c3d4-e5f6-4789-a012-3456789abcde"

    @Test("passwordCommand matches the documented restic RESTIC_PASSWORD_COMMAND string byte-for-byte")
    func passwordCommandExactString() {
        let expected = "/usr/bin/security find-generic-password -s restic-station -a \(Self.account) -w"
        let client = KeychainSecretStore(runner: FakeProcessRunner())
        #expect(client.passwordCommand(destId: Self.destId) == expected)
    }

    @Test("setPassword deletes then adds, with -T on the create path, and ignores a not-found delete")
    func setPasswordDeleteThenAdd() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password"], exitCode: 0),
        ])
        let client = KeychainSecretStore(runner: runner)

        try await client.setPassword("hunter2", destId: Self.destId)

        #expect(runner.invocations.count == 2)

        let deleteArgv = runner.invocations[0].argv
        #expect(deleteArgv == [
            "/usr/bin/security", "delete-generic-password",
            "-s", "restic-station",
            "-a", Self.account,
        ])

        let addArgv = runner.invocations[1].argv
        #expect(addArgv == [
            "/usr/bin/security", "add-generic-password",
            "-s", "restic-station",
            "-a", Self.account,
            "-w", "hunter2",
            "-T", "/usr/bin/security",
        ])
        // -U must never appear: set* always goes through delete-then-add.
        #expect(!addArgv.contains("-U"))
    }

    @Test("setPassword still deletes-then-adds when an item already exists (delete succeeds)")
    func setPasswordDeleteThenAddWhenItemExists() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 0),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password"], exitCode: 0),
        ])
        let client = KeychainSecretStore(runner: runner)

        try await client.setPassword("newpw", destId: Self.destId)

        #expect(runner.invocations.count == 2)
        #expect(runner.invocations[0].argv[1] == "delete-generic-password")
        #expect(runner.invocations[1].argv[1] == "add-generic-password")
    }

    @Test("setPassword propagates a non-44 delete failure instead of proceeding to add")
    func setPasswordPropagatesRealDeleteFailure() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], stderr: "boom", exitCode: 1),
        ])
        let client = KeychainSecretStore(runner: runner)

        await #expect(throws: SecretStoreError.backendFailed("boom")) {
            try await client.setPassword("pw", destId: Self.destId)
        }
        // add must never have been attempted.
        #expect(runner.invocations.count == 1)
    }

    @Test("password() reads via find-generic-password and trims exactly one trailing newline")
    func passwordTrimsTrailingNewline() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "find-generic-password"], stdoutLines: ["hunter2"], exitCode: 0),
        ])
        let client = KeychainSecretStore(runner: runner)

        let pw = try await client.password(destId: Self.destId)

        #expect(pw == "hunter2")
        #expect(runner.invocations[0].argv == [
            "/usr/bin/security", "find-generic-password",
            "-s", "restic-station",
            "-a", Self.account,
            "-w",
        ])
    }

    @Test("password() surfaces exit 44 as SecretStoreError.itemNotFound")
    func passwordNotFound() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "find-generic-password"], exitCode: 44),
        ])
        let client = KeychainSecretStore(runner: runner)

        await #expect(throws: SecretStoreError.itemNotFound) {
            _ = try await client.password(destId: Self.destId)
        }
    }

    @Test("password() surfaces other nonzero exits as SecretStoreError.backendFailed with stderr")
    func passwordOtherFailure() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "find-generic-password"], stderr: "keychain locked", exitCode: 1),
        ])
        let client = KeychainSecretStore(runner: runner)

        await #expect(throws: SecretStoreError.backendFailed("keychain locked")) {
            _ = try await client.password(destId: Self.destId)
        }
    }

    @Test("deletePassword tolerates a not-found item (idempotent)")
    func deletePasswordToleratesNotFound() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
        ])
        let client = KeychainSecretStore(runner: runner)

        // Must not throw.
        try await client.deletePassword(destId: Self.destId)
        #expect(runner.invocations.count == 1)
    }

    @Test("deletePassword propagates a real failure")
    func deletePasswordPropagatesRealFailure() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], stderr: "denied", exitCode: 1),
        ])
        let client = KeychainSecretStore(runner: runner)

        await #expect(throws: SecretStoreError.backendFailed("denied")) {
            try await client.deletePassword(destId: Self.destId)
        }
    }

    @Test("secretEnv() round-trips a JSON dict blob through setSecretEnv/secretEnv")
    func secretEnvRoundTrip() async throws {
        let envVars = ["AWS_ACCESS_KEY_ID": "AKIA123", "AWS_SECRET_ACCESS_KEY": "shh"]

        let setRunner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password"], exitCode: 0),
        ])
        let setClient = KeychainSecretStore(runner: setRunner)
        try await setClient.setSecretEnv(envVars, destId: Self.destId)

        // Account for the env blob is "<uuid>-env".
        let addArgv = setRunner.invocations[1].argv
        #expect(addArgv == [
            "/usr/bin/security", "add-generic-password",
            "-s", "restic-station",
            "-a", "\(Self.account)-env",
            "-w", addArgv[7],
            "-T", "/usr/bin/security",
        ])

        // Capture exactly what was written (-w value) and feed it back as the
        // scripted find-generic-password reply to prove a real round trip.
        let writtenJSON = addArgv[7]
        let decodedDirectly = try JSONDecoder().decode([String: String].self, from: Data(writtenJSON.utf8))
        #expect(decodedDirectly == envVars)

        let getRunner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "find-generic-password"], stdoutLines: [writtenJSON], exitCode: 0),
        ])
        let getClient = KeychainSecretStore(runner: getRunner)
        let roundTripped = try await getClient.secretEnv(destId: Self.destId)

        #expect(roundTripped == envVars)
        #expect(getRunner.invocations[0].argv == [
            "/usr/bin/security", "find-generic-password",
            "-s", "restic-station",
            "-a", "\(Self.account)-env",
            "-w",
        ])
    }

    @Test("secretEnv() returns an empty dict when no item exists, rather than throwing")
    func secretEnvMissingItemReturnsEmptyDict() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "find-generic-password"], exitCode: 44),
        ])
        let client = KeychainSecretStore(runner: runner)

        let result = try await client.secretEnv(destId: Self.destId)
        #expect(result.isEmpty)
    }

    @Test("deleteSecretEnv targets the '-env' account and tolerates not-found")
    func deleteSecretEnvToleratesNotFound() async throws {
        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
        ])
        let client = KeychainSecretStore(runner: runner)

        try await client.deleteSecretEnv(destId: Self.destId)
        #expect(runner.invocations[0].argv == [
            "/usr/bin/security", "delete-generic-password",
            "-s", "restic-station",
            "-a", "\(Self.account)-env",
        ])
    }

    @Test("account strings are the lowercased UUID even when the source UUID is mixed/upper case")
    func accountStringIsLowercased() async throws {
        let mixedCaseId = UUID(uuidString: "A1B2C3D4-E5F6-4789-A012-3456789ABCDE")!
        #expect(mixedCaseId.uuidString != mixedCaseId.uuidString.lowercased())

        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "find-generic-password"], exitCode: 44),
        ])
        let client = KeychainSecretStore(runner: runner)

        await #expect(throws: SecretStoreError.itemNotFound) {
            _ = try await client.password(destId: mixedCaseId)
        }
        #expect(runner.invocations[0].argv.contains(Self.account))
    }

    @Test("conditional rollback preserves a newer password and restores the unchanged environment")
    func conditionalRollbackRestoresFieldsIndependently() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-keychain-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installedEnv = try SecretEnvBlob.encode(["TOKEN": "editor"])
        let runner = FakeProcessRunner(script: [
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: ["newer-helper-password"]
            ),
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: [installedEnv]
            ),
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 0),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password"], exitCode: 0),
        ])
        let client = KeychainSecretStore(runner: runner, paths: AppPaths(root: root))
        let rollback = DestinationSecretRollback(
            destId: Self.destId,
            password: SecretRollbackChange(
                installed: "editor-password",
                previous: "original-password"
            ),
            secretEnv: SecretRollbackChange(
                installed: ["TOKEN": "editor"],
                previous: ["TOKEN": "original"]
            )
        )

        let result = try await client.restoreDestinationSecretsIfCurrent(rollback)

        #expect(result.passwordRestored == false)
        #expect(result.secretEnvRestored == true)
        #expect(!result.allRestored)
        #expect(runner.invocations.count == 4)
        let restoredEnv = try SecretEnvBlob.decode(runner.invocations[3].argv[7])
        #expect(restoredEnv == ["TOKEN": "original"])
    }

    @Test("production keychain mutations wait for the shared secrets lock")
    func keychainMutationUsesSharedLock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-keychain-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        let heldLock = FileLock(path: paths.secretsLockFile, trustedRoot: root)
        #expect(heldLock.acquire() == .acquired)

        let runner = FakeProcessRunner(script: [
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
        ])
        let client = KeychainSecretStore(runner: runner, paths: paths)
        let mutation = Task {
            try await client.deletePassword(destId: Self.destId)
        }

        try await Task.sleep(for: .milliseconds(75))
        #expect(runner.invocations.isEmpty)
        heldLock.release()
        try await mutation.value
        #expect(runner.invocations.count == 1)
    }
}
#endif
