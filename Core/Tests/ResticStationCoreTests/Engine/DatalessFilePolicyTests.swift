import Foundation
import Testing
@testable import ResticStationCore

/// #156: which restic children may download an online-only file by reading
/// it. Only the backup of a set whose `onlineOnlyFiles` is `.download`;
/// every other restic process, whatever the set's policy, is refused.
@Suite struct DatalessFilePolicyTests {
    typealias T = BackupEngineTests

    @Test("only a download set's backup may download online-only files; every other restic child is refused")
    func policyPerChild() async throws {
        for setPolicy in OnlineOnlyFiles.allCases {
            let env = T.makeEnv(script: [], onlineOnlyFiles: setPolicy)
            defer { env.cleanUp() }
            env.fake.script = SecretPreflightAttentionTests.anything
            _ = await env.engine.runSet(env.set, trigger: .scheduled)
            env.fake.script = SecretPreflightAttentionTests.anything
            _ = await env.engine.runCheck(env.set, trigger: .scheduled)
            env.fake.script = SecretPreflightAttentionTests.anything
            _ = await env.engine.runRestore(request: RestoreRequest(
                destId: T.primaryId, snapshotID: "abc123", targetPath: "/tmp/target"
            ))

            let restic = env.fake.datalessPolicies.filter { $0.argv.first == env.resticPath }
            let kinds = Set(restic.compactMap { $0.argv.dropFirst(3).first })
            #expect(kinds.isSuperset(of: ["backup", "copy", "forget", "check", "restore"]), "\(setPolicy): \(kinds)")
            for call in restic {
                let expected: DatalessFileReads =
                    call.argv.contains("backup") && setPolicy == .download ? .download : .refuse
                #expect(call.policy == expected, "\(setPolicy): \(call.argv.dropFirst(3).prefix(1)) got \(String(describing: call.policy))")
            }
        }
    }
}
