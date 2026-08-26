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

    // MARK: - Producer binding

    // The rows above pin the classifier against synthetic `LockFailure`s;
    // these bind the rows to the *producers*, by driving the real probe code
    // paths into failure and classifying what they actually emit. A renamed
    // operation string in `FileLock` now fails here instead of silently
    // falling through `classifyHealthArtifactFailure` to `.diagnostic`
    // while the synthetic table keeps passing on the old spelling.
    //
    // "flock" is the one machine-wide row with no portably drivable
    // producer: its failure arm needs the syscall itself to fail (an
    // flock-less filesystem), which no temp-directory setup can simulate.
    // It stays table-only, pinned additionally by the contention tests in
    // FileLockTests exercising the surrounding switch.

    private func makeTempDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lh-producer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    @Test(
        "probeActualCreation's real failure classifies machine-wide",
        .enabled(if: canInjectPermissionFaults, "root can create in mode-0500 directories")
    )
    func actualCreationProbeFailureIsBoundToItsRow() throws {
        let directory = try makeTempDirectory()
        defer {
            chmod(directory.path, 0o700)
            try? FileManager.default.removeItem(at: directory)
        }
        try #require(chmod(directory.path, 0o500) == 0)

        let failure = try #require(
            FileLock.probeActualCreation(in: directory),
            "an unwritable directory must fail the creation probe"
        )
        #expect(Self.machineWideOperations.contains(failure.operation),
                "producer emitted \(failure.operation), which has no machine-wide row")
        #expect(LockingHealth.classifyHealthArtifactFailure(failure).scope == .machine)
    }

    @Test(
        "ensureDirectory's real creation failure classifies machine-wide",
        .enabled(if: canInjectPermissionFaults, "root can create in mode-0500 directories")
    )
    func ensureDirectoryCreateFailureIsBoundToItsRow() throws {
        let root = try makeTempDirectory()
        defer {
            chmod(root.appendingPathComponent("parent").path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try #require(chmod(parent.path, 0o500) == 0)

        let failure = try #require(
            FileLock.ensureDirectory(
                parent.appendingPathComponent("locks"),
                parent: parent,
                trustedRoot: root,
                mode: 0o700
            ),
            "creation under an unwritable parent must fail"
        )
        #expect(Self.machineWideOperations.contains(failure.operation),
                "producer emitted \(failure.operation), which has no machine-wide row")
        #expect(LockingHealth.classifyHealthArtifactFailure(failure).scope == .machine)
    }
}
