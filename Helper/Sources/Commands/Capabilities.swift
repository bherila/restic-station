import ArgumentParser
import Foundation
import ResticStationCore

/// `capabilities [--json]` (#83): what this helper can do here, for an agent
/// deciding what to call before calling it.
///
/// Like `version`, it never loads configuration or builds a
/// `HelperContext`, so it works with no `config.json`, an invalid one, or
/// no data directory at all, and it creates nothing. The only process it
/// starts is restic discovery's `restic version`, never a repository
/// command. It reads no secret, touches no scheduler and writes no state.
struct Capabilities: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Describe this helper's commands, their safety classes, and the features available here. "
            + "Needs no configuration and changes nothing. --json for scripting."
    )

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    func run() async throws {
        let document = CapabilityDocument.build(
            applicationName: Version.name,
            applicationVersion: Version.version,
            platform: .current,
            discovery: await ResticDiscovery().discover(),
            environment: ProcessInfo.processInfo.environment
        )
        if json {
            CLIJSON.print(document)
        } else {
            for line in Self.humanLines(document) {
                print(line)
            }
        }
    }

    static func humanLines(_ document: CapabilityDocument) -> [String] {
        func describe(_ feature: CapabilityDocument.Feature) -> String {
            feature.available ? "yes" : "no — \(feature.reason ?? "unavailable")"
        }
        let restic = document.restic.available
            ? "restic \(document.restic.version ?? "?")"
            : "restic unavailable — \(document.restic.reason ?? "unknown")"
        var lines = [
            "\(document.application.name) \(document.application.version) on \(document.platform.rawValue)",
            "  \(restic) (minimum \(document.restic.minimumVersion))",
            "  config.json schema: \(document.configSchema.current)",
            "  scheduler: \(document.scheduler.kind), managed by the \(document.scheduler.managedBy)",
            "  secret backend: \(document.secretBackend.kind ?? "invalid — \(document.secretBackend.reason ?? "")")",
            "  backup dry-run: \(describe(document.features.backupDryRun))",
            "  skip online-only files (--exclude-cloud-files): \(describe(document.features.excludeCloudFiles))",
            "  manual retention apply: \(describe(document.features.manualRetentionApply))",
            "  commands:",
        ]
        for command in document.commands {
            let json = command.json ? " --json" : ""
            let availability = command.available ? "" : " (unavailable: \(command.reason ?? ""))"
            lines.append("    \(command.name)\(json) — \(command.safetyClass.rawValue)\(availability)")
        }
        return lines
    }
}
