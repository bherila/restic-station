import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Writing to stdout/stderr when the reader has gone away.
///
/// When the app spawns the helper, the helper's stdout and stderr are pipes
/// back to the app. If the app crashes or is force-quit mid-operation, the
/// next write raises SIGPIPE, whose default disposition kills the helper —
/// and `FileHandle.write(_:)` additionally raises an uncatchable ObjC
/// exception rather than throwing. A helper that dies at, say, the warning it
/// emits when `RunStore.finish` fails takes the run record with it: the one
/// artifact that would have explained what happened.
///
/// The guard is the same one `DefaultProcessRunner` uses for child stdin, and
/// for the same reason it must not be left installed process-wide: POSIX
/// preserves an *ignored* disposition across `exec`, and
/// swift-corelibs-foundation does not reset child dispositions, so a restic
/// child spawned inside the window would stop dying on a broken pipe. Sharing
/// `SIGPIPEGuard` means these writes and every spawn take one lock, so the
/// window can never overlap a `posix_spawn`.
public enum StandardStream {
    public static func write(_ text: String, to handle: FileHandle) {
        write(Data(text.utf8), to: handle)
    }

    /// Best-effort by design: if the reader is gone there is nowhere left to
    /// report that fact, and the caller's real work must continue.
    public static func write(_ data: Data, to handle: FileHandle) {
        SIGPIPEGuard.withIgnored {
            try? handle.write(contentsOf: data)
        }
    }

    /// Spelled out for call sites whose argument spans several lines, where
    /// a trailing `to:` label reads worse than the destination in the name.
    public static func writeToStandardError(_ data: Data) {
        write(data, to: .standardError)
    }

    public static func writeToStandardOutput(_ data: Data) {
        write(data, to: .standardOutput)
    }
}
