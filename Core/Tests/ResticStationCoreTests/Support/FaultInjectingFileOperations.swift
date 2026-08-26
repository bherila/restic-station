import Foundation
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Programmable fault injector for `RunStoreFileOperations`, RunStore's
/// narrow POSIX seam (see `docs/testing.md` §RunStore fault injection).
///
/// Three fault programs, plus an operation trace:
///
/// - ``crashAfter(operations:)`` — every seam call whose 1-based ordinal
///   exceeds the given count silently does nothing while *reporting
///   success*. That is the in-process analog of the process dying at that
///   step boundary: nothing later reaches the disk, and no error path runs
///   (a dead process has no error path). A test then "remounts" by building
///   a fresh live `RunStore` over the same directory and running the
///   recovery scan against whatever the crash left behind.
/// - ``failSync(atCall:errno:)`` — one-shot fsync failures (`EINTR`,
///   `EIO`, ...) at an exact fsync ordinal, counted across all descriptors.
/// - ``tearWrite(toFileNamed:keepingBytes:)`` — the first write to the
///   named file persists only a prefix, then the "process" crashes.
///
/// The ``trace`` labels each write/fsync by target — the file name it was
/// opened under through the seam, or `.directory` (detected by `fstat`,
/// because RunStore opens directory descriptors outside the seam) — so
/// tests can assert the documented ordering contracts directly.
///
/// Model limits, deliberately: crashes replay at *seam-call* boundaries
/// against the real filesystem. Losing un-fsynced page cache is not
/// simulated, and `FileManager` calls (mkdir/remove) are not part of the
/// seam, so a crash "between" one of those and a seam call is not
/// representable.
final class FaultInjectingFileOperations: @unchecked Sendable {
    enum Target: Equatable {
        case file(String)
        case directory
        case unknown
    }

    enum Operation: Equatable {
        case openAt(String)
        case write(Target)
        case sync(Target)
        case rename(from: String, to: String)
        case unlink(String)
    }

    private let live = RunStoreFileOperations.live
    private let lock = NSLock()
    private var fdNames: [Int32: String] = [:]
    private var operationOrdinal = 0
    private var syncOrdinal = 0
    private var recordedTrace: [Operation] = []
    private var crashAfterOperationCount: Int?
    private var oneShotSyncErrno: [Int: Int32] = [:]
    private var pendingTear: (fileName: String, keepBytes: Int)?
    private var crashed = false

    // MARK: - Programming

    func crashAfter(operations: Int) {
        withLock { crashAfterOperationCount = operations }
    }

    /// The `call`-th fsync (1-based) fails once with `errno`; a retry of
    /// the same fsync is the next ordinal and proceeds normally.
    func failSync(atCall call: Int, errno code: Int32) {
        withLock { oneShotSyncErrno[call] = code }
    }

    func tearWrite(toFileNamed fileName: String, keepingBytes keepBytes: Int) {
        withLock { pendingTear = (fileName, keepBytes) }
    }

    // MARK: - Observation

    /// Whether the programmed crash point was actually reached. A crash
    /// matrix's largest argument asserts this is `false`, proving the
    /// parameter range still covers the whole flow.
    var didCrash: Bool { withLock { crashed } }
    var operationCount: Int { withLock { operationOrdinal } }
    var syncCallCount: Int { withLock { syncOrdinal } }
    var trace: [Operation] { withLock { recordedTrace } }

    // MARK: - The seam

    var operations: RunStoreFileOperations {
        RunStoreFileOperations(
            openAt: { [self] directory, name, flags, mode in
                handleOpenAt(directory, name, flags, mode)
            },
            write: { [self] fd, buffer, count in
                handleWrite(fd, buffer, count)
            },
            sync: { [self] fd in
                handleSync(fd)
            },
            renameAt: { [self] oldDirectory, oldName, newDirectory, newName in
                handleRenameAt(oldDirectory, oldName, newDirectory, newName)
            },
            unlinkAt: { [self] directory, name in
                handleUnlinkAt(directory, name)
            }
        )
    }

    // MARK: - Handlers

    private func handleOpenAt(
        _ directory: Int32, _ name: String, _ flags: Int32, _ mode: mode_t
    ) -> Int32 {
        let dead = advanceOperation(recording: .openAt(name))
        let fd: Int32
        if dead {
            // The caller needs a descriptor it can close; writes and syncs
            // against it are already no-ops via the crash flag.
            fd = "/dev/null".withCString { open($0, O_RDWR) }
        } else {
            fd = live.openAt(directory, name, flags, mode)
        }
        if fd >= 0 {
            withLock { fdNames[fd] = name }
        }
        return fd
    }

    private func handleWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        let target = classify(fd)
        let dead = advanceOperation(recording: .write(target))
        if dead { return count }
        if let tear = withLock({ pendingTear }), target == .file(tear.fileName) {
            let keep = min(max(tear.keepBytes, 0), count)
            var written = 0
            while written < keep {
                let result = live.write(fd, buffer.advanced(by: written), keep - written)
                if result <= 0 { break }
                written += result
            }
            withLock {
                pendingTear = nil
                // Everything after the torn write is the dead process.
                crashAfterOperationCount = operationOrdinal
                crashed = true
            }
            return count
        }
        return live.write(fd, buffer, count)
    }

    private func handleSync(_ fd: Int32) -> Int32 {
        let target = classify(fd)
        let dead = advanceOperation(recording: .sync(target))
        let injected: Int32? = withLock {
            syncOrdinal += 1
            return oneShotSyncErrno.removeValue(forKey: syncOrdinal)
        }
        if let code = injected {
            setInjectedErrno(code)
            return -1
        }
        if dead { return 0 }
        return live.sync(fd)
    }

    private func handleRenameAt(
        _ oldDirectory: Int32, _ oldName: String, _ newDirectory: Int32, _ newName: String
    ) -> Int32 {
        let dead = advanceOperation(recording: .rename(from: oldName, to: newName))
        if dead { return 0 }
        return live.renameAt(oldDirectory, oldName, newDirectory, newName)
    }

    private func handleUnlinkAt(_ directory: Int32, _ name: String) -> Int32 {
        let dead = advanceOperation(recording: .unlink(name))
        if dead { return 0 }
        return live.unlinkAt(directory, name)
    }

    // MARK: - Internals

    /// Records the operation, advances the ordinal, and reports whether the
    /// operation lies beyond the programmed crash point.
    private func advanceOperation(recording operation: Operation) -> Bool {
        withLock {
            operationOrdinal += 1
            recordedTrace.append(operation)
            if let crashPoint = crashAfterOperationCount, operationOrdinal > crashPoint {
                crashed = true
                return true
            }
            return false
        }
    }

    private func classify(_ fd: Int32) -> Target {
        if Self.isDirectory(fd) { return .directory }
        if let name = withLock({ fdNames[fd] }) { return .file(name) }
        return .unknown
    }

    private static func isDirectory(_ fd: Int32) -> Bool {
        var info = stat()
        #if canImport(Darwin)
        guard Darwin.fstat(fd, &info) == 0 else { return false }
        #elseif canImport(Glibc)
        guard Glibc.fstat(fd, &info) == 0 else { return false }
        #elseif canImport(Musl)
        guard Musl.fstat(fd, &info) == 0 else { return false }
        #endif
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func setInjectedErrno(_ value: Int32) {
        #if canImport(Darwin)
        __error().pointee = value
        #elseif canImport(Glibc)
        __errno_location().pointee = value
        #elseif canImport(Musl)
        __errno_location().pointee = value
        #endif
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
