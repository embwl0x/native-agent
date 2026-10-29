import Foundation
import SwiftUI
// Blueprint: | `AdvancedPageComponents.swift` | Shared Advanced page sections and read status |

/// A stable quiet slot for a page read; cached content stays mounted below it.
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
//
// Page components use shell type and colour without painting another material.

/// How a section's content sits under its eyebrow.
enum AdvancedSectionCard {
    /// ONE group card, each child a row with a hairline between.
    case rows
    /// ONE card holding the content as a single stack of controls.
    case single
    /// No card: the content brings its own cards.
    case bare
}

/// THE section block on every settings and Advanced page: the kit's eyebrow,
/// the content under it in the shape `card` names, and an optional quiet line.
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
                    // Secondary, not tertiary: tertiary fails where the haze peaks.
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// What would fill this, said in the page's own left column. No plate, no
/// glyph, no tinted button — an empty state is a sentence, not a poster.
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

/// A read that has not landed yet. One line, one small spinner — never a
/// centred `ProgressView` claiming the whole pane.
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

/// A status, said in the room's three state colours. `calm` when a thing is up,
/// `trouble` when it is not, the teal ONLY where something waits on a person
/// (house rule 1), and the quiet ink for everything that is merely a fact.
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

    /// No slugs in front of a person: `needs_setup` is "Needs setup".
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

/// One status word. The badge it replaces was a tinted capsule; on the sheet a
/// coloured word says the same thing without a second plate.
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

/// A fact beside a row — what the pill used to carry, without the pill.
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

/// A number and what it counts. Bare by construction: these sit INSIDE a card,
/// and a card inside a card is the plate-on-plate the pass exists to remove.
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
