import Combine
import Foundation

/// `tail -f` for `runs/<runId>/log.txt` (`docs/ui-spec.md` §Runs: "scrolling
/// monospaced log view — tail -f while running (re-read on StateWatcher
/// events), full content when finished").
///
/// Three properties make this cheap enough to drive from every watcher
/// event:
///
/// 1. **Only the appended suffix is read.** A byte offset is kept across
///    refreshes; each refresh seeks to it and reads to EOF, so a 50 MB log
///    is read once and then only grows by whatever restic just wrote.
/// 2. **Only whole lines are committed.** A refresh that lands mid-write
///    keeps the trailing partial line in `pendingLine` instead of decoding
///    it — that is what prevents a multi-byte UTF-8 sequence split across
///    two reads from rendering as `�`. `finish()` flushes it once the run is
///    over (a log's last line may legitimately have no newline).
/// 3. **The displayed text is capped.** A pathological log cannot grow the
///    UI's string without bound; the head is dropped with a marker.
///
/// Truncation or replacement of the file (size shrank below the offset) is
/// treated as "start over", so this never renders a spliced mixture of two
/// generations of a file.
@MainActor
final class RunLogTail: ObservableObject {

    /// Everything read so far, newline-terminated.
    @Published private(set) var text: String = ""
    /// `true` until a log file has been successfully opened at least once —
    /// a run that failed before restic was spawned never writes one.
    @Published private(set) var hasLogFile = false

    private var url: URL?
    private var offset: UInt64 = 0
    private var pendingLine = Data()
    /// Tracked incrementally: `String.count` is O(n), and this is consulted
    /// on every appended chunk.
    private var characterCount = 0

    /// Roughly a megabyte of log kept in memory for display, trimmed back to
    /// `trimTarget` when exceeded so trimming is amortised rather than
    /// happening on every subsequent append.
    private static let maximumCharacters = 1_000_000
    private static let trimTarget = 750_000
    private static let truncationMarker = "… earlier output truncated — use Reveal log in Finder for the whole file …\n"

    /// Reads whatever has been appended since the last call. Pointing the
    /// tail at a different file resets it, so one instance can follow the
    /// selection as the user moves between runs.
    func refresh(url: URL) {
        if self.url != url { reset(to: url) }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Not an error: the log appears a moment after the run record
            // does, and some runs never produce one.
            return
        }
        defer { try? handle.close() }
        hasLogFile = true

        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // Truncated or replaced — re-read from the beginning.
            offset = 0
            pendingLine.removeAll()
            text = ""
            characterCount = 0
        }
        guard size > offset else { return }

        guard (try? handle.seek(toOffset: offset)) != nil,
              let appended = try? handle.readToEnd(), !appended.isEmpty else { return }
        offset += UInt64(appended.count)

        pendingLine.append(appended)
        commitCompleteLines()
    }

    /// Flushes a trailing line that never got its newline. Call once the run
    /// is finished — while it is running, an unterminated tail is simply a
    /// write in progress.
    func finish() {
        guard !pendingLine.isEmpty else { return }
        append(String(decoding: pendingLine, as: UTF8.self))
        pendingLine.removeAll()
    }

    private func reset(to url: URL) {
        self.url = url
        offset = 0
        pendingLine.removeAll()
        text = ""
        characterCount = 0
        hasLogFile = false
    }

    private func commitCompleteLines() {
        guard let lastNewline = pendingLine.lastIndex(of: 0x0A) else { return }
        let complete = pendingLine[...lastNewline]
        pendingLine = Data(pendingLine[pendingLine.index(after: lastNewline)...])
        append(String(decoding: complete, as: UTF8.self))
    }

    private func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
        characterCount += chunk.count
        guard characterCount > Self.maximumCharacters else { return }

        var trimmed = String(text.suffix(Self.trimTarget))
        // Drop the (now partial) first line so the view never starts
        // mid-token.
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        }
        text = Self.truncationMarker + trimmed
        characterCount = text.count
    }
}
