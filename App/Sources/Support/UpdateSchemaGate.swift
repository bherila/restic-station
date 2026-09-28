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
///
/// The element is only evidence if the feed it came from is signed. Sparkle's
/// EdDSA archive signature covers the zip, not the appcast, so an unsigned
/// feed could pair any genuine archive — including an old release that cannot
/// read today's config — with any schema claim. The feed is therefore signed
/// as a whole (`SURequireSignedFeed`), which binds the schema claim to the
/// archive's signature in the same signed document, and an item from a feed
/// whose signature did not verify is refused outright.
enum UpdateSchemaGate {
    /// The appcast element, exactly as Sparkle keys it in
    /// `SUAppcastItem.propertiesDictionary` (prefix as written in the feed).
    static let appcastElement = "resticstation:configSchemaVersion"

    enum Decision: Equatable {
        /// Same schema as the running app: no fleet impact.
        case proceed
        /// The update migrates the shared config to `to`, or does not say.
        case confirm(SchemaChange)
        /// Never offered; see `Refusal`.
        case refuse(Refusal)
    }

    enum Refusal: Equatable {
        /// The update declares an *older* schema than this app writes. It
        /// could not read the config this app has already written — the
        /// exact failure that makes every backup set vanish from the UI.
        case olderSchema(declared: Int)
        /// The appcast's own signature did not verify (or was not checked),
        /// so nothing it says about the update can be trusted.
        case unverifiedFeed
    }

    enum SchemaChange: Equatable {
        case upgrade(from: Int, to: Int)
        case undeclared
    }

    /// `feedVerified` is true only when Sparkle verified the appcast's
    /// signature against `SUPublicEDKey`
    /// (`SUAppcastItem.signingValidationStatus == .succeeded`).
    static func decision(declared rawValue: Any?, feedVerified: Bool, running: Int) -> Decision {
        guard feedVerified else {
            return .refuse(.unverifiedFeed)
        }
        guard let declared = parse(rawValue) else {
            return .confirm(.undeclared)
        }
        if declared == running {
            return .proceed
        }
        if declared < running {
            return .refuse(.olderSchema(declared: declared))
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

    static func refusalMessage(version: String, refusal: Refusal, running: Int) -> String {
        switch refusal {
        case .olderSchema(let declared):
            return "Restic Station \(version) uses config schema v\(declared), older than the v\(running) this "
                + "version already writes, so it couldn't read your backup sets. The update was not "
                + "offered. Report this — it is a release mistake."
        case .unverifiedFeed:
            return "The update feed offering Restic Station \(version) is not signed with this app's update "
                + "key, so the update was not offered. Report this — the feed may have been altered."
        }
    }
}
