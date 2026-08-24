import Foundation
import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Reads one destructive-preview capability without ever admitting it to
/// argv, an environment variable, or an error message.
///
/// PreviewTokenStore creates 32 random bytes and uses unpadded base64url, so
/// the one canonical wire form is 43 ASCII characters. The bounded reader is
/// deliberately separate from SecretInput: a repository password may be any
/// size and may contain newlines, while a capability must be rejected before
/// an unbounded stdin read can turn hostile input into memory pressure.
enum CapabilityInput {
    static let payloadBytes = 43
    static let maximumInputBytes = payloadBytes + 1 // one optional terminal LF

    /// Reads and validates the capability. A TTY gets the same stderr prompt
    /// and echo suppression SecretInput uses; a pipe/file is consumed only
    /// through the fixed 44-byte bound.
    static func read(prompt: String) throws -> String {
        let bytes: Data
        if isatty(STDIN_FILENO) == 1 {
            StandardStream.write(Data(prompt.utf8), to: .standardError)
            do {
                bytes = try SecretInput.withEchoDisabled {
                    try readTTYLine()
                }
            } catch {
                StandardStream.write(Data("\n".utf8), to: .standardError)
                throw error
            }
            // The user's Return was hidden with echo; preserve the terminal
            // layout even when validation below rejects the value.
            StandardStream.write(Data("\n".utf8), to: .standardError)
        } else {
            bytes = try readPipeOrFile()
        }
        return try validate(bytes)
    }

    /// Exposed to tests so every rejection assertion exercises the same
    /// canonicalization branch the command uses. The error text is shape-only
    /// and deliberately cannot reflect an attempted capability.
    static func validate(_ input: Data) throws -> String {
        var bytes = input
        if bytes.last == 0x0A {
            bytes.removeLast()
        }
        guard bytes.count == payloadBytes,
              bytes.allSatisfy({
                  ($0 >= Character.zero && $0 <= Character.nine)
                      || ($0 >= Character.upperA && $0 <= Character.upperZ)
                      || ($0 >= Character.lowerA && $0 <= Character.lowerZ)
                      || $0 == Character.hyphen
                      || $0 == Character.underscore
              }),
              let value = String(bytes: bytes, encoding: .ascii) else {
            throw invalidInput()
        }

        let padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let decoded = Data(base64Encoded: padded), decoded.count == 32 else {
            throw invalidInput()
        }
        let canonical = decoded
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard canonical == value else {
            throw invalidInput()
        }
        return value
    }

    private static func readTTYLine() throws -> Data {
        // A canonical terminal read returns after Return. Asking for one byte
        // beyond the maximum distinguishes the allowed 43 bytes + LF from
        // an oversized line without ever allocating from its length.
        guard let bytes = try FileHandle.standardInput.read(upToCount: maximumInputBytes + 1) else {
            return Data()
        }
        guard bytes.count <= maximumInputBytes else { throw invalidInput() }
        return bytes
    }

    private static func readPipeOrFile() throws -> Data {
        var bytes = Data()
        do {
            while true {
                let remaining = maximumInputBytes + 1 - bytes.count
                guard remaining > 0 else { throw invalidInput() }
                guard let chunk = try FileHandle.standardInput.read(upToCount: remaining), !chunk.isEmpty else {
                    return bytes
                }
                bytes.append(chunk)
                if bytes.count > maximumInputBytes { throw invalidInput() }
            }
        } catch let failure as CLIFailure {
            throw failure
        } catch {
            // Do not surface an OS error that might include a user-supplied
            // path or a platform-specific object description.
            throw CLIFailure.invalidArguments("could not read the capability from standard input")
        }
    }

    private static func invalidInput() -> CLIFailure {
        CLIFailure.invalidArguments(
            "capability input must be exactly 43 unpadded base64url characters (optionally followed by one newline)"
        )
    }

    private enum Character {
        static let zero: UInt8 = 48
        static let nine: UInt8 = 57
        static let upperA: UInt8 = 65
        static let upperZ: UInt8 = 90
        static let lowerA: UInt8 = 97
        static let lowerZ: UInt8 = 122
        static let hyphen: UInt8 = 45
        static let underscore: UInt8 = 95
    }
}
