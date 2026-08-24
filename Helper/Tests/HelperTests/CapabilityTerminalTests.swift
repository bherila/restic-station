import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@testable import restic_station_helper

/// `CapabilityInput` deliberately reuses SecretInput's TTY mechanics. This
/// opens a real pseudo-terminal rather than assuming a pipe test says
/// anything about echo, and throws from the guarded body to model malformed
/// capability input. The .serialized trait is required because the test
/// temporarily redirects the process-wide standard input descriptor.
@Suite("capability terminal echo", .serialized)
struct CapabilityTerminalTests {
    private struct MalformedCapability: Error {}

    @Test("echo is disabled during malformed capability input and restored afterwards")
    func echoIsRestoredAfterFailure() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        #expect(openpty(&master, &slave, nil, nil, nil) == 0)
        defer {
            if master >= 0 { _ = close(master) }
            if slave >= 0 { _ = close(slave) }
        }

        let savedStdin = dup(STDIN_FILENO)
        #expect(savedStdin >= 0)
        defer {
            if savedStdin >= 0 {
                _ = dup2(savedStdin, STDIN_FILENO)
                _ = close(savedStdin)
            }
        }
        #expect(dup2(slave, STDIN_FILENO) >= 0)

        var original = termios()
        #expect(tcgetattr(STDIN_FILENO, &original) == 0)
        #expect(throws: MalformedCapability.self) {
            try SecretInput.withEchoDisabled {
                var whileReading = termios()
                #expect(tcgetattr(STDIN_FILENO, &whileReading) == 0)
                #expect((whileReading.c_lflag & tcflag_t(ECHO)) == 0)
                throw MalformedCapability()
            }
        }

        var restored = termios()
        #expect(tcgetattr(STDIN_FILENO, &restored) == 0)
        #expect((restored.c_lflag & tcflag_t(ECHO)) == (original.c_lflag & tcflag_t(ECHO)))
    }
}
