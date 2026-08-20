import Foundation
import ResticStationCore

/// The one path that owns stdout in `--json` mode, for every subcommand
/// (`docs/cli-json.md`, issues #29/#79/#81).
///
/// Three rules, all load-bearing:
///
/// 1. **`--json` output is only JSON on stdout.** No leading/trailing prose,
///    no progress dots — a caller pipes this straight into `jq` (the test
///    suite does exactly that). Anything a subcommand wants to say *about*
///    the JSON (a warning it could not fetch some optional piece of state,
///    for instance) belongs on stderr.
/// 2. **Every payload is wrapped in ``CLISuccessEnvelope``.** Commands hand
///    over their own shape and this adds `schemaVersion`/`ok`/`data`, which
///    is what stops the envelope from being something each command has to
///    remember — and what makes success and failure the same three top-level
///    keys. A command therefore cannot opt out by accident; `config export`,
///    which must emit a bare config document, deliberately does not come
///    through here at all.
/// 3. **Same encoding convention as everything else this app persists** —
///    `.sortedKeys` + `.prettyPrinted`, ISO 8601 dates with fractional
///    seconds (`ConfigStore.makeEncoder()`). A machine-readable shape that
///    used a different date format than `runs/index.jsonl` would be its own
///    small bug waiting to happen for anyone scripting against both.
enum CLIJSON {
    /// Wraps `value` in the success envelope, encodes it, and writes it to
    /// stdout followed by exactly one newline — nothing else touches stdout
    /// in `--json` mode.
    static func print<T: Encodable>(_ value: T) {
        do {
            let data = try ConfigStore.makeEncoder().encode(CLISuccessEnvelope(value))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            // Encoding one of these value types failing is a programmer
            // error (they are plain Codable structs of strings/numbers/
            // dates), not a runtime condition — but even here nothing but
            // JSON may reach stdout, so the failure goes to stderr and the
            // process exits 1 rather than emitting half a JSON document.
            HelperExit.fail("could not encode JSON output: \(error)")
        }
    }
}
