import Foundation
import ServiceManagement
import Testing
@testable import Restic_Station

@Suite("Launchd registration presentation")
struct LaunchdManagerTests {
    @Test("a present embedded agent is not diagnosed as a broken installation")
    func presentAgentBeforeRegistration() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-present-\(UUID().uuidString).app", isDirectory: true)
        let agents = bundle.appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data().write(to: agents.appendingPathComponent(LaunchdManager.plistName))

        #expect(LaunchdManager.embeddedAgentExists(in: bundle.path))
        let message = LaunchdManager.diagnostic(for: .notFound, bundlePath: bundle.path)
        #expect(message?.contains("not set up yet") == true)
        #expect(message?.contains("could not find") == false)
    }

    @Test("a genuinely absent embedded agent retains reinstall guidance")
    func missingAgent() {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-missing-\(UUID().uuidString).app", isDirectory: true)

        #expect(!LaunchdManager.embeddedAgentExists(in: bundle.path))
        let message = LaunchdManager.diagnostic(for: .notFound, bundlePath: bundle.path)
        #expect(message?.contains("could not find") == true)
        #expect(message?.contains("reinstalling") == true)
    }
}
