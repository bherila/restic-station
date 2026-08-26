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
        #expect(runner.invocations.count == 3)
        #expect(runner.invocations[2].argv.contains("-U"))
        let restoredEnv = try SecretEnvBlob.decode(runner.invocations[2].argv[8])
        #expect(restoredEnv == ["TOKEN": "original"])
    }

    @Test("conditional rollback preserves same-value writes from another process")
    func conditionalRollbackUsesPersistentGenerations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-keychain-generations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let envAccount = "\(Self.account)-env"
        let runner = StatefulKeychainRunner(items: [
            Self.account: "original-password",
            envAccount: try SecretEnvBlob.encode(["TOKEN": "original"]),
        ])
        let client = KeychainSecretStore(runner: runner, paths: AppPaths(root: root))
        let rollback = try await client.updateDestinationSecrets(
            DestinationSecretUpdate(
                destId: Self.destId,
                password: "editor-password",
                secretEnv: [:]
            )
        )

        // A separate helper invocation takes the same cross-process lock and
        // advances the field identity even though the values do not change.
        try await client.setPassword("editor-password", destId: Self.destId)
        try await client.deleteSecretEnv(destId: Self.destId)
        let result = try await client.restoreDestinationSecretsIfCurrent(rollback)

        #expect(result.passwordRestored == false)
        #expect(result.secretEnvRestored == false)
        #expect(try await client.password(destId: Self.destId) == "editor-password")
        #expect(try await client.secretEnv(destId: Self.destId).isEmpty)
    }

    @Test("failed direct password mutations restore the previous generation marker")
    func failedDirectPasswordMutationRestoresGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-keychain-generation-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let generationAccount = "\(Self.account)-generation"
        let runner = StatefulKeychainRunner(items: [
            Self.account: "editor-password",
            generationAccount: "editor-generation",
        ])
        runner.failNextDelete(account: Self.account)
        let client = KeychainSecretStore(runner: runner, paths: AppPaths(root: root))

        await #expect(throws: SecretStoreError.backendFailed("injected delete failure")) {
            try await client.setPassword("helper-password", destId: Self.destId)
        }

        #expect(runner.value(account: Self.account) == "editor-password")
        #expect(runner.value(account: generationAccount) == "editor-generation")
    }

    @Test("failed direct environment deletes restore the previous generation marker")
    func failedDirectEnvironmentDeleteRestoresGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-keychain-env-generation-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let envAccount = "\(Self.account)-env"
        let generationAccount = "\(envAccount)-generation"
        let raw = try SecretEnvBlob.encode(["TOKEN": "editor"])
        let runner = StatefulKeychainRunner(items: [
            envAccount: raw,
            generationAccount: "editor-generation",
        ])
        runner.failNextDelete(account: envAccount)
        let client = KeychainSecretStore(runner: runner, paths: AppPaths(root: root))

        await #expect(throws: SecretStoreError.backendFailed("injected delete failure")) {
            try await client.deleteSecretEnv(destId: Self.destId)
        }

        #expect(runner.value(account: envAccount) == raw)
        #expect(runner.value(account: generationAccount) == "editor-generation")
    }

    @Test("failed password update does not rewrite an untouched environment")
    func failedPasswordUpdateRestoresOnlyStartedFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-keychain-partial-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previousEnvRaw = try SecretEnvBlob.encode(["TOKEN": "original"])
        let runner = FakeProcessRunner(script: [
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: ["original-password"]
            ),
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: [previousEnvRaw]
            ),
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 0),
            .init(
                argvPrefix: ["/usr/bin/security", "add-generic-password"],
                stderr: "injected password failure",
                exitCode: 1
            ),
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password"], exitCode: 0),
        ])
        let client = KeychainSecretStore(runner: runner)

        await #expect(throws: SecretStoreError.backendFailed("injected password failure")) {
            _ = try await client.updateDestinationSecrets(
                DestinationSecretUpdate(
                    destId: Self.destId,
                    password: "new-password",
                    secretEnv: ["TOKEN": "new"]
                )
            )
        }

        #expect(runner.invocations.count == 6)
        #expect(runner.invocations.dropFirst(2).allSatisfy {
            !$0.argv.contains("\(Self.account)-env")
        })
        #expect(runner.invocations[5].argv[7] == "original-password")
    }

    @Test("a failed generation write never recreates an untouched credential")
    func failedGenerationWriteRestoresOnlyItsMarker() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-keychain-generation-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let generationAccount = "\(Self.account)-generation"
        let runner = FakeProcessRunner(script: [
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: ["original-password"]
            ),
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: ["original-generation"]
            ),
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 0),
            .init(
                argvPrefix: ["/usr/bin/security", "add-generic-password"],
                stderr: "injected generation failure",
                exitCode: 1
            ),
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password"], exitCode: 0),
        ])
        let client = KeychainSecretStore(runner: runner, paths: AppPaths(root: root))

        await #expect(throws: SecretStoreError.backendFailed("injected generation failure")) {
            _ = try await client.updateDestinationSecrets(
                DestinationSecretUpdate(
                    destId: Self.destId,
                    password: "new-password",
                    secretEnv: nil
                )
            )
        }

        #expect(runner.invocations.count == 6)
        #expect(runner.invocations.dropFirst().allSatisfy { invocation in
            guard let accountIndex = invocation.argv.firstIndex(of: "-a"),
                  accountIndex + 1 < invocation.argv.count else { return false }
            return invocation.argv[accountIndex + 1] == generationAccount
        })
        #expect(runner.invocations.last?.argv[7] == "original-generation")
    }

    @Test("a failed conditional replacement remains retryable without deleting the installed item")
    func conditionalRollbackReplacementIsAtomicAndRetryable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-keychain-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeProcessRunner(script: [
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: ["editor-password"]
            ),
            .init(
                argvPrefix: ["/usr/bin/security", "add-generic-password", "-U"],
                stderr: "transient failure",
                exitCode: 1
            ),
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: ["editor-password"]
            ),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password", "-U"], exitCode: 0),
        ])
        let client = KeychainSecretStore(runner: runner, paths: AppPaths(root: root))
        let rollback = DestinationSecretRollback(
            destId: Self.destId,
            password: SecretRollbackChange(
                installed: "editor-password",
                previous: "original-password"
            ),
            secretEnv: nil
        )

        await #expect(throws: SecretStoreError.backendFailed("transient failure")) {
            _ = try await client.restoreDestinationSecretsIfCurrent(rollback)
        }
        let result = try await client.restoreDestinationSecretsIfCurrent(rollback)

        #expect(result.passwordRestored == true)
        #expect(runner.invocations.count == 4)
        #expect(!runner.invocations.contains { $0.argv.contains("delete-generic-password") })
        #expect(runner.invocations[3].argv[8] == "original-password")
    }

    @Test("a valid environment edit can replace and roll back a malformed keychain blob")
    func malformedEnvironmentCanBeRepairedAndRestored() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-keychain-malformed-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let validEnv = ["TOKEN": "repaired"]
        let validRaw = try SecretEnvBlob.encode(validEnv)
        let malformedRaw = "{not-json"
        let runner = FakeProcessRunner(script: [
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: [malformedRaw]
            ),
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 0),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password"], exitCode: 0),
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: [validRaw]
            ),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password", "-U"], exitCode: 0),
        ])
        let client = KeychainSecretStore(runner: runner)

        let rollback = try await client.updateDestinationSecrets(
            DestinationSecretUpdate(destId: Self.destId, password: nil, secretEnv: validEnv)
        )
        #expect(rollback.previousSecretEnvRaw == malformedRaw)
        let result = try await client.restoreDestinationSecretsIfCurrent(rollback)

        #expect(result.secretEnvRestored == true)
        #expect(runner.invocations.count == 5)
        #expect(runner.invocations[4].argv[8] == malformedRaw)
    }

    @Test("rolling back a cleared environment recreates it with the trusted ACL")
    func clearedEnvironmentRollbackUsesTrustedCreationPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-keychain-cleared-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previousRaw = try SecretEnvBlob.encode(["TOKEN": "original"])
        let runner = FakeProcessRunner(script: [
            .init(
                argvPrefix: ["/usr/bin/security", "find-generic-password"],
                stdoutLines: [previousRaw]
            ),
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 0),
            .init(argvPrefix: ["/usr/bin/security", "find-generic-password"], exitCode: 44),
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password"], exitCode: 0),
        ])
        let client = KeychainSecretStore(runner: runner)
        let rollback = try await client.updateDestinationSecrets(
            DestinationSecretUpdate(destId: Self.destId, password: nil, secretEnv: [:])
        )

        let result = try await client.restoreDestinationSecretsIfCurrent(rollback)

        #expect(result.secretEnvRestored == true)
        let creationArgv = runner.invocations[4].argv
        #expect(creationArgv.contains("-T"))
        #expect(creationArgv.contains("/usr/bin/security"))
        #expect(!creationArgv.contains("-U"))
        #expect(creationArgv[7] == previousRaw)
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
            .init(argvPrefix: ["/usr/bin/security", "find-generic-password"], exitCode: 44),
            .init(argvPrefix: ["/usr/bin/security", "delete-generic-password"], exitCode: 44),
            .init(argvPrefix: ["/usr/bin/security", "add-generic-password"], exitCode: 0),
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
        #expect(runner.invocations.count == 4)
    }
}

private final class StatefulKeychainRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    private var deleteFailures: Set<String> = []

    init(items: [String: String]) {
        self.items = items
    }

    func failNextDelete(account: String) {
        _ = withLock { deleteFailures.insert(account) }
    }

    func value(account: String) -> String? {
        withLock { items[account] }
    }

    func run(
        _ argv: [String],
        env: [String: String]?,
        stdin: Data?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?
    ) async throws -> ProcessResult {
        withLock {
            guard let accountFlag = argv.firstIndex(of: "-a"), accountFlag + 1 < argv.count else {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing account".utf8))
            }
            let account = argv[accountFlag + 1]
            switch argv.dropFirst().first {
            case "find-generic-password":
                guard let value = items[account] else {
                    return ProcessResult(exitCode: 44, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data((value + "\n").utf8), stderr: Data())
            case "delete-generic-password":
                if deleteFailures.remove(account) != nil {
                    return ProcessResult(
                        exitCode: 1,
                        stdout: Data(),
                        stderr: Data("injected delete failure".utf8)
                    )
                }
                guard items.removeValue(forKey: account) != nil else {
                    return ProcessResult(exitCode: 44, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            case "add-generic-password":
                guard let passwordFlag = argv.firstIndex(of: "-w"), passwordFlag + 1 < argv.count else {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing value".utf8))
                }
                items[account] = argv[passwordFlag + 1]
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            default:
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("unsupported command".utf8))
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
#endif
