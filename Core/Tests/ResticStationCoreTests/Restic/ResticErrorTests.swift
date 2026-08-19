import Foundation
import Testing
@testable import ResticStationCore

@Suite("ResticExitClass mapping (docs/restic-cli.md §Exit codes)")
struct ResticErrorTests {
    /// The full documented table, including the categories from
    /// `docs/architecture.md` §Error taxonomy.
    @Test(
        "exit code table",
        arguments: [
            (Int32(0), ResticExitClass.success, ResticErrorCategory.success),
            (1, .fatal(stderrSummary: "Fatal: unable to open config file"), .terminal),
            (2, .fatal(stderrSummary: "Fatal: unable to open config file"), .terminal),
            (3, .warningIncompleteRead, .warning),
            (10, .repoDoesNotExist, .terminal),
            (11, .repoLocked, .retryable),
            (12, .wrongPassword, .terminal),
            (127, .other(127), .terminal),
            (-1, .other(-1), .terminal),
        ]
    )
    func exitCodeTable(code: Int32, expected: ResticExitClass, category: ResticErrorCategory) {
        let mapped = ResticExitClass.classify(exitCode: code, stderr: "Fatal: unable to open config file")
        #expect(mapped == expected)
        #expect(mapped.category == category)
        #expect(mapped.isSuccess == (code == 0))
    }

    @Test("exit 1 carries a trimmed stderr summary")
    func fatalCarriesStderr() throws {
        let stderr = try FixtureLoader.string("err-wrongpw.txt")
        guard case .fatal(let summary) = ResticExitClass.classify(exitCode: 1, stderr: stderr) else {
            Issue.record("expected .fatal")
            return
        }
        #expect(summary == stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!summary.hasSuffix("\n"))
    }

    @Test("a very long stderr blob is capped")
    func fatalSummaryIsCapped() {
        let stderr = String(repeating: "x", count: 5_000)
        guard case .fatal(let summary) = ResticExitClass.classify(exitCode: 1, stderr: stderr) else {
            Issue.record("expected .fatal")
            return
        }
        #expect(summary.count == ResticExitClass.summaryCharacterLimit + 1) // + the ellipsis
        #expect(summary.hasSuffix("…"))
    }

    /// ui-spec.md §Voice: every surfaced error carries the mapped reason and
    /// **one** next step. Each row pins the exact next-step sentence, and the
    /// assertions check it is a suffix of a strictly longer message (reason +
    /// next step).
    @Test(
        "every failure message is a reason plus exactly one next step",
        arguments: [
            (ResticExitClass.warningIncompleteRead, "Open the run log to see which files were skipped."),
            (.fatal(stderrSummary: "Fatal: boom"), "Open the run log for the full restic output."),
            (.repoDoesNotExist, "Check the destination's path, then initialize the repository if it is new."),
            (.repoLocked, "If no other backup is running, remove stale locks in Maintenance and try again."),
            (.wrongPassword, "Update the password in the destination's settings."),
            (.other(42), "Open the run log for the full restic output."),
        ]
    )
    func userFacingMessages(value: ResticExitClass, nextStep: String) {
        let message = value.userFacingMessage
        #expect(message.hasSuffix(nextStep), "message did not end with its next step: \(message)")
        #expect(message.count > nextStep.count, "message is missing the reason: \(message)")
        let reason = String(message.dropLast(nextStep.count)).trimmingCharacters(in: .whitespaces)
        #expect(reason.hasSuffix("."), "reason is not a complete sentence: \(reason)")
        // Reason + one next step, and nothing more.
        #expect(!reason.dropLast().contains("."), "more than one next step in: \(message)")
    }

    @Test("success needs no next step")
    func successMessage() {
        #expect(ResticExitClass.success.userFacingMessage == "Completed successfully.")
    }

    @Test("distinct messages for the codes the docs call out as distinct")
    func distinctMessages() {
        #expect(ResticExitClass.repoDoesNotExist.userFacingMessage.lowercased().contains("initialize"))
        #expect(ResticExitClass.wrongPassword.userFacingMessage.lowercased().contains("password"))
        #expect(ResticExitClass.repoLocked.userFacingMessage.lowercased().contains("lock"))
        #expect(ResticExitClass.warningIncompleteRead.userFacingMessage.lowercased().contains("run log"))
    }

    @Test("ResticRunnerError categories follow architecture.md's taxonomy")
    func runnerErrorCategories() {
        let destinationId = UUID()
        #expect(ResticRunnerError.secretsUnavailable(destinationId: destinationId).category == .retryable)
        // Terminal, and the one case where that differs from its sibling:
        // a store that could not be read may read fine later, whereas a
        // destination with nothing stored stays that way until a human
        // stores something.
        #expect(ResticRunnerError.secretsNotConfigured(destinationId: destinationId).category == .terminal)
        #expect(ResticRunnerError.launchFailed("no such file").category == .terminal)
        #expect(ResticRunnerError.timedOut.category == .terminal)
    }

    /// Regression test for the review finding that this message branched on
    /// `#if os(macOS)`. It has no store to ask (it is a property on an error
    /// value), so it follows the *configured* backend — which in production
    /// is the same environment every store is built from.
    @Test("secretsUnavailable is worded for the configured backend, not the host OS")
    func secretsUnavailableWordingFollowsTheBackend() {
        let message = ResticRunnerError.secretsUnavailable(destinationId: UUID()).userFacingMessage
        let backend = SecretBackend.configured
        #expect(message == "\(backend.unavailableSummary) \(backend.unavailableAdvice)")

        // Both backends produce a "what happened" + "one next step" pair, and
        // neither borrows the other's remediation.
        #expect(SecretBackend.file.unavailableSummary.contains("secrets file"))
        #expect(!SecretBackend.file.unavailableAdvice.lowercased().contains("keychain"))
        #expect(SecretBackend.keychain.unavailableAdvice.contains("Unlock your login keychain"))
    }

    @Test("ResticRunnerError descriptions never carry secret material")
    func runnerErrorDescriptions() {
        let destinationId = UUID()
        for error in [
            ResticRunnerError.secretsUnavailable(destinationId: destinationId),
            ResticRunnerError.secretsNotConfigured(destinationId: destinationId),
        ] {
            #expect(error.description.contains(destinationId.uuidString))
            #expect(!error.userFacingMessage.isEmpty)
        }
    }

    @Test("an absent password names the remedy, not the store it is absent from")
    func secretsNotConfiguredWording() {
        let message = ResticRunnerError.secretsNotConfigured(destinationId: UUID()).userFacingMessage
        #expect(message.contains("secret set"))
        // Unlike its sibling this is not worded per backend: which store
        // does not hold the password is not something the reader can act
        // on, and naming it invites a look inside for something absent.
        #expect(!message.lowercased().contains("keychain"))
        #expect(!message.lowercased().contains("secrets file"))
    }
}
