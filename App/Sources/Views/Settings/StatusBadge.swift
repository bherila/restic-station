import AppKit
import SwiftUI

/// The one visual vocabulary every status surface in Settings and onboarding
/// speaks: a coloured SF Symbol + label capsule, plus an optional line of
/// explanation underneath.
///
/// Colours come from the semantic palette (`.green`/`.yellow`/`.red`/
/// `.secondary`) so light and dark mode both work without custom colours,
/// and the symbol carries the same meaning as the colour — a badge must
/// still be readable when the colour is not (`docs/ui-spec.md` §Shell:
/// "Support light + dark mode").
enum StatusTone {
    case ok
    case warning
    case problem
    /// Not "bad" — *not known*. Grey, not red, and never green.
    case unknown
    case inProgress

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .yellow
        case .problem: return .red
        case .unknown, .inProgress: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        case .inProgress: return "clock.fill"
        }
    }
}

struct StatusBadge: View {
    let tone: StatusTone
    let label: String
    /// Shown as a spinner in place of the symbol; for "checking…" states.
    var isBusy: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: tone.symbolName)
                    .foregroundStyle(tone.color)
            }
            Text(label)
                .fontWeight(.medium)
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(tone.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.35)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)")
    }
}

/// A named badge row: "App  [Granted]" with the explanation underneath.
struct StatusRow: View {
    let title: String
    let tone: StatusTone
    let badgeLabel: String
    let detail: String
    var isBusy: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 12)
                StatusBadge(tone: tone, label: badgeLabel, isBusy: isBusy)
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Monospaced, selectable path with a "copy" button — used wherever the user
/// has to retype something into another app (System Settings' file picker,
/// a Terminal window).
struct CopyablePath: View {
    let text: String
    var helpText: String = "Copy"

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copy()
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .help(helpText)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func copy() {
        Pasteboard.copy(text)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}

/// One place that touches `NSPasteboard`, so the views stay AppKit-free.
enum Pasteboard {
    @MainActor
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
