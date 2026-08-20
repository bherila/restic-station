import Foundation
import Testing
@testable import ResticStationCore

@Suite("PreviewTokenStore")
struct PreviewTokenStoreTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(_ date: Date) { self.date = date }

        var now: @Sendable () -> Date {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                return date
            }
        }

        func advance(_ interval: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(interval)
            lock.unlock()
        }
    }

    @Test("SHA-256 config fingerprint primitive matches published vectors")
    func sha256Vectors() {
        #expect(SHA256Digest.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb924"
            + "27ae41e4649b934ca495991b7852b855")
        #expect(SHA256Digest.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223"
            + "b00361a396177a9cb410ff61f20015ad")
    }

    @Test("tokens are random, owner-only, scoped, expiring, and single-use")
    func lifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-preview-token-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let clock = Clock(Date(timeIntervalSince1970: 1_784_000_000))
        let store = PreviewTokenStore(paths: paths, now: clock.now)
        let setId = UUID()
        let destinationId = UUID()
        let config = AppConfig(resticPath: "/opt/homebrew/bin/restic", sets: [])

        let token = try store.issue(
            machineId: "example-machine",
            setId: setId,
            destinations: [PreviewTokenDestination(destinationId: destinationId, snapshotIDs: ["b", "a"])],
            config: config,
            patterns: ["DerivedData"]
        )

        #expect(token.value.count >= 43, "a URL-safe encoding of 256 random bits")
        #expect(token.destinations[0].snapshotIDs == ["a", "b"])
        #expect(token.expiresAt == clock.now().addingTimeInterval(PreviewTokenStore.defaultLifetime))
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.previewTokensFile.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        #expect(try store.token(token.value) == token)

        _ = try store.consume(token.value)
        #expect(throws: PreviewTokenError.alreadyUsed) { try store.token(token.value) }

        let maintenance = try store.issueMaintenancePrune(
            machineId: "example-machine",
            setId: setId,
            destinationId: destinationId,
            effectiveDestinationFingerprint: "secret-inclusive-preview"
        )
        #expect(maintenance.count >= 43)
        #expect(maintenance != "secret-inclusive-preview")
        try store.consumeMaintenancePrune(
            maintenance,
            machineId: "example-machine",
            setId: setId,
            destinationId: destinationId,
            effectiveDestinationFingerprint: "secret-inclusive-preview"
        )
        #expect(throws: PreviewTokenError.alreadyUsed) {
            try store.consumeMaintenancePrune(
                maintenance,
                machineId: "example-machine",
                setId: setId,
                destinationId: destinationId,
                effectiveDestinationFingerprint: "secret-inclusive-preview"
            )
        }

        let changed = try store.issueMaintenancePrune(
            machineId: "example-machine",
            setId: setId,
            destinationId: destinationId,
            effectiveDestinationFingerprint: "preview-secret-environment"
        )
        #expect(throws: PreviewTokenError.unknown) {
            try store.consumeMaintenancePrune(
                changed,
                machineId: "example-machine",
                setId: setId,
                destinationId: destinationId,
                effectiveDestinationFingerprint: "changed-secret-environment"
            )
        }

        let expiring = try store.issue(
            machineId: "example-machine",
            setId: setId,
            destinations: [PreviewTokenDestination(destinationId: destinationId, snapshotIDs: [])],
            config: config,
            patterns: ["DerivedData"],
            lifetime: 1
        )
        clock.advance(1)
        #expect(throws: PreviewTokenError.expired) { try store.token(expiring.value) }
    }
}
