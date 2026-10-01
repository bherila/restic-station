import Foundation
import ResticStationCore
import Testing
@testable import Restic_Station

/// #162: a `config.json` this build cannot read must never look like an
/// empty one. These pin the model state the set list, the window banner and
/// the menu bar read.
@Suite("Config file problems are not an empty config", .serialized)
@MainActor
struct ConfigFileProblemTests {
    private func makePaths() -> (AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-config-problem-\(UUID().uuidString)", isDirectory: true)
        return (AppPaths(root: root), root)
    }

    private func oneSetConfig() -> AppConfig {
        AppConfig(sets: [
            BackupSet(
                id: UUID(),
                name: "Documents",
                sources: ["/Users/shared/Documents"],
                schedule: .daily(hour: 2, minute: 30),
                destinations: [
                    Destination(id: UUID(), label: "Primary", repoURL: "/Volumes/backup/docs.restic", isPrimary: true),
                ]
            ),
        ])
    }

    /// The bytes a newer build would write: today's config, relabelled.
    private func writeNewerSchema(_ config: AppConfig, to paths: AppPaths, version: Int) throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: ConfigStore.makeEncoder().encode(config)) as? [String: Any]
        )
        object["version"] = version
        try JSONSerialization.data(withJSONObject: object).write(to: paths.configFile, options: .atomic)
    }

    @Test("a config from a newer schema is reported as such, not as no sets")
    func newerSchemaAtLaunch() throws {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try ConfigStore(paths: paths).save(AppConfig())
        try writeNewerSchema(oneSetConfig(), to: paths, version: AppConfig.currentVersion + 1)

        let model = AppModel(paths: paths)

        #expect(model.config.sets.isEmpty)
        #expect(model.configFileProblem
            == .newerSchema(found: AppConfig.currentVersion + 1, supported: AppConfig.currentVersion))
        #expect(model.configFileProblem?.offersUpdateCheck == true)
        #expect(model.configLoadError != nil)
    }

    @Test("malformed config.json is unreadable, with no update offered")
    func malformedAtLaunch() throws {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try ConfigStore(paths: paths).save(AppConfig())
        try Data("{ not json".utf8).write(to: paths.configFile, options: .atomic)

        let model = AppModel(paths: paths)

        guard case .unreadable = model.configFileProblem else {
            Issue.record("expected .unreadable, got \(String(describing: model.configFileProblem))")
            return
        }
        #expect(model.configFileProblem?.offersUpdateCheck == false)
    }

    @Test("a machine.json failure alone is not a config problem")
    func machineFailureIsNotConfigProblem() throws {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try ConfigStore(paths: paths).save(oneSetConfig())
        try Data("not json".utf8).write(to: paths.machineFile, options: .atomic)

        let model = AppModel(paths: paths)

        #expect(model.configLoadError != nil)
        #expect(model.configFileProblem == nil)
        #expect(model.config.sets.count == 1)
    }

    @Test("a failed reload keeps the last sets, flags them, and a good reload clears it")
    func reloadFailureThenRecovery() async throws {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = oneSetConfig()
        try ConfigStore(paths: paths).save(config)
        let model = AppModel(paths: paths)
        #expect(model.configFileProblem == nil)

        try writeNewerSchema(config, to: paths, version: AppConfig.currentVersion + 1)
        await model.reloadConfigFromDisk()
        #expect(model.config.sets.map(\.name) == ["Documents"])
        #expect(model.configFileProblem
            == .newerSchema(found: AppConfig.currentVersion + 1, supported: AppConfig.currentVersion))

        try ConfigStore(paths: paths).save(config)
        await model.reloadConfigFromDisk()
        #expect(model.configFileProblem == nil)
        #expect(model.configLoadError == nil)
    }

    @Test("an unreadable config raises app health to warning, never over critical")
    func healthPrecedence() {
        let problem = ConfigFileProblem.newerSchema(found: 5, supported: 4)
        #expect(AppModel.health(.idle, pendingSecretRollbackError: nil, configFileProblem: problem) == .warning)
        #expect(AppModel.health(.running, pendingSecretRollbackError: nil, configFileProblem: problem) == .warning)
        #expect(AppModel.health(.critical, pendingSecretRollbackError: nil, configFileProblem: problem) == .critical)
        #expect(AppModel.health(.idle, pendingSecretRollbackError: nil, configFileProblem: nil) == .idle)
        #expect(AppModel.health(.idle, pendingSecretRollbackError: "x", configFileProblem: nil) == .warning)
    }

    @Test("the copy says the data is intact and names both schema versions")
    func newerSchemaCopy() {
        let problem = ConfigFileProblem.newerSchema(found: 5, supported: 4)
        #expect(problem.explanation.contains("v5"))
        #expect(problem.explanation.contains("v4"))
        #expect(problem.explanation.contains("unchanged"))
        #expect(problem.title != SetsCopy.emptyStateTitle)
        #expect(ConfigFileProblem(ConfigError.newerVersion(found: 5, supported: 4)) == problem)
    }
}
