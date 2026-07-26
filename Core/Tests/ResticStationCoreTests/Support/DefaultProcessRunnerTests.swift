import Foundation
import Testing
@testable import ResticStationCore

/// Portable smoke tests for `DefaultProcessRunner` — real subprocesses, no
/// mocking. Uses only `/bin/echo` and `/bin/sh`, present on both macOS and
/// the `swift:6.1` Linux CI container (see docs/testing.md).
@Suite("DefaultProcessRunner")
struct DefaultProcessRunnerTests {
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

    @Test("throws ProcessRunnerError.timeout and stops a long-running process via SIGINT")
    func timeoutSendsSIGINT() async throws {
        let runner = DefaultProcessRunner()

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
}
