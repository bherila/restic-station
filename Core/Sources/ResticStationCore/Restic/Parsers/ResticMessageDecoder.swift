import Foundation

// MARK: - ResticMessage

/// The decoded form of a single NDJSON line streamed by restic in
/// `--json` mode (`backup`, `restore`, `ls`), or of the one-line
/// `exit_error` message any streamed command may emit on stdout.
///
/// This mirrors the enum shape T04 (`docs/tasks/T04-restic-runner.md`)
/// specifies for `ResticRunner`'s NDJSON callback, so T04 can consume
/// ``ResticMessageDecoder`` as-is once it lands. T05 owns both the enum
/// and the decoder; T04 does not redefine either.
public enum ResticMessage: Equatable, Sendable {
    case status(BackupStatus)
    case summary(BackupSummary)
    case exitError(code: Int, message: String)
    case node(LsNode)
    case snapshotHeader(Snapshot)
    case restoreSummary(RestoreSummary)
    /// A line that was empty, not valid JSON, or had an unrecognized/
    /// missing `message_type` (e.g. `error`, `verbose_status`, or a
    /// future message type) — never thrown, always tolerated.
    case unparsed(String)
}

// MARK: - Date decoding

/// restic emits ISO8601 timestamps whose fractional-seconds component
/// varies in precision (absent entirely, milliseconds, microseconds, or
/// nanoseconds — e.g. `"2026-07-26T16:57:01.494355014-04:00"`) and always
/// carries a numeric UTC offset (never bare `Z` in our fixtures, though
/// that is handled too). `ISO8601DateFormatter`'s built-in fractional
/// support only covers a fixed precision, so fractional seconds are
/// parsed manually here: split off the fractional digits (of whatever
/// length) and the trailing timezone, parse the whole-second base with
/// `ISO8601DateFormatter`, then add the fraction as a `TimeInterval`.
/// This is intentionally Linux-safe (pure `Foundation`, no ICU-specific
/// formatting quirks).
enum ResticDate {
    static func date(from string: String) -> Date? {
        guard let dotIndex = string.firstIndex(of: ".") else {
            return wholeSecondFormatter.date(from: string)
        }
        let base = String(string[string.startIndex..<dotIndex])
        let rest = string[string.index(after: dotIndex)...]

        var fracEnd = rest.startIndex
        while fracEnd < rest.endIndex, rest[fracEnd].isNumber {
            fracEnd = rest.index(after: fracEnd)
        }
        let fractionDigits = String(rest[rest.startIndex..<fracEnd])
        let timezoneSuffix = String(rest[fracEnd...])

        guard let baseDate = wholeSecondFormatter.date(from: base + timezoneSuffix) else {
            return nil
        }
        guard !fractionDigits.isEmpty, let fraction = Double("0." + fractionDigits) else {
            return baseDate
        }
        return baseDate.addingTimeInterval(fraction)
    }

    // Recreated per call rather than cached in a `static let`: `ISO8601DateFormatter`
    // is a mutable, non-`Sendable` class, so a shared static instance would be a
    // concurrency hazard under Swift 6 strict-concurrency checking.
    private static var wholeSecondFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

/// Builds a `JSONDecoder` configured for restic's snake_case JSON and the
/// dual (fractional/non-fractional) ISO8601 date formats it emits. Used by
/// every parser in this module so date handling stays in one place.
public func makeResticJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = ResticDate.date(from: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized restic date format: \(string)"
            )
        }
        return date
    }
    return decoder
}

// MARK: - Line decoder

/// Decodes individual NDJSON lines streamed by restic (`backup`,
/// `restore`, `ls`) into ``ResticMessage``. Dispatches on `message_type`.
/// Never throws: any line that is empty, not JSON, missing
/// `message_type`, or whose payload fails to decode against the expected
/// shape becomes `.unparsed(line)`.
public struct ResticMessageDecoder: Sendable {
    private let decoder: JSONDecoder

    public init() {
        self.decoder = makeResticJSONDecoder()
    }

    public func decodeLine(_ line: String) -> ResticMessage {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return .unparsed(line)
        }
        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            let envelope = jsonObject as? [String: Any],
            let messageType = envelope["message_type"] as? String
        else {
            return .unparsed(line)
        }

        switch messageType {
        case "status":
            if let value = try? decoder.decode(BackupStatus.self, from: data) {
                return .status(value)
            }
        case "summary":
            // `backup` and `restore` both emit `message_type: "summary"`
            // with different payloads; `files_restored` only appears on
            // the restore variant.
            if envelope["files_restored"] != nil {
                if let value = try? decoder.decode(RestoreSummary.self, from: data) {
                    return .restoreSummary(value)
                }
            } else if let value = try? decoder.decode(BackupSummary.self, from: data) {
                return .summary(value)
            }
        case "exit_error":
            if let value = try? decoder.decode(ExitErrorMessage.self, from: data) {
                return .exitError(code: value.code, message: value.message)
            }
        case "node":
            if let value = try? decoder.decode(LsNode.self, from: data) {
                return .node(value)
            }
        case "snapshot":
            if let value = try? decoder.decode(Snapshot.self, from: data) {
                return .snapshotHeader(value)
            }
        default:
            // `error`, `verbose_status`, and any future message type:
            // tolerate gracefully per restic-cli.md.
            break
        }
        return .unparsed(line)
    }
}
