import Foundation
import Testing
@testable import ResticStationCore

/// Verbatim from `docs/data-model.md` §config.json, except the three
/// destination UUIDs, which the doc writes as truncated placeholders
/// (`"0A1B2C3D-...-PRIMARY"` etc.) that are not valid UUID strings and would
/// fail to decode. They are replaced here with valid UUIDs that keep the
/// doc's recognizable prefix. Every other byte — keys, values, nesting,
/// including the `retention` block's explicit `null`s — matches the doc.
///
/// It is a schema-v3 config with **no** `machines` keys — the shape the vast
/// majority of installs have, and the one the compatibility guarantee is
/// about: absent `machines` means inherit and run everywhere.
let dataModelExampleConfigJSON = """
{
  "version": 3,
  "resticPath": "/opt/homebrew/bin/restic",
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "Projects",
      "sources": ["/Users/user/proj", "/Users/user/.gitconfig"],
      "excludes": ["node_modules", ".build", "*.tmp"],
      "purgeExcludes": ["DerivedData"],
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
        #expect(config.version == 3)
        #expect(config.resticPath == "/opt/homebrew/bin/restic")
        #expect(config.showMenuBarIcon == true)
        #expect(config.sets.count == 1)
        #expect(config.sets[0].purgeExcludes == ["DerivedData"])

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
              "purgeExcludes": [],
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
              "purgeExcludes": [],
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
              "purgeExcludes": [],
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
              "purgeExcludes": [],
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

// MARK: - T24: per-machine overrides

/// The worked example from `docs/data-model.md` §Per-machine scoping, pinned
/// the same way the v1 example is: it must decode, validate, and re-encode
/// to exactly these keys — no `"machines": null` sprayed over the entries
/// that have no overrides, and no override field materialising as an
/// explicit `null`. Carries an explicit `"purgeExcludes": []` (absent from
/// the doc's v2-era prose) because `BackupSet.encode(to:)` always writes the
/// key regardless of a config's `version` — the structural round-trip below
/// would otherwise fail on the key the encoder adds back.
let dataModelMachinesExampleJSON = """
{
  "version": 2,
  "resticPath": null,
  "showMenuBarIcon": true,
  "sets": [
    {
      "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name": "Documents",
      "sources": ["/Users/bwh/Documents"],
      "excludes": [],
      "purgeExcludes": [],
      "schedule": { "kind": "daily", "hour": 2, "minute": 30 },
      "retention": null,
      "checkPolicy": null,
      "stalenessWarningDays": 14,
      "machines": {
        "linux-nas": { "enabled": true, "sources": ["/srv/data"] },
        "old-laptop": { "enabled": false }
      },
      "destinations": [
        {
          "id": "0A1B2C3D-4E5F-4A1B-8C1D-000000000001",
          "label": "Big Drive",
          "repoURL": "/Volumes/Big/repo",
          "isPrimary": true,
          "nonSecretEnv": {},
          "machines": { "linux-nas": { "repoURL": "/mnt/big/repo" } }
        }
      ]
    }
  ]
}
"""

@Suite struct ModelsMachineOverrideCodingTests {

    @Test func documentedOverrideExampleDecodesAndValidates() throws {
        let config = try ConfigStore.makeDecoder().decode(
            AppConfig.self,
            from: Data(dataModelMachinesExampleJSON.utf8)
        )
        try config.validate()

        let set = config.sets[0]
        #expect(set.machines?["linux-nas"] == BackupSetMachineOverride(enabled: true, sources: ["/srv/data"]))
        #expect(set.machines?["old-laptop"] == BackupSetMachineOverride(enabled: false))
        #expect(set.destinations[0].machines?["linux-nas"] == DestinationMachineOverride(repoURL: "/mnt/big/repo"))
    }

    @Test func documentedOverrideExampleRoundTripsStructurally() throws {
        let decoder = ConfigStore.makeDecoder()
        let config = try decoder.decode(AppConfig.self, from: Data(dataModelMachinesExampleJSON.utf8))
        let data = try ConfigStore.makeEncoder().encode(config)

        #expect(try decoder.decode(AppConfig.self, from: data) == config)

        let actual = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(
            with: Data(dataModelMachinesExampleJSON.utf8)
        ) as? NSDictionary
        #expect(actual == expected)
    }

    /// The compatibility rule that keeps every existing `config.json`
    /// byte-identical apart from its version number: a set or destination
    /// with no overrides must not gain a `machines` key on save.
    @Test func absentOverridesAreEncodedAsAbsentNotNull() throws {
        let config = AppConfig(sets: [BackupSet(
            id: UUID(),
            name: "Plain",
            sources: ["/src"],
            schedule: .daily(hour: 1, minute: 0),
            destinations: [Destination(id: UUID(), label: "Primary", repoURL: "/repo", isPrimary: true)]
        )])
        let object = try JSONSerialization.jsonObject(
            with: ConfigStore.makeEncoder().encode(config)
        ) as? [String: Any]
        let sets = object?["sets"] as? [[String: Any]]
        #expect(sets?[0].keys.contains("machines") == false)
        let destinations = sets?[0]["destinations"] as? [[String: Any]]
        #expect(destinations?[0].keys.contains("machines") == false)
    }

    /// A sparse override is written sparsely: `{"enabled": false}` does not
    /// become `{"enabled": false, "sources": null, "schedule": null}`.
    @Test func overrideFieldsThatAreNilAreOmitted() throws {
        var config = AppConfig(sets: [BackupSet(
            id: UUID(),
            name: "Plain",
            sources: ["/src"],
            schedule: .daily(hour: 1, minute: 0),
            destinations: [Destination(id: UUID(), label: "Primary", repoURL: "/repo", isPrimary: true)]
        )])
        config.sets[0].machines = ["old-laptop": BackupSetMachineOverride(enabled: false)]

        let object = try JSONSerialization.jsonObject(
            with: ConfigStore.makeEncoder().encode(config)
        ) as? [String: Any]
        let sets = object?["sets"] as? [[String: Any]]
        let machines = sets?[0]["machines"] as? [String: [String: Any]]
        #expect(machines?["old-laptop"]?.keys.sorted() == ["enabled"])
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

    @Test("maintenance bindings resolve a local repository symlink")
    func maintenanceBindingUsesResolvedLocalRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-destination-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.restic", isDirectory: true)
        let second = root.appendingPathComponent("second.restic", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("current.restic", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)

        let destination = Destination(id: UUID(), label: "Primary", repoURL: link.path, isPrimary: true)
        let firstFingerprint = destination.pruneConfirmationFingerprint(secretEnv: [:])
        #expect(destination.pruneInvocationDestination().repoURL == first.path)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)

        #expect(destination.pruneInvocationDestination().repoURL == second.path)
        #expect(firstFingerprint != destination.pruneConfirmationFingerprint(secretEnv: [:]))
    }

    @Test("maintenance binding includes the previewed executable identity")
    func maintenanceBindingUsesExecutableIdentity() {
        let destination = Destination(id: UUID(), label: "Primary", repoURL: "/tmp/repo", isPrimary: true)
        #expect(destination.pruneConfirmationFingerprint(secretEnv: [:], executableIdentity: "restic-a")
            != destination.pruneConfirmationFingerprint(secretEnv: [:], executableIdentity: "restic-b"))
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

// MARK: - onboardingCompleted (T18)

/// `AppConfig.onboardingCompleted` was added after v1 configs were already on
/// disk, so the field carries a decode/encode compatibility contract:
/// a config written by an older build (no such key) must still decode, and a
/// config that has never run the setup assistant must still *encode* without
/// the key — otherwise the first save after upgrading would rewrite every
/// user's `config.json` and diverge from the documented example.
@Suite struct AppConfigOnboardingCompletedCompatibilityTests {
    @Test func decodesLegacyConfigWithoutTheKey() throws {
        // The documented example — no `onboardingCompleted` anywhere.
        let config = try ConfigStore.makeDecoder().decode(
            AppConfig.self,
            from: Data(dataModelExampleConfigJSON.utf8)
        )
        #expect(config.onboardingCompleted == nil)
        try config.validate()
    }

    @Test func decodesExplicitNullAsNil() throws {
        let json = #"{"version":1,"resticPath":null,"showMenuBarIcon":true,"onboardingCompleted":null,"sets":[]}"#
        let config = try ConfigStore.makeDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.onboardingCompleted == nil)
    }

    @Test(arguments: [true, false])
    func decodesBothBooleanValues(flag: Bool) throws {
        let json = #"{"version":1,"resticPath":null,"showMenuBarIcon":true,"onboardingCompleted":\#(flag),"sets":[]}"#
        let config = try ConfigStore.makeDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.onboardingCompleted == flag)
    }

    @Test func nilOmitsTheKeyWhileSetValuesRoundTrip() throws {
        let encoder = ConfigStore.makeEncoder()
        let decoder = ConfigStore.makeDecoder()

        let never = AppConfig()
        #expect(never.onboardingCompleted == nil)
        let neverJSON = try JSONSerialization.jsonObject(with: encoder.encode(never)) as? [String: Any]
        #expect(neverJSON?.keys.contains("onboardingCompleted") == false)

        for flag in [true, false] {
            var config = AppConfig()
            config.onboardingCompleted = flag
            let data = try encoder.encode(config)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(object?["onboardingCompleted"] as? Bool == flag)
            #expect(try decoder.decode(AppConfig.self, from: data) == config)
        }
    }

    /// Round-trips through the real `ConfigStore` (temp dir), which is the
    /// path the Settings/onboarding UI actually takes.
    @Test func survivesASaveLoadCycle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restic-station-onboarding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ConfigStore(paths: AppPaths(root: root))
        var config = AppConfig()
        config.onboardingCompleted = true
        try store.save(config)
        #expect(try store.load().onboardingCompleted == true)
    }
}

// MARK: - purgeExcludes (schema v3)

/// A minimal, hand-authored `BackupSet` JSON body, with `purgeExcludesField`
/// spliced in right after `"excludes":[]` — everything `BackupSet.init(from:)`
/// requires, and nothing else, so each case below can vary just the one
/// field under test.
private func backupSetJSON(purgeExcludesField: String) -> String {
    """
    {"id":"11111111-1111-4111-8111-111111111111","name":"x","sources":["/src"],\
    "excludes":[]\(purgeExcludesField),\
    "schedule":{"kind":"daily","hour":1,"minute":1},"retention":null,"checkPolicy":null,\
    "stalenessWarningDays":14,"destinations":[]}
    """
}

/// `BackupSet.purgeExcludes` was added at schema v3, so — like
/// `onboardingCompleted` at v1→v2 — it carries a decode/encode compatibility
/// contract. It diverges from that precedent in exactly one place: unlike
/// `onboardingCompleted`, which uses `encodeIfPresent` to stay invisible on
/// every pre-existing config, `purgeExcludes` is a non-optional `[String]`
/// and `BackupSet.encode(to:)` writes it unconditionally — an empty array
/// still encodes as `"purgeExcludes": []`, never an absent key. That
/// asymmetry is deliberate (see `Models.swift`'s `AppConfig.currentVersion`
/// doc comment) and is exactly what the third test below pins down.
@Suite struct BackupSetPurgeExcludesCompatibilityTests {
    @Test func decodesLegacySetWithoutTheKey() throws {
        let json = backupSetJSON(purgeExcludesField: "")
        let set = try ConfigStore.makeDecoder().decode(BackupSet.self, from: Data(json.utf8))
        #expect(set.purgeExcludes == [])
    }

    @Test func decodesExplicitNullAsEmptyArray() throws {
        let json = backupSetJSON(purgeExcludesField: #","purgeExcludes":null"#)
        let set = try ConfigStore.makeDecoder().decode(BackupSet.self, from: Data(json.utf8))
        #expect(set.purgeExcludes == [])
    }

    @Test func decodedValuesRoundTrip() throws {
        let json = backupSetJSON(purgeExcludesField: #","purgeExcludes":["secrets/","*.key"]"#)
        let set = try ConfigStore.makeDecoder().decode(BackupSet.self, from: Data(json.utf8))
        #expect(set.purgeExcludes == ["secrets/", "*.key"])

        let encoder = ConfigStore.makeEncoder()
        let decoder = ConfigStore.makeDecoder()
        let reencoded = try decoder.decode(BackupSet.self, from: encoder.encode(set))
        #expect(reencoded == set)
    }

    /// The divergence from `onboardingCompleted`: the key is written even
    /// when the array is empty, not omitted.
    @Test func theKeyIsAlwaysPresentInEncodedOutputEvenWhenEmpty() throws {
        let set = BackupSet(
            id: UUID(),
            name: "Plain",
            sources: ["/src"],
            schedule: .daily(hour: 1, minute: 0),
            destinations: [Destination(id: UUID(), label: "Primary", repoURL: "/repo", isPrimary: true)]
        )
        #expect(set.purgeExcludes == [])

        let object = try JSONSerialization.jsonObject(with: ConfigStore.makeEncoder().encode(set)) as? [String: Any]
        #expect(object?.keys.contains("purgeExcludes") == true)
        #expect(object?["purgeExcludes"] as? [String] == [])
    }

    /// Round-trips through the real `ConfigStore` (temp dir), the same way
    /// `onboardingCompleted`'s equivalent test does.
    @Test func survivesASaveLoadCycle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restic-station-purge-excludes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ConfigStore(paths: AppPaths(root: root))
        let config = AppConfig(sets: [BackupSet(
            id: UUID(),
            name: "Documents",
            sources: ["/src"],
            purgeExcludes: ["cache/", "*.tmp"],
            schedule: .daily(hour: 1, minute: 0),
            destinations: [Destination(id: UUID(), label: "Primary", repoURL: "/repo", isPrimary: true)]
        )])
        try store.save(config)
        #expect(try store.load().sets[0].purgeExcludes == ["cache/", "*.tmp"])
    }
}

// MARK: - BackupSet.effectiveBackupExcludes

@Suite struct EffectiveBackupExcludesTests {
    private func set(excludes: [String], purgeExcludes: [String]) -> BackupSet {
        BackupSet(
            id: UUID(),
            name: "Documents",
            sources: ["/src"],
            excludes: excludes,
            purgeExcludes: purgeExcludes,
            schedule: .daily(hour: 1, minute: 0),
            destinations: [Destination(id: UUID(), label: "Primary", repoURL: "/repo", isPrimary: true)]
        )
    }

    @Test func excludesComeBeforePurgeExcludes() {
        let backupSet = set(excludes: ["a", "b"], purgeExcludes: ["c", "d"])
        #expect(backupSet.effectiveBackupExcludes == ["a", "b", "c", "d"])
    }

    @Test func aPatternInBothListsIsDedupedKeepingItsFirstOccurrence() {
        let backupSet = set(excludes: ["a", "shared"], purgeExcludes: ["shared", "b"])
        #expect(backupSet.effectiveBackupExcludes == ["a", "shared", "b"])
    }

    @Test func bothEmptyProducesAnEmptyList() {
        let backupSet = set(excludes: [], purgeExcludes: [])
        #expect(backupSet.effectiveBackupExcludes == [])
    }
}

// MARK: - validate() and purgeExcludes

@Suite struct PurgeExcludesValidationTests {
    private func set(excludes: [String] = [], purgeExcludes: [String] = []) -> BackupSet {
        BackupSet(
            id: UUID(),
            name: "Documents",
            sources: ["/src"],
            excludes: excludes,
            purgeExcludes: purgeExcludes,
            schedule: .daily(hour: 1, minute: 0),
            destinations: [Destination(id: UUID(), label: "Primary", repoURL: "/repo", isPrimary: true)]
        )
    }

    @Test func emptyStringPurgePatternThrowsWithTheOffendingSetAndIndex() {
        let backupSet = set(purgeExcludes: ["ok/", "", "also-ok/"])
        let config = AppConfig(sets: [backupSet])

        #expect(throws: ConfigError.emptyPurgeExcludePattern(setId: backupSet.id, index: 1)) {
            try config.validate()
        }
    }

    @Test func nonEmptyPurgePatternsValidate() throws {
        let config = AppConfig(sets: [set(purgeExcludes: ["cache/", "*.tmp"])])
        try config.validate()
    }

    /// `excludes` is deliberately left unvalidated: a blank row there is
    /// harmless noise, not a `restic rewrite --forget` argument.
    @Test func anEmptyStringEntryInPlainExcludesStillValidates() throws {
        let config = AppConfig(sets: [set(excludes: ["", "node_modules"])])
        try config.validate()
    }
}
