import Foundation
import Testing
@testable import ResticStationCore

/// The load-bearing test double for `ProcessRunning` (see `docs/testing.md`
/// §FakeProcessRunner). Every argv-producing type under test (KeychainClient
/// now; ResticRunner, Reachability, BackupEngine later) is driven through
/// this fake instead of a real subprocess.
///
/// Scripted `Expectation`s are consumed in order; each `run(...)` call pops
/// the next one, asserts the recorded argv starts with `argvPrefix`, and
/// replays the scripted stdout/stderr/exit code (streaming stdout lines to
/// `onStdoutLine` and the stderr string to `onStderrLine` as it would in
/// production).
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Expectation {
        let argvPrefix: [String]
        let stdoutLines: [String]
        let stderr: String
        let exitCode: Int32
        let delay: TimeInterval?
        /// When set, `run(...)` throws this instead of returning a result —
        /// how tests reach the `ProcessRunnerError.timeout` / `.launchFailed`
        /// paths that a scripted exit code cannot express.
        let failure: ProcessRunnerError?

        init(
            argvPrefix: [String],
            stdoutLines: [String] = [],
            stderr: String = "",
            exitCode: Int32 = 0,
            delay: TimeInterval? = nil,
            failure: ProcessRunnerError? = nil
        ) {
            self.argvPrefix = argvPrefix
            self.stdoutLines = stdoutLines
            self.stderr = stderr
            self.exitCode = exitCode
            self.delay = delay
            self.failure = failure
        }
    }

    private let lock = NSLock()
    private var _script: [Expectation]
    private var _invocations: [(argv: [String], env: [String: String]?, stdin: Data?)] = []

    init(script: [Expectation] = []) {
        self._script = script
    }

    var script: [Expectation] {
        get { withLock { _script } }
        set { withLock { _script = newValue } }
    }

    private(set) var invocations: [(argv: [String], env: [String: String]?, stdin: Data?)] {
        get { withLock { _invocations } }
        set { withLock { _invocations = newValue } }
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
        withLock { _invocations.append((argv, env, stdin)) }

        guard let expectation = withLock({ () -> Expectation? in
            guard !_script.isEmpty else { return nil }
            return _script.removeFirst()
        }) else {
            Issue.record("FakeProcessRunner: no more scripted expectations, but got argv \(argv)")
            throw ProcessRunnerError.launchFailed("FakeProcessRunner: unscripted call")
        }

        guard argv.starts(with: expectation.argvPrefix) else {
            Issue.record(
                "FakeProcessRunner: argv \(argv) does not start with expected prefix \(expectation.argvPrefix)"
            )
            throw ProcessRunnerError.launchFailed("FakeProcessRunner: argv mismatch")
        }

        if let delay = expectation.delay {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if let failure = expectation.failure {
            throw failure
        }

        var stdoutData = Data()
        for line in expectation.stdoutLines {
            onStdoutLine?(line)
            stdoutData.append(Data((line + "\n").utf8))
        }
        if !expectation.stderr.isEmpty {
            onStderrLine?(expectation.stderr)
        }
        let stderrData = Data(expectation.stderr.utf8)

        return ProcessResult(exitCode: expectation.exitCode, stdout: stdoutData, stderr: stderrData)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
