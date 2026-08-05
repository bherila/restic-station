import Foundation
import ResticStationCore

/// `ResticDiscovery`, `ResticProbe` and `ResticDiscoveryResult` live in Core
/// (`Core/Sources/ResticStationCore/Restic/ResticDiscovery.swift`) since T25 —
/// the helper needs them too, and `App/` is never compiled on Linux.
///
/// What stays here is only the *UI vocabulary*: the translation from a probe
/// outcome into `ResticStatus`, the enum the Settings chip and the menu-bar
/// health derivation speak. Core has no business knowing about it, and the
/// mapping is the one part of the old file that was genuinely app-side.
extension ResticProbe {
    /// Maps a probe onto the status vocabulary the Settings chip and the
    /// menu-bar health derivation already speak (`AppModel.resticStatus`).
    var status: ResticStatus {
        switch outcome {
        case .ok(let version):
            return .ok(path: path, version: version)
        case .tooOld(let version):
            return .tooOld(path: path, version: version, minimum: ResticDiscovery.minimumVersion)
        case .unusable(let reason):
            return .unavailable(path: path, reason: reason)
        }
    }
}

extension ResticDiscoveryResult {
    /// The best thing we can say about this search, in the vocabulary of the
    /// Settings chip: a working binary, else the first too-old one we found
    /// (candidates are probed in preference order, so this is the binary the
    /// user is most likely to think of as "their" restic), else the first
    /// unusable candidate, else "nothing on this Mac".
    var status: ResticStatus {
        if let chosen {
            return chosen.status
        }
        if let firstTooOld {
            return firstTooOld.status
        }
        if let firstUnusable = rejected.first {
            return firstUnusable.status
        }
        return .notConfigured
    }
}
