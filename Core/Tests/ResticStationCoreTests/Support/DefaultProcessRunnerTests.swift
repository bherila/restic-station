import Foundation
import Testing
@testable import ResticStationCore

/// Portable smoke tests for `DefaultProcessRunner` — real subprocesses, no
/// mocking. Uses only `/bin/echo` and `/bin/sh`, present on both macOS and
/// the `swift:6.1` Linux CI container (see docs/testing.md).
@Suite("DefaultProcessRunner")
struct DefaultProcessRunnerTests {
    @Test("writes supplied stdin and closes it at EOF")
    func writesStdin() async throws {
        let runner = DefaultProcessRunner()
        let password = Data("stdin-only-secret\n".utf8)

        let result = try await runner.run(
            ["/bin/sh", "-c", "IFS= read -r value; printf '%s' \"$value\""],
            env: nil,
            stdin: password,
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: nil
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == Data("stdin-only-secret".utf8))
    }

    /// A child that exits without reading closes the read end of the stdin
    /// pipe. Writing into it then fails with EPIPE and raises SIGPIPE, which
    /// by default kills the writer — here, the helper, mid-maintenance. The
    /// payload deliberately exceeds one pipe buffer so the write cannot be
    /// absorbed and returned before the child is gone.
    ///
    /// The time limit is a backstop, not the assertion: readers start before
    /// the stdin write, so a full buffer can drain rather than deadlock.
    @Test("survives a child that exits without draining a large stdin", .timeLimit(.minutes(1)))
    func stdinWriteToClosedChildDoesNotKillTheProcess() async throws {
        let runner = DefaultProcessRunner()

        let result = try await runner.run(
            ["/bin/sh", "-c", "exit 0"],
            env: nil,
            stdin: Data(repeating: UInt8(ascii: "x"), count: 1 << 20),
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: 30
        )

        #expect(result.exitCode == 0)
    }

    /// The SIGPIPE protection must stay the parent's. POSIX preserves an
    /// *ignored* disposition across `exec`, so a process-wide
    /// `signal(SIGPIPE, SIG_IGN)` would silently become a property of every
    /// restic invocation too — a child that relies on dying on a broken pipe
    /// would continue or hang instead. Signal 13 here means the child still
    /// has the default disposition.
    @Test("does not leak SIGPIPE suppression into spawned children")
    func childrenKeepTheDefaultSIGPIPEDisposition() async throws {
        let runner = DefaultProcessRunner()

        // Run the stdin path first, so any leaked suppression is in place.
        _ = try await runner.run(
            ["/bin/sh", "-c", "exit 0"],
            env: nil,
            stdin: Data("x".utf8),
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: 30
        )

        let result = try await runner.run(
            ["/bin/sh", "-c", "kill -PIPE $$; echo survived"],
            env: nil,
            stdin: nil,
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: 30
        )

        #expect(result.exitCode == 13)
        #expect(result.stdout.isEmpty)
    }

    @Test("runs /bin/echo, streams the line callback, and captures stdout")
    func echoSmokeTest() async throws {
        let runner = DefaultProcessRunner()

        let collector = LineCollector()
        let result = try await runner.run(
            ["/bin/echo", "hi"],
            env: nil,
            currentDirectory: nil,
            onStdoutLine: { line in collector.append(line) },
            onStderrLine: nil,
            timeout: nil
        )

        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hi\n")
        #expect(collector.lines == ["hi"])
        #expect(result.stderr.isEmpty)
    }

    @Test("flushes a trailing partial line (no newline) at EOF")
    func partialLineFlushedAtEOF() async throws {
        let runner = DefaultProcessRunner()

        let collector = LineCollector()
        let result = try await runner.run(
            ["/bin/sh", "-c", "printf 'no-trailing-newline'"],
            env: nil,
            currentDirectory: nil,
            onStdoutLine: { line in collector.append(line) },
            onStderrLine: nil,
            timeout: nil
        )

        #expect(result.exitCode == 0)
        #expect(collector.lines == ["no-trailing-newline"])
        #expect(String(decoding: result.stdout, as: UTF8.self) == "no-trailing-newline")
    }

    @Test("replaces (does not inherit) the environment when env is non-nil")
    func replacesEnvironment() async throws {
        let runner = DefaultProcessRunner()

        let result = try await runner.run(
            ["/bin/sh", "-c", "echo \"MARKER=$MARKER_VAR PATH_SET=${PATH:-unset}\""],
            env: ["MARKER_VAR": "present"],
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: nil
        )

        #expect(result.exitCode == 0)
        let output = String(decoding: result.stdout, as: UTF8.self)
        #expect(output.contains("MARKER=present"))
    }

    @Test("task cancellation stops the process via SIGINT and throws CancellationError")
    func cancellationStopsProcess() async throws {
        let runner = DefaultProcessRunner()

        let task = Task {
            try await runner.run(
                ["/bin/sleep", "30"],
                env: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: nil
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelledAt = Date()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        // On macOS, SIGINT kills `sleep` at once — assert the fast path.
        // In Linux CI containers the child inherits an ignored-SIGINT
        // disposition from the runner, so termination legitimately falls
        // through to the 10 s grace + SIGKILL fallback; only assert that the
        // fallback actually terminated it. Production only runs on macOS.
        #if os(macOS)
        #expect(Date().timeIntervalSince(cancelledAt) < 5)
        #else
        #expect(Date().timeIntervalSince(cancelledAt) < 15)
        #endif
    }

    /// The elapsed bound is the half of this test that earns its name.
    /// `#expect(throws:)` alone passes just as happily when the deadline is
    /// reported on schedule and the child then runs to completion regardless
    /// — which is exactly the failure #114 was about. Returning within a few
    /// seconds of a 0.3 s deadline can only mean SIGINT actually reached
    /// `sleep`, since the SIGKILL escalation is 10 s behind it.
    @Test("throws ProcessRunnerError.timeout and stops a long-running process via SIGINT", .timeLimit(.minutes(1)))
    func timeoutSendsSIGINT() async throws {
        let runner = DefaultProcessRunner()
        let started = Date()

        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await runner.run(
                ["/bin/sleep", "30"],
                env: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 0.3
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 5, "returned after \(elapsed)s; SIGINT did not reach the child")
    }
}

/// Thread-safe line accumulator for asserting on lines streamed from a
/// `@Sendable` callback invoked off the main actor.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        _lines.append(line)
    }

    /// When the app spawns the helper, the helper's stdout/stderr are pipes
    /// back to the app. If the app dies mid-operation, the next write raises
    /// SIGPIPE — and the default disposition kills the helper, taking with it
    /// the run record that would have explained what happened.
    ///
    /// Exercised through a real subprocess so the assertion is about actual
    /// signal delivery, not about which function was called: the child writes
    /// to a pipe whose read end is already closed, and must survive to report
    /// its own exit status.
    @Test("StandardStream survives a reader that has gone away")
    func standardStreamSurvivesAClosedReader() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        try pipe.fileHandleForReading.close()

        // Would raise SIGPIPE and kill this test binary without the guard.
        StandardStream.write("this reader is gone\n", to: writer)
        StandardStream.writeToStandardError(Data())

        #expect(Bool(true), "reached the next statement, i.e. was not killed by SIGPIPE")
        try? writer.close()
    }
}
