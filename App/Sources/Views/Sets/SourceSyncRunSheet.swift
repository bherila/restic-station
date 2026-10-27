import ResticStationCore
import SwiftUI

/// A deliberate, reviewable manual action with independent sync and backup
/// scopes. The helper owns every mutation and confirmation capability.
struct SourceSyncRunSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let set: BackupSet
    @State private var previews: [UUID: SourceSyncPreview] = [:]
    @State private var statuses: [UUID: SourceSyncStatus] = [:]
    @State private var errors: [UUID: String] = [:]
    @State private var busy = false
    @State private var completed = false
    private var helper: HelperInvoker { model.helper }

    private var needsRecovery: Bool { statuses.values.contains { $0.operationId != nil } }
    private var ready: Bool {
        errors.isEmpty && set.syncFolders.allSatisfy { group in
            statuses[group.id]?.operationId != nil || previews[group.id]?.previewToken != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(completed ? "Sync and backup complete" : "Sync & Back Up")
                .font(.title2).fontWeight(.semibold)
            Text(set.name).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Keep in sync") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(set.syncFolders) { group in
                                folder(group)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    GroupBox("Back up") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("All configured backup sources")
                            ForEach(set.sources, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                            Text("Includes folders outside the sync selection and all configured backup destinations.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
            }
            if busy {
                HStack { ProgressView().controlSize(.small); Text("Checking, protecting and backing up…") }
            } else if !completed {
                Text("Finish editing these folders before starting. If files change during the operation, it stops for review.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button(completed ? "Done" : "Cancel") { dismiss() }.disabled(busy)
                if !completed {
                    Button("Back Up Only") {
                        dismiss()
                        model.backUpNow(setId: set.id, backupOnly: true)
                    }.disabled(busy)
                    Spacer()
                    Button("Refresh Preview") { Task { await load() } }.disabled(busy)
                    Button(needsRecovery ? "Resume & Back Up" : "Sync & Back Up") { Task { await run() } }
                        .buttonStyle(.borderedProminent).disabled(busy || !ready)
                }
            }
        }
        .padding(24).frame(width: 680, height: 600)
        .interactiveDismissDisabled(busy)
        .task { await load() }
    }

    @ViewBuilder private func folder(_ group: SourceSyncGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.name).fontWeight(.semibold)
            Text(group.localPath).textSelection(.enabled)
            Text("↔ \(group.peer.sshTarget.map { $0 + ":" } ?? "")\(group.peer.path)").textSelection(.enabled)
            if let error = errors[group.id] {
                // Selectable, so an install command in the reason can be copied.
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            } else if completed {
                Label("Synchronized and backed up", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if statuses[group.id]?.operationId != nil {
                Text("An interrupted operation is ready to resume. Existing recovery copies are retained.").foregroundStyle(.orange)
                if statuses[group.id]?.canCancel == true {
                    Button("Cancel Pending Plan") {
                        Task {
                            busy = true
                            do { _ = try await helper.syncRecover(setId: set.id, groupId: group.id, cancelUnstarted: true) }
                            catch { errors[group.id] = String(describing: error); busy = false; return }
                            await load()
                        }
                    }.disabled(busy)
                    Text("No files have been installed. Cancel to make a new preview if the folders changed.").font(.footnote).foregroundStyle(.secondary)
                }
            } else if let preview = previews[group.id] {
                Text("\(preview.copies) copies · \(preview.removals) removals · \(preview.conflicts) conflicts")
                if preview.conflicts > 0 {
                    Text("Resolve the listed conflicts in the original folders, then refresh the preview. You can back up now.")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let changes = preview.changes, !changes.isEmpty {
                    DisclosureGroup("Review changes") {
                        ForEach(changes) { change in
                            HStack {
                                Text(action(change.action)).frame(width: 120, alignment: .leading)
                                Text(change.path).textSelection(.enabled)
                            }.font(.callout)
                        }
                    }
                }
            }
            if let recovery = statuses[group.id]?.recovery {
                DisclosureGroup("Recovery copies") {
                    Text("These private locations may hold preserved originals. A path exists only after its original version was moved aside.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let snapshot = recovery.protectedSnapshotId {
                        Text("Protection snapshot: \(snapshot)").font(.caption).textSelection(.enabled)
                    }
                    ForEach(recovery.entries) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.path).fontWeight(.semibold)
                            if let local = entry.localCopy { Text("This computer: \(local)").textSelection(.enabled) }
                            if let peer = entry.peerCopy { Text("Other computer: \(peer)").textSelection(.enabled) }
                        }.font(.caption)
                    }
                }
            }
        }.font(.callout)
    }

    @MainActor private func load() async {
        busy = true; errors = [:]; previews = [:]; statuses = [:]
        defer { busy = false }
        for group in set.syncFolders {
            do {
                statuses[group.id] = try await helper.syncStatus(setId: set.id, groupId: group.id)
                if statuses[group.id]?.operationId == nil {
                    previews[group.id] = try await helper.syncPlan(setId: set.id, groupId: group.id)
                }
            } catch { errors[group.id] = String(describing: error) }
        }
    }

    @MainActor private func run() async {
        busy = true
        model.setSourceSyncBusy(true, setId: set.id)
        defer { busy = false; model.setSourceSyncBusy(false, setId: set.id); model.refresh() }
        for group in set.syncFolders {
            do {
                if statuses[group.id]?.operationId != nil {
                    statuses[group.id] = try await helper.syncRecover(setId: set.id, groupId: group.id)
                } else if let token = previews[group.id]?.previewToken {
                    statuses[group.id] = try await helper.syncApply(setId: set.id, groupId: group.id, token: token)
                } else { throw SourceSyncError.stalePlan }
            } catch {
                errors[group.id] = String(describing: error)
                // A refresh reads the durable operation identity before a
                // retry. Never reuse an already consumed preview token.
                return
            }
        }
        completed = true
    }

    private func action(_ action: SyncChange.Action) -> String {
        switch action {
        case .copyToLocal: return "Copy here"
        case .copyToPeer: return "Copy to other"
        case .removeLocal: return "Remove here"
        case .removePeer: return "Remove on other"
        case .conflict: return "Conflict"
        }
    }
}
