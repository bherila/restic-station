import Foundation

/// The part of a sync folder that synchronization covers: everything the
/// set's backup covers, as far as that can be decided from a relative path
/// alone (#202).
///
/// A path the set's backup excludes, such as a `__pycache__` the global
/// catalogue names, is outside the sync scope. It is not copied, not
/// counted as a conflict, and never deleted, so a regenerated cache that
/// differs between the copies no longer blocks every sync. Without this,
/// the plan would copy such a file, its protection backup would leave it
/// out, and verification would refuse the whole operation, correctly but
/// forever.
///
/// **Only decidable patterns narrow the scope.** A pattern this type cannot
/// match exactly as restic does (anchored, negated, using environment
/// variables, character classes or escapes) is ignored, which keeps that
/// path in scope: the pre-#202 behavior, where protection verification
/// refuses an excluded payload. Any negation disables the scope entirely,
/// because a later `!pattern` can re-include what an earlier one excluded.
/// `--exclude-caches`, `--exclude-larger-than` and online-only files are not
/// expressible as a path pattern, so they keep that behavior too.
/// Verification remains the final authority: a mismatch here can only
/// refuse, never drop protection silently.
///
/// **Matching uses only the components below the sync root.** restic tests a
/// relative pattern against every run of components of an item's absolute
/// path. A run inside the relative path is also inside the live path and the
/// protection vault's path, so whatever this type excludes, both backups
/// exclude. A pattern that needs a component above the root to match is not
/// applied here, which again keeps the path in scope.
public struct SyncScope: Codable, Equatable, Sendable {
    /// Case-sensitive, as restic's `--exclude`.
    public var patterns: [String]
    /// Case-insensitive, as restic's `--iexclude`.
    public var caseInsensitivePatterns: [String]

    public init(patterns: [String] = [], caseInsensitivePatterns: [String] = []) {
        self.patterns = patterns
        self.caseInsensitivePatterns = caseInsensitivePatterns
    }

    /// Covers every path: what an operation journaled before #202 used.
    public static let everything = SyncScope()

    public var isEverything: Bool { patterns.isEmpty && caseInsensitivePatterns.isEmpty }

    /// The scope matching what this set's ordinary backup excludes on this
    /// host: the same `--exclude` and `--iexclude` lists `BackupEngine`
    /// passes, after the catalogue patterns that would swallow a source
    /// have been held back.
    public static func backupScope(of set: BackupSet, applying plan: GlobalExcludePlan) -> SyncScope {
        let exact = set.effectiveBackupExcludes + set.hostBackupExcludes(applying: plan)
        let folded = set.globalBackupExcludes(applying: plan)
        guard !(exact + folded).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("!") }) else {
            return .everything
        }
        return SyncScope(patterns: unique(exact.filter(isDecidable)), caseInsensitivePatterns: unique(folded.filter(isDecidable)))
    }

    /// Whether the set's backup excludes this relative path, or a directory
    /// above it within the sync folder.
    public func excludes(_ relativePath: String) -> Bool {
        patterns.contains { GlobalExcludeAncestorSafety.matchesSourceOrAncestor(pattern: $0, sourcePath: relativePath, caseInsensitive: false) }
            || caseInsensitivePatterns.contains { GlobalExcludeAncestorSafety.matchesSourceOrAncestor(pattern: $0, sourcePath: relativePath, caseInsensitive: true) }
    }

    /// A relative glob of literal components, `*`, `?` and `**`, which
    /// `GlobalExcludeAncestorSafety` matches the way restic does.
    static func isDecidable(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, pattern == pattern.trimmingCharacters(in: .whitespacesAndNewlines),
              !pattern.hasPrefix("/"), !pattern.hasSuffix("/"),
              !pattern.contains(where: { "!$~\\[]{}\0".contains($0) }) else { return false }
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
