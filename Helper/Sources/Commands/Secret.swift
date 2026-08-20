import ArgumentParser
import Foundation
import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - secret

/// `secret …` — enter and manage repository passwords and secret environment
/// variables from a terminal.
///
/// The Linux host has no GUI, so there is nowhere to type a password except
/// here. On macOS these commands work too (against the login keychain), which
/// makes them the scriptable equivalent of the destination editor's password
/// field.
///
/// **No secret is ever an argument.** `secret set` and `secret set-env` read
/// from stdin; nothing in this file puts a secret in argv, in a log line, in
/// a run record, or in an error message. `secret list` prints which
/// destinations have secrets, never what they are.
struct Secret: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Store, inspect and remove destination passwords and secret environment variables. "
            + "Values are read from stdin, never from the command line. Exit 0 ok, 1 error.",
        subcommands: [
            SecretSet.self,
            SecretSetEnv.self,
            SecretRemove.self,
            SecretList.self,
        ]
    )
}

// MARK: - secret set

struct SecretSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Read a repository password from stdin and store it for one destination. "
            + "On a terminal you are prompted with echo disabled; from a pipe the input is "
            + "taken raw (one trailing newline is stripped), so "
            + "`pass show repo | … secret set --dest <uuid>` works. Exit 0 ok, 1 error."
    )

    @Option(name: .long, help: "The destination UUID whose password is being set.")
    var dest: UUID

    func run() async throws {
        let context = try SecretContext.make()
        let destination = context.destination(dest)

        let password = SecretInput.read(prompt: "Password for \"\(destination.label)\": ")
        guard !password.isEmpty else {
            HelperExit.fail("refusing to store an empty password for \"\(destination.label)\"")
        }

        do {
            try await context.store.setPassword(password, destId: dest)
        } catch {
            HelperExit.fail("could not store the password for \"\(destination.label)\": \(error)")
        }
        print("stored a password for \"\(destination.label)\"")
        HelperExit.code(0)
    }
}

// MARK: - secret set-env

struct SecretSetEnv: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-env",
        abstract: "Read a JSON object of secret environment variables "
            + "(e.g. {\"AWS_ACCESS_KEY_ID\":\"…\"}) from stdin and store it for one destination. "
            + "Replaces any previously stored set. Exit 0 ok, 1 error."
    )

    @Option(name: .long, help: "The destination UUID whose secret environment is being set.")
    var dest: UUID

    func run() async throws {
        let context = try SecretContext.make()
        let destination = context.destination(dest)

        let raw = SecretInput.readAllStdin()
        let env: [String: String]
        do {
            env = try SecretEnvInput.parse(raw)
        } catch let error as SecretEnvInput.ParseError {
            // `error` describes the *shape* of the input, never a value.
            HelperExit.fail("could not read the secret environment: \(error.message)")
        }

        do {
            try await context.store.setSecretEnv(env, destId: dest)
        } catch {
            HelperExit.fail("could not store the secret environment for \"\(destination.label)\": \(error)")
        }
        let names = env.keys.sorted().joined(separator: ", ")
        print("stored \(env.count) secret environment variable(s) for \"\(destination.label)\": \(names)")
        HelperExit.code(0)
    }
}

// MARK: - secret rm

struct SecretRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove a destination's stored password, or (with --env) its stored secret "
            + "environment. Idempotent: removing something that is not there succeeds. "
            + "Exit 0 ok, 1 error."
    )

    @Option(name: .long, help: "The destination UUID to remove a secret from.")
    var dest: UUID

    @Flag(
        name: .long,
        help: "Remove the secret environment variables instead of the repository password."
    )
    var env = false

    func run() async throws {
        let context = try SecretContext.make()
        let destination = context.destination(dest)

        do {
            if env {
                try await context.store.deleteSecretEnv(destId: dest)
            } else {
                try await context.store.deletePassword(destId: dest)
            }
        } catch {
            HelperExit.fail("could not remove the secret for \"\(destination.label)\": \(error)")
        }
        // Deliberately does not claim something was removed: the delete is
        // idempotent, so the honest report is the resulting state.
        let what = env ? "secret environment" : "password"
        print("\"\(destination.label)\": no \(what) is stored any more")
        HelperExit.code(0)
    }
}

// MARK: - secret list

struct SecretList: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the configured destinations that have a stored password and/or secret "
            + "environment. Never prints a secret value. --json for scripting. "
            + "Exit 0 ok, 1 error."
    )

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    func run() async throws {
        let context = try SecretContext.make()

        var rows: [SecretListing.Row] = []
        for entry in context.destinations {
            let destId = entry.destination.id
            var hasPassword = false
            do {
                // The value is read and immediately discarded — presence is
                // the only thing this command reports.
                _ = try await context.store.password(destId: destId)
                hasPassword = true
            } catch SecretStoreError.itemNotFound {
                hasPassword = false
            } catch {
                throw CLIFailure.classify(error)
            }

            let secretEnvCount: Int
            do {
                secretEnvCount = try await context.store.secretEnv(destId: destId).count
            } catch {
                throw CLIFailure.classify(error)
            }

            rows.append(
                SecretListing.Row(
                    destId: destId,
                    label: entry.destination.label,
                    setName: entry.setName,
                    hasPassword: hasPassword,
                    secretEnvCount: secretEnvCount
                )
            )
        }

        if json {
            // Presence metadata only. `Row` has no field that can hold a
            // password or an env *value* — it counts them. That is the same
            // redaction-by-shape rule `CLIErrorDetails` follows, and it is
            // why this command can have a JSON mode at all.
            //
            // Filtered by `hasAnything`, exactly as `SecretListing.format`
            // filters for human mode: this command lists "destinations that
            // have a stored password and/or secret environment", so an empty
            // store must answer `[]` rather than one row per configured
            // destination saying it has nothing. The two modes disagreeing
            // about the result set is the trap a shared payload exists to
            // remove.
            CLIJSON.print(rows.filter(\.hasAnything))
        } else {
            for line in SecretListing.format(rows) {
                print(line)
            }
        }
        HelperExit.code(0)
    }
}

// MARK: - print-password

/// `print-password --dest <uuid>` — writes the raw password to stdout with
/// **no trailing newline**.
///
/// This exists solely so `FileSecretStore.passwordCommand(destId:)` has
/// something to name in `RESTIC_PASSWORD_COMMAND`; restic runs it as a child
/// and reads the password off its stdout. It is hidden from `--help`
/// (`shouldDisplay: false`) because it is machinery, not a user-facing
/// action — a `secret` subcommand that prints a password would invite
/// exactly the copy-paste-into-a-log habit this whole design avoids.
///
/// Unlike the `secret` subcommands this does **not** load `config.json`: the
/// password path must have as few moving parts as possible, and a
/// destination's presence in the config is irrelevant to whether its
/// password can be read.
struct PrintPassword: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "print-password",
        abstract: "Write one destination's repository password to stdout, with no trailing newline. "
            + "Used by RESTIC_PASSWORD_COMMAND. Exit 0 ok, 1 error.",
        shouldDisplay: false
    )

    @Option(name: .long, help: "The destination UUID whose password should be printed.")
    var dest: UUID

    func run() async throws {
        let paths = AppPaths.default()
        let store = try HelperContext.makeSecretStore(paths: paths, runner: DefaultProcessRunner())

        let password: String
        do {
            password = try await store.password(destId: dest)
        } catch SecretStoreError.itemNotFound {
            HelperExit.fail("no stored password for destination \(dest)")
        } catch {
            HelperExit.fail("could not read the password for destination \(dest): \(error)")
        }

        // Raw bytes, no newline: restic trims a trailing newline itself, but
        // emitting one would make `secret set` / `print-password` a lossy
        // round trip for a password that legitimately ends in one.
        FileHandle.standardOutput.write(Data(password.utf8))
        HelperExit.code(0)
    }
}

// MARK: - stdin

/// Reads secrets from stdin. Never from argv — a command line is visible to
/// every process on the machine and lands in shell history.
enum SecretInput {

    /// One secret, as text.
    ///
    /// - On a TTY: writes `prompt` to **stderr** (stdout may be redirected),
    ///   disables terminal echo, and reads one line.
    /// - On a pipe or file: reads stdin to EOF and strips exactly one
    ///   trailing newline, so `printf '%s' pw |` and `echo pw |` both give
    ///   the same result and a password containing newlines survives.
    static func read(prompt: String) -> String {
        guard isatty(STDIN_FILENO) == 1 else {
            return stripOneTrailingNewline(readAllStdin())
        }
        FileHandle.standardError.write(Data(prompt.utf8))
        let line = withEchoDisabled { readLine(strippingNewline: true) ?? "" }
        // The user's Return was swallowed by the disabled echo; put the
        // cursor back on its own line.
        FileHandle.standardError.write(Data("\n".utf8))
        return line
    }

    static func readAllStdin() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    /// Exactly one — not "all trailing whitespace". A password may end in a
    /// newline, and trimming greedily would silently change it.
    static func stripOneTrailingNewline(_ text: String) -> String {
        var value = text
        if value.hasSuffix("\n") {
            value.removeLast()
        }
        return value
    }

    private static func withEchoDisabled<T>(_ body: () -> T) -> T {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            // Not a real terminal after all — better to echo than to refuse.
            return body()
        }
        var modified = original
        modified.c_lflag &= ~tcflag_t(ECHO)
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &modified)
        defer { _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        return body()
    }
}

// MARK: - secret set-env parsing

/// Parses the `{"VAR":"value"}` object `secret set-env` reads from stdin.
///
/// Split out from the command so it can be unit-tested without a process:
/// the failure messages are the whole point here, and they must describe the
/// *shape* of the input without ever quoting a value.
enum SecretEnvInput {
    struct ParseError: Error {
        let message: String
    }

    static func parse(_ text: String) throws -> [String: String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError(message: "stdin was empty; expected a JSON object like {\"AWS_ACCESS_KEY_ID\":\"…\"}")
        }

        let any: Any
        do {
            // `.fragmentsAllowed` so a top-level string or number parses and
            // can be reported as "you gave me a string", rather than being
            // lumped in with genuinely malformed JSON.
            any = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            throw ParseError(message: "stdin is not valid JSON")
        }
        guard let object = any as? [String: Any] else {
            throw ParseError(
                message: "expected a JSON object of environment variables like "
                    + "{\"AWS_ACCESS_KEY_ID\":\"…\"}, got a \(describe(any))"
            )
        }

        var env: [String: String] = [:]
        for key in object.keys.sorted() {
            guard let value = object[key] as? String else {
                throw ParseError(
                    message: "the value of \"\(key)\" is a \(describe(object[key] as Any)); "
                        + "environment variables must be JSON strings"
                )
            }
            guard !key.isEmpty else {
                throw ParseError(message: "an environment variable name cannot be empty")
            }
            env[key] = value
        }
        return env
    }

    /// Names a JSON value's *kind* — never its contents.
    private static func describe(_ value: Any) -> String {
        switch value {
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        case is String: return "string"
        case is NSNull: return "null"
        case is NSNumber: return "number or boolean"
        default: return "value of an unsupported type"
        }
    }
}

// MARK: - secret list formatting

/// Renders `secret list`. Pure, so a test can assert on the exact lines and
/// prove no secret value can reach stdout.
enum SecretListing {
    /// Also `secret list --json`'s element shape (`docs/cli-json.md`).
    /// Encodable deliberately carries *counts*, never values.
    struct Row: Encodable {
        let destId: UUID
        let label: String
        let setName: String
        let hasPassword: Bool
        let secretEnvCount: Int

        var hasAnything: Bool { hasPassword || secretEnvCount > 0 }
    }

    static func format(_ rows: [Row]) -> [String] {
        let stored = rows.filter(\.hasAnything)
        guard !stored.isEmpty else {
            return ["no destination has a stored password or secret environment"]
        }
        return stored.map { row in
            var kinds: [String] = []
            if row.hasPassword {
                kinds.append("password")
            }
            if row.secretEnvCount > 0 {
                kinds.append("secret-env (\(row.secretEnvCount) variable(s))")
            }
            return "\(row.destId.uuidString.lowercased())  \"\(row.label)\" "
                + "(set \"\(row.setName)\")  \(kinds.joined(separator: ", "))"
        }
    }
}
