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
    /// (#114). Once the stop sequence has run, the transcript is drained for
    /// a bounded grace and then abandoned, because a descendant that
    /// inherited the pipe ends can hold them open indefinitely. Neither
    /// transcript is readable on that path — `run` throws instead of
    /// returning a `ProcessResult`.
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
    public init() {
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
        let stdoutTask = Task { await Self.readPipeToCompletion(stdoutPipe, onLine: onStdoutLine) }
        let stderrTask = Task { await Self.readPipeToCompletion(stderrPipe, onLine: onStderrLine) }

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
        let cancellationFlag = CancellationFlag()
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
            if let timeout {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await terminationSignal.wait()
                    }
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                        } catch {
                            // Cancelled: the process already exited before the
                            // deadline, or the caller cancelled (handled by
                            // the cancellation handler below).
                            return
                        }
                        await timeoutFlag.trigger()
                        await Self.stopAfterGracePeriod(processBox)
                    }
                    await group.next()
                    group.cancelAll()
                }
            }
            await terminationSignal.wait()

            let timedOut = await timeoutFlag.triggered
            guard timedOut || cancellationFlag.isCancelled else {
                return (await stdoutTask.value, await stderrTask.value)
            }
            // The stop sequence has run, so the direct child is gone and any
            // writer still holding the inherited pipe ends is a descendant
            // (`ssh` for the sftp backend, a password command). Waiting for
            // *their* EOF is unbounded and would make the deadline
            // unenforceable again by a second route. This path throws below,
            // so the transcript is discarded either way.
            return await Self.drainWithinGrace(stdoutTask, stderrTask)
        } onCancel: {
            cancellationFlag.mark()
            // Synchronous part first so the signal lands immediately; the
            // grace period + SIGKILL run detached (this closure cannot await).
            Self.sendSignal(SIGINT, to: processBox.process)
            Task.detached {
                await Self.stopAfterGracePeriod(processBox, sendInitialInterrupt: false)
            }
        }

        if cancellationFlag.isCancelled {
            throw CancellationError()
        }
        if await timeoutFlag.triggered {
            throw ProcessRunnerError.timeout
        }

        return ProcessResult(exitCode: process.terminationStatus, stdout: outData, stderr: errData)
    }

    /// SIGINT (optional — already sent by the cancellation handler), then up
    /// to 10 s of grace, then SIGKILL.
    private static func stopAfterGracePeriod(_ box: ProcessBox, sendInitialInterrupt: Bool = true) async {
        if sendInitialInterrupt {
            sendSignal(SIGINT, to: box.process)
        }
        var waited: TimeInterval = 0
        while box.process.isRunning && waited < 10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        if box.process.isRunning {
            sendSignal(SIGKILL, to: box.process)
        }
    }

    /// How long a timed-out or cancelled run keeps draining its pipes after
    /// the direct child is gone. Bytes already buffered in a 64 KiB pipe
    /// drain in microseconds, so this is generous by orders of magnitude for
    /// anything but a descendant that is still holding the write ends open.
    private static let postStopDrainGrace: TimeInterval = 10

    /// Awaits both pipe readers for at most `postStopDrainGrace`, returning
    /// empty transcripts if that grace expires.
    ///
    /// Only ever called on a path that is about to throw. Empty rather than
    /// partial is not a choice: `readPipeToCompletion` accumulates into a
    /// local buffer and publishes it once at EOF, so there is no partial
    /// buffer to hand back, and `run()` throws before any caller could read
    /// one.
    ///
    /// Deliberately not a task group: a group awaits *all* of its children,
    /// and awaiting `Task<Data, Never>.value` ignores cancellation, so the
    /// losing arm would hold the group open for exactly as long as the wait
    /// this bound exists to cut short. The loser here is detached and simply
    /// completes later, when the descendant finally closes the pipe.
    private static func drainWithinGrace(
        _ stdoutTask: Task<Data, Never>,
        _ stderrTask: Task<Data, Never>
    ) async -> (Data, Data) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Data, Data), Never>) in
            let resumer = OnceResumer(continuation)
            Task.detached {
                let out = await stdoutTask.value
                let err = await stderrTask.value
                resumer.resume(with: (out, err))
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(postStopDrainGrace * 1_000_000_000))
                resumer.resume(with: (Data(), Data()))
            }
        }
    }

    private static func sendSignal(_ signal: Int32, to process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, signal)
    }

    /// Reads a pipe to EOF on a background dispatch queue (never blocks the
    /// Swift concurrency cooperative thread pool), streaming complete lines
    /// to `onLine` as they arrive and buffering any trailing partial line to
    /// flush once at EOF. Returns the raw accumulated bytes.
    private static func readPipeToCompletion(
        _ pipe: Pipe,
        onLine: (@Sendable (String) -> Void)?
    ) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let box = PipeBox(pipe: pipe)
            DispatchQueue.global(qos: .utility).async {
                let handle = box.pipe.fileHandleForReading
                var accumulated = Data()
                var lineBuffer = Data()
                let newline = UInt8(ascii: "\n")

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        break
                    }
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

/// `Pipe` is not `Sendable`, but it is only ever touched from one thread at
/// a time in `readPipeToCompletion` (handed off once to the background
/// queue and never read from concurrently elsewhere). This box lets us
/// cross the `@Sendable` closure boundary without a data race.
private struct PipeBox: @unchecked Sendable {
    let pipe: Pipe
}

/// Same reasoning as `PipeBox`: `Process` is not `Sendable`, but the only
/// members touched across concurrency domains here are `isRunning`,
/// `processIdentifier` and signal delivery, which are safe to read from the
/// cancellation handler while the launching task awaits the process.
private struct ProcessBox: @unchecked Sendable {
    let process: Process
}

/// Records — synchronously, from `withTaskCancellationHandler`'s handler —
/// that the calling task was cancelled. Cannot be an `actor`: the handler is
/// a non-async closure.
/// Resumes a continuation exactly once, whichever of two racing detached
/// tasks arrives first. The loser's call is a no-op rather than the fatal
/// double-resume it would otherwise be.
private final class OnceResumer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func mark() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}

/// One-shot latching signal bridging `Process.terminationHandler` (fired on
/// a Foundation-internal queue) to async/await. `fire()` may happen before,
/// during, or after `wait()`; every waiter resumes exactly once.
///
/// Multiple waiters are supported deliberately. The deadline races
/// termination inside a task group and the run then awaits termination again
/// outside it, and `withCheckedContinuation` is not cancellable — so the
/// racing waiter can still be parked when the second one arrives. A
/// single-slot continuation would drop the parked one, and the task group,
/// which awaits all of its children, would never return.
private final class TerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let waiters = continuations
        continuations = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                cont.resume()
                return
            }
            continuations.append(cont)
            lock.unlock()
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
