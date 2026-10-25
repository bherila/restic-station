import Foundation

public enum SourceSyncBinding {
    /// The effective set, machine settings, shared revision and executable
    /// form one confirmation context. Missing machine bytes are an error at
    /// the caller, never the same fingerprint as an unreadable file.
    public static func make(configFingerprint: String, machineBytes: Data, set: BackupSet, machineId: String, executableIdentity: String) throws -> String {
        SHA256Digest.hex(try ConfigStore.makeEncoder().encode([
            "source-sync:v1", configFingerprint, SHA256Digest.hex(machineBytes),
            SHA256Digest.hex(try ConfigStore.makeEncoder().encode(set)), machineId, executableIdentity,
        ]))
    }
}
