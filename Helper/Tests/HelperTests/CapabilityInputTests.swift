import Foundation
import ResticStationCore
import Testing

@testable import restic_station_helper

@Suite("bounded canonical capability input")
struct CapabilityInputTests {
    private static let canonical = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    @Test("accepts exactly 43 canonical base64url characters and one final LF")
    func acceptsCanonicalForms() throws {
        #expect(try CapabilityInput.validate(Data(Self.canonical.utf8)) == Self.canonical)
        #expect(try CapabilityInput.validate(Data((Self.canonical + "\n").utf8)) == Self.canonical)
    }

    @Test("rejects noncanonical, malformed, or excess bytes without reflecting input")
    func rejectsInvalidForms() {
        let inputs = [
            "",
            String(repeating: "A", count: 42),
            String(repeating: "A", count: 44),
            Self.canonical + "\n\n",
            String(Self.canonical.dropLast()) + "=",
            String(Self.canonical.dropLast()) + "+",
            String(Self.canonical.dropLast()) + " ",
            String(Self.canonical.dropLast()) + "\r",
            String(Self.canonical.dropLast()) + "B", // decodes but is not canonical for 32 zero bytes
        ]
        for input in inputs {
            do {
                _ = try CapabilityInput.validate(Data(input.utf8))
                Issue.record("expected capability input rejection")
            } catch let failure as CLIFailure {
                #expect(failure.code == .invalidArguments)
                if !input.isEmpty {
                    #expect(!failure.message.contains(input))
                }
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }
}
