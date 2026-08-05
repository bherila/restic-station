import Foundation
import Testing
@testable import ResticStationCore

@Suite("ResticRunner: env assembly, secret pre-flight, streaming, exit mapping")
struct ResticRunnerTests {
    // MARK: - Fixtures for these tests

    static let resticPath = "/usr/local/bin/restic"
    static let primaryId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let secondaryId = UUID(uuidString: "66666666-7777-8888-9999-000000000000")!
    static let password = "correct-horse-battery-staple"

    static let primary = Destination(
        id: primaryId,
        label: "Primary",
        repoURL: "/Volumes/Backup/primary",
        isPrimary: true,
        nonSecretEnv: ["AWS_DEFAULT_REGION": "auto"]
    )
    static let secondary = Destination(
        id: secondaryId,
        label: "R2 mirror",
        repoURL: "s3:https://acct.r2.cloudflarestorage.com/bucket/prefix",
        isPrimary: false,
        nonSecretEnv: ["AWS_DEFAULT_REGION": "us-east-1"]
    )

    static func paths() -> AppPaths {
        AppPaths(root: URL(fileURLWithPath: "/tmp/restic-station-tests", isDirectory: true))
    }

    /// The secret store is injected as a `FakeSecretStore`, so the scripted
    /// process expectations below contain restic spawns and nothing else —
    /// there is no `/usr/bin/security` argv anywhere in this file any more.
    /// That is what makes these tests run identically on macOS and Linux.
    static func makeRunner(
        _ fake: FakeProcessRunner,
        secrets: FakeSecretStore = FakeSecretStore(defaultPassword: password)
    ) -> ResticRunner {
        ResticRunner(
            resticPath: resticPath,
            paths: paths(),
            secrets: secrets,
            runner: fake
        )
    }

    static func expectedPasswordCommand(_ id: UUID) -> String {
        FakeSecretStore.passwordCommand(destId: id)
    }

    /// A store where every destination has ``password`` and `id` also has a
    /// secret-env blob.
    static func secretStore(for id: UUID, secretEnv: [String: String]) -> FakeSecretStore {
        let store = FakeSecretStore(defaultPassword: password)
        store.store(secretEnv: secretEnv, for: id)
        return store
    }

    // MARK: - Environment assembly

    @Test("single destination: exact password command, cache dir, secret env injected, nothing inherited")
    func environmentForSingleDestination() async throws {
        let fake = FakeProcessRunner(script: [
            .init(argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "backup", "--json"]),
        ])
        let runner = Self.makeRunner(fake, secrets: Self.secretStore(
            for: Self.primaryId,
            secretEnv: ["AWS_ACCESS_KEY_ID": "AKIAPRIMARY", "AWS_SECRET_ACCESS_KEY": "primary-secret"]
        ))

        let outcome = try await runner.run(
            .backup(repo: Self.primary.repoURL, sources: ["/Users/user/Documents"]),
            for: ResticInvocation(destination: Self.primary)
        )
        #expect(outcome.exitCode == 0)
        #expect(outcome.status == .success)

        // Reading secrets is not a subprocess any more: restic is the only
        // thing this runner spawns.
        #expect(fake.invocations.count == 1)
        let resticCall = fake.invocations[0]
        #expect(resticCall.argv == [
            Self.resticPath, "-r", Self.primary.repoURL, "backup", "--json", "/Users/user/Documents",
        ])

        let env = try #require(resticCall.env)
        #expect(env["RESTIC_PASSWORD_COMMAND"] == Self.expectedPasswordCommand(Self.primaryId))
        #expect(env["RESTIC_FROM_PASSWORD_COMMAND"] == nil)
        #expect(env["RESTIC_CACHE_DIR"] == Self.paths().resticCacheDir.path)
        #expect(env["AWS_ACCESS_KEY_ID"] == "AKIAPRIMARY")
        #expect(env["AWS_SECRET_ACCESS_KEY"] == "primary-secret")
        #expect(env["AWS_DEFAULT_REGION"] == "auto")

        // The inherited environment is REPLACED, not extended: PATH is the
        // FIXED system path (never the test process's inherited one), and no
        // key outside the documented set may appear.
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        let allowed: Set<String> = [
            "HOME", "USER", "TMPDIR", "PATH",
            "RESTIC_CACHE_DIR", "RESTIC_PASSWORD_COMMAND",
            "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_DEFAULT_REGION",
        ]
        #expect(Set(env.keys).isSubset(of: allowed), "unexpected env keys: \(Set(env.keys).subtracting(allowed))")
    }

    @Test("argv never contains a secret, by construction")
    func argvContainsNoSecrets() async throws {
        let fake = FakeProcessRunner(script: [
            .init(argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "backup", "--json"]),
        ])
        let runner = Self.makeRunner(fake, secrets: Self.secretStore(
            for: Self.primaryId,
            secretEnv: ["AWS_SECRET_ACCESS_KEY": "primary-secret"]
        ))
        _ = try await runner.run(
            .backup(repo: Self.primary.repoURL, sources: ["/Users/user/Documents"]),
            for: ResticInvocation(destination: Self.primary)
        )

        let resticArgv = fake.invocations[0].argv
        for element in resticArgv {
            #expect(element != Self.password)
            #expect(!element.contains(Self.password))
            #expect(!element.contains("primary-secret"))
        }
    }

    @Test("from-destination: both password commands, destination wins every env conflict")
    func environmentWithFromDestination() async throws {
        // Both destinations define AWS_ACCESS_KEY_ID (secret) and
        // AWS_DEFAULT_REGION (non-secret); the `-r` destination must win.
        let fake = FakeProcessRunner(script: [
            .init(argvPrefix: [Self.resticPath, "-r", Self.secondary.repoURL, "copy"]),
        ])
        let secrets = FakeSecretStore(defaultPassword: Self.password)
        secrets.store(secretEnv: ["AWS_ACCESS_KEY_ID": "AKIAPRIMARY", "PRIMARY_ONLY": "yes"], for: Self.primaryId)
        secrets.store(secretEnv: ["AWS_ACCESS_KEY_ID": "AKIASECONDARY"], for: Self.secondaryId)
        let runner = Self.makeRunner(fake, secrets: secrets)

        _ = try await runner.run(
            .copy(toRepo: Self.secondary.repoURL, fromRepo: Self.primary.repoURL),
            for: ResticInvocation(destination: Self.secondary, fromDestination: Self.primary)
        )

        #expect(fake.invocations.count == 1)
        let resticCall = fake.invocations[0]
        #expect(resticCall.argv == [
            Self.resticPath, "-r", Self.secondary.repoURL, "copy", "--from-repo", Self.primary.repoURL,
        ])

        let env = try #require(resticCall.env)
        #expect(env["RESTIC_PASSWORD_COMMAND"] == Self.expectedPasswordCommand(Self.secondaryId))
        #expect(env["RESTIC_FROM_PASSWORD_COMMAND"] == Self.expectedPasswordCommand(Self.primaryId))
        // Conflicts resolve in favour of the `-r` destination…
        #expect(env["AWS_ACCESS_KEY_ID"] == "AKIASECONDARY")
        #expect(env["AWS_DEFAULT_REGION"] == "us-east-1")
        // …while non-conflicting from-destination values survive.
        #expect(env["PRIMARY_ONLY"] == "yes")
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("nonSecretEnv cannot hijack the restic-controlling variables")
    func configuredEnvCannotOverrideResticVars() async throws {
        let hostile = Destination(
            id: Self.primaryId,
            label: "Hostile config",
            repoURL: "/repo",
            isPrimary: true,
            nonSecretEnv: [
                "RESTIC_PASSWORD_COMMAND": "/bin/echo pwned",
                "RESTIC_CACHE_DIR": "/tmp/pwned",
                "RESTIC_PASSWORD": "pwned",
            ]
        )
        let fake = FakeProcessRunner(script: [
            .init(argvPrefix: [Self.resticPath, "-r", "/repo", "snapshots", "--json"]),
        ])
        let runner = Self.makeRunner(fake)
        _ = try await runner.run(.snapshots(repo: "/repo"), for: ResticInvocation(destination: hostile))

        let env = try #require(fake.invocations[0].env)
        #expect(env["RESTIC_PASSWORD_COMMAND"] == Self.expectedPasswordCommand(Self.primaryId))
        #expect(env["RESTIC_CACHE_DIR"] == Self.paths().resticCacheDir.path)
        // RESTIC_PASSWORD is not one of ours, so it passes through as
        // configured — documented behavior; only the variables we set are
        // protected.
        #expect(env["RESTIC_PASSWORD"] == "pwned")
    }

    @Test("nonSecretEnv can override the fixed PATH (rclone escape hatch)")
    func nonSecretEnvOverridesPath() async throws {
        let destination = Destination(
            id: Self.primaryId,
            label: "Custom PATH",
            repoURL: "rclone:remote:bucket",
            isPrimary: true,
            nonSecretEnv: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        )
        let fake = FakeProcessRunner(script: [
            .init(argvPrefix: [Self.resticPath, "-r", "rclone:remote:bucket", "snapshots", "--json"]),
        ])
        let runner = Self.makeRunner(fake)
        _ = try await runner.run(.snapshots(repo: "rclone:remote:bucket"), for: ResticInvocation(destination: destination))

        let env = try #require(fake.invocations[0].env)
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
    }

    @Test("stored secret env wins over nonSecretEnv for the same destination")
    func secretEnvBeatsNonSecretEnv() async throws {
        let destination = Destination(
            id: Self.primaryId,
            label: "Both",
            repoURL: "/repo",
            isPrimary: true,
            nonSecretEnv: ["AWS_SECRET_ACCESS_KEY": "stale-plaintext"]
        )
        let fake = FakeProcessRunner(script: [
            .init(argvPrefix: [Self.resticPath, "-r", "/repo", "snapshots", "--json"]),
        ])
        let runner = Self.makeRunner(fake, secrets: Self.secretStore(
            for: Self.primaryId,
            secretEnv: ["AWS_SECRET_ACCESS_KEY": "from-the-store"]
        ))
        _ = try await runner.run(.snapshots(repo: "/repo"), for: ResticInvocation(destination: destination))

        let env = try #require(fake.invocations[0].env)
        #expect(env["AWS_SECRET_ACCESS_KEY"] == "from-the-store")
    }

    /// End-to-end env assembly with the *real* file backend, on every
    /// platform: the assembled environment must carry both the password
    /// command and the two variables its child needs to find the same
    /// `secrets.json`. This is the unit-level half of what
    /// `scripts/secret-cli-test.sh` proves against real restic.
    @Test("FileSecretStore: password command plus the env its child needs, and no secret anywhere")
    func fileBackendEnvironmentAssembly() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("restic-station-runner-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileSecretStore(
            paths: AppPaths(root: root),
            helperPath: "/opt/restic-station/restic-station-helper"
        )
        try await store.setPassword(Self.password, destId: Self.primaryId)
        try await store.setSecretEnv(["AWS_SECRET_ACCESS_KEY": "file-backed-secret"], destId: Self.primaryId)

        let fake = FakeProcessRunner(script: [
            .init(argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "snapshots", "--json"]),
        ])
        let runner = ResticRunner(resticPath: Self.resticPath, paths: Self.paths(), secrets: store, runner: fake)
        _ = try await runner.run(
            .snapshots(repo: Self.primary.repoURL),
            for: ResticInvocation(destination: Self.primary)
        )

        let env = try #require(fake.invocations[0].env)
        #expect(
            env["RESTIC_PASSWORD_COMMAND"]
                == "/opt/restic-station/restic-station-helper print-password "
                + "--dest \(Self.primaryId.uuidString.lowercased())"
        )
        #expect(env["RESTIC_STATION_DATA_DIR"] == root.path)
        #expect(env[SecretBackend.environmentKey] == "file")
        // The secret env blob is still injected as real variables…
        #expect(env["AWS_SECRET_ACCESS_KEY"] == "file-backed-secret")
        // …but the repository password reaches restic only through the
        // command, never through the environment or the argv.
        #expect(!env.values.contains(Self.password))
        for element in fake.invocations[0].argv {
            #expect(!element.contains(Self.password))
        }
    }

    @Test("runWithoutRepository (version probe): no secret reads, no password env")
    func versionProbeNeedsNoDestination() async throws {
        let fake = FakeProcessRunner(script: [
            .init(
                argvPrefix: [Self.resticPath, "version", "--json"],
                stdoutLines: [try FixtureLoader.string("version.json").trimmingCharacters(in: .whitespacesAndNewlines)]
            ),
        ])
        let runner = Self.makeRunner(fake)

        let outcome = try await runner.runWithoutRepository(.version)
        #expect(outcome.status == .success)
        #expect(fake.invocations.count == 1)
        #expect(fake.invocations[0].argv == [Self.resticPath, "version", "--json"])

        let env = try #require(fake.invocations[0].env)
        #expect(env["RESTIC_PASSWORD_COMMAND"] == nil)
        #expect(env["RESTIC_CACHE_DIR"] == Self.paths().resticCacheDir.path)
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    // MARK: - Secret-store pre-flight

    @Test("pre-flight failure throws secretsUnavailable and never spawns restic")
    func secretPreflightFailure() async throws {
        let fake = FakeProcessRunner()
        let secrets = FakeSecretStore(defaultPassword: Self.password)
        secrets.failPassword(for: Self.primaryId)
        let runner = Self.makeRunner(fake, secrets: secrets)

        await #expect(throws: ResticRunnerError.secretsUnavailable(destinationId: Self.primaryId)) {
            _ = try await runner.run(
                .backup(repo: Self.primary.repoURL, sources: ["/Users/user/Documents"]),
                for: ResticInvocation(destination: Self.primary)
            )
        }
        // Nothing was spawned at all: restic never ran.
        #expect(fake.invocations.isEmpty)
    }

    @Test("pre-flight covers the from-destination too")
    func secretPreflightFailureOnFromDestination() async throws {
        let fake = FakeProcessRunner()
        let secrets = FakeSecretStore(defaultPassword: Self.password)
        secrets.failPassword(for: Self.primaryId)
        let runner = Self.makeRunner(fake, secrets: secrets)

        await #expect(throws: ResticRunnerError.secretsUnavailable(destinationId: Self.primaryId)) {
            _ = try await runner.run(
                .copy(toRepo: Self.secondary.repoURL, fromRepo: Self.primary.repoURL),
                for: ResticInvocation(destination: Self.secondary, fromDestination: Self.primary)
            )
        }
        #expect(fake.invocations.isEmpty)
    }

    @Test("an unreadable secret-env blob is also retryable, not a crash")
    func secretEnvFailureIsSecretsUnavailable() async throws {
        let fake = FakeProcessRunner()
        let secrets = FakeSecretStore(defaultPassword: Self.password)
        secrets.failSecretEnv(for: Self.primaryId)
        let runner = Self.makeRunner(fake, secrets: secrets)

        await #expect(throws: ResticRunnerError.secretsUnavailable(destinationId: Self.primaryId)) {
            _ = try await runner.run(.snapshots(repo: "/repo"), for: ResticInvocation(destination: Self.primary))
        }
        #expect(fake.invocations.isEmpty)
    }

    // MARK: - NDJSON streaming

    @Test("streams decoded NDJSON messages and captures raw output")
    func streamsNdjson() async throws {
        let lines = try FixtureLoader.lines("backup.ndjson")
        let fake = FakeProcessRunner(script: [
            .init(
                    argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "backup", "--json"],
                    stdoutLines: lines
            ),
        ])
        let runner = Self.makeRunner(fake)

        let streamed = MessageBox()
        let rawLines = MessageBox()
        let outcome = try await runner.run(
            .backup(repo: Self.primary.repoURL, sources: ["/src"]),
            for: ResticInvocation(destination: Self.primary),
            onLine: { streamed.appendMessage($0) },
            onRawLine: { rawLines.appendRaw($0) }
        )

        let expected = lines.map { ResticMessageDecoder().decodeLine($0) }
        #expect(outcome.messages == expected)
        #expect(streamed.messages == expected)
        #expect(rawLines.raw == lines)
        #expect(outcome.rawOutput == lines.map { $0 + "\n" }.joined())
        #expect(outcome.status == .success)

        guard case .summary(let summary) = try #require(outcome.messages.last) else {
            Issue.record("expected the last message to be a backup summary")
            return
        }
        #expect(summary.snapshotId == "e9ffc5cb64395ad443fd14f432751a9823181224978d6b25bf2af1a99ad367fd")
    }

    @Test("stderr lines reach onRawLine (the run log) but never onLine")
    func stderrGoesToRawLog() async throws {
        let fake = FakeProcessRunner(script: [
            .init(
                    argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "snapshots", "--json"],
                    stdoutLines: ["[]"],
                    stderr: "Fatal: unable to open config file",
                    exitCode: 1
            ),
        ])
        let runner = Self.makeRunner(fake)

        let streamed = MessageBox()
        let rawLines = MessageBox()
        let outcome = try await runner.run(
            .snapshots(repo: Self.primary.repoURL),
            for: ResticInvocation(destination: Self.primary),
            onLine: { streamed.appendMessage($0) },
            onRawLine: { rawLines.appendRaw($0) }
        )

        #expect(rawLines.raw == ["[]", "Fatal: unable to open config file"])
        #expect(streamed.messages.count == 1)
        #expect(outcome.rawOutput == "[]\nFatal: unable to open config file")
        #expect(outcome.status == .fatal(stderrSummary: "Fatal: unable to open config file"))
    }

    // MARK: - Exit mapping through the runner

    @Test("exit 3 is the incomplete-read warning, not a failure")
    func exitThreeIsWarning() async throws {
        let fake = FakeProcessRunner(script: [
            .init(
                    argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "backup", "--json"],
                    stdoutLines: try FixtureLoader.lines("backup.ndjson"),
                    exitCode: 3
            ),
        ])
        let runner = Self.makeRunner(fake)
        let outcome = try await runner.run(
            .backup(repo: Self.primary.repoURL, sources: ["/src"]),
            for: ResticInvocation(destination: Self.primary)
        )
        #expect(outcome.exitCode == 3)
        #expect(outcome.status == .warningIncompleteRead)
        #expect(outcome.status.category == .warning)
    }

    @Test("exit_error line (locked-error.json) surfaces .repoLocked on exit 11")
    func exitErrorOnElevenSurfacesRepoLocked() async throws {
        let line = try FixtureLoader.string("locked-error.json").trimmingCharacters(in: .whitespacesAndNewlines)
        let fake = FakeProcessRunner(script: [
            .init(
                    argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "backup", "--json"],
                    stdoutLines: [line],
                    exitCode: 11
            ),
        ])
        let runner = Self.makeRunner(fake)
        let outcome = try await runner.run(
            .backup(repo: Self.primary.repoURL, sources: ["/src"]),
            for: ResticInvocation(destination: Self.primary)
        )
        #expect(outcome.exitCode == 11)
        #expect(outcome.status == .repoLocked)
        #expect(outcome.status.category == .retryable)
        guard case .exitError(let code, let message) = try #require(outcome.messages.first) else {
            Issue.record("expected an .exitError message")
            return
        }
        #expect(code == 11)
        #expect(message.contains("already locked"))
    }

    @Test("a streamed exit_error code beats a generic exit status")
    func exitErrorCodeBeatsGenericExitStatus() async throws {
        let line = try FixtureLoader.string("locked-error.json").trimmingCharacters(in: .whitespacesAndNewlines)
        let fake = FakeProcessRunner(script: [
            .init(
                    argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "backup", "--json"],
                    stdoutLines: [line],
                    exitCode: 1
            ),
        ])
        let runner = Self.makeRunner(fake)
        let outcome = try await runner.run(
            .backup(repo: Self.primary.repoURL, sources: ["/src"]),
            for: ResticInvocation(destination: Self.primary)
        )
        #expect(outcome.exitCode == 1)
        #expect(outcome.status == .repoLocked)
    }

    @Test("an exit_error on a successful run does not manufacture a failure")
    func exitZeroStaysSuccess() async throws {
        let line = try FixtureLoader.string("locked-error.json").trimmingCharacters(in: .whitespacesAndNewlines)
        let fake = FakeProcessRunner(script: [
            .init(
                    argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "backup", "--json"],
                    stdoutLines: [line],
                    exitCode: 0
            ),
        ])
        let runner = Self.makeRunner(fake)
        let outcome = try await runner.run(
            .backup(repo: Self.primary.repoURL, sources: ["/src"]),
            for: ResticInvocation(destination: Self.primary)
        )
        #expect(outcome.status == .success)
    }

    @Test("exit 12 maps to wrongPassword using the captured stderr fixture")
    func exitTwelveWrongPassword() async throws {
        let fake = FakeProcessRunner(script: [
            .init(
                    argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "snapshots", "--json"],
                    stderr: try FixtureLoader.string("err-wrongpw.txt"),
                    exitCode: 12
            ),
        ])
        let runner = Self.makeRunner(fake)
        let outcome = try await runner.run(
            .snapshots(repo: Self.primary.repoURL),
            for: ResticInvocation(destination: Self.primary)
        )
        #expect(outcome.status == .wrongPassword)
        #expect(outcome.status.category == .terminal)
    }

    // MARK: - Timeout & cancellation

    @Test("a ProcessRunning timeout becomes ResticRunnerError.timedOut")
    func timeoutIsMapped() async throws {
        let fake = FakeProcessRunner(script: [
            .init(
                    argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "cat", "config"],
                    failure: .timeout
            ),
        ])
        let runner = Self.makeRunner(fake)

        await #expect(throws: ResticRunnerError.timedOut) {
            _ = try await runner.run(
                .catConfig(repo: Self.primary.repoURL),
                for: ResticInvocation(destination: Self.primary),
                timeout: 10
            )
        }
    }

    @Test("a launch failure becomes ResticRunnerError.launchFailed")
    func launchFailureIsMapped() async throws {
        let fake = FakeProcessRunner(script: [
            .init(
                    argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "cat", "config"],
                    failure: .launchFailed("No such file or directory")
            ),
        ])
        let runner = Self.makeRunner(fake)

        await #expect(throws: ResticRunnerError.launchFailed("No such file or directory")) {
            _ = try await runner.run(
                .catConfig(repo: Self.primary.repoURL),
                for: ResticInvocation(destination: Self.primary)
            )
        }
    }

    @Test("cancelling the calling task surfaces CancellationError")
    func cancellationPropagates() async throws {
        let fake = FakeProcessRunner(script: [
            .init(
                    argvPrefix: [Self.resticPath, "-r", Self.primary.repoURL, "backup", "--json"],
                    delay: 30
            ),
        ])
        let runner = Self.makeRunner(fake)

        let task = Task {
            try await runner.run(
                .backup(repo: Self.primary.repoURL, sources: ["/src"]),
                for: ResticInvocation(destination: Self.primary)
            )
        }
        // Let the pre-flight finish and the (slow) restic call start.
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    // MARK: - NDJSON across awkward chunk boundaries (real subprocess)

    /// End-to-end through the production `DefaultProcessRunner`: a shell
    /// writes `backup.ndjson` to the pipe in chunks that deliberately split
    /// mid-line (and immediately before/after a newline), with pauses so the
    /// reader really observes partial lines. The decoded message stream must
    /// be identical to decoding the fixture line by line.
    @Test("NDJSON survives awkward chunk boundaries on the wire")
    func ndjsonChunkBoundaries() async throws {
        let fixture = try FixtureLoader.data("backup.ndjson")
        let bytes = [UInt8](fixture)
        let firstNewline = try #require(bytes.firstIndex(of: UInt8(ascii: "\n")))

        // Awkward on purpose: just before a newline, just after it, mid-line,
        // mid-way through the stream, and two bytes before EOF.
        let boundaries = [firstNewline, firstNewline + 1, firstNewline + 40, bytes.count / 2, bytes.count - 2]
            .filter { $0 > 0 && $0 < bytes.count }
            .sorted()
            .reduce(into: [Int]()) { unique, value in
                if unique.last != value { unique.append(value) }
            }
        #expect(boundaries.count >= 4)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("restic-station-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var start = 0
        var chunkFiles: [String] = []
        for end in boundaries + [bytes.count] where end > start {
            let url = directory.appendingPathComponent("chunk\(chunkFiles.count)")
            try Data(bytes[start..<end]).write(to: url)
            chunkFiles.append(url.path)
            start = end
        }

        // Absolute paths only: the assembled env has no PATH by design.
        let script = chunkFiles
            .map { "/bin/cat \($0)" }
            .joined(separator: "; /bin/sleep 0.05; ")

        let runner = ResticRunner(
            resticPath: "/bin/sh",
            paths: Self.paths(),
            secrets: FakeSecretStore(),
            runner: DefaultProcessRunner()
        )
        let streamed = MessageBox()
        let outcome = try await runner.runWithoutRepository(
            ResticCommand(argv: ["-c", script]),
            onLine: { streamed.appendMessage($0) }
        )

        let expected = try FixtureLoader.lines("backup.ndjson").map { ResticMessageDecoder().decodeLine($0) }
        #expect(outcome.exitCode == 0)
        #expect(streamed.messages == expected)
        #expect(outcome.messages == expected)
        #expect(outcome.rawOutput == String(decoding: fixture, as: UTF8.self))
        #expect(!expected.contains { if case .unparsed = $0 { return true } else { return false } })
    }
}

// MARK: - Test support

/// Thread-safe collector for the `@Sendable` streaming callbacks.
private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [ResticMessage] = []
    private var _raw: [String] = []

    var messages: [ResticMessage] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }

    var raw: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _raw
    }

    func appendMessage(_ message: ResticMessage) {
        lock.lock()
        defer { lock.unlock() }
        _messages.append(message)
    }

    func appendRaw(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        _raw.append(line)
    }
}
