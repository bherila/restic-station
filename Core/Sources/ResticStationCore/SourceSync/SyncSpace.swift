import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Whether there is room to synchronize (#197). A first sync of a large
/// folder needs several temporary copies, and running out of space halfway is
/// recoverable but slow and alarming, so preview estimates the need from the
/// plan and refuses, with the numbers, before anything is reserved.
///
/// An **estimate**, deliberately a little generous. It counts file bytes only
/// (restic's own cache and journals are small beside them), and counts each
/// volume separately, so two folders on one volume are not summed. A computer
/// that cannot report its free space (a helper older than #197, or a
/// filesystem that will not say) is not blocked: unknown is not "full".
enum SyncSpace {
    /// What each place needs, in bytes, before slack.
    struct Need: Equatable {
        /// The application-state volume of the coordinating computer, which
        /// holds the operation's vault and its verification restores.
        var coordinator: UInt64
        /// Beside each synchronized folder (private sibling storage on the
        /// same volume): what that copy exports, plus what it receives.
        var local: UInt64
        var peer: UInt64
    }

    /// What the plan will write, by place.
    ///
    /// The vault holds both copies' exports of every entry a change touches.
    /// With protection, the vault is restored once to verify it and again
    /// after the final backup, and both restores stay until cleanup, so
    /// three times the vault; without protection, two.
    static func need(for plan: SourceSyncPlan) -> Need {
        func bytes(_ items: [String: SyncItem], touched: Set<String>) -> UInt64 {
            touched.reduce(0) { $0 + (items[$1].map { $0.kind == .file ? $0.bytes : 0 } ?? 0) }
        }
        func touched(_ items: [String: SyncItem]) -> Set<String> {
            var result: Set<String> = []
            for change in plan.changes where items[change.path] != nil { result.insert(change.path) }
            return result
        }
        let exportLocal = bytes(plan.local.items, touched: touched(plan.local.items))
        let exportPeer = bytes(plan.peer.items, touched: touched(plan.peer.items))
        // Files that arrive on a copy: the other copy's version of every change that copies to it.
        var intoLocal: UInt64 = 0, intoPeer: UInt64 = 0
        for change in plan.changes {
            if change.action == .copyToLocal, let item = change.peer, item.kind == .file { intoLocal += item.bytes }
            if change.action == .copyToPeer, let item = change.local, item.kind == .file { intoPeer += item.bytes }
        }
        let vault = exportLocal + exportPeer
        return Need(coordinator: vault * (plan.requiresProtection ? 3 : 2), local: exportLocal + intoLocal, peer: exportPeer + intoPeer)
    }

    /// Slack on top of an estimate: ten percent and 64 MiB. Nothing is
    /// needed when nothing will be copied.
    static func required(_ bytes: UInt64) -> UInt64 {
        bytes == 0 ? 0 : bytes + bytes / 10 + 64 * 1024 * 1024
    }

    /// One line per place that is known to be short; empty when all is well
    /// or unknown. `local` and `peer` are free space beside each folder as
    /// that endpoint reported it.
    static func shortfalls(_ need: Need, coordinator: UInt64?, local: UInt64?, peer: UInt64?, peerIsRemote: Bool) -> [String] {
        var lines: [String] = []
        func check(_ place: String, _ needed: UInt64, _ free: UInt64?) {
            let want = required(needed)
            guard let free, want > free else { return }
            lines.append("\(place): about \(format(want)) needed, \(format(free)) free")
        }
        check("this computer's Restic Station data", need.coordinator, coordinator)
        check("beside this computer's folder", need.local, local)
        check(peerIsRemote ? "beside the other computer's folder" : "beside the other folder", need.peer, peer)
        return lines
    }

    static func refusal(_ lines: [String]) -> SourceSyncError {
        .stateInvalid("There is not enough free space to synchronize these folders safely. Temporary copies are needed: \(lines.joined(separator: "; ")). Free up space, or synchronize less at once, then preview again.")
    }

    /// Binary units, one decimal, never zero for a nonzero number.
    static func format(_ bytes: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes), index = 0
        while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
        return index == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[index])
    }

    /// Replaced only by tests, which cannot fill a disk.
    @TaskLocal static var availableOverride: (@Sendable (String) -> UInt64?)?

    /// Free bytes an unprivileged writer can use on the volume holding
    /// `path`, or nil if it cannot be read.
    static func available(atPath path: String) -> UInt64? {
        if let override = availableOverride { return override(path) }
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return nil }
        return UInt64(info.f_bavail) * UInt64(info.f_frsize)
    }
}
