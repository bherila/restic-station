import Foundation
import ResticStationCore
import Sparkle
import Testing
@testable import Restic_Station

@Suite("Update schema gate")
struct UpdateSchemaGateTests {
    @Test("an update that writes the running schema goes straight to Sparkle")
    func sameSchemaProceeds() {
        #expect(UpdateSchemaGate.decision(declared: "4", feedVerified: true, running: 4) == .proceed)
        #expect(UpdateSchemaGate.decision(declared: " 4\n", feedVerified: true, running: 4) == .proceed)
    }

    @Test("an update that migrates the shared config asks first")
    func schemaUpgradeConfirms() {
        #expect(UpdateSchemaGate.decision(declared: "5", feedVerified: true, running: 4) == .confirm(.upgrade(from: 4, to: 5)))
    }

    @Test("an update that couldn't read the current config is refused")
    func olderSchemaRefuses() {
        #expect(UpdateSchemaGate.decision(declared: "3", feedVerified: true, running: 4) == .refuse(.olderSchema(declared: 3)))
    }

    @Test(
        "a missing or malformed schema is an unknown change, never 'unchanged'",
        arguments: [nil, "", "four", "0", "-1", "4.0", "4 5"] as [String?]
    )
    func undeclaredSchemaConfirms(raw: String?) {
        #expect(UpdateSchemaGate.decision(declared: raw, feedVerified: true, running: 4) == .confirm(.undeclared))
    }

    @Test("a non-string value is treated as undeclared")
    func nonStringConfirms() {
        #expect(UpdateSchemaGate.decision(declared: NSNumber(value: 4), feedVerified: true, running: 4) == .confirm(.undeclared))
    }

    @Test(
        "an item from a feed whose signature didn't verify is refused, whatever it claims",
        arguments: ["4", "5", "3", nil] as [String?]
    )
    func unverifiedFeedRefuses(raw: String?) {
        #expect(UpdateSchemaGate.decision(declared: raw, feedVerified: false, running: 4) == .refuse(.unverifiedFeed))
    }

    @Test("the confirmation names both schema versions and the fleet consequence")
    func confirmationCopy() {
        let message = UpdateSchemaGate.confirmationMessage(change: .upgrade(from: 4, to: 5))
        #expect(message.contains("v4"))
        #expect(message.contains("v5"))
        #expect(message.contains("backups stop"))
    }
}

@Suite("UpdateController gate wiring")
@MainActor
struct UpdateControllerGateTests {
    /// A fresh defaults domain per test, so acknowledgements never leak
    /// between tests or into the real app's domain.
    private func makeDefaults() -> UserDefaults {
        let suite = "UpdateControllerGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private final class Prompter {
        var answers: [Bool]
        var titles: [String] = []
        init(_ answers: [Bool]) { self.answers = answers }
        func ask(_ title: String, _ message: String) -> Bool {
            titles.append(title)
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }

    private func makeController(defaults: UserDefaults, prompter: Prompter) -> UpdateController {
        UpdateController(
            defaults: defaults,
            runningSchema: 4,
            startingUpdater: false,
            confirm: { prompter.ask($0, $1) }
        )
    }

    @Test("same schema never prompts")
    func sameSchemaDoesNotPrompt() throws {
        let prompter = Prompter([])
        let controller = makeController(defaults: makeDefaults(), prompter: prompter)
        try controller.evaluate(declared: "4", feedVerified: true, version: "0.2.0", build: "2", updateCheck: .updates)
        try controller.evaluate(declared: "4", feedVerified: true, version: "0.2.0", build: "2", updateCheck: .updatesInBackground)
        #expect(prompter.titles.isEmpty)
    }

    @Test("declining a schema change cancels silently and asks again next time")
    func declineCancelsAndReasks() {
        let defaults = makeDefaults()
        let prompter = Prompter([false, false])
        let controller = makeController(defaults: defaults, prompter: prompter)

        for _ in 0..<2 {
            #expect {
                try controller.evaluate(declared: "5", feedVerified: true, version: "0.2.0", build: "2", updateCheck: .updatesInBackground)
            } throws: { error in
                let error = error as NSError
                return error.domain == SUSparkleErrorDomain
                    && error.code == Int(SUError.installationCanceledError.rawValue)
            }
        }
        #expect(prompter.titles.count == 2)
        #expect(defaults.stringArray(forKey: UpdateController.acknowledgedVersionsKey) == nil)
    }

    @Test("confirming a schema change is remembered for that build only")
    func confirmIsRememberedPerBuild() throws {
        let defaults = makeDefaults()
        let prompter = Prompter([true, true])
        let controller = makeController(defaults: defaults, prompter: prompter)

        try controller.evaluate(declared: "5", feedVerified: true, version: "0.2.0", build: "2", updateCheck: .updates)
        #expect(prompter.titles.count == 1)
        try controller.evaluate(declared: "5", feedVerified: true, version: "0.2.0", build: "2", updateCheck: .updatesInBackground)
        #expect(prompter.titles.count == 1)
        try controller.evaluate(declared: "5", feedVerified: true, version: "0.2.1", build: "3", updateCheck: .updates)
        #expect(prompter.titles.count == 2)
        #expect(defaults.stringArray(forKey: UpdateController.acknowledgedVersionsKey) == ["2", "3"])
    }

    @Test("an undeclared schema prompts like a schema change")
    func undeclaredPrompts() throws {
        let prompter = Prompter([true])
        let controller = makeController(defaults: makeDefaults(), prompter: prompter)
        try controller.evaluate(declared: nil, feedVerified: true, version: "0.2.0", build: "2", updateCheck: .updates)
        #expect(prompter.titles == [UpdateSchemaGate.confirmationTitle(version: "0.2.0", change: .undeclared)])
    }

    @Test("an older schema is refused with a visible error and no prompt")
    func olderSchemaRefusedWithoutPrompt() {
        let prompter = Prompter([true])
        let controller = makeController(defaults: makeDefaults(), prompter: prompter)
        #expect {
            try controller.evaluate(declared: "3", feedVerified: true, version: "0.2.0", build: "2", updateCheck: .updates)
        } throws: { error in
            let error = error as NSError
            return error.code != Int(SUError.installationCanceledError.rawValue)
                && error.localizedDescription.contains("v3")
        }
        #expect(prompter.titles.isEmpty)
    }

    @Test("an unsigned feed is refused even for a build the user already confirmed")
    func unverifiedFeedIgnoresAcknowledgement() throws {
        let defaults = makeDefaults()
        let prompter = Prompter([true])
        let controller = makeController(defaults: defaults, prompter: prompter)
        try controller.evaluate(declared: "5", feedVerified: true, version: "0.2.0", build: "2", updateCheck: .updates)
        #expect(defaults.stringArray(forKey: UpdateController.acknowledgedVersionsKey) == ["2"])

        for declared in ["4", "5"] {
            #expect {
                try controller.evaluate(
                    declared: declared, feedVerified: false, version: "0.2.0", build: "2", updateCheck: .updates
                )
            } throws: { error in
                let error = error as NSError
                return error.code == Int(SUError.validationError.rawValue)
                    && error.localizedDescription.contains("not signed")
            }
        }
        #expect(prompter.titles.count == 1)
    }

    @Test("an information-only probe never prompts, even for a schema change")
    func informationProbeDoesNotPrompt() throws {
        let prompter = Prompter([])
        let controller = makeController(defaults: makeDefaults(), prompter: prompter)
        try controller.evaluate(declared: "5", feedVerified: true, version: "0.2.0", build: "2", updateCheck: .updateInformation)
        #expect(prompter.titles.isEmpty)
    }
}

@Suite("Sparkle Info.plist configuration")
struct SparkleInfoPlistTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    @Test("the feed is the latest GitHub release's appcast")
    func feedURL() {
        #expect(info["SUFeedURL"] as? String
            == "https://github.com/bherila/restic-station/releases/latest/download/appcast.xml")
    }

    @Test("the EdDSA public key is a 32-byte Ed25519 key")
    func publicKey() {
        let key = (info["SUPublicEDKey"] as? String).flatMap { Data(base64Encoded: $0) }
        #expect(key?.count == 32)
    }

    @Test("checks run daily and nothing installs without a click")
    func checkPolicy() {
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUScheduledCheckInterval"] as? Int == 86_400)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
    }

    @Test("the appcast must be signed, with no grace period after a failed check")
    func signedFeedRequired() {
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        // Sparkle ignores SURequireSignedFeed unless archives are also
        // verified before extraction.
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        // Sparkle's default (20 days) falls back to *offering* items from a
        // feed that keeps failing; 0 disables that fallback.
        #expect((info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue == 0)
    }

    @Test("the test host never starts the real updater")
    func testHostDetected() {
        #expect(UpdateController.isTestHost)
    }
}
