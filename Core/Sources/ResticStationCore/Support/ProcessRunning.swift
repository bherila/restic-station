import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
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
    /// Cancelling the calling task stops the subprocess the same way (SIGINT,
    /// 10 s grace, SIGKILL) and throws `CancellationError`.
    func run(
        _ argv: [String],
        env: [String: String]?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?
    ) async throws -> ProcessResult
}

/// Production `ProcessRunning` implementation backed by `Foundation.Process`
/// and `Pipe`. Portable: relies only on `Process`/`Pipe`/`FileHandle` (which
/// work on Linux via swift-corelibs-foundation) plus `kill(2)` for signaling,
/// imported from `Darwin` or `Glibc` depending on platform.
public struct DefaultProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        _ argv: [String],
        env: [String: String]?,
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
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(String(describing: error))
        }

        // Plain `Task`s (not `async let`) so they can be captured by the
        // nested task-group closure below.
        let stdoutTask = Task { await Self.readPipeToCompletion(stdoutPipe, onLine: onStdoutLine) }
        let stderrTask = Task { await Self.readPipeToCompletion(stderrPipe, onLine: onStderrLine) }

        let timeoutFlag = TimeoutFlag()
        let cancellationFlag = CancellationFlag()
        let processBox = ProcessBox(process: process)

        // Task cancellation is handled with the same stop sequence as a
        // timeout (SIGINT, 10 s grace, SIGKILL). SIGINT rather than SIGTERM
        // because restic installs a SIGINT handler that removes the
        // repository lock it holds before exiting — a cancelled run must not
        // leave a stale lock behind.
        let (outData, errData) = await withTaskCancellationHandler {
            if let timeout {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        _ = await stdoutTask.value
                        _ = await stderrTask.value
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

            let out = await stdoutTask.value
            let err = await stderrTask.value
            process.waitUntilExit()
            return (out, err)
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

/// Tiny actor used to record, from a concurrently-running timeout task,
/// that the deadline elapsed — independent of which of the two racing
/// tasks (natural exit vs. timeout) happens to be observed first.
private actor TimeoutFlag {
    private(set) var triggered = false

    func trigger() {
        triggered = true
    }
}
