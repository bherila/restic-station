import ArgumentParser
import Foundation
import ResticStationCore
import Testing

@testable import restic_station_helper

/// The helper half of issue #81's contract. The classification itself is
/// Core's (`CLIErrorTests`); what is tested here is the part only the CLI
/// can get wrong — **which output mode a failure is rendered in**, and the
/// boundary where the answer has to be guessed.
///
/// Asserted off the command tree rather than by shelling out to the built
/// binary, so it behaves identically on macOS and Linux
/// (`SubcommandRegistrationTests` sets the same precedent). The end-to-end
/// behaviour of the built binary is covered by
/// `scripts/headless-cli-test.sh` §8.

@Suite("--json mode detection")
struct JSONModeDetectionTests {

    /// The complete set of `--json`-capable commands, and the same list
    /// `docs/cli-json.md`'s matrix publishes. A new `--json` command that
    /// forgets the `JSONRenderable` conformance shows up here as a missing
    /// entry rather than as silent prose on stdout when it fails.
    ///
    /// `timer status` is deliberately absent — it is Linux-only and
    /// documented as human-only, its machine-readable equivalent being
    /// `status --json`'s `.scheduler` object.
    static let jsonCapable: [[String]] = [
        ["version", "--json"],
        ["status", "--json"],
        ["sets", "list", "--json"],
        ["runs", "list", "--json"],
        ["runs", "show", "some-run-id", "--json"],
        ["config", "show", "--json"],
        ["config", "validate", "--json"],
        [
            "probe-repo", "--set", "00000000-0000-0000-0000-000000000001",
            "--dest", "00000000-0000-0000-0000-000000000002", "--json",
        ],
        ["maintenance", "prune", "--set", "00000000-0000-0000-0000-000000000001", "--json"],
        ["purge", "preview", "--set", "00000000-0000-0000-0000-000000000001", "--json"],
        [
            "purge", "apply", "--set", "00000000-0000-0000-0000-000000000001",
            "--preview-token-stdin", "--json",
        ],
        ["secret", "list", "--json"],
        ["cli", "status", "--json"],
        ["fda-check", "--json"],
    ]

    @Test("every command with a --json flag reports it through JSONRenderable")
    func everyJSONCommandIsRenderable() throws {
        // Parsed rather than constructed: this asserts the flag is actually
        // wired to the protocol, which a hand-built instance would not.
        for argv in Self.jsonCapable {
            let command = try HelperMain.parseAsRoot(argv)
            #expect(
                command is JSONRenderable,
                "\(argv.joined(separator: " ")) has a --json flag but does not conform to JSONRenderable"
            )
            #expect(HelperOutput.wantsJSON(command), "\(argv.joined(separator: " ")) did not report JSON mode")
        }
    }

    @Test("the same commands report human mode without the flag")
    func withoutTheFlagTheyAreHuman() throws {
        for argv in Self.jsonCapable {
            let human = argv.filter { $0 != "--json" }
            let command = try HelperMain.parseAsRoot(human)
            #expect(
                !HelperOutput.wantsJSON(command),
                "\(human.joined(separator: " ")) reported JSON mode without the flag"
            )
        }
    }

    @Test("a command with no --json flag is never treated as JSON-capable")
    func nonJSONCommandsAreHuman() throws {
        let command = try HelperMain.parseAsRoot(["version"])
        #expect(!HelperOutput.wantsJSON(command))
        #expect(!HelperOutput.wantsJSON(nil))
    }
}

@Suite("the argv fallback, used only when parsing produced no command")
struct ArgvFallbackTests {

    @Test("--json anywhere in the flags is honoured")
    func recognisesTheFlag() {
        #expect(HelperOutput.argvRequestsJSON(["helper", "runs", "show", "--json"]))
        #expect(HelperOutput.argvRequestsJSON(["helper", "status", "--json", "--extra"]))
        #expect(!HelperOutput.argvRequestsJSON(["helper", "status"]))
        #expect(!HelperOutput.argvRequestsJSON(["helper"]))
    }

    @Test("argv[0] is never inspected")
    func executableNameIsIgnored() {
        // A binary that happened to live at a path named `--json` would
        // otherwise put every usage error into JSON mode.
        #expect(!HelperOutput.argvRequestsJSON(["--json"]))
        #expect(!HelperOutput.argvRequestsJSON(["/tmp/--json", "status"]))
    }

    @Test("operands after -- are not scanned")
    func separatorEndsTheScan() {
        // A restore `--include` pattern, or any path, spelled `--json`
        // is an operand and must not switch the output mode.
        #expect(!HelperOutput.argvRequestsJSON(["helper", "restore", "--", "--json"]))
        #expect(HelperOutput.argvRequestsJSON(["helper", "status", "--json", "--", "--not-json"]))
    }
}

@Suite("envelope rendering")
struct EnvelopeRenderingTests {

    @Test("the last-resort envelope is itself valid JSON in the documented shape")
    func lastResortEnvelopeIsValid() throws {
        // It exists precisely for the case where the encoder failed, so it
        // cannot be generated by the encoder — which means nothing but a
        // test proves it parses.
        let data = Data(HelperOutput.lastResortEnvelope.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        #expect(object["schemaVersion"] as? Int == CLIErrorEnvelope.schemaVersion)
        let body = try #require(object["error"] as? [String: Any])
        #expect(body["code"] as? String == CLIErrorCode.internalError.rawValue)
        #expect(body["retryable"] as? Bool == false)
    }
}

@Suite("restic-unavailable classification keeps the existing prose")
struct ResticUnavailableWiringTests {

    /// `HelperContext.make()` throws
    /// `CLIFailure.resticUnavailable(result:message:)` with the message
    /// `resticNotFoundMessage` builds, so the human-mode sentence is
    /// unchanged and only the *code* is new.
    ///
    /// Asserted here rather than by running the binary because the branch is
    /// unreachable on a host that has restic installed anywhere
    /// `ResticDiscovery` looks — which is every developer Mac, and is why
    /// CI's own discovery assertions live in the Linux job.
    private static func failure(for result: ResticDiscoveryResult) -> CLIFailure {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/restic-station-test"))
        return .resticUnavailable(
            result: result,
            message: HelperContext.resticNotFoundMessage(paths: paths, result: result)
        )
    }

    @Test("a too-old restic keeps the version-naming message and reports restic_unsupported")
    func tooOld() {
        let result = ResticDiscoveryResult(
            chosen: nil,
            rejected: [ResticProbe(path: "/usr/bin/restic", outcome: .tooOld(version: "0.16.4"))],
            searchedDescription: "PATH"
        )
        let failure = Self.failure(for: result)
        #expect(failure.code == .resticUnsupported)
        // The three things issue #50 requires the message to say. If the
        // wording changes these stay true; if the *wiring* breaks and the
        // message is replaced by a generic one, they do not.
        #expect(failure.message.contains("0.16.4"))
        #expect(failure.message.contains(ResticDiscovery.minimumVersion))
        #expect(!failure.message.contains("restic not found"))
        #expect(failure.details.versionFound == "0.16.4")
    }

    @Test("a restic that ran and is not restic keeps its reason and is not reported as missing")
    func unusable() {
        let result = ResticDiscoveryResult(
            chosen: nil,
            rejected: [ResticProbe(path: "/tmp/restic", outcome: .unusable(reason: "/tmp/restic exited 72."))],
            searchedDescription: "PATH"
        )
        let failure = Self.failure(for: result)
        #expect(failure.code == .resticUnsupported)
        #expect(failure.message.contains("72"))
        #expect(!failure.message.contains("restic not found"))
    }

    @Test("nothing found anywhere is restic_not_found, and says where it looked")
    func notFoundAtAll() {
        let result = ResticDiscoveryResult(
            chosen: nil,
            rejected: [],
            searchedDescription: "/usr/bin/restic and every directory on PATH"
        )
        let failure = Self.failure(for: result)
        #expect(failure.code == .resticNotFound)
        #if os(Linux)
        // The macOS message is the "open Restic Station" one, which is
        // deliberately different and is asserted not to appear on Linux by
        // the workflow's own discovery step.
        #expect(failure.message.contains("restic not found"))
        #expect(failure.message.contains("every directory on PATH"))
        #expect(failure.message.contains("github.com/restic/restic/releases"))
        #endif
    }
}

@Suite("failures classified by the commands themselves")
struct CommandFailureClassificationTests {

    @Test("purge preview preserves local lock failure as non-retryable infrastructure")
    func purgePreviewInfrastructureFailure() {
        let setId = UUID()
        let destination = Destination(
            id: UUID(), label: "Primary", repoURL: "/repo", isPrimary: true
        )
        let result = PurgePlanResult(
            plan: PurgePlan(
                destinationId: destination.id,
                snapshots: [],
                sourcePaths: [],
                hostnames: [],
                patterns: ["build/**"]
            ),
            status: .infrastructureFailure,
            message: "backup-set lock unusable — refused by ownership check"
        )

        do {
            try PurgePreview.validate(result: result, setId: setId, destination: destination)
            Issue.record("expected infrastructure failure")
        } catch let failure as CLIFailure {
            #expect(failure.code == .internalError)
            #expect(!failure.retryable)
            #expect(failure.message.contains("backup-set lock unusable"))
            #expect(failure.details.setId == setId)
            #expect(failure.details.destinationId == destination.id)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(
        "maintenance infrastructure failures do not claim that history alone failed",
        arguments: [
            "backup-set lock unusable — /data/locks/set.lock: refused by file type check",
            "preview-token store unusable — /data/state/preview-tokens.lock: refused by ownership check",
        ]
    )
    func maintenanceInfrastructureFailure(reason: String) {
        let setId = UUID()
        let destinationId = UUID()
        let failure = MaintenancePrune.infrastructureFailure(
            reason: reason,
            setId: setId,
            destinationId: destinationId
        )

        #expect(failure.code == .internalError)
        #expect(failure.message.contains(reason))
        #expect(!failure.message.contains("terminal result"))
        #expect(failure.message.contains("new reclaim preview"))
        #expect(failure.details.setId == setId)
        #expect(failure.details.destinationId == destinationId)
    }

    @Test("maintenance audit failures never recommend a fresh destructive preview")
    func maintenanceAuditFailureGuidance() {
        let failure = MaintenancePrune.infrastructureFailure(
            reason: "operation_completed_audit_failed — repository outcome unknown",
            setId: UUID(),
            destinationId: UUID()
        )

        #expect(failure.code == .operationCompletedAuditFailed)
        #expect(!failure.retryable)
        #expect(failure.message.contains("Inspect the repository"))
        #expect(failure.message.contains("reconcile run history"))
        #expect(!failure.message.contains("new reclaim preview"))
    }

    @Test("a non-positive --limit is invalid_arguments, not an internal error")
    func limitValidation() async throws {
        // `runs list` validates `--limit` by hand rather than through
        // ArgumentParser's `validate()`, precisely so it exits 1 rather than
        // 64 (see the comment at the call site). That makes it the one
        // invalid_arguments case whose exit code is the ordinary one, so it
        // is worth pinning both halves.
        var command = try #require(HelperMain.parseAsRoot(["runs", "list", "--limit", "0"]) as? RunsList)
        await #expect(throws: CLIFailure.invalidArguments("--limit must be positive; got 0")) {
            try await command.run()
        }
        #expect(CLIErrorCode.invalidArguments.exitCode == .error)
    }

    @Test("an unloadable config.json is config_invalid from every --json command")
    func brokenConfigIsClassifiedUniformly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-error-envelope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not valid json{{{".utf8)
            .write(to: directory.appendingPathComponent("config.json"))

        // `AppPaths.default()` reads this, which is how the command under
        // test is pointed at the fixture without a seam of its own. Through
        // ``TestEnvironmentLock`` because the variable is process-global and
        // other suites set it too — parallel tests would otherwise read each
        // other's fixture directory.
        try await TestEnvironmentLock.withDataDirectory(directory.path) {
            // `secret list` is in this list because it reaches its config
            // through `SecretContext.make()`, not `HelperContext.make()` —
            // entering a password has to work before restic is configured — so
            // it had a second setup path with its own `HelperExit.fail` and kept
            // answering a broken config with an empty stdout.
            for argv in [["sets", "list"], ["status"], ["config", "show"], ["secret", "list"]] {
                var command = try #require(HelperMain.parseAsRoot(argv) as? any AsyncParsableCommand)
                do {
                    try await command.run()
                    Issue.record("\(argv.joined(separator: " ")) did not fail on an unloadable config")
                } catch let failure as CLIFailure {
                    #expect(failure.code == .configInvalid)
                    #expect(failure.exitCode == .error)
                    // The message names the file and stays bounded — the
                    // pre-#81 version printed a whole DecodingError description.
                    #expect(failure.message.hasPrefix("could not load configuration:"))
                    #expect(failure.message.count <= CLIFailure.messageCharacterLimit)
                }
            }
        }
    }
}
