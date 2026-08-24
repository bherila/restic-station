import Testing

@testable import restic_station_helper

@Suite("legacy capability argv rejection")
struct LegacyCapabilityArgumentsTests {
    @Test(
        "recognizes both retired capability options in attached and separated form",
        arguments: [
            ["helper", "purge", "apply", "--preview-token=CANARY_CAPABILITY_MUST_NOT_BE_REFLECTED"],
            ["helper", "purge", "apply", "--preview-token", "CANARY_CAPABILITY_MUST_NOT_BE_REFLECTED"],
            ["helper", "maintenance", "prune", "--expected-destination=CANARY_CAPABILITY_MUST_NOT_BE_REFLECTED"],
            ["helper", "maintenance", "prune", "--expected-destination", "CANARY_CAPABILITY_MUST_NOT_BE_REFLECTED"],
        ]
    )
    func recognizesLegacyValueBearingOptions(arguments: [String]) {
        #expect(LegacyCapabilityArguments.containsLegacyValueBearingOption(arguments: arguments))
    }

    @Test("does not inspect operands after option separator")
    func ignoresSeparatedOperand() {
        #expect(!LegacyCapabilityArguments.containsLegacyValueBearingOption(
            arguments: ["helper", "restore", "--", "--preview-token=ordinary-operand"]
        ))
    }
}
