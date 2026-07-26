import Foundation

/// `restic version --json` (fixture `version.json`).
public struct VersionInfo: Decodable, Equatable, Sendable {
    public let version: String
    public let goVersion: String?
    public let goOS: String?
    public let goArch: String?

    private enum CodingKeys: String, CodingKey {
        case version
        case goVersion = "go_version"
        case goOS = "go_os"
        case goArch = "go_arch"
    }

    /// True when `version` is numerically >= `minVersion`, comparing
    /// dotted numeric triples component-by-component (missing trailing
    /// components treated as `0`; non-numeric suffixes ignored). E.g.
    /// `"0.18.1".meetsMinimum("0.17.0") == true`.
    public func meetsMinimum(_ minVersion: String) -> Bool {
        VersionInfo.compareVersions(version, minVersion) >= 0
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let l = VersionInfo.numericTriple(lhs)
        let r = VersionInfo.numericTriple(rhs)
        for i in 0..<max(l.count, r.count) {
            let lv = i < l.count ? l[i] : 0
            let rv = i < r.count ? r[i] : 0
            if lv != rv { return lv < rv ? -1 : 1 }
        }
        return 0
    }

    static func numericTriple(_ version: String) -> [Int] {
        version.split(separator: ".").map { component in
            Int(component.prefix(while: { $0.isNumber })) ?? 0
        }
    }
}

/// Parses the single JSON object returned by `restic version --json`
/// (fixture `version.json`).
public func parseVersion(_ data: Data) throws -> VersionInfo {
    try makeResticJSONDecoder().decode(VersionInfo.self, from: data)
}
