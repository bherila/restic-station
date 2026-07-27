import AppKit
import ResticStationCore
import SwiftUI

/// The Mount card (`docs/ui-spec.md` §Restore → "Mount section").
///
/// With macFUSE installed this offers a live, read-only Finder view of the
/// whole repository; without it, the card is disabled and carries the
/// spec's exact copy — mounting is a convenience, never a prerequisite for
/// restoring.
struct MountSection: View {
    let repository: RestoreRepository?
    @ObservedObject var mounts: MountController
    @EnvironmentObject private var model: AppModel

    @State private var isWorking = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if MountController.isMacFUSEInstalled {
                    installedBody
                } else {
                    Text(MountController.missingMacFUSECopy)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Mount snapshot browser") {}
                        .disabled(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Mount", systemImage: "externaldrive.connected.to.line.below")
        }
        .disabled(!MountController.isMacFUSEInstalled)
    }

    // MARK: - macFUSE present

    @ViewBuilder
    private var installedBody: some View {
        if isMountedHere, let mountpoint = mounts.mountpoint {
            Text(mountpoint.path)
                .font(.caption)
                .monospaced()
                .lineLimit(2)
                .truncationMode(.head)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([mountpoint])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button("Unmount") {
                    Task {
                        isWorking = true
                        await mounts.unmount()
                        isWorking = false
                    }
                }
                .disabled(isWorking || mounts.phase == .unmounting)
                if isWorking || mounts.phase == .unmounting {
                    ProgressView().controlSize(.small)
                }
            }
        } else if mounts.phase == .mounting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Mounting…").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Text("Browse the whole repository in Finder, read-only. One repository at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Mount snapshot browser") {
                guard let repository, let resticPath = model.config.resticPath else { return }
                Task {
                    isWorking = true
                    await mounts.mount(repository: repository, resticPath: resticPath, paths: model.paths)
                    isWorking = false
                }
            }
            .disabled(repository == nil || model.config.resticPath == nil || isOtherRepositoryMounted || isWorking)

            if isOtherRepositoryMounted {
                Text("Another repository is mounted. Unmount it first — restic mounts one repository at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let error = mounts.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isMountedHere: Bool {
        guard let repository else { return false }
        return mounts.isMounted(repositoryID: repository.id)
    }

    private var isOtherRepositoryMounted: Bool {
        mounts.phase == .mounted && !isMountedHere
    }
}
