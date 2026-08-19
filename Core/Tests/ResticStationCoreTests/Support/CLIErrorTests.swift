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
    .secretUnavailable: .classify(SecretStoreError.itemNotFound),
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
    .internalError: .classify(ConfigStoreError.renameFailed(errno: 13, from: "a", to: "b")),
    // These two have no typed error yet: `repositoryOffline` is produced by
    // a `Reachability` *result* (#79 wires it), and `operationNotAllowed` by
    // engine invariants that today refuse before throwing. Constructed
    // directly and deliberately, so `everyCodeIsReachable` stays meaningful
    // for the rest.
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
        #expect(CLIErrorCode.resticNotFound.rawValue == "restic_not_found")
        #expect(CLIErrorCode.resticUnsupported.rawValue == "restic_unsupported")
        #expect(CLIErrorCode.resticFailed.rawValue == "restic_failed")
        #expect(CLIErrorCode.operationNotAllowed.rawValue == "operation_not_allowed")
        #expect(CLIErrorCode.internalError.rawValue == "internal_error")
        #expect(CLIErrorCode.allCases.count == 18)
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

    @Test("a restic that could not be spawned at all is reported as not found")
    func launchFailureIsNotFound() {
        #expect(CLIFailure.classify(ResticRunnerError.launchFailed("no such file")).code == .resticNotFound)
    }

    @Test("both secret backends map to the same logical code")
    func secretBackendsAgree() {
        // The acceptance criterion from #81: a macOS keychain failure and a
        // Linux `secrets.json` failure must be indistinguishable to a caller
        // deciding what to do about it.
        #expect(CLIFailure.classify(SecretStoreError.itemNotFound).code == .secretUnavailable)
        #expect(
            CLIFailure.classify(SecretStoreError.backendFailed("security: exit 51")).code
                == .secretUnavailable
        )
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
        #expect(failure.message.count == CLIFailure.messageCharacterLimit + 1) // + the ellipsis
        #expect(failure.message.hasSuffix("…"))
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
