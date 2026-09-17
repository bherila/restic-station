import Testing
@testable import ResticStationCore

@Suite("CloudStorageSafety")
struct CloudStorageSafetyTests {
    private let home = "/Users/test"

    @Test("recognizes iCloud Drive and File Provider roots without prefix false positives")
    func cloudRoots() {
        #expect(CloudStorageSafety.isCloudSyncedPath(
            "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Documents",
            homeDirectory: home
        ))
        #expect(CloudStorageSafety.isCloudSyncedPath(
            "/Users/test/Library/CloudStorage/OneDrive-Example/SharePoint",
            homeDirectory: home
        ))
        #expect(!CloudStorageSafety.isCloudSyncedPath(
            "/Users/test/Library/CloudStorage-old/archive",
            homeDirectory: home
        ))
        #expect(!CloudStorageSafety.isCloudSyncedPath(
            "/Users/test/Documents",
            homeDirectory: home
        ))
    }

    @Test("a mixed source list enables cloud placeholder exclusion")
    func mixedSources() {
        #expect(CloudStorageSafety.containsCloudBackedSource([
            "/Users/test/proj",
            "/Users/test/Library/CloudStorage/OneDrive/Documents",
        ], homeDirectory: home))
        #expect(!CloudStorageSafety.containsCloudBackedSource([
            "/Users/test/proj",
            "/Users/test/Documents",
        ], homeDirectory: home))
    }
}
