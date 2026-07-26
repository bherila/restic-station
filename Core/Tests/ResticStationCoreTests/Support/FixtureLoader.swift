import Foundation

/// Loads fixture files copied byte-identical from `docs/fixtures/` into
/// this test target's resource bundle (see `Package.swift`:
/// `.copy("Fixtures")`).
enum FixtureLoader {
    enum FixtureError: Error {
        case missing(String)
    }

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    /// Splits an NDJSON fixture into its non-empty lines.
    static func lines(_ name: String) throws -> [String] {
        try string(name)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
