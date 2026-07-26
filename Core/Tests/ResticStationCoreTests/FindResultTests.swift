import Testing
import Foundation
@testable import ResticStationCore

@Suite("FindResult fixture decoding")
struct FindResultTests {
    @Test("find.json: one hit per snapshot")
    func findJson() throws {
        let data = try FixtureLoader.data("find.json")
        let results = try parseFind(data)
        #expect(results.count == 2)

        let first = results[0]
        #expect(first.hits == 1)
        #expect(first.snapshot == "f391ba97c0968db507509e12d467de87753929ae749cbc2b1cfd81743eb19f52")
        #expect(first.matches.count == 1)
        #expect(first.matches[0].path == "/src/subdir/file2.txt")
        #expect(first.matches[0].type == .file)
        #expect(first.matches[0].size == 23)

        let second = results[1]
        #expect(second.snapshot == "e9ffc5cb64395ad443fd14f432751a9823181224978d6b25bf2af1a99ad367fd")
        #expect(second.hits == 1)
    }
}
