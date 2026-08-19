import ArgumentParser
import Foundation
import ResticStationCore

// MARK: - JSONRenderable

/// Conformed by every subcommand that has a `--json` flag.
///
/// It exists so the failure path can ask the *parsed command itself*
/// whether the caller wants JSON, rather than guessing from `CommandLine`.
/// That distinction is the whole reason `--json somefile` cannot make a
/// human-mode command start emitting envelopes — see
/// ``HelperOutput/argvRequestsJSON(_:)`` for the one case where guessing is
/// unavoidable.
///
/// #79 conforms the remaining inspection and probe commands as it gives
/// them their own `--json`.
protocol JSONRenderable {
    var json: Bool { get }
}

// MARK: - HelperOutput

/// Where a classified failure becomes bytes.
///
/// Both output modes consume the same ``CLIFailure``, which is what keeps
/// them from drifting apart in what they classify: the JSON envelope and
/// the human sentence are two renderings of one value, never two
/// independently maintained descriptions of one condition.
enum HelperOutput {

    /// Writes `failure` in the requested mode and exits.
    ///
    /// - Parameter exitCode: Overrides the code implied by
    ///   ``CLIFailure/exitCode``. Used for argument-parser failures, which
    ///   must keep exiting `EX_USAGE` (64) exactly as they do today — the
    ///   envelope's job is to *describe* the existing exit contract, not to
    ///   redefine it, so human and JSON mode always agree on the code.
    static func renderFailure(_ failure: CLIFailure, json: Bool, exitCode: Int32? = nil) -> Never {
        let code = exitCode ?? failure.exitCode.rawValue
        if json {
            writeEnvelope(failure)
        } else {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
        }
        exit(code)
    }

    /// Emits exactly one JSON document on stdout.
    ///
    /// The fallback matters: "stdout always parses as one JSON document on a
    /// handled failure" is an acceptance criterion, and a caller that has
    /// already committed to `jq` cannot recover from half a document. So an
    /// encoding failure — which for a struct of strings and integers would
    /// be a programmer error — still produces a valid envelope rather than
    /// nothing.
    private static func writeEnvelope(_ failure: CLIFailure) {
        let data: Data
        do {
            data = try ConfigStore.makeEncoder().encode(CLIErrorEnvelope(failure))
        } catch {
            data = Data(Self.lastResortEnvelope.utf8)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// Hand-written so it cannot itself fail to encode.
    static let lastResortEnvelope = """
        {
          "schemaVersion" : \(CLIErrorEnvelope.schemaVersion),
          "ok" : false,
          "error" : {
            "code" : "\(CLIErrorCode.internalError.rawValue)",
            "message" : "The error could not be encoded.",
            "retryable" : false
          }
        }
        """

    // MARK: - Deciding the mode

    /// The authority for a failure that happened *after* parsing: the
    /// command the user actually invoked.
    static func wantsJSON(_ command: ParsableCommand?) -> Bool {
        (command as? JSONRenderable)?.json ?? false
    }

    /// The fallback for a failure that happened *during* parsing, where
    /// there is no command to ask.
    ///
    /// **This is the documented boundary of the contract**
    /// (`docs/cli-json.md` §Argument-parser failures). Scanning argv is a
    /// guess: a value that happens to be the literal string `--json` would
    /// be counted, and a command with no `--json` flag at all would still
    /// get an envelope for its usage error. Both are accepted deliberately,
    /// because the alternative — staying silent on stdout — is the exact
    /// failure #81 exists to remove, and because a caller who typed
    /// `--json` has already said which shape it can parse.
    ///
    /// Everything after a `--` separator is ignored: those are operands, not
    /// flags, so a path or pattern spelled `--json` cannot reach this.
    static func argvRequestsJSON(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.dropFirst().prefix { $0 != "--" }.contains("--json")
    }
}
