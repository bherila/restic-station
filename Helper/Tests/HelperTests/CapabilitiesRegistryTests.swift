import ArgumentParser
import Foundation
import ResticStationCore
import Testing

@testable import restic_station_helper

/// #83: every command registered in the binary has exactly one entry in
/// `CommandRegistry` or a documented exclusion, so a new command cannot
/// reach `--help` without someone deciding its safety class.
@Suite("capabilities registry")
struct CapabilitiesRegistryTests {
    /// Leaf command paths as typed (`"snapshots list"`), walked off the live
    /// ArgumentParser tree rather than restated.
    static func leafPaths(_ type: any ParsableCommand.Type, prefix: String) -> [String] {
        let configuration = type.configuration
        let name = configuration.commandName ?? "<unnamed \(type)>"
        let path = prefix.isEmpty ? name : prefix + " " + name
        let children = configuration.subcommands
        guard !children.isEmpty else { return [path] }
        var paths: [String] = []
        for child in children {
            paths += leafPaths(child, prefix: path)
        }
        return paths
    }

    static var registeredPaths: [String] {
        var paths: [String] = []
        for subcommand in HelperMain.configuration.subcommands {
            paths += leafPaths(subcommand, prefix: "")
        }
        return paths
    }

    @Test("every registered command is classified or excluded, and nothing else is listed")
    func registryMatchesTheCommandTree() {
        let registered = Set(Self.registeredPaths)
        #if os(Linux)
        let builtHere = CommandRegistry.commands
        #else
        let builtHere = CommandRegistry.commands.filter { command in !command.linuxOnly }
        #endif
        let classified = Set(builtHere.map { command in command.name })
        let excluded = Set(CommandRegistry.excludedCommands.keys)

        #expect(registered.subtracting(classified).subtracting(excluded).isEmpty,
                "registered but unclassified: \(registered.subtracting(classified).subtracting(excluded).sorted())")
        #expect(classified.subtracting(registered).isEmpty,
                "classified but not registered: \(classified.subtracting(registered).sorted())")
        #expect(excluded.isSubset(of: registered))
        #expect(classified.isDisjoint(with: excluded))
    }

    @Test("each command appears once")
    func namesAreUnique() {
        let names = CommandRegistry.commands.map { command in command.name }
        #expect(Set(names).count == names.count)
    }

    /// The `--json` flag each entry claims is the parsed command's own.
    @Test("a command's json flag matches whether it declares --json")
    func jsonFlagsMatchTheCommands() throws {
        for command in CommandRegistry.commands where !command.linuxOnly {
            let arguments = command.name.split(separator: " ").map(String.init)
            let commandType = try Self.type(at: arguments)
            let helpText = HelperMain.helpMessage(for: commandType, includeHidden: false, columns: 500)
            #expect(helpText.contains("--json") == command.json, "\(command.name)")
        }
    }

    struct NoSuchCommand: Error {}

    static func type(at path: [String]) throws -> any ParsableCommand.Type {
        var current: [any ParsableCommand.Type] = HelperMain.configuration.subcommands
        var found: (any ParsableCommand.Type)?
        for component in path {
            guard let next = current.first(where: { candidate in candidate.configuration.commandName == component }) else {
                throw NoSuchCommand()
            }
            found = next
            current = next.configuration.subcommands
        }
        guard let found else { throw NoSuchCommand() }
        return found
    }
}
