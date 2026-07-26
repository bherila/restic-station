import Testing
import Foundation
@testable import ResticStationCore

@Suite("cat-config / init probe fixture decoding")
struct ProbesTests {
    @Test("cat-config.json")
    func catConfig() throws {
        let data = try FixtureLoader.data("cat-config.json")
        let config = try parseRepositoryConfig(data)
        #expect(config.version == 2)
        #expect(config.id == "4c743a243c4453e70133dd27e57e91b7be1ae619a96f2aaa232a88755879ca24")
        #expect(config.chunkerPolynomial == "3ec7451ee4546b")
    }

    @Test("init.json")
    func initJson() throws {
        let data = try FixtureLoader.data("init.json")
        let result = try parseInitialized(data)
        #expect(result.id == "4c743a243c4453e70133dd27e57e91b7be1ae619a96f2aaa232a88755879ca24")
        #expect(result.repository == "primary")
    }

    @Test("init-secondary.json")
    func initSecondaryJson() throws {
        let data = try FixtureLoader.data("init-secondary.json")
        let result = try parseInitialized(data)
        #expect(result.id == "d23650e8771ce90a33e772dc40adc0c36d43f6ee1129913a06dc3ff36e177a06")
        #expect(result.repository == "secondary")
    }
}
