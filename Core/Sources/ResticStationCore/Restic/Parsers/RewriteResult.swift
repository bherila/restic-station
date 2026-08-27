import Foundation

/// One snapshot mentioned by `restic rewrite`.
public struct RewriteSnapshot: Equatable, Sendable {
    public let shortID: String
    public let newSnapshotShortID: String?

    public init(shortID: String, newSnapshotShortID: String? = nil) {
        self.shortID = shortID
        self.newSnapshotShortID = newSnapshotShortID
    }
}

/// What `restic rewrite` reported about the number of snapshots it changed.
///
/// restic prints three mutually exclusive summaries, and collapsing any two
/// of them discards safety-relevant information:
///
/// - an explicit count — `modified 2 snapshots` / `would modify 2 snapshots`;
/// - an explicit *nothing* — `no snapshots were modified` /
///   `no snapshots would be modified`, which is what a repeat purge of an
///   already-applied rule emits;
/// - no recognizable summary at all, which means the transcript cannot be
///   trusted to describe what the command did to the repository.
///
/// The first two are both successful, fully described runs. Only the third is
/// untrustworthy. Modelling this as `Int?` conflated "explicitly nothing" with
/// "unreadable", so the *normal second run* of every purge rule was reported
/// as an infrastructure failure — see ``RewriteSummary/nothingModified``.
/// There is deliberately no `Int?` accessor to fall back to: callers switch
/// exhaustively so a future summary form cannot silently read as a failure.
public enum RewriteSummary: Equatable, Sendable {
    /// restic named a count. `0` is only ever reported as
    /// ``nothingModified`` — restic does not print `modified 0 snapshots`.
    case modified(Int)
    /// restic explicitly reported that nothing changed. Semantically a count
    /// of zero, kept distinct so fixtures assert restic's exact wording.
    case nothingModified
    /// No recognized summary line, or two summary lines that disagree. The
    /// transcript does not describe the outcome; treat it as unusable
    /// evidence rather than as zero work.
    case unrecognized
}

/// The useful, stable facts in the human output of `restic rewrite`.
///
/// `rewrite` has no JSON mode.  Keep the parser deliberately narrow: the
/// snapshot header and save/modify phrases are the parts needed to connect a
/// dry-run back to the already parsed snapshot list.  Unknown lines remain
/// available through `rawOutput` and never make parsing fail.
public struct RewriteResult: Equatable, Sendable {
    public let snapshots: [RewriteSnapshot]
    public let summary: RewriteSummary
    public let rawOutput: String

    public init(snapshots: [RewriteSnapshot], summary: RewriteSummary, rawOutput: String) {
        self.snapshots = snapshots
        self.summary = summary
        self.rawOutput = rawOutput
    }

    public var changedShortIDs: Set<String> {
        Set(snapshots.map(\.shortID))
    }
}

/// Parses output captured from a real restic `rewrite` invocation.
///
/// Every phrase matched here is anchored to a captured fixture in
/// `docs/fixtures/` (`rewrite-forget.txt`, `rewrite-dry-run.txt`,
/// `rewrite-noop.txt`, `rewrite-dry-run-noop.txt`) per `docs/restic-cli.md`.
public func parseRewrite(_ output: String) -> RewriteResult {
    let lines = output.components(separatedBy: .newlines)
    var snapshots: [RewriteSnapshot] = []
    var currentShortID: String?
    var summary: RewriteSummary?
    var summariesDisagree = false

    let header = try? NSRegularExpression(pattern: #"^snapshot ([0-9a-f]+) of \["#)
    let saved = try? NSRegularExpression(pattern: #"^saved new snapshot ([0-9a-f]+)$"#)
    let modified = try? NSRegularExpression(pattern: #"^(?:would modify|modified) ([0-9]+) snapshots$"#)

    // restic's two no-op summaries. Exact, anchored strings: a transcript
    // that merely *mentions* one of these phrases mid-line is not a summary.
    let noOpSummaries: Set<String> = [
        "no snapshots were modified",
        "no snapshots would be modified",
    ]

    // A transcript must describe one outcome. Two different summary lines
    // mean the output is not the shape this parser understands, so it is
    // downgraded to `.unrecognized` rather than letting the last line win.
    func record(_ candidate: RewriteSummary) {
        guard let existing = summary else {
            summary = candidate
            return
        }
        if existing != candidate { summariesDisagree = true }
    }

    for line in lines {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if let match = header?.firstMatch(in: line, range: range), match.numberOfRanges > 1,
           let idRange = Range(match.range(at: 1), in: line) {
            currentShortID = String(line[idRange])
            continue
        }

        if line == "would save new snapshot", let currentShortID {
            snapshots.append(RewriteSnapshot(shortID: currentShortID))
            continue
        }

        if let match = saved?.firstMatch(in: line, range: range), match.numberOfRanges > 1,
           let idRange = Range(match.range(at: 1), in: line), let currentShortID {
            snapshots.append(RewriteSnapshot(
                shortID: currentShortID,
                newSnapshotShortID: String(line[idRange])
            ))
            continue
        }

        if noOpSummaries.contains(line) {
            record(.nothingModified)
            continue
        }

        if let match = modified?.firstMatch(in: line, range: range), match.numberOfRanges > 1,
           let countRange = Range(match.range(at: 1), in: line),
           let count = Int(line[countRange]) {
            record(.modified(count))
        }
    }

    return RewriteResult(
        snapshots: snapshots,
        summary: summariesDisagree ? .unrecognized : (summary ?? .unrecognized),
        rawOutput: output
    )
}
