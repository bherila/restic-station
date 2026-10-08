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

    /// Codex on #174: the policy covers the whole process, so a download
    /// set backing up *into* cloud storage would let a repository pack
    /// evicted mid-backup be downloaded. Paths only: nothing is created
    /// under a real home directory.
    @Test("a download set does not download when its primary repository is in cloud storage")
    func cloudRepositoryOverridesDownload() throws {
        let home = "/Users/example"
        let env = T.makeEnv(script: [], onlineOnlyFiles: .download)
        defer { env.cleanUp() }
        var cloudPrimary = env.primary
        for (repo, downloads) in [
            ("\(home)/Library/Mobile Documents/com~apple~CloudDocs/restic", false),
            ("\(home)/Library/CloudStorage/OneDrive-Example/restic", false),
            ("/Volumes/Backup/restic", true),
        ] {
            cloudPrimary.repoURL = repo
            #expect(
                BackupEngine.backupDownloadsOnlineOnlyFiles(set: env.set, primary: cloudPrimary, homeDirectory: home)
                    == downloads,
                "\(repo)"
            )
        }
        var skipSet = env.set
        skipSet.onlineOnlyFiles = .skip
        cloudPrimary.repoURL = "/Volumes/Backup/restic"
        #expect(!BackupEngine.backupDownloadsOnlineOnlyFiles(set: skipSet, primary: cloudPrimary, homeDirectory: home))
    }
}
