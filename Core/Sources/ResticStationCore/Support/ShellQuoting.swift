import Foundation

/// POSIX shell quoting for paths this project *prints as commands*.
///
/// Every user-facing "run this" line — the cron fallback, the `rm` that
/// clears an abandoned run — embeds a path the user chose. Data directories
/// legitimately contain spaces, and a path is not required to avoid `;`,
/// `$(` or a quote character just because it would be inconvenient. A line
/// printed for someone to copy and paste is a line that will be copied and
/// pasted, so it has to survive the shell it lands in.
///
/// Cross-platform on purpose: `SystemdCommand` is Linux-only, and the
/// `rm`-an-abandoned-run advice is printed on both platforms.
public enum ShellQuoting {

    /// Single quotes, with the `'\''` dance, rather than double: inside
    /// single quotes nothing at all is special to `sh` — no `$`, no
    /// backtick, no backslash — and these values are arbitrary user text.
    ///
    /// Values made only of characters that are already literal to `sh` are
    /// left bare, so the common case stays a readable one-liner rather than
    /// a wall of punctuation.
    public static func quoteIfNeeded(_ value: String) -> String {
        guard value.isEmpty || value.contains(where: { !safeCharacters.contains($0) }) else {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Characters that need no quoting in any POSIX shell word. Deliberately
    /// conservative — `~` is excluded because a leading one would be tilde-
    /// expanded, and `%` because a printed command may also pass through
    /// `crontab(5)`, which treats it as a line separator.
    private static let safeCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./:=@,+"
    )
}
