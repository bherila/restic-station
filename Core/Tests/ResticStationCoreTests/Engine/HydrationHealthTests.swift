import Foundation
import Testing
@testable import ResticStationCore

/// #180: a local repository in cloud storage with online-only files reaches
/// set health as `cloudRepositoryNotHydrated`, from the probe or the
/// runner's refusal through the destination's repo status, and clears once
/// a later look finds every file local.
@Suite struct HydrationHealthTests {
    typealias T = BackupEngineTests

    /// Which repositories have an online-only entry right now. Mutable so a
    /// test can download the files between two runs.
    final class OnlineOnly: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String>

        init(_ paths: Set<String> = []) { self.paths = paths }

        func set(_ newPaths: Set<String>) {
            lock.lock()
            paths = newPaths
            lock.unlock()
        }

        var entry: @Sendable (String) -> String? {
            { [self] path in
                lock.lock()
                defer { lock.unlock() }
                return paths.contains(path) ? "data/ab/abcdef" : nil
            }
        }
    }

    static let anything = SecretPreflightAttentionTests.anything

    /// What the menu bar and `status` would derive from this env's state.
    static func health(_ env: T.Env) -> SetHealth {
        var statuses: [UUID: RepoStatus] = [:]
        var secretAttention: [UUID: SecretAttentionRecord] = [:]
        for destination in env.set.destinations {
            statuses[destination.id] = env.stateStore.readRepoStatus(destId: destination.id)
            secretAttention[destination.id] = env.stateStore.readSecretAttention(destId: destination.id)
        }
        return HealthDerivation.setHealth(
            set: env.set,
            recentRuns: env.indexEntries.reversed(),
            currentRun: nil,
            repoStatuses: statuses,
            setScheduleState: env.stateStore.readScheduleState()?.sets[T.setId],
            now: env.clock.now(),
            calendar: Calendar(identifier: .gregorian),
            secretAttention: secretAttention
        )
    }

    @Test("a primary with online-only files shows as not downloaded, then clears once it is local")
    func primaryNotDownloadedThenCleared() async throws {
        let online = OnlineOnly()
        let env = T.makeEnv(
            script: [], retention: nil, reachableSecondaries: [],
            probeDatalessEntry: online.entry, runnerDatalessEntry: online.entry
        )
        defer { env.cleanUp() }
        online.set([env.primary.repoURL])

        _ = await env.engine.runSet(env.set, trigger: .scheduled)

        #expect(env.fake.invocations.isEmpty, "restic must not read an online-only repository")
        let problem = try #require(Self.health(env).primarySecretProblem)
        #expect(problem.attention == .cloudRepositoryNotHydrated)
        #expect(problem.detail.contains("data/ab/abcdef"))
        #expect(problem.detectedAt == T.t0)
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId) == nil, "not a secret problem")

        // Still online-only an hour later: first seen is kept.
        env.clock.advance(3600)
        _ = await env.engine.runSet(env.set, trigger: .scheduled)
        #expect(Self.health(env).primarySecretProblem?.detectedAt == T.t0)

        // Downloaded: the next probe finds every file local.
        online.set([])
        env.fake.script = Self.anything
        _ = await env.engine.runSet(env.set, trigger: .scheduled)
        #expect(Self.health(env).secretAttention.isEmpty)
    }

    /// The nearest independent constraint: a mirror's problem must not read
    /// as the primary's, which would say the whole set is skipped.
    @Test("a mirror with online-only files shows as not downloaded, and only for the mirror")
    func mirrorNotDownloaded() async throws {
        let online = OnlineOnly()
        let env = T.makeEnv(
            script: [], retention: nil, reachableSecondaries: [true],
            probeDatalessEntry: online.entry, runnerDatalessEntry: online.entry
        )
        defer { env.cleanUp() }
        online.set([env.secondaries[0].repoURL])
        env.fake.script = Self.anything

        _ = await env.engine.runSet(env.set, trigger: .scheduled)

        let health = Self.health(env)
        #expect(health.primarySecretProblem == nil)
        #expect(health.secretAttention.map(\.destId) == [T.secondaryAId])
        #expect(health.secretAttention.first?.attention == .cloudRepositoryNotHydrated)
        #expect(health.needsAttention)
    }

    /// Evicted after the probe passed, so only the runner's own check at
    /// launch sees it.
    @Test("the runner's refusal after a passing probe is recorded too")
    func runnerRefusalIsRecorded() async throws {
        let online = OnlineOnly()
        let env = T.makeEnv(
            script: [], retention: nil, reachableSecondaries: [],
            probeDatalessEntry: { _ in nil }, runnerDatalessEntry: online.entry
        )
        defer { env.cleanUp() }
        online.set([env.primary.repoURL])

        _ = await env.engine.runSet(env.set, trigger: .scheduled)

        #expect(env.fake.invocations.isEmpty)
        #expect(env.stateStore.readRepoStatus(destId: T.primaryId)?.attention == .cloudRepositoryNotHydrated)
        #expect(Self.health(env).primarySecretProblem?.attention == .cloudRepositoryNotHydrated)
    }

    // MARK: - Projection

    static let destId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let setId = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!

    static func status(_ attention: DestinationAttention?) -> RepoStatus {
        RepoStatus(
            destId: destId, reachable: false, probedAt: T.t0,
            lastError: "repository is not fully downloaded (data/ab/abcdef is online-only)",
            attention: attention, attentionSince: attention == nil ? nil : T.t0
        )
    }

    /// The secret pre-flight refuses before anything looks at the
    /// repository, so its record is the one that explains the skip.
    @Test("a secret record wins over a projected hydration problem")
    func secretRecordWins() {
        let set = BackupSet(
            id: Self.setId, name: "Projects", sources: ["/src"],
            schedule: .daily(hour: 2, minute: 30),
            destinations: [Destination(id: Self.destId, label: "Primary", repoURL: "/repo", isPrimary: true)]
        )
        let record = SecretAttentionRecord(
            destId: Self.destId, setId: Self.setId, attention: .secretNotConfigured,
            detail: "nothing stored", detectedAt: T.t0
        )
        let health = HealthDerivation.setHealth(
            set: set, recentRuns: [], currentRun: nil,
            repoStatuses: [Self.destId: Self.status(.cloudRepositoryNotHydrated)],
            setScheduleState: nil, now: T.t0, calendar: Calendar(identifier: .gregorian),
            secretAttention: [Self.destId: record]
        )
        #expect(health.secretAttention == [record])
    }

    /// Only hydration is projected. A secret case on the repo status is the
    /// probe's copy of what `state/secret-attention` owns, and the secret
    /// pre-flight clears that record, not this one.
    @Test("a secret case on the repo status is not projected")
    func secretCasesAreNotProjected() {
        for attention in DestinationAttention.allCases where attention != .cloudRepositoryNotHydrated {
            #expect(HealthDerivation.hydrationAttention(status: Self.status(attention), setId: Self.setId) == nil)
        }
        #expect(HealthDerivation.hydrationAttention(status: Self.status(nil), setId: Self.setId) == nil)
        #expect(HealthDerivation.hydrationAttention(status: nil, setId: Self.setId) == nil)
        #expect(
            HealthDerivation.hydrationAttention(status: Self.status(.cloudRepositoryNotHydrated), setId: Self.setId)
                == SecretAttentionRecord(
                    destId: Self.destId, setId: Self.setId, attention: .cloudRepositoryNotHydrated,
                    detail: "repository is not fully downloaded (data/ab/abcdef is online-only)", detectedAt: T.t0
                )
        )
    }

    // MARK: - RepoStatus.record

    @Test("every probe re-derives attention, and first seen is kept while it is unchanged")
    func recordKeepsFirstSeen() {
        let hydration = RepoProbeResult.needsAttention(.cloudRepositoryNotHydrated, reason: "not downloaded")
        var status = RepoStatus(destId: Self.destId, reachable: true, probedAt: T.t0)
        status.record(probe: hydration, at: T.t0)
        status.record(probe: hydration, at: T.t0.addingTimeInterval(60))
        #expect(status.attention == .cloudRepositoryNotHydrated)
        #expect(status.attentionSince == T.t0)
        #expect(status.probedAt == T.t0.addingTimeInterval(60))

        status.record(probe: .needsAttention(.secretNotConfigured, reason: "nothing stored"), at: T.t0.addingTimeInterval(120))
        #expect(status.attentionSince == T.t0.addingTimeInterval(120), "a different problem starts over")

        for clearing: RepoProbeResult in [.reachable, .offline(reason: "volume not mounted"), .error(.repoLocked)] {
            var cleared = status
            cleared.record(probe: clearing, at: T.t0.addingTimeInterval(180))
            #expect(cleared.attention == nil, "\(clearing)")
            #expect(cleared.attentionSince == nil, "\(clearing)")
        }
    }
}
