import Foundation
import ApprovalTransactions
import EngineRuntime
import Transcripts
import SwiftUI
import NativeAgentShared
import ChatSessionWork
import MultimodalTTS
import AppKit
import CoreGraphics
import ScreenVision
import UniformTypeIdentifiers
import MemoryV2
import PersistenceCore
import TurnTrace
import ChatTurnRuntime
// Blueprint: | `ChatMessageListView.swift` | Windowed transcript interleaves HerScreen other-room exchanges from the contact projection; rows open the sidebar's contact thread; paging, grouping and card placement stay on the transcript rows |

enum ChatTranscriptWindow {
    static func range(count: Int, start: Int? = nil) -> Range<Int> {
        let count = max(0, count)
        let size = ChatMessageListView.windowSize
        let lower = min(max(0, start ?? (count - size)), max(0, count - size))
        return lower..<min(count, lower + size)
    }
}
// NATIVE_AGENT_RENDER_AUDIT=1 dumps render counters to stderr every five seconds.
final class RenderAudit: @unchecked Sendable {
    static let shared = RenderAudit()
    let enabled = ProcessInfo.processInfo.environment["NATIVE_AGENT_RENDER_AUDIT"] == "1"
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var lastDump = Date()

    static func bump(_ key: String) { shared._bump(key) }

    private func _bump(_ key: String) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1
        if Date().timeIntervalSince(lastDump) >= 5 {
            let line = counts.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            FileHandle.standardError.write(Data("RenderAudit[5s]: \(line)\n".utf8))
            counts = [:]
            lastDump = Date()
        }
    }
}
/// The one quiet line above a row that follows an hour of silence.
private struct ChatQuietGapLine: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, NativeAgentSpacing.sm)
            .accessibilityAddTraits(.isHeader)
    }

    private var label: String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct ChatMessageListView: View {
    var messages: [ChatMessage]
    // Detached panels pass their session identity for structural preparation
    // and the streaming bubble's current-session presentation.
    var sessionId: String = ""
    /// This session's streaming state makes its final assistant row the live tail.
    var isStreaming: Bool = false
    /// The current transcript-search result. Highlighting is projection-only;
    /// it never changes or filters canonical messages.
    var highlightedMessageID: String? = nil
    /// False while the reader has scrolled up: an entrance nobody is looking at
    /// is motion for nothing, and the "Latest" pill leads the eye instead.
    var animatesArrival: Bool = true
    var latestRequest: Int = 0
    /// Told whether a page anchor pins the list to an earlier page, so the
    /// chat's re-arm knows its bottom is not the live one.
    var onPagedBackChange: ((Bool) -> Void)? = nil
    /// The mounted preparation reads the transcript owner's structure version.
    @Environment(AppModel.self) private var appModel
    @Environment(\.inlineCardAction) private var inlineCardAction

    /// Bound resident selectable-text groups; paging and search reach the complete transcript.
    nonisolated static let windowSize = 60
    @State private var pageAnchorID: String?
    @State private var pagedSearchID: String?
    @State private var revealedSessionId = ""
    @State private var openedContact: AgentContactPresentation?
    /// Page by stable group identity, so appended replies do not move a reader
    /// browsing history. A new search selection centers its own bounded page.
    private func windowRange(for groups: MessageGrouper.GroupedTranscript) -> Range<Int> {
        if let highlightedMessageID, highlightedMessageID != pagedSearchID || revealedSessionId != sessionId,
           let hit = groups.firstIndex(where: { group in
               group.messages.contains { $0.id == highlightedMessageID }
           }) {
            return ChatTranscriptWindow.range(count: groups.count, start: hit - Self.windowSize / 2)
        }
        let start = revealedSessionId == sessionId
            ? groups.firstIndex(where: { $0.id == pageAnchorID }) : nil
        return ChatTranscriptWindow.range(count: groups.count, start: start)
    }

    /// Scroll identity, search highlight and entrance transition stay on the laid-out row.
    @ViewBuilder
    private func bubbleRow(
        _ msg: ChatMessage, lastAssistantId: String?, liveTailId: String? = nil
    ) -> some View {
        // One view for every row. Only the live tail reads chunks; a reply
        // that stops being the tail keeps its identity, so it never remounts
        // or replays its arrival when the next turn starts.
        StreamingTailBubble(
            message: msg,
            isLastAssistant: msg.role == "assistant" && msg.id == lastAssistantId,
            isLive: msg.id == liveTailId
        )
        // Keep each message an independent accessibility container. Without
        // this boundary SwiftUI coalesces adjacent transcript text into one
        // enormous element, forcing clients to resolve the whole page's text
        // to inspect a single message. Containment preserves child links and
        // the bubble's named actions without altering visual layout.
        .accessibilityElement(children: .contain)
        .transcriptLayoutProbe(rowID: msg.id, kind: .bubble)
        .readingBlock(msg.id)
        .modifier(MacChatTranscriptSearchHighlight(
            isHighlighted: msg.id == highlightedMessageID
        ))
        .id(MacChatTranscriptSearch.scrollTargetID(for: msg.id))
        // Arrival uses animateMacChatMutation; removal and wholesale replacement stay instant.
        .transition(animatesArrival
            ? .asymmetric(
                insertion: NativeAgentMotion.arrival,
                removal: .identity)
            : .identity)
    }

    var body: some View {
        // Keep the transcript mounted while its session prepares rows.
        VStack(alignment: .leading, spacing: NativeAgentShellLayout.transcriptGap) {
            transcriptRows
        }
        .sheet(item: $openedContact) { contact in
            SimpleContactThread(contact: contact, store: appModel.engine.contactThreads) { openedContact = nil }
                .frame(minWidth: 600, minHeight: 500)
        }
        .onAppear { appModel.engine.contactThreads.start() }
        .task(id: "\(sessionId)|\(appModel.engine.transcripts.structureVersion(for: sessionId))") {
            await appModel.engine.transcripts.prepareGroups(for: sessionId)
        }
    }

    @ViewBuilder private var transcriptRows: some View {
        let lastAssistantId = messages.last(where: { $0.role == "assistant" })?.id
        let allGroups = appModel.engine.transcripts.groups(for: sessionId)
        let range = windowRange(for: allGroups)
        let hidden = range.lowerBound
        let groups = Array(allGroups[range])
        let nextPageAt = range.upperBound < allGroups.count
            ? allGroups[range.upperBound].messages.first.flatMap { UserDisplayFormatters.parseISOTimestamp($0.createdAt) } : nil
        let exchanges = OtherRoomExchange.anchored(appModel.engine.contactThreads.otherRooms.filter { event in
            event.sessionID != sessionId && nextPageAt.map { event.at < $0 } != false
        },
            to: groups.compactMap { group in
                group.messages.first.flatMap { message in
                    UserDisplayFormatters.parseISOTimestamp(message.createdAt).map { (id: group.id, at: $0) }
                }
            })
        let tailId = messages.last.flatMap { $0.role == "assistant" ? $0.id : nil }
        let liveTailId = isStreaming ? tailId : nil
        let cardMount = InlineCardMount.map(groups: groups, messages: messages,
            readStatus: appModel.engine.transcripts.transcriptReadStatus(for: sessionId))
        let relocatedRows = cardMount.relocated
        if hidden > 0 {
            ChatEarlierMessagesRow(hidden: hidden) {
                revealedSessionId = sessionId
                pagedSearchID = highlightedMessageID
                pageAnchorID = allGroups[max(0, range.lowerBound - Self.windowSize)].id
            }
        }
        ForEach(groups) { group in
            exchangeRows(exchanges[group.id] ?? [])
            if let gapAbove = group.gapAbove {
                ChatQuietGapLine(date: gapAbove)
            }
            if group.isToolGroup {
                if group.messages.count == 1 {
                    let msg = group.messages[0]
                    if msg.metadata?.isPendingApproval == true {
                        InlineApprovalCard(message: msg)
                            .transcriptLayoutProbe(rowID: msg.id, kind: .approval)
                            .readingBlock(msg.id)
                    } else if msg.metadata?.interactionMirror != nil {
                        ChatInlineCardHost(cards: cardMount.cardsByRow[msg.id] ?? [], action: inlineCardAction)
                            .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
                            .transcriptLayoutProbe(rowID: msg.id, kind: .approval)
                            .readingBlock(msg.id)
                    } else {
                        ToolCallGroup(messages: [msg])
                            .transcriptLayoutProbe(rowID: msg.id, kind: .toolRow)
                            .readingBlock(msg.id)
                    }
                    if msg.metadata?.interactionMirror == nil, !relocatedRows.contains(msg.id) {
                        ReadingCards(rowID: msg.id, cards: cardMount.cardsByRow[msg.id] ?? [])
                    }
                } else {
                    ToolCallGroup(messages: group.messages)
                    .transcriptLayoutProbe(rowID: group.id, kind: .toolGroup)
                    .readingBlock(group.id)
                    // Cards retain their tool-row ownership and call order within a folded run.
                    ForEach(group.messages) { member in
                        if !relocatedRows.contains(member.id) {
                            ReadingCards(rowID: member.id, cards: cardMount.cardsByRow[member.id] ?? [])
                        }
                    }
                }
            } else {
                let msg = group.messages[0]
                // Only card hosts get a wrapper; ordinary rows keep their layout and scroll identity.
                if let hosted = cardMount.byHost[msg.id], !hosted.isEmpty {
                    VStack(alignment: .leading, spacing: NativeAgentShellLayout.transcriptGap) {
                        bubbleRow(msg, lastAssistantId: lastAssistantId, liveTailId: liveTailId)
                        // The handle, directly under what she just said: same
                        // leading edge, the transcript's one gap, nothing that
                        // reads as an interruption.
                        ForEach(hosted, id: \.self) { rowID in
                            ReadingCards(rowID: rowID, cards: cardMount.cardsByRow[rowID] ?? [])
                        }
                    }
                } else {
                    bubbleRow(msg, lastAssistantId: lastAssistantId, liveTailId: liveTailId)
                }
            }
        }
        .onChange(of: latestRequest) { _, _ in
            revealedSessionId = sessionId
            pagedSearchID = highlightedMessageID
            pageAnchorID = nil
        }
        .onChange(of: revealedSessionId == sessionId && pageAnchorID != nil, initial: true) { _, pagedBack in
            onPagedBackChange?(pagedBack)
        }
        exchangeRows(exchanges[""] ?? [])
        if range.upperBound < allGroups.count {
            HStack {
                Button("Later messages") {
                    revealedSessionId = sessionId
                    pagedSearchID = highlightedMessageID
                    pageAnchorID = allGroups[range.upperBound].id
                }
                Button("Latest") {
                    revealedSessionId = sessionId
                    pagedSearchID = highlightedMessageID
                    pageAnchorID = nil
                }
            }
            .buttonStyle(.plain)
            .font(ShellType.label)
            .foregroundStyle(NativeAgentShell.secondary)
            .padding(.vertical, 8)
        }
    }

    private func exchangeRows(_ exchanges: [OtherRoomExchange]) -> some View {
        ForEach(exchanges) { exchange in
            Button {
                openedContact = appModel.engine.contactThreads.contacts.first { $0.id == exchange.contactID }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(exchange.title)
                    Text(exchange.subtitle).foregroundStyle(.secondary)
                }.font(.callout).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!appModel.engine.contactThreads.contacts.contains { $0.id == exchange.contactID })
        }
    }
}

/// A row's cards as one reading block, only when it has any: an empty slot
/// stays no view at all, or the stack would space it like a row.
private struct ReadingCards: View {
    let rowID: String
    let cards: [InlineCardModel]
    @Environment(\.inlineCardAction) private var action

    var body: some View {
        if !cards.isEmpty {
            ChatInlineCardHost(cards: cards, action: action)
                .readingBlock("cards:" + rowID)
        }
    }
}

/// The one row above a windowed transcript: how many rows are above the fold,
/// and a click reveals the next page. Secondary label, no chrome.
private struct ChatEarlierMessagesRow: View {
    let hidden: Int
    let reveal: () -> Void

    var body: some View {
        Button(action: reveal) {
            Text("\(hidden) earlier \(hidden == 1 ? "message" : "messages")")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the next \(ChatMessageListView.windowSize) earlier messages")
    }
}

private struct MacChatTranscriptSearchHighlight: ViewModifier {
    let isHighlighted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isHighlighted {
            content
                .overlay {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                        .strokeBorder(NativeAgentShell.secondary, lineWidth: 2)
                        .padding(-5)
                        .accessibilityHidden(true)
                }
                .accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}
