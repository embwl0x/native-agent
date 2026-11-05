import SwiftUI
import Foundation
import StandingBots
import NativeAgentShared
import EngineRuntime
import SwarmRuns
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import AppKit
import AppToolRuntime
// Blueprint: | `SimpleThreadPresentation.swift` | Thread typography, outcomes, `SimpleThreadDocument` rows; absent time and pending work stay explicit |

/// A Simple thread as document rows, in the order given: each line is a left-seated paragraph headed by its speaker, as the thread
/// always read. They are display rows (role "system": nothing to regenerate, no first-render receipt) and are never written anywhere.
enum SimpleThreadDocument {
    struct Line {
        let id: String
        let speaker: String
        let text: String
        let at: Date?
    }

    static func groups(_ lines: [Line]) -> MessageGrouper.GroupedTranscript {
        MessageGrouper.projection(for: lines.map { line in
            ChatMessage(id: line.id, role: "system", content: "**\(line.speaker)**\n\n\(line.text)",
                        createdAt: line.at.map(NativeTimestampFormat.plainZulu) ?? "")
        })
    }
}

extension View {
    /// Share transcript geometry so changing thread kind cannot shift its text column.
    func simpleRoomColumn(gutter: CGFloat = NativeAgentShellLayout.roomGutter) -> some View {
        padding(.horizontal, gutter)
            .frame(maxWidth: NativeAgentShellLayout.roomColumn, alignment: .topLeading)
            .padding(.leading, NativeAgentShellLayout.roomLeadingInset)
            .padding(.trailing, NativeAgentShellLayout.roomTrailingInset)
            .frame(maxWidth: .infinity, alignment: NativeAgentShellLayout.roomAlignment)
    }
}

/// Dissolve scrolling text beneath pinned headers so their words never overlap.
struct SimpleThreadHeader<Mark: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        HStack(spacing: 12) {
            mark()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ShellType.title)
                    .foregroundStyle(NativeAgentShell.text)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .simpleRoomColumn()
        .padding(.top, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}

struct SimpleTranscriptEntry: View, Equatable {
    let speaker: String
    let text: String
    let at: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(speaker)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text(at.map(BotsShelfRecord.shortDate) ?? "Time unavailable")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
            }
            SimpleLiveText(text: text)
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.text)
                .lineSpacing(NativeAgentShellLayout.replyLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// Preserve line breaks when applying the chat's inline markdown styling.
    nonisolated static func inline(_ text: String) -> AttributedString {
        ChatMarkdownCache.inline(text).presentation
    }
}

struct SimpleLiveText: View {
    let text: String
    @State private var rendered: AttributedString?
    @State private var renderedSource: String?

    var body: some View {
        Group {
            if renderedSource == text, let rendered {
                Text(rendered)
            } else {
                Text("Formatting message…")
            }
        }
        .task(id: text) {
            let parsed = await Task.detached(priority: .userInitiated) { [text] in
                SimpleTranscriptEntry.inline(text)
            }.value
            guard !Task.isCancelled else { return }
            rendered = parsed
            renderedSource = text
        }
    }
}
