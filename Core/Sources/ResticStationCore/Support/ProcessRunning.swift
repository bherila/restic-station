import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The result of running a subprocess to completion.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    /// Whether everything written to either pipe before the reader stopped
    /// was read (#150). True at end-of-file, and true when the bounded drain
    /// after the child's exit stopped with the pipe empty: a descendant holding
    /// the write end idly (`ssh` ControlPersist) cut nothing. False when data
    /// was still arriving after a bounded final read (a descendant writing),
    /// or a read failed. `stdout`/`stderr` are then a prefix, and nothing in
    /// them shows where it was cut.
    public let outputComplete: Bool

    public init(exitCode: Int32, stdout: Data, stderr: Data, outputComplete: Bool = true) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.outputComplete = outputComplete
    }
}

/// Errors thrown by a `ProcessRunning` implementation.
public enum ProcessRunnerError: Error, Sendable, Equatable {
    /// `argv` was empty; there is nothing to execute.
    case invalidArgv
    /// The subprocess could not be launched (e.g. executable not found).
    case launchFailed(String)
    /// `timeout` elapsed before the process exited. The runner has already
    /// sent SIGINT (and SIGKILL after a 10s grace period) by the time this
    /// is thrown.
    case timeout
}

/// Whether a child may make the system download an online-only ("dataless")
/// file by reading it (#156): a file a cloud provider such as iCloud Drive
/// has evicted to a placeholder.
///
/// On macOS this is the child's `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`
/// policy, enforced by the kernel for the child's whole life. Elsewhere
/// there are no dataless files and it has no effect.
public enum DatalessFileReads: Sendable, Equatable {
    /// Reading one downloads it first.
    case download
    /// Reading one fails instead of downloading it.
    case refuse
}

/// Abstraction over subprocess execution. No code in `ResticStationCore`
/// calls `Process` directly — everything goes through this protocol so
/// tests can inject a fake (see `docs/testing.md` §FakeProcessRunner).
public protocol ProcessRunning: Sendable {
    /// Runs argv[0] with argv[1...], replacing (not inheriting) the environment
    /// when `env` is non-nil. `onStdoutLine` receives each complete
    /// newline-terminated line as it arrives (for NDJSON streaming).
    /// Throws ProcessRunnerError.timeout after sending SIGINT (then SIGKILL
    /// after a 10 s grace period) if `timeout` elapses.
    ///
    /// The deadline races process *termination*, never pipe EOF: a child that
    /// closes stdout and stderr but keeps running must still be stopped
    /// (#114).
    ///
    /// Once the child is gone — or has been told to go and did not — the
    /// readers get a bounded grace and are then told to stop. That bound is
    /// unconditional, including on the success path: a descendant which
    /// inherited the pipe ends (`ssh` with `ControlPersist` outlives its
    /// client by design) would otherwise hold the call open for its own
    /// lifetime, and where the deadline never fired the call would come back
    /// a descendant's lifetime late reporting *success*. A run is still
    /// waited on for as long as its own child runs; only the drain after
    /// that is bounded. A stopped reader first takes whatever is already in
    /// the pipe, and ``ProcessResult/outputComplete`` says whether anything
    /// written before the stop was left unread (#150).
    ///
    /// Both readers run to completion before `run` returns, so no
    /// `onStdoutLine` or `onStderrLine` callback can fire after it — callers
    /// close per-run log writers on that return.
    ///
    /// Cancelling the calling task stops the subprocess the same way (SIGINT,
    /// 10 s grace, SIGKILL) and throws `CancellationError`.
    func run(
        _ argv: [String],
        env: [String: String]?,
        stdin: Data?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?
    ) async throws -> ProcessResult

    /// ``run(_:env:stdin:currentDirectory:onStdoutLine:onStderrLine:timeout:)``
    /// with the child's ``DatalessFileReads`` policy decided by the caller.
    /// nil means the child inherits this process's policy.
    func run(
        _ argv: [String],
        env: [String: String]?,
        stdin: Data?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?,
        datalessFiles: DatalessFileReads?
    ) async throws -> ProcessResult
}

public extension ProcessRunning {
    /// For runners that spawn nothing real (test doubles): the policy has
    /// nothing to apply to. ``DefaultProcessRunner`` implements it.
    func run(
        _ argv: [String],
        env: [String: String]?,
        stdin: Data?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?,
        datalessFiles: DatalessFileReads?
    ) async throws -> ProcessResult {
        try await run(
            argv,
            env: env,
            stdin: stdin,
            currentDirectory: currentDirectory,
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine,
            timeout: timeout
        )
    }

    /// Convenience for the overwhelmingly common no-stdin subprocess.
    func run(
        _ argv: [String],
        env: [String: String]?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?
    ) async throws -> ProcessResult {
        try await run(
            argv,
            env: env,
            stdin: nil,
            currentDirectory: currentDirectory,
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine,
            timeout: timeout
        )
    }
}

/// Production `ProcessRunning` implementation. Spawns with `posix_spawn` and
/// reaps the child itself (`OwnedProcess`, #114): the child leads its own
/// process group, so the stop sequence reaches its descendants, and owning
/// the reap is what proves a pid is still ours when a signal is sent.
/// `ProcessLease.descriptors` are handed to the child so a set lock outlives
/// a helper that dies mid-run.
public struct DefaultProcessRunner: ProcessRunning {
    /// How long SIGINT is given to work before SIGKILL (`terminationGrace`,
    /// the documented 10 s), and how long a run keeps waiting for termination
    /// and for its pipes once the child is gone or has been told to go
    /// (`drainGrace`, also 10 s).
    ///
    /// They are settable only so tests can assert the stop sequence in
    /// seconds rather than half a minute. The sequence is four waits deep in
    /// the worst case — deadline, SIGINT grace, termination bound, drain
    /// grace — so at production values a single assertion costs 30 s+, and a
    /// bound loose enough to survive that is too loose to distinguish "the
    /// deadline was enforced" from "the child was waited out".
    let terminationGrace: TimeInterval
    let drainGrace: TimeInterval

    public init() {
        self.init(terminationGrace: 10, drainGrace: 10)
    }

    init(terminationGrace: TimeInterval, drainGrace: TimeInterval) {
        self.terminationGrace = terminationGrace
        self.drainGrace = drainGrace
        // Install before anything can spawn, rather than lazily inside the
        // call that also spawns. `static let` initialization is thread-safe,
        // but doing it at first use leaves one window where a thread is
        // inside `posix_spawn` — which reads the process's signal
        // dispositions — while another installs the handler. Nothing is known
        // to have gone wrong there, but the ordering is free.
        SIGPIPEGuard.ensureInstalled()
    }

    /// Spawn attempts before giving up (#116).
    ///
    /// `posix_spawn` intermittently fails with `EFAULT` under concurrent
    /// spawn load — a spurious failure, not a real bad address, since the
    /// same argv succeeds on the next attempt. It is safe to retry precisely
    /// because it is a *launch* failure: POSIX guarantees no child exists
    /// when `posix_spawn` reports an error, so a retry cannot double-spawn.
    /// That matters here, because some of what this runner launches is
    /// destructive.
    private static let spawnAttempts = 3

    private static func spawnWithRetry(
        argv: [String],
        env: [String: String]?,
        datalessFiles: DatalessFileReads?,
        terminationSignal: TerminationSignal
    ) throws -> OwnedProcess {
        var lastError: Error?
        for attempt in 1...spawnAttempts {
            do {
                SIGPIPEGuard.ensureInstalled()
                // Duplicated atomically with respect to every release, and
                // owned here until the spawn has made its own copies.
                let leases = try ProcessLeases.shared.duplicates()
                defer { OwnedProcess.closeAll(leases) }
                return try OwnedProcess.spawn(argv: argv, env: env, inherit: leases, datalessFiles: datalessFiles) {
                    terminationSignal.fire()
                }
            } catch {
                lastError = error
                guard attempt < spawnAttempts, isTransientSpawnFailure(error) else {
                    throw error
                }
            }
        }
        throw lastError ?? ProcessRunnerError.launchFailed("spawn failed with no reported error")
    }

    /// A spawn failure that says nothing about the command and everything
    /// about the moment it was attempted. `EFAULT` is #116's signature;
    /// `EAGAIN` is the ordinary "out of process slots right now".
    static func isTransientSpawnFailure(_ error: Error) -> Bool {
        if let failure = error as? SpawnFailure {
            return failure.errnoValue == EFAULT || failure.errnoValue == EAGAIN
        }
        guard let code = spawnErrno(of: error) else { return false }
        return code == EFAULT || code == EAGAIN
    }

    /// The errno behind a spawn failure, however this platform's Foundation
    /// chose to wrap it.
    ///
    /// Darwin throws `NSPOSIXErrorDomain` directly. swift-corelibs-foundation
    /// does not: `Process.run()` reports the failure through
    /// `_NSErrorWithErrno`, which yields `NSCocoaErrorDomain` /
    /// `fileReadUnknown` and carries the errno only under
    /// `NSUnderlyingErrorKey`. Matching the POSIX domain alone made this
    /// retry dead code on every Linux host — which is precisely where the
    /// production argument for retrying applies, since that is what runs
    /// unattended.
    ///
    /// The Linux errno is also the less trustworthy of the two: corelibs
    /// passes the global `errno`, while `posix_spawn` returns its error
    /// without setting `errno`. That can only cause a retry of something
    /// that was never going to work, which costs two further attempts and
    /// returns the same error. It cannot make a retry *unsafe*: that rests
    /// on no child existing when a spawn reports failure, not on which
    /// errno was reported.
    private static func spawnErrno(of error: Error) -> Int32? {
        let reported = error as NSError
        if reported.domain == NSPOSIXErrorDomain {
            return Int32(reported.code)
        }
        guard let underlying = reported.userInfo[NSUnderlyingErrorKey] as? NSError,
              underlying.domain == NSPOSIXErrorDomain else {
            return nil
        }
        return Int32(underlying.code)
    }

    public func run(
        _ argv: [String],
        env: [String: String]?,
        stdin: Data?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?
    ) async throws -> ProcessResult {
        try await run(
            argv,
            env: env,
            stdin: stdin,
            currentDirectory: currentDirectory,
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine,
            timeout: timeout,
            datalessFiles: nil
        )
    }

    public func run(
        _ argv: [String],
        env: [String: String]?,
        stdin: Data?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?,
        datalessFiles: DatalessFileReads?
    ) async throws -> ProcessResult {
        guard !argv.isEmpty else {
            throw ProcessRunnerError.invalidArgv
        }

        // Termination is observed via `terminationHandler` (delivered on an
        // internal Foundation queue), NEVER `waitUntilExit()`: waitUntilExit
        // delivers through the spawning thread's runloop, and Swift
        // concurrency cooperative threads don't run one — the notification
        // can be lost and the wait then hangs forever with a zombie child.
        // Observed in practice (T19): a hung helper holds its flocks until
        // killed, silently stopping all scheduled backups. The handler MUST
        // be installed before `run()` so a fast-exiting child can't race it.
        let terminationSignal = TerminationSignal()

        // No caller sets a working directory, and `posix_spawn`'s chdir
        // action is not portable to every libc this ships against; refusing
        // beats silently running somewhere else.
        guard currentDirectory == nil else {
            throw ProcessRunnerError.launchFailed("a working directory is not supported")
        }
        let process: OwnedProcess
        do {
            process = try Self.spawnWithRetry(
                argv: argv,
                env: env,
                datalessFiles: datalessFiles,
                terminationSignal: terminationSignal
            )
        } catch let error as ProcessRunnerError {
            throw error
        } catch {
            throw ProcessRunnerError.launchFailed(String(describing: error))
        }
        // Plain `Task`s (not `async let`) so they can be captured by the
        // nested task-group closure below.
        //
        // These start BEFORE the stdin write. The write below is synchronous
        // and blocks once the stdin pipe buffer fills, so a child that writes
        // its own output before draining stdin would deadlock against readers
        // that had not started yet. Today's only stdin payload is a password,
        // far under the buffer, but the ordering costs nothing and removes
        // the whole failure class.
        // Shared with both readers so a timed-out or cancelled run can end
        // them rather than abandon them; see `readPipeToCompletion`.
        let readerStop = AtomicFlag()
        let stdoutTask = Task {
            await Self.readPipeToCompletion(process.stdoutRead, onLine: onStdoutLine, stop: readerStop)
        }
        let stderrTask = Task {
            await Self.readPipeToCompletion(process.stderrRead, onLine: onStderrLine, stop: readerStop)
        }

        if let stdin {
            // A child that has already closed its stdin (a fast-failing
            // `ssh`: BatchMode, rejected key) makes this write fail with
            // `EPIPE` rather than kill the helper — `SIGPIPEGuard` — and the
            // early exit then surfaces as the child's real exit status.
            Self.writeAll(stdin, to: process.stdinWrite)
        }
        close(process.stdinWrite)

        let timeoutFlag = TimeoutFlag()
        let cancellationFlag = AtomicFlag()

        // Task cancellation is handled with the same stop sequence as a
        // timeout (SIGINT, 10 s grace, SIGKILL). SIGINT rather than SIGTERM
        // because restic installs a SIGINT handler that removes the
        // repository lock it holds before exiting — a cancelled run must not
        // leave a stale lock behind.
        let (outData, errData) = await withTaskCancellationHandler {
            // The deadline races *process termination*, never pipe EOF. A
            // child that closes stdout and stderr but keeps running hands the
            // readers EOF immediately; racing them therefore cancelled the
            // deadline at that instant and left the runner waiting on the
            // live child forever — holding the set lock, and finally
            // reporting the run as a success with no timeout at all (#114).
            //
            // Deliberately sequential rather than a task group. Every wait
            // below is bounded once we have decided to stop the child, and a
            // group cannot offer that: it awaits all of its children, and the
            // termination wait is a `withCheckedContinuation` that
            // `cancelAll()` cannot unpark. See `TerminationSignal`.
            if let timeout {
                await terminationSignal.wait(upTo: max(0, timeout))
                // `!cancellationFlag.isSet` because that wait can also be
                // ended by the cancellation handler releasing its waiters,
                // not only by the deadline. Without it a cancelled run would
                // run a second, redundant stop sequence here — another
                // SIGINT, another full grace — behind the one cancellation
                // already started, and would flag itself as timed out on the
                // way past. `CancellationError` still wins the classification
                // below either way; this keeps the run from paying for a
                // stop sequence twice.
                if !terminationSignal.hasFired && !cancellationFlag.isSet {
                    await timeoutFlag.trigger()
                    await Self.stopAfterGracePeriod(
                        process,
                        terminated: terminationSignal,
                        grace: terminationGrace
                    )
                    // A child that has now survived both SIGINT and SIGKILL
                    // is not going to be waited into submission, and the
                    // caller is holding a lock. Give up on a bound rather
                    // than trade a reported deadline for a real hang.
                    await terminationSignal.wait(upTo: drainGrace)
                }
            } else {
                // No deadline was asked for, so there is none to enforce: a
                // legitimate multi-hour backup must not be abandoned. It is
                // still released if the caller cancels — see
                // `releaseWaiters`, armed by the cancellation handler — so
                // "no deadline" never means "no way out once we have decided
                // to stop".
                await terminationSignal.wait()
            }

            // Once the direct child is gone, any writer still holding the
            // inherited pipe ends is a descendant (`ssh` for the sftp
            // backend, a password command), and waiting for *their* EOF is
            // unbounded. That is true on the success path too, which is why
            // this is armed unconditionally rather than only after a stop
            // sequence: an `ssh` master with `ControlPersist` outlives the
            // child by design. Bounded only from here, so a run still waits
            // as long as its own child runs.
            //
            // Measured before this was unconditional: a child exiting at once
            // while a descendant held the pipes returned 15.02 s later — and
            // on the success path returned *success*, with the deadline it
            // had been given never raised at all.
            //
            // Awaiting both readers to completion is what keeps every
            // `onLine` callback strictly inside the call. Callers close the
            // run's `LogWriter` on this return, so a reader still delivering
            // lines afterwards would be racing that close.
            let stopper = Task.detached {
                try await Task.sleep(nanoseconds: UInt64(drainGrace * 1_000_000_000))
                readerStop.set()
            }
            defer { stopper.cancel() }
            let collected = (await stdoutTask.value, await stderrTask.value)
            OwnedProcess.closeAll([process.stdoutRead, process.stderrRead])
            return collected
        } onCancel: {
            cancellationFlag.set()
            // Synchronous part first so the signal lands immediately; the
            // grace period + SIGKILL run detached (this closure cannot await).
            process.signalGroup(SIGINT)
            Task.detached {
                await Self.stopAfterGracePeriod(
                    process,
                    terminated: terminationSignal,
                    grace: terminationGrace,
                    sendInitialInterrupt: false
                )
                // The run may be parked in the unbounded wait used when no
                // deadline was requested — which every real backup, forget
                // and prune uses. Cancelling is a stop decision like any
                // other, so the same bound applies from here: SIGINT and
                // SIGKILL have both been spent, and a child that survived
                // them will not be waited into submission while the caller
                // holds the set lock.
                await terminationSignal.wait(upTo: drainGrace)
                terminationSignal.releaseWaiters()
            }
        }

        if cancellationFlag.isSet {
            throw CancellationError()
        }
        if await timeoutFlag.triggered {
            throw ProcessRunnerError.timeout
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: outData.data,
            stderr: errData.data,
            outputComplete: outData.complete && errData.complete
        )
    }

    /// Writes all of `data`, giving up quietly on any error other than
    /// `EINTR` — a child that stopped reading is reported through its exit
    /// status, not here.
    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    /// SIGINT (optional — already sent by the cancellation handler), then up
    /// to 10 s of grace, then SIGKILL.
    ///
    /// The grace is a wall-clock deadline, not a count of nominal sleeps: a
    /// loaded cooperative pool stretches each 100 ms sleep, and summing the
    /// requested durations would then escalate to SIGKILL long before ten
    /// real seconds of grace had passed.
    private static func stopAfterGracePeriod(
        _ process: OwnedProcess,
        terminated: TerminationSignal,
        grace: TimeInterval,
        sendInitialInterrupt: Bool = true
    ) async {
        if sendInitialInterrupt {
            process.signalGroup(SIGINT)
        }
        // `ContinuousClock`, not `Date`: this is an elapsed-duration bound,
        // and a wall clock stepped backwards by NTP would extend the grace
        // past the deadline the caller was promised, while a forward step
        // would swallow most of it.
        let graceEnds = ContinuousClock.now.advanced(by: .seconds(grace))
        while !terminated.hasFired && ContinuousClock.now < graceEnds {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                // Cancelled — which means the caller's cancellation handler
                // has already started its *own* stop sequence, with a full
                // SIGINT grace, on a task nothing cancels. Returning leaves
                // that one to finish. Escalating here instead would fire
                // SIGKILL immediately, cutting short the grace restic needs
                // to remove its repository lock, which is the whole reason
                // the sequence starts with SIGINT.
                return
            }
        }
        process.signalGroup(SIGKILL)
    }

    /// Reads a pipe on a background dispatch queue (never blocks the Swift
    /// concurrency cooperative thread pool), streaming complete lines to
    /// `onLine` as they arrive and buffering any trailing partial line to
    /// flush once at the end. Returns the raw accumulated bytes.
    ///
    /// The wait is a short `poll(2)` rather than a blocking read, so `stop`
    /// can end the loop even on a pipe that will never reach EOF — a
    /// descendant that inherited the write ends can hold them open for as
    /// long as it likes. Being interruptible is what lets a timed-out or
    /// cancelled `run` bound its drain *and still* have both readers finish:
    /// abandoning them instead would leak the task, its continuation and the
    /// descriptors, and would let `onLine` keep firing after `run` had
    /// already thrown — into, for the engine's callers, a `LogWriter` the
    /// same return path has just closed.
    /// How much a stopped reader takes from a pipe that is still filling
    /// before it gives up and reports the transcript incomplete. Several pipe
    /// buffers' worth: the child's own unread output is at most one.
    private static let finalDrainLimit = 1024 * 1024

    static func readPipeToCompletion(
        _ fd: Int32,
        onLine: (@Sendable (String) -> Void)?,
        stop: AtomicFlag,
        finalDrainLimit: Int = finalDrainLimit
    ) async -> (data: Data, complete: Bool) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(data: Data, complete: Bool), Never>) in
            DispatchQueue.global(qos: .utility).async {
                var accumulated = Data()
                var lineBuffer = Data()
                let newline = UInt8(ascii: "\n")
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                var reachedEOF = false

                reading: while !stop.isSet {
                    var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&poller, 1, 200)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        break reading
                    }
                    // Timed out with nothing readable: the only purpose of
                    // the timeout is to get back here and re-check `stop`.
                    if ready == 0 { continue }

                    let count = buffer.withUnsafeMutableBytes { raw -> Int in
                        read(fd, raw.baseAddress, raw.count)
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        break reading
                    }
                    if count == 0 { // EOF
                        reachedEOF = true
                        break reading
                    }

                    let chunk = Data(buffer[0..<count])
                    accumulated.append(chunk)
                    lineBuffer.append(chunk)

                    while let newlineIndex = lineBuffer.firstIndex(of: newline) {
                        let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                        onLine?(String(decoding: lineData, as: UTF8.self))
                        lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
                    }
                }

                // Told to stop before EOF: a descendant still holds the write
                // end. Whatever is already in the pipe is taken now, without
                // waiting. Everything the child wrote before it exited is
                // there or already read. A pipe that is then empty means
                // nothing was cut: an idle holder (`ssh` ControlPersist) is
                // not a truncation. Data still arriving after a bounded extra
                // read means a descendant is writing, and the transcript
                // cannot be told complete (#150).
                var complete = reachedEOF
                if !reachedEOF && stop.isSet {
                    var extra = 0
                    final: while true {
                        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        let ready = poll(&poller, 1, 0)
                        if ready < 0 {
                            if errno == EINTR { continue }
                            break final
                        }
                        if ready == 0 {
                            complete = true
                            break final
                        }
                        // Read before judging the budget: a pipe that hits
                        // end-of-file just as the budget runs out was read
                        // completely, and only a read that returns data
                        // after the budget is spent proves a writer is
                        // still going (Codex on #175).
                        let count = buffer.withUnsafeMutableBytes { raw -> Int in
                            read(fd, raw.baseAddress, raw.count)
                        }
                        if count < 0 {
                            if errno == EINTR { continue }
                            break final
                        }
                        if count == 0 {
                            complete = true
                            break final
                        }
                        let overBudget = extra >= finalDrainLimit
                        extra += count
                        let chunk = Data(buffer[0..<count])
                        accumulated.append(chunk)
                        lineBuffer.append(chunk)
                        while let newlineIndex = lineBuffer.firstIndex(of: newline) {
                            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                            onLine?(String(decoding: lineData, as: UTF8.self))
                            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
                        }
                        if overBudget { break final }
                    }
                }

                if !lineBuffer.isEmpty {
                    onLine?(String(decoding: lineBuffer, as: UTF8.self))
                }

                continuation.resume(returning: (accumulated, complete))
            }
        }
    }
}

/// Records — synchronously, from `withTaskCancellationHandler`'s handler —
/// that the calling task was cancelled. Cannot be an `actor`: the handler is
/// a non-async closure.
/// A one-way boolean, safe to set from one concurrency domain and read from
/// another. Used both for "the caller cancelled" and for "stop reading the
/// pipes now".
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}

/// One-shot latching signal bridging `Process.terminationHandler` (fired on
/// a Foundation-internal queue) to async/await. `fire()` may happen before,
/// during, or after a wait; every waiter resumes exactly once.
///
/// `wait(upTo:)` exists because **no wait for a child may be unbounded once
/// we have decided to stop it**. `withCheckedContinuation` cannot be
/// cancelled, so a waiter parked on a child that outlives its stop sequence
/// stays parked. Previously that waiter was one arm of a task group, and a
/// task group awaits *all* of its children — so `cancelAll()` could not free
/// it and the whole group blocked until the child exited on its own. The
/// deadline was reported on time and the call still did not return: on the
/// `linux` CI job, `.timeout` was thrown at 2 s and `run` returned at
/// 45.003 s, the child's full natural lifetime, with the set lock held
/// throughout. macOS never showed it, because there SIGKILL lands and the
/// waiter is freed a few seconds in.
final class TerminationSignal: @unchecked Sendable {
    /// Holds one parked continuation and guarantees a single resume,
    /// whichever of `fire()` or an expiring bound gets there first.
    ///
    /// It also owns that bound's sleeper, so an early termination cancels it
    /// rather than leaving it to run out. Without that, every bounded wait
    /// outlives its own subprocess by the whole configured timeout — up to
    /// ten minutes on the longer query paths — and a long-lived app doing
    /// frequent short probes accumulates one abandoned task and waiter per
    /// call.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var bound: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        /// Hands over the sleeper enforcing this waiter's bound. Cancels it
        /// immediately if the wait is already over — the resume can win the
        /// race against the task even being created.
        func attach(_ task: Task<Void, Never>) {
            lock.lock()
            let alreadyResumed = continuation == nil
            if !alreadyResumed {
                bound = task
            }
            lock.unlock()
            if alreadyResumed {
                task.cancel()
            }
        }

        func resumeOnce() {
            lock.lock()
            let pending = continuation
            continuation = nil
            let sleeper = bound
            bound = nil
            lock.unlock()
            sleeper?.cancel()
            pending?.resume()
        }
    }

    private let lock = NSLock()
    private var fired = false
    /// Sticky, and deliberately separate from `fired`: cancellation releases
    /// waiters without anyone concluding the child terminated.
    private var released = false
    private var waiters: [Waiter] = []

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func fire() {
        lock.lock()
        fired = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resumeOnce()
        }
    }

    /// Resumes everyone waiting **without** claiming the child has
    /// terminated: `hasFired` stays false, so the stop sequence keeps
    /// refusing to signal a child it believes is gone and no caller reads
    /// `terminationStatus` off the back of it.
    ///
    /// Used only by the cancellation path, to release a run parked in the
    /// unbounded `wait()` that a no-deadline call uses.
    func releaseWaiters() {
        lock.lock()
        released = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resumeOnce()
        }
    }

    /// Waits for termination with no bound. Correct only where the caller has
    /// asked for no deadline and is content to wait as long as the child runs.
    func wait() async {
        await wait(upTo: nil)
    }

    /// Waits for termination, giving up after `seconds` if it has not
    /// happened. Returning does **not** imply the child is gone — callers on
    /// this path are already failing the run and must not read
    /// `terminationStatus`.
    func wait(upTo seconds: TimeInterval?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = Waiter(continuation)
            lock.lock()
            // `released` is checked here, not just drained in
            // `releaseWaiters`, because the release can land *before* the
            // waiter exists. An already-cancelled task runs its cancellation
            // handler before the operation body, so the detached stop task
            // can reach `releaseWaiters` while there is nothing to drain —
            // and the wait registered afterwards would then park forever,
            // recreating the very hang the release was added to prevent.
            if fired || released {
                lock.unlock()
                waiter.resumeOnce()
                return
            }
            waiters.append(waiter)
            lock.unlock()
            guard let seconds else { return }
            // Cancelled by `resumeOnce` the moment the wait ends, so a child
            // that exits in milliseconds does not leave this running for the
            // rest of the timeout. An expired waiter stays in `waiters` until
            // `fire()` drains it, which is at most a couple of entries for
            // one child.
            waiter.attach(Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                waiter.resumeOnce()
            })
        }
    }
}

/// Tiny actor used to record, from a concurrently-running timeout task,
/// that the deadline elapsed — independent of which of the two racing
/// tasks (natural exit vs. timeout) happens to be observed first.
private actor TimeoutFlag {
    private(set) var triggered = false

    func trigger() {
        triggered = true
    }
}

/// Keeps a broken pipe from killing this process, without changing what any
/// child inherits.
///
/// Installed **once**, permanently, as a no-op *handler* — deliberately not
/// `SIG_IGN`. POSIX resets signals "set to be caught" to the default action on
/// `exec`, while it preserves an *ignored* disposition. So a handler protects
/// this process and every child still dies on a broken pipe exactly as before,
/// with no window to serialize and no lock to contend on.
///
/// Both halves rest on deterministic experiments, not inference:
///
/// - A permanent `SIG_IGN` **does** leak. Linux CI failed
///   `childrenKeepTheDefaultSIGPIPEDisposition` against it — the child printed
///   `survived` and exited 0 — because swift-corelibs-foundation does not
///   reset child dispositions, though macOS's Foundation does, which hides it
///   locally.
/// - A no-op handler does **not** leak: with one installed, a spawned
///   `kill -PIPE $$; echo survived` still exits with signal 13 and prints
///   nothing, while a write to a closed pipe in this process throws `EPIPE`
///   instead of dying.
/// - `pthread_sigmask` around the write is not sufficient on its own; that was
///   tried first and the process still died.
enum SIGPIPEGuard {
    /// `Void` static: the runtime guarantees exactly one initialization,
    /// whichever thread gets there first.
    private static let installed: Void = {
        _ = signal(SIGPIPE, { _ in })
    }()

    /// Forces installation at a deterministic point, before any subprocess
    /// work begins.
    static func ensureInstalled() {
        _ = installed
    }

    static func withIgnored<T>(_ body: () -> T) -> T {
        _ = installed
        return body()
    }

}
