import Foundation

// MARK: - Invocation

/// Which destination(s) a `ResticCommand` runs against — the input to env
/// assembly. `fromDestination` is set exactly for the two commands that read
/// a second repository (`copy`, `init --from-repo`).
public struct ResticInvocation: Sendable {
    public let destination: Destination
    public let fromDestination: Destination?

    public init(destination: Destination, fromDestination: Destination? = nil) {
        self.destination = destination
        self.fromDestination = fromDestination
    }
}

// MARK: - Outcome

/// The result of running restic to completion. A nonzero exit is *not* an
/// error here — it is reported as ``status`` so callers (engine, probes) can
/// apply the taxonomy in `docs/architecture.md`.
public struct ResticOutcome: Sendable {
    public let exitCode: Int32
    public let status: ResticExitClass
    /// Every stdout line, decoded by ``ResticMessageDecoder`` in arrival
    /// order. Lines from non-JSON commands (`copy`, `check`, `unlock`,
    /// `mount`, `cat config`) decode to `.unparsed`.
    public let messages: [ResticMessage]
    /// Captured stdout followed by captured stderr, verbatim. Written to the
    /// run log; contains restic's own output only — never env values.
    public let rawOutput: String

    public init(exitCode: Int32, status: ResticExitClass, messages: [ResticMessage], rawOutput: String) {
        self.exitCode = exitCode
        self.status = status
        self.messages = messages
        self.rawOutput = rawOutput
    }
}

// MARK: - ResticRunner

/// The single place restic is executed. Builds the environment, performs the
/// secret-store pre-flight, streams NDJSON, and maps exit codes.
///
/// **Environment (docs/restic-cli.md §General).** The inherited environment
/// is *replaced*, never extended: a scheduled launchd invocation and a
/// manual one must produce byte-identical env. Assembly order (later writes
/// win):
///
/// 1. minimal base — `HOME`, `USER`, `TMPDIR` passed through when present
///    (restic and `security` need them), plus a fixed system `PATH`
///    (`/usr/bin:/bin:/usr/sbin:/sbin`): restic's `sftp:` backend locates
///    `ssh` via PATH lookup. Every program *we* spawn is named absolutely;
///    the PATH exists solely for restic's own children, and a destination's
///    `nonSecretEnv` may override it (e.g. to reach a Homebrew `rclone`).
/// 2. from-destination's `nonSecretEnv`, then its stored secret-env blob
/// 3. destination's `nonSecretEnv`, then its stored secret-env blob —
///    **so on a key collision the destination (the `-r` repo) wins over the
///    from-repo.** Two S3 destinations in one set needing *different*
///    credentials is a known v1 limitation (restic-cli.md §init secondary).
///    Within one destination the stored blob wins over `nonSecretEnv`, so
///    a non-secret config entry can never shadow a stored credential.
/// 4. `RESTIC_CACHE_DIR`, the secret store's own
///    `passwordCommandEnvironment` (empty on the keychain backend),
///    `RESTIC_PASSWORD_COMMAND` and (when a from-destination is present)
///    `RESTIC_FROM_PASSWORD_COMMAND` — written last so no user-supplied
///    `nonSecretEnv` entry can hijack how restic obtains a password or where
///    it caches.
///
/// **Secrets.** Passwords never appear in argv (`ResticCommand` guarantees
/// this) and are never logged: the pre-flight read is discarded, and no env
/// value is ever placed in an error or log line.
///
/// **Cancellation.** Cancelling the calling `Task` sends SIGINT to restic,
/// waits 10 s, then SIGKILL (implemented in `DefaultProcessRunner`), and
/// surfaces as `CancellationError`. SIGINT is the right signal: restic
/// installs a handler that removes the repository lock it holds before
/// exiting, so a cancelled run does not leave a stale lock behind.
public final class ResticRunner: Sendable {
    /// Env keys copied from the parent process, in restic-cli.md's order.
    static let passThroughEnvKeys = ["HOME", "USER", "TMPDIR"]

    private let resticPath: String
    private let paths: AppPaths
    private let secrets: any SecretStore
    private let runner: ProcessRunning
    private let decoder = ResticMessageDecoder()

    public init(resticPath: String, paths: AppPaths, secrets: any SecretStore, runner: ProcessRunning) {
        self.resticPath = resticPath
        self.paths = paths
        self.secrets = secrets
        self.runner = runner
    }

    // MARK: - Running

    /// Runs `cmd` against `inv`'s destination(s).
    ///
    /// - Parameters:
    ///   - onLine: each decoded stdout line, as it arrives.
    ///   - onRawLine: each raw stdout **and** stderr line, as it arrives
    ///     (the run log's input).
    ///   - timeout: wall-clock limit; on expiry restic is SIGINT'd (then
    ///     SIGKILL'd after 10 s) and ``ResticRunnerError/timedOut`` is thrown.
    /// - Throws: ``ResticRunnerError`` for failures that produced no outcome,
    ///   or `CancellationError` if the calling task was cancelled.
    @discardableResult
    public func run(
        _ cmd: ResticCommand,
        for inv: ResticInvocation,
        onLine: (@Sendable (ResticMessage) -> Void)? = nil,
        onRawLine: (@Sendable (String) -> Void)? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ResticOutcome {
        try Task.checkCancellation()

        // Pre-flight: read every password we are about to make restic read,
        // so an unreadable secret store (a locked keychain, a secrets file
        // with the wrong mode) is a clean, retryable error instead of a
        // confusing restic failure mid-run (T09 scenario 9). The values are
        // discarded immediately — only reachability is being tested.
        try await preflightSecrets(destination: inv.destination)
        if let fromDestination = inv.fromDestination {
            try await preflightSecrets(destination: fromDestination)
        }

        let env = try await environment(for: inv)
        return try await execute(cmd, env: env, onLine: onLine, onRawLine: onRawLine, timeout: timeout)
    }

    /// Runs a command that targets no repository — currently only
    /// `.version`, used to validate a discovered restic binary before any
    /// destination exists. No secret-store pre-flight, no password env.
    @discardableResult
    public func runWithoutRepository(
        _ cmd: ResticCommand,
        onLine: (@Sendable (ResticMessage) -> Void)? = nil,
        onRawLine: (@Sendable (String) -> Void)? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ResticOutcome {
        precondition(
            cmd.repoURL == nil,
            "runWithoutRepository requires a command with no repository; use run(_:for:) instead"
        )
        try Task.checkCancellation()
        return try await execute(cmd, env: baseEnvironment(), onLine: onLine, onRawLine: onRawLine, timeout: timeout)
    }

    /// Which secret backend this runner reads passwords from.
    ///
    /// Exposed so collaborators that only hold a `ResticRunner` — notably
    /// `Reachability` — can word a secret-store failure for the store
    /// actually in use rather than for the host OS.
    public var secretBackend: SecretBackend {
        secrets.backend
    }

    // MARK: - Secret-store pre-flight

    private func preflightSecrets(destination: Destination) async throws {
        do {
            _ = try await secrets.password(destId: destination.id)
        } catch {
            // The underlying backend failure text is intentionally dropped
            // here rather than wrapped: it is of no use to the user and this
            // error string ends up in run logs. What is *not* dropped is
            // which of the two conditions it was — collapsing "the store
            // could not be read" into "nothing is stored" is what made a
            // permanently missing password look retryable to every caller
            // downstream of here.
            throw Self.runnerError(for: error, destination: destination)
        }
    }

    /// Which pre-flight failure a secret-store error is, with the backend's
    /// own text discarded either way.
    private static func runnerError(for error: any Error, destination: Destination) -> ResticRunnerError {
        if case SecretStoreError.itemNotFound = error {
            return .secretsNotConfigured(destinationId: destination.id)
        }
        return .secretsUnavailable(destinationId: destination.id)
    }

    // MARK: - Environment

    /// See the type documentation for the ordering rules this implements.
    func environment(for inv: ResticInvocation) async throws -> [String: String] {
        var env = baseEnvironment()

        if let fromDestination = inv.fromDestination {
            env.merge(fromDestination.nonSecretEnv) { _, new in new }
            env.merge(try await secretEnv(for: fromDestination)) { _, new in new }
        }
        env.merge(inv.destination.nonSecretEnv) { _, new in new }
        env.merge(try await secretEnv(for: inv.destination)) { _, new in new }

        // Written last: these must not be overridable by configured env.
        env["RESTIC_CACHE_DIR"] = paths.resticCacheDir.path
        // What the password command's child needs to find the same store —
        // empty for the keychain backend, so macOS's assembled environment is
        // exactly what it was before T23. See
        // `SecretStore.passwordCommandEnvironment`.
        env.merge(secrets.passwordCommandEnvironment) { _, new in new }
        env["RESTIC_PASSWORD_COMMAND"] = secrets.passwordCommand(destId: inv.destination.id)
        if let fromDestination = inv.fromDestination {
            env["RESTIC_FROM_PASSWORD_COMMAND"] = secrets.passwordCommand(destId: fromDestination.id)
        }
        return env
    }

    private func secretEnv(for destination: Destination) async throws -> [String: String] {
        do {
            return try await secrets.secretEnv(destId: destination.id)
        } catch {
            // Same reasoning as the pre-flight: a secret store that cannot be
            // read is retryable, one with nothing in it is not, and the raw
            // failure text never propagates either way.
            throw Self.runnerError(for: error, destination: destination)
        }
    }

    private func baseEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        let inherited = ProcessInfo.processInfo.environment
        for key in Self.passThroughEnvKeys {
            if let value = inherited[key] {
                env[key] = value
            }
        }
        // Fixed, not inherited: restic's sftp backend execs `ssh` via PATH.
        // Merged before nonSecretEnv, so destinations can override it.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["RESTIC_CACHE_DIR"] = paths.resticCacheDir.path
        return env
    }

    // MARK: - Execution

    private func execute(
        _ cmd: ResticCommand,
        env: [String: String],
        onLine: (@Sendable (ResticMessage) -> Void)?,
        onRawLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?
    ) async throws -> ResticOutcome {
        let argv = [resticPath] + cmd.argv
        let collector = MessageCollector()
        let decoder = self.decoder

        let result: ProcessResult
        do {
            result = try await runner.run(
                argv,
                env: env,
                currentDirectory: nil,
                onStdoutLine: { line in
                    onRawLine?(line)
                    let message = decoder.decodeLine(line)
                    collector.append(message)
                    onLine?(message)
                },
                onStderrLine: { line in
                    onRawLine?(line)
                },
                timeout: timeout
            )
        } catch let error as ProcessRunnerError {
            switch error {
            case .timeout:
                throw ResticRunnerError.timedOut
            case .launchFailed(let reason):
                throw ResticRunnerError.launchFailed(reason)
            case .invalidArgv:
                throw ResticRunnerError.launchFailed("empty argv")
            }
        }

        let messages = collector.messages
        let stdoutText = String(decoding: result.stdout, as: UTF8.self)
        let stderrText = String(decoding: result.stderr, as: UTF8.self)
        return ResticOutcome(
            exitCode: result.exitCode,
            status: Self.status(exitCode: result.exitCode, messages: messages, stderr: stderrText),
            messages: messages,
            rawOutput: stdoutText + stderrText
        )
    }

    /// Classifies a finished run.
    ///
    /// In `--json` mode restic reports fatal errors as an `exit_error` NDJSON
    /// line on stdout carrying its own code (restic-cli.md §JSON-mode
    /// errors; fixture `locked-error.json` has code 11). That code is the
    /// precise one — the process exit status is sometimes the generic 1 — so
    /// when the run failed and an `exit_error` was streamed, the message's
    /// code and text drive the classification.
    static func status(exitCode: Int32, messages: [ResticMessage], stderr: String) -> ResticExitClass {
        guard exitCode != 0 else {
            return .success
        }
        let exitErrors = messages.compactMap { message -> (code: Int, message: String)? in
            guard case .exitError(let code, let text) = message else { return nil }
            return (code, text)
        }
        if let last = exitErrors.last, last.code != 0 {
            let detail = last.message.isEmpty ? stderr : last.message
            return .classify(exitCode: Int32(clamping: last.code), stderr: detail)
        }
        return .classify(exitCode: exitCode, stderr: stderr)
    }
}

// MARK: - MessageCollector

/// Accumulates decoded messages from the `@Sendable` stdout callback, which
/// runs on `DefaultProcessRunner`'s reader queue.
private final class MessageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [ResticMessage] = []

    var messages: [ResticMessage] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }

    func append(_ message: ResticMessage) {
        lock.lock()
        defer { lock.unlock() }
        _messages.append(message)
    }
}
