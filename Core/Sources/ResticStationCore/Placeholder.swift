/// Placeholder type for the ResticStationCore package scaffold (T01).
///
/// Real logic (config model + store, keychain client, restic runner,
/// schedule math, run store, reachability, state store, etc.) lands in
/// later tasks. This file exists so the package has a buildable source
/// and the test target has something trivial to exercise on both macOS
/// and Linux CI.
public enum ResticStationCore {
    /// A stable placeholder value used by the scaffold test.
    public static let placeholderVersion = "0.1.0"
}
