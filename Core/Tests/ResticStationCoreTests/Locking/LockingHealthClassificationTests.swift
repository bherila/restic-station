import Foundation
import Testing
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The lock-health contention-vs-breakage taxonomy, pinned as a table.
//
// `LockingHealth.classifyHealthArtifactFailure` decides whether damage found
// on a *health-only* artifact proves a machine-wide production outage or is
// merely diagnostic failure. Unlike the other classification taxonomies,
// `LockFailure.operation` is a string (it names the failing syscall or
// policy check), so this classifier cannot be made compile-time exhaustive
// without retyping every `LockFailure` construction site — which PR-conflict
// constraints rule out for now. This table is the runtime substitute: it
// enumerates **every operation string the health-artifact probes can
// produce** and pins each one's scope, so a new or renamed operation that
// silently changes classification fails a named row here.

@Suite("classification table: lock-health artifact failures")
struct LockingHealthClassificationTests {

    /// The capabilities the health artifacts exist to exercise. A failure of
    /// one of these is a production outage even when it happens on a
    /// health-only inode: the filesystem refused a lock, an inode
    /// allocation, or a directory creation it would also refuse production.
    private static let machineWideOperations: [String] = [
        "flock",
        "create lock probe",
        "create protected directory",
    ]

    /// Every other operation string the health-artifact code paths
    /// (`FileLock.probeLocking`, `FileLock.ensureDirectory` on the scratch
    /// directory, `FileLock.probeActualCreation`) can put in a
    /// `LockFailure`. Damage to the artifact itself is inconclusive about
    /// production locks, so these classify as `.diagnostic`.
    private static let diagnosticOperations: [String] = [
        // open/verify of the health lock file itself
        "open",
        "fstat",
        "file type",
        "ownership",
        "fchmod",
        "fstat after fchmod",
        "permissions",
        // scratch-directory creation and repair
        "fchmod created protected directory",
        "open protected directory",
        "fstat protected directory",
        "protected directory type",
        "protected directory ownership",
        "fchmod protected directory",
        "fstat after protected directory fchmod",
        "protected directory permissions",
        "trusted directory boundary",
        // probe-file lifecycle
        "remove lock probe",
    ]

    @Test("capability failures on health artifacts are machine-wide outages")
    func machineWideRows() {
        for operation in Self.machineWideOperations {
            let classified = LockingHealth.classifyHealthArtifactFailure(
                LockFailure(path: "/data/locks/health.lock", operation: operation, errnoValue: ENOSPC)
            )
            #expect(classified.scope == .machine, "\(operation)")
        }
    }

    @Test("artifact-integrity failures stay diagnostic")
    func diagnosticRows() {
        for operation in Self.diagnosticOperations {
            let classified = LockingHealth.classifyHealthArtifactFailure(
                LockFailure(path: "/data/locks/health.lock", operation: operation, errnoValue: 0)
            )
            #expect(classified.scope == .diagnostic, "\(operation)")
        }
    }

    @Test("the two tables never overlap or drift into each other")
    func tablesAreDisjoint() {
        #expect(Set(Self.machineWideOperations).isDisjoint(with: Set(Self.diagnosticOperations)))
    }
}
