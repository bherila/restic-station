import Foundation
import Testing
@testable import ResticStationCore

@Suite struct LogWriterTests {
    private func makeLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-logwriter-test-\(UUID().uuidString).txt")
    }

    @Test func appendLinePrefixesTimestampAndTrailingNewline() throws {
        let url = makeLogURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2026
        components.month = 7
        components.day = 26
        components.hour = 9
        components.minute = 5
        components.second = 3
        let knownDate = calendar.date(from: components)!

        let writer = try LogWriter(url: url, now: { knownDate })
        writer.appendLine("backup started")
        writer.appendLine("files_new: 3")
        writer.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        #expect(lines == ["[09:05:03] backup started", "[09:05:03] files_new: 3"])
    }

    @Test func appendLineFlushesImmediatelyForAConcurrentReader() throws {
        let url = makeLogURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try LogWriter(url: url, now: { Date() })
        writer.appendLine("first line")

        // A totally separate read handle, opened while `writer` is still
        // open, must already see the line — no userspace buffering.
        let readBack = try String(contentsOf: url, encoding: .utf8)
        #expect(readBack.contains("first line"))

        writer.appendLine("second line")
        let readBack2 = try String(contentsOf: url, encoding: .utf8)
        #expect(readBack2.contains("first line"))
        #expect(readBack2.contains("second line"))

        writer.close()
    }

    @Test func appendPreservesExistingContentOnReopen() throws {
        let url = makeLogURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer1 = try LogWriter(url: url, now: { Date() })
        writer1.appendLine("from first writer")
        writer1.close()

        let writer2 = try LogWriter(url: url, now: { Date() })
        writer2.appendLine("from second writer")
        writer2.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("from first writer"))
        #expect(contents.contains("from second writer"))
    }

    @Test func closeIsIdempotentAndDeinitDoesNotCrash() throws {
        let url = makeLogURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var writer: LogWriter? = try LogWriter(url: url, now: { Date() })
        writer?.appendLine("line")
        writer?.close()
        writer?.close() // idempotent
        writer = nil // deinit should not crash on an already-closed fd
    }

    /// #148: `close()` runs on the engine's thread while `appendLine` runs
    /// on a pipe-reader queue. A close that lands mid-write would let the
    /// write hit a descriptor number already reused by an unrelated file, so
    /// close must wait for the in-flight write. Deterministic: the hook holds
    /// the first write open under the writer's lock.
    @Test func closeWaitsForAnInFlightWrite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logwriter-race-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        let first = OnceFlag()
        let writer = try LogWriter(url: url, now: Date.init, beforeWrite: {
            if first.take() {
                entered.signal()
                release.wait()
            }
        })

        DispatchQueue.global().async { writer.appendLine("in flight") }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            writer.close()
            closed.signal()
        }

        #expect(closed.wait(timeout: .now() + 0.3) == .timedOut, "close() returned while a write was in flight")
        release.signal()
        #expect(closed.wait(timeout: .now() + 5) == .success)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("in flight"))

        // And after close, a late line goes nowhere.
        writer.appendLine("too late")
        #expect(!(try String(contentsOf: url, encoding: .utf8).contains("too late")))
    }
}

/// Thread-safe one-shot flag for the test hook above.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
