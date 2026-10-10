import Foundation
import ResticStationCore
import Testing

@testable import restic_station_helper

/// #80: the set/destination selection `backup dry-run`, `snapshots list`
/// and `retention preview` share, and the snapshot shape both new commands
/// publish. The engine half is pinned by `RepositoryQueryTests`.
@Suite("repository query commands")
struct RepositoryQueryCommandTests {
    static let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    static let primaryId = UUID(uuidString: "0A1B2C3D-8B86-D011-B42D-00C04FC964FF")!
    static let mirrorId = UUID(uuidString: "1B2C3D4E-8B86-D011-B42D-00C04FC964FF")!
    static let unknownId = UUID(uuidString: "99999999-8B86-D011-B42D-00C04FC964FF")!

    /// `mirror-box` switches the mirror off; `laptop` switches the whole set off.
    static func config() -> AppConfig {
        AppConfig(sets: [BackupSet(
            id: setId,
            name: "Documents",
            sources: ["/Users/test/Documents"],
            schedule: .daily(hour: 2, minute: 30),
            destinations: [
                Destination(id: primaryId, label: "Big Drive", repoURL: "/Volumes/Big/docs", isPrimary: true),
                Destination(
                    id: mirrorId, label: "Scratch", repoURL: "/Volumes/Scratch/docs", isPrimary: false,
                    machines: ["mirror-box": DestinationMachineOverride(enabled: false)]
                ),
            ],
            machines: ["laptop": BackupSetMachineOverride(enabled: false)]
        )])
    }

    static func code(_ body: () throws -> Any) -> CLIErrorCode? {
        do {
            _ = try body()
            return nil
        } catch let failure as CLIFailure {
            return failure.code
        } catch {
            return .internalError
        }
    }

    @Test("a set switched off here is set_disabled_here; an unknown one set_not_found")
    func setSelection() throws {
        let config = Self.config()
        let disabled = Self.code { try RepositorySelection.set(Self.setId, scheduled: config.resolved(for: "laptop")) }
        #expect(disabled == .setDisabledHere)
        let unknown = Self.code { try RepositorySelection.set(Self.unknownId, scheduled: config.resolved(for: "studio")) }
        #expect(unknown == .setNotFound)
        let set = try RepositorySelection.set(Self.setId, scheduled: config.resolved(for: "studio"))
        #expect(set.id == Self.setId)
    }

    @Test("no --dest is the primary; a destination switched off here is destination_disabled_here")
    func destinationSelection() throws {
        let config = Self.config()
        let here = config.resolved(for: "mirror-box")
        let set = try RepositorySelection.set(Self.setId, scheduled: here)
        let addressable = config.addressable(for: "mirror-box")

        let primary = try RepositorySelection.destination(nil, of: set, addressable: addressable, machineId: "mirror-box")
        #expect(primary.id == Self.primaryId)
        let disabled = Self.code {
            try RepositorySelection.destination(Self.mirrorId, of: set, addressable: addressable, machineId: "mirror-box")
        }
        #expect(disabled == .destinationDisabledHere)
        let unknown = Self.code {
            try RepositorySelection.destination(Self.unknownId, of: set, addressable: addressable, machineId: "mirror-box")
        }
        #expect(unknown == .destinationNotFound)

        let elsewhere = try RepositorySelection.set(Self.setId, scheduled: config.resolved(for: "studio"))
        let mirror = try RepositorySelection.destination(
            Self.mirrorId, of: elsewhere, addressable: config.addressable(for: "studio"), machineId: "studio"
        )
        #expect(mirror.id == Self.mirrorId)
    }

    static func snapshot() throws -> Snapshot {
        let json = """
            [{"id":"\(String(repeating: "a", count: 64))","short_id":"aaaaaaaa","time":"2026-07-01T10:00:00Z",
              "paths":["/Users/test/Documents","/Users/test/Notes"],"hostname":"example-mac","username":"test",
              "tags":null}]
            """
        struct NoSnapshot: Error {}
        guard let first = try parseSnapshots(Data(json.utf8)).first else { throw NoSnapshot() }
        return first
    }

    @Test("snapshot JSON: paths null unless asked for, tags never null, reasons only when given")
    func snapshotShape() throws {
        let snapshot = try Self.snapshot()
        struct NotAnObject: Error {}
        func object(_ value: SnapshotJSON) throws -> [String: Any] {
            let data = try JSONEncoder().encode(value)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NotAnObject()
            }
            return object
        }

        let plain = try object(SnapshotJSON(snapshot, includePaths: false))
        #expect(plain["paths"] is NSNull)
        #expect(plain["pathCount"] as? Int == 2)
        #expect((plain["tags"] as? [String]) == [])
        #expect(plain["parent"] is NSNull)
        #expect(plain["reasons"] == nil)

        let withPaths = try object(SnapshotJSON(snapshot, includePaths: true, reasons: ["last snapshot"]))
        #expect((withPaths["paths"] as? [String]) == ["/Users/test/Documents", "/Users/test/Notes"])
        #expect((withPaths["reasons"] as? [String]) == ["last snapshot"])
    }

    @Test("destination JSON carries a role and never the repository URL")
    func destinationShape() throws {
        let destination = Destination(id: Self.mirrorId, label: "Scratch", repoURL: "/Volumes/Scratch/docs", isPrimary: false)
        let text = String(decoding: try JSONEncoder().encode(DestinationJSON(destination)), as: UTF8.self)
        #expect(text.contains("\"role\":\"secondary\""))
        #expect(!text.contains("Volumes"))
    }
}
