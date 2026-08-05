import Foundation
import Testing

@testable import restic_station_helper

/// Unit coverage for the pure parts of the `secret` subcommands — the stdin
/// handling, the `set-env` parser, and the `list` renderer.
///
/// The end-to-end behaviour (real binary, real `secrets.json`, real restic
/// authenticating through `RESTIC_PASSWORD_COMMAND`) is
/// `scripts/secret-cli-test.sh`, which is what actually asserts on the
/// process's stdout bytes; these tests pin the logic that script exercises.
@Suite("secret CLI")
struct SecretCommandTests {

    // MARK: - stdin

    @Test("exactly one trailing newline is stripped, never more")
    func stripsExactlyOneNewline() {
        #expect(SecretInput.stripOneTrailingNewline("hunter2\n") == "hunter2")
        #expect(SecretInput.stripOneTrailingNewline("hunter2") == "hunter2")
        // `echo` adds one; a password that genuinely ends in a newline keeps
        // the rest.
        #expect(SecretInput.stripOneTrailingNewline("hunter2\n\n") == "hunter2\n")
        #expect(SecretInput.stripOneTrailingNewline("\n") == "")
        // Interior newlines and trailing spaces are part of the password.
        #expect(SecretInput.stripOneTrailingNewline("two\nlines\n") == "two\nlines")
        #expect(SecretInput.stripOneTrailingNewline("trailing space \n") == "trailing space ")
    }

    // MARK: - set-env parsing

    @Test("a JSON object of strings parses")
    func parsesStringObject() throws {
        let env = try SecretEnvInput.parse(#"{"AWS_ACCESS_KEY_ID":"AKIA123","AWS_SECRET_ACCESS_KEY":"shh"}"#)
        #expect(env == ["AWS_ACCESS_KEY_ID": "AKIA123", "AWS_SECRET_ACCESS_KEY": "shh"])
    }

    @Test("surrounding whitespace and a trailing newline are tolerated")
    func toleratesWhitespace() throws {
        let env = try SecretEnvInput.parse("  {\"A\":\"1\"}\n")
        #expect(env == ["A": "1"])
    }

    @Test("an empty object is a legitimate 'no secret env'")
    func parsesEmptyObject() throws {
        #expect(try SecretEnvInput.parse("{}").isEmpty)
    }

    @Test("empty stdin is rejected with a message that shows the expected shape")
    func rejectsEmptyInput() {
        #expect(throws: SecretEnvInput.ParseError.self) {
            _ = try SecretEnvInput.parse("   \n")
        }
    }

    @Test("a non-object is rejected, naming the kind it got")
    func rejectsNonObject() {
        for (input, kind) in [(#"["a","b"]"#, "array"), (#""just a string""#, "string"), ("42", "number")] {
            do {
                _ = try SecretEnvInput.parse(input)
                Issue.record("expected \(input) to be rejected")
            } catch let error as SecretEnvInput.ParseError {
                #expect(error.message.contains(kind), "message was: \(error.message)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test("a non-string value is rejected, naming the variable but never a value")
    func rejectsNonStringValues() {
        do {
            _ = try SecretEnvInput.parse(#"{"OK":"yes","PORT":9000}"#)
            Issue.record("expected a numeric value to be rejected")
        } catch let error as SecretEnvInput.ParseError {
            #expect(error.message.contains("PORT"))
            #expect(error.message.contains("must be JSON strings"))
            // The *other* variable's value must not leak into the diagnostic.
            #expect(!error.message.contains("yes"))
            #expect(!error.message.contains("9000"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("invalid JSON is rejected without echoing the input back")
    func rejectsInvalidJSON() {
        do {
            _ = try SecretEnvInput.parse(#"{"AWS_SECRET_ACCESS_KEY": "super-secret"#)
            Issue.record("expected invalid JSON to be rejected")
        } catch let error as SecretEnvInput.ParseError {
            #expect(error.message == "stdin is not valid JSON")
            #expect(!error.message.contains("super-secret"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - list rendering

    static let destId = UUID(uuidString: "A1B2C3D4-E5F6-4789-A012-3456789ABCDE")!
    static let otherId = UUID(uuidString: "B1B2C3D4-E5F6-4789-A012-3456789ABCDE")!

    @Test("list shows only destinations that have something stored")
    func listsOnlyDestinationsWithSecrets() {
        let lines = SecretListing.format([
            .init(destId: Self.destId, label: "Primary", setName: "Docs",
                  hasPassword: true, secretEnvCount: 0),
            .init(destId: Self.otherId, label: "Nothing here", setName: "Docs",
                  hasPassword: false, secretEnvCount: 0),
        ])
        #expect(lines.count == 1)
        #expect(lines[0].contains("a1b2c3d4-e5f6-4789-a012-3456789abcde"))
        #expect(lines[0].contains("Primary"))
        #expect(lines[0].contains("password"))
        #expect(!lines.joined().contains("Nothing here"))
    }

    @Test("list reports secret-env counts, never names or values")
    func listReportsCountsOnly() {
        let lines = SecretListing.format([
            .init(destId: Self.destId, label: "R2 mirror", setName: "Docs",
                  hasPassword: true, secretEnvCount: 2),
        ])
        #expect(lines[0].contains("secret-env (2 variable(s))"))
        #expect(!lines[0].contains("AWS"))
    }

    @Test("an empty store says so rather than printing nothing")
    func listOnEmptyStore() {
        let lines = SecretListing.format([
            .init(destId: Self.destId, label: "Primary", setName: "Docs",
                  hasPassword: false, secretEnvCount: 0),
        ])
        #expect(lines == ["no destination has a stored password or secret environment"])
    }

    /// The output is built only from ids, labels, set names and counts — the
    /// renderer is never handed a secret at all, which is the structural
    /// reason `secret list` cannot print one.
    @Test("no secret value can reach list output, by construction")
    func listCannotPrintSecrets() {
        let rows = [
            SecretListing.Row(destId: Self.destId, label: "Primary", setName: "Docs",
                              hasPassword: true, secretEnvCount: 3),
            SecretListing.Row(destId: Self.otherId, label: "Mirror", setName: "Docs",
                              hasPassword: true, secretEnvCount: 0),
        ]
        let output = SecretListing.format(rows).joined(separator: "\n")
        for forbidden in ["hunter2", "AKIA", "super-secret"] {
            #expect(!output.contains(forbidden))
        }
    }
}
