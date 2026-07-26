import Foundation
import Testing
@testable import ResticStationCore

/// Verbatim from `docs/data-model.md` §config.json, except the three
/// destination UUIDs, which the doc writes as truncated placeholders
/// (`"0A1B2C3D-...-PRIMARY"` etc.) that are not valid UUID strings and would
/// fail to decode. They are replaced here with valid UUIDs that keep the
/// doc's recognizable prefix. Every other byte — keys, values, nesting,
/// including the `retention` block's explicit `null`s — matches the doc.
let dataModelExampleConfigJSON = """
{
  "version": 1,
  "resticPath": "/opt/homebrew/bin/restic",
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "Projects",
      "sources": ["/Users/user/proj", "/Users/user/.gitconfig"],
      "excludes": ["node_modules", ".build", "*.tmp"],
      "schedule": { "kind": "daily", "hour": 2, "minute": 30 },
      "retention": {
        "keepLast": null, "keepHourly": null, "keepDaily": 7,
        "keepWeekly": 4, "keepMonthly": 12, "keepYearly": 2
      },
      "checkPolicy": { "enabled": true, "readDataSubsetSlices": 20 },
      "stalenessWarningDays": 14,
      "destinations": [
        {
          "id": "0A1B2C3D-4E5F-4A1B-8C1D-000000000001",
          "label": "iCloud",
          "repoURL": "/Users/user/Library/Mobile Documents/com~apple~CloudDocs/Backups/proj.restic",
          "isPrimary": true,
          "nonSecretEnv": {}
        },
        {
          "id": "1B2C3D4E-5F60-4A1B-8C1D-000000000002",
          "label": "R2 mirror",
          "repoURL": "s3:https://accountid.r2.cloudflarestorage.com/my-bucket/proj",
          "isPrimary": false,
          "nonSecretEnv": { "AWS_DEFAULT_REGION": "auto" }
        },
        {
          "id": "2C3D4E5F-6061-4A1B-8C1D-000000000003",
          "label": "External HDD",
          "repoURL": "/Volumes/BackupDisk/proj.restic",
          "isPrimary": false,
          "nonSecretEnv": {}
        }
      ]
    }
  ]
}
"""

@Suite struct ModelsDataModelExampleTests {
    @Test func exampleConfigDecodesWithoutError() throws {
        let data = Data(dataModelExampleConfigJSON.utf8)
        let config = try ConfigStore.makeDecoder().decode(AppConfig.self, from: data)
        try config.validate()

        // Field-for-field checks against the documented example.
        #expect(config.version == 1)
        #expect(config.resticPath == "/opt/homebrew/bin/restic")
        #expect(config.showMenuBarIcon == true)
        #expect(config.sets.count == 1)

        let set = config.sets[0]
        #expect(set.id == UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        #expect(set.name == "Projects")
        #expect(set.sources == ["/Users/user/proj", "/Users/user/.gitconfig"])
        #expect(set.excludes == ["node_modules", ".build", "*.tmp"])
        #expect(set.schedule == .daily(hour: 2, minute: 30))
        #expect(set.retention == RetentionPolicy(keepDaily: 7, keepWeekly: 4, keepMonthly: 12, keepYearly: 2))
        #expect(set.checkPolicy == CheckPolicy(enabled: true, readDataSubsetSlices: 20))
        #expect(set.stalenessWarningDays == 14)
        #expect(set.destinations.count == 3)

        let primary = set.destinations[0]
        #expect(primary.label == "iCloud")
        #expect(primary.isPrimary == true)
        #expect(primary.kind == .localPath)
        #expect(primary.nonSecretEnv == [:])

        let mirror1 = set.destinations[1]
        #expect(mirror1.label == "R2 mirror")
        #expect(mirror1.isPrimary == false)
        #expect(mirror1.kind == .s3)
        #expect(mirror1.nonSecretEnv == ["AWS_DEFAULT_REGION": "auto"])

        let mirror2 = set.destinations[2]
        #expect(mirror2.label == "External HDD")
        #expect(mirror2.isPrimary == false)
        #expect(mirror2.kind == .localPath)
    }
}

@Suite struct ModelsRoundTripTests {
    /// Exercises every `Schedule` case and every `DestinationKind`, then
    /// round-trips through `ConfigStore`'s encoder/decoder and checks both
    /// `Equatable` equality and JSON structural equality (parsed via
    /// `JSONSerialization`, so key order is irrelevant but every key/value —
    /// including explicit `null`s — must match byte-compatibly).
    @Test func roundTripEveryScheduleAndDestinationKind() throws {
        let everyMinutesSet = BackupSet(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            name: "EveryMinutes",
            sources: ["/src/a"],
            excludes: [],
            schedule: .everyMinutes(30),
            retention: nil,
            checkPolicy: nil,
            stalenessWarningDays: 14,
            destinations: [
                Destination(
                    id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                    label: "Local",
                    repoURL: "/repo/a",
                    isPrimary: true
                )
            ]
        )

        let hourlySet = BackupSet(
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            name: "Hourly",
            sources: ["/src/b"],
            excludes: ["*.tmp"],
            schedule: .hourly(minute: 15),
            retention: RetentionPolicy(keepLast: 5),
            checkPolicy: CheckPolicy(enabled: false, readDataSubsetSlices: 10),
            stalenessWarningDays: 7,
            destinations: [
                Destination(
                    id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
                    label: "SFTP primary",
                    repoURL: "sftp:user@host:/repo/b",
                    isPrimary: true
                ),
                Destination(
                    id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
                    label: "REST mirror",
                    repoURL: "rest:https://rest.example.com/repo/b",
                    isPrimary: false,
                    nonSecretEnv: ["FOO": "bar"]
                )
            ]
        )

        let dailySet = BackupSet(
            id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
            name: "Daily",
            sources: ["/src/c"],
            excludes: [],
            schedule: .daily(hour: 2, minute: 30),
            retention: RetentionPolicy(),
            checkPolicy: nil,
            stalenessWarningDays: 14,
            destinations: [
                Destination(
                    id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
                    label: "S3 primary",
                    repoURL: "s3:https://s3.amazonaws.com/bucket/repo-c",
                    isPrimary: true
                )
            ]
        )

        let weeklySet = BackupSet(
            id: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
            name: "Weekly",
            sources: ["/src/d"],
            excludes: [],
            schedule: .weekly(weekday: 7, hour: 23, minute: 59),
            retention: nil,
            checkPolicy: nil,
            stalenessWarningDays: 30,
            destinations: [
                Destination(
                    id: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
                    label: "B2 primary",
                    repoURL: "b2:bucket:path",
                    isPrimary: true
                )
            ]
        )

        let config = AppConfig(
            version: 1,
            resticPath: "/opt/homebrew/bin/restic",
            showMenuBarIcon: false,
            sets: [everyMinutesSet, hourlySet, dailySet, weeklySet]
        )
        try config.validate()

        let encoder = ConfigStore.makeEncoder()
        let decoder = ConfigStore.makeDecoder()

        let data = try encoder.encode(config)
        let decoded = try decoder.decode(AppConfig.self, from: data)

        #expect(decoded == config)

        // Every Schedule case represented.
        let schedules = decoded.sets.map(\.schedule)
        #expect(schedules.contains(.everyMinutes(30)))
        #expect(schedules.contains(.hourly(minute: 15)))
        #expect(schedules.contains(.daily(hour: 2, minute: 30)))
        #expect(schedules.contains(.weekly(weekday: 7, hour: 23, minute: 59)))

        // Every DestinationKind represented.
        let kinds = Set(decoded.sets.flatMap { $0.destinations.map(\.kind) })
        #expect(kinds == [.localPath, .sftp, .rest, .s3, .otherCloud])

        // Structural JSON equality against a hand-authored expected JSON,
        // ignoring key order (both sides parsed via JSONSerialization).
        let expectedJSON = """
        {
          "version": 1,
          "resticPath": "/opt/homebrew/bin/restic",
          "showMenuBarIcon": false,
          "sets": [
            {
              "id": "11111111-1111-4111-8111-111111111111",
              "name": "EveryMinutes",
              "sources": ["/src/a"],
              "excludes": [],
              "schedule": { "kind": "everyMinutes", "minutes": 30 },
              "retention": null,
              "checkPolicy": null,
              "stalenessWarningDays": 14,
              "destinations": [
                {
                  "id": "22222222-2222-4222-8222-222222222222",
                  "label": "Local",
                  "repoURL": "/repo/a",
                  "isPrimary": true,
                  "nonSecretEnv": {}
                }
              ]
            },
            {
              "id": "33333333-3333-4333-8333-333333333333",
              "name": "Hourly",
              "sources": ["/src/b"],
              "excludes": ["*.tmp"],
              "schedule": { "kind": "hourly", "minute": 15 },
              "retention": { "keepLast": 5, "keepHourly": null, "keepDaily": null, "keepWeekly": null, "keepMonthly": null, "keepYearly": null },
              "checkPolicy": { "enabled": false, "readDataSubsetSlices": 10 },
              "stalenessWarningDays": 7,
              "destinations": [
                {
                  "id": "44444444-4444-4444-8444-444444444444",
                  "label": "SFTP primary",
                  "repoURL": "sftp:user@host:/repo/b",
                  "isPrimary": true,
                  "nonSecretEnv": {}
                },
                {
                  "id": "55555555-5555-4555-8555-555555555555",
                  "label": "REST mirror",
                  "repoURL": "rest:https://rest.example.com/repo/b",
                  "isPrimary": false,
                  "nonSecretEnv": { "FOO": "bar" }
                }
              ]
            },
            {
              "id": "66666666-6666-4666-8666-666666666666",
              "name": "Daily",
              "sources": ["/src/c"],
              "excludes": [],
              "schedule": { "kind": "daily", "hour": 2, "minute": 30 },
              "retention": { "keepLast": null, "keepHourly": null, "keepDaily": null, "keepWeekly": null, "keepMonthly": null, "keepYearly": null },
              "checkPolicy": null,
              "stalenessWarningDays": 14,
              "destinations": [
                {
                  "id": "77777777-7777-4777-8777-777777777777",
                  "label": "S3 primary",
                  "repoURL": "s3:https://s3.amazonaws.com/bucket/repo-c",
                  "isPrimary": true,
                  "nonSecretEnv": {}
                }
              ]
            },
            {
              "id": "88888888-8888-4888-8888-888888888888",
              "name": "Weekly",
              "sources": ["/src/d"],
              "excludes": [],
              "schedule": { "kind": "weekly", "weekday": 7, "hour": 23, "minute": 59 },
              "retention": null,
              "checkPolicy": null,
              "stalenessWarningDays": 30,
              "destinations": [
                {
                  "id": "99999999-9999-4999-8999-999999999999",
                  "label": "B2 primary",
                  "repoURL": "b2:bucket:path",
                  "isPrimary": true,
                  "nonSecretEnv": {}
                }
              ]
            }
          ]
        }
        """

        let actualObject = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let expectedObject = try JSONSerialization.jsonObject(with: Data(expectedJSON.utf8)) as? NSDictionary
        #expect(actualObject == expectedObject)
    }
}

@Suite struct ScheduleCodingTests {
    @Test(arguments: [
        (Schedule.everyMinutes(30), #"{"kind":"everyMinutes","minutes":30}"#),
        (Schedule.hourly(minute: 15), #"{"kind":"hourly","minute":15}"#),
        (Schedule.daily(hour: 2, minute: 30), #"{"kind":"daily","hour":2,"minute":30}"#),
        (Schedule.weekly(weekday: 1, hour: 3, minute: 0), #"{"kind":"weekly","weekday":1,"hour":3,"minute":0}"#)
    ])
    func encodesAndDecodesRoundTrip(schedule: Schedule, json: String) throws {
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Schedule.self, from: Data(json.utf8))
        #expect(decoded == schedule)

        let encoder = JSONEncoder()
        let data = try encoder.encode(schedule)
        let redecoded = try decoder.decode(Schedule.self, from: data)
        #expect(redecoded == schedule)
    }

    @Test func unknownKindThrows() {
        let json = #"{"kind":"monthly","day":1}"#
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
        }
    }
}

@Suite struct DestinationKindTests {
    @Test(arguments: [
        ("/Volumes/BackupDisk/repo", DestinationKind.localPath),
        ("/Users/user/Library/Mobile Documents/com~apple~CloudDocs/repo", DestinationKind.localPath),
        ("sftp:user@host:/repo", DestinationKind.sftp),
        ("rest:https://rest.example.com/repo", DestinationKind.rest),
        ("s3:https://s3.amazonaws.com/bucket", DestinationKind.s3),
        ("b2:bucket:path", DestinationKind.otherCloud),
        ("azure:container:path", DestinationKind.otherCloud),
        ("gs:bucket:path", DestinationKind.otherCloud),
        ("swift:container:path", DestinationKind.otherCloud),
        ("rclone:remote:path", DestinationKind.otherCloud)
    ])
    func derivesKindFromRepoURLPrefix(repoURL: String, expectedKind: DestinationKind) {
        let destination = Destination(id: UUID(), label: "x", repoURL: repoURL, isPrimary: true)
        #expect(destination.kind == expectedKind)
    }
}

@Suite struct RetentionPolicyTests {
    @Test func isEmptyWhenAllFieldsNil() {
        #expect(RetentionPolicy().isEmpty == true)
    }

    @Test func isNotEmptyWhenAnyFieldSet() {
        #expect(RetentionPolicy(keepLast: 1).isEmpty == false)
        #expect(RetentionPolicy(keepYearly: 1).isEmpty == false)
    }
}
