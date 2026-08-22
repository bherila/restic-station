import ArgumentParser
import Foundation
import ResticStationCore

/// `runs …` — inspect recorded runs (`runs/index.jsonl`, `runs/<runId>/`).
struct Runs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runs",
        abstract: "Inspect recorded runs. Exit 0 ok, 1 error.",
        subcommands: [RunsList.self, RunsShow.self]
    )
}

// MARK: - runs list

struct RunsList: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List recent runs from runs/index.jsonl, newest first. --json for scripting. "
            + "Exit 0 ok, 1 error."
    )

    @Option(name: .long, help: "Only runs for this backup set.")
    var set: UUID?

    @Option(name: .long, help: "Maximum number of runs to print (default 20).")
    var limit: Int = 20

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    func run() async throws {
        // A manual check, not ArgumentParser's own `validate()` throw: that
        // path exits with ArgumentParser's own usage code (64), not the 0/1
        // contract every subcommand here otherwise honours.
        guard limit > 0 else {
            throw CLIFailure.invalidArguments("--limit must be positive; got \(limit)")
        }

        let paths = AppPaths.default()
        let runStore = RunStore(paths: paths)

        // `RunStore.recentRuns(setId:limit:)` filters by `--set` *before*
        // truncating to `--limit` — a set that is not the most recently
        // active one still gets its own `limit` worth of history instead of
        // being crowded out by busier sets' newer runs.
        let entries: [RunIndexEntry]
        do {
            entries = try runStore.recentRuns(setId: set, limit: limit)
        } catch {
            throw CLIFailure.stateUnreadable("could not read runs/index.jsonl: \(error)")
        }

        if json {
            CLIJSON.print(entries)
        } else if entries.isEmpty {
            print("no runs recorded")
        } else {
            let formatter = ConfigStore.makeISO8601Formatter()
            for entry in entries {
                let end = entry.end.map(formatter.string(from:)) ?? "(running)"
                let error = entry.errorSummary.map { "  error=\($0)" } ?? ""
                print(
                    "\(entry.runId)  \(entry.kind.rawValue)  \(entry.status.rawValue)  "
                        + "start=\(formatter.string(from: entry.start))  end=\(end)\(error)"
                )
            }
        }
        HelperExit.code(0)
    }
}

// MARK: - runs show

struct RunsShow: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print one run's metadata (runs/<runId>/metadata.json). --log additionally "
            + "prints the full run log. --json emits the metadata as JSON (incompatible with "
            + "--log — the log is not part of the metadata shape). Exit 0 ok, 1 error."
    )

    @Argument(help: "The runId to show, e.g. 20260726T205704Z-backup-6f9619ff.")
    var runId: String

    @Flag(name: .long, help: "Also print the full runs/<runId>/log.txt.")
    var log = false

    @Flag(name: .long, help: "Emit the metadata as JSON. Only JSON reaches stdout in this mode.")
    var json = false

    func run() async throws {
        let paths = AppPaths.default()
        let runStore = RunStore(paths: paths)

        let metadata: RunMetadata
        do {
            metadata = try runStore.metadata(runId: runId)
        } catch {
            throw CLIFailure.runUnreadable(runId: runId, underlying: error)
        }

        if json {
            if log {
                StandardStream.writeToStandardError(
                    Data("--log has no effect with --json; the log is not part of the metadata shape\n".utf8)
                )
            }
            CLIJSON.print(metadata)
            HelperExit.code(0)
        }

        let formatter = ConfigStore.makeISO8601Formatter()
        print("runId:    \(metadata.runId)")
        print("kind:     \(metadata.kind.rawValue)")
        print("setId:    \(metadata.setId.uuidString.lowercased())")
        print("destId:   \(metadata.destId.uuidString.lowercased())")
        print("status:   \(metadata.status.rawValue)")
        print("trigger:  \(metadata.trigger.rawValue)")
        print("start:    \(formatter.string(from: metadata.start))")
        print("end:      \(metadata.end.map(formatter.string(from:)) ?? "(running)")")
        if let snapshotId = metadata.snapshotId {
            print("snapshot: \(snapshotId)")
        }
        if let errorSummary = metadata.errorSummary {
            print("error:    \(errorSummary)")
        }
        // `argvRedacted` never contains a secret (see its doc comment in
        // `Core/Sources/ResticStationCore/Runs/RunRecord.swift` — passwords
        // and secret env only ever travel via `RESTIC_PASSWORD_COMMAND`/
        // `secrets.passwordCommandEnvironment`, never argv).
        if !metadata.argvRedacted.isEmpty {
            print("argv:     \(metadata.argvRedacted.joined(separator: " "))")
        }

        if log {
            let logURL = runStore.logURL(runId: runId)
            guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else {
                throw CLIFailure.stateUnreadable("could not read \(logURL.path)")
            }
            print("")
            print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
        }
        HelperExit.code(0)
    }
}
