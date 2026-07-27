import ResticStationCore
import SwiftUI

// MARK: - MaintenanceSection

/// The card every Maintenance section is drawn in: a titled `GroupBox` with
/// an optional trailing accessory (the section's own action button) and an
/// optional caption.
///
/// `docs/ui-spec.md` §Copy/tone rules asks for restic terms to be "briefly
/// explained in captions on first use per screen" — the caption slot is where
/// that happens, once per section, rather than in a tooltip nobody opens.
struct MaintenanceSection<Accessory: View, Content: View>: View {
    let title: String
    let systemImage: String
    let caption: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(
        _ title: String,
        systemImage: String,
        caption: String? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.caption = caption
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                    Spacer(minLength: 12)
                    accessory
                }
                if let caption {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension MaintenanceSection where Accessory == EmptyView {
    init(
        _ title: String,
        systemImage: String,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, systemImage: systemImage, caption: caption, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - DestinationTitle

/// A destination's name with its kind icon and, for the primary, the PRIMARY
/// tag the destinations table uses — so the same repository is recognizable
/// across screens.
struct DestinationTitle: View {
    let destination: Destination

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: destination.kind.symbolName)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(destination.label)
                .font(.headline)
                .lineLimit(1)
            if destination.isPrimary {
                Text("PRIMARY")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Primary destination")
            }
        }
    }
}

extension DestinationKind {
    /// SF Symbols per `docs/ui-spec.md` §Shell ("Use SF Symbols throughout").
    var symbolName: String {
        switch self {
        case .localPath: return "folder"
        case .sftp: return "network"
        case .rest: return "server.rack"
        case .s3: return "cloud"
        case .otherCloud: return "cloud"
        }
    }
}

// MARK: - MaintenanceBanner

/// The result of the last helper-backed action, dismissible. Errors follow
/// the "what failed, mapped reason, one next step" rule — the text itself is
/// assembled in `MaintenanceModel.activity(...)`.
struct MaintenanceBanner: View {
    let activity: MaintenanceActivity
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activity.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(activity.isError ? .orange : .green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title)
                    .font(.headline)
                Text(activity.detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let runId = activity.runId {
                    // The run this action produced. Named, not linked: the
                    // Runs screen is a sibling section, and deep-linking
                    // into it is T15's to define.
                    Text("Recorded as run \(runId)\(activity.runStatus.map { " — \($0.rawValue)" } ?? "").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - MaintenanceFormat

/// All the number/date formatting the screen does, in one place.
enum MaintenanceFormat {
    /// `ByteCountFormatter`, per `docs/ui-spec.md` §Maintenance. `.file` is
    /// the right count style for repository sizes: it is what Finder shows
    /// for the same bytes on disk.
    static func bytes(_ value: Int?) -> String {
        guard let value else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return formatter.string(fromByteCount: Int64(value))
    }

    static func count(_ value: Int?, singular: String, plural: String) -> String {
        guard let value else { return "—" }
        return "\(value) \(value == 1 ? singular : plural)"
    }

    /// "2 hours ago" — the same relative phrasing the menu bar uses.
    static func relative(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func absolute(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "27 Jul 2026 at 14:02 (2 hours ago)" for the tooltips/details where
    /// both matter.
    static func absoluteAndRelative(_ date: Date, now: Date = Date()) -> String {
        guard let relative = relative(date, now: now) else { return absolute(date) }
        return "\(absolute(date)) (\(relative))"
    }

    /// A one-line summary of a `RetentionPolicy`, e.g.
    /// "7 daily, 4 weekly, 12 monthly". `nil` policy = never forget.
    static func retentionSummary(_ policy: RetentionPolicy?) -> String {
        guard let policy, !policy.isEmpty else {
            return "Keep every snapshot (no retention policy)"
        }
        let parts: [(Int?, String)] = [
            (policy.keepLast, "last"),
            (policy.keepHourly, "hourly"),
            (policy.keepDaily, "daily"),
            (policy.keepWeekly, "weekly"),
            (policy.keepMonthly, "monthly"),
            (policy.keepYearly, "yearly"),
        ]
        let rendered = parts.compactMap { value, name -> String? in
            guard let value else { return nil }
            return "\(value) \(name)"
        }
        return "Keep \(rendered.joined(separator: ", "))"
    }
}

// MARK: - RunStatus presentation

// RunStatus presentation (label/symbolName/tint) lives in
// Views/Runs/RunHistory.swift — one canonical extension for all screens.
