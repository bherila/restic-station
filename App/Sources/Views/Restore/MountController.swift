import AppKit
import Combine
import Foundation
import ResticStationCore

#if canImport(Darwin)
import Darwin
#endif

/// Owns the one `restic mount` child process the app may run
/// (`docs/restic-cli.md` §mount, `docs/ui-spec.md` §Restore: "Mount is
/// per-destination, one at a time").
///
/// Why a child process here rather than through the helper: `mount` is a
/// **read-only** FUSE view of a repository — it mutates nothing, so it falls
/// under the same sanctioned exception as `ls`/`find`
/// (`docs/architecture.md` §The single-code-path rule). It is also
/// *long-lived by design* (it blocks for as long as the mount exists), which
/// is the opposite of the helper's do-one-thing-and-exit contract: a helper
/// invocation that never returns would hold the set lock forever and stall
/// every scheduled backup.
///
/// Lifetime rules:
/// - Exactly one mount at a time; `mount(...)` refuses while one is live.
/// - Unmount is SIGINT → 5 s grace → `diskutil unmount force` → SIGKILL.
///   SIGINT first because restic tears the FUSE mount down cleanly on it;
///   `diskutil` because a FUSE mount whose server is wedged can only be
///   detached from the VFS side; SIGKILL only as the last resort.
/// - The app must never exit leaving a mount behind (the mountpoint would
///   linger in Finder as a dead volume), so this type registers an
///   `NSApplication.willTerminateNotification` observer that runs the same
///   escalation synchronously.
@MainActor
final class MountController: ObservableObject {

    /// `docs/ui-spec.md` §Restore / `docs/restic-cli.md` §mount.
    static let macFUSEPath = "/Library/Filesystems/macfuse.fs"

    /// The exact copy `docs/ui-spec.md` §Restore fixes for the disabled card.
    static let missingMacFUSECopy =
        "Mounting requires macFUSE (macfuse.github.io). You can browse and restore without it."

    static var isMacFUSEInstalled: Bool {
        FileManager.default.fileExists(atPath: macFUSEPath)
    }

    enum Phase: Equatable {
        case idle
        case mounting
        case mounted
        case unmounting
    }

    @Published private(set) var phase: Phase = .idle
    /// The destination whose repository is mounted (or being mounted).
    @Published private(set) var mountedRepositoryID: UUID?
    @Published private(set) var mountpoint: URL?
    @Published private(set) var lastError: String?

    private var process: Process?
    private var outputPipe: Pipe?
    private var output = MountOutput()
    private var terminationObserver: NSObjectProtocol?

    /// How long to wait for the mount to become browsable before reporting
    /// it as up anyway. restic populates `snapshots/`, `hosts/`, `ids/` and
    /// `tags/` as soon as FUSE is serving.
    private static let readinessTimeout: TimeInterval = 15
    private static let sigintGrace: TimeInterval = 5

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Posted on the main queue, i.e. the main actor's executor.
            MainActor.assumeIsolated {
                self?.unmountSynchronously()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Mount

    func isMounted(repositoryID: UUID) -> Bool {
        phase == .mounted && mountedRepositoryID == repositoryID
    }

    /// Spawns `restic -r <repo> mount <mountpoint>` for `repository`.
    ///
    /// The environment is assembled the same way `ResticRunner` does it
    /// (`docs/restic-cli.md` §General): a *replaced*, minimal environment
    /// with a fixed `PATH`, the destination's non-secret env, its keychain
    /// secret-env blob, and `RESTIC_PASSWORD_COMMAND` written last so no
    /// configured value can hijack how restic obtains the password. The
    /// password itself never appears in argv or in this process's memory.
    func mount(repository: RestoreRepository, resticPath: String, paths: AppPaths) async {
        guard phase == .idle else { return }
        guard Self.isMacFUSEInstalled else {
            lastError = Self.missingMacFUSECopy
            return
        }

        phase = .mounting
        lastError = nil
        mountedRepositoryID = repository.id
        output.reset()

        let directory = paths.mountsDir(destId: repository.destination.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail("The mount folder could not be created at \(directory.path): \(error.localizedDescription). "
                + "Check the permissions on that folder, then try again.")
            return
        }
        mountpoint = directory

        let environment: [String: String]
        do {
            environment = try await Self.environment(for: repository.destination, paths: paths)
        } catch {
            fail("The password for this destination could not be read from the keychain. "
                + "Unlock your login keychain, then mount again.")
            return
        }

        let command = ResticCommand.mount(repo: repository.destination.repoURL, mountpoint: directory.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resticPath)
        process.arguments = command.argv
        process.environment = environment

        let collector = output
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.append(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] finished in
            let text = collector.text()
            Task { @MainActor [weak self] in
                self?.handleTermination(status: finished.terminationStatus, output: text)
            }
        }

        do {
            try process.run()
        } catch {
            fail("restic could not be started: \(error.localizedDescription). "
                + "Check the restic path in Settings.")
            return
        }
        self.process = process
        self.outputPipe = pipe

        await waitForReadiness(process: process, directory: directory)
    }

    /// Polls until FUSE serves the mountpoint, restic exits, or the timeout
    /// elapses. Polling (rather than parsing restic's "Now serving …" line)
    /// keeps this independent of restic's human-readable output, which has
    /// no `--json` mode for `mount`.
    private func waitForReadiness(process: Process, directory: URL) async {
        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        while Date() < deadline {
            if !process.isRunning {
                // `terminationHandler` has (or is about to) set the failure.
                return
            }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            if entries.contains("snapshots") {
                phase = .mounted
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Still running but not obviously serving: report it as mounted
        // rather than killing a process that may just be slow on a remote
        // repository. "Show in Finder" tells the user the truth either way.
        if process.isRunning {
            phase = .mounted
        }
    }

    private func handleTermination(status: Int32, output text: String) {
        process = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        output.reset()
        switch phase {
        case .unmounting, .idle:
            // Expected: our own unmount, already reported.
            phase = .idle
            mountedRepositoryID = nil
            mountpoint = nil
        case .mounting, .mounted:
            let detail = Self.tail(of: text)
            phase = .idle
            mountedRepositoryID = nil
            mountpoint = nil
            lastError = detail.isEmpty
                ? "The mount ended unexpectedly (restic exited \(status)). Try mounting again."
                : "The mount ended unexpectedly: \(detail)"
        }
    }

    // MARK: - Unmount

    /// SIGINT → 5 s → `diskutil unmount force` → SIGKILL
    /// (`docs/restic-cli.md` §mount).
    func unmount() async {
        guard let process, process.isRunning else {
            phase = .idle
            mountedRepositoryID = nil
            mountpoint = nil
            return
        }
        phase = .unmounting
        let directory = mountpoint

        kill(process.processIdentifier, SIGINT)
        let deadline = Date().addingTimeInterval(Self.sigintGrace)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if process.isRunning, let directory {
            Self.runDiskutilUnmount(directory)
            let forceDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < forceDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        phase = .idle
        mountedRepositoryID = nil
        mountpoint = nil
        Self.removeEmptyMountpoint(directory)
    }

    /// The `applicationWillTerminate` path: the same escalation, blocking,
    /// because there is no runloop left to await on. Bounded by the same
    /// 5 s grace, so a quit can never hang indefinitely.
    private func unmountSynchronously() {
        guard let process, process.isRunning else { return }
        phase = .unmounting
        let directory = mountpoint

        kill(process.processIdentifier, SIGINT)
        let deadline = Date().addingTimeInterval(Self.sigintGrace)
        while process.isRunning, Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning, let directory {
            Self.runDiskutilUnmount(directory)
            let forceDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < forceDeadline {
                usleep(100_000)
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        self.process = nil
        phase = .idle
        Self.removeEmptyMountpoint(directory)
    }

    private static func runDiskutilUnmount(_ directory: URL) {
        let diskutil = Process()
        diskutil.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        diskutil.arguments = ["unmount", "force", directory.path]
        diskutil.standardOutput = FileHandle.nullDevice
        diskutil.standardError = FileHandle.nullDevice
        try? diskutil.run()
        diskutil.waitUntilExit()
    }

    /// Best effort: leaves the directory alone if anything is still there
    /// (a wedged mount), so nothing can be deleted through a live mount.
    private static func removeEmptyMountpoint(_ directory: URL?) {
        guard let directory else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["not-empty"]
        guard entries.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Environment

    private static func environment(for destination: Destination, paths: AppPaths) async throws -> [String: String] {
        var environment: [String: String] = [:]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER", "TMPDIR"] {
            if let value = inherited[key] {
                environment[key] = value
            }
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment.merge(destination.nonSecretEnv) { _, new in new }

        // The embedded helper, never this process: with the file backend the
        // store bakes this executable into `RESTIC_PASSWORD_COMMAND`, and
        // `restic mount` would otherwise be handed the SwiftUI app binary.
        let secrets = try SecretStoreFactory.make(
            paths: paths,
            runner: DefaultProcessRunner(),
            helperExecutablePath: HelperInvoker.helperURL.path
        )
        let secretEnv = try await secrets.secretEnv(destId: destination.id)
        environment.merge(secretEnv) { _, new in new }

        // Written last — not overridable by configured env. Mirrors
        // `ResticRunner.environment(for:)`, including the store's own
        // password-command environment (empty on the keychain backend).
        environment["RESTIC_CACHE_DIR"] = paths.resticCacheDir.path
        environment.merge(secrets.passwordCommandEnvironment) { _, new in new }
        environment["RESTIC_PASSWORD_COMMAND"] = secrets.passwordCommand(destId: destination.id)
        return environment
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        phase = .idle
        mountedRepositoryID = nil
        mountpoint = nil
        lastError = message
    }

    func clearError() {
        lastError = nil
    }

    private static func tail(of text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(3)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - MountOutput

/// restic's `mount` output, accumulated from the pipe's reader queue. Only
/// the tail is ever shown, so the buffer is capped.
private final class MountOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer += chunk
        if buffer.count > 8_000 {
            buffer = String(buffer.suffix(4_000))
        }
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer = ""
    }
}
