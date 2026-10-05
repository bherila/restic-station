#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import ResticStationCore

/// #156 on the real kernel: the dataless-file policy a child is spawned with
/// is the one it reports from inside, for its whole life, and the helper's
/// own policy is back as it was afterwards.
///
/// No dataless file is involved — the probe only reads its own policy with
/// `getiopolicy_np`, so nothing on this machine can be downloaded or evicted
/// by running it. The probe is compiled per run because no stock binary
/// prints the policy.
@Suite(.serialized) struct DatalessSpawnPolicyTests {
    private static let probeSource = """
        #include <stdio.h>
        #include <sys/resource.h>
        int main(void) {
            printf("%d\\n", getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS));
            return 0;
        }
        """

    private static func compileProbe(in directory: URL) async throws -> String {
        let source = directory.appendingPathComponent("probe.c")
        let binary = directory.appendingPathComponent("probe")
        try probeSource.write(to: source, atomically: true, encoding: .utf8)
        let result = try await DefaultProcessRunner().run(
            ["/usr/bin/xcrun", "--sdk", "macosx", "clang", "-o", binary.path, source.path],
            env: nil,
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: 120
        )
        try #require(result.exitCode == 0, "probe did not compile: \(String(decoding: result.stderr, as: UTF8.self))")
        return binary.path
    }

    private static func childPolicy(_ probe: String, _ reads: DatalessFileReads?) async throws -> Int32? {
        let result = try await DefaultProcessRunner().run(
            [probe],
            env: [:],
            stdin: nil,
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: 30,
            datalessFiles: reads
        )
        return Int32(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static var ownPolicy: Int32 {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS)
    }

    @Test("a child runs under the policy it was spawned with, and the parent's is restored")
    func childSeesItsPolicy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dataless-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = try await Self.compileProbe(in: directory)
        let before = Self.ownPolicy

        #expect(try await Self.childPolicy(probe, .refuse) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(try await Self.childPolicy(probe, .download) == IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        #expect(try await Self.childPolicy(probe, nil) == before, "nil must leave the child to inherit")
        #expect(Self.ownPolicy == before, "the helper's own policy must be put back")
    }

    /// The window is guarded by `spawnLock`: concurrent spawns asking for
    /// different policies must each get their own, never a neighbour's.
    @Test("concurrent spawns with different policies each get their own")
    func concurrentSpawnsDoNotMix() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dataless-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = try await Self.compileProbe(in: directory)
        let before = Self.ownPolicy

        let mismatches = try await withThrowingTaskGroup(of: String?.self) { group in
            for index in 0..<32 {
                let reads: DatalessFileReads = index.isMultiple(of: 2) ? .refuse : .download
                group.addTask {
                    let expected = reads == .refuse
                        ? IOPOL_MATERIALIZE_DATALESS_FILES_OFF : IOPOL_MATERIALIZE_DATALESS_FILES_ON
                    let seen = try await Self.childPolicy(probe, reads)
                    return seen == expected ? nil : "\(reads) saw \(String(describing: seen))"
                }
            }
            var found: [String] = []
            for try await mismatch in group {
                if let mismatch { found.append(mismatch) }
            }
            return found
        }

        #expect(mismatches.isEmpty, "\(mismatches)")
        #expect(Self.ownPolicy == before)
    }
}
#endif
