import Foundation
import SwiftUI

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
// 2026-09-03 finish pass. Capabilities, Knowledge Graph and Dreams sit inside
// `ShellPageFrame` (SetupView.swift:110), which already draws the back row, the
// title and the sheet. These are the only surfaces the three pages add on top
// of it: one card, one eyebrow, one empty state, one waiting line — everything
// else is words on the sheet. Type comes from `ShellType`, colour from
// `NativeAgentShell`, and nothing here paints a material.

/// A section head, spelled exactly like the Advanced list's: 13 semibold,
/// uppercase, 0.6 of tracking, on the sheet rather than on a plate.
struct AdvancedEyebrow: View {
    let text: String

    // Alive glass (2026-09-23): the kit's eyebrow.
    var body: some View {
        AliveEyebrow(text)
    }
}

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
        "mcp": "MCP",
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

/// A code at caption size, which `ShellType` has no token for (13 monospaced
/// is `ShellType.code`). Sized off `ShellType`, never a loose number.
enum AdvancedType {
    static let codeCaption = Font.system(size: ShellType.captionSize, design: .monospaced)
}

/// A bare fold: a chevron, the words, and one gesture on the whole row. No
/// plate, and the motion goes through the shell's fold spring.
struct AdvancedFold<Content: View>: View {
    let title: String
    var subtitle: String = ""
    /// What the fold would otherwise hide — the one signal that survives a
    /// collapse.
    var attention: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(
                    NativeAgentMotion.respecting(NativeAgentMotion.arrive, reduceMotion: reduceMotion)
                ) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(ShellType.labelSemibold)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(ShellType.bodySemibold)
                            .foregroundStyle(NativeAgentShell.text)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    // Folded, the count is one quiet word, not an alarm.
                    if let attention {
                        AdvancedStatusWord(status: nil, text: attention)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .transition(NativeAgentMotion.arrivalFade)
            }
        }
    }
}
