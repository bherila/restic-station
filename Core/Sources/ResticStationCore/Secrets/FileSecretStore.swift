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
/// mode, a group/world-writable result is refused while a readable-only result
/// warns about metadata exposure and continues. The secret file is never
/// create-then-`chmod`, which would leave a window in which it is
/// world-readable. Every read re-verifies the file mode and refuses to read
/// a group- or world-accessible file (see ``load()``).
///
/// **Atomicity.** Writes go to a fixed-name temp file in the same directory,
/// created `O_EXCL` at `0600`, `fsync`ed, then `rename(2)`d over the real
/// file — the same pattern as `ConfigStore.save(_:)`. A crash can therefore
/// never truncate `secrets.json`; the worst case is a leftover temp file,
/// which the next write unlinks.
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
    static let lockTimeout: TimeInterval = 10
    private static let lockPollNanoseconds: UInt64 = 25_000_000

    public let backend = SecretBackend.file

    private let paths: AppPaths
    private let helperPath: String
    private let directoryModeSetter: @Sendable (String, mode_t) -> Void
    private let warningHandler: @Sendable (String) -> Void

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
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
        )
    }

    init(
        paths: AppPaths,
        helperPath: String,
        directoryModeSetter: @escaping @Sendable (String, mode_t) -> Void,
        warningHandler: @escaping @Sendable (String) -> Void
    ) {
        self.paths = paths
        self.helperPath = helperPath
        self.directoryModeSetter = directoryModeSetter
        self.warningHandler = warningHandler
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

    /// `locks/secrets.lock`. Composed here rather than in `AppPaths` only
    /// because `AppPaths` is owned elsewhere right now; it belongs there.
    var lockFileURL: URL {
        paths.locksDir.appendingPathComponent("secrets.lock", isDirectory: false)
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

    private func withWriteLock(_ body: () throws -> Void) async throws {
        try prepareDirectories()
        let lock = FileLock(path: lockFileURL)
        let deadline = Date().addingTimeInterval(Self.lockTimeout)
        while !lock.tryAcquire() {
            guard Date() < deadline else {
                throw SecretStoreError.backendFailed(
                    "timed out after \(Int(Self.lockTimeout))s waiting for the secrets lock at "
                        + "\(lockFileURL.path). Another Restic Station process may be stuck; "
                        + "check for running restic-station-helper processes."
                )
            }
            try await Task.sleep(nanoseconds: Self.lockPollNanoseconds)
        }
        defer { lock.release() }
        try body()
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
        _ = tempPath.withCString { unlink($0) }
        let fd = tempPath.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        guard fd >= 0 else {
            throw SecretStoreError.backendFailed(
                "could not create \(tempPath): \(Self.describe(errno: errno))"
            )
        }
        // Not "create-then-chmod": the file was *created* at 0600 and a umask
        // can only clear bits, never set them, so the file has never been
        // wider than 0600 for an instant. This pins the mode to exactly 0600
        // whatever the process umask happened to strip.
        _ = fchmod(fd, 0o600)

        do {
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
    /// it. Group/world-write access is fatal because another user could
    /// unlink or rename the `0600` file and substitute one whose mode still
    /// passes the read-time check. Group/world-read access without write
    /// access exposes only destination IDs and file metadata, so it emits a
    /// warning to stderr but does not prevent storing the protected file.
    func prepareDirectories() throws {
        try createDirectory(at: paths.root, mode: 0o700)
        // Lock files hold nothing; the default mode is fine.
        try FileManager.default.createDirectory(at: paths.locksDir, withIntermediateDirectories: true)
    }

    private func createDirectory(at url: URL, mode: mode_t) throws {
        var info = stat()
        if url.path.withCString({ stat($0, &info) }) == 0 {
            try setMode(mode, on: url)
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
            try setMode(mode, on: url)
            return
        }
        if errno == EEXIST {
            // Another process created it after the stat above. It will hold
            // this process's secrets too, so enforce the same mode.
            try setMode(mode, on: url)
        } else {
            throw SecretStoreError.backendFailed(
                "could not create \(url.path): \(Self.describe(errno: errno))"
            )
        }
    }

    private func setMode(_ mode: mode_t, on url: URL) throws {
        let path = url.path
        directoryModeSetter(path, mode)

        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else {
            throw SecretStoreError.backendFailed(
                "could not inspect permissions on \(path): \(Self.describe(errno: errno))"
            )
        }
        let permissions = UInt32(info.st_mode) & 0o777
        guard permissions & 0o022 == 0 else {
            throw SecretStoreError.backendFailed(
                "refusing to store secrets in \(path): the directory is group- or world-writable "
                    + "(mode \(Self.octal(permissions))). Another user could replace secrets.json "
                    + "even though the file is mode 0600. Fix it with: chmod 700 \(path)"
            )
        }
        if permissions & 0o044 != 0 {
            warningHandler(
                "warning: \(path) remains group- or world-readable "
                    + "(mode \(Self.octal(permissions))) after attempting chmod 700. "
                    + "secrets.json is still created mode 0600, but other users can see which "
                    + "destinations have secrets and the file's size and mtime. "
                    + "Fix the directory with: chmod 700 \(path)"
            )
        }
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
        "0" + String(permissions, radix: 8)
    }
}
