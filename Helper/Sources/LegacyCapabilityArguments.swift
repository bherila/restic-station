import Foundation

/// Redacts the retired token-in-argv spellings before ArgumentParser can
/// reproduce their values in a usage error. This is intentionally not an
/// option declaration, so it never appears in `--help` and can never be a
/// second accepted transport path.
enum LegacyCapabilityArguments {
    static func containsLegacyValueBearingOption(
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        // `--` terminates option parsing. A filename or other operand after
        // it is not a legacy flag and must retain ArgumentParser's normal
        // treatment.
        for argument in arguments.dropFirst().prefix(while: { $0 != "--" }) {
            if argument == "--preview-token"
                || argument.hasPrefix("--preview-token=")
                || argument == "--expected-destination"
                || argument.hasPrefix("--expected-destination=") {
                return true
            }
        }
        return false
    }
}
