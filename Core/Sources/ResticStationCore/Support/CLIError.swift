import Foundation

// MARK: - CLIErrorCode

/// The machine-readable failure classification carried by every `--json`
/// error envelope (`docs/cli-json.md`, issue #81).
///
/// **Why this exists.** ``HelperExitCode`` is deliberately coarse — 0 ok,
/// 1 error, 2 busy, 3 offline — which is the right shape for `&&` in a shell
/// and useless for an agent that needs to tell "this set does not exist"
/// from "the repository is locked" from "the password could not be read".
/// Rather than allocate a new exit code per failure (which would break every
/// existing caller), the precise classification moves into the JSON payload
/// and the exit code stays exactly what it was.
///
/// **This is a published contract.** The raw values are the stable names
/// callers match on; they are `snake_case` because that is what the envelope
/// puts on the wire, and they must never be renamed. `message` is
/// presentation text and may change freely.
///
/// **Adding a case is additive** and does *not* bump
/// ``CLIErrorEnvelope/schemaVersion``: clients are required to treat an
/// unrecognised code as a failure of unknown class rather than crash on it.
/// That is what lets #82/#88 add the `preview_*` family later without a
/// version break.
///
/// Deliberately absent, each for a reason recorded in `docs/cli-json.md`:
/// `config_missing` (a missing `config.json` is an empty config, not an
/// error — see ``ConfigStore/load()``), the `preview_*` family (the
/// mechanism lands with #82/#88), and `cloud_repository_not_hydrated` (no
/// detector exists, and inferring it would mean matching restic's English
/// stderr — exactly what this contract is meant to stop callers doing).
public enum CLIErrorCode: String, Sendable, Codable, CaseIterable, Equatable {

    // ── The request could not be understood ───────────────────────────────

    /// Arguments were missing, malformed, or out of range. Also what a
    /// failure to *parse* the command line reports in `--json` mode.
    case invalidArguments = "invalid_arguments"

    // ── Configuration ─────────────────────────────────────────────────────

    /// A configuration file on this host will not load: `config.json`
    /// could not be decoded, failed ``AppConfig/validate()``, or was written
    /// by a newer Restic Station than this build supports — or `machine.json`
    /// could not be read. `message` names which file it was; see
    /// ``CLIFailure/machineIdentityUnreadable(path:underlying:)`` for why
    /// the two share a code.
    case configInvalid = "config_invalid"

    // ── The thing you named is not here ───────────────────────────────────

    case setNotFound = "set_not_found"
    /// The set exists in the shared config but is switched off for this
    /// machine, so the requested operation has nothing to act on.
    case setDisabledHere = "set_disabled_here"
    case destinationNotFound = "destination_not_found"
    case destinationDisabledHere = "destination_disabled_here"
    /// No run record with this id. Not in issue #81's original list;
    /// `runs show <unknown-id>` is a real failure of a `--json` command and
    /// had no code to report.
    case runNotFound = "run_not_found"

    // ── Transient conditions worth retrying ───────────────────────────────

    /// Another operation holds this set's lock.
    case setBusy = "set_busy"
    /// The destination did not answer. The expected state of an unplugged
    /// drive or a sleeping NAS — not a fault.
    case repositoryOffline = "repository_offline"
    /// restic exit 11: another restic process holds the repository lock.
    case repositoryLocked = "repository_locked"
    /// The repository password or secret environment could not be *read* —
    /// a locked login keychain at a pre-login tick, or a `secrets.json`
    /// whose mode has been widened. Retryable: the same request can succeed
    /// once the backend is available again.
    case secretUnavailable = "secret_unavailable"
    /// The secret was read fine and restic rejected it (exit 12).
    ///
    /// Split from ``secretUnavailable`` because the two need opposite
    /// responses and would otherwise have to share one `retryable` value:
    /// an unreadable keychain is worth retrying unchanged, whereas a wrong
    /// password will fail identically forever until a human replaces it.
    /// Not in issue #81's original list — restic's exit-code contract makes
    /// this distinction reliably detectable, so collapsing it would have
    /// meant publishing a `retryable` that is wrong half the time.
    case secretRejected = "secret_rejected"
    /// Nothing is stored for this destination — the backend answered, and
    /// the answer was "no such item" (``SecretStoreError/itemNotFound``).
    ///
    /// Split from ``secretUnavailable`` for the same reason
    /// ``secretRejected`` is: the two conditions are indistinguishable to a
    /// caller that only sees "the secret could not be read", and they need
    /// opposite retry advice. A keychain that is locked at a pre-login tick
    /// unlocks by itself; a destination whose password was never stored
    /// stays that way until a human runs `secret set`.
    case secretNotConfigured = "secret_not_configured"

    // ── Repository state ──────────────────────────────────────────────────

    /// restic exit 10: nothing is initialized at this location.
    case repositoryNotInitialized = "repository_not_initialized"

    // ── restic itself ─────────────────────────────────────────────────────

    /// No usable restic binary was found.
    case resticNotFound = "restic_not_found"
    /// A restic binary was found and ran, but is below the supported
    /// minimum or is not restic at all.
    case resticUnsupported = "restic_unsupported"
    /// restic ran and failed.
    case resticFailed = "restic_failed"

    // ── Refused on purpose ────────────────────────────────────────────────

    /// The operation is understood and was refused by a safety invariant —
    /// `forget` with an empty retention policy, `prune` on a mirror that is
    /// behind its primary (`docs/architecture.md` §Invariants).
    case operationNotAllowed = "operation_not_allowed"

    // ── Everything else ───────────────────────────────────────────────────

    /// An unexpected failure. Its `message` is bounded and never carries a
    /// serialized object description — see ``CLIFailure/bounded(_:)``.
    case internalError = "internal_error"
}

extension CLIErrorCode {

    /// The process exit code this classification maps onto.
    ///
    /// The mapping is deliberately many-to-one: the exit code stays the
    /// coarse shell contract it has always been, and `code` carries the
    /// precision. Only two classifications leave exit 1.
    ///
    /// - Note: `repositoryOffline` maps to ``HelperExitCode/offline``, which
    ///   `docs/architecture.md` currently describes as "`probe-repo` only".
    ///   No `--json` command emits it yet, so nothing changes today; #79 is
    ///   what widens it, and it updates that sentence when it does.
    public var exitCode: HelperExitCode {
        switch self {
        case .setBusy:
            return .busy
        case .repositoryOffline:
            return .offline
        case .invalidArguments, .configInvalid, .setNotFound, .setDisabledHere,
             .destinationNotFound, .destinationDisabledHere, .runNotFound,
             .repositoryLocked, .secretUnavailable, .secretRejected,
             .secretNotConfigured,
             .repositoryNotInitialized, .resticNotFound, .resticUnsupported,
             .resticFailed, .operationNotAllowed, .internalError:
            return .error
        }
    }

    /// Whether repeating the identical request later could plausibly
    /// succeed **without anyone changing anything**.
    ///
    /// This is advice for an automated caller's backoff loop, so it is
    /// deliberately narrow — it means "the identical request could succeed
    /// later with nobody changing anything". ``secretRejected`` and
    /// ``secretNotConfigured`` exist so that a wrong password and an absent
    /// one do not have to share this flag with a locked keychain. It tracks
    /// ``ResticErrorCategory/retryable`` where the two overlap.
    public var retryable: Bool {
        switch self {
        case .setBusy, .repositoryOffline, .repositoryLocked, .secretUnavailable:
            return true
        case .invalidArguments, .configInvalid, .setNotFound, .setDisabledHere,
             .destinationNotFound, .destinationDisabledHere, .runNotFound,
             .secretRejected, .secretNotConfigured,
             .repositoryNotInitialized, .resticNotFound,
             .resticUnsupported, .resticFailed, .operationNotAllowed,
             .internalError:
            return false
        }
    }
}

// MARK: - CLIErrorDetails

/// The structured half of an error envelope: identifiers and safe enum
/// values a caller can act on without parsing prose.
///
/// **A fixed shape, not a dictionary — and that is the redaction policy.**
/// Every field below is an id, a small integer, or a closed enum value.
/// There is deliberately no field that can hold a repository URL, a source
/// path, a password, a secret environment value, raw keychain output, a
/// subprocess environment, or an unbounded restic stderr blob. Making the
/// type incapable of carrying those is what keeps the rule from depending on
/// every future call site remembering it.
///
/// Absent fields are omitted rather than encoded as `null` — the envelope is
/// read by machines, and a key that is present only when meaningful is
/// easier to branch on than one that is always there and usually null. This
/// is the one place in the project that omits rather than nulls; see
/// `docs/data-model.md` §Encoding conventions for why the config files go
/// the other way.
public struct CLIErrorDetails: Encodable, Equatable, Sendable {
    public var setId: UUID?
    public var destinationId: UUID?
    public var runId: String?
    public var machineId: String?
    /// restic's own exit code, when restic ran and failed.
    public var resticExitCode: Int32?
    /// restic's failure category (`terminal`, `retryable`, …).
    public var resticCategory: ResticErrorCategory?
    /// The schema/binary version actually found, when a version mismatch is
    /// the failure.
    public var versionFound: String?
    /// The version this build requires.
    public var versionSupported: String?
    /// A run id or log path the caller may fetch for the full story. Only
    /// set when it is both safe to publish and useful.
    public var diagnosticReference: String?

    public init(
        setId: UUID? = nil,
        destinationId: UUID? = nil,
        runId: String? = nil,
        machineId: String? = nil,
        resticExitCode: Int32? = nil,
        resticCategory: ResticErrorCategory? = nil,
        versionFound: String? = nil,
        versionSupported: String? = nil,
        diagnosticReference: String? = nil
    ) {
        self.setId = setId
        self.destinationId = destinationId
        self.runId = runId
        self.machineId = machineId
        self.resticExitCode = resticExitCode
        self.resticCategory = resticCategory
        self.versionFound = versionFound
        self.versionSupported = versionSupported
        self.diagnosticReference = diagnosticReference
    }

    /// `true` when nothing is set, so the envelope can omit `details`
    /// entirely rather than emit an empty object.
    public var isEmpty: Bool {
        self == CLIErrorDetails()
    }

    /// Longest any single free-form string in `details` will be on the wire.
    ///
    /// The fixed shape stops a *repository URL* or a stderr blob from ever
    /// having a field to live in, but it does not stop a field's own value
    /// from being enormous: `machineId` comes from `config.json` and
    /// `MachineIdentity.isValid` imposes no length limit, so "`details` is
    /// bounded by construction" was true of the key set and not of the
    /// document. 128 is generous for every real value — a UUID string is 36,
    /// a machine slug is a hostname, a run id is a timestamp and a suffix.
    public static let valueCharacterLimit = 128

    /// Caps one free-form value, marking it so a truncated id reads as
    /// truncated rather than as a different id.
    static func boundedValue(_ text: String?) -> String? {
        guard let text else { return nil }
        guard text.count > valueCharacterLimit else { return text }
        return String(text.prefix(valueCharacterLimit - 1)) + "…"
    }

    private enum CodingKeys: String, CodingKey {
        case setId, destinationId, runId, machineId
        case resticExitCode, resticCategory
        case versionFound, versionSupported, diagnosticReference
    }

    // `encodeIfPresent` throughout — see the omission note above.
    //
    // Every free-form string is capped **here** rather than in the factories
    // that set them. The fields are `public var`, so a cap applied on the way
    // in can be undone by assignment; applied on the way out it holds for
    // every value however it arrived, which is what the published guarantee
    // says. `setId`/`destinationId` are `UUID` and cannot be oversized;
    // `resticExitCode` and `resticCategory` are an integer and a closed enum.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(setId, forKey: .setId)
        try container.encodeIfPresent(destinationId, forKey: .destinationId)
        try container.encodeIfPresent(Self.boundedValue(runId), forKey: .runId)
        try container.encodeIfPresent(Self.boundedValue(machineId), forKey: .machineId)
        try container.encodeIfPresent(resticExitCode, forKey: .resticExitCode)
        try container.encodeIfPresent(resticCategory?.rawValue, forKey: .resticCategory)
        try container.encodeIfPresent(Self.boundedValue(versionFound), forKey: .versionFound)
        try container.encodeIfPresent(Self.boundedValue(versionSupported), forKey: .versionSupported)
        try container.encodeIfPresent(Self.boundedValue(diagnosticReference), forKey: .diagnosticReference)
    }
}

// MARK: - CLIFailure

/// A classified failure on its way out of the process.
///
/// Commands throw this instead of writing their own JSON. The renderer
/// (`Helper/Sources/HelperOutput.swift`) decides whether it becomes an
/// envelope on stdout or a sentence on stderr; both consume this same value,
/// so the two modes can never drift apart in what they classify.
public struct CLIFailure: Error, Equatable, Sendable {
    public let code: CLIErrorCode
    /// Presentation text. Not part of the stable contract — but it is what a
    /// human sees, so it still follows the project's "one next step" rule.
    public let message: String
    public let details: CLIErrorDetails

    /// `message` is bounded here rather than at the call sites, so the cap
    /// below is a property of the type and not of every constructor
    /// remembering it. `setDisabledHere` was the counter-example: it
    /// interpolates a machine id, and `MachineIdentity.isValid` imposes no
    /// length limit, so a valid id could carry the message past the bound
    /// this type publishes.
    public init(code: CLIErrorCode, message: String, details: CLIErrorDetails = CLIErrorDetails()) {
        self.code = code
        self.message = Self.bounded(message)
        self.details = details
    }

    public var exitCode: HelperExitCode { code.exitCode }
    public var retryable: Bool { code.retryable }

    /// Longest `message` this type will carry.
    ///
    /// Mirrors ``ResticExitClass/summarize(_:)``'s cap and exists for the
    /// same reason: an unbounded message is how a `DecodingError`'s full
    /// `NSDebugDescription`, or a subprocess's entire stderr, ends up in a
    /// published payload. Nothing reaches the wire without passing through
    /// here.
    public static let messageCharacterLimit = 500

    /// Trims and caps arbitrary text for use as a `message`.
    ///
    /// Applied by ``init(code:message:details:)`` to everything, so calling
    /// it explicitly is only ever belt-and-braces at a site that wants to be
    /// obvious about capping a subprocess's output.
    ///
    /// The ellipsis is counted, not added on top: `messageCharacterLimit` is
    /// published as the longest message this type will carry, and a caller
    /// enforcing it would reject a 501-character one.
    public static func bounded(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > messageCharacterLimit else {
            return trimmed
        }
        return String(trimmed.prefix(messageCharacterLimit - 1)) + "…"
    }

    /// Reduces a version string **reported by a probed executable** to the
    /// dotted numeric triple the comparison actually used.
    ///
    /// `versionFound` is the one `details` field whose value originates
    /// outside this process: it is whatever the binary put in its
    /// `version` field, and `VersionInfo` accepts any string there because
    /// `numericTriple` ignores what it cannot read. Copying it verbatim
    /// would let an arbitrary — arbitrarily long, arbitrarily worded —
    /// payload into the half of the envelope that promises to be bounded
    /// and safe to log, which is exactly the promise `details` being a
    /// fixed struct exists to keep.
    ///
    /// Publishing the triple keeps the field honest rather than merely
    /// short: it is the number the too-old decision was made on. The raw
    /// text still reaches a human through `message`, which is capped.
    public static func boundedVersion(_ raw: String) -> String {
        let triple = VersionInfo.numericTriple(raw).prefix(3)
        guard !triple.isEmpty else { return "0" }
        return triple.map(String.init).joined(separator: ".")
    }
}

// MARK: - Constructors for the cases no typed error covers

/// The named constructors below are the reason command handlers never
/// hand-author an error. "This set does not exist" is not a Core error type
/// — no `throw` site produces it — so without these each command would
/// invent its own code *and* its own wording, which is precisely the drift
/// this contract exists to prevent.
extension CLIFailure {

    public static func invalidArguments(_ message: String) -> CLIFailure {
        CLIFailure(code: .invalidArguments, message: bounded(message))
    }

    public static func setNotFound(setId: UUID) -> CLIFailure {
        CLIFailure(
            code: .setNotFound,
            message: "No backup set with id \(setId).",
            details: CLIErrorDetails(setId: setId)
        )
    }

    public static func setDisabledHere(setId: UUID, machineId: String) -> CLIFailure {
        CLIFailure(
            code: .setDisabledHere,
            message: "Backup set \(setId) is switched off for machine “\(machineId)”.",
            details: CLIErrorDetails(setId: setId, machineId: machineId)
        )
    }

    public static func destinationNotFound(setId: UUID, destinationId: UUID) -> CLIFailure {
        CLIFailure(
            code: .destinationNotFound,
            message: "Destination \(destinationId) does not belong to backup set \(setId).",
            details: CLIErrorDetails(setId: setId, destinationId: destinationId)
        )
    }

    public static func destinationDisabledHere(
        setId: UUID,
        destinationId: UUID,
        machineId: String
    ) -> CLIFailure {
        CLIFailure(
            code: .destinationDisabledHere,
            message: "Destination \(destinationId) is switched off for machine “\(machineId)”.",
            details: CLIErrorDetails(setId: setId, destinationId: destinationId, machineId: machineId)
        )
    }

    public static func runNotFound(runId: String) -> CLIFailure {
        CLIFailure(
            code: .runNotFound,
            message: "No run with id \(bounded(runId)).",
            details: CLIErrorDetails(runId: bounded(runId))
        )
    }

    public static func setBusy(setId: UUID) -> CLIFailure {
        CLIFailure(
            code: .setBusy,
            message: "Another operation for this backup set is already running.",
            details: CLIErrorDetails(setId: setId)
        )
    }

    /// Classifies a failed restic search.
    ///
    /// The three-way discrimination deliberately mirrors
    /// `ResticPathResolution.resticNotFoundMessage(paths:result:)`, which
    /// builds the prose for exactly these cases — the caller passes that
    /// message straight in rather than having a second, subtly different
    /// wording grow here. Splitting "nothing installed" from "installed but
    /// unusable" is the whole point of issue #50's work; the code must not
    /// re-flatten it.
    public static func resticUnavailable(
        result: ResticDiscoveryResult,
        message: String
    ) -> CLIFailure {
        if let tooOld = result.firstTooOld {
            return CLIFailure(
                code: .resticUnsupported,
                message: bounded(message),
                details: CLIErrorDetails(
                    versionFound: tooOld.version.map(boundedVersion),
                    versionSupported: ResticDiscovery.minimumVersion
                )
            )
        }
        if let first = result.rejected.first, case .unusable = first.outcome {
            // Ran, and is not restic. `versionFound` stays nil — there was
            // no version to find, and inventing one would be a lie a caller
            // could branch on.
            return CLIFailure(
                code: .resticUnsupported,
                message: bounded(message),
                details: CLIErrorDetails(versionSupported: ResticDiscovery.minimumVersion)
            )
        }
        return CLIFailure(code: .resticNotFound, message: bounded(message))
    }

    /// Wraps whatever `ConfigStore.load()` threw. The underlying error is
    /// bounded, not embedded whole: a `DecodingError`'s description carries
    /// an `NSDebugDescription` that quotes the offending bytes.
    public static func configInvalid(underlying: any Error) -> CLIFailure {
        if let configError = underlying as? ConfigError {
            // Classified for its code and details, then re-prefixed: this is
            // the *load* path, and dropping the prefix would both regress
            // human mode (the old `HelperExit.fail` interpolated the same
            // `description` behind it) and leave the message silent about
            // which file failed — `config_invalid` also covers `machine.json`.
            let classified = classify(configError)
            return CLIFailure(
                code: classified.code,
                message: "could not load configuration: \(configError.description)",
                details: classified.details
            )
        }
        // Wording preserved verbatim from the `HelperExit.fail` call sites
        // this replaced, so human mode stays byte-identical. Only the cap is
        // new — and the message it caps is a `DecodingError` description
        // that quotes the offending bytes.
        return CLIFailure(
            code: .configInvalid,
            message: bounded("could not load configuration: \(underlying)")
        )
    }

    /// `machine.json` could not be read.
    ///
    /// Reported as ``CLIErrorCode/configInvalid`` rather than as its own
    /// code: it is a configuration file on this host that will not load, the
    /// caller's remedy is the same class of action, and `message` names
    /// which of the two files it was. A separate code would be a
    /// distinction no caller could act on differently.
    ///
    /// The path stays in `message` and out of `details` — a data-directory
    /// path carries a home directory, and `details` is the half of the
    /// envelope that promises to be safe to log.
    public static func machineIdentityUnreadable(path: String, underlying: any Error) -> CLIFailure {
        CLIFailure(
            code: .configInvalid,
            message: bounded("could not read this machine's identity (\(path)): \(underlying)")
        )
    }

    /// A run's `metadata.json` could not be read.
    ///
    /// "Absent" and "corrupt" are different answers to the caller — one
    /// means the id is wrong, the other means this host's state is damaged —
    /// so they are separated here rather than collapsed into one message the
    /// caller would have to read.
    public static func runUnreadable(runId: String, underlying: any Error) -> CLIFailure {
        if isFileNotFound(underlying) {
            return .runNotFound(runId: runId)
        }
        return CLIFailure(
            code: .internalError,
            message: bounded("could not read run \"\(runId)\": \(underlying)"),
            details: CLIErrorDetails(runId: bounded(runId))
        )
    }

    /// A local state file this host owns could not be read. Not the
    /// caller's fault and not something a retry fixes.
    public static func stateUnreadable(_ message: String) -> CLIFailure {
        CLIFailure(code: .internalError, message: bounded(message))
    }

    /// Whether an error means "that file is not there", across both
    /// Foundation implementations. `CocoaError` is what `Data(contentsOf:)`
    /// throws on Darwin *and* on swift-corelibs-foundation, so one check
    /// covers macOS and Linux.
    static func isFileNotFound(_ error: any Error) -> Bool {
        (error as? CocoaError)?.code == .fileReadNoSuchFile
            || (error as NSError).domain == NSCocoaErrorDomain
            && (error as NSError).code == NSFileReadNoSuchFileError
    }
}

// MARK: - Mapping Core's typed errors

extension CLIFailure {

    /// The single place a typed domain error becomes a classified failure.
    ///
    /// Everything Core can `throw` on a path a CLI command reaches goes
    /// through here, so a new error case shows up as one edit rather than as
    /// a wrong code in whichever command happened to catch it. Anything
    /// unrecognised lands on ``CLIErrorCode/internalError`` with a bounded
    /// message rather than being guessed at from its English text.
    public static func classify(_ error: any Error) -> CLIFailure {
        switch error {
        case let failure as CLIFailure:
            return failure

        case let configError as ConfigError:
            return classify(configError)

        case let runnerError as ResticRunnerError:
            return classify(runnerError)

        case let secretError as SecretStoreError:
            return classify(secretError)

        case let storeError as ConfigStoreError:
            // A failed rename during save. Not "your config is invalid" —
            // the config was fine and the filesystem was not.
            return CLIFailure(code: .internalError, message: bounded(storeError.description))

        default:
            return CLIFailure(code: .internalError, message: bounded("\(error)"))
        }
    }

    static func classify(_ error: ConfigError) -> CLIFailure {
        switch error {
        case .newerVersion(let found, let supported):
            return CLIFailure(
                code: .configInvalid,
                message: error.description,
                details: CLIErrorDetails(
                    versionFound: String(found),
                    versionSupported: String(supported)
                )
            )
        default:
            // Every other case is a validation failure of a config this
            // build *can* read. They are one code on purpose: a caller
            // fixes them all the same way — edit config.json — and the
            // per-field detail is in `message`, which is where a human
            // needs it.
            return CLIFailure(code: .configInvalid, message: bounded(error.description))
        }
    }

    static func classify(_ error: ResticRunnerError) -> CLIFailure {
        switch error {
        case .secretsNotConfigured(let destinationId):
            return CLIFailure(
                code: .secretNotConfigured,
                message: error.userFacingMessage,
                details: CLIErrorDetails(
                    destinationId: destinationId,
                    resticCategory: error.category
                )
            )
        case .secretsUnavailable(let destinationId):
            return CLIFailure(
                code: .secretUnavailable,
                message: error.userFacingMessage,
                details: CLIErrorDetails(
                    destinationId: destinationId,
                    resticCategory: error.category
                )
            )
        case .launchFailed:
            return CLIFailure(
                code: .resticNotFound,
                message: error.userFacingMessage,
                details: CLIErrorDetails(resticCategory: error.category)
            )
        case .timedOut:
            return CLIFailure(
                code: .resticFailed,
                message: error.userFacingMessage,
                details: CLIErrorDetails(resticCategory: error.category)
            )
        }
    }

    static func classify(_ error: SecretStoreError) -> CLIFailure {
        // The acceptance criterion is that the macOS keychain backend and
        // the Linux file backend map to the *same* logical code — and they
        // do: both report a missing item as `itemNotFound` and everything
        // else as `backendFailed`, so this split is by condition, not by
        // backend. It is `retryable` that forces it. `backendFailed` is a
        // backend that answered badly and may answer well later; a missing
        // item is a stable fact about this host until someone runs
        // `secret set`, and publishing `retryable: true` for it would tell
        // an automated caller to loop forever on a request that cannot
        // succeed. The backend's own diagnostic text stays in `message`,
        // bounded, and never reaches `details`.
        switch error {
        case .itemNotFound:
            return CLIFailure(code: .secretNotConfigured, message: error.description)
        case .backendFailed:
            return CLIFailure(code: .secretUnavailable, message: error.description)
        }
    }

    /// restic ran to completion and reported a failure.
    ///
    /// Separate from ``classify(_:)-(any Error)`` because a ``ResticExitClass``
    /// is not an `Error` — it is a *result*, and only the caller knows
    /// whether a given one counts as a failure at all
    /// (``ResticExitClass/warningIncompleteRead`` is a successful backup).
    public static func classify(
        exitClass: ResticExitClass,
        setId: UUID? = nil,
        destinationId: UUID? = nil,
        diagnosticReference: String? = nil
    ) -> CLIFailure {
        let code: CLIErrorCode
        var resticExitCode: Int32?
        switch exitClass {
        case .repoDoesNotExist:
            code = .repositoryNotInitialized
            resticExitCode = 10
        case .repoLocked:
            code = .repositoryLocked
            resticExitCode = 11
        case .wrongPassword:
            code = .secretRejected
            resticExitCode = 12
        case .other(let raw):
            code = .resticFailed
            resticExitCode = raw
        case .fatal:
            code = .resticFailed
            resticExitCode = 1
        case .success, .warningIncompleteRead:
            // Not failures. Reaching here means a caller asked for a
            // classification of something that succeeded; say so plainly
            // rather than inventing a plausible-looking code.
            code = .internalError
            resticExitCode = nil
        }
        return CLIFailure(
            code: code,
            message: bounded(exitClass.userFacingMessage),
            details: CLIErrorDetails(
                setId: setId,
                destinationId: destinationId,
                resticExitCode: resticExitCode,
                resticCategory: exitClass.category,
                diagnosticReference: diagnosticReference
            )
        )
    }
}

// MARK: - CLIErrorEnvelope

/// The exact document a `--json` command writes to stdout when it fails.
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "ok": false,
///   "error": {
///     "code": "repository_locked",
///     "message": "The repository is locked by another operation. …",
///     "retryable": true,
///     "details": { "destinationId": "…" }
///   }
/// }
/// ```
///
/// `ok` is always `false` — an envelope is only ever produced for a failure.
/// It is present so a caller can branch on one field without first checking
/// whether `error` exists, and so the success shapes #79 introduces can
/// carry the same discriminator.
public struct CLIErrorEnvelope: Encodable, Equatable, Sendable {

    /// Bumped only for a **breaking** change to the envelope's shape.
    /// Adding a ``CLIErrorCode`` case or a ``CLIErrorDetails`` field is
    /// additive and does not bump it — see the note on ``CLIErrorCode``.
    public static let schemaVersion = 1

    public struct ErrorBody: Encodable, Equatable, Sendable {
        public let code: CLIErrorCode
        public let message: String
        public let retryable: Bool
        public let details: CLIErrorDetails?
    }

    public let schemaVersion: Int
    public let ok: Bool
    public let error: ErrorBody

    public init(_ failure: CLIFailure) {
        self.schemaVersion = Self.schemaVersion
        self.ok = false
        self.error = ErrorBody(
            code: failure.code,
            message: failure.message,
            retryable: failure.retryable,
            details: failure.details.isEmpty ? nil : failure.details
        )
    }
}
