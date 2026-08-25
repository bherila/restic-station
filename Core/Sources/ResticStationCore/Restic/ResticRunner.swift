import Foundation

// MARK: - Invocation

/// Which destination(s) a `ResticCommand` runs against — the input to env
/// assembly. `fromDestination` is set exactly for the two commands that read
/// a second repository (`copy`, `init --from-repo`).
public struct ResticInvocation: Sendable {
    public let destination: Destination
    public let fromDestination: Destination?
    /// A caller-supplied secret-env snapshot. Destructive preview/confirm
    /// flows use this to ensure the environment they validate is exactly the
    /// one passed to restic; ordinary invocations read the current store value.
    public let destinationSecretEnv: [String: String]?
    /// A helper-validated, canonical restic executable for a destructive
    /// preview/confirmation. Normal calls leave this nil and use the runner's
    /// configured path unchanged.
    public let resticPathOverride: String?
    /// Opaque digest binding for a helper-confirmed maintenance executable.
    /// The runner rechecks it immediately before the child is spawned.
    public let expectedExecutableIdentity: String?

    public init(
        destination: Destination,
        fromDestination: Destination? = nil,
        destinationSecretEnv: [String: String]? = nil,
        resticPathOverride: String? = nil,
        expectedExecutableIdentity: String? = nil
    ) {
        self.destination = destination
        self.fromDestination = fromDestination
        self.destinationSecretEnv = destinationSecretEnv
        self.resticPathOverride = resticPathOverride
        self.expectedExecutableIdentity = expectedExecutableIdentity
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

    public struct MaintenanceExecutable: Equatable, Sendable {
        public let path: String
        public let identity: String
    }

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
        timeout: TimeInterval? = nil,
        beforeLaunch: (@Sendable () throws -> Void)? = nil,
        auditBeforeLaunch: (@Sendable () throws -> Void)? = nil,
        afterLaunchFailure: (@Sendable () -> Void)? = nil
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
        return try await execute(
            cmd,
            env: env,
            executablePath: inv.resticPathOverride,
            expectedExecutableIdentity: inv.expectedExecutableIdentity,
            beforeLaunch: beforeLaunch,
            auditBeforeLaunch: auditBeforeLaunch,
            afterLaunchFailure: afterLaunchFailure,
            onLine: onLine,
            onRawLine: onRawLine,
            timeout: timeout
        )
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

    /// Runs an ssh-wrapped maintenance command. The destination password is
    /// delivered solely on the local ssh process stdin; it is never present
    /// in argv or environment.
    public func runRemoteMaintenance(
        _ command: RemoteResticCommand,
        destination: Destination,
        onRawLine: (@Sendable (String) -> Void)? = nil,
        beforeLaunch: (@Sendable () throws -> Void)? = nil,
        auditBeforeLaunch: (@Sendable () throws -> Void)? = nil,
        afterLaunchFailure: (@Sendable () -> Void)? = nil
    ) async throws -> ResticOutcome {
        let password: String
        do { password = try await secrets.password(destId: destination.id) }
        catch { throw Self.runnerError(for: error, destination: destination) }
        let command = command.withPassword(password)
        let collector = MessageCollector()
        let result: ProcessResult
        do {
            // Match the local destructive-command invariant: consume a
            // confirmation only after the password is available and directly
            // before Process receives the SSH argv.
            try beforeLaunch?()
            do {
                try auditBeforeLaunch?()
            } catch {
                // A capability may have been consumed, but no process has
                // received argv yet. Restore it on this pre-spawn audit
                // failure just as on Process.run() launch failure.
                afterLaunchFailure?()
                throw error
            }
            result = try await runner.run(command.argv, env: nil, stdin: command.password, currentDirectory: nil, onStdoutLine: { line in
                onRawLine?(line); let message = self.decoder.decodeLine(line); collector.append(message)
                // No wall-clock timeout on purpose: a legitimate prune on a
                // large repository runs for hours, and killing it partway is
                // worse than waiting. A *dead* session is bounded instead by
                // ssh's ServerAlive keepalive in `RemoteResticCommand`, which
                // distinguishes "slow" from "gone" — a timeout here cannot.
            }, onStderrLine: { line in onRawLine?(line) }, timeout: nil)
        } catch let error as ProcessRunnerError {
            if case .launchFailed = error {
                afterLaunchFailure?()
            }
            switch error { case .timeout: throw ResticRunnerError.timedOut; case .invalidArgv, .launchFailed: throw ResticRunnerError.launchFailed("remote maintenance ssh could not be launched") }
        }
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        return ResticOutcome(exitCode: result.exitCode, status: Self.status(exitCode: result.exitCode, messages: collector.messages, stderr: stderr), messages: collector.messages, rawOutput: stdout + stderr)
    }

    public func verifyRemoteMaintenance(_ command: RemoteResticCommand) async throws -> VersionInfo {
        let result: ProcessResult
        do { result = try await runner.run(command.argv, env: nil, stdin: nil, currentDirectory: nil, onStdoutLine: nil, onStderrLine: nil, timeout: 20) }
        catch { throw ResticRunnerError.launchFailed("remote maintenance SSH could not be launched") }
        guard result.exitCode == 0, let info = try? parseVersion(result.stdout), info.meetsMinimum("0.17.0") else {
            // An unpinned host key is the one failure here with a specific,
            // actionable remedy, and it is invisible in the generic message.
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            if stderr.contains("Host key verification failed")
                || stderr.contains("No RSA host key is known")
                || stderr.contains("no matching host key") {
                throw ResticRunnerError.launchFailed(
                    "the maintenance host's SSH key is not known. Connect to it once with ssh to "
                        + "verify and record the key, then retry."
                )
            }
            throw ResticRunnerError.launchFailed("remote restic is unavailable or below version 0.17")
        }
        return info
    }

    /// Which secret backend this runner reads passwords from.
    ///
    /// Exposed so collaborators that only hold a `ResticRunner` — notably
    /// `Reachability` — can word a secret-store failure for the store
    /// actually in use rather than for the host OS.
    public var secretBackend: SecretBackend {
        secrets.backend
    }

    /// A stable identity for the executable that will receive a destructive
    /// maintenance command.  The resolved path catches symlink changes and
    /// the content digest catches an in-place replacement at the same path.
    /// It is intentionally an opaque input to the helper's preview binding,
    /// never emitted in a report or run log.
    public func maintenanceExecutable() -> MaintenanceExecutable? {
        maintenanceExecutable(path: resticPath)
    }

    /// The identity as of *right now*, hashed rather than recalled. Used
    /// only where the answer authorizes a destructive launch; see
    /// ``ExecutableIdentityCache``.
    func revalidatedMaintenanceExecutable(path: String) -> MaintenanceExecutable? {
        maintenanceExecutable(path: path, bypassingCache: true)
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
        let destinationSecretEnv: [String: String]
        if let supplied = inv.destinationSecretEnv {
            destinationSecretEnv = supplied
        } else {
            destinationSecretEnv = try await secretEnv(for: inv.destination)
        }
        env.merge(destinationSecretEnv) { _, new in new }

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
        executablePath: String? = nil,
        expectedExecutableIdentity: String? = nil,
        beforeLaunch: (@Sendable () throws -> Void)? = nil,
        auditBeforeLaunch: (@Sendable () throws -> Void)? = nil,
        afterLaunchFailure: (@Sendable () -> Void)? = nil,
        onLine: (@Sendable (ResticMessage) -> Void)?,
        onRawLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?
    ) async throws -> ResticOutcome {
        let resolvedExecutablePath = executablePath ?? resticPath
        // `revalidated…`, not the cached accessor: the whole point of this
        // check is that the bytes on disk may have changed since the
        // preview, and a metadata-keyed cache cannot see an in-place
        // overwrite that preserves size and mtime.
        if let expectedExecutableIdentity,
           revalidatedMaintenanceExecutable(path: resolvedExecutablePath)?.identity != expectedExecutableIdentity {
            throw ResticRunnerError.launchFailed("the restic executable changed after the maintenance preview")
        }
        // Destructive preview tokens are consumed here, after every launch
        // prerequisite has passed but immediately before the process runner
        // receives the argv. A failed secret read or executable revalidation
        // must leave confirmation retryable.
        try beforeLaunch?()
        do {
            try auditBeforeLaunch?()
        } catch {
            afterLaunchFailure?()
            throw error
        }
        let argv = [resolvedExecutablePath] + cmd.argv
        let collector = MessageCollector()
        let decoder = self.decoder

        let result: ProcessResult
        do {
            result = try await runner.run(
                argv,
                env: env,
                stdin: nil,
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
            // `DefaultProcessRunner` emits `.launchFailed` only from
            // `Process.run()`, before a child exists. Destructive callers
            // may therefore safely restore their just-consumed capability.
            if case .launchFailed = error {
                afterLaunchFailure?()
            }
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

    /// Digesting the restic binary is not cheap — it is ~28 MB, and
    /// `SHA256Digest` is a dependency-free Swift implementation, so a single
    /// call costs about 10s in a debug build and is far from free in a
    /// release one. A purge preview and apply ask for the identity several
    /// times each, which turned one engine test from 0.3s into 40s.
    ///
    /// Cached per process, keyed by the file's identity *and* its mutable
    /// metadata, so an in-place replacement invalidates the entry. This does
    /// not weaken the binding it feeds: preview and confirmation run in
    /// **different** helper processes, so the cross-process check that
    /// actually guards the destructive operation still re-reads and re-hashes
    /// the file.
    private static let executableCache = ExecutableIdentityCache()

    private func maintenanceExecutable(path: String, bypassingCache: Bool = false) -> MaintenanceExecutable? {
        guard path.hasPrefix("/") else { return nil }
        let executable = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return Self.executableCache.identity(for: executable, bypassingCache: bypassingCache)
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

/// Process-local memo for ``ResticRunner/MaintenanceExecutable``.
///
/// The cache key includes device, inode, size and mtime, so *most* ways of
/// replacing the binary miss the cache and are re-hashed.
///
/// **Metadata is not a substitute for the bytes, and this cache must never
/// be trusted to enforce a pin.** An in-place overwrite that keeps the same
/// inode, writes the same number of bytes and restores the original mtime —
/// exactly what an updater preserving timestamps does — produces an
/// unchanged key and returns the *previous* digest. The launch-time
/// revalidation would then compare a stale identity to itself and let the
/// replacement receive the destructive command, defeating the pin it exists
/// to enforce. So every revalidation passes `bypassingCache: true` and
/// hashes the file (#109 exact-head review).
///
/// The cache still does its job — `335e33d` added it so a multi-step purge
/// does not re-hash restic on every step — because only the comparatively
/// rare destructive *launch* pays for a fresh hash.
final class ExecutableIdentityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: ResticRunner.MaintenanceExecutable] = [:]

    func identity(for executable: URL, bypassingCache: Bool = false) -> ResticRunner.MaintenanceExecutable? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path) else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let key = "\(executable.path)|\(device)|\(inode)|\(size)|\(modified)"

        if !bypassingCache {
            lock.lock()
            let cached = entries[key]
            lock.unlock()
            if let cached { return cached }
        }

        guard let data = try? Data(contentsOf: executable) else { return nil }
        let value = ResticRunner.MaintenanceExecutable(
            path: executable.path,
            identity: "\(executable.path):\(SHA256Digest.hex(data))"
        )
        lock.lock()
        entries[key] = value
        lock.unlock()
        return value
    }
}
