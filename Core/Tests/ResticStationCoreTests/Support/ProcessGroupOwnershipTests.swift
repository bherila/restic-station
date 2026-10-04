import Foundation
import Testing
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// #114: the runner spawns into its own process group, owns the reap, and
/// can lease a lock descriptor to the child.
@Suite struct ProcessGroupOwnershipTests {
    private let runner = DefaultProcessRunner(terminationGrace: 10, drainGrace: 2)
    /// For the two tests that prove SIGINT reached the group: with a 30 s
    /// SIGKILL grace, the old direct-child behaviour takes at least 31 s and
    /// the group behaviour about 1 s, so a bound of 20 s tells them apart
    /// even on a heavily loaded CI runner.
    private let patientRunner = DefaultProcessRunner(terminationGrace: 30, drainGrace: 2)

    /// Polls until `pid` is gone or dead (or `seconds` pass).
    ///
    /// Dead includes a zombie. An orphaned descendant is reparented to PID 1,
    /// and in a CI container PID 1 is often not an init that reaps, so a
    /// killed grandchild can stay a zombie indefinitely — `kill(pid, 0)`
    /// still succeeds on it although it has stopped running.
    private func waitForExit(_ pid: pid_t, seconds: Double = 5) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            if isZombie(pid) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func isZombie(_ pid: pid_t) -> Bool {
        #if os(Linux)
        // /proc/<pid>/stat: "pid (comm) S ..." — the state follows the last ')'.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return false }
        return stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("Z")
        #else
        // macOS: launchd reaps orphans promptly, so ESRCH is the signal.
        return false
        #endif
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ line: String) { lock.lock(); values.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    @Test("a grandchild holding the pipes is stopped with the group at the deadline")
    func grandchildIsStoppedAtDeadline() async throws {
        let lines = Lines()
        let started = ContinuousClock.now
        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await patientRunner.run(
                ["/bin/sh", "-c", "sleep 60 & echo $!; wait"],
                env: nil, currentDirectory: nil,
                onStdoutLine: { lines.append($0) }, onStderrLine: nil, timeout: 1
            )
        }
        #expect(ContinuousClock.now - started < .seconds(20))
        let grandchild = try #require(lines.all.first.flatMap { pid_t($0) })
        #expect(await waitForExit(grandchild), "the backgrounded sleep survived the stop sequence")
    }

    /// SIGINT is what lets restic remove its repository lock. Sent to the
    /// direct pid only, a shell defers it while it waits on its child, so the
    /// run sat out the whole SIGKILL grace (#147 measured ~13 s for a 2 s
    /// deadline). Sent to the group, it reaches the worker at once.
    @Test("SIGINT reaches a worker behind a shell, well inside the SIGKILL grace")
    func interruptReachesTheGroup() async throws {
        let started = ContinuousClock.now
        await #expect(throws: ProcessRunnerError.timeout) {
            _ = try await patientRunner.run(
                ["/bin/sh", "-c", "sleep 60; true"],
                env: nil, currentDirectory: nil, onStdoutLine: nil, onStderrLine: nil, timeout: 1
            )
        }
        #expect(ContinuousClock.now - started < .seconds(20), "SIGINT did not reach the group; SIGKILL grace was waited out")
    }

    @Test("a descendant left behind by a child that exited normally is stopped")
    func strayDescendantIsStoppedOnNormalExit() async throws {
        let lines = Lines()
        let result = try await runner.run(
            ["/bin/sh", "-c", "sleep 30 & echo $!"],
            env: nil, currentDirectory: nil,
            onStdoutLine: { lines.append($0) }, onStderrLine: nil, timeout: 20
        )
        #expect(result.exitCode == 0)
        let stray = try #require(lines.all.first.flatMap { pid_t($0) })
        #expect(await waitForExit(stray), "a descendant outlived its run inside our process group")
    }

    /// Codex on #168: the caller releases the set lock when `run` returns,
    /// so a descendant that ignores SIGTERM must be gone by then — SIGKILL
    /// after a bounded grace — not merely asked once. Its pipes are
    /// redirected, so the drain bound cannot be what stops it.
    @Test("a straggler that ignores SIGTERM is killed before the run returns")
    func termIgnoringStragglerIsKilledBeforeReturn() async throws {
        let lines = Lines()
        let result = try await runner.run(
            ["/bin/sh", "-c", "(trap '' TERM; exec sleep 60) </dev/null >/dev/null 2>&1 & echo $!"],
            env: nil, currentDirectory: nil,
            onStdoutLine: { lines.append($0) }, onStderrLine: nil, timeout: 30
        )
        #expect(result.exitCode == 0)
        let straggler = try #require(lines.all.first.flatMap { pid_t($0) })
        // Immediately, not after polling: the guarantee is "before return".
        let gone = (kill(straggler, 0) != 0 && errno == ESRCH) || isZombie(straggler)
        #expect(gone, "a TERM-ignoring descendant was still running when run() returned")
    }

    @Test("a run that leaves no stragglers pays no grace period")
    func noStragglersNoDelay() async throws {
        let started = ContinuousClock.now
        _ = try await runner.run(["/bin/sh", "-c", "true"], env: nil, currentDirectory: nil,
                                 onStdoutLine: nil, onStderrLine: nil, timeout: 30)
        #expect(ContinuousClock.now - started < .seconds(OwnedProcess.stragglerGrace))
    }

    @Test("exit status matches Foundation's convention: exit code, or the signal number")
    func exitStatusConvention() async throws {
        let exited = try await runner.run(["/bin/sh", "-c", "exit 7"], env: nil, currentDirectory: nil,
                                          onStdoutLine: nil, onStderrLine: nil, timeout: 10)
        #expect(exited.exitCode == 7)
        let signalled = try await runner.run(["/bin/sh", "-c", "kill -TERM $$"], env: nil, currentDirectory: nil,
                                             onStdoutLine: nil, onStderrLine: nil, timeout: 10)
        #expect(signalled.exitCode == SIGTERM)
    }

    @Test("a working directory is refused rather than ignored")
    func workingDirectoryRefused() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await runner.run(["/bin/echo"], env: nil, currentDirectory: "/tmp",
                                     onStdoutLine: nil, onStderrLine: nil, timeout: 5)
        }
    }

    // MARK: - Owning the reap

    /// Waits for `semaphore` on a dedicated thread, so a test never blocks a
    /// thread of the shared pool that timing-sensitive tests depend on.
    private func wait(_ semaphore: DispatchSemaphore, seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success) }.start()
        }
    }

    private func spawnAndWait(
        _ argv: [String],
        inherit: [Int32] = []
    ) throws -> (process: OwnedProcess, exited: DispatchSemaphore) {
        let exited = DispatchSemaphore(value: 0)
        let process = try OwnedProcess.spawn(argv: argv, env: nil, inherit: inherit) { exited.signal() }
        close(process.stdinWrite)
        return (process, exited)
    }

    @Test("no signal delivery is attempted once the child is reaped")
    func neverSignalsAfterReap() async throws {
        let (process, exited) = try spawnAndWait(["/bin/sh", "-c", "exit 0"])
        #expect(await wait(exited, seconds: 10))
        #expect(process.hasBeenReaped)
        let attempts = Lines()
        let sent = OwnedProcess.$deliver.withValue({ pid, signal in
            attempts.append("\(pid):\(signal)")
            return 0
        }) {
            process.signalGroup(SIGKILL)
        }
        #expect(!sent)
        #expect(attempts.all.isEmpty, "a reaped pid is no longer ours; nothing may be sent to it")
        OwnedProcess.closeAll([process.stdoutRead, process.stderrRead])
    }

    @Test("the child leads its own process group")
    func childLeadsItsGroup() async throws {
        let (process, exited) = try spawnAndWait(["/bin/sleep", "2"])
        defer { OwnedProcess.closeAll([process.stdoutRead, process.stderrRead]) }
        #expect(getpgid(process.pid) == process.pid)
        #expect(getpgid(process.pid) != getpgrp())
        process.signalGroup(SIGKILL)
        #expect(await wait(exited, seconds: 10))
    }

    @Test("inheritance is opt-in: a descriptor not leased does not reach the child")
    func noAmbientInheritance() async throws {
        let leaked = open("/dev/null", O_RDONLY) // deliberately without O_CLOEXEC
        defer { close(leaked) }
        let (process, exited) = try spawnAndWait(
            ["/bin/sh", "-c", "if [ -e /dev/fd/\(leaked) ]; then echo leaked; else echo clean; fi"]
        )
        #expect(await wait(exited, seconds: 10))
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(process.stdoutRead, &buffer, buffer.count)
        OwnedProcess.closeAll([process.stdoutRead, process.stderrRead])
        #expect(String(decoding: buffer[0..<max(0, count)], as: UTF8.self).hasPrefix("clean"))
    }

    // MARK: - Lease (#114 bullet 3)

    /// The acceptance criterion: if the helper is killed after launching a
    /// long-running child, a later helper cannot take the same set lock while
    /// that child is alive. "Killed" here is closing the parent's descriptor
    /// without `LOCK_UN`, which is what process death does to it.
    @Test("a leased lock stays held by the child after the parent's descriptor is gone")
    func leasedLockOutlivesParent() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lease-\(UUID().uuidString).lock").path
        defer { unlink(path) }
        let parentDescriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        #expect(parentDescriptor >= 0)
        #expect(flock(parentDescriptor, LOCK_EX | LOCK_NB) == 0)

        let (process, exited) = try spawnAndWait(["/bin/sleep", "2"], inherit: [parentDescriptor])
        defer { OwnedProcess.closeAll([process.stdoutRead, process.stderrRead]) }
        close(parentDescriptor) // the parent "dies": no LOCK_UN

        let contender = open(path, O_RDWR | O_CLOEXEC)
        defer { close(contender) }
        #expect(flock(contender, LOCK_EX | LOCK_NB) != 0, "the lock was released while the child still ran")

        #expect(await wait(exited, seconds: 10))
        #expect(flock(contender, LOCK_EX | LOCK_NB) == 0, "the lock stayed held after the child exited")
    }

    @Test("a lease-holding FileLock registers while held and unregisters on release")
    func fileLockRegistersLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lease-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Set(ProcessLeases.shared.current)
        let lock = FileLock(path: root.appendingPathComponent("set.lock"), leaseToChildren: true)
        #expect(lock.acquire() == .acquired)
        let during = Set(ProcessLeases.shared.current).subtracting(before)
        #expect(during.count == 1)
        lock.release()
        #expect(Set(ProcessLeases.shared.current).isDisjoint(with: during))

        let plain = FileLock(path: root.appendingPathComponent("other.lock"))
        #expect(plain.acquire() == .acquired)
        #expect(Set(ProcessLeases.shared.current).subtracting(before).isEmpty)
        plain.release()
    }
}
