import Foundation
import Testing
@testable import ResticStationCore

/// Process-lifetime contracts for `DefaultProcessRunner` (#114).
///
/// These cover one defect from several sides: a deadline that was really a
/// race against *pipe EOF* rather than against process termination, and the
/// unbounded waits hiding behind it. `/bin/sh` stands in for the descendants
/// `restic` spawns of its own (`ssh` for the sftp backend, a password
/// command) and is present on both macOS and the `swift:6.1` Linux CI
/// container (see docs/testing.md).
///
/// **What is asserted is that the call returns within a bound, not that any
/// particular signal worked.** Whether SIGINT reaches a child is not portable
/// — see `stopSequenceGracesAreTenSecondsInProduction` and docs/testing.md —
/// so a test that pins the *mechanism* pins a platform. The contract the
/// engine depends on is that a run with a deadline cannot hold the set lock
/// indefinitely, and that survives either outcome.
///
/// Each test therefore asserts an elapsed-time bound and not only the thrown
/// error: the failure being covered is a wait that never ends, so "it
/// eventually returned the right value" is not the contract. Children sleep
/// far longer than any bound here, so "waited the child out" cannot pass.
@Suite("Process lifetime")
struct ProcessLifetimeTests {
    /// Graces shrunk from the production 10 s. The stop sequence is up to
    /// four waits deep, so at production values one assertion costs 30 s+ and
    /// any bound loose enough to survive that stops distinguishing "the
    /// deadline was enforced" from "the child was waited out".
    private static func runner() -> DefaultProcessRunner {
        DefaultProcessRunner(terminationGrace: 1, drainGrace: 1)
    }

    /// The production graces are the documented ones. Guards the seam above:
    /// shrinking graces for tests must not quietly become the shipped values.
    @Test("the stop sequence's graces are 10s in production")
    func stopSequenceGracesAreTenSecondsInProduction() {
        let production = DefaultProcessRunner()
        #expect(production.terminationGrace == 10)
        #expect(production.drainGrace == 10)
    }

    /// A child that closes stdout and stderr but keeps running hands the
    /// reader tasks EOF immediately. When the deadline raced those readers it
    /// was cancelled at that instant, and the runner then waited on the live
    /// child indefinitely — holding the set lock, and finally returning the
    /// run as a *success* with no timeout raised at all.
    @Test("terminates a child that closes its pipes but keeps running", .timeLimit(.minutes(1)))
    func timeoutTerminatesChildThatClosedItsPipes() async throws {
        let started = Date()

        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await Self.runner().run(
                ["/bin/sh", "-c", "exec 1>&- 2>&-; sleep 60"],
                env: nil,
                stdin: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 1
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 10, "returned after \(elapsed)s; the child was waited out rather than stopped at the deadline")
    }

    /// A child that *ignores* SIGINT, so the run can only end through the
    /// escalation behind it — or through the bound behind that.
    ///
    /// This is the shape that caught the worst of #114 on the `linux` job.
    /// The termination wait was one arm of a task group, and a task group
    /// awaits all of its children, so a `withCheckedContinuation` parked on a
    /// child that outlived its stop sequence could not be unparked by
    /// `cancelAll()`. `.timeout` was thrown at 2 s and the call returned at
    /// 45.003 s — the child's whole natural lifetime — with the set lock held
    /// throughout. macOS never showed it, because SIGKILL lands there and
    /// frees the waiter within seconds.
    @Test("a child that ignores SIGINT cannot outlast the deadline", .timeLimit(.minutes(1)))
    func childIgnoringSIGINTCannotOutlastTheDeadline() async throws {
        let started = Date()

        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await Self.runner().run(
                ["/bin/sh", "-c", "trap '' INT; sleep 60"],
                env: nil,
                stdin: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 1
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 12, "returned after \(elapsed)s; nothing bounded the wait for a child that survives SIGINT")
    }

    /// The mirror image: the deadline fires and the direct child is stopped,
    /// but a descendant still holds the inherited stdout/stderr write ends.
    /// Draining "until EOF" then outlasts the deadline by the descendant's
    /// whole lifetime, so the timeout is unenforceable by a second route.
    @Test("a descendant holding the pipes cannot outlast the deadline", .timeLimit(.minutes(1)))
    func descendantHoldingPipesCannotOutlastTheDeadline() async throws {
        let started = Date()

        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await Self.runner().run(
                ["/bin/sh", "-c", "sleep 60 & sleep 60"],
                env: nil,
                stdin: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 1
            )
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 12, "returned after \(elapsed)s; the descendant holding the pipes was waited out")
    }
}
