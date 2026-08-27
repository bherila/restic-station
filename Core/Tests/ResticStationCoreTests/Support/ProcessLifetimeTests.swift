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

    /// Cancellation's release must be sticky, not a one-shot drain of
    /// whoever happens to be parked at that instant.
    ///
    /// The reachable path is an **already-cancelled** task:
    /// `withTaskCancellationHandler` runs its handler before the operation
    /// body, so the detached stop sequence can reach `releaseWaiters()` while
    /// there is nothing yet to drain. A wait registered afterwards would then
    /// park with nobody left to free it — recreating the exact hang the
    /// release exists to prevent.
    ///
    /// The second assertion matters as much as the first: a release must
    /// never be mistaken for termination, or the stop sequence would stop
    /// signalling a child that is still alive and a caller could read
    /// `terminationStatus` off a process that never exited.
    @Test("a release landing before the wait still frees it", .timeLimit(.minutes(1)))
    func releaseBeforeWaitDoesNotPark() async {
        let signal = TerminationSignal()
        let completed = CompletionFlag()

        signal.releaseWaiters()
        let waiter = Task.detached {
            await signal.wait()
            completed.set()
        }

        // Polled rather than awaited, and deliberately. A regression here
        // parks on a `withCheckedContinuation`, which cannot be cancelled, so
        // `await signal.wait()` would hang this test forever — and
        // `.timeLimit` cannot interrupt it either, since that also relies on
        // cancellation. Confirmed by red-check: reverting the latch hangs
        // rather than fails. Polling turns a hung suite into a 2 s failure.
        let deadline = Date().addingTimeInterval(2)
        while !completed.isSet, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(completed.isSet, "the wait parked — a release landing before the waiter existed was lost")
        #expect(!signal.hasFired, "a release must not be mistaken for the child having terminated")
        waiter.cancel()
    }

    /// The retry must cover only failures that say nothing about the
    /// command. Retrying a real one — a missing binary, a permission
    /// refusal — would turn one honest error into three attempts at the same
    /// wrong thing, and for a destructive command that is the wrong instinct
    /// entirely.
    ///
    /// Safe to retry at all only because this is a *launch* failure: POSIX
    /// guarantees no child exists when `posix_spawn` reports an error, so a
    /// retry cannot double-spawn.
    @Test("only moment-dependent spawn failures are retried")
    func onlyTransientSpawnFailuresAreRetried() {
        func posix(_ code: Int32) -> Error {
            NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }

        // #116's signature, and the ordinary "no process slots right now".
        #expect(DefaultProcessRunner.isTransientSpawnFailure(posix(EFAULT)))
        #expect(DefaultProcessRunner.isTransientSpawnFailure(posix(EAGAIN)))

        // Real answers about the command. Retrying these hides them.
        #expect(!DefaultProcessRunner.isTransientSpawnFailure(posix(ENOENT)))
        #expect(!DefaultProcessRunner.isTransientSpawnFailure(posix(EACCES)))
        #expect(!DefaultProcessRunner.isTransientSpawnFailure(posix(ENOEXEC)))

        // Same numeric code, different domain — not a spawn errno at all.
        #expect(!DefaultProcessRunner.isTransientSpawnFailure(
            NSError(domain: NSCocoaErrorDomain, code: Int(EFAULT))
        ))

        // How swift-corelibs-foundation actually reports a failed spawn:
        // `NSCocoaErrorDomain` / `fileReadUnknown`, with the errno buried
        // under `NSUnderlyingErrorKey`. Matching only the POSIX domain made
        // this retry dead code on Linux — and this test green there while
        // proving nothing, because it built errors Linux never throws.
        func corelibsWrapped(_ code: Int32) -> Error {
            NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileReadUnknown.rawValue,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))]
            )
        }
        #expect(DefaultProcessRunner.isTransientSpawnFailure(corelibsWrapped(EFAULT)))
        #expect(DefaultProcessRunner.isTransientSpawnFailure(corelibsWrapped(EAGAIN)))
        #expect(!DefaultProcessRunner.isTransientSpawnFailure(corelibsWrapped(ENOENT)))

        // Wrapped, but the underlying error is not a POSIX one.
        #expect(!DefaultProcessRunner.isTransientSpawnFailure(NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: Int(EFAULT))]
        )))
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

        // One tick per second, not ten. The loop forks a `sleep` per
        // iteration, and this suite's spawn churn is what pushes the
        // intermittent `posix_spawn` EFAULT of #116 from rare to routine.
        // Self-limiting at ~60 s so a regression cannot leave a process
        // running for longer than the suite that spawned it.
        let script = "i=0; while [ $i -lt 60 ]; do printf x >> '\(ticks.path)'; sleep 1; i=$((i+1)); done"

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

        // Long enough that a surviving child must tick at least twice more.
        func tickCount() -> Int { (try? Data(contentsOf: ticks))?.count ?? 0 }
        let atReturn = tickCount()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let afterWatching = tickCount()

        #expect(
            afterWatching == atReturn,
            "the child wrote \(afterWatching - atReturn) more ticks after the deadline was reported — it was abandoned, not stopped"
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
        let armed = directory.appendingPathComponent("trap-armed")

        // Writes the marker from a SIGINT handler, exactly as restic uses its
        // own handler to release the repository lock. Only reachable if the
        // signal is delivered and the child is given time to act on it.
        //
        // The second file exists because cancelling on a fixed delay is a
        // race, and it is one this test lost on CI: a spawn slower than the
        // delay lets SIGINT arrive before `sh` has installed the trap, and
        // the marker then never appears for a reason that has nothing to do
        // with the contract under test.
        let script = "trap 'printf caught > '\''\(marker.path)'\''; exit 0' INT; "
            + "printf armed > '\(armed.path)'; "
            + "i=0; while [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done"

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
        // Cancel only once the trap is demonstrably installed.
        let armedBy = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: armed.path), Date() < armedBy {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(
            FileManager.default.fileExists(atPath: armed.path),
            "the child never got as far as installing its trap; nothing about SIGINT is under test yet"
        )

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
    ///
    /// macOS only, and for a sharper reason than the other gate in this file:
    /// the *precondition* is unreachable on Linux. This needs the child's
    /// exit to be observed before the deadline, and there a `/bin/sh -c`
    /// child's termination is not observed at all while a descendant lives
    /// (#149) — so the deadline fires and the run ends as a bounded
    /// `.timeout` instead, at 26.97 s against a 20 s deadline. That is the
    /// runner behaving correctly; it simply is not this scenario. A bound
    /// loose enough to pass there would be satisfied with the fix reverted,
    /// which is worse than not running the test.
    #if canImport(Darwin)
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
    #endif

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

/// Minimal thread-safe flag, so `releaseBeforeWaitDoesNotPark` can observe a
/// wait completing without awaiting it.
private final class CompletionFlag: @unchecked Sendable {
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
