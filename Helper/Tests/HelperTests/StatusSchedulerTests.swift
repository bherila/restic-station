#if os(macOS)

import Foundation
import Testing

import ResticStationCore
@testable import restic_station_helper

@Suite("status launchd scheduler probe")
struct StatusSchedulerTests {
    final class Runner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private let result: Result<ProcessResult, ProcessRunnerError>
        private var recordedArgv: [String] = []
        private var recordedTimeout: TimeInterval?

        init(result: Result<ProcessResult, ProcessRunnerError>) {
            self.result = result
        }

        var argv: [String] {
            withLock { recordedArgv }
        }

        var timeout: TimeInterval? {
            withLock { recordedTimeout }
        }

        func run(
            _ argv: [String],
            env: [String: String]?,
            currentDirectory: String?,
            onStdoutLine: (@Sendable (String) -> Void)?,
            onStderrLine: (@Sendable (String) -> Void)?,
            timeout: TimeInterval?
        ) async throws -> ProcessResult {
            withLock {
                recordedArgv = argv
                recordedTimeout = timeout
            }
            return try result.get()
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private func result(exitCode: Int32) -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: Data(), stderr: Data())
    }

    @Test("exit zero means the LaunchAgent is loaded")
    func loadedAgentIsHealthy() async throws {
        let runner = Runner(result: .success(result(exitCode: 0)))

        let scheduler = try #require(await Status.scheduler(
            paths: AppPaths(root: FileManager.default.temporaryDirectory),
            runner: runner,
            uid: 502
        ))

        #expect(scheduler.kind == "launchd-agent")
        #expect(scheduler.healthy == true)
        #expect(scheduler.problems.isEmpty)
        #expect(runner.argv == [
            "/bin/launchctl", "print", "gui/502/net.herila.ResticStation.helper",
        ])
        #expect(runner.timeout == 5)
    }

    @Test("nonzero means scheduled backups will not happen")
    func missingAgentIsUnhealthy() async throws {
        let runner = Runner(result: .success(result(exitCode: 113)))

        let scheduler = try #require(await Status.scheduler(
            paths: AppPaths(root: FileManager.default.temporaryDirectory),
            runner: runner,
            uid: 501
        ))

        #expect(scheduler.healthy == false)
        #expect(scheduler.problems == ["agentNotLoaded"])
        #expect(scheduler.summaries.first?.contains("net.herila.ResticStation.helper") == true)
    }

    @Test("a failed probe stays unknown instead of claiming the scheduler is broken")
    func probeFailureIsUnknown() async throws {
        let runner = Runner(result: .failure(.timeout))

        let scheduler = try #require(await Status.scheduler(
            paths: AppPaths(root: FileManager.default.temporaryDirectory),
            runner: runner,
            uid: 501
        ))

        #expect(scheduler.healthy == nil)
        #expect(scheduler.problems == ["launchctlProbeFailed"])
    }
}

#endif
