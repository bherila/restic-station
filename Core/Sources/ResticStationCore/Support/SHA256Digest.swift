import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-256 for fingerprints that must be identical on macOS and the
/// `swift:6.1` Linux container. The token store needs a collision-resistant
/// binding, but Core deliberately has no swift-crypto package dependency —
/// hence the portable implementation below.
///
/// On Darwin it defers to CryptoKit, which is a system framework (no new
/// dependency) and hardware-accelerated. That matters because these digests
/// cover whole files: hashing the 28 MB restic binary for a maintenance
/// binding costs ~0.2s through the Swift implementation in a release build
/// and **~10s in a debug build**, which made one engine test take 40s. Both
/// paths are pinned to the same published vectors by `sha256Vectors`.
enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(CryptoKit.SHA256.hash(data: data))
        #else
        return portableDigest(data)
        #endif
    }

    /// Exposed unconditionally so the vectors exercise it on every platform,
    /// not only the one that lacks CryptoKit.
    static func portableDigest(_ data: Data) -> [UInt8] {
        var stream = PortableStream()
        stream.update(data)
        return stream.finish()
    }

    /// Hashes an already-open, no-follow file without loading an archive
    /// into memory. The caller owns the descriptor and verifies its inode
    /// and modification stamps before/after the read.
    static func fileHex(descriptor: Int32) throws -> String {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        #if canImport(CryptoKit)
        var stream = CryptoKit.SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { stream.update(data: data) }
        return stream.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        var stream = PortableStream()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { stream.update(data) }
        return stream.finish().map { String(format: "%02x", $0) }.joined()
        #endif
    }

    struct PortableStream {
        private var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        private var pending: [UInt8] = []
        private var bytes: UInt64 = 0

        mutating func update(_ data: Data) {
            bytes &+= UInt64(data.count)
            pending.append(contentsOf: data)
            let consumed = pending.count / 64 * 64
            for offset in stride(from: 0, to: consumed, by: 64) {
                SHA256Digest.compress(pending, offset: offset, state: &state)
            }
            pending.removeFirst(consumed)
        }

        mutating func finish() -> [UInt8] {
            let bitLength = bytes &* 8
            pending.append(0x80)
            while pending.count % 64 != 56 { pending.append(0) }
            pending.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))
            for offset in stride(from: 0, to: pending.count, by: 64) {
                SHA256Digest.compress(pending, offset: offset, state: &state)
            }
            return state.flatMap { withUnsafeBytes(of: $0.bigEndian, Array.init) }
        }
    }

    private static func compress(_ message: [UInt8], offset: Int, state: inout [UInt32]) {
            var words = Array(repeating: UInt32(0), count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = (UInt32(message[start]) << 24)
                    | (UInt32(message[start + 1]) << 16)
                    | (UInt32(message[start + 2]) << 8)
                    | UInt32(message[start + 3])
            }
            for index in 16..<64 {
                let small0 = rotateRight(words[index - 15], by: 7)
                    ^ rotateRight(words[index - 15], by: 18) ^ (words[index - 15] >> 3)
                let small1 = rotateRight(words[index - 2], by: 17)
                    ^ rotateRight(words[index - 2], by: 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ small0 &+ words[index - 7] &+ small1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let upper1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choose = (e & f) ^ ((~e) & g)
                let temp1 = h &+ upper1 &+ choose &+ constants[index] &+ words[index]
                let upper0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = upper0 &+ majority
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}
