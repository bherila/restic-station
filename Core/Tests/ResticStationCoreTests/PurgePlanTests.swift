import Foundation
import Testing
@testable import ResticStationCore

@Suite("PurgePlan snapshot attribution")
struct PurgePlanTests {
    private static let destinationId = UUID(uuidString: "0A1B2C3D-8B86-D011-B42D-00C04FC964FF")!
    private static let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func snapshot(id: String, paths: [String], hostname: String) -> Snapshot {
        let json = """
        {
          "id": "\(id)", "short_id": "\(id.prefix(8))",
          "time": "2026-08-19T23:32:12Z", "paths": \(json(paths)),
          "hostname": "\(hostname)", "username": "bwh"
        }
        """
        return try! makeResticJSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    private func json(_ values: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: values)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("requires both source-subset and known-hostname attribution")
    func attribution() {
        let good = snapshot(id: "aaaaaaaaaaaaaaaa", paths: ["/Users/bwh/Projects"], hostname: "studio-mac")
        let otherHost = snapshot(id: "bbbbbbbbbbbbbbbb", paths: ["/Users/bwh/Projects"], hostname: "linux-nas")
        let otherPath = snapshot(id: "cccccccccccccccc", paths: ["/Users/bwh/Secrets"], hostname: "studio-mac")

        let plan = PurgePlan(
            destinationId: Self.destinationId,
            snapshots: [good, otherHost, otherPath],
            sourcePaths: ["/Users/bwh/Projects"],
            hostnames: ["studio-mac"],
            patterns: ["build/**"]
        )

        #expect(plan.matched.map(\.id) == [good.id])
        #expect(plan.unattributed.map(\.id) == [otherHost.id, otherPath.id])
        #expect(plan.patterns == ["build/**"])
    }

    @Test("raw set source union includes every machine override")
    func sourceUnion() {
        let set = BackupSet(
            id: Self.setId,
            name: "Projects",
            sources: ["/shared"],
            schedule: .daily(hour: 2, minute: 30),
            destinations: [],
            machines: [
                "studio-mac": BackupSetMachineOverride(sources: ["/Users/bwh/Projects"]),
                "linux-nas": BackupSetMachineOverride(sources: ["/srv/projects"]),
            ]
        )
        let snapshots = [
            snapshot(id: "aaaaaaaaaaaaaaaa", paths: ["/Users/bwh/Projects"], hostname: "studio-mac"),
            snapshot(id: "bbbbbbbbbbbbbbbb", paths: ["/srv/projects"], hostname: "linux-nas"),
        ]
        let plan = PurgePlan(
            destinationId: Self.destinationId,
            snapshots: snapshots,
            set: set,
            hostnames: ["studio-mac", "linux-nas"]
        )
        #expect(plan.matched.count == 2)
    }

    @Test("missing hostname history declines otherwise matching paths")
    func requiresHostnameHistory() {
        let snapshot = snapshot(
            id: "aaaaaaaaaaaaaaaa",
            paths: ["/Users/bwh/Projects"],
            hostname: "studio-mac"
        )
        let plan = PurgePlan(
            destinationId: Self.destinationId,
            snapshots: [snapshot],
            sourcePaths: ["/Users/bwh/Projects"],
            hostnames: [],
            patterns: ["build/**"]
        )

        #expect(plan.matched.isEmpty)
        #expect(plan.unattributed.map(\.id) == [snapshot.id])
    }
}
