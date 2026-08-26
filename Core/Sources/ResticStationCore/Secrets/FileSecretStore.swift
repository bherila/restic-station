import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The Linux ``SecretStore`` backend (and an opt-in alternative on macOS):
/// a single `0600` JSON file at `<AppPaths.root>/secrets.json`.
///
/// **Why a plain file.** The Linux host this ships to has no desktop
/// session, no keyring daemon, and no GPG agent — a headless machine whose
/// only interactive surface is SSH. Every "real" secret service on Linux
/// (`gnome-keyring`, `kwallet`, `pass`) needs one of those. A file whose
/// mode is enforced is the honest option: its threat model is exactly the
/// Unix file-permission model, with no hidden dependency that fails at 03:00
/// when a scheduled backup fires. See `docs/keychain-and-fda.md` §5 for the
/// full threat model and how it differs from the macOS ACL strategy.
///
/// **Secrets never reach argv.** macOS's accepted `security -w <value>`
/// tradeoff is specific to `security(1)`; nothing here ever passes a secret
/// as a process argument, writes one to a log, or embeds one in an error.
/// The password reaches restic through
/// `RESTIC_PASSWORD_COMMAND=<helper> print-password --dest <uuid>`, i.e. over
/// the child's stdout, never its command line.
///
/// **Permissions.** The file is created `0600`. A fresh containing directory
/// is created `0700` via `mkdir(2)`; an existing one is tightened to `0700`
/// before the secrets file is written. If the filesystem cannot enforce that
/// mode, unprotected group/world write-and-search access is refused, while
/// group/world read or search access warns about metadata exposure and
/// continues. A sticky directory owned by this user (or root) protects its
/// entries from other writers and is therefore not refused. The secret temp
/// file is created no wider than `0600`, then descriptor-`fchmod`ed and
/// re-`fstat`ed to require exact `0600`; there is no wider-permission window.
/// Every read re-verifies the file mode and refuses to read a group- or
/// world-accessible file or one owned outside the helper/root trust boundary
/// (see ``load()``).
///
/// **Atomicity.** Writes go to a fixed-name temp file in the same directory,
/// created `O_EXCL` no wider than `0600`, pinned and verified at exact `0600`,
/// `fsync`ed, then `rename(2)`d over the real file — the same pattern as
/// `ConfigStore.save(_:)`. A crash can therefore
/// never truncate `secrets.json`; the worst case is a leftover temp file,
/// which the next write unlinks or reports with ownership-aware recovery
/// guidance if another user has squatted the fixed path.
///
/// **Concurrency.** The tick helper and an interactive `secret set` can run
/// at the same time, so every read-modify-write happens under the shared
/// `locks/secrets.lock` `flock`. Reads take no lock: `rename(2)` is atomic,
/// so a reader always observes one complete generation of the file.
public struct FileSecretStore: SecretStore {

    /// Bumped only if the on-disk shape changes. A file whose `version` is
    /// newer than this is refused rather than silently misread.
    static let currentVersion = 1

    /// How long a writer waits for `locks/secrets.lock` before giving up.
    /// Generous: the critical section is a small read-modify-write, and the
    /// only realistic contender is another `secret` invocation.
    static let lockTimeout: Duration = .seconds(10)
    private static let lockPollNanoseconds: UInt64 = 25_000_000

    public let backend = SecretBackend.file

    private let paths: AppPaths
    private let helperPath: String
    private let directoryModeSetter: @Sendable (String, mode_t) -> Void
    private let warningHandler: @Sendable (String) -> Void
    private let effectiveUserID: @Sendable () -> uid_t
    private let fileModeSetter: @Sendable (Int32, mode_t) -> Int32

    /// - Parameters:
    ///   - paths: supplies `root` (the secrets file's directory) and
    ///     `locksDir`.
    ///   - helperPath: absolute path of the `restic-station-helper` binary,
    ///     baked into ``passwordCommand(destId:)``.
    ///
    ///     Required, with **no default**. "This executable" is the right
    ///     answer only inside the helper; the app process builds a store too
    ///     (restore browsing, `mount`, primary `init`), and a default there
    ///     would point `RESTIC_PASSWORD_COMMAND` at the SwiftUI app binary.
    ///     See `SecretStoreFactory.make(paths:runner:helperExecutablePath:environment:)`.
    ///     The helper passes ``currentExecutablePath()``, which reads
    ///     `/proc/self/exe` — deliberately **not**
    ///     `CommandLine.arguments[0]`, which is whatever the caller chose to
    ///     put in `argv[0]` and is trivially spoofable.
    public init(paths: AppPaths, helperPath: String) {
        self.init(
            paths: paths,
            helperPath: helperPath,
            directoryModeSetter: { path, mode in
                _ = path.withCString { chmod($0, mode) }
            },
            warningHandler: { message in
                StandardStream.write(Data((message + "\n").utf8), to: .standardError)
            }
        )
    }

    init(
        paths: AppPaths,
        helperPath: String,
        directoryModeSetter: @escaping @Sendable (String, mode_t) -> Void,
        warningHandler: @escaping @Sendable (String) -> Void,
        effectiveUserID: @escaping @Sendable () -> uid_t = { geteuid() },
        fileModeSetter: @escaping @Sendable (Int32, mode_t) -> Int32 = { fd, mode in
            fchmod(fd, mode) == 0 ? 0 : errno
        }
    ) {
        self.paths = paths
        self.helperPath = helperPath
        self.directoryModeSetter = directoryModeSetter
        self.warningHandler = warningHandler
        self.effectiveUserID = effectiveUserID
        self.fileModeSetter = fileModeSetter
    }

    // MARK: - Paths

    /// `<AppPaths.root>/secrets.json`.
    public var fileURL: URL {
        paths.root.appendingPathComponent("secrets.json", isDirectory: false)
    }

    /// The fixed-name temp file ``store(_:)`` renames from. Fixed, not
    /// randomized, so a crash between write and rename leaves a
    /// deterministic, recognizable leftover that the next write removes.
    var tempFileURL: URL {
        paths.root.appendingPathComponent("secrets.json.tmp", isDirectory: false)
    }

    /// `locks/secrets.lock`.
    var lockFileURL: URL {
        paths.secretsLockFile
    }

    // MARK: - Repo password

    public func setPassword(_ password: String, destId: UUID) async throws {
        try await mutate { document in
            document.secrets[SecretAccount.password(destId)] = password
        }
    }

    public func password(destId: UUID) async throws -> String {
        guard let value = try load().secrets[SecretAccount.password(destId)] else {
            throw SecretStoreError.itemNotFound
        }
        return value
    }

    public func deletePassword(destId: UUID) async throws {
        try await mutate { document in
            document.secrets.removeValue(forKey: SecretAccount.password(destId))
        }
    }

    // MARK: - Secret env

    public func setSecretEnv(_ env: [String: String], destId: UUID) async throws {
        let json = try SecretEnvBlob.encode(env)
        try await mutate { document in
            document.secrets[SecretAccount.secretEnv(destId)] = json
        }
    }

    /// `[:]` when absent, matching ``KeychainSecretStore`` — no secret env
    /// was ever configured for this destination.
    public func secretEnv(destId: UUID) async throws -> [String: String] {
        guard let json = try load().secrets[SecretAccount.secretEnv(destId)] else {
            return [:]
        }
        return try SecretEnvBlob.decode(json)
    }

    public func deleteSecretEnv(destId: UUID) async throws {
        try await mutate { document in
            document.secrets.removeValue(forKey: SecretAccount.secretEnv(destId))
        }
    }

    public func updateDestinationSecrets(
        _ update: DestinationSecretUpdate
    ) async throws -> DestinationSecretRollback {
        try await withWriteLock {
            var document = try load()
            let passwordAccount = SecretAccount.password(update.destId)
            let envAccount = SecretAccount.secretEnv(update.destId)
            let previousPassword = update.password == nil ? nil : document.secrets[passwordAccount]
            let previousEnv = try update.secretEnv == nil
                ? nil
                : document.secrets[envAccount].map(SecretEnvBlob.decode) ?? [:]
            let rollback = DestinationSecretRollback(
                destId: update.destId,
                password: update.password.map {
                    SecretRollbackChange(installed: Optional($0), previous: previousPassword)
                },
                secretEnv: update.secretEnv.map {
                    SecretRollbackChange(installed: $0, previous: previousEnv ?? [:])
                }
            )
            guard update.password != nil || update.secretEnv != nil else { return rollback }
            if let password = update.password {
                document.secrets[passwordAccount] = password
            }
            if let env = update.secretEnv {
                document.secrets[envAccount] = env.isEmpty ? nil : try SecretEnvBlob.encode(env)
            }
            document.version = Self.currentVersion
            try store(document)
            return rollback
        }
    }

    public func restoreDestinationSecretsIfCurrent(
        _ rollback: DestinationSecretRollback
    ) async throws -> Bool {
        try await withWriteLock {
            guard rollback.password != nil || rollback.secretEnv != nil else { return true }
            var document = try load()
            let passwordAccount = SecretAccount.password(rollback.destId)
            let envAccount = SecretAccount.secretEnv(rollback.destId)
            if let change = rollback.password,
               document.secrets[passwordAccount] != change.installed {
                return false
            }
            if let change = rollback.secretEnv {
                let current = try document.secrets[envAccount].map(SecretEnvBlob.decode) ?? [:]
                guard current == change.installed else { return false }
            }
            if let change = rollback.password {
                document.secrets[passwordAccount] = change.previous
            }
            if let change = rollback.secretEnv {
                document.secrets[envAccount] = change.previous.isEmpty
                    ? nil
                    : try SecretEnvBlob.encode(change.previous)
            }
            document.version = Self.currentVersion
            try store(document)
            return true
        }
    }

    // MARK: - Password command

    /// `<absolute-helper-path> print-password --dest <uuid>`.
    ///
    /// restic word-splits `RESTIC_PASSWORD_COMMAND` with its own splitter
    /// (not `sh -c`), which understands single- and double-quoted arguments
    /// but **not** backslash escapes — verified against restic 0.18.1, see
    /// `docs/restic-cli.md` §General. So the path is double-quoted only when
    /// it contains a character that needs it (the overwhelmingly common case
    /// produces an unquoted string, the same shape the keychain backend
    /// emits).
    public func passwordCommand(destId: UUID) -> String {
        "\(Self.quoteForRestic(helperPath)) print-password --dest \(SecretAccount.password(destId))"
    }

    /// The child that ``passwordCommand(destId:)`` names is another copy of
    /// *this* helper, and it re-resolves the store from its own environment.
    /// Without these two variables it would read the default data directory
    /// with the platform-default backend — which on macOS-with-`file` is the
    /// keychain, and under a `RESTIC_STATION_DATA_DIR` override (tests,
    /// `scripts/integration-test.sh`, a non-standard install) is the wrong
    /// directory. Both are non-secret by construction: a path and the word
    /// "file".
    public var passwordCommandEnvironment: [String: String] {
        [
            "RESTIC_STATION_DATA_DIR": paths.root.path,
            SecretBackend.environmentKey: SecretBackend.file.rawValue,
        ]
    }

    /// Characters restic's splitter passes through unquoted. Anything else
    /// (space, quote, `$`, backslash, …) forces double quotes.
    private static let unquotedSafe = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+=:,@"
    )

    /// - Note: a path containing a literal `"` cannot be expressed at all —
    ///   restic's splitter has no escape mechanism and reports
    ///   `double-quoted string not terminated`. Such a path is refused at
    ///   ``init(paths:helperPath:)`` time by nobody, because it is not
    ///   reachable in practice (the helper is installed by us); it is called
    ///   out here so a future reader does not have to rediscover it.
    static func quoteForRestic(_ path: String) -> String {
        if !path.isEmpty, path.allSatisfy({ unquotedSafe.contains($0) }) {
            return path
        }
        return "\"\(path)\""
    }

    // MARK: - Executable path

    /// This executable's absolute path, as the kernel/dyld reports it.
    ///
    /// - Linux: `/proc/self/exe` — unforgeable, and correct even when the
    ///   binary was invoked through a symlink or a `PATH` lookup.
    /// - Darwin: `_NSGetExecutablePath`, then `realpath` to resolve `..`,
    ///   symlinks and a relative launch path.
    ///
    /// Deliberately **not** `CommandLine.arguments[0]`: `argv[0]` is whatever
    /// the caller chose to put there, and baking it into a command string
    /// restic will execute would be a straightforward code-execution hole.
    ///
    /// Deliberately **not** `Bundle.main.executablePath` either: for a
    /// command-line tool living inside an `.app` bundle's `Contents/MacOS/`
    /// — which is exactly where `restic-station-helper` ships — the main
    /// bundle is the *app*, so that property returns the app's executable
    /// rather than this one. It is kept only as a last-resort fallback.
    public static func currentExecutablePath() -> String {
        #if os(Linux)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink("/proc/self/exe", &buffer, buffer.count - 1)
        if length > 0 {
            buffer[length] = 0
            if let resolved = Self.string(fromNulTerminated: buffer) {
                return resolved
            }
        }
        #elseif canImport(Darwin)
        var size = UInt32(PATH_MAX) * 2
        var raw = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&raw, &size) == 0 {
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            if realpath(raw, &resolved) != nil, let path = Self.string(fromNulTerminated: resolved) {
                return path
            }
            if let path = Self.string(fromNulTerminated: raw) {
                return path
            }
        }
        #endif
        if let executable = Bundle.main.executablePath, !executable.isEmpty {
            return executable
        }
        // Reached only if the process cannot introspect itself at all.
        return "restic-station-helper"
    }

    // MARK: - Document

    /// The on-disk shape:
    /// `{"version":1,"secrets":{"<uuid>":"…","<uuid>-env":"{…}"}}` —
    /// deliberately mirroring the keychain account naming so the two
    /// backends stay structurally comparable.
    struct Document: Codable, Equatable {
        var version: Int
        var secrets: [String: String]

        init(version: Int = FileSecretStore.currentVersion, secrets: [String: String] = [:]) {
            self.version = version
            self.secrets = secrets
        }
    }

    // MARK: - Reading

    /// Reads and validates the file. A missing file is an empty document
    /// (nothing stored yet), not an error.
    ///
    /// Refuses, with an actionable message, any file that is not a regular
    /// file, is a symlink, or has any group/other permission bit set.
    /// Silently reading a leaked secret file is worse than failing.
    func load() throws -> Document {
        guard let data = try readEnforcingMode() else {
            return Document()
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            // `error` describes JSON structure, never a value: `DecodingError`
            // reports key paths and expected types only.
            throw SecretStoreError.backendFailed(
                "\(fileURL.path) is not readable as a secrets file: \(error)"
            )
        }
        guard document.version <= Self.currentVersion else {
            throw SecretStoreError.backendFailed(
                "\(fileURL.path) was written by a newer version of Restic Station "
                    + "(format \(document.version), this build understands \(Self.currentVersion)). "
                    + "Upgrade Restic Station rather than letting it overwrite the file."
            )
        }
        return document
    }

    /// `nil` when the file does not exist.
    private func readEnforcingMode() throws -> Data? {
        let path = fileURL.path
        // O_NOFOLLOW closes the symlink-swap hole, and fstat-on-the-open-fd
        // closes the TOCTOU hole a path-based stat would leave: the mode we
        // check is the mode of the exact file we are about to read.
        let fd = path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT {
                return nil
            }
            if code == ELOOP {
                throw SecretStoreError.backendFailed(
                    "refusing to read \(path): it is a symbolic link. "
                        + "Replace it with a regular file owned by you (mode 0600)."
                )
            }
            throw SecretStoreError.backendFailed("could not open \(path): \(Self.describe(errno: code))")
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw SecretStoreError.backendFailed("could not stat \(path): \(Self.describe(errno: errno))")
        }
        let mode = UInt32(info.st_mode)
        guard mode & UInt32(S_IFMT) == UInt32(S_IFREG) else {
            throw SecretStoreError.backendFailed(
                "refusing to read \(path): it is not a regular file."
            )
        }
        let euid = effectiveUserID()
        guard Self.isTrustedOwner(info.st_uid, effectiveUID: euid) else {
            throw SecretStoreError.backendFailed(
                "refusing to read \(path): it is owned by uid \(info.st_uid), outside this "
                    + "helper's trusted ownership boundary (\(Self.trustedOwnerDescription(effectiveUID: euid))). "
                    + "Fix the ownership with: chown \(euid) \(ShellQuoting.quoteIfNeeded(path))"
            )
        }
        let permissions = mode & 0o777
        guard permissions & 0o077 == 0 else {
            throw SecretStoreError.backendFailed(
                "refusing to read \(path): it is group- or world-accessible "
                    + "(mode \(Self.octal(permissions))). Fix it with: chmod 600 \(path)"
            )
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return handle.readDataToEndOfFile()
    }

    // MARK: - Writing

    /// Read-modify-write under `locks/secrets.lock`, so a concurrent
    /// `secret set` can never lose the other writer's entry.
    private func mutate(_ change: @Sendable (inout Document) -> Void) async throws {
        try await withWriteLock {
            var document = try load()
            document.version = Self.currentVersion
            change(&document)
            try store(document)
        }
    }

    private func withWriteLock<T>(_ body: () throws -> T) async throws -> T {
        // `store` repeats the check inside the lock so it remains safe if it
        // is ever called from another write path. Keep this pre-lock check to
        // create the lock directory, but report a degraded mode only once.
        try prepareDirectories(reportWarnings: false)
        let lock = FileLock(path: lockFileURL, trustedRoot: paths.root)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.lockTimeout)
        while true {
            switch lock.acquire() {
            case .acquired:
                break
            case .busy:
                guard clock.now < deadline else {
                    throw SecretStoreError.backendFailed(
                        "timed out after 10s waiting for the secrets lock at "
                            + "\(lockFileURL.path). Another Restic Station process may be stuck; "
                            + "check for running restic-station-helper processes."
                    )
                }
                try await Task.sleep(nanoseconds: Self.lockPollNanoseconds)
                continue
            case .failed(let failure):
                // Reported as itself rather than waited out and then blamed
                // on a stuck peer: the advice above ("check for running
                // helper processes") is actively misleading when the lock
                // file is simply unopenable or owned by another user (#110).
                throw SecretStoreError.lockUnusable(failure)
            }
            break
        }
        defer { lock.release() }
        return try body()
    }

    /// temp file (`O_EXCL`, `0600`) → `fsync` → `rename(2)`.
    private func store(_ document: Document) throws {
        try prepareDirectories()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw SecretStoreError.backendFailed("could not encode the secrets file: \(error)")
        }

        let tempPath = tempFileURL.path
        // Clear any leftover from a crashed write so O_EXCL always creates a
        // brand-new file — which is what guarantees the 0600 creation mode
        // actually applies (open(2) ignores `mode` for an existing file).
        // A sticky shared directory can make another user's squatted entry
        // impossible for us to unlink, so never discard that failure.
        let removed = tempPath.withCString { unlink($0) }
        if removed != 0 {
            let code = errno
            if code != ENOENT {
                throw SecretStoreError.backendFailed(
                    Self.tempFileConflictMessage(
                        path: tempPath,
                        reason: "could not remove the existing temporary entry: \(Self.describe(errno: code))"
                    )
                )
            }
        }
        let fd = tempPath.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        guard fd >= 0 else {
            let code = errno
            if code == EEXIST {
                throw SecretStoreError.backendFailed(
                    Self.tempFileConflictMessage(
                        path: tempPath,
                        reason: "another entry appeared before the secure temporary file could be created"
                    )
                )
            }
            throw SecretStoreError.backendFailed(
                "could not create \(tempPath): \(Self.describe(errno: code))"
            )
        }
        do {
            // Not "create-then-chmod": the file was *created* no wider than
            // 0600 because umask can only clear bits. Pin and verify the exact
            // reusable mode on this descriptor before any secret bytes are
            // written or the entry can be renamed into place.
            let chmodError = fileModeSetter(fd, 0o600)
            guard chmodError == 0 else {
                throw SecretStoreError.backendFailed(
                    "could not set mode 0600 on \(tempPath): \(Self.describe(errno: chmodError))"
                )
            }
            var tightened = stat()
            guard fstat(fd, &tightened) == 0 else {
                throw SecretStoreError.backendFailed(
                    "could not verify mode 0600 on \(tempPath): \(Self.describe(errno: errno))"
                )
            }
            guard tightened.st_mode & 0o777 == 0o600 else {
                throw SecretStoreError.backendFailed(
                    "could not enforce mode 0600 on \(tempPath): filesystem reported mode "
                        + "\(Self.octal(UInt32(tightened.st_mode) & 0o777))"
                )
            }
            try Self.writeAll(fd: fd, data: data)
            guard fsync(fd) == 0 else {
                throw SecretStoreError.backendFailed(
                    "could not flush \(tempPath): \(Self.describe(errno: errno))"
                )
            }
        } catch {
            close(fd)
            _ = tempPath.withCString { unlink($0) }
            throw error
        }
        close(fd)

        let destinationPath = fileURL.path
        let renamed = tempPath.withCString { from in
            destinationPath.withCString { to in
                rename(from, to)
            }
        }
        guard renamed == 0 else {
            let code = errno
            _ = tempPath.withCString { unlink($0) }
            throw SecretStoreError.backendFailed(
                "could not replace \(destinationPath): \(Self.describe(errno: code))"
            )
        }
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SecretStoreError.backendFailed("write failed: \(describe(errno: errno))")
                }
                if written == 0 { break }
                offset += written
            }
        }
        guard offset == data.count else {
            throw SecretStoreError.backendFailed("short write to the secrets file")
        }
    }

    // MARK: - Directories

    /// Creates or attempts to tighten `root` to `0700`, then creates `locks/`.
    ///
    /// A fresh `root` is created with `mkdir(2)`'s mode argument, so there is
    /// no interval where a newly created secrets directory has a looser mode.
    /// An existing `root` is tightened before any secret is written. The
    /// resulting mode, not `chmod(2)`'s return value, decides what happens —
    /// some network and non-POSIX filesystems report success without changing
    /// it. Group/world write *and search* access is fatal when it is not
    /// protected by sticky-directory ownership: another user could unlink or
    /// rename the `0600` file and substitute one whose mode still passes the
    /// read-time check. A sticky directory is accepted only when its owner and
    /// the protected entry's owner are this process's user (or root, which is
    /// outside the threat model). Group/world read or search access exposes
    /// directory entries and/or file metadata, so it emits a warning to stderr
    /// but does not prevent storing the protected file.
    ///
    /// The immediate parent receives the same replacement-risk check because
    /// otherwise another writer could rename `root` itself. This deliberately
    /// stops at one parent rather than claiming to audit the full ancestor
    /// chain or filesystem ACLs; those remain deployment boundaries.
    func prepareDirectories(reportWarnings: Bool = true) throws {
        try createDirectory(at: paths.root, mode: 0o700, reportWarnings: reportWarnings)
        try validateImmediateParent()
        // A permissive umask must not create a mutation-lock parent that the
        // lock verifier immediately refuses. Use the same descriptor-relative
        // creation and tightening path as AppPaths setup.
        if let failure = FileLock.ensureDirectory(
            paths.locksDir,
            parent: paths.root,
            trustedRoot: paths.root,
            mode: 0o700,
            tightenExisting: false
        ) {
            throw SecretStoreError.lockUnusable(failure)
        }
    }

    private func createDirectory(at url: URL, mode: mode_t, reportWarnings: Bool) throws {
        var info = stat()
        if url.path.withCString({ stat($0, &info) }) == 0 {
            try setMode(mode, on: url, reportWarnings: reportWarnings)
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let created = url.path.withCString { mkdir($0, mode) }
        if created == 0 {
            // Same reasoning as the file's fchmod: the directory was created
            // at `mode`, so this only pins it there against the umask.
            try setMode(mode, on: url, reportWarnings: reportWarnings)
            return
        }
        if errno == EEXIST {
            // Another process created it after the stat above. It will hold
            // this process's secrets too, so enforce the same mode.
            try setMode(mode, on: url, reportWarnings: reportWarnings)
        } else {
            throw SecretStoreError.backendFailed(
                "could not create \(url.path): \(Self.describe(errno: errno))"
            )
        }
    }

    private func setMode(_ mode: mode_t, on url: URL, reportWarnings: Bool) throws {
        let path = url.path
        directoryModeSetter(path, mode)

        let info = try directoryInfo(at: url)
        let euid = effectiveUserID()
        try requireTrustedOwner(
            info.st_uid,
            at: path,
            role: "secrets directory",
            effectiveUID: euid
        )
        let modeBits = UInt32(info.st_mode)
        let displayedMode = modeBits & 0o7777
        guard !Self.hasUnprotectedReplacementAccess(
            info,
            entryOwner: euid,
            effectiveUID: euid
        ) else {
            throw SecretStoreError.backendFailed(
                "refusing to store secrets in \(path): the directory has unprotected group/world "
                    + "write-and-search access (mode \(Self.octal(displayedMode))). Another user "
                    + "could replace secrets.json "
                    + "even though the file is mode 0600. " + Self.tightenRemedy(for: path)
            )
        }
        if reportWarnings && modeBits & 0o055 != 0 {
            warningHandler(
                "warning: \(path) remains accessible to group or other users "
                    + "(mode \(Self.octal(displayedMode))). "
                    + "secrets.json is still created mode 0600, but directory entries and/or "
                    + "file metadata may be visible. " + Self.tightenRemedy(for: path)
            )
        }
    }

    /// The remedy sentence for both messages in `setMode`.
    ///
    /// Neither message is reachable unless this process's *own*
    /// `chmod(path, 0700)` has just run and the following `stat` showed the
    /// bits still set — so "fix it with: chmod 700" on its own prescribes the
    /// exact command the code has already tried and watched fail. A headless
    /// operator runs it, nothing changes, and the next `secret set` prints the
    /// identical message; advice that cannot work is how a correct refusal
    /// teaches people to distrust this tool's output. Name the two reachable
    /// causes instead. Found by review on #60.
    private static func tightenRemedy(for path: String) -> String {
        "chmod 700 \(path) did not take effect. Either the directory belongs to another user, "
            + "in which case run that chmod as its owner or as root; or the filesystem does not "
            + "honour permissions at all (a CIFS/FAT mount with dir_mode/dmask, vboxsf, WSL "
            + "drvfs without metadata), in which case no chmod by anyone will ever change it and "
            + "the data directory has to move — point RESTIC_STATION_DATA_DIR at a filesystem "
            + "that does."
    }

    private func validateImmediateParent() throws {
        let parent = paths.root.deletingLastPathComponent()
        guard parent.path != paths.root.path else { return }

        var rootEntryInfo = stat()
        guard paths.root.path.withCString({ lstat($0, &rootEntryInfo) }) == 0 else {
            throw SecretStoreError.backendFailed(
                "could not inspect \(paths.root.path): \(Self.describe(errno: errno))"
            )
        }
        let parentInfo = try directoryInfo(at: parent)
        let euid = effectiveUserID()
        try requireTrustedOwner(
            rootEntryInfo.st_uid,
            at: paths.root.path,
            role: "secrets directory entry",
            effectiveUID: euid
        )
        try requireTrustedOwner(
            parentInfo.st_uid,
            at: parent.path,
            role: "immediate parent directory",
            effectiveUID: euid
        )
        guard !Self.hasUnprotectedReplacementAccess(
            parentInfo,
            entryOwner: rootEntryInfo.st_uid,
            effectiveUID: euid
        ) else {
            let displayedMode = UInt32(parentInfo.st_mode) & 0o7777
            throw SecretStoreError.backendFailed(
                "refusing to store secrets under \(parent.path): the immediate parent directory "
                    + "has unprotected group/world write-and-search access "
                    + "(mode \(Self.octal(displayedMode))), allowing another user to rename or "
                    + "replace \(paths.root.lastPathComponent). Fix the parent permissions or "
                    + "use a sticky directory whose entries are owner-protected."
            )
        }
    }

    private func directoryInfo(at url: URL) throws -> stat {
        var info = stat()
        guard url.path.withCString({ stat($0, &info) }) == 0 else {
            throw SecretStoreError.backendFailed(
                "could not inspect permissions on \(url.path): \(Self.describe(errno: errno))"
            )
        }
        guard UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR) else {
            throw SecretStoreError.backendFailed("expected a directory at \(url.path)")
        }
        return info
    }

    /// Whether mode bits let another user replace an entry in `directory`.
    /// Directory mutation requires write and search for the same permission
    /// class. Sticky mode then limits it to the entry owner, directory owner,
    /// or root, so both relevant owners must belong to the trusted boundary.
    private static func hasUnprotectedReplacementAccess(
        _ directory: stat,
        entryOwner: uid_t,
        effectiveUID: uid_t
    ) -> Bool {
        let mode = UInt32(directory.st_mode)
        let groupCanReplace = mode & 0o030 == 0o030
        let otherCanReplace = mode & 0o003 == 0o003
        guard groupCanReplace || otherCanReplace else { return false }
        guard mode & UInt32(S_ISVTX) != 0 else { return true }

        return !isTrustedOwner(directory.st_uid, effectiveUID: effectiveUID)
            || !isTrustedOwner(entryOwner, effectiveUID: effectiveUID)
    }

    /// A non-root helper accepts its own entries and root-managed entries. A
    /// root helper accepts only root: otherwise root's ability to read/chmod
    /// everything would turn an attacker-owned 0600 file or 0700 directory
    /// into a trusted secrets source.
    static func isTrustedOwner(_ owner: uid_t, effectiveUID: uid_t) -> Bool {
        owner == effectiveUID || owner == 0
    }

    private func requireTrustedOwner(
        _ owner: uid_t,
        at path: String,
        role: String,
        effectiveUID: uid_t
    ) throws {
        guard Self.isTrustedOwner(owner, effectiveUID: effectiveUID) else {
            throw SecretStoreError.backendFailed(
                "refusing to store secrets at \(path): the \(role) is owned by uid \(owner), "
                    + "outside this helper's trusted ownership boundary "
                    + "(\(Self.trustedOwnerDescription(effectiveUID: effectiveUID))). "
                    + "Move RESTIC_STATION_DATA_DIR to trusted storage or deliberately change "
                    + "ownership with: "
                    + "chown \(effectiveUID) \(ShellQuoting.quoteIfNeeded(path))"
            )
        }
    }

    private static func trustedOwnerDescription(effectiveUID: uid_t) -> String {
        effectiveUID == 0 ? "root (uid 0)" : "uid \(effectiveUID) or root (uid 0)"
    }

    private static func tempFileConflictMessage(path: String, reason: String) -> String {
        var info = stat()
        let owner: String
        if path.withCString({ lstat($0, &info) }) == 0 {
            owner = " The existing entry is owned by uid \(info.st_uid)."
        } else {
            owner = " Its owner could not be inspected because the entry changed concurrently."
        }
        return "could not safely create \(path): \(reason)." + owner
            + " Remove that entry as its owner or as root, then retry. If the data directory is itself "
            + "shared and sticky (for example /tmp), move it to private storage and point "
            + "RESTIC_STATION_DATA_DIR there."
    }

    // MARK: - Small helpers

    private static func describe(errno code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// Decodes a NUL-terminated `CChar` buffer. Spelled by hand rather than
    /// with `String(validatingCString:)` (deprecated in newer toolchains) or
    /// its replacement (absent from older ones), so the same source compiles
    /// warning-free on both the Linux CI toolchain and current macOS ones.
    private static func string(fromNulTerminated buffer: [CChar]) -> String? {
        guard let end = buffer.firstIndex(of: 0), end > 0 else { return nil }
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func octal(_ permissions: UInt32) -> String {
        let digits = String(permissions, radix: 8)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}
