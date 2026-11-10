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
/// (restic's own cache and journals are small beside them). Places on one
/// volume are summed, since they draw on the same free space. A computer that
/// cannot report its free space (a helper older than #197, or a filesystem
/// that will not say) is not blocked: unknown is not "full".
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

    /// What a volume says about itself: free bytes an unprivileged writer can
    /// use, and an identifier for the volume, so places that share one are
    /// counted together. Either may be unknown.
    struct Reading: Equatable, Sendable {
        var free: UInt64?
        var volume: UInt64?
        init(free: UInt64? = nil, volume: UInt64? = nil) { self.free = free; self.volume = volume }
    }

    /// What the plan will write, by place. Changes that are conflicts are not
    /// counted: a plan with a conflict is never applied.
    ///
    /// The vault holds both copies' exports of every entry a change touches.
    /// With protection, the vault is restored once to verify it and again
    /// after the final backup, and both restores stay until cleanup, so
    /// three times the vault; without protection, two.
    static func need(for plan: SourceSyncPlan) -> Need {
        let changes = plan.changes.filter { $0.action != .conflict }
        func exported(_ items: [String: SyncItem]) -> UInt64 {
            var seen = Set<String>(), total: UInt64 = 0
            for change in changes where seen.insert(change.path).inserted {
                if let item = items[change.path], item.kind == .file { total += item.bytes }
            }
            return total
        }
        let exportLocal = exported(plan.local.items), exportPeer = exported(plan.peer.items)
        // Files that arrive on a copy: the other copy's version of every change that copies to it.
        var intoLocal: UInt64 = 0, intoPeer: UInt64 = 0
        for change in changes {
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

    /// One line per volume that is known to be short; empty when all is well
    /// or unknown. Places that report the same volume are summed. The other
    /// computer's folder is never grouped with this computer's, since volume
    /// identifiers mean nothing across computers.
    static func shortfalls(_ need: Need, coordinator: Reading, local: Reading, peer: Reading, peerIsRemote: Bool) -> [String] {
        // Places on one volume, in first-seen order.
        var byVolume: [(volume: UInt64?, names: [String], needed: UInt64, free: UInt64?)] = []
        func record(_ name: String, _ needed: UInt64, _ reading: Reading, groupable: Bool) {
            if groupable, let volume = reading.volume, let index = byVolume.firstIndex(where: { $0.volume == volume }) {
                byVolume[index].names.append(name)
                byVolume[index].needed += needed
                // Quotas can make two places on one volume see different free figures; the smaller is the safe one.
                byVolume[index].free = [byVolume[index].free, reading.free].compactMap { $0 }.min()
            } else {
                byVolume.append((groupable ? reading.volume : nil, [name], needed, reading.free))
            }
        }
        record("this computer's Restic Station data", need.coordinator, coordinator, groupable: true)
        record("beside this computer's folder", need.local, local, groupable: true)
        record(peerIsRemote ? "beside the other computer's folder" : "beside the other folder", need.peer, peer, groupable: !peerIsRemote)
        return byVolume.compactMap { entry in
            let want = required(entry.needed)
            guard let free = entry.free, want > free else { return nil }
            return "\(entry.names.joined(separator: " and ")): about \(format(want)) needed, \(format(free)) free"
        }
    }

    static func refusal(_ lines: [String]) -> SourceSyncError {
        .stateInvalid("There is not enough free space to synchronize these folders safely. Temporary copies are needed: \(lines.joined(separator: "; ")). Free up space on those volumes, or move part of the folder elsewhere, then preview again.")
    }

    /// Binary units, one decimal, never zero for a nonzero number.
    static func format(_ bytes: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes), index = 0
        while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
        return index == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[index])
    }

    /// Replaced only by tests, which cannot fill a disk.
    @TaskLocal static var readingOverride: (@Sendable (String) -> Reading)?

    /// Free space and volume of the filesystem holding `path`.
    static func reading(atPath path: String) -> Reading {
        if let override = readingOverride { return override(path) }
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return Reading() }
        var stamp = stat()
        let volume: UInt64? = stat(path, &stamp) == 0 ? UInt64(truncatingIfNeeded: stamp.st_dev) : nil
        return Reading(free: free(available: UInt64(info.f_bavail), fragment: UInt64(info.f_frsize), blocks: UInt64(info.f_blocks)), volume: volume)
    }

    /// Free bytes from `statvfs` figures, or nil when they cannot be trusted:
    /// a filesystem that reports no blocks or no block size (some FUSE and
    /// network mounts) says nothing, which is unknown and not full, and a
    /// product that overflows is nonsense. A volume with blocks and none
    /// available really is full.
    static func free(available: UInt64, fragment: UInt64, blocks: UInt64) -> UInt64? {
        guard blocks > 0, fragment > 0 else { return nil }
        let (bytes, overflow) = available.multipliedReportingOverflow(by: fragment)
        return overflow ? nil : bytes
    }
}
