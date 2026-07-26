import Testing
import Foundation
@testable import ResticStationCore

@Suite("Stats fixture decoding")
struct StatsTests {
    @Test("stats-raw.json: raw-data mode")
    func statsRaw() throws {
        let data = try FixtureLoader.data("stats-raw.json")
        let stats = try parseStats(data)
        #expect(stats.totalSize == 67719)
        #expect(stats.totalUncompressedSize == 69990)
        #expect(stats.totalBlobCount == 9)
        #expect(stats.snapshotsCount == 2)
        #expect(stats.totalFileCount == nil)
        #expect(stats.compressionRatio != nil)
    }

    @Test("stats-restore.json: restore-size mode")
    func statsRestore() throws {
        let data = try FixtureLoader.data("stats-restore.json")
        let stats = try parseStats(data)
        #expect(stats.totalSize == 131147)
        #expect(stats.totalFileCount == 10)
        #expect(stats.snapshotsCount == 2)
        #expect(stats.totalBlobCount == nil)
    }
}
