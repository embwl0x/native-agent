import Foundation
import SwiftUI
// Blueprint: | `AdvancedPageComponents.swift` | Shared Advanced page sections and read status |

/// Keep cached content mounted while the page read reports its status.
struct PageReadStatus: View {
    let isReading: Bool
    var text: String?

    var body: some View {
        HStack(spacing: 8) {
            if isReading { ProgressView().controlSize(.small) }
            if let text {
                Text(text)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 24, alignment: .leading)
    }
}

// MARK: - The Advanced page kit

enum AdvancedSectionCard {
    case rows
    case single
    case bare
}

/// Use shared section chrome so settings and Advanced pages keep the same hierarchy.
struct AdvancedSection<Content: View>: View {
    let title: String
    var card: AdvancedSectionCard = .rows
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow(title)
            switch card {
            case .rows:
                AliveGroupCard { content }
            case .single:
                AliveGroupCard {
                    VStack(alignment: .leading, spacing: 12) { content }
                }
            case .bare:
                content
            }
            if let note {
                Text(note)
                    .font(ShellType.rowDetail)
                    // Tertiary ink loses contrast at the haze peak.
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Keep empty states in the page's text column so they do not compete with content.
struct AdvancedEmptyState: View {
    let title: String
    var detail: String = ""
    var actionTitle: String?
    var actionIsDisabled = false
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            if !detail.isEmpty {
                Text(detail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .disabled(actionIsDisabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

/// Keep loading inline so it does not claim the whole pane.
struct AdvancedWaitingLine: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reserve teal for waiting on a person; calm, trouble and quiet ink distinguish the other states.
enum AdvancedStatusWords {
    static func color(_ status: String?) -> Color {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending", "awaiting_approval", "needs_approval":
            return NativeAgentShell.needsYou
        case "ok", "done", "passed", "succeeded", "active", "valid", "ready",
             "scheduled", "granted", "installed", "approved", "trusted", "healthy":
            return NativeAgentShell.calm
        case "fail", "failed", "error", "timeout", "quarantined", "evidence_failed",
             "denied", "revoked", "refused", "warn", "warning", "blocked",
             "needs_setup", "interrupted", "disabled", "rolled_back", "stale":
            return NativeAgentShell.trouble
        default:
            return NativeAgentShell.secondary
        }
    }

    /// Translate storage slugs into readable labels.
    static func label(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = known[trimmed.lowercased()] { return known }
        let spaced = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first, first.isLowercase else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }

    private static let known: [String: String] = [
        "ok": "OK",
        "warn": "Warning",
        "fail": "Failed",
        "info": "Working",
    ]
}

/// Use a colored word to avoid stacking another plate on the sheet.
struct AdvancedStatusWord: View {
    let status: String?
    var text: String?

    var body: some View {
        Text(AdvancedStatusWords.label(text ?? status ?? ""))
            .font(ShellType.caption)
            .foregroundStyle(AdvancedStatusWords.color(status))
            .lineLimit(1)
    }
}

struct AdvancedMeta: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)
            .lineLimit(1)
    }
}

/// Keep metrics bare because they already sit inside a card.
struct AdvancedStat: View {
    let title: String
    let value: String
    var detail: String = ""
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(ShellType.bodySemibold)
                .monospacedDigit()
                .foregroundStyle(status.map(AdvancedStatusWords.color) ?? NativeAgentShell.text)
                .lineLimit(1)
            Text(title)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(1)
            if !detail.isEmpty {
                Text(AdvancedStatusWords.label(detail))
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
