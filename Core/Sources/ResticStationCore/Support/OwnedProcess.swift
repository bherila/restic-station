import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Descriptors every subprocess must keep open for as long as it lives
/// (#114). A set lock taken with `FileLock(…, leaseToChildren: true)` is
/// registered here while held; the runner hands every registered descriptor
/// to each child as fds 3, 4, … Because a `flock` belongs to the open file
/// description, the lock then stays held while restic — or any descendant
/// that inherited the descriptor — is alive, even if the helper that took it
/// is killed. A later operation on the same set reads as busy instead of
/// overlapping the orphan.
///
/// Process-wide rather than scoped to a task: a helper runs one set
/// operation at a time (the tick visits sets sequentially), so "every lease
/// held now" is exactly the operation's. Should two ever overlap in one
/// process, a child would also hold the other's lock after a crash — the
/// fail-safe direction: busy, never overlapping.
public final class ProcessLeases: @unchecked Sendable {
    public static let shared = ProcessLeases()

    public struct Token: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private let lock = NSLock()
    private var next: UInt64 = 0
    private var held: [UInt64: Int32] = [:]

    func hold(_ descriptor: Int32) -> Token {
        lock.lock()
        defer { lock.unlock() }
        next &+= 1
        held[next] = descriptor
        return Token(id: next)
    }

    func release(_ token: Token) {
        lock.lock()
        defer { lock.unlock() }
        held.removeValue(forKey: token.id)
    }

    /// In acquisition order.
    var current: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return held.sorted { $0.key < $1.key }.map(\.value)
    }
}

/// A child process this process spawned and reaps itself (#114), in its own
/// process group.
///
/// `Foundation.Process` could not do either: it exposes no process-group
/// control on any platform, and it reaps the child on its own monitor, so the
/// pid it hands out can be freed — and reused — before anything here learns
/// the child has gone. Owning the reap is what makes signalling safe:
///
/// - a waiter thread observes exit with `waitid(…, WEXITED | WNOWAIT)`, which
///   does **not** reap, so the leader stays a zombie and its pid (= its pgid)
///   cannot be reused;
/// - it then signals what is left of the group and only afterwards calls
///   `waitpid` to reap, recording that under `lock`;
/// - every other signal is sent under the same `lock`, and only while the
///   child is not yet reaped.
///
/// So a signal is never delivered to a pid this process has not proven it
/// still owns.
final class OwnedProcess: @unchecked Sendable {
    let pid: pid_t
    /// Parent ends of the child's stdin, stdout and stderr pipes. Owned by
    /// the caller once `spawn` returns.
    let stdinWrite: Int32
    let stdoutRead: Int32
    let stderrRead: Int32

    /// `killpg(2)`, replaceable only by tests (task-local), which use it to
    /// prove that no delivery is even attempted once the child is reaped —
    /// a reused pid cannot be staged, and a real `killpg` on a freed pid
    /// just fails with `ESRCH`, which would hide a missing guard.
    @TaskLocal static var deliver: @Sendable (pid_t, Int32) -> Int32 = { killpg($0, $1) }

    private let lock = NSLock()
    private var reaped = false
    private var waitStatus: Int32 = 0

    private init(pid: pid_t, stdinWrite: Int32, stdoutRead: Int32, stderrRead: Int32) {
        self.pid = pid
        self.stdinWrite = stdinWrite
        self.stdoutRead = stdoutRead
        self.stderrRead = stderrRead
    }

    /// The exit status as `Foundation.Process.terminationStatus` reported it:
    /// the exit code, or the signal number for a child killed by a signal.
    /// Meaningful only after `onExit` has run.
    var terminationStatus: Int32 {
        lock.lock()
        defer { lock.unlock() }
        let low = waitStatus & 0x7f
        return low == 0 ? (waitStatus >> 8) & 0xff : low
    }

    var hasBeenReaped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reaped
    }

    /// Sends `signal` to the child's whole process group, if and only if the
    /// child is not yet reaped. Returns whether it was sent.
    @discardableResult
    func signalGroup(_ signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped else { return false }
        return Self.deliver(pid, signal) == 0
    }

    /// Spawns `argv` (an absolute executable path first) in a new process
    /// group, with stdin/stdout/stderr on fresh pipes and `inherit` as fds
    /// 3, 4, …; every other descriptor is closed in the child. `onExit` runs
    /// once, on the waiter thread, after the child has been reaped.
    static func spawn(
        argv: [String],
        env: [String: String]?,
        inherit: [Int32],
        onExit: @escaping @Sendable () -> Void
    ) throws -> OwnedProcess {
        precondition(!argv.isEmpty)
        let stdinPipe = try makePipe()
        let stdoutPipe: (read: Int32, write: Int32)
        let stderrPipe: (read: Int32, write: Int32)
        do {
            stdoutPipe = try makePipe()
        } catch {
            closeAll([stdinPipe.read, stdinPipe.write])
            throw error
        }
        do {
            stderrPipe = try makePipe()
        } catch {
            closeAll([stdinPipe.read, stdinPipe.write, stdoutPipe.read, stdoutPipe.write])
            throw error
        }
        // Lease sources moved above any target slot, close-on-exec, so
        // `dup2` onto 3, 4, … can never overwrite another source first.
        var leaseSources: [Int32] = []
        for descriptor in inherit {
            let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
            guard copy >= 0 else {
                let code = errno
                closeAll(leaseSources + [stdinPipe.read, stdinPipe.write, stdoutPipe.read, stdoutPipe.write,
                                         stderrPipe.read, stderrPipe.write])
                throw ProcessRunnerError.launchFailed("could not prepare lease descriptor \(descriptor): errno \(code)")
            }
            leaseSources.append(copy)
        }
        let childEnds = [stdinPipe.read, stdoutPipe.write, stderrPipe.write]
        defer { closeAll(childEnds + leaseSources) }

        let pid: pid_t
        do {
            pid = try posixSpawn(
                argv: argv,
                env: env ?? ProcessInfo.processInfo.environment,
                stdio: (stdinPipe.read, stdoutPipe.write, stderrPipe.write),
                leases: leaseSources
            )
        } catch {
            closeAll([stdinPipe.write, stdoutPipe.read, stderrPipe.read])
            throw error
        }

        let process = OwnedProcess(
            pid: pid,
            stdinWrite: stdinPipe.write,
            stdoutRead: stdoutPipe.read,
            stderrRead: stderrPipe.read
        )
        let waiter = Thread { process.awaitExit(onExit: onExit) }
        waiter.name = "restic-station.waitpid.\(pid)"
        waiter.start()
        return process
    }

    /// Exit observation without reaping, then the group's stragglers, then
    /// the reap.
    private func awaitExit(onExit: @Sendable () -> Void) {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 {
            if errno == EINTR { continue }
            break // ECHILD cannot happen for our own unreaped child; reap below regardless
        }
        // The leader is a zombie: its pid, and so the group id, is still
        // ours. Anything still in the group is a descendant that would
        // otherwise outlive its run. SIGTERM, not SIGKILL: a run that ended
        // on its own gets the polite version.
        signalGroup(SIGTERM)

        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, 0)
        } while result < 0 && errno == EINTR
        lock.lock()
        waitStatus = result == pid ? status : (0x7f00 | 0) // unknown: report as exit 127
        reaped = true
        lock.unlock()
        onExit()
    }

    // MARK: - posix_spawn

    private static func posixSpawn(
        argv: [String],
        env: [String: String],
        stdio: (in: Int32, out: Int32, err: Int32),
        leases: [Int32]
    ) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw ProcessRunnerError.launchFailed("posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw ProcessRunnerError.launchFailed("posix_spawnattr_init failed")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // Every setup call is checked: `posix_spawn` would happily launch a
        // child missing an action that failed to register — and a missing
        // lease is a set lock that does not survive the helper (#114).
        func check(_ result: Int32, _ what: String) throws {
            guard result == 0 else {
                throw ProcessRunnerError.launchFailed("\(what) failed: errno \(result)")
            }
        }
        try check(posix_spawn_file_actions_adddup2(&actions, stdio.in, 0), "adddup2 stdin")
        try check(posix_spawn_file_actions_adddup2(&actions, stdio.out, 1), "adddup2 stdout")
        try check(posix_spawn_file_actions_adddup2(&actions, stdio.err, 2), "adddup2 stderr")
        // `dup2` clears close-on-exec on the target, which is what makes a
        // lease survive `exec`.
        for (index, source) in leases.enumerated() {
            try check(posix_spawn_file_actions_adddup2(&actions, source, Int32(3 + index)), "adddup2 lease")
        }

        var flags = Int32(POSIX_SPAWN_SETPGROUP) | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        // Everything not named above is closed in the child: inheritance is
        // opt-in, never ambient.
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        // No CLOEXEC_DEFAULT on Linux: close, in the child, every inherited
        // descriptor at or above the first free slot. Close-on-exec ones go
        // at `exec` anyway, so only the others need an action.
        for descriptor in try inheritableDescriptors() where descriptor >= 3 + Int32(leases.count) {
            try check(posix_spawn_file_actions_addclose(&actions, descriptor), "addclose")
        }
        #endif
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "setflags")
        try check(posix_spawnattr_setpgroup(&attributes, 0), "setpgroup")

        // Default dispositions and an empty mask in the child on every
        // platform. macOS's Foundation reset them; swift-corelibs does not,
        // which is how an ignored SIGPIPE once leaked into children on Linux.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in Int32(1)..<Int32(32) where signal != SIGKILL && signal != SIGSTOP {
            sigaddset(&defaults, signal)
        }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), "setsigdefault")
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        try check(posix_spawnattr_setsigmask(&attributes, &emptyMask), "setsigmask")

        let argvC = argv.map { strdup($0) } + [nil]
        let envC = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argvC.forEach { free($0) }
            envC.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = argvC.withUnsafeBufferPointer { argvBuffer in
            envC.withUnsafeBufferPointer { envBuffer in
                posix_spawn(&pid, argv[0], &actions, &attributes, argvBuffer.baseAddress!, envBuffer.baseAddress!)
            }
        }
        guard result == 0 else {
            throw SpawnFailure(errnoValue: result, path: argv[0])
        }
        return pid
    }

    #if !canImport(Darwin)
    /// Open descriptors without close-on-exec, from `/proc/self/fd`.
    private static func inheritableDescriptors() -> [Int32] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") else {
            return []
        }
        return names.compactMap { Int32($0) }.filter { descriptor in
            let flags = fcntl(descriptor, F_GETFD)
            return flags >= 0 && flags & FD_CLOEXEC == 0
        }
    }
    #endif

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        // `pipe2` is not exported by every Glibc overlay this builds with, so
        // close-on-exec is set right after. A child spawned concurrently in
        // that instant could see these ends without it — but every spawn here
        // closes such descriptors in the child (CLOEXEC_DEFAULT on Darwin, the
        // explicit close actions on Linux), so nothing is inherited either way.
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            throw ProcessRunnerError.launchFailed("pipe failed: errno \(errno)")
        }
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        return (ends[0], ends[1])
    }

    static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            close(descriptor)
        }
    }
}

/// `posix_spawn`'s own error, carrying its errno so the #116 retry can tell
/// a transient spawn failure from a permanent one on every platform.
struct SpawnFailure: Error, CustomStringConvertible {
    let errnoValue: Int32
    let path: String

    var description: String {
        "posix_spawn(\(path)) failed: \(String(cString: strerror(errnoValue))) (errno \(errnoValue))"
    }
}
