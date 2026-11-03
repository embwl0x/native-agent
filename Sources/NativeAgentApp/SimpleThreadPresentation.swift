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
// Blueprint: | `SimpleThreadPresentation.swift` | Shared thread column, header and transcript text render the chat's typography and shared inline outcomes; missing recorded times display Time unavailable; pending preparation is explicit |

extension View {
    /// Threads share the chat transcript's width, gutter and anchor.
    func simpleRoomColumn(gutter: CGFloat = NativeAgentShellLayout.roomGutter) -> some View {
        padding(.horizontal, gutter)
            .frame(maxWidth: NativeAgentShellLayout.roomColumn, alignment: .topLeading)
            .padding(.leading, NativeAgentShellLayout.roomLeadingInset)
            .padding(.trailing, NativeAgentShellLayout.roomTrailingInset)
            .frame(maxWidth: .infinity, alignment: NativeAgentShellLayout.roomAlignment)
    }
}

/// Pinned thread headers share chat typography and dissolve scrolling words beneath them.
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

/// One read-only transcript entry: who, when, and the words in the chat's
/// reply type.
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

    /// Bold, italics and code as the chat shows them; line breaks kept.
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
