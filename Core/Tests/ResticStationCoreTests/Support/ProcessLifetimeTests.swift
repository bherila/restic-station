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

    /// The stop sequence must actually **end the child**, not merely stop
    /// waiting for it. Asserted through liveness — the child appends to a
    /// file on a short loop, and that file must stop growing once the
    /// deadline has been reported.
    ///
    /// Every other test here bounds elapsed time, and elapsed time alone does
    /// not check this. A review of this PR deleted the entire kill path — no
    /// SIGINT, no SIGKILL, ever — and every one of them still passed, leaving
    /// eight children running, because the bounded drains satisfy the bounds
    /// on their own. That is precisely the vacuity this PR removed from
    /// `timeoutSendsSIGINT`, reproduced one level up.
    ///
    /// Liveness rather than a pid probe, because `kill(pid, 0)` succeeds
    /// against a zombie: on Linux a child ended by this sequence may not be
    /// reaped promptly (#149), so a pid probe would report a dead child as
    /// alive there. Counting writes is portable and cares only about whether
    /// the process is still executing.
    @Test("the deadline ends the child, not just the wait", .timeLimit(.minutes(1)))
    func deadlineEndsTheChild() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("process-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ticks = directory.appendingPathComponent("ticks")

        // Self-limiting at ~30 s so a regression cannot leave a process
        // running for longer than the suite that spawned it.
        let script = "i=0; while [ $i -lt 300 ]; do printf x >> '\(ticks.path)'; sleep 0.1; i=$((i+1)); done"

        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await Self.runner().run(
                ["/bin/sh", "-c", script],
                env: nil,
                stdin: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 1
            )
        }

        func tickCount() -> Int { (try? Data(contentsOf: ticks))?.count ?? 0 }
        let atReturn = tickCount()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let afterASecond = tickCount()

        #expect(
            afterASecond == atReturn,
            "the child wrote \(afterASecond - atReturn) more ticks after the deadline was reported — it was abandoned, not stopped"
        )
    }

    /// Cancelling delivers SIGINT and lets the child act on it. restic
    /// removes the repository lock it holds when it handles SIGINT, so a
    /// cancelled run that goes straight to SIGKILL strands that lock and
    /// blocks the next run against the same repository.
    ///
    /// **What this does not cover.** The narrower regression fixed alongside
    /// it — cancelling *while the timeout's* stop sequence is mid-grace, which
    /// made `Task.sleep` throw and escalated to SIGKILL at once — is not
    /// isolated here. The deadline below is 30 s and never fires, so that path
    /// is never entered. Reaching it needs the cancellation to land inside a
    /// grace that has already sent its own SIGINT, which leaves only the
    /// child's time-of-death to distinguish the two behaviours, about a second
    /// apart. That is a timing assertion this suite would rather not own; the
    /// gap is recorded instead of papered over.
    ///
    /// macOS only. On Linux an ignored SIGINT disposition is inherited across
    /// `exec` and the child never sees the signal at all (#149), so there the
    /// marker would be absent whether or not the grace was honoured.
    #if canImport(Darwin)
    @Test("cancelling delivers SIGINT so the child can release its lock", .timeLimit(.minutes(1)))
    func cancellingDeliversSIGINT() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("process-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("caught-sigint")

        // Writes the marker from a SIGINT handler, exactly as restic uses its
        // own handler to release the repository lock. Only reachable if the
        // signal is delivered and the child is given time to act on it.
        let script = "trap 'printf caught > '\''\(marker.path)'\''; exit 0' INT; i=0; "
            + "while [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done"

        let task = Task {
            try await Self.runner().run(
                ["/bin/sh", "-c", script],
                env: nil,
                stdin: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 30
            )
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        _ = try? await task.value

        #expect(
            FileManager.default.fileExists(atPath: marker.path),
            "the child never ran its SIGINT handler; the cancellation path skipped the grace and went straight to SIGKILL"
        )
    }
    #endif

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

    /// The case the elapsed bounds elsewhere structurally cannot reach: the
    /// direct child exits *before* the deadline, so no stop sequence ever
    /// runs, while a descendant keeps the inherited pipe ends open.
    ///
    /// Draining to EOF then waits out the descendant with nothing bounding
    /// it, and because the deadline never fired the call finally returns
    /// **success** — a run reported good, minutes late, with the set lock
    /// held the whole time and no timeout raised. Measured at 15.02 s for a
    /// 15 s descendant against a 1 s deadline.
    ///
    /// `ssh` with `ControlPersist` is the production shape: the master
    /// outlives the client by design and holds what it inherited.
    ///
    /// Every other test here uses a child that survives to the deadline, so
    /// this interleaving was untested until a review constructed it.
    @Test("a descendant cannot extend a run whose child already exited", .timeLimit(.minutes(1)))
    func descendantCannotExtendARunWhoseChildExited() async throws {
        let started = Date()

        let result = try await Self.runner().run(
            ["/bin/sh", "-c", "sleep 30 & exit 0"],
            env: nil,
            stdin: nil,
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: 20
        )

        let elapsed = Date().timeIntervalSince(started)
        #expect(result.exitCode == 0)
        #expect(
            elapsed < 10,
            "returned after \(elapsed)s; the descendant was waited out, and because the deadline never fired this came back as a late success"
        )
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
