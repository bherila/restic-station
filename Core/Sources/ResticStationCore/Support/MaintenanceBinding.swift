import Foundation

/// What a destructive maintenance confirmation is bound to.
///
/// `config.json`'s bytes alone are not enough. The helper resolves an
/// **effective** set from `config.json` *and* `machine.json`, and machine
/// state decides machine identity, which per-machine overrides apply, which
/// destinations are enabled here, and which restic binary runs. A
/// confirmation that binds only the shared config can therefore be honoured
/// against a materially different effective set: replace `machine.json`
/// between preview and apply and the config hash still matches, while the
/// helper prunes a different destination list under a different identity.
///
/// This binds the whole effective picture, so any of those moving invalidates
/// the confirmation instead of silently redefining it.
public enum MaintenanceBinding {
    /// Deterministic: `.sortedKeys` plus the model's explicit-null encoding.
    /// Both processes must compute byte-identical input from the same state.
    private struct EffectiveSet: Encodable {
        let machineId: String
        let configFingerprint: String
        let machineFingerprint: String
        let resticExecutableIdentity: String?
        let set: BackupSet
    }

    public static func effectiveSetFingerprint(
        machineId: String,
        set: BackupSet,
        configFingerprint: String,
        machineFingerprint: String,
        resticExecutableIdentity: String?
    ) -> String {
        let effective = EffectiveSet(
            machineId: machineId,
            configFingerprint: configFingerprint,
            machineFingerprint: machineFingerprint,
            resticExecutableIdentity: resticExecutableIdentity,
            set: set
        )
        // Encoding in-memory values cannot fail in practice. If it ever did,
        // a fixed sentinel would compare equal on both sides and authorize
        // the operation it was supposed to refuse; a random value can never
        // match a stored one, so the failure mode is a refusal.
        guard let data = try? ConfigStore.makeEncoder().encode(effective) else {
            return "unbindable-" + UUID().uuidString
        }
        return SHA256Digest.hex(data)
    }
}
