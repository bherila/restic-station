import Foundation

/// The result of probing a single destination for reachability.
///
/// - ``reachable``: the repository answered (local path exists, or remote
///   `cat config` exited 0).
/// - ``offline(reason:)``: the destination could not be reached at all —
///   missing local volume, network/launch failure, timeout, or a locked
///   keychain. These are transient/environmental: retry later, no user
///   action implied beyond "try again" (or "unlock your keychain").
/// - ``error(_:)``: restic *ran* against the repository and reported a
///   problem with the repository itself (wrong password, repository does
///   not exist, ...). These need user attention — they are not "offline".
public enum RepoProbeResult: Equatable, Sendable {
    case reachable
    case offline(reason: String)
    case error(ResticExitClass)
    /// The pre-flight refused before restic could run, and repeating the
    /// identical probe cannot change the answer: nothing is stored for this
    /// destination, the secret store will not be read at all, or a
    /// cloud-synced local repository has online-only files.
    ///
    /// Distinct from ``offline`` because a caller is told to *retry* an
    /// offline probe — `probe-repo` publishes it as `ok: true`, exit 3, on
    /// the grounds that an unplugged drive is a destination's expected
    /// state. That advice is wrong for a refusal whose message names the
    /// `chmod` or the `secret set` to run (#96). Distinct from ``error``
    /// because that carries a ``ResticExitClass``, and inventing one here
    /// would publish an exit code restic never produced.
    case needsAttention(DestinationAttention, reason: String)
}

/// Destination reachability probing — see `docs/data-model.md`
/// §state/repo-status and `docs/architecture.md` §Process model.
///
/// Local-path destinations (including `/Volumes/...` and iCloud paths) are
/// probed with a plain `FileManager` existence check — no restic invocation —
/// plus, under a cloud root, a metadata-only scan for online-only entries.
/// Every other destination kind is probed with the cheap `restic cat config`
/// read-only command (`docs/restic-cli.md` §version / cat config), bounded
/// by a 10 s timeout.
public struct Reachability: Sendable {
    /// Wall-clock bound for the remote `cat config` probe.
    static let probeTimeout: TimeInterval = 10

    private let restic: ResticRunner
    private let datalessRepositoryEntry: @Sendable (String) -> String?

    /// - Parameter datalessRepositoryEntry: the first online-only entry of a
    ///   local repository path, or nil. Injected so the probe's refusal can
    ///   be tested on hosts without File Provider placeholders.
    public init(
        restic: ResticRunner,
        datalessRepositoryEntry: @escaping @Sendable (String) -> String? = { path in
            CloudStorageSafety.firstDatalessEntry(inRepository: path)
        }
    ) {
        self.restic = restic
        self.datalessRepositoryEntry = datalessRepositoryEntry
    }

    public func probe(
        _ dest: Destination,
        destinationSecretEnv: [String: String]? = nil,
        expectedExecutableIdentity: String? = nil
    ) async -> RepoProbeResult {
        if dest.kind == .localPath {
            return Self.probeLocal(dest, datalessEntry: datalessRepositoryEntry)
        }
        return await probeRemote(
            dest,
            destinationSecretEnv: destinationSecretEnv,
            expectedExecutableIdentity: expectedExecutableIdentity
        )
    }

    // MARK: - Local

    static func probeLocal(
        _ dest: Destination,
        datalessEntry: (String) -> String? = { _ in nil }
    ) -> RepoProbeResult {
        let path = dest.repoURL
        if FileManager.default.fileExists(atPath: path) {
            // A metadata-only walk, and only for a path under a cloud root.
            // Reported here, before anything runs restic, so every command
            // that probes first publishes the refusal as itself rather than
            // as a restic failure — and the badge reads Error, not Offline.
            if let entry = datalessEntry(path) {
                return .needsAttention(
                    .cloudRepositoryNotHydrated,
                    reason: "repository is not fully downloaded (\(entry) is online-only)"
                )
            }
            return .reachable
        }
        if let root = volumeRoot(forPath: path), !FileManager.default.fileExists(atPath: root) {
            return .offline(reason: "volume not mounted")
        }
        return .offline(reason: "repository path does not exist")
    }

    /// For a path under `/Volumes/`, the mountpoint that must exist for the
    /// volume to be mounted at all — `/Volumes/<name>`. `nil` if `path` is
    /// not under `/Volumes/`.
    static func volumeRoot(forPath path: String) -> String? {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return nil }
        let remainder = path.dropFirst(prefix.count)
        guard let slashIndex = remainder.firstIndex(of: "/") else {
            // `path` IS the volume root (no subpath component after it).
            return path
        }
        return prefix + remainder[remainder.startIndex..<slashIndex]
    }

    // MARK: - Remote

    private func probeRemote(
        _ dest: Destination,
        destinationSecretEnv: [String: String]?,
        expectedExecutableIdentity: String?
    ) async -> RepoProbeResult {
        do {
            let outcome = try await restic.run(
                .catConfig(repo: dest.repoURL),
                for: ResticInvocation(
                    destination: dest,
                    destinationSecretEnv: destinationSecretEnv,
                    expectedExecutableIdentity: expectedExecutableIdentity
                ),
                timeout: Self.probeTimeout
            )
            if outcome.status == .success {
                return .reachable
            }
            // restic ran and reported a problem with the repository itself
            // (wrong password, missing repo, locked, fatal, ...) — that is
            // NOT "offline", it needs user attention.
            return .error(outcome.status)
        } catch let error as ResticRunnerError {
            switch error {
            case .secretsUnavailable:
                // Retryable, not alarming — see docs/architecture.md
                // §Error taxonomy and ResticRunnerError.secretsUnavailable.
                // This string is persisted to `repo-status-<destId>.json` and
                // matched by the app's badge heuristic (`SetsBadges`). Taken
                // from the store actually in use, so a macOS host running the
                // file backend does not record "keychain locked"; the
                // keychain backend's string is unchanged from before T23.
                return .offline(reason: restic.secretBackend.unavailableProbeReason)
            case .secretsNotConfigured:
                // Not environmental: nothing is stored, and no amount of
                // waiting changes that. The reason string is deliberately
                // outside `SetsBadges`'s environmental list, so the badge
                // reads "Error" (needs attention) rather than "Offline"
                // (try later) — and it is unchanged from when this case
                // returned `.offline`, because that string is persisted
                // and matched.
                return .needsAttention(
                    .secretNotConfigured,
                    reason: "no password stored for this destination"
                )
            case .secretsStoreUnusable:
                // Also not environmental, and for a stronger reason than
                // `secretsNotConfigured`: the store refused to be read at
                // all and its refusal already names the fix. The reason
                // string is deliberately outside `SetsBadges`'s
                // environmental list — note that list matches the bare
                // substring "could not", which is why this wording avoids
                // it — so the badge reads "Error" rather than "Offline".
                return .needsAttention(
                    .secretStoreUnusable,
                    reason: "the secret store is not usable as configured"
                )
            case .cloudRepositoryNotHydrated:
                // Not reached by today's probes: the dataless pre-flight only
                // examines local-path repositories, and those are probed with
                // an existence check that never runs restic. Mapped rather
                // than defaulted so the switch stays exhaustive.
                return .offline(reason: error.userFacingMessage)
            case .timedOut:
                return .offline(reason: "timed out")
            case .launchFailed(let reason):
                return .offline(reason: reason)
            }
        } catch {
            // CancellationError or anything else unexpected: treat as an
            // offline probe rather than crashing a non-throwing API.
            return .offline(reason: "\(error)")
        }
    }
}
