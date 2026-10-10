import Foundation
import Testing
@testable import ResticStationCore

/// #83: `capabilities --json`'s document, for both platforms, built on
/// either. The command half (no config, no writes) is pinned by
/// `scripts/cli-contract-test.sh`.
@Suite struct CapabilityDocumentTests {
    /// A path no output may contain: where discovery "found" restic.
    static let canaryPath = "/opt/capability-canary-path/restic"

    static func found(_ version: String) -> ResticDiscoveryResult {
        ResticDiscoveryResult(
            chosen: ResticProbe(path: canaryPath, outcome: .ok(version: version)),
            rejected: [],
            searchedDescription: "test"
        )
    }

    static func document(
        _ platform: CapabilityDocument.Platform,
        discovery: ResticDiscoveryResult = found("0.19.1"),
        environment: [String: String] = [:]
    ) -> CapabilityDocument {
        CapabilityDocument.build(
            applicationName: "restic-station-helper",
            applicationVersion: "9.9.9",
            platform: platform,
            discovery: discovery,
            environment: environment
        )
    }

    static func object(_ document: CapabilityDocument) throws -> [String: Any] {
        struct NotAnObject: Error {}
        let data = try JSONEncoder().encode(document)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotAnObject()
        }
        return object
    }

    static func text(_ document: CapabilityDocument) throws -> String {
        String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
    }

    @Test("schema version 1 and the documented top-level keys")
    func shape() throws {
        let object = try Self.object(Self.document(.macOS))
        #expect(object["capabilitiesVersion"] as? Int == 1)
        #expect(Set(object.keys) == [
            "capabilitiesVersion", "application", "platform", "configSchema", "restic",
            "features", "scheduler", "secretBackend", "safetyClasses", "commands",
        ])
        let classes = object["safetyClasses"] as? [String]
        #expect(classes == ["readOnly", "localStateWrite", "configurationWrite", "repositoryWrite", "destructive"])
    }

    @Test("macOS: launchd, keychain, online-only safety, and the flag on restic 0.19")
    func macOS() throws {
        let document = Self.document(.macOS)
        #expect(document.platform == .macOS)
        #expect(document.scheduler.kind == "launchd")
        #expect(document.scheduler.managedBy == "app")
        #expect(document.secretBackend.kind == "keychain")
        #expect(document.features.excludeCloudFiles.available)
        #expect(document.features.onlineOnlyFilesRefusedAtKernel.available)
        #expect(document.features.cloudRepositoryDatalessPreflight.available)
        #expect(document.features.backupDryRun.available)
        #expect(!document.features.manualRetentionApply.available)
        #expect(document.features.purgeRequiresPreviewToken.available)

        let timer = try #require(document.commands.first { command in command.name == "timer install" })
        #expect(!timer.available)
        #expect(timer.reason != nil)
        let older = Self.document(.macOS, discovery: Self.found("0.18.1"))
        #expect(!older.features.excludeCloudFiles.available)
    }

    @Test("Linux: systemd timer, file secrets, no online-only features, never the flag")
    func linux() throws {
        let document = Self.document(.linux)
        #expect(document.scheduler.kind == "systemdUser")
        #expect(document.scheduler.managedBy == "helper")
        #expect(document.secretBackend.kind == "file")
        // #186: restic on Linux rejects the flag whatever its version.
        #expect(!document.features.excludeCloudFiles.available)
        #expect(!document.features.onlineOnlyFilesRefusedAtKernel.available)
        #expect(!document.features.cloudRepositoryDatalessPreflight.available)
        #expect(document.commands.allSatisfy { command in command.available })
    }

    @Test("restic missing, too old, or unusable: unavailable with a reason, and features follow")
    func resticStates() {
        let missing = Self.document(.macOS, discovery: ResticDiscoveryResult(chosen: nil, rejected: [], searchedDescription: "t"))
        #expect(!missing.restic.available)
        #expect(missing.restic.version == nil)
        #expect(missing.restic.reason != nil)
        #expect(!missing.features.backupDryRun.available)
        #expect(!missing.features.excludeCloudFiles.available)

        let old = Self.document(.macOS, discovery: ResticDiscoveryResult(
            chosen: nil,
            rejected: [ResticProbe(path: Self.canaryPath, outcome: .tooOld(version: "0.16.4"))],
            searchedDescription: "t"
        ))
        #expect(!old.restic.available)
        #expect(old.restic.version == "0.16.4")
        #expect(old.restic.minimumVersion == ResticDiscovery.minimumVersion)

        let broken = Self.document(.macOS, discovery: ResticDiscoveryResult(
            chosen: nil,
            rejected: [ResticProbe(path: Self.canaryPath, outcome: .unusable(reason: "exec format error"))],
            searchedDescription: "t"
        ))
        #expect(!broken.restic.available)
        #expect(broken.restic.version == nil)
    }

    @Test("an unknown secret backend override is reported, not thrown")
    func invalidSecretBackend() {
        let document = Self.document(.linux, environment: [SecretBackend.environmentKey: "vault"])
        #expect(document.secretBackend.kind == nil)
        #expect(document.secretBackend.reason != nil)
        let file = Self.document(.macOS, environment: [SecretBackend.environmentKey: "file"])
        #expect(file.secretBackend.kind == "file")
        // A real backend name the Linux helper refuses (Codex on #189).
        let keychainOnLinux = Self.document(.linux, environment: [SecretBackend.environmentKey: "keychain"])
        #expect(keychainOnLinux.secretBackend.kind == nil)
        #expect(keychainOnLinux.secretBackend.reason != nil)
        let keychainOnMac = Self.document(.macOS, environment: [SecretBackend.environmentKey: "keychain"])
        #expect(keychainOnMac.secretBackend.kind == "keychain")
    }

    @Test("no path, version text or override value leaks into the document")
    func noPrivateValues() throws {
        let document = Self.document(.macOS, environment: [SecretBackend.environmentKey: "secret-canary-value"])
        let text = try Self.text(document)
        #expect(!text.contains("capability-canary-path"))
        #expect(!text.contains("secret-canary-value"))
        // A version string that is not a version is reduced, never echoed.
        let odd = Self.document(.macOS, discovery: Self.found("0.19.1-canary/../etc"))
        #expect(!(try Self.text(odd)).contains("canary"))
    }

    @Test("the command table pins each command's safety class and json flag")
    func commandTable() {
        let table = Dictionary(uniqueKeysWithValues: CommandRegistry.commands.map { command in
            (command.name, command)
        })
        // Secret-attention bookkeeping is a local write (Codex on #189).
        #expect(table["backup dry-run"]?.safetyClass == .localStateWrite)
        #expect(table["snapshots list"]?.safetyClass == .localStateWrite)
        #expect(table["retention preview"]?.safetyClass == .localStateWrite)
        #expect(table["status"]?.safetyClass == .readOnly)
        #expect(table["probe-repo"]?.safetyClass == .localStateWrite)
        #expect(table["secret rm"]?.safetyClass == .configurationWrite)
        #expect(table["restore"]?.safetyClass == .repositoryWrite)
        #expect(table["run-set"]?.safetyClass == .destructive)
        #expect(table["purge apply"]?.safetyClass == .destructive)
        #expect(table["config export"]?.json == false)
        // `--out` writes a file (Codex on #189).
        #expect(table["config export"]?.safetyClass == .localStateWrite)
        #expect(table["capabilities"]?.json == true)
        #expect(CommandRegistry.excludedCommands["print-password"] != nil)
        #expect(table["print-password"] == nil)
    }
}
