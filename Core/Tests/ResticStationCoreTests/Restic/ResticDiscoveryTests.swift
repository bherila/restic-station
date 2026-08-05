import Foundation
import Testing

@testable import ResticStationCore

/// `ResticDiscovery` moved from `App/` to Core in T25 so the helper can use
/// it on Linux. These tests exist to make sure nothing was lost in the move:
/// the probe-by-running rule, the per-candidate timeout, and the candidate
/// cap are all load-bearing.
///
/// Everything here runs on **both** platforms: the well-known list is
/// injected and the "binaries" are real files in a temp directory that the
/// fake runner decides the fate of, so macOS CI genuinely exercises the code
/// path Linux takes.
@Suite struct ResticDiscoveryTests {

    // MARK: - Test doubles

    /// A `ProcessRunning` keyed by executable path (unlike the sequential
    /// `FakeProcessRunner`, discovery's whole point is *which* candidate got
    /// run, and in what order). Records every argv and the timeout it was
    /// handed.
    final class ProbeRunner: ProcessRunning, @unchecked Sendable {
        enum Behaviour {
            /// Ran and printed a `version --json` object.
            case reports(version: String)
            /// Ran and exited nonzero (a Homebrew shim for an uninstalled
            /// formula does this).
            case exits(code: Int32, stderr: String)
            /// Ran and printed something that is not restic's version JSON.
            case printsGarbage(String)
            /// Could not be launched at all (bad architecture, broken
            /// interpreter line, dangling symlink target).
            case failsToLaunch
            /// Hung past the deadline.
            case timesOut
        }

        private let lock = NSLock()
        private var behaviours: [String: Behaviour]
        private var _calls: [(argv: [String], timeout: TimeInterval?)] = []

        init(_ behaviours: [String: Behaviour]) {
            self.behaviours = behaviours
        }

        /// Scoped rather than bare `lock()`/`unlock()` calls: the latter are
        /// unavailable from an async context.
        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var calls: [(argv: [String], timeout: TimeInterval?)] {
            withLock { _calls }
        }

        var probedPaths: [String] {
            calls.compactMap { call in call.argv.first }
        }

        func run(
            _ argv: [String],
            env: [String: String]?,
            currentDirectory: String?,
            onStdoutLine: (@Sendable (String) -> Void)?,
            onStderrLine: (@Sendable (String) -> Void)?,
            timeout: TimeInterval?
        ) async throws -> ProcessResult {
            let behaviour = withLock { () -> Behaviour in
                _calls.append((argv, timeout))
                return behaviours[argv.first ?? ""] ?? .failsToLaunch
            }

            #expect(env == nil, "the probe must not pass an environment (rule 3)")

            switch behaviour {
            case .reports(let version):
                let json = """
                    {"version":"\(version)","go_version":"go1.22.0","go_os":"linux","go_arch":"arm64"}
                    """
                return ProcessResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
            case .exits(let code, let stderr):
                return ProcessResult(exitCode: code, stdout: Data(), stderr: Data(stderr.utf8))
            case .printsGarbage(let text):
                return ProcessResult(exitCode: 0, stdout: Data(text.utf8), stderr: Data())
            case .failsToLaunch:
                throw ProcessRunnerError.launchFailed("Bad CPU type in executable")
            case .timesOut:
                throw ProcessRunnerError.timeout
            }
        }
    }

    /// A temp directory of real, executable, entirely inert files — enough
    /// to satisfy `fileExists` + `isExecutableFile`, which is exactly the
    /// filter the probe-by-running rule refuses to trust on its own.
    final class FakeBinaries {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("restic-discovery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        /// Explicit rather than a `deinit`: the test only holds the
        /// directory alive through a local `let`, and ARC is free to release
        /// that before the test body ends.
        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        /// Creates an executable file and returns its absolute path.
        @discardableResult
        func makeExecutable(_ relativePath: String) throws -> String {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }

        /// Creates a non-executable regular file and returns its path.
        @discardableResult
        func makeNonExecutable(_ relativePath: String) throws -> String {
            let path = try makeExecutable(relativePath)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            return path
        }

        func directory(_ relativePath: String) throws -> String {
            let url = root.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
    }

    // MARK: - Platform-conditional well-known lists

    @Test("the documented per-platform well-known lists")
    func wellKnownListsAreTheDocumentedOnes() {
        #expect(ResticDiscovery.macOSWellKnownPaths == [
            "/opt/homebrew/bin/restic",
            "/usr/local/bin/restic",
            "/opt/local/bin/restic",
        ])
        #expect(ResticDiscovery.linuxWellKnownPaths == [
            "/usr/bin/restic",
            "/usr/local/bin/restic",
            "/opt/restic/bin/restic",
        ])
    }

    @Test("the default list is the one for the platform this build targets")
    func defaultWellKnownListIsPlatformConditional() {
        #if os(macOS)
        #expect(ResticDiscovery.wellKnownPaths == ResticDiscovery.macOSWellKnownPaths)
        #expect(!ResticDiscovery.wellKnownPaths.contains("/usr/bin/restic"))
        #else
        #expect(ResticDiscovery.wellKnownPaths == ResticDiscovery.linuxWellKnownPaths)
        #expect(!ResticDiscovery.wellKnownPaths.contains("/opt/homebrew/bin/restic"))
        #endif
    }

    // MARK: - Candidate list

    @Test("well-known locations are searched before PATH")
    func wellKnownComesFirst() throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let wellKnown = try binaries.makeExecutable("opt/restic")
        let pathDir = try binaries.directory("pathbin")
        try binaries.makeExecutable("pathbin/restic")

        let discovery = ResticDiscovery(
            wellKnownPaths: [wellKnown],
            environment: ["PATH": pathDir],
            runner: ProbeRunner([:])
        )
        #expect(discovery.candidatePaths() == [wellKnown, pathDir + "/restic"])
    }

    @Test("relative PATH entries are dropped, absolute ones are normalized")
    func relativePathEntriesAreDropped() throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let pathDir = try binaries.directory("bin")
        let candidate = try binaries.makeExecutable("bin/restic")

        let discovery = ResticDiscovery(
            wellKnownPaths: [],
            // Leading colon (= cwd), a relative entry, and a trailing slash.
            environment: ["PATH": ":relative/bin:\(pathDir)/"],
            runner: ProbeRunner([:])
        )
        #expect(discovery.candidatePaths() == [candidate])
    }

    @Test("non-executable files and directories are never candidates")
    func onlyExecutableRegularFilesAreCandidates() throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let notExecutable = try binaries.makeNonExecutable("a/restic")
        let directoryNamedRestic = try binaries.directory("b/restic")
        let good = try binaries.makeExecutable("c/restic")

        let discovery = ResticDiscovery(
            wellKnownPaths: [notExecutable, directoryNamedRestic, good],
            environment: [:],
            runner: ProbeRunner([:])
        )
        #expect(discovery.candidatePaths() == [good])
    }

    @Test("a symlink to an already-seen binary is not probed twice")
    func symlinksAreDeduplicated() throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let real = try binaries.makeExecutable("real/restic")
        let linkDir = try binaries.directory("link")
        let link = linkDir + "/restic"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        let discovery = ResticDiscovery(
            wellKnownPaths: [real, link],
            environment: [:],
            runner: ProbeRunner([:])
        )
        #expect(discovery.candidatePaths() == [real])
    }

    @Test("a pathological PATH cannot exceed the candidate cap")
    func candidateCountIsCapped() throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        var directories: [String] = []
        for index in 0..<(ResticDiscovery.maxCandidates + 10) {
            directories.append(try binaries.directory("bin\(index)"))
            try binaries.makeExecutable("bin\(index)/restic")
        }

        let discovery = ResticDiscovery(
            wellKnownPaths: [],
            environment: ["PATH": directories.joined(separator: ":")],
            runner: ProbeRunner([:])
        )
        #expect(discovery.candidatePaths().count == ResticDiscovery.maxCandidates)
    }

    @Test("the cap bounds how many candidates are actually executed")
    func discoveryExecutesNoMoreThanTheCap() async throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        var directories: [String] = []
        for index in 0..<(ResticDiscovery.maxCandidates + 10) {
            directories.append(try binaries.directory("bin\(index)"))
            try binaries.makeExecutable("bin\(index)/restic")
        }

        // Every candidate exists and is +x, and none of them run: the worst
        // case, where only the cap stops the search.
        let runner = ProbeRunner([:])
        let discovery = ResticDiscovery(
            wellKnownPaths: [],
            environment: ["PATH": directories.joined(separator: ":")],
            runner: runner
        )
        let result = await discovery.discover()
        #expect(result.chosen == nil)
        #expect(runner.calls.count == ResticDiscovery.maxCandidates)
    }

    // MARK: - The probe-by-running rule

    @Test("a candidate that exists and is +x but fails to run is NOT found")
    func executableThatCannotRunIsRejected() async throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let shim = try binaries.makeExecutable("opt/homebrew/bin/restic")

        // The filesystem says yes to both questions discovery is allowed to
        // ask cheaply…
        #expect(FileManager.default.fileExists(atPath: shim))
        #expect(FileManager.default.isExecutableFile(atPath: shim))

        let runner = ProbeRunner([shim: .failsToLaunch])
        let discovery = ResticDiscovery(wellKnownPaths: [shim], environment: [:], runner: runner)

        let result = await discovery.discover()
        // …and it is still not a find, because it never ran.
        #expect(result.chosen == nil)
        #expect(result.rejected.count == 1)
        #expect(result.rejected[0].path == shim)
        #expect(result.rejected[0].isUsable == false)
        if case .unusable = result.rejected[0].outcome {} else {
            Issue.record("expected .unusable, got \(result.rejected[0].outcome)")
        }
        // And it was rejected by *running* it, not by inspecting it.
        #expect(runner.probedPaths == [shim])
        #expect(runner.calls[0].argv == [shim, "version", "--json"])
    }

    @Test("a candidate that runs but is not restic is NOT found")
    func executableThatIsNotResticIsRejected() async throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let impostor = try binaries.makeExecutable("bin/restic")

        let runner = ProbeRunner([impostor: .printsGarbage("restic 0.18.1 compiled with go1.22\n")])
        let discovery = ResticDiscovery(wellKnownPaths: [impostor], environment: [:], runner: runner)

        let result = await discovery.discover()
        #expect(result.chosen == nil)
        #expect(result.rejected.first?.version == nil)
    }

    @Test("a candidate that runs and exits nonzero is NOT found")
    func executableThatExitsNonzeroIsRejected() async throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let broken = try binaries.makeExecutable("bin/restic")

        let runner = ProbeRunner([
            broken: .exits(code: 127, stderr: "Error: restic is not installed"),
        ])
        let discovery = ResticDiscovery(wellKnownPaths: [broken], environment: [:], runner: runner)

        let result = await discovery.discover()
        #expect(result.chosen == nil)
        if case .unusable(let reason) = result.rejected.first?.outcome {
            #expect(reason.contains("127"))
            #expect(reason.contains("restic is not installed"))
        } else {
            Issue.record("expected .unusable with the exit code and stderr")
        }
    }

    @Test("probing never inherits an environment and always carries the timeout")
    func everyProbeIsBoundedAndEnvironmentFree() async throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let hung = try binaries.makeExecutable("a/restic")
        let good = try binaries.makeExecutable("b/restic")

        let runner = ProbeRunner([hung: .timesOut, good: .reports(version: "0.18.1")])
        let discovery = ResticDiscovery(
            wellKnownPaths: [hung, good],
            environment: [:],
            runner: runner
        )

        let result = await discovery.discover()
        #expect(result.chosen?.path == good)
        // A hung candidate is bounded and does not abort the search.
        #expect(runner.calls.count == 2)
        for call in runner.calls {
            #expect(call.timeout == ResticDiscovery.probeTimeout)
        }
        if case .unusable(let reason) = result.rejected.first?.outcome {
            #expect(reason.contains("did not respond"))
        } else {
            Issue.record("expected the timed-out candidate to be reported as unusable")
        }
    }

    // MARK: - Version gating and ordering

    @Test("the first candidate meeting the minimum wins and stops the search")
    func firstUsableCandidateWins() async throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let first = try binaries.makeExecutable("a/restic")
        let second = try binaries.makeExecutable("b/restic")

        let runner = ProbeRunner([
            first: .reports(version: "0.18.1"),
            second: .reports(version: "0.19.0"),
        ])
        let discovery = ResticDiscovery(
            wellKnownPaths: [first, second],
            environment: [:],
            runner: runner
        )

        let result = await discovery.discover()
        #expect(result.chosen?.path == first)
        #expect(result.chosen?.version == "0.18.1")
        #expect(runner.probedPaths == [first], "the search must stop at the first usable candidate")
    }

    @Test("a too-old binary is remembered but does not end the search")
    func tooOldIsRememberedAndOvertaken() async throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let old = try binaries.makeExecutable("a/restic")
        let new = try binaries.makeExecutable("b/restic")

        let runner = ProbeRunner([
            old: .reports(version: "0.16.4"),
            new: .reports(version: "0.18.1"),
        ])
        let discovery = ResticDiscovery(
            wellKnownPaths: [old, new],
            environment: [:],
            runner: runner
        )

        let result = await discovery.discover()
        #expect(result.chosen?.path == new)
        #expect(result.firstTooOld?.path == old)
        #expect(result.firstTooOld?.version == "0.16.4")
    }

    @Test("the minimum version is the documented one")
    func minimumVersionIsDocumented() {
        #expect(ResticDiscovery.minimumVersion == "0.17.0")
    }

    // MARK: - probe(path:)

    @Test("a relative path is refused without running anything")
    func relativePathIsRefused() async {
        let runner = ProbeRunner([:])
        let discovery = ResticDiscovery(wellKnownPaths: [], environment: [:], runner: runner)
        let probe = await discovery.probe(path: "restic")
        #expect(probe.isUsable == false)
        #expect(runner.calls.isEmpty)
    }

    @Test("a nonexistent path is refused without running anything")
    func missingPathIsRefused() async throws {
        let binaries = try FakeBinaries()
        defer { binaries.cleanup() }
        let runner = ProbeRunner([:])
        let discovery = ResticDiscovery(wellKnownPaths: [], environment: [:], runner: runner)
        let probe = await discovery.probe(path: binaries.root.appendingPathComponent("nope").path)
        #expect(probe.isUsable == false)
        #expect(runner.calls.isEmpty)
    }

    // MARK: - searchedDescription

    @Test("the failure message names what was searched")
    func searchedDescriptionNamesTheList() {
        let discovery = ResticDiscovery(
            wellKnownPaths: ResticDiscovery.linuxWellKnownPaths,
            environment: [:],
            runner: ProbeRunner([:])
        )
        #expect(discovery.searchedDescription
            == "/usr/bin/restic, /usr/local/bin/restic, /opt/restic/bin/restic, and every directory on PATH")
    }
}
