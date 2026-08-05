import Foundation
import ResticStationCore

/// The shared `--json` output convention for T27's read-oriented subcommands
/// (`status`, `sets list`, `runs list`, `runs show`, `config show`).
///
/// Two rules, both load-bearing:
///
/// 1. **`--json` output is only JSON on stdout.** No leading/trailing prose,
///    no progress dots — a caller pipes this straight into `jq` (the test
///    suite does exactly that). Anything a subcommand wants to say *about*
///    the JSON (a warning it could not fetch some optional piece of state,
///    for instance) belongs on stderr.
/// 2. **Same encoding convention as everything else this app persists** —
///    `.sortedKeys` + `.prettyPrinted`, ISO 8601 dates with fractional
///    seconds (`ConfigStore.makeEncoder()`). A machine-readable shape that
///    used a different date format than `runs/index.jsonl` would be its own
///    small bug waiting to happen for anyone scripting against both.
enum CLIJSON {
    /// Encodes `value` and writes it to stdout followed by exactly one
    /// newline — nothing else touches stdout in `--json` mode.
    static func print<T: Encodable>(_ value: T) {
        do {
            let data = try ConfigStore.makeEncoder().encode(value)
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
