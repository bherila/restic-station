import Foundation
import Testing
@testable import ResticStationCore

/// Process-lifetime contracts for `DefaultProcessRunner` (#114).
///
/// Both tests cover the same defect from opposite sides: a timeout that is
/// really a race against *pipe EOF* rather than against process termination.
/// `/bin/sh` stands in for the descendants `restic` spawns of its own (`ssh`
/// for the sftp backend, a password command) and is present on both macOS
/// and the `swift:6.1` Linux CI container (see docs/testing.md).
///
/// Each asserts an elapsed-time bound and not only the thrown error: the
/// failure being covered is a wait that never ends while the set lock is
/// held, so "it eventually returned the right value" is not the contract.
/// The bounds are loose on purpose — they separate "the deadline was
/// enforced" from "the child was waited out", not one stop phase from
/// another, and must not turn into timing flakes on a loaded CI runner.
@Suite("Process lifetime")
struct ProcessLifetimeTests {
    /// A child that closes stdout and stderr but keeps running hands the
    /// reader tasks EOF immediately. When the deadline raced those readers it
    /// was cancelled at that instant, and the runner then waited on the live
    /// child indefinitely — holding the set lock, and finally returning the
    /// run as a *success* with no timeout raised at all.
    ///
    /// The observed wait here is the 2 s deadline plus most of the 10 s
    /// SIGKILL grace, because SIGINT reaches only the direct child: a shell
    /// defers it while waiting on `sleep`, so nothing stops until SIGKILL.
    /// That is the process-group half of #114, still open, and the reason
    /// this bound is 20 s rather than a few seconds.
    @Test("terminates a child that closes its pipes but keeps running", .timeLimit(.minutes(1)))
    func timeoutTerminatesChildThatClosedItsPipes() async throws {
        let runner = DefaultProcessRunner()
        let started = Date()

        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await runner.run(
                ["/bin/sh", "-c", "exec 1>&- 2>&-; sleep 45"],
                env: nil,
                stdin: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 2
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 20, "returned after \(elapsed)s; the child was waited out rather than stopped at the deadline")
    }

    /// The SIGKILL escalation, covered on its own. A child that *ignores*
    /// SIGINT can only be ended by the escalation behind it, so this is the
    /// one test that fails if the escalation is silently skipped.
    ///
    /// It is the case the `linux` CI job caught: the stop sequence gated
    /// every signal on `Foundation.Process.isRunning`, and where that flag
    /// misreports a live child as finished, both SIGINT and SIGKILL become
    /// no-ops. `run` still threw `.timeout` exactly on schedule while the
    /// child ran to completion — a deadline enforced in name only, with the
    /// set lock held throughout. Liveness is now judged by this file's own
    /// termination latch, which is also the flag that proves the pid has not
    /// been reaped and therefore cannot have been reused.
    @Test("the SIGKILL escalation reaches a child that ignores SIGINT", .timeLimit(.minutes(2)))
    func killEscalationReachesChildIgnoringSIGINT() async throws {
        let runner = DefaultProcessRunner()
        let started = Date()

        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await runner.run(
                ["/bin/sh", "-c", "trap '' INT; sleep 45"],
                env: nil,
                stdin: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 2
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 25, "returned after \(elapsed)s; only SIGKILL can end this child, and it never arrived")
    }

    /// The mirror image: the deadline fires and the direct child is stopped,
    /// but a descendant still holds the inherited stdout/stderr write ends.
    /// Draining "until EOF" then outlasts the deadline by the descendant's
    /// whole lifetime, so the timeout is unenforceable by a second route.
    ///
    /// The bound admits the deadline, the SIGKILL grace and the full
    /// post-stop drain grace in series, and still excludes waiting out the
    /// 45 s descendant.
    @Test("a descendant holding the pipes cannot outlast the deadline", .timeLimit(.minutes(2)))
    func descendantHoldingPipesCannotOutlastTheDeadline() async throws {
        let runner = DefaultProcessRunner()
        let started = Date()

        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await runner.run(
                ["/bin/sh", "-c", "sleep 45 & sleep 45"],
                env: nil,
                stdin: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 2
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 40, "returned after \(elapsed)s; the descendant holding the pipes was waited out")
    }
}
