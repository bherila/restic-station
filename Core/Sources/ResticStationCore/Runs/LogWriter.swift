import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Line-append handle to `runs/<runId>/log.txt` (see `docs/data-model.md`
/// §AppPaths). Each appended line is prefixed with a `[HH:mm:ss] ` (UTC)
/// timestamp and flushed immediately — the underlying write is a single
/// `write(2)` syscall per line with no userspace buffering, so a reader
/// that opens the same file concurrently (e.g. a "tail the running log" UI)
/// sees each line as soon as it's appended.
public final class LogWriter: @unchecked Sendable {
    private var fd: Int32
    private let now: () -> Date

    /// Opens (creating if necessary) `url` for appending. Existing content,
    /// if any, is preserved (`O_APPEND`).
    public init(url: URL, now: @escaping () -> Date = Date.init) throws {
        let opened = url.path.withCString { open($0, O_CREAT | O_WRONLY | O_APPEND, 0o644) }
        guard opened >= 0 else {
            throw LogWriterError.openFailed(errno: errno, path: url.path)
        }
        self.fd = opened
        self.now = now
    }

    /// Appends one `[HH:mm:ss] <line>\n` record. A trailing newline is
    /// added if `line` doesn't already end in one; embedded newlines in
    /// `line` are written verbatim (only the leading timestamp is added).
    public func appendLine(_ line: String) {
        guard fd >= 0 else { return }
        let timestamp = Self.timestampFormatter.string(from: now())
        var text = "[\(timestamp)] \(line)"
        if !text.hasSuffix("\n") {
            text += "\n"
        }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard var base = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break } // best-effort; nothing sane to do with a log-write failure
                remaining -= n
                base += n
            }
        }
    }

    /// Closes the underlying file descriptor. Safe to call multiple times.
    public func close() {
        guard fd >= 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #elseif canImport(Glibc)
        _ = Glibc.close(fd)
        #elseif canImport(Musl)
        _ = Musl.close(fd)
        #endif
        fd = -1
    }

    deinit {
        close()
    }

    private static var timestampFormatter: DateFormatter {
        // Fresh instance per call: DateFormatter is a mutable, non-Sendable
        // class and LogWriter may be used from concurrent contexts.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }
}

public enum LogWriterError: Error, Equatable, Sendable, CustomStringConvertible {
    case openFailed(errno: Int32, path: String)

    public var description: String {
        switch self {
        case .openFailed(let errno, let path):
            return "open(\(path)) failed: errno \(errno)"
        }
    }
}
