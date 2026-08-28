import Foundation
import Testing
@testable import ResticStationCore

// Exhaustive, table-driven pins for every failure-classification mapping —
// one table per taxonomy, one row per enum case.
//
// The companion change in the classifiers themselves removed every
// `default:` arm and every `.token`-style catch-all sub-pattern, so **adding
// an enum case now fails compilation at each classifier**. These tables are
// the runtime half of that guarantee: each `expected…` function below is
// itself an exhaustive `switch` (no `default`), so a new case also fails
// compilation *here*, in the file whose whole job is to make the author
// write down the intended mapping — and each `cases` list is checked for
// completeness where `CaseIterable` exists.
//
// Motivation: PR #117 fixed ~17 call sites that collapsed typed failures to
// generic `.failed`/`internal_error`/wrong-retryable codes, one review round
// at a time. This file is what turns the next instance of that bug shape
// into a compile error plus a single failing row.

private let setId = UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA")!
private let destId = UUID(uuidString: "0A1B2C3D-4E5F-4A1B-8C1D-000000000001")!

// MARK: - CLIErrorCode (the published envelope codes)

@Suite("classification table: CLIErrorCode")
struct CLIErrorCodeTableTests {

    /// Every published code → (wire name, process exit code, retryable).
    /// `CLIErrorCode` is `CaseIterable`, so a case added without a row makes
    /// the completeness test below fail by itself.
    private static let rows: [(code: CLIErrorCode, raw: String, exit: HelperExitCode, retryable: Bool)] = [
        (.invalidArguments, "invalid_arguments", .error, false),
        (.configInvalid, "config_invalid", .error, false),
        (.setNotFound, "set_not_found", .error, false),
        (.setDisabledHere, "set_disabled_here", .error, false),
        (.destinationNotFound, "destination_not_found", .error, false),
        (.destinationDisabledHere, "destination_disabled_here", .error, false),
        (.runNotFound, "run_not_found", .error, false),
        (.setBusy, "set_busy", .busy, true),
        (.repositoryOffline, "repository_offline", .offline, true),
        (.repositoryLocked, "repository_locked", .error, true),
        (.secretUnavailable, "secret_unavailable", .error, true),
        (.secretRejected, "secret_rejected", .error, false),
        (.secretNotConfigured, "secret_not_configured", .error, false),
        (.secretStoreUnusable, "secret_store_unusable", .error, false),
        (.repositoryNotInitialized, "repository_not_initialized", .error, false),
        (.resticNotFound, "restic_not_found", .error, false),
        (.resticUnsupported, "restic_unsupported", .error, false),
        (.resticFailed, "restic_failed", .error, false),
        (.operationTimedOut, "operation_timed_out", .error, true),
        (.previewExpired, "preview_expired", .error, false),
        (.operationNotAllowed, "operation_not_allowed", .error, false),
        (.operationCompletedAuditFailed, "operation_completed_audit_failed", .error, false),
        (.internalError, "internal_error", .error, false),
    ]

    @Test("every case has exactly one row")
    func tableIsComplete() {
        #expect(Set(Self.rows.map(\.code)) == Set(CLIErrorCode.allCases))
        #expect(Self.rows.count == CLIErrorCode.allCases.count)
    }

    @Test("each row pins wire name, exit code, and retryable bit")
    func rowsMatchImplementation() {
        for row in Self.rows {
            #expect(row.code.rawValue == row.raw, "\(row.raw)")
            #expect(row.code.exitCode == row.exit, "\(row.raw)")
            #expect(row.code.retryable == row.retryable, "\(row.raw)")
        }
    }
}

// MARK: - PurgeApplyError (including every PreviewTokenError sub-case)

@Suite("classification table: PurgeApplyError / PreviewTokenError")
struct PurgeApplyErrorTableTests {

    /// The intended envelope classification for every case, written as an
    /// exhaustive switch: a new `PurgeApplyError` or `PreviewTokenError`
    /// case fails compilation on this function until a mapping is chosen.
    private static func expected(_ error: PurgeApplyError) -> (code: CLIErrorCode, retryable: Bool) {
        switch error {
        case .token(let tokenError):
            switch tokenError {
            case .expired:
                return (.previewExpired, false)
            case .storeUnusable:
                return (.internalError, false)
            case .unavailable, .unknown, .alreadyUsed:
                // Deliberately opaque: a caller must not learn whether a
                // token value is unknown, spent, or merely stale.
                return (.operationNotAllowed, false)
            }
        case .tokenDoesNotMatchCurrentPlan:
            return (.operationNotAllowed, false)
        case .busy:
            return (.setBusy, true)
        case .lockUnusable:
            return (.internalError, false)
        case .infrastructureFailure(let reason, _):
            return (reason.hasPrefix("operation_completed_audit_failed")
                ? (.operationCompletedAuditFailed, false)
                : (.internalError, false))
        case .auditFailure:
            return (.operationCompletedAuditFailed, false)
        case .destinationOffline:
            return (.repositoryOffline, true)
        case .unavailable:
            return (.secretUnavailable, true)
        case .secretRefused(let attention, _, _):
            // The code the pre-flight reported, never a fixed one: a
            // destination with no password and a store that will not be
            // read need different repairs (#96 review).
            return (attention.code, false)
        case .resticUnavailable:
            return (.resticNotFound, false)
        }
    }

    /// One concrete value per case (and per meaningful payload variant).
    private static let cases: [PurgeApplyError] = [
        .token(.unavailable),
        .token(.storeUnusable("lock file owned by another user")),
        .token(.unknown),
        .token(.expired),
        .token(.alreadyUsed),
        .tokenDoesNotMatchCurrentPlan,
        .busy,
        .secretRefused(
            .secretStoreUnusable,
            destinationId: destId,
            "refusing to read /data/secrets.json: it is a symbolic link."
        ),
        .secretRefused(.secretNotConfigured, destinationId: destId, "no stored secret for this destination"),
        .lockUnusable("open lock directory failed"),
        .infrastructureFailure(reason: "run history unusable", operationMayHaveRun: false),
        .infrastructureFailure(reason: "run history unusable", operationMayHaveRun: true),
        .infrastructureFailure(
            reason: "operation_completed_audit_failed — terminal audit persistence failed",
            operationMayHaveRun: true
        ),
        .auditFailure(
            reason: "operation_completed_audit_failed — prior destructive run needs inspection",
            operationMayHaveRun: false,
            runId: "20260825T210000Z-purge-deadbeef"
        ),
        .destinationOffline(destinationId: destId),
        .unavailable,
        .resticUnavailable,
    ]

    @Test("every case maps to its pinned envelope code, exit code, and retryable bit")
    func rowsMatchClassifier() {
        for error in Self.cases {
            let failure = CLIFailure.classifyPurgeOperation(error, setId: setId)
            let want = Self.expected(error)
            #expect(failure.code == want.code, "\(error)")
            #expect(failure.retryable == want.retryable, "\(error)")
            #expect(failure.exitCode == want.code.exitCode, "\(error)")
            #expect(failure.details.setId == setId, "\(error)")
        }
    }

    /// A permanent secret refusal names the destination it is about. An
    /// apply spans several, and the repair it prescribes — `secret set`, or
    /// a `chmod` on one repository's credentials — cannot be carried out
    /// against a set id alone (#96 review).
    @Test("a secret refusal publishes the destination that was refused")
    func secretRefusalCarriesItsDestination() {
        for attention in DestinationAttention.allCases {
            let failure = CLIFailure.classifyPurgeOperation(
                PurgeApplyError.secretRefused(attention, destinationId: destId, "refused"),
                setId: setId
            )
            #expect(failure.details.destinationId == destId, "\(attention)")
            #expect(failure.code == attention.code, "\(attention)")
            #expect(!failure.retryable, "\(attention)")
        }
    }

    @Test("no purge classification can leak token material")
    func messagesNeverCarryTokens() {
        for error in Self.cases {
            let failure = CLIFailure.classifyPurgeOperation(error, setId: setId)
            #expect(!failure.message.lowercased().contains("token value"), "\(error)")
        }
    }
}

// MARK: - ResticExitClass

@Suite("classification table: ResticExitClass")
struct ResticExitClassTableTests {

    /// Exhaustive: (envelope code, published restic exit code, run-record
    /// category). A new exit class fails compilation here.
    private static func expected(
        _ exitClass: ResticExitClass
    ) -> (code: CLIErrorCode, resticExit: Int32?, category: ResticErrorCategory) {
        switch exitClass {
        case .success:
            return (.internalError, nil, .success)
        case .warningIncompleteRead:
            return (.internalError, nil, .warning)
        case .fatal:
            return (.resticFailed, 1, .terminal)
        case .repoDoesNotExist:
            return (.repositoryNotInitialized, 10, .terminal)
        case .repoLocked:
            return (.repositoryLocked, 11, .retryable)
        case .wrongPassword:
            return (.secretRejected, 12, .terminal)
        case .other(let raw):
            return (.resticFailed, raw, .terminal)
        }
    }

    private static let cases: [ResticExitClass] = [
        .success,
        .warningIncompleteRead,
        .fatal(stderrSummary: "repository is damaged"),
        .repoDoesNotExist,
        .repoLocked,
        .wrongPassword,
        .other(130),
    ]

    @Test("every exit class maps to its pinned envelope code, restic exit, and category")
    func rowsMatchClassifier() {
        for exitClass in Self.cases {
            let failure = CLIFailure.classify(exitClass: exitClass, setId: setId, destinationId: destId)
            let want = Self.expected(exitClass)
            #expect(failure.code == want.code, "\(exitClass)")
            #expect(failure.details.resticExitCode == want.resticExit, "\(exitClass)")
            #expect(failure.details.resticCategory == want.category, "\(exitClass)")
            #expect(exitClass.category == want.category, "\(exitClass)")
            #expect(failure.retryable == want.code.retryable, "\(exitClass)")
        }
    }
}

// MARK: - ResticRunnerError

@Suite("classification table: ResticRunnerError")
struct ResticRunnerErrorTableTests {

    /// Exhaustive: (envelope code, retryable, run-record category).
    private static func expected(
        _ error: ResticRunnerError
    ) -> (code: CLIErrorCode, retryable: Bool, category: ResticErrorCategory) {
        switch error {
        case .secretsUnavailable:
            return (.secretUnavailable, true, .retryable)
        case .secretsNotConfigured:
            return (.secretNotConfigured, false, .terminal)
        case .secretsStoreUnusable:
            return (.secretStoreUnusable, false, .terminal)
        case .launchFailed:
            return (.resticNotFound, false, .terminal)
        case .timedOut:
            return (.operationTimedOut, true, .terminal)
        }
    }

    private static let cases: [ResticRunnerError] = [
        .secretsUnavailable(destinationId: destId),
        .secretsNotConfigured(destinationId: destId),
        .secretsStoreUnusable(destinationId: destId),
        .launchFailed("no such file"),
        .timedOut,
    ]

    @Test("every runner error maps to its pinned envelope code, retryable bit, and category")
    func rowsMatchClassifier() {
        for error in Self.cases {
            let failure = CLIFailure.classify(error)
            let want = Self.expected(error)
            #expect(failure.code == want.code, "\(error)")
            #expect(failure.retryable == want.retryable, "\(error)")
            #expect(error.category == want.category, "\(error)")
        }
    }
}

// MARK: - SecretStoreError

@Suite("classification table: SecretStoreError")
struct SecretStoreErrorTableTests {

    /// Exhaustive: envelope code and retryable bit per case.
    private static func expected(_ error: SecretStoreError) -> (code: CLIErrorCode, retryable: Bool) {
        switch error {
        case .itemNotFound:
            return (.secretNotConfigured, false)
        case .lockUnusable:
            return (.internalError, false)
        case .storeUnusable:
            return (.secretStoreUnusable, false)
        case .backendFailed:
            return (.secretUnavailable, true)
        }
    }

    private static let cases: [SecretStoreError] = [
        .itemNotFound,
        .lockUnusable(LockFailure(path: "/data/locks/secrets.lock", operation: "ownership", errnoValue: 0)),
        .storeUnusable("refusing to read /data/secrets.json: it is a symbolic link."),
        .backendFailed("security: exit 51"),
    ]

    @Test("every secret-store error maps to its pinned envelope code and retryable bit")
    func rowsMatchClassifier() {
        for error in Self.cases {
            let failure = CLIFailure.classify(error)
            let want = Self.expected(error)
            #expect(failure.code == want.code, "\(error)")
            #expect(failure.retryable == want.retryable, "\(error)")
        }
    }
}

// MARK: - ConfigError

@Suite("classification table: ConfigError")
struct ConfigErrorTableTests {

    /// Every `ConfigError` case classifies as `config_invalid`; only
    /// `newerVersion` additionally publishes the version pair in `details`.
    /// The switch is exhaustive so a new case fails compilation here — the
    /// classifier's own switch (`CLIFailure.classify(_: ConfigError)`) is now
    /// case-exhaustive too, so both break together.
    private static func expected(_ error: ConfigError) -> (code: CLIErrorCode, carriesVersions: Bool) {
        switch error {
        case .newerVersion:
            return (.configInvalid, true)
        case .remoteMaintenanceRequiresSFTP, .notExactlyOnePrimaryDestination,
             .duplicateIdentifier, .emptySources, .relativeSourcePath,
             .emptyPurgeExcludePattern, .invalidSchedule,
             .invalidStalenessWarningDays, .invalidReadDataSubsetSlices,
             .invalidMachineIdKey, .relativeOverrideSourcePath,
             .nonCanonicalSourcePath, .nonCanonicalOverrideSourcePath,
             .notExactlyOnePrimaryDestinationForMachine:
            return (.configInvalid, false)
        }
    }

    private static let cases: [ConfigError] = [
        .remoteMaintenanceRequiresSFTP(destinationId: destId),
        .newerVersion(found: 4, supported: 3),
        .notExactlyOnePrimaryDestination(setId: setId, count: 2),
        .duplicateIdentifier(setId),
        .emptySources(setId: setId),
        .relativeSourcePath(setId: setId, path: "Documents"),
        .emptyPurgeExcludePattern(setId: setId, index: 0),
        .invalidSchedule(setId: setId, reason: "minute out of range"),
        .invalidStalenessWarningDays(setId: setId, value: 0),
        .invalidReadDataSubsetSlices(setId: setId, value: 1),
        .invalidMachineIdKey(setId: setId, machineId: "Bad_Slug"),
        .relativeOverrideSourcePath(setId: setId, machineId: "linux-nas", path: "Documents"),
        .nonCanonicalSourcePath(setId: setId, path: "/srv/../srv/data"),
        .nonCanonicalOverrideSourcePath(setId: setId, machineId: "linux-nas", path: "/srv/./data"),
        .notExactlyOnePrimaryDestinationForMachine(setId: setId, machineId: "linux-nas", count: 0),
    ]

    @Test("every config error is config_invalid, non-retryable, exit 1")
    func rowsMatchClassifier() {
        for error in Self.cases {
            let failure = CLIFailure.classify(error)
            let want = Self.expected(error)
            #expect(failure.code == want.code, "\(error)")
            #expect(!failure.retryable, "\(error)")
            #expect(failure.exitCode == .error, "\(error)")
            if want.carriesVersions {
                #expect(failure.details.versionFound == "4", "\(error)")
                #expect(failure.details.versionSupported == "3", "\(error)")
            } else {
                #expect(failure.details.versionFound == nil, "\(error)")
            }
        }
    }
}
