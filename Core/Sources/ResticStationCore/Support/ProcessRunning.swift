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

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
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
    /// that is bounded, and a transcript cut short by it fails a downstream
    /// parse closed rather than reading as an empty success.
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
}

public extension ProcessRunning {
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

/// Production `ProcessRunning` implementation backed by `Foundation.Process`
/// and `Pipe`. Portable: relies only on `Process`/`Pipe`/`FileHandle` (which
/// work on Linux via swift-corelibs-foundation) plus `kill(2)` for signaling,
/// imported from `Darwin` or `Glibc` depending on platform.
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

    private static func withSIGPIPEIgnored<T>(_ body: () -> T) -> T {
        SIGPIPEGuard.withIgnored(body)
    }

    private static func launch(_ process: Process) throws {
        try SIGPIPEGuard.launch(process)
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
        guard !argv.isEmpty else {
            throw ProcessRunnerError.invalidArgv
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        if let env {
            process.environment = env
        }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        // Termination is observed via `terminationHandler` (delivered on an
        // internal Foundation queue), NEVER `waitUntilExit()`: waitUntilExit
        // delivers through the spawning thread's runloop, and Swift
        // concurrency cooperative threads don't run one — the notification
        // can be lost and the wait then hangs forever with a zombie child.
        // Observed in practice (T19): a hung helper holds its flocks until
        // killed, silently stopping all scheduled backups. The handler MUST
        // be installed before `run()` so a fast-exiting child can't race it.
        let terminationSignal = TerminationSignal()
        process.terminationHandler = { _ in
            terminationSignal.fire()
        }

        do {
            // Under the same lock as the SIGPIPE window, so no child is ever
            // created while that signal is ignored and inherits it.
            try Self.launch(process)
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
            await Self.readPipeToCompletion(stdoutPipe, onLine: onStdoutLine, stop: readerStop)
        }
        let stderrTask = Task {
            await Self.readPipeToCompletion(stderrPipe, onLine: onStderrLine, stop: readerStop)
        }

        if let stdin {
            // `write(contentsOf:)`, never `write(_:)`: the latter raises an
            // uncatchable ObjC exception when the child has already closed
            // its stdin, which for a fast-failing `ssh` (BatchMode, rejected
            // key) is a live race against the password write. With SIGPIPE
            // ignored, an early exit now surfaces as the child's real exit
            // status instead of killing the helper mid-operation.
            Self.withSIGPIPEIgnored {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
            }
        }
        try? stdinPipe.fileHandleForWriting.close()

        let timeoutFlag = TimeoutFlag()
        let cancellationFlag = AtomicFlag()
        let processBox = ProcessBox(process: process)

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
                if !terminationSignal.hasFired {
                    await timeoutFlag.trigger()
                    await Self.stopAfterGracePeriod(
                        processBox,
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
            return (await stdoutTask.value, await stderrTask.value)
        } onCancel: {
            cancellationFlag.set()
            // Synchronous part first so the signal lands immediately; the
            // grace period + SIGKILL run detached (this closure cannot await).
            Self.sendSignal(SIGINT, to: processBox, unlessTerminated: terminationSignal)
            Task.detached {
                await Self.stopAfterGracePeriod(
                    processBox,
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

        return ProcessResult(exitCode: process.terminationStatus, stdout: outData, stderr: errData)
    }

    /// SIGINT (optional — already sent by the cancellation handler), then up
    /// to 10 s of grace, then SIGKILL.
    ///
    /// The grace is a wall-clock deadline, not a count of nominal sleeps: a
    /// loaded cooperative pool stretches each 100 ms sleep, and summing the
    /// requested durations would then escalate to SIGKILL long before ten
    /// real seconds of grace had passed.
    private static func stopAfterGracePeriod(
        _ box: ProcessBox,
        terminated: TerminationSignal,
        grace: TimeInterval,
        sendInitialInterrupt: Bool = true
    ) async {
        if sendInitialInterrupt {
            sendSignal(SIGINT, to: box, unlessTerminated: terminated)
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
        sendSignal(SIGKILL, to: box, unlessTerminated: terminated)
    }

    /// Signals the child unless it is already known to have terminated.
    ///
    /// The liveness guard is **our own** termination latch, never
    /// `Process.isRunning`. Foundation's flag is bookkeeping we have already
    /// learned not to trust on Linux — the same distrust that makes this file
    /// observe exit through `terminationHandler` and never `waitUntilExit()`.
    /// A guard that wrongly reads "not running" silently swallows both SIGINT
    /// and SIGKILL, which leaves the deadline enforced in name only: `run`
    /// throws `.timeout` on schedule while the child keeps going and the
    /// caller keeps holding the set lock.
    ///
    /// A latch that has not fired means Foundation has not reaped the child,
    /// so the pid is still ours and cannot have been reused. Signalling a
    /// not-yet-reaped zombie is harmless.
    private static func sendSignal(
        _ signal: Int32,
        to box: ProcessBox,
        unlessTerminated terminated: TerminationSignal
    ) {
        guard !terminated.hasFired else { return }
        kill(box.process.processIdentifier, signal)
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
    private static func readPipeToCompletion(
        _ pipe: Pipe,
        onLine: (@Sendable (String) -> Void)?,
        stop: AtomicFlag
    ) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let box = PipeBox(pipe: pipe)
            DispatchQueue.global(qos: .utility).async {
                let fd = box.pipe.fileHandleForReading.fileDescriptor
                var accumulated = Data()
                var lineBuffer = Data()
                let newline = UInt8(ascii: "\n")
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)

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
                    if count == 0 { break reading } // EOF

                    let chunk = Data(buffer[0..<count])
                    accumulated.append(chunk)
                    lineBuffer.append(chunk)

                    while let newlineIndex = lineBuffer.firstIndex(of: newline) {
                        let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                        onLine?(String(decoding: lineData, as: UTF8.self))
                        lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
                    }
                }

                if !lineBuffer.isEmpty {
                    onLine?(String(decoding: lineBuffer, as: UTF8.self))
                }

                continuation.resume(returning: accumulated)
            }
        }
    }
}

private struct PipeBox: @unchecked Sendable {
    let pipe: Pipe
}

/// Same reasoning as `PipeBox`: `Process` is not `Sendable`, but the only
/// member touched across concurrency domains here is `processIdentifier`,
/// which is safe to read from the cancellation handler while the launching
/// task awaits the process. Liveness is deliberately *not* read from
/// `Process` — see `sendSignal(_:to:unlessTerminated:)`.
private struct ProcessBox: @unchecked Sendable {
    let process: Process
}

/// Records — synchronously, from `withTaskCancellationHandler`'s handler —
/// that the calling task was cancelled. Cannot be an `actor`: the handler is
/// a non-async closure.
/// A one-way boolean, safe to set from one concurrency domain and read from
/// another. Used both for "the caller cancelled" and for "stop reading the
/// pipes now".
private final class AtomicFlag: @unchecked Sendable {
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
private final class TerminationSignal: @unchecked Sendable {
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
            if fired {
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

    static func launch(_ process: Process) throws {
        _ = installed
        try process.run()
    }
}
