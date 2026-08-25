import Foundation
import Testing
@testable import ResticStationCore

// The published `--json` error contract (issue #81, `docs/cli-json.md`).
//
// Two properties are worth more than the individual cases here:
//
//  1. **Every code is reachable from a real typed error.** A code nothing
//     can produce is worse than a missing one — it invites a caller to
//     branch on a case that will never arrive. `everyCodeIsReachable` below
//     is what keeps the enum honest as errors are added and removed.
//  2. **Nothing unbounded reaches the wire.** The failure this contract
//     replaces printed a whole `DecodingError` description, quoted bytes and
//     all. `boundedMessages` pins the cap.

private let setId = UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA")!
private let destId = UUID(uuidString: "0A1B2C3D-4E5F-4A1B-8C1D-000000000001")!

/// One representative failure per code, built from an *injected typed
/// error* wherever a typed error exists — never by constructing the code
/// directly, which would assert nothing about the mapping.
private let representative: [CLIErrorCode: CLIFailure] = [
    .invalidArguments: .invalidArguments("--limit must be positive; got 0"),
    .configInvalid: .configInvalid(underlying: ConfigError.emptySources(setId: setId)),
    .setNotFound: .setNotFound(setId: setId),
    .setDisabledHere: .setDisabledHere(setId: setId, machineId: "linux-nas"),
    .destinationNotFound: .destinationNotFound(setId: setId, destinationId: destId),
    .destinationDisabledHere: .destinationDisabledHere(
        setId: setId, destinationId: destId, machineId: "linux-nas"
    ),
    .runNotFound: .runNotFound(runId: "20260819T000000Z-backup-00000000"),
    .setBusy: .setBusy(setId: setId),
    .repositoryLocked: .classify(exitClass: .repoLocked),
    .repositoryNotInitialized: .classify(exitClass: .repoDoesNotExist),
    .secretUnavailable: .classify(SecretStoreError.backendFailed("security: SecKeychainSearchCopyNext: user canceled")),
    .secretNotConfigured: .classify(SecretStoreError.itemNotFound),
    .secretRejected: .classify(exitClass: .wrongPassword),
    .resticNotFound: .resticUnavailable(
        result: ResticDiscoveryResult(chosen: nil, rejected: [], searchedDescription: "PATH"),
        message: "restic not found. Searched PATH."
    ),
    .resticUnsupported: .resticUnavailable(
        result: ResticDiscoveryResult(
            chosen: nil,
            rejected: [ResticProbe(path: "/usr/bin/restic", outcome: .tooOld(version: "0.16.4"))],
            searchedDescription: "PATH"
        ),
        message: "restic 0.16.4 at /usr/bin/restic is too old."
    ),
    .resticFailed: .classify(exitClass: .fatal(stderrSummary: "repository is damaged")),
    .operationTimedOut: .classify(ResticRunnerError.timedOut),
    .previewExpired: .classifyPurgeOperation(PurgeApplyError.token(.expired), setId: setId),
    .operationCompletedAuditFailed: .classifyPurgeOperation(
        PurgeApplyError.infrastructureFailure(reason: "terminal audit persistence failed", operationMayHaveRun: true),
        setId: setId
    ),
    .internalError: .classify(ConfigStoreError.renameFailed(errno: 13, from: "a", to: "b")),
    // `repositoryOffline` is a `Reachability` result rather than an Error,
    // so this representative remains direct. `operationNotAllowed` is also
    // reachable from `PurgeApplyError`, but stays direct here because the
    // public code-table test deliberately does not import an engine fixture.
    .repositoryOffline: CLIFailure(
        code: .repositoryOffline,
        message: "The destination did not answer.",
        details: CLIErrorDetails(destinationId: destId)
    ),
    .operationNotAllowed: CLIFailure(
        code: .operationNotAllowed,
        message: "Refusing to forget with an empty retention policy."
    ),
]

@Suite("CLI error contract")
struct CLIErrorContractTests {

    @Test("every code has a representative failure that maps back to it")
    func everyCodeIsReachable() throws {
        for code in CLIErrorCode.allCases {
            let failure = try #require(
                representative[code],
                "\(code.rawValue) has no representative failure — map it from a typed error or delete the case"
            )
            #expect(failure.code == code)
        }
    }

    @Test("raw values are the published names and never change")
    func rawValuesArePinned() {
        // Spelled out rather than derived: this is the wire contract, and a
        // test that computed it from the enum would pass through a rename.
        #expect(CLIErrorCode.invalidArguments.rawValue == "invalid_arguments")
        #expect(CLIErrorCode.configInvalid.rawValue == "config_invalid")
        #expect(CLIErrorCode.setNotFound.rawValue == "set_not_found")
        #expect(CLIErrorCode.setDisabledHere.rawValue == "set_disabled_here")
        #expect(CLIErrorCode.destinationNotFound.rawValue == "destination_not_found")
        #expect(CLIErrorCode.destinationDisabledHere.rawValue == "destination_disabled_here")
        #expect(CLIErrorCode.runNotFound.rawValue == "run_not_found")
        #expect(CLIErrorCode.setBusy.rawValue == "set_busy")
        #expect(CLIErrorCode.repositoryOffline.rawValue == "repository_offline")
        #expect(CLIErrorCode.repositoryLocked.rawValue == "repository_locked")
        #expect(CLIErrorCode.repositoryNotInitialized.rawValue == "repository_not_initialized")
        #expect(CLIErrorCode.secretUnavailable.rawValue == "secret_unavailable")
        #expect(CLIErrorCode.secretRejected.rawValue == "secret_rejected")
        #expect(CLIErrorCode.secretNotConfigured.rawValue == "secret_not_configured")
        #expect(CLIErrorCode.resticNotFound.rawValue == "restic_not_found")
        #expect(CLIErrorCode.resticUnsupported.rawValue == "restic_unsupported")
        #expect(CLIErrorCode.resticFailed.rawValue == "restic_failed")
        #expect(CLIErrorCode.operationTimedOut.rawValue == "operation_timed_out")
        #expect(CLIErrorCode.previewExpired.rawValue == "preview_expired")
        #expect(CLIErrorCode.operationNotAllowed.rawValue == "operation_not_allowed")
        #expect(CLIErrorCode.operationCompletedAuditFailed.rawValue == "operation_completed_audit_failed")
        #expect(CLIErrorCode.internalError.rawValue == "internal_error")
        #expect(CLIErrorCode.allCases.count == 22)
    }

    @Test("only busy and offline leave exit 1 — the coarse shell contract is unchanged")
    func exitCodeMapping() {
        for code in CLIErrorCode.allCases {
            switch code {
            case .setBusy:
                #expect(code.exitCode == .busy)
            case .repositoryOffline:
                #expect(code.exitCode == .offline)
            default:
                #expect(code.exitCode == .error, "\(code.rawValue) must not invent a new exit code")
            }
        }
    }

    @Test("retryable means 'try again unchanged', so a wrong password is not retryable")
    func retryability() {
        #expect(CLIErrorCode.setBusy.retryable)
        #expect(CLIErrorCode.repositoryOffline.retryable)
        #expect(CLIErrorCode.repositoryLocked.retryable)
        #expect(!CLIErrorCode.setNotFound.retryable)
        #expect(!CLIErrorCode.configInvalid.retryable)
        #expect(!CLIErrorCode.internalError.retryable)
        // restic exit 12: the secret is present and does not open the repo.
        // Retrying byte-for-byte can only fail again — which is why it is
        // `secret_rejected` and not `secret_unavailable`.
        let rejected = CLIFailure.classify(exitClass: .wrongPassword)
        #expect(rejected.code == .secretRejected)
        #expect(!rejected.retryable)
        #expect(CLIErrorCode.secretUnavailable.retryable)
        #expect(!CLIErrorCode.previewExpired.retryable)
        // And a destination whose password was never stored: the backend
        // answered, the answer will not change on its own, and a caller
        // told `retryable: true` would loop until a human runs `secret set`.
        let missing = CLIFailure.classify(SecretStoreError.itemNotFound)
        #expect(missing.code == .secretNotConfigured)
        #expect(!missing.retryable)
    }

    @Test("purge token refusals use safe, actionable envelope codes")
    func purgeTokenClassification() {
        let expired = CLIFailure.classifyPurgeOperation(PurgeApplyError.token(.expired), setId: setId)
        #expect(expired.code == .previewExpired)
        #expect(expired.details.setId == setId)
        #expect(!expired.retryable)

        let stale = CLIFailure.classifyPurgeOperation(PurgeApplyError.tokenDoesNotMatchCurrentPlan, setId: setId)
        #expect(stale.code == .operationNotAllowed)
        #expect(stale.details.setId == setId)
        #expect(!stale.message.contains("token"), "capabilities never appear in an envelope")

        let didNotRun = CLIFailure.classifyPurgeApply(
            PurgeApplyError.infrastructureFailure(
                reason: "run history unusable",
                operationMayHaveRun: false
            ),
            setId: setId
        )
        #expect(didNotRun.code == .internalError)
        #expect(!didNotRun.retryable)
        #expect(didNotRun.message.contains("did not run destructive work"))
        #expect(!didNotRun.message.contains("backup-set lock"))

        let mayHaveRun = CLIFailure.classifyPurgeApply(
            PurgeApplyError.infrastructureFailure(
                reason: "run history unusable",
                operationMayHaveRun: true
            ),
            setId: setId
        )
        #expect(mayHaveRun.code == .operationCompletedAuditFailed)
        #expect(!mayHaveRun.retryable)
        #expect(mayHaveRun.message.contains("may have changed repository data"))
        #expect(mayHaveRun.message.contains("Inspect the repositories before retrying"))
        #expect(!mayHaveRun.message.contains("backup-set lock"))

        let blockedByPriorAuditFailure = CLIFailure.classifyPurgeApply(
            PurgeApplyError.infrastructureFailure(
                reason: "operation_completed_audit_failed — prior destructive run needs inspection",
                operationMayHaveRun: false
            ),
            setId: setId
        )
        #expect(blockedByPriorAuditFailure.code == .operationCompletedAuditFailed)
        #expect(!blockedByPriorAuditFailure.retryable)
        #expect(blockedByPriorAuditFailure.message.contains("blocked by an earlier destructive operation"))
    }
}

@Suite("the published code table")
struct CLIErrorDocumentationTests {

    /// `docs/cli-json.md` is normative and is what callers read. A code that
    /// exists and is undocumented is as bad as one that is documented and
    /// does not exist, and neither shows up in any other test — the doc is
    /// prose that nothing else in the build ever reads.
    ///
    /// Located from `#filePath` rather than from the test bundle: the doc is
    /// a repo file, not a test resource, and this works identically on both
    /// platforms. Precedent: `ModelsTests.dataModelExampleConfigJSON`
    /// decodes `docs/data-model.md`'s example verbatim for the same reason.
    private static var codeTable: String {
        get throws {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // …/Support
                .deletingLastPathComponent()   // …/ResticStationCoreTests
                .deletingLastPathComponent()   // …/Tests
                .deletingLastPathComponent()   // …/Core
                .deletingLastPathComponent()   // repo root
            let doc = repoRoot.appendingPathComponent("docs/cli-json.md")
            return try String(contentsOf: doc, encoding: .utf8)
        }
    }

    @Test("every code has a row in docs/cli-json.md")
    func everyCodeIsDocumented() throws {
        let table = try Self.codeTable
        for code in CLIErrorCode.allCases {
            #expect(
                table.contains("| `\(code.rawValue)` |"),
                "\(code.rawValue) has no row in the docs/cli-json.md code table"
            )
        }
    }

    @Test("the documented retryability and exit code match the implementation")
    func documentedFlagsMatch() throws {
        let table = try Self.codeTable
        for code in CLIErrorCode.allCases {
            let row = try #require(
                table.split(separator: "\n").first { $0.hasPrefix("| `\(code.rawValue)` |") },
                "\(code.rawValue) has no row to check"
            )
            let columns = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            // | code | retryable | exit | meaning |
            let documentedRetryable = columns[1].contains("yes")
            #expect(
                documentedRetryable == code.retryable,
                "\(code.rawValue): docs say retryable=\(documentedRetryable), code says \(code.retryable)"
            )
            #expect(
                columns[2].contains(String(code.exitCode.rawValue)),
                "\(code.rawValue): docs say exit \(columns[2]), code says \(code.exitCode.rawValue)"
            )
        }
    }

    @Test("the table documents no code that does not exist")
    func noPhantomCodes() throws {
        let known = Set(CLIErrorCode.allCases.map(\.rawValue))
        for line in try Self.codeTable.split(separator: "\n") where line.hasPrefix("| `") {
            let name = line.dropFirst(3).prefix { $0 != "`" }
            // Skip the `details` table, whose first column is a key name.
            guard name.contains("_") else { continue }
            #expect(
                known.contains(String(name)),
                "docs/cli-json.md documents \(name), which is not a CLIErrorCode"
            )
        }
    }
}

@Suite("CLI error mapping from typed errors")
struct CLIErrorMappingTests {

    @Test("a newer-schema config reports the versions rather than only prose")
    func newerVersionCarriesVersions() {
        let failure = CLIFailure.configInvalid(
            underlying: ConfigError.newerVersion(found: 9, supported: AppConfig.currentVersion)
        )
        #expect(failure.code == .configInvalid)
        #expect(failure.details.versionFound == "9")
        #expect(failure.details.versionSupported == String(AppConfig.currentVersion))
        // Classified *and* still prefixed. The prefix is what the
        // `HelperExit.fail` call sites this replaced printed, and it is the
        // only thing in the envelope that says which of the two files
        // `config_invalid` covers actually failed.
        #expect(failure.message.hasPrefix("could not load configuration:"))
    }

    @Test("every config-load failure names the file, typed or not")
    func configLoadFailuresKeepTheirContext() {
        // A `ConfigError` took an early return that skipped the prefix,
        // so the two arms of the same call disagreed about whether the
        // message identified `config.json` at all.
        let typed = CLIFailure.configInvalid(underlying: ConfigError.emptySources(setId: setId))
        #expect(typed.code == .configInvalid)
        #expect(typed.message.hasPrefix("could not load configuration:"))
        #expect(typed.message.contains(ConfigError.emptySources(setId: setId).description))

        let untyped = CLIFailure.configInvalid(underlying: ConfigStoreError.renameFailed(errno: 13, from: "a", to: "b"))
        #expect(untyped.code == .configInvalid)
        #expect(untyped.message.hasPrefix("could not load configuration:"))
    }

    @Test("restic exit codes map to their repository meanings, with the raw code kept")
    func resticExitClasses() {
        let locked = CLIFailure.classify(exitClass: .repoLocked, destinationId: destId)
        #expect(locked.code == .repositoryLocked)
        #expect(locked.details.resticExitCode == 11)
        #expect(locked.details.destinationId == destId)

        let missing = CLIFailure.classify(exitClass: .repoDoesNotExist)
        #expect(missing.code == .repositoryNotInitialized)
        #expect(missing.details.resticExitCode == 10)

        let odd = CLIFailure.classify(exitClass: .other(77))
        #expect(odd.code == .resticFailed)
        #expect(odd.details.resticExitCode == 77)
    }

    @Test("classifying a success is an internal error, not a plausible-looking code")
    func successIsNotAFailure() {
        // Guards against a future caller passing every outcome through
        // `classify` and getting a confident wrong answer for the good ones.
        #expect(CLIFailure.classify(exitClass: .success).code == .internalError)
        #expect(CLIFailure.classify(exitClass: .warningIncompleteRead).code == .internalError)
    }

    @Test("a failed restic search separates 'not installed' from 'installed but unusable'")
    func resticDiscoveryClassification() {
        let absent = CLIFailure.resticUnavailable(
            result: ResticDiscoveryResult(chosen: nil, rejected: [], searchedDescription: "PATH"),
            message: "restic not found."
        )
        #expect(absent.code == .resticNotFound)
        #expect(absent.details.versionFound == nil)

        let tooOld = CLIFailure.resticUnavailable(
            result: ResticDiscoveryResult(
                chosen: nil,
                rejected: [ResticProbe(path: "/usr/bin/restic", outcome: .tooOld(version: "0.16.4"))],
                searchedDescription: "PATH"
            ),
            message: "too old"
        )
        #expect(tooOld.code == .resticUnsupported)
        #expect(tooOld.details.versionFound == "0.16.4")
        #expect(tooOld.details.versionSupported == ResticDiscovery.minimumVersion)

        // Found, ran, exited 72 — issue #50's "is never silent" case. It is
        // unsupported, not missing, and carries no invented version.
        let notRestic = CLIFailure.resticUnavailable(
            result: ResticDiscoveryResult(
                chosen: nil,
                rejected: [ResticProbe(path: "/tmp/restic", outcome: .unusable(reason: "exited 72"))],
                searchedDescription: "PATH"
            ),
            message: "restic could not be used."
        )
        #expect(notRestic.code == .resticUnsupported)
        #expect(notRestic.details.versionFound == nil)
    }

    @Test("a probed binary cannot put arbitrary text into details.versionFound")
    func versionFoundIsBounded() {
        // `versionFound` is the one `details` field whose value comes from
        // outside this process — a wrapper on PATH can answer `version`
        // with any JSON object it likes, and `VersionInfo` accepts the
        // string because its comparison simply ignores what it cannot read.
        // Verbatim, that would put unbounded attacker-chosen text into the
        // half of the envelope documented as safe to log.
        let hostile = String(repeating: "9", count: 4_000) + " <script>"
        let failure = CLIFailure.resticUnavailable(
            result: ResticDiscoveryResult(
                chosen: nil,
                rejected: [ResticProbe(path: "/tmp/restic", outcome: .tooOld(version: hostile))],
                searchedDescription: "PATH"
            ),
            message: "too old"
        )
        let found = try? #require(failure.details.versionFound)
        #expect(found?.count ?? .max <= 64)
        #expect(found?.contains("<script>") == false)
        // Ordinary versions survive intact — this sanitizes, it does not
        // discard, and the published value is the number the too-old
        // decision was actually made on.
        #expect(CLIFailure.boundedVersion("0.16.4") == "0.16.4")
        #expect(CLIFailure.boundedVersion("0.17.0-rc.1") == "0.17.0")
        #expect(CLIFailure.boundedVersion("") == "0")
    }

    @Test("a timeout tells an agent what it tells a person: try again")
    func timeoutsAreRetryable() {
        // `timedOut.userFacingMessage` has always ended "then try again",
        // while the envelope classified it as `restic_failed`, whose
        // published `retryable` is false — the two halves of the same
        // failure gave opposite advice.
        let timeout = CLIFailure.classify(ResticRunnerError.timedOut)
        #expect(timeout.code == .operationTimedOut)
        #expect(timeout.retryable)
        #expect(timeout.message.contains("try again"))
        // Not published: it answers the engine's "write a failed record?"
        // question, and would read as `terminal` beside `retryable: true`.
        #expect(timeout.details.resticCategory == nil)
        #expect(timeout.details == CLIErrorDetails())
    }

    @Test("the runner's two secret failures stay distinct all the way to the envelope")
    func runnerSecretFailuresKeepTheirRetryAdvice() {
        // The runner's pre-flight used to collapse both `SecretStoreError`
        // cases into `secretsUnavailable`, which made `secret_not_configured`
        // unreachable from the path that actually runs restic — so a caller
        // was told to retry a request that cannot succeed until a human
        // stores a password.
        let unreadable = CLIFailure.classify(ResticRunnerError.secretsUnavailable(destinationId: destId))
        #expect(unreadable.code == .secretUnavailable)
        #expect(unreadable.retryable)

        let absent = CLIFailure.classify(ResticRunnerError.secretsNotConfigured(destinationId: destId))
        #expect(absent.code == .secretNotConfigured)
        #expect(!absent.retryable)
        #expect(absent.details.destinationId == destId)
        // The published category agrees with `retryable` rather than
        // contradicting it in the same envelope.
        #expect(absent.details.resticCategory == .terminal)
    }

    @Test("a restic that could not be spawned at all is reported as not found")
    func launchFailureIsNotFound() {
        #expect(CLIFailure.classify(ResticRunnerError.launchFailed("no such file")).code == .resticNotFound)
    }

    @Test("both secret backends map to the same logical code")
    func secretBackendsAgree() {
        // The acceptance criterion from #81: a macOS keychain failure and a
        // Linux `secrets.json` failure must be indistinguishable to a caller
        // deciding what to do about it. Both backends raise the same two
        // cases, so the split below is by *condition* and not by backend —
        // `KeychainSecretStore` maps `security`'s exit 44 to `itemNotFound`
        // exactly as `FileSecretStore` maps a missing key.
        #expect(CLIFailure.classify(SecretStoreError.itemNotFound).code == .secretNotConfigured)
        #expect(
            CLIFailure.classify(SecretStoreError.backendFailed("security: exit 51")).code
                == .secretUnavailable
        )
        let lockFailure = CLIFailure.classify(SecretStoreError.lockUnusable(LockFailure(
            path: "/data/locks/secrets.lock",
            operation: "file type",
            errnoValue: 0
        )))
        #expect(lockFailure.code == .internalError)
        #expect(!lockFailure.retryable)
    }

    @Test("an unrecognised error is internal_error, never guessed at from its text")
    func unknownErrorsAreNotGuessed() {
        struct Surprise: Error, CustomStringConvertible {
            var description: String { "repository is locked and offline and busy" }
        }
        let failure = CLIFailure.classify(Surprise())
        #expect(failure.code == .internalError)
        #expect(failure.details.isEmpty)
    }

    @Test("classify passes an already-classified failure straight through")
    func classifyIsIdempotent() {
        let original = CLIFailure.setNotFound(setId: setId)
        #expect(CLIFailure.classify(original) == original)
    }

    @Test("messages are bounded so no object description reaches the wire")
    func boundedMessages() {
        struct Verbose: Error, CustomStringConvertible {
            var description: String { String(repeating: "x", count: 5_000) }
        }
        let failure = CLIFailure.classify(Verbose())
        #expect(failure.message.count == CLIFailure.messageCharacterLimit) // the ellipsis is inside the cap
        #expect(failure.message.hasSuffix("…"))
    }

    @Test("no single details value can be enormous, however it got there")
    func detailsValuesAreBounded() throws {
        // `machineId` comes from `config.json`, and `MachineIdentity.isValid`
        // imposes no length limit — so "details is bounded by construction"
        // was true of the *key set* and not of the document. Asserted on the
        // encoded form, because that is what the guarantee is about and
        // because the fields are `var`s that can be assigned after any
        // constructor has had its say.
        var details = CLIErrorDetails(setId: setId)
        details.machineId = String(repeating: "n", count: 4_000)
        details.runId = String(repeating: "r", count: 4_000)
        details.diagnosticReference = String(repeating: "/log", count: 4_000)
        details.versionSupported = String(repeating: "9", count: 4_000)

        let failure = CLIFailure(code: .setDisabledHere, message: "disabled", details: details)
        let data = try ConfigStore.makeEncoder().encode(CLIErrorEnvelope(failure))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let body = try #require(object["error"] as? [String: Any])
        let encoded = try #require(body["details"] as? [String: Any])
        for key in ["machineId", "runId", "diagnosticReference", "versionSupported"] {
            let value = try #require(encoded[key] as? String, "\(key) missing from the encoded details")
            #expect(value.count <= CLIErrorDetails.valueCharacterLimit, "\(key) was \(value.count) characters")
            // Marked, so a truncated id reads as truncated rather than as a
            // different id that happens to exist.
            #expect(value.hasSuffix("…"))
        }
        // The id types cannot be oversized in the first place.
        #expect(encoded["setId"] as? String == setId.uuidString)
    }

    @Test("a valid but enormous machine id does not reach the wire")
    func machineIdFromConfigIsBounded() throws {
        // The concrete route Codex named: `setDisabledHere` and
        // `destinationDisabledHere` both put a config-supplied machine id
        // straight into `details`.
        let longId = String(repeating: "m", count: 3_000)
        for failure in [
            CLIFailure.setDisabledHere(setId: setId, machineId: longId),
            CLIFailure.destinationDisabledHere(setId: setId, destinationId: destId, machineId: longId),
        ] {
            let data = try ConfigStore.makeEncoder().encode(CLIErrorEnvelope(failure))
            #expect(data.count < 2_000, "the whole envelope should be small, was \(data.count) bytes")
        }
    }

    @Test("the cap belongs to the type, not to whichever constructor remembered it")
    func theInitializerBoundsToo() {
        // Constructed directly, the way a future call site will. Nothing
        // here calls `bounded(_:)`, and the message is still bounded.
        let direct = CLIFailure(code: .operationNotAllowed, message: String(repeating: "y", count: 5_000))
        #expect(direct.message.count == CLIFailure.messageCharacterLimit)

        // The concrete case that motivated it: a machine id is interpolated
        // into this message and `MachineIdentity` imposes no length limit.
        let longId = String(repeating: "n", count: 2_000)
        let disabled = CLIFailure.setDisabledHere(setId: setId, machineId: longId)
        #expect(disabled.message.count <= CLIFailure.messageCharacterLimit)
    }
}

@Suite("CLI error envelope encoding")
struct CLIErrorEnvelopeTests {

    private func encode(_ failure: CLIFailure) throws -> String {
        let data = try ConfigStore.makeEncoder().encode(CLIErrorEnvelope(failure))
        return String(decoding: data, as: UTF8.self)
    }

    @Test("the envelope is exactly the documented shape")
    func envelopeShape() throws {
        let json = try encode(.classify(exitClass: .repoLocked, destinationId: destId))
        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(json.contains("\"ok\" : false"))
        #expect(json.contains("\"code\" : \"repository_locked\""))
        #expect(json.contains("\"retryable\" : true"))
        #expect(json.contains("\"destinationId\" : \"\(destId.uuidString)\""))
        #expect(json.contains("\"resticExitCode\" : 11"))
    }

    @Test("empty details are omitted rather than encoded as an empty object")
    func detailsOmittedWhenEmpty() throws {
        let json = try encode(.invalidArguments("--limit must be positive; got 0"))
        #expect(!json.contains("details"))
    }

    @Test("every representative failure encodes as one parseable JSON object")
    func allCodesEncode() throws {
        for code in CLIErrorCode.allCases {
            let failure = try #require(representative[code])
            let data = try ConfigStore.makeEncoder().encode(CLIErrorEnvelope(failure))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let parsed = try #require(object, "\(code.rawValue) did not encode as a JSON object")
            #expect(parsed["ok"] as? Bool == false)
            let body = try #require(parsed["error"] as? [String: Any])
            #expect(body["code"] as? String == code.rawValue)
            #expect(body["retryable"] as? Bool == code.retryable)
            let message = try #require(body["message"] as? String)
            #expect(!message.isEmpty, "\(code.rawValue) must say something to a human")
        }
    }

    @Test("details can only ever carry ids and safe enum values")
    func detailsCannotCarrySecrets() throws {
        // The redaction policy is enforced by the *shape* of
        // `CLIErrorDetails`, so the test that matters is that the shape has
        // not grown a free-form field. If this list needs updating, the
        // redaction policy in docs/cli-json.md needs re-reading first.
        let full = CLIErrorDetails(
            setId: setId,
            destinationId: destId,
            runId: "run-1",
            machineId: "linux-nas",
            resticExitCode: 11,
            resticCategory: .terminal,
            versionFound: "0.16.4",
            versionSupported: "0.17.0",
            diagnosticReference: "runs/run-1/log.txt"
        )
        let data = try ConfigStore.makeEncoder().encode(full)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(
            Set(object.keys) == [
                "setId", "destinationId", "runId", "machineId",
                "resticExitCode", "resticCategory",
                "versionFound", "versionSupported", "diagnosticReference",
            ]
        )
    }
}
