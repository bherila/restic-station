import Foundation
import Testing
@testable import ResticStationCore

@Suite("Reachability: local existence checks + remote cat-config probe")
struct ReachabilityTests {
    static let destId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    static let password = "correct-horse-battery-staple"

    static func paths() -> AppPaths {
        AppPaths(root: URL(fileURLWithPath: "/tmp/restic-station-reachability-tests", isDirectory: true))
    }

    static func makeReachability(
        _ fake: FakeProcessRunner,
        secrets: FakeSecretStore = FakeSecretStore(defaultPassword: password)
    ) -> Reachability {
        let runner = ResticRunner(
            resticPath: "/usr/local/bin/restic",
            paths: paths(),
            secrets: secrets,
            runner: fake
        )
        return Reachability(restic: runner)
    }

    /// The `offline` reason `ResticRunner`'s secret pre-flight produces —
    /// taken from the **store in use**, not from the host OS. The keychain
    /// wording (which the app's badge heuristic matches on) is unchanged by
    /// T23.
    static var secretsUnavailableReason: String {
        SecretBackend.platformDefault.unavailableProbeReason
    }

    // MARK: - Local: present / missing

    @Test("local path that exists is reachable")
    func localPathExists() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-reachability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dest = Destination(id: Self.destId, label: "Local", repoURL: dir.path, isPrimary: true)
        let reachability = Self.makeReachability(FakeProcessRunner())

        let result = await reachability.probe(dest)
        #expect(result == .reachable)
    }

    @Test("local path that does not exist (not under /Volumes) is offline with a generic reason")
    func localPathMissingGenericReason() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let dest = Destination(id: Self.destId, label: "Local", repoURL: missing.path, isPrimary: true)
        let reachability = Self.makeReachability(FakeProcessRunner())

        let result = await reachability.probe(dest)
        #expect(result == .offline(reason: "repository path does not exist"))
    }

    @Test("missing repo under an unmounted /Volumes volume reports 'volume not mounted'")
    func localPathUnderUnmountedVolume() async throws {
        let dest = Destination(
            id: Self.destId,
            label: "External HDD",
            repoURL: "/Volumes/NoSuchTestVolume-\(UUID().uuidString)/proj.restic",
            isPrimary: true
        )
        let reachability = Self.makeReachability(FakeProcessRunner())

        let result = await reachability.probe(dest)
        #expect(result == .offline(reason: "volume not mounted"))
    }

    @Test("volumeRoot(forPath:) extracts the /Volumes/<name> mountpoint")
    func volumeRootExtraction() {
        #expect(Reachability.volumeRoot(forPath: "/Volumes/BackupDisk/proj.restic") == "/Volumes/BackupDisk")
        #expect(Reachability.volumeRoot(forPath: "/Volumes/BackupDisk") == "/Volumes/BackupDisk")
        #expect(Reachability.volumeRoot(forPath: "/Users/user/proj.restic") == nil)
    }

    // MARK: - Remote: exit 0 / timeout / exit 10 / exit 12 / keychain failure

    @Test("remote destination: exit 0 is reachable")
    func remoteExitZeroIsReachable() async throws {
        let dest = Destination(id: Self.destId, label: "R2", repoURL: "s3:https://x/bucket", isPrimary: false)
        let fake = FakeProcessRunner(script: [
                .init(argvPrefix: ["/usr/local/bin/restic", "-r", dest.repoURL, "cat", "config"], exitCode: 0),
            ]
        )
        let reachability = Self.makeReachability(fake)

        let result = await reachability.probe(dest)
        #expect(result == .reachable)

        // Verify the probe used the documented 10s timeout / catConfig argv.
        let resticCall = fake.invocations.last
        #expect(resticCall?.argv == ["/usr/local/bin/restic", "-r", dest.repoURL, "cat", "config"])
    }

    @Test("remote destination: a ProcessRunning timeout is offline, not error")
    func remoteTimeoutIsOffline() async throws {
        let dest = Destination(id: Self.destId, label: "R2", repoURL: "s3:https://x/bucket", isPrimary: false)
        let fake = FakeProcessRunner(script: [
                .init(argvPrefix: ["/usr/local/bin/restic", "-r", dest.repoURL, "cat", "config"], failure: .timeout),
            ]
        )
        let reachability = Self.makeReachability(fake)

        let result = await reachability.probe(dest)
        #expect(result == .offline(reason: "timed out"))
    }

    @Test("remote destination: a delayed reply beyond the timeout still resolves (offline via scripted timeout failure)")
    func remoteDelayedReplyScriptedAsTimeout() async throws {
        // FakeProcessRunner does not itself enforce `timeout` against
        // `delay` (that enforcement lives in DefaultProcessRunner); the
        // documented way to exercise "timeout elapsed" through the fake is
        // to script `failure: .timeout`, exactly as ResticRunnerTests does.
        // This test additionally exercises a nonzero `delay` alongside it to
        // confirm Reachability still surfaces the timeout mapping when the
        // fake takes some (bounded) time before throwing.
        let dest = Destination(id: Self.destId, label: "R2", repoURL: "s3:https://x/bucket", isPrimary: false)
        let fake = FakeProcessRunner(script: [
                .init(
                    argvPrefix: ["/usr/local/bin/restic", "-r", dest.repoURL, "cat", "config"],
                    delay: 0.05,
                    failure: .timeout
                ),
            ]
        )
        let reachability = Self.makeReachability(fake)

        let result = await reachability.probe(dest)
        #expect(result == .offline(reason: "timed out"))
    }

    @Test("remote destination: exit 10 (repo does not exist) is .error, not .offline")
    func remoteExitTenIsError() async throws {
        let dest = Destination(id: Self.destId, label: "R2", repoURL: "s3:https://x/bucket", isPrimary: false)
        let fake = FakeProcessRunner(script: [
                .init(argvPrefix: ["/usr/local/bin/restic", "-r", dest.repoURL, "cat", "config"], exitCode: 10),
            ]
        )
        let reachability = Self.makeReachability(fake)

        let result = await reachability.probe(dest)
        #expect(result == .error(.repoDoesNotExist))
    }

    @Test("remote destination: exit 12 (wrong password) is .error, not .offline")
    func remoteExitTwelveIsError() async throws {
        let dest = Destination(id: Self.destId, label: "R2", repoURL: "s3:https://x/bucket", isPrimary: false)
        let fake = FakeProcessRunner(script: [
                .init(argvPrefix: ["/usr/local/bin/restic", "-r", dest.repoURL, "cat", "config"], exitCode: 12),
            ]
        )
        let reachability = Self.makeReachability(fake)

        let result = await reachability.probe(dest)
        #expect(result == .error(.wrongPassword))
    }

    @Test("remote destination: secret pre-flight failure is offline, never .error")
    func remoteSecretPreflightFailureIsOffline() async throws {
        let dest = Destination(id: Self.destId, label: "R2", repoURL: "s3:https://x/bucket", isPrimary: false)
        let fake = FakeProcessRunner()
        let secrets = FakeSecretStore(defaultPassword: Self.password)
        secrets.failPassword(for: Self.destId)
        let reachability = Self.makeReachability(fake, secrets: secrets)

        let result = await reachability.probe(dest)
        #expect(result == .offline(reason: Self.secretsUnavailableReason))
        // restic itself was never spawned.
        #expect(fake.invocations.isEmpty)
    }

    /// Regression test for the review finding that this reason branched on
    /// `#if os(macOS)`. A macOS host running `RESTIC_STATION_SECRET_BACKEND=file`
    /// must not record "keychain locked" in `repo-status-<destId>.json`, and
    /// a keychain host must still record exactly that (the app's badge
    /// heuristic matches on it).
    @Test("the offline reason names the store in use, on every host")
    func secretPreflightReasonFollowsTheBackend() async throws {
        let dest = Destination(id: Self.destId, label: "R2", repoURL: "s3:https://x/bucket", isPrimary: false)

        for backend in SecretBackend.allCases {
            let secrets = FakeSecretStore(defaultPassword: Self.password, backend: backend)
            secrets.failPassword(for: Self.destId)
            let reachability = Self.makeReachability(FakeProcessRunner(), secrets: secrets)

            let result = await reachability.probe(dest)
            #expect(result == .offline(reason: backend.unavailableProbeReason))
        }
    }

    @Test("remote destination: launch failure is offline with the launch failure reason")
    func remoteLaunchFailureIsOffline() async throws {
        let dest = Destination(id: Self.destId, label: "R2", repoURL: "s3:https://x/bucket", isPrimary: false)
        let fake = FakeProcessRunner(script: [
                .init(
                    argvPrefix: ["/usr/local/bin/restic", "-r", dest.repoURL, "cat", "config"],
                    failure: .launchFailed("No such file or directory")
                ),
            ]
        )
        let reachability = Self.makeReachability(fake)

        let result = await reachability.probe(dest)
        #expect(result == .offline(reason: "No such file or directory"))
    }
}
