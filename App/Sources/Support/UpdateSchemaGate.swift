import Foundation

/// Decides whether an offered app update may go straight to Sparkle's update
/// window, or must first be confirmed because it changes the shared
/// `config.json` schema (`docs/release.md` §Updates).
///
/// A schema bump is a fleet event (`docs/data-model.md` §Versioning): the
/// first host to run the new release migrates `config.json`, and every other
/// host sharing it stops backing up until it reads the new schema too. An
/// update must never be able to do that without the user having been told.
///
/// Every appcast item states the schema it writes in
/// `<resticstation:configSchemaVersion>`. The value is read fail-closed: an
/// item without it, or with one that is not a positive integer, is treated
/// as an unknown schema change and asks, rather than reading as "unchanged".
enum UpdateSchemaGate {
    /// The appcast element, exactly as Sparkle keys it in
    /// `SUAppcastItem.propertiesDictionary` (prefix as written in the feed).
    static let appcastElement = "resticstation:configSchemaVersion"

    enum Decision: Equatable {
        /// Same schema as the running app: no fleet impact.
        case proceed
        /// The update migrates the shared config to `to`, or does not say.
        case confirm(SchemaChange)
        /// The update declares an *older* schema than this app writes. It
        /// could not read the config this app has already written — the
        /// exact failure that makes every backup set vanish from the UI.
        case refuse(declared: Int)
    }

    enum SchemaChange: Equatable {
        case upgrade(from: Int, to: Int)
        case undeclared
    }

    static func decision(declared rawValue: Any?, running: Int) -> Decision {
        guard let declared = parse(rawValue) else {
            return .confirm(.undeclared)
        }
        if declared == running {
            return .proceed
        }
        if declared < running {
            return .refuse(declared: declared)
        }
        return .confirm(.upgrade(from: running, to: declared))
    }

    /// A positive integer written as the element's text; anything else is
    /// `nil` (and therefore asks).
    static func parse(_ rawValue: Any?) -> Int? {
        guard let text = rawValue as? String,
              let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else {
            return nil
        }
        return value
    }

    // MARK: - Copy

    static func confirmationTitle(version: String, change: SchemaChange) -> String {
        switch change {
        case .upgrade:
            return "Restic Station \(version) changes the shared configuration"
        case .undeclared:
            return "Restic Station \(version) doesn't say whether it changes the configuration"
        }
    }

    static func confirmationMessage(change: SchemaChange) -> String {
        let fleet = "Every machine that shares this config.json, including Linux hosts, must be "
            + "upgraded at the same time, or backups stop on the ones left behind."
        switch change {
        case .upgrade(let from, let to):
            return "Installing it upgrades config.json from schema v\(from) to v\(to) the next time "
                + "Restic Station opens. \(fleet)"
        case .undeclared:
            return "This update's feed entry has no config schema version, so Restic Station can't "
                + "tell whether it will rewrite config.json. If it does: \(fleet)"
        }
    }

    static func refusalMessage(version: String, declared: Int, running: Int) -> String {
        "Restic Station \(version) uses config schema v\(declared), older than the v\(running) this "
            + "version already writes, so it couldn't read your backup sets. The update was not "
            + "offered. Report this — it is a release mistake."
    }
}
