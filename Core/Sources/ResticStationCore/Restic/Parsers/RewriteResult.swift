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

/// The useful, stable facts in the human output of `restic rewrite`.
///
/// `rewrite` has no JSON mode.  Keep the parser deliberately narrow: the
/// snapshot header and save/modify phrases are the parts needed to connect a
/// dry-run back to the already parsed snapshot list.  Unknown lines remain
/// available through `rawOutput` and never make parsing fail.
public struct RewriteResult: Equatable, Sendable {
    public let snapshots: [RewriteSnapshot]
    public let modifiedCount: Int?
    public let rawOutput: String

    public init(snapshots: [RewriteSnapshot], modifiedCount: Int?, rawOutput: String) {
        self.snapshots = snapshots
        self.modifiedCount = modifiedCount
        self.rawOutput = rawOutput
    }

    public var changedShortIDs: Set<String> {
        Set(snapshots.map(\.shortID))
    }
}

/// Parses output captured from a real restic `rewrite` invocation.
public func parseRewrite(_ output: String) -> RewriteResult {
    let lines = output.components(separatedBy: .newlines)
    var snapshots: [RewriteSnapshot] = []
    var currentShortID: String?
    var modifiedCount: Int?

    let header = try? NSRegularExpression(pattern: #"^snapshot ([0-9a-f]+) of \["#)
    let saved = try? NSRegularExpression(pattern: #"^saved new snapshot ([0-9a-f]+)$"#)
    let modified = try? NSRegularExpression(pattern: #"^(?:would modify|modified) ([0-9]+) snapshots$"#)

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

        if let match = modified?.firstMatch(in: line, range: range), match.numberOfRanges > 1,
           let countRange = Range(match.range(at: 1), in: line) {
            modifiedCount = Int(line[countRange])
        }
    }

    return RewriteResult(snapshots: snapshots, modifiedCount: modifiedCount, rawOutput: output)
}
