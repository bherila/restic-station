import AppKit
import ResticStationCore
import SwiftUI

/// A narrow, explicit selection beside the existing broader backup list.
/// A folder chooser supplies the name and this computer's identity; the
/// normal flow does not ask users to understand replica IDs or generations.
struct SourceSyncSection: View {
    @Binding var folders: [SourceSyncGroup]
    let machineId: String
    let errorMessage: String?

    var body: some View {
        Section {
            if folders.isEmpty {
                Text("Choose a folder only if you also want to keep another live copy in sync.")
                    .foregroundStyle(.secondary)
            }
            ForEach($folders) { $folder in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Label", text: $folder.name)
                            .font(.headline)
                        Spacer()
                        Button(role: .destructive) {
                            folders.removeAll { $0.id == folder.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Stop synchronizing this folder; keep all existing copies")
                    }
                    HStack {
                        TextField("Folder on this computer", text: $folder.localPath)
                        Button("Choose…") {
                            if let path = chooseFolder(message: "Choose the specific folder to keep in sync.") {
                                folder.localPath = path
                            }
                        }
                    }
                    Picker("Other copy", selection: Binding(
                        get: { folder.peer.sshTarget != nil },
                        set: { folder.peer.sshTarget = $0 ? "" : nil }
                    )) {
                        Text("Another folder on this computer").tag(false)
                        Text("Folder on another computer (SSH)").tag(true)
                    }
                    if folder.peer.sshTarget != nil {
                        TextField("Computer (SSH)", text: Binding(
                            get: { folder.peer.sshTarget ?? "" },
                            set: { folder.peer.sshTarget = $0 }
                        ), prompt: Text("sync.example.test"))
                        TextField("Folder on that computer", text: $folder.peer.path, prompt: Text("/srv/shared-notes"))
                    } else {
                        HStack {
                            TextField("Other folder", text: $folder.peer.path)
                            Button("Choose…") {
                                if let path = chooseFolder(message: "Choose the other live copy of this folder.") {
                                    folder.peer.path = path
                                }
                            }
                        }
                    }
                    DisclosureGroup("Advanced") {
                        LabeledContent("Run synchronization on", value: folder.coordinatorMachineId == machineId ? "This computer" : folder.coordinatorMachineId)
                        if folder.peer.sshTarget != nil {
                            TextField("Remote helper", text: $folder.peer.helperPath)
                            Text("The other computer needs a compatible Restic Station helper and SSH access. Credentials stay in your existing SSH configuration.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Button("Add Folder to Keep in Sync…") {
                guard let path = chooseFolder(message: "Choose a folder already included in this set's backup sources.") else { return }
                folders.append(SourceSyncGroup(
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    localPath: path, peer: SyncEndpoint(path: ""), coordinatorMachineId: machineId
                ))
            }
            if let errorMessage { InlineMessage(errorMessage) }
        } header: {
            Text("Keep in sync (optional)")
        } footer: {
            Text("Only these selected folders are synchronized. Sources above still define everything backed up; you do not need to move folders or create another backup set.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func chooseFolder(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
