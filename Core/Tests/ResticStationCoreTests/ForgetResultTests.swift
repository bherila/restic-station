import Testing
import Foundation
@testable import ResticStationCore

@Suite("ForgetResult fixture decoding")
struct ForgetResultTests {
    @Test("forget.json: one group, one keep, one remove")
    func forgetJson() throws {
        let data = try FixtureLoader.data("forget.json")
        let groups = try parseForget(data)
        #expect(groups.count == 1)

        let group = groups[0]
        #expect(group.host == "example-mac.local")
        #expect(group.paths == ["/Users/user/example/src"])
        #expect(group.keep?.count == 1)
        #expect(group.keep?.first?.shortId == "f391ba97")
        #expect(group.remove?.count == 1)
        #expect(group.remove?.first?.shortId == "e9ffc5cb")
        #expect(group.reasons?.count == 1)
        #expect(group.reasons?.first?.matches == ["last snapshot"])
        #expect(group.reasons?.first?.snapshot.shortId == "f391ba97")
    }

    @Test("null remove is tolerated")
    func nullRemove() throws {
        let json = """
        [{"tags":null,"host":"h","paths":["/x"],"keep":[],"remove":null,"reasons":[]}]
        """
        let groups = try makeResticJSONDecoder().decode([ForgetResult].self, from: Data(json.utf8))
        #expect(groups.count == 1)
        #expect(groups[0].remove == nil)
        #expect(groups[0].keep?.isEmpty == true)
    }
}
