import Foundation
import Testing
@testable import ResticStationCore

// T24: `machine.json` — the host-local identity a shared `config.json` is
// resolved against. Nothing here mutates the process environment: the
// `RESTIC_STATION_MACHINE_ID` override is injected through `MachineStore`'s
// internal initializer, so these tests are hermetic and can run in parallel
// with everything else.

private func makeTempPaths() -> (AppPaths, () -> Void) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("restic-station-machine-\(UUID().uuidString)", isDirectory: true)
    return (AppPaths(root: root), { try? FileManager.default.removeItem(at: root) })
}

// MARK: - Slug rules

@Suite struct MachineIdentitySlugTests {

    @Test(arguments: [
        ("studio-mac", "studio-mac"),
        ("Studio-Mac", "studio-mac"),
        // The hostname's dots are separators like any other disallowed
        // character — deliberately not special-cased into a domain strip.
        ("studio-mac.local", "studio-mac-local"),
        ("Bens-MacBook-Pro.local", "bens-macbook-pro-local"),
        ("nas01", "nas01"),
        // Runs collapse, leading/trailing separators are trimmed.
        ("  weird__host!!name  ", "weird-host-name"),
        ("---leading", "leading"),
        ("trailing---", "trailing"),
        ("a...b", "a-b"),
        ("ünïcødé-hôst", "n-c-d-h-st"),
    ])
    func slugifyMatchesTheDocumentedRules(input: String, expected: String) {
        #expect(MachineIdentity.slugify(input) == expected)
        #expect(MachineIdentity.isValid(expected))
    }

    @Test(arguments: ["", "   ", "...", "!!!", "-", "--"])
    func slugifyReturnsNilWhenNothingUsableSurvives(input: String) {
        #expect(MachineIdentity.slugify(input) == nil)
    }

    @Test(arguments: ["studio-mac", "nas01", "a", "0", "a-b-c"])
    func validIdsAreAccepted(machineId: String) {
        #expect(MachineIdentity.isValid(machineId))
    }

    @Test(arguments: ["", "Studio-Mac", "studio_mac", "studio mac", "studio.mac", "café", "*", "mac/1"])
    func invalidIdsAreRejected(machineId: String) {
        #expect(!MachineIdentity.isValid(machineId))
    }

    @Test func generateSlugifiesTheHostName() {
        #expect(MachineIdentity.generate(hostName: "Studio-Mac.local") == "studio-mac-local")
    }

    /// An unusable hostname falls back to a UUID — which must itself be a
    /// valid slug, or the id it generates would fail the validation the
    /// `machines` keys are held to.
    @Test(arguments: ["", "!!!", "   "])
    func generateFallsBackToAValidUUIDSlug(hostName: String) {
        let generated = MachineIdentity.generate(hostName: hostName)
        #expect(MachineIdentity.isValid(generated))
        #expect(UUID(uuidString: generated) != nil)
    }
}

// MARK: - Store

@Suite struct MachineStoreTests {

    @Test func loadAutoCreatesTheFileWithASlugifiedHostName() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        let store = MachineStore(paths: paths, environment: [:])
        let machine = try store.load()

        #expect(machine.version == MachineConfig.currentVersion)
        #expect(MachineIdentity.isValid(machine.machineId))
        #expect(machine.resticPath == nil)
        #expect(FileManager.default.fileExists(atPath: paths.machineFile.path))

        // Stable across loads: the id is persisted, not regenerated.
        #expect(try store.load() == machine)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        let store = MachineStore(paths: paths, environment: [:])
        let machine = MachineConfig(machineId: "studio-mac", resticPath: "/opt/homebrew/bin/restic")
        try store.save(machine)
        #expect(try store.load() == machine)
    }

    @Test func savedFileMatchesTheDocumentedShape() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        try MachineStore(paths: paths, environment: [:])
            .save(MachineConfig(machineId: "studio-mac", resticPath: "/usr/bin/restic"))

        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: paths.machineFile)
        ) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(
            with: Data(#"{ "version": 1, "machineId": "studio-mac", "resticPath": "/usr/bin/restic" }"#.utf8)
        ) as? NSDictionary
        #expect(object == expected)

        // Explicit `null`, per the house convention — not an omitted key.
        try MachineStore(paths: paths, environment: [:]).save(MachineConfig(machineId: "studio-mac"))
        let withoutPath = try JSONSerialization.jsonObject(
            with: Data(contentsOf: paths.machineFile)
        ) as? [String: Any]
        #expect(withoutPath?.keys.contains("resticPath") == true)
        #expect(withoutPath?["resticPath"] is NSNull)
    }

    @Test func saveIsAtomicAndLeavesNoTempFile() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        let store = MachineStore(paths: paths, environment: [:])
        try store.save(MachineConfig(machineId: "studio-mac"))

        #expect(!FileManager.default.fileExists(atPath: store.tempMachineFile.path))
        #expect(FileManager.default.fileExists(atPath: paths.machineFile.path))
    }

    // MARK: Environment override

    @Test func environmentOverrideReplacesTheMachineIdWithoutRewritingTheFile() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        try MachineStore(paths: paths, environment: [:])
            .save(MachineConfig(machineId: "studio-mac", resticPath: "/usr/bin/restic"))

        let overridden = try MachineStore(
            paths: paths,
            environment: [MachineIdentity.environmentOverrideKey: "second-profile"]
        ).load()

        #expect(overridden.machineId == "second-profile")
        // Other fields still come from the file…
        #expect(overridden.resticPath == "/usr/bin/restic")
        // …and the host's own identity on disk is untouched.
        #expect(try MachineStore(paths: paths, environment: [:]).load().machineId == "studio-mac")
    }

    @Test func emptyEnvironmentOverrideIsIgnored() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        try MachineStore(paths: paths, environment: [:]).save(MachineConfig(machineId: "studio-mac"))
        let loaded = try MachineStore(
            paths: paths,
            environment: [MachineIdentity.environmentOverrideKey: ""]
        ).load()
        #expect(loaded.machineId == "studio-mac")
    }

    @Test func invalidEnvironmentOverrideThrowsRatherThanResolvingToNoOverrides() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        try MachineStore(paths: paths, environment: [:]).save(MachineConfig(machineId: "studio-mac"))
        let store = MachineStore(
            paths: paths,
            environment: [MachineIdentity.environmentOverrideKey: "Second Profile"]
        )
        #expect(throws: MachineError.invalidMachineId("Second Profile")) {
            _ = try store.load()
        }
    }

    // MARK: Rejections

    /// A `machineId` that no `machines` key can ever match would silently
    /// resolve to "no overrides" — i.e. quietly back up the wrong
    /// directories. It has to be loud.
    @Test(arguments: ["", "Studio-Mac", "studio_mac"])
    func invalidMachineIdOnDiskThrows(machineId: String) throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        try paths.ensureDirectories()
        let json = #"{"version":1,"machineId":"\#(machineId)","resticPath":null}"#
        try Data(json.utf8).write(to: paths.machineFile)

        #expect(throws: MachineError.invalidMachineId(machineId)) {
            _ = try MachineStore(paths: paths, environment: [:]).load()
        }
    }

    @Test func saveRejectsAnInvalidMachineIdAndWritesNothing() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        #expect(throws: MachineError.invalidMachineId("Studio Mac")) {
            try MachineStore(paths: paths, environment: [:]).save(MachineConfig(machineId: "Studio Mac"))
        }
        #expect(!FileManager.default.fileExists(atPath: paths.machineFile.path))
    }

    // MARK: savePreservingIdentity — the override must never round-trip

    /// The blocker Fable caught: every write path that is *not* creating or
    /// renaming an identity has to keep the on-disk `machineId`.
    ///
    /// The app's restic discovery reaches `AppModel.updateMachine` on its own
    /// — a `.task` on the Settings pane, no user action — and it holds a
    /// `MachineConfig` whose id came from `RESTIC_STATION_MACHINE_ID`. A
    /// plain `save` there bakes the temporary profile name into the file, and
    /// the damage outlives the variable: once unset, the host keeps resolving
    /// that profile's `machines` overrides and can silently back up the wrong
    /// sources, unattended, from launchd.
    ///
    /// This is the whole `updateMachine` sequence, at `MachineStore` level.
    @Test func savePreservingIdentityKeepsTheOnDiskMachineId() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        try MachineStore(paths: paths, environment: [:])
            .save(MachineConfig(machineId: "studio-mac"))

        // Exactly what the app holds while the override is in effect.
        let overrideAware = MachineStore(
            paths: paths,
            environment: [MachineIdentity.environmentOverrideKey: "second-profile"]
        )
        var draft = try overrideAware.load()
        #expect(draft.machineId == "second-profile") // precondition
        draft.resticPath = "/usr/bin/restic"

        let written = try overrideAware.savePreservingIdentity(draft)

        // The host's identity is untouched…
        #expect(written.machineId == "studio-mac")
        #expect(try MachineStore.persistentIdentity(paths: paths).load().machineId == "studio-mac")
        // …and the change the caller actually wanted did land.
        #expect(try MachineStore.persistentIdentity(paths: paths).load().resticPath == "/usr/bin/restic")
        // The override still applies in memory, which is what it is for.
        #expect(try overrideAware.load().machineId == "second-profile")
        #expect(try overrideAware.load().resticPath == "/usr/bin/restic")
    }

    /// Not just the environment override: **any** `machineId` in the value
    /// handed to `savePreservingIdentity` is ignored. The guarantee is a
    /// property of the method, not of how the caller obtained its value.
    @Test func savePreservingIdentityIgnoresAnyMachineIdInTheValue() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        let store = MachineStore(paths: paths, environment: [:])
        try store.save(MachineConfig(machineId: "studio-mac"))

        try store.savePreservingIdentity(
            MachineConfig(machineId: "something-else-entirely", resticPath: "/opt/restic")
        )

        let onDisk = try store.load()
        #expect(onDisk.machineId == "studio-mac")
        #expect(onDisk.resticPath == "/opt/restic")
    }

    /// Every non-identity field is carried through, so a field added to
    /// `MachineConfig` later cannot be silently dropped by this path.
    @Test func savePreservingIdentityCarriesEveryOtherField() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        let store = MachineStore(paths: paths, environment: [:])
        try store.save(MachineConfig(machineId: "studio-mac", resticPath: "/old/restic"))

        let desired = MachineConfig(machineId: "ignored", resticPath: "/new/restic")
        let written = try store.savePreservingIdentity(desired)

        var expected = desired
        expected.machineId = "studio-mac"
        #expect(written == expected)
        #expect(try store.load() == expected)
    }

    /// With no `machine.json` yet, the identity to preserve is the generated
    /// one the load creates — never the override.
    @Test func savePreservingIdentityCreatesTheGeneratedIdentityWhenAbsent() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        let overrideAware = MachineStore(
            paths: paths,
            environment: [MachineIdentity.environmentOverrideKey: "second-profile"]
        )
        let written = try overrideAware.savePreservingIdentity(
            MachineConfig(machineId: "second-profile", resticPath: "/usr/bin/restic")
        )

        #expect(written.machineId != "second-profile")
        #expect(MachineIdentity.isValid(written.machineId))
        #expect(try MachineStore.persistentIdentity(paths: paths).load().machineId == written.machineId)
    }

    /// `save(_:)` remains the identity-setting primitive — creating and
    /// deliberately renaming both still work, which is why the two methods
    /// exist rather than one.
    @Test func plainSaveStillWritesTheIdentityVerbatim() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        let store = MachineStore(paths: paths, environment: [:])
        try store.save(MachineConfig(machineId: "studio-mac"))
        try store.save(MachineConfig(machineId: "renamed-mac"))
        #expect(try store.load().machineId == "renamed-mac")
    }

    @Test func newerVersionThrows() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        try paths.ensureDirectories()
        try Data(#"{"version":99,"machineId":"studio-mac","resticPath":null}"#.utf8)
            .write(to: paths.machineFile)

        #expect(throws: MachineError.newerVersion(found: 99, supported: MachineConfig.currentVersion)) {
            _ = try MachineStore(paths: paths, environment: [:]).load()
        }
    }

    @Test func corruptFileThrowsRatherThanSilentlyRegenerating() throws {
        let (paths, cleanup) = makeTempPaths()
        defer { cleanup() }

        try paths.ensureDirectories()
        try Data("not json {{{".utf8).write(to: paths.machineFile)

        #expect(throws: (any Error).self) {
            _ = try MachineStore(paths: paths, environment: [:]).load()
        }
    }
}
