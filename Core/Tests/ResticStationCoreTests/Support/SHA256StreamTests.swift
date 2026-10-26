import Foundation
import Testing
@testable import ResticStationCore

@Test("streaming fingerprints match whole-buffer hashes across padding and read boundaries")
func streamingHashBoundaries() throws {
    for length in [0, 1, 55, 56, 63, 64, 65, 127, 128, 4097, 1048583] {
        let bytes = Data((0..<length).map { UInt8($0 % 251) })
        var stream = SHA256Digest.PortableStream()
        for start in stride(from: 0, to: bytes.count, by: 137) {
            stream.update(bytes.subdata(in: start..<min(start + 137, bytes.count)))
        }
        #expect(stream.finish() == SHA256Digest.digest(bytes))
    }
}
