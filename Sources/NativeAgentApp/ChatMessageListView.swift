import SwiftUI
import ImageIO
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
import TurnTrace
import ChatOrchestration
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

// PATCH-2026-05-08: wave2-chat-ux — groups consecutive tool messages into collapsible stacks
// B.6: MessageGrouper — shared grouping logic exposed as a static helper so the
// ForEach can live directly in the outer transcript stack.
/// The transcript's container: a plain `VStack`, always.
///
/// User, 2026-09-04: every main-thread pin since 2026-08-31 sampled the same:
/// `NSRunLoop.flushObservers` → `NSHostingView.beginTransaction` → layout, and
/// at the end of each update `LazyLayoutViewCache.signalPrefetch` →
/// `NSHostingView.requestUpdate` → the next one, with no app code anywhere on
/// the stack. macOS 26's LazyVStack prefetches row hierarchies past the
/// viewport's edges and, in this tree, never settled. Bars made it happen in
/// fifteen minutes; insets took nine hours. A VStack has no prefetch, and
/// AttributeGraph memoizes unchanged rows, so a hundred-row thread costs the
/// same per delta either way. Long threads are windowed by
/// `ChatMessageListView.windowSize` instead of made lazy, so no thread ever
/// re-enters the machinery that pinned; the trap in the plan of record catches
/// a recurrence with a sample.
struct ChatTranscriptStack<Content: View>: View {
    let alignment: HorizontalAlignment
    let spacing: CGFloat
    let content: () -> Content

    init(
        alignment: HorizontalAlignment,
        spacing: CGFloat,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: alignment, spacing: spacing, content: content)
            .focusSection()
    }
}

struct MessageGroup: Identifiable {
    var id: String
    var messages: [ChatMessage]
    var isToolGroup: Bool
    /// Set when this row follows more than an hour of quiet: when it began.
    var gapAbove: Date? = nil
}

enum ChatTranscriptWindow {
    static func range(count: Int, start: Int? = nil) -> Range<Int> {
        let count = max(0, count)
        let size = ChatMessageListView.windowSize
        let lower = min(max(0, start ?? (count - size)), max(0, count - size))
        return lower..<min(count, lower + size)
    }
}

/// Where a card mounts.
///
/// Agent, 2026-09-13: her prose comes FIRST and the card is the handle under
/// it. A need is raised on the blocked tool row, so that is where it is
/// persisted — but the row the reader sees next is the reply that closed the
/// waiting turn, and the card belongs under THAT. When the turn left no reply
/// row (it parked before she said anything), the card stays on the tool row,
/// which is where it has always been.
enum InlineCardMount {
    /// The mount map plus the rows it moved cards OFF, so the list computes
    /// neither per render.
    struct Map {
        var byHost: [String: [String]] = [:]
        var relocated: Set<String> = []
    }

    /// Memoized per transcript structure (2026-09-14).
    ///
    /// This walk used to run inside `ChatMessageListView.body`, which a
    /// streamed chunk re-runs ~14 times a second: every render scanned every
    /// reply in the visible page for `<tool_use` markers and rebuilt a
    /// dictionary and a set. Where a card mounts can only change when the rows
    /// change, and every write except the streaming delta bumps
    /// `engine.transcripts.structureVersion` — so that, plus the page the reader is
    /// on, is the whole key.
    @MainActor private static var slots: [String: Map] = [:]
    @MainActor private static var slotOrder: [String] = []

    @MainActor
    static func map(
        groups: [MessageGroup], sessionId: String, structureVersion: UInt64
    ) -> Map {
        // The one thing a streamed chunk CAN change here: a reply row that was
        // empty when it was appended starts saying something, and the card
        // belongs under it from that moment. `hasVisibleText` stops at the
        // first non-space character, so this flips false→true exactly once per
        // turn and the walk below runs once more — not once per chunk.
        let tailSpeaks = ChatTranscriptPresentation.hasVisibleText(
            groups.last?.messages.last?.content ?? ""
        )
        let key = """
            \(sessionId)|\(structureVersion)|\(groups.first?.id ?? "")|\
            \(groups.count)|\(tailSpeaks)
            """
        if let cached = slots[key] { return cached }
        let byHost = hosts(groups: groups)
        let built = Map(byHost: byHost, relocated: Set(byHost.values.joined()))
        slots[key] = built
        slotOrder.append(key)
        // A detached panel on another session, and the page either one is on,
        // each want their own answer; older keys are dead the moment the
        // version moves.
        if slotOrder.count > 8 { slots.removeValue(forKey: slotOrder.removeFirst()) }
        return built
    }

    /// Assistant row id → the tool rows whose cards mount under it.
    static func hosts(groups: [MessageGroup]) -> [String: [String]] {
        var hosts: [String: [String]] = [:]
        for (index, group) in groups.enumerated() where group.isToolGroup {
            guard index + 1 < groups.count else { continue }
            let next = groups[index + 1]
            guard !next.isToolGroup,
                  let reply = next.messages.first,
                  reply.role == "assistant",
                  isReadableReply(reply.content)
            else { continue }
            hosts[reply.id, default: []].append(contentsOf: group.messages.map(\.id))
        }
        return hosts
    }

    /// A reply worth putting the card under is one the person can actually
    /// read. A row whose whole content is the protocol marker a text-compat
    /// turn left behind ("<tool_use name=…>{}</tool_use>") draws nothing, and
    /// moving the card onto it would move the card off the screen.
    static func isReadableReply(_ content: String) -> Bool {
        var visible = ""
        var rest = Substring(content)
        while let open = rest.range(of: "<tool_use") {
            visible += rest[rest.startIndex..<open.lowerBound]
            let after = rest[open.upperBound...]
            if let close = after.range(of: "</tool_use>") {
                rest = after[close.upperBound...]
            } else if let end = after.range(of: ">") {
                rest = after[end.upperBound...]
            } else {
                rest = after[after.endIndex...]
            }
        }
        visible += rest
        return ChatTranscriptPresentation.hasVisibleText(visible)
    }
}

enum ChatTranscriptPresentation {
    static func hasVisibleText(_ text: some StringProtocol) -> Bool {
        text.contains { !$0.isWhitespace }
    }
}

/// The mounted assistant bubble owns the only honest first-render boundary: a
/// non-empty final assistant bubble has become visible to the person using the
/// Mac app. The registry supplies correlation and claim-once behavior; this
/// type keeps eligibility/refusal observable without making a visual render
/// depend on telemetry delivery.
enum ChatFirstRenderTelemetry {
    enum Eligibility: Equatable, Sendable {
        case eligible(sessionID: String, turnID: String)
        case notAssistant
        case notLastAssistant
        case emptyContent
        case missingSessionID
        case missingTurnID
    }

    enum Outcome: Equatable, Sendable {
        case emitted(TurnTraceEvent)
        case ineligible(Eligibility)
        case noPendingTurn
    }

    static func eligibility(
        role: String,
        content: String,
        isLastAssistant: Bool,
        messageSessionID: String?,
        messageTurnID: String?,
        activeSessionID: String
    ) -> Eligibility {
        guard role == "assistant" else { return .notAssistant }
        guard isLastAssistant else { return .notLastAssistant }
        guard ChatTranscriptPresentation.hasVisibleText(content) else {
            return .emptyContent
        }
        // A present-but-blank message session is malformed; do not fall back
        // to the active tab and attach its first render to the wrong turn.
        let sessionID = messageSessionID ?? activeSessionID
        let cleanSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSessionID.isEmpty else { return .missingSessionID }
        guard let turnID = messageTurnID, !turnID.isEmpty else { return .missingTurnID }
        return .eligible(sessionID: cleanSessionID, turnID: turnID)
    }

    static func emit(
        eligibility: Eligibility,
        registry: TurnFirstRenderRegistry = .shared,
        bus: TurnTraceBus = .shared
    ) async -> Outcome {
        guard case .eligible(let sessionID, let turnID) = eligibility else {
            return .ineligible(eligibility)
        }
        guard let event = await registry.claimFirstRenderEvent(
            sessionId: sessionID,
            turnId: turnID,
            observedBy: "NativeAgentApp.MessageBubble"
        ) else {
            return .noPendingTurn
        }
        TurnTraceBus.fire(event, on: bus)
        return .emitted(event)
    }
}

enum ToolCallGroupPresentation {
    static func expandsInline(messages: [ChatMessage]) -> Bool {
        messages.contains { $0.metadata?.isPendingApproval == true }
    }
}

enum ChatAttachmentPresentation {
    static func partition(_ attachments: [PersistedAttachment]) -> (localImages: [PersistedAttachment], chips: [PersistedAttachment]) {
        let localImages = attachments.filter { attachment in
            attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
                && (attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        let chips = attachments.filter { attachment in
            !(attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
                && (attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false))
        }
        return (localImages, chips)
    }
}

/// The visible state for an image attachment that was persisted with a local
/// path. A load failure is distinct from the short loading placeholder: a
/// transcript must not silently turn an unreadable image into a blank bubble.
enum ChatLocalImageAttachmentPresentation {
    enum State: Equatable {
        case loading
        case loaded
        case unavailable
    }

    static func state(
        path: String?,
        hasLoadedImage: Bool,
        loadFailed: Bool
    ) -> State {
        let hasPath = path?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        guard hasPath else { return .unavailable }
        if hasLoadedImage { return .loaded }
        return loadFailed ? .unavailable : .loading
    }

    static func unavailableDetail(for attachment: PersistedAttachment) -> String {
        let name = attachment.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        return "Image attachment"
    }
}

// chat-smoothness phase 1 (2026-06-12): env-gated render-count instrumentation.
// NATIVE_AGENT_RENDER_AUDIT=1 dumps counters to stderr every 5s — the
// before/after proof for streaming render work. Zero cost when disabled.
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

// PATCH-2026-05-08: review-fix-r2 Memoize grouping so SwiftUI body redraws
// don't re-walk the whole message list. Cached by message-list identity
// (count + last id).
private final class _MessageGroupCache: @unchecked Sendable {
    static let shared = _MessageGroupCache()
    private struct StableKey: Equatable {
        var count: Int
        var lastID: String?
        var lastRole: String?
    }
    private struct Slot {
        var stableKey: StableKey
        var lastMessage: ChatMessage?
        /// 2026-09-06: `engine.transcripts.structureVersion` as of the
        /// compute. It replaces a total-content-byte count, which was both a
        /// walk of every row per render AND collision-prone: an interior row
        /// swapped for one of the same length, or changed only in its
        /// metadata, matched the key, the tail and the byte count, and the
        /// view kept stale groups. The version is bumped by every transcript
        /// write except the streaming delta, which the fast path below patches
        /// in place.
        var structureVersion: UInt64
        var groups: MessageGrouper.Projection
    }
    // chat-smoothness phase 1: one slot PER SESSION (FIFO-capped) — a detached
    // panel viewing another session must not thrash the active session's slot
    // back to O(n) recomputes every tick.
    private var slots: [String: Slot] = [:]
    private var slotOrder: [String] = []
    private let slotCap = 8
    private let lock = NSLock()
    // S.3: sessionId included in cache key to prevent cross-session collisions
    func groups(
        for messages: [ChatMessage],
        sessionId: String,
        structureVersion: UInt64
    ) -> MessageGrouper.Projection {
        // chat-smoothness phase 1: content.count lives OUTSIDE the stable key.
        // During streaming only the last bubble's content grows — the old
        // single key missed on EVERY delta tick, re-walking the whole list
        // ~20x/sec. Same shape + grown content now patches the cached last
        // group through a separate tail value instead.
        // Keep the token-rate discriminator structural. The former String key
        // interpolated the shape and then hashed the COMPLETE growing message
        // on every delta, turning one long reply into quadratic total hashing
        // work. The assistant patch below already replaces the exact tail row,
        // so neither a content hash nor an allocated composite key is needed.
        let stableKey = StableKey(
            count: messages.count,
            lastID: messages.last?.id,
            lastRole: messages.last?.role
        )
        lock.lock(); defer { lock.unlock() }
        // Fast path is assistant-only: only the streaming assistant bubble's
        // content ever grows in place, and _compute's visibility rules
        // (e.g. hiding "[tool:" system rows) can change with CONTENT for other
        // roles — patching those could keep a row _compute would now hide.
        if var slot = slots[sessionId],
           slot.stableKey == stableKey,
           slot.structureVersion == structureVersion {
            // The version proves every row but the last is the one this slot
            // was computed from, so an unchanged tail means an unchanged list.
            if slot.lastMessage == messages.last { return slot.groups }
            if let last = messages.last, last.role == "assistant",
               let lastGroup = slot.groups.last, !lastGroup.isToolGroup,
               lastGroup.messages.count == 1, lastGroup.messages[0].id == last.id {
                RenderAudit.bump("grouper.patch")
                var patched = lastGroup
                patched.messages[0] = last
                slot.groups.liveTail = patched
                slot.lastMessage = last
                slots[sessionId] = slot
                return slot.groups
            }
        }
        RenderAudit.bump("grouper.compute")
        let computed = MessageGrouper.Projection(base: MessageGrouper._compute(for: messages))
        if slots[sessionId] == nil {
            slotOrder.append(sessionId)
            if slotOrder.count > slotCap {
                slots.removeValue(forKey: slotOrder.removeFirst())
            }
        }
        slots[sessionId] = Slot(
            stableKey: stableKey,
            lastMessage: messages.last,
            structureVersion: structureVersion,
            groups: computed
        )
        return computed
    }
}

enum MessageGrouper {
    /// Historical groups stay shared and immutable while the streaming tail
    /// changes. Materializing a visible page copies at most that page, rather
    /// than triggering a copy of the entire cached array on every delta.
    struct Projection: RandomAccessCollection {
        let base: [MessageGroup]
        var liveTail: MessageGroup?

        var startIndex: Int { base.startIndex }
        var endIndex: Int { base.endIndex }

        subscript(position: Int) -> MessageGroup {
            if position == endIndex - 1, let liveTail { return liveTail }
            return base[position]
        }
    }

    static func groups(
        for messages: [ChatMessage],
        sessionId: String = "",
        structureVersion: UInt64
    ) -> [MessageGroup] {
        Array(projection(for: messages, sessionId: sessionId, structureVersion: structureVersion))
    }

    static func projection(
        for messages: [ChatMessage],
        sessionId: String = "",
        structureVersion: UInt64
    ) -> Projection {
        _MessageGroupCache.shared.groups(
            for: messages,
            sessionId: sessionId,
            structureVersion: structureVersion
        )
    }
    static func _compute(for messages: [ChatMessage]) -> [MessageGroup] {
        var result: [MessageGroup] = []
        var toolRun: [ChatMessage] = []
        func flushTools() {
            guard !toolRun.isEmpty else { return }
            // Stable id for the whole tool run (first tool's id) so appending a
            // new tool UPDATES the existing ToolCallGroup in place — letting the
            // live-flip transition animate — instead of recreating the view.
            result.append(MessageGroup(id: "toolrun-" + (toolRun.first?.id ?? UUID().uuidString), messages: toolRun, isToolGroup: true))
            toolRun = []
        }
        for msg in messages {
            // PATCH-2026-05-11: Change C — hide tool-summary system rows (role=system, content starts with "[tool:")
            // These are memory aids for compact_chat_history and should not render as chat bubbles.
            if msg.role == "system" && msg.content.hasPrefix("[tool:") { continue }
            if msg.role == "tool", msg.metadata?.interactionMirror == nil {
                toolRun.append(msg)
            } else if msg.metadata?.interactionMirror != nil {
                // A mirrored card is its own row, always, never folded into a tool run.
                flushTools()
                result.append(MessageGroup(id: msg.id, messages: [msg], isToolGroup: true))
            } else {
                flushTools()
                result.append(MessageGroup(id: msg.id, messages: [msg], isToolGroup: false))
            }
        }
        flushTools()
        // A row after an hour of quiet carries its time, so a morning message
        // never reads as the end of last night's reply.
        var previous: Date?
        for index in result.indices {
            let group = result[index]
            let first = group.messages.first.flatMap { UserDisplayFormatters.parseISOTimestamp($0.createdAt) }
            if let first, let previous, first.timeIntervalSince(previous) > quietGap {
                result[index].gapAbove = first
            }
            previous = group.messages.last.flatMap { UserDisplayFormatters.parseISOTimestamp($0.createdAt) } ?? previous
        }
        return result
    }

    static let quietGap: TimeInterval = 60 * 60
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

// ChatMessageListView kept for any remaining call sites outside the main list.
struct ChatMessageListView: View {
    var messages: [ChatMessage]
    // chat-smoothness phase 1: detached panels must pass their session id so
    // (a) the grouper cache keys correctly per session, and (b) the streaming
    // bubble takes the plain-Text branch (isLastAssistant) instead of pushing
    // transient growing prefixes through ChatMarkdownCache.
    var sessionId: String = ""
    /// True while THIS session is streaming a turn: the last assistant row is
    /// then the live tail. Callers that genuinely have no live state (the
    /// default) keep the old behaviour.
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
    /// 2026-09-06: the grouper cache keys on the transcript's mutation
    /// version, so the list needs the model, not just the rows it was handed.
    @Environment(AppModel.self) private var appModel

    /// Rows shown at once. User, 2026-09-04: the transcript is a plain VStack
    /// (no LazyVStack, no prefetch loop), so every shown row is resident —
    /// about 1.5 MB each with selectable text. A long thread shows its last
    /// `windowSize` rows and one row above them that reveals the next page.
    // Keep several screens available without making every scroll/layout
    // transaction carry hundreds of selectable message hierarchies. Earlier
    // and later pages plus search retain access to the complete transcript.
    nonisolated static let windowSize = 60
    @State private var pageAnchorID: String?
    @State private var pagedSearchID: String?
    @State private var revealedSessionId = ""

    /// Page by stable group identity, so appended replies do not move a reader
    /// browsing history. A new search selection centers its own bounded page.
    private func windowRange(for groups: MessageGrouper.Projection) -> Range<Int> {
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

    /// One ordinary transcript row, exactly as it was before the cards round:
    /// the scroll target id, the search highlight and the entrance transition
    /// all sit on the row the list lays out and scrolls to.
    @ViewBuilder
    private func bubbleRow(
        _ msg: ChatMessage, lastAssistantId: String?, tailId: String? = nil, liveTailId: String? = nil
    ) -> some View {
        Group {
            if msg.id == tailId {
                // 2026-09-14: the ONE row a streamed chunk may re-render. It
                // observes its own `ChatStreamingTailBox`; the parent list
                // observes structure only, so a token lays out this bubble
                // instead of all 300 rows. Everything below stays on the row,
                // so the scroll target, the highlight and the entrance are
                // exactly where they were. Fluid glass A1: the tail keeps this
                // view after the stream ends, so its settle can crossfade.
                StreamingTailBubble(
                    message: msg,
                    isLastAssistant: msg.role == "assistant" && msg.id == lastAssistantId,
                    isLive: msg.id == liveTailId
                )
            } else {
                MessageBubble(
                    message: msg,
                    isLastAssistant: msg.role == "assistant" && msg.id == lastAssistantId
                )
                // A streamed chunk rebuilds every row value; this is what stops
                // it from re-running every row's body (2026-09-13).
                .equatable()
            }
        }
        // Keep each message an independent accessibility container. Without
        // this boundary SwiftUI coalesces adjacent transcript text into one
        // enormous element, forcing clients to resolve the whole page's text
        // to inspect a single message. Containment preserves child links and
        // the bubble's named actions without altering visual layout.
        .accessibilityElement(children: .contain)
        .transcriptLayoutProbe(rowID: msg.id, kind: .bubble)
        .modifier(MacChatTranscriptSearchHighlight(
            isHighlighted: msg.id == highlightedMessageID
        ))
        .id(MacChatTranscriptSearch.scrollTargetID(for: msg.id))
        // phase 6: entrance animates ONLY when the append seam
        // (appendChatMessage) supplies a transaction; removals and
        // wholesale replaces are .identity → instant (no animated
        // teardown on the end-of-turn id swap or session switch).
        .transition(animatesArrival
            ? .asymmetric(
                insertion: NativeAgentMotion.arrival,
                removal: .identity)
            : .identity)
    }

    var body: some View {
        let lastAssistantId = messages.last(where: { $0.role == "assistant" })?.id
        let allGroups = MessageGrouper.projection(
            for: messages,
            sessionId: sessionId,
            structureVersion: appModel.engine.transcripts.structureVersion
        )
        let range = windowRange(for: allGroups)
        let hidden = range.lowerBound
        let groups = Array(allGroups[range])
        // Prose first, card under it as the handle (Agent, 2026-09-13).
        // Computed once per transcript structure, never per streamed chunk.
        // The live tail: the final row, while this session is streaming into
        // it. Only that row takes the leaf-observed path.
        let tailId = messages.last.flatMap { $0.role == "assistant" ? $0.id : nil }
        let liveTailId = isStreaming ? tailId : nil
        let cardMount = InlineCardMount.map(
            groups: groups,
            sessionId: sessionId,
            structureVersion: appModel.engine.transcripts.structureVersion
        )
        let relocatedRows = cardMount.relocated
        if hidden > 0 {
            ChatEarlierMessagesRow(hidden: hidden) {
                revealedSessionId = sessionId
                pagedSearchID = highlightedMessageID
                pageAnchorID = allGroups[max(0, range.lowerBound - Self.windowSize)].id
            }
        }
        ForEach(groups) { group in
            if let gapAbove = group.gapAbove {
                ChatQuietGapLine(date: gapAbove)
            }
            if group.isToolGroup {
                if group.messages.count == 1 {
                    let msg = group.messages[0]
                    if msg.metadata?.isPendingApproval == true {
                        InlineApprovalCard(message: msg)
                            .transcriptLayoutProbe(rowID: msg.id, kind: .approval)
                    } else if let mirrored = msg.metadata?.interactionMirror {
                        // A card raised in another thread, answered here on the original.
                        InteractionInboxCard(mirrorOf: .init(sessionID: mirrored.sessionID,
                                                             interactionID: mirrored.interactionID))
                            .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
                            .transcriptLayoutProbe(rowID: msg.id, kind: .approval)
                    } else if PersonaWriteReceiptRow.receipt(
                                for: msg, exemptTitle: appModel.firstConversationReceiptTitle
                              ) != nil {
                        // The first conversation's own line is the one piece of
                        // tool traffic that is a CONSEQUENCE the person should
                        // see without asking. It takes the settled receipt
                        // instead of the collapsed fold (Agent, 2026-09-15).
                        // Every other persona write keeps the quiet row.
                        PersonaWriteReceiptRow(
                            message: msg, exemptTitle: appModel.firstConversationReceiptTitle
                        )
                        .transcriptLayoutProbe(rowID: msg.id, kind: .toolRow)
                    } else {
                        ShellToolRow(messages: [msg])
                            .transcriptLayoutProbe(rowID: msg.id, kind: .toolRow)
                    }
                    // 0.4.12 cards round: an interaction that blocks this tool
                    // row appears HERE, under the row it belongs to, and never
                    // in a modal — unless the turn left a reply, in which case
                    // the card mounts under her words instead. With nothing
                    // injected this renders nothing and the transcript is
                    // exactly as it was.
                    if !relocatedRows.contains(msg.id) {
                        InlineCardsForRow(rowID: msg.id)
                    }
                } else {
                    ToolCallGroup(messages: group.messages)
                    .transcriptLayoutProbe(rowID: group.id, kind: .toolGroup)
                    // A card belongs to the ROW whose call raised it, not to
                    // the run that row happens to be collapsed into: the need
                    // is persisted on the blocked tool's own message, so the
                    // cards are asked for per message and appear under the
                    // group in the order their calls were made.
                    ForEach(group.messages) { member in
                        if !relocatedRows.contains(member.id) {
                            InlineCardsForRow(rowID: member.id)
                        }
                    }
                }
            } else {
                let msg = group.messages[0]
                // 2026-09-14: only a row that ACTUALLY hosts a card gets the
                // wrapper. Wrapping every row put a VStack and an empty ForEach
                // around all 300 of them on every streamed chunk, and moved the
                // scroll id and the transition off the row the list follows —
                // which is why the transcript stopped riding the stream and the
                // working card landed under the composer.
                if let hosted = cardMount.byHost[msg.id], !hosted.isEmpty {
                    VStack(alignment: .leading, spacing: NativeAgentShellLayout.transcriptGap) {
                        bubbleRow(msg, lastAssistantId: lastAssistantId, tailId: tailId, liveTailId: liveTailId)
                        // The handle, directly under what she just said: same
                        // leading edge, the transcript's one gap, nothing that
                        // reads as an interruption.
                        ForEach(hosted, id: \.self) { rowID in
                            InlineCardsForRow(rowID: rowID)
                        }
                    }
                } else {
                    bubbleRow(msg, lastAssistantId: lastAssistantId, tailId: tailId, liveTailId: liveTailId)
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

// PATCH-2026-05-08: wave2-chat-ux — collapsible tool-call group for consecutive tool messages
struct ToolCallGroup: View {
    @Environment(AppModel.self) private var appModel
    var messages: [ChatMessage]

    // An unresolved approval must never be hidden behind a collapsed summary.
    private var hasPendingApproval: Bool {
        ToolCallGroupPresentation.expandsInline(messages: messages)
    }

    var body: some View {
        // 2026-09-25: each phase swaps in place on one line that takes the new
        // row's size, so they never overlap. An approval list leaves at once.
        // While she works, this is the settled fold already: the turn card is
        // the one live surface (p3-voice, 2026-10-07).
        ChatCrossfadeStack(current: hasPendingApproval ? 0 : 1) {
            phaseBody
        }
    }

    @ViewBuilder
    private var phaseBody: some View {
        if hasPendingApproval {
            fullList
                .layoutValue(key: ChatCrossfadePhase.self, value: 0)
                .transition(.identity)
        } else {
            // ui-simplify 2026-09-02: one quiet row for the whole turn's tool
            // traffic — tools and skills together — instead of two collapsed
            // boxes of raw tool names.
            //
            // 2026-09-15: except a persona write, which is a consequence rather
            // than traffic and is lifted out of the fold into its own settled
            // receipt. The remaining traffic keeps the quiet row, and a turn
            // whose only tool call was the write shows the receipt alone.
            let exemptTitle = appModel.firstConversationReceiptTitle
            let receipts = messages.filter {
                PersonaWriteReceiptRow.receipt(for: $0, exemptTitle: exemptTitle) != nil
            }
            let rest = messages.filter {
                PersonaWriteReceiptRow.receipt(for: $0, exemptTitle: exemptTitle) == nil
            }
            VStack(alignment: .leading, spacing: NativeAgentShellLayout.transcriptGap) {
                if !rest.isEmpty {
                    ShellToolRow(messages: rest)
                }
                ForEach(receipts) { message in
                    PersonaWriteReceiptRow(message: message, exemptTitle: exemptTitle)
                }
            }
            .layoutValue(key: ChatCrossfadePhase.self, value: 1)
            .transition(NativeAgentMotion.fadeThrough)
        }
    }

    private var fullList: some View {
        VStack(alignment: .leading, spacing: NativeAgentShellLayout.transcriptGap) {
            ForEach(messages) { msg in
                if msg.metadata?.isPendingApproval == true {
                    InlineApprovalCard(message: msg)
                } else {
                    ToolPillView(message: msg)
                }
            }
        }
    }
}

// PATCH-2026-05-09: chat-ux-polish — polished MessageBubble
// User: purple→pink gradient, white text, rounded-right corners
// Assistant: glass-card style, soft border, primary text
// Hover actions: copy, regenerate (last assistant only), read aloud
// chat-smoothness phase 1 (2026-06-12): finished bubbles re-parsed their
// markdown on EVERY body re-evaluation — during streaming that's every
// visible bubble, every coalesce tick. Parse once per content string;
// FIFO-evict to bound memory. Thread-safe (bubbles render on main, but the
// cache shouldn't care).
final class ChatMarkdownCache: @unchecked Sendable {
    static let shared = ChatMarkdownCache()
    private let cache = ChatContentCache<AttributedString>()

    static func attributed(_ content: String) -> AttributedString? {
        shared._attributed(content)
    }

    private func _attributed(_ content: String) -> AttributedString? {
        if let hit = cache.lookup(content) {
            return hit
        }
        RenderAudit.bump("markdown.parse")
        guard let parsed = Self.parse(content) else { return nil }
        cache.insertIfAbsent(parsed, for: content)
        return parsed
    }

    /// The parse itself, uncached. The live reply streams through this: its
    /// last paragraph grows every frame and must not fill the cache.
    static func parse(_ content: String) -> AttributedString? {
        guard let raw = try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
        // Untrusted content: drop live links for any scheme outside the
        // allowlist before the string is ever handed to a Text view.
        return ChatLinkPolicy.sanitized(raw)
    }

    /// What Copy puts on the clipboard: the words as the bubble draws them,
    /// so a pasted reply carries no `**` (fenced code stays as written).
    static func plainText(_ content: String) -> String {
        ChatRichContentCache.blocks(content).map { block in
            switch block {
            case .prose(let text): attributed(text).map { String($0.characters) } ?? text
            case .code(_, let code): code
            }
        }.joined(separator: "\n\n")
    }
}

/// Wave 3 (Grok's rhythm): a blank line between paragraphs is drawn as the
/// stream's gap (line spacing + `StreamingParagraphText.paragraphGap`) inside
/// one `Text`, not as a whole empty line. The empty paragraph gets an exact
/// height of `paragraphGap - lineSpacing`, so with the line spacing above and
/// below it the break measures what the stream's stack does (measured with
/// ImageRenderer: equal heights at spacing 8 and 2, wrapped or not); extra
/// blank lines collapse, as they do in the stream. Cached per content and
/// spacing, like the parse.
enum ChatParagraphGap {
    private static let cache = ChatContentCache<AttributedString>()

    static func applied(_ parsed: AttributedString, content: String, lineSpacing: CGFloat) -> AttributedString {
        guard content.contains("\n\n") else { return parsed }
        let key = "\(lineSpacing)|" + content
        if let hit = cache.lookup(key) { return hit }
        var out = parsed
        // Character offsets of each run of 2+ newlines, last first, so an
        // edit never moves an offset still to be visited.
        var runs: [(start: Int, count: Int)] = []
        var offset = 0
        var runStart = -1
        for character in out.characters {
            if character == "\n" {
                if runStart < 0 { runStart = offset }
            } else {
                if runStart >= 0, offset - runStart >= 2 { runs.append((runStart, offset - runStart)) }
                runStart = -1
            }
            offset += 1
        }
        if runStart >= 0, offset - runStart >= 2 { runs.append((runStart, offset - runStart)) }
        let height = max(0, StreamingParagraphText.paragraphGap - lineSpacing)
        for run in runs.reversed() {
            let blank = out.characters.index(out.startIndex, offsetBy: run.start + 1)
            let afterBlank = out.characters.index(after: blank)
            if run.count > 2 {
                out.removeSubrange(afterBlank..<out.characters.index(out.startIndex, offsetBy: run.start + run.count))
            }
            out[blank..<out.characters.index(after: blank)].lineHeight = .exact(points: height)
        }
        cache.insertIfAbsent(out, for: key)
        return out
    }
}

// Render-cost audit F10 — process-wide attachment image cache.
//
// The 2026-07-21 fix (decode cached in `@State`, read detached) is correct but
// the cache is per-VIEW-INSTANCE: `LazyVStack` recycling (scroll away and back)
// and tab teardown (`ContentView.swift`'s detail `switch` destroys the Chat
// tree on leave) both re-read the file from disk and re-decode it. This is the
// shared tier, mirroring `ChatMarkdownCache`'s shape.
//
// BOUNDED BY BYTES, NOT ENTRY COUNT. `NSCache.totalCostLimit` with a cost of
// decoded pixel bytes — an entry cap would let a handful of large screenshots
// hold hundreds of MB while a hundred thumbnails held almost nothing.
//
// SAME PIXELS. The full-size `NSImage` is cached exactly as decoded; there is
// no downsample to the 360 pt display size (that would be a visible change and
// is deliberately out of scope). A hit returns the identical object the miss
// path would have produced from the same bytes.
//
// KEY = FILE IDENTITY, NOT PATH. Keying on path alone would serve stale pixels
// if a file is rewritten in place. The key carries size + modification time, so
// changed bytes miss. The stat is one syscall on a hit, versus a full read +
// decode before.
final class ChatImageCache: @unchecked Sendable {
    static let shared = ChatImageCache()

    private let cache = NSCache<NSString, NSImage>()
    /// ~96 MB of decoded pixels. Well under what a chat with a few screenshots
    /// needs, and `NSCache` also evicts under memory pressure on its own.
    private static let byteBudget = 96 * 1024 * 1024

    private init() {
        cache.totalCostLimit = Self.byteBudget
    }

    /// Identity of the file at `url` — nil when it cannot be stat'd (the caller
    /// then skips the cache entirely rather than caching under a guessed key).
    /// Safe to call off the main actor.
    static func identityKey(for url: URL) -> String? {
        // stat-strength identity (gpt-5.5 wave-2 NEEDS_FIX): Date+size
        // misses a same-second or metadata-preserving rewrite; dev+inode+
        // size+mtime_ns matches the Desk/transcript memo stamps.
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(url.path)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    static func image(forKey key: String) -> NSImage? {
        shared.cache.object(forKey: key as NSString)
    }

    static func store(_ image: NSImage, forKey key: String) {
        shared.cache.setObject(image, forKey: key as NSString, cost: pixelByteCost(image))
    }

    /// Decoded pixel bytes at 4 bytes/pixel. Prefers the largest bitmap rep's
    /// true pixel dimensions (which differ from `size` on Retina assets); falls
    /// back to point size for vector/unknown reps. Floored at 1 so a degenerate
    /// image can never be a zero-cost entry that `NSCache` keeps forever.
    static func pixelByteCost(_ image: NSImage) -> Int {
        var pixels = 0
        for rep in image.representations {
            pixels = max(pixels, rep.pixelsWide * rep.pixelsHigh)
        }
        if pixels == 0 {
            pixels = Int(max(0, image.size.width) * max(0, image.size.height))
        }
        return max(1, pixels * 4)
    }
}

/// The production image read/decode/cache seam used by transcript bubbles.
/// It is synchronous by design so callers can move the whole disk operation
/// off the render actor; it never fabricates a thumbnail when the bytes cannot
/// be read or decoded.
enum ChatLocalImageAttachmentLoader {
    static func cachedImage(forKey key: String?) -> NSImage? {
        guard let key else { return nil }
        return ChatImageCache.image(forKey: key)
    }

    static func readData(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Longest side of a decoded transcript image, in pixels. The bubble shows
    /// it in a 360 pt box, so 720 px is exactly 2× and sharp on every Mac
    /// display; a 2560-wide screenshot decoded whole is 15 MB of pixels the
    /// frame never shows. User, 2026-09-04: the transcript is a plain VStack
    /// now, so every image row in a thread decodes at open; thirty screenshots
    /// at 1440 px measured 141 MB of raster, at 720 px a quarter of that.
    static let maxDecodedPixelSize = 720

    static func decode(_ data: Data, cacheKey: String?) -> NSImage? {
        guard let image = decodeBounded(data) ?? NSImage(data: data) else { return nil }
        if let key = cacheKey { ChatImageCache.store(image, forKey: key) }
        return image
    }

    /// Decodes through ImageIO at `maxDecodedPixelSize`, keeping the point size
    /// the full image would have had so layout does not move. Returns nil when
    /// ImageIO cannot read the bytes, and the caller falls back to `NSImage`.
    private static func decodeBounded(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let full = NSImage(data: data)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDecodedPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: full.size)
    }

    static func load(at url: URL) -> NSImage? {
        let key = ChatImageCache.identityKey(for: url)
        if let cached = cachedImage(forKey: key) {
            return cached
        }
        guard let data = readData(at: url) else { return nil }
        return decode(data, cacheKey: key)
    }
}

struct MessageBubble: View {
    var message: ChatMessage
    /// Whether this is the last assistant message in the list (enables Regenerate action)
    var isLastAssistant: Bool = false

    /// The drawn-field gate for `.equatable()` at the call site.
    ///
    /// User, 2026-09-13, "the whole app has to feel snappy": a streamed chunk
    /// republishes the whole `[ChatMessage]`, so the transcript rebuilds every
    /// row value per tick. Without an explicit `==` SwiftUI falls back to the
    /// synthesized whole-struct compare, which walks `ChatMessageMetadata?` —
    /// forty-odd optional Strings plus the optional's copy/destroy — for every
    /// settled row, and then re-ran every body anyway. `/usr/bin/sample`
    /// during one streamed reply: hundreds of main-thread samples in
    /// `ChatMessage.__derived_struct_equals` and
    /// `outlined init with copy of ChatMessageMetadata?`, 251 in
    /// `MessageBubble.body`.
    ///
    /// This compares exactly what the row draws. Every field listed here is
    /// read somewhere in `bubbleBody`, `messageProvenance`, the hover line
    /// (`brainLine`) or the failure line; the rest of the metadata envelope (tool plumbing, approval
    /// ids, before/after diffs) belongs to the tool rows, not to this view. A
    /// field added to the bubble must be added here too, or the row will keep
    /// drawing the old value.
    nonisolated static func drawsTheSame(_ l: ChatMessage, _ r: ChatMessage) -> Bool {
        guard l.id == r.id,
              l.role == r.role,
              l.createdAt == r.createdAt,
              l.sessionId == r.sessionId,
              l.source == r.source,
              l.content == r.content
        else { return false }
        guard let lm = l.metadata else { return r.metadata == nil }
        guard let rm = r.metadata else { return false }
        return lm.origin == rm.origin
            && lm.error == rm.error
            && lm.partial == rm.partial
            && lm.cancelled == rm.cancelled
            && lm.model == rm.model
            && lm.requestedModel == rm.requestedModel
            && lm.reasoningEffort == rm.reasoningEffort
            && lm.fileAccessMode == rm.fileAccessMode
            && lm.attachments == rm.attachments
            && lm.workingCommentaryChars == rm.workingCommentaryChars
            && lm.providerRefusal == rm.providerRefusal
            && lm.providerRefusalDraft == rm.providerRefusalDraft
            && lm.envelope == rm.envelope
    }

    /// The mind a reply ran on — model / effort / access — said on hover
    /// beside its time, never in the reading line.
    /// Each recorded field stands on its own; a model that was only asked
    /// for says so rather than passing as the one that ran.
    nonisolated static func brainLine(_ metadata: ChatMessageMetadata?) -> String? {
        guard let metadata else { return nil }
        let model = metadata.model ?? metadata.requestedModel.map { "requested \($0)" }
        let fields = [model, metadata.reasoningEffort, metadata.fileAccessMode]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return fields.isEmpty ? nil : fields.joined(separator: " / ")
    }

    @State private var voiceOutput = VoiceOutputController.sharedMessagePlayback
    @Environment(AppModel.self) private var appModel
    /// True in the offscreen copy a quiet page read mounts. Nothing here is on
    /// anybody's screen, so nothing here may claim a render the person made.
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.troubleCardOwnsRetry) private var troubleCardOwnsRetry
    /// Set when a retry of this failed turn could repeat a real action.
    @State private var retryConfirmation: ChatTurnFailure?
    @State private var showJSONSheet = false
    @State private var bubbleToast: String? = nil
    @State private var isHovered = false
    /// The hover bar hangs below the row's own frame, so the pointer on it is
    /// tracked separately.
    @State private var isBarHovered = false
    private var showsHoverBar: Bool { isHovered || isBarHovered }
    /// Third pass, item 3: the settled reply's working commentary starts folded.
    @State private var commentaryExpanded = false
    /// Fluid glass A1: keeps the stream on screen for the one frame between
    /// the turn settling and the animated swap to the settled reply.
    @State private var holdsLive = false

    /// Her reply is still arriving into this row. A turn that has reached
    /// its terminal phase is not, even while the runtime marker lingers for
    /// the post-turn bookkeeping: the terminal reduce clears
    /// `replyTextSettled`, so `isStreaming` alone flipped a settled reply back
    /// to raw text until the marker cleared.
    private var isLiveReply: Bool {
        guard isLastAssistant, message.role == "assistant" else { return false }
        let sessionId = message.sessionId ?? appModel.activeChatSessionId
        let turns = appModel.engine.turns
        return turns.isStreaming(sessionId)
            && turns.lifecycle(for: sessionId)?.presentation.isTerminal != true
    }

    private var normalizedRole: String {
        message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private var isUser: Bool { normalizedRole == "user" }
    private var speechOwnerID: String {
        "message:\(message.sessionId ?? "unknown"):\(message.id)"
    }
    private var isReadingThisMessage: Bool {
        voiceOutput.isSpeaking(ownerID: speechOwnerID)
    }

    private var messageProvenance: MacChatMessageProvenance? {
        MacChatMessageProvenance.make(
            role: message.role,
            source: message.source,
            origin: message.metadata?.origin
        )
    }
    // ui-simplify 2026-09-02 (Lane A): her replies are prose, not chat
    // furniture — plain text at 16pt on a 1.6 line height inside 600pt, with
    // the user's own words in one soft bubble opposite.
    private var userCorners: RectangleCornerRadii { NativeAgentShellLayout.userBubbleCorners }

    /// The bridge writes `[from: claude, via bridge] …` into the message body
    /// so downstream consumers can see the route. That is plumbing: the room
    /// shows the text and puts the route in a small tag above it. The
    /// out-of-band provenance badge (MacChatMessageProvenance) is unchanged and
    /// remains the trust signal — this tag is only the friendly restatement.
    /// 2026-09-06: provenance, not syntax, decides. A quoted routing prefix in
    /// a message the person typed used to buy the sender's seat and silence the
    /// trust badge.
    private var isBridgeRouted: Bool {
        ChatShellConversationRow.isBridgeRouted(message.metadata?.origin)
    }

    private var isPeerBridgeMessage: Bool {
        // Peers and helpers both speak in the person's seat only by transport.
        isUser && ["agent-bridge", "bot"].contains(message.metadata?.origin?.surface?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    private var bridgeTag: String? {
        guard isUser, isBridgeRouted, !isPeerBridgeMessage else { return nil }
        return ChatShellConversationRow.bridgeAgentTag(message.content)
    }

    /// Agent, 2026-09-02: a bridge message is another AGENT talking. It
    /// carries the user role only because that is the seat the runtime hands
    /// an inbound turn — it was never User. Rendering it in the right-hand
    /// bubble put Claude's and Codex's words in User's seat, so the room read
    /// as though he had said them. User's seat is User's only.
    private var isBridgeMessage: Bool { bridgeTag != nil || isPeerBridgeMessage }

    /// Which side of the room this message sits on. Only the human's own
    /// words take the right.
    private var seatsRight: Bool { isUser && !isBridgeMessage }

    /// A bridge message renders on the left and QUIETER than her replies:
    /// smaller, secondary, and with no bubble behind it, so it reads as
    /// traffic passing through the room rather than as either voice in it.
    private var isQuietBridge: Bool { isBridgeMessage }

    private var displayContent: String {
        if isPeerBridgeMessage {
            return SimpleViewStore.bridgedText(message.content)
        }
        guard isBridgeRouted,
              ChatShellConversationRow.hasBridgePrefix(message.content)
        else {
            return message.content
        }
        return ChatShellConversationRow.stripBridgePrefix(message.content)
    }

    var body: some View {
        // Agent, 2026-09-02: a worker's completion envelope is a note to her,
        // not a conversation for User. It folds like tools.
        // 2026-09-06: `isBridgeRouted` for the same reason as `bridgeTag` — a
        // person who quotes a routing slip must not have their own message
        // folded away into a worker receipt.
        if isUser, isBridgeRouted, ChatShellEnvelope.isEnvelope(message.content, envelope: message.metadata?.envelope) {
            ShellEnvelopeRow(content: message.content)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            bubbleBody
        }
    }

    @ViewBuilder
    private var bubbleBody: some View {
        let _ = RenderAudit.bump("bubble.body")
        // One immutable projection per bubble pass. These were four separate
        // computed-property reads, each of which partitioned the full
        // attachment array twice. The streaming tail also built a trimmed copy
        // of the entire growing reply merely to test for visible content.
        let attachments = ChatAttachmentPresentation.partition(
            message.metadata?.attachments ?? []
        )
        let hasVisibleContent = ChatTranscriptPresentation.hasVisibleText(displayContent)
        let timestamp = UserDisplayFormatters.chatTimestamp(message.createdAt)
        let bubbleHPad: CGFloat = seatsRight ? 16 : 0
        HStack(alignment: .bottom, spacing: NativeAgentSpacing.sm) {
            if seatsRight { Spacer(minLength: 60) }

            VStack(alignment: seatsRight ? .trailing : .leading, spacing: NativeAgentSpacing.xs) {
                if let bridgeTag {
                    // The one word that says who is speaking is not the
                    // faintest thing on the page (Agent, 2026-09-02).
                    Text(bridgeTag)
                        .font(ShellType.labelSemibold)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .accessibilityLabel("From \(bridgeTag), through the bridge")
                }
                // 658.14 session provenance. A user row that did not come from
                // the human at this Mac says so, durably and above the bubble,
                // so scrollback is readable as a trust boundary and not just as
                // prose. The label set is closed (MacChatMessageProvenance) —
                // no recorded string is ever interpolated into this view.
                if isUser, bridgeTag == nil, let provenance = messageProvenance {
                    HStack(spacing: NativeAgentSpacing.xs) {
                        Image(systemName: provenance.symbol)
                        Text(provenance.label)
                    }
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(provenance.isAutomated ? Color.orange : Color.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Message origin: \(provenance.label)")
                }

                // Message content bubble
                VStack(alignment: seatsRight ? .trailing : .leading, spacing: NativeAgentSpacing.sm) {
                    // A live reply mounts its paced text while still empty, so
                    // the first words pace in instead of arriving as a mount.
                    if hasVisibleContent || isLiveReply {
                        renderedMessageText
                    } else if attachments.localImages.isEmpty && attachments.chips.isEmpty {
                        Text(" ")
                    }
                    ForEach(attachments.localImages, id: \.id) { attachment in
                        MessageLocalImageAttachmentView(attachment: attachment)
                    }
                    ForEach(attachments.chips, id: \.id) { attachment in
                        MessageAttachmentChipView(attachment: attachment)
                    }
                }
                    // User, 2026-09-03: her replies at 16 regular read soft
                    // next to the 13 medium of a bridge note. Medium is what
                    // stays crisp on glass; 15 keeps hers the larger voice.
                    // User, 2026-09-03: "chonky lettering". The cause was
                    // macOS font smoothing (stem darkening), which the app now
                    // turns off for itself at launch, the way Chromium apps
                    // draw; regular weight reads crisp without it.
                    .font(isQuietBridge ? ShellType.label : ShellType.body)
                    .textSelection(.enabled)
                    .lineSpacing(bubbleLineSpacing)
                    .padding(.horizontal, bubbleHPad)
                    .padding(.vertical, seatsRight ? 12 : NativeAgentSpacing.xs)
                    .modifier(UserBubbleSurface(seatsRight: seatsRight, corners: userCorners))
                    // The cap comes after the fill so the bubble hugs short
                    // text; the padding is added back so long text still
                    // wraps at the same width.
                    .frame(
                        maxWidth: (seatsRight
                                ? NativeAgentShellLayout.userBubbleMaxWidth
                                : NativeAgentShellLayout.replyMaxWidth)
                            + 2 * bubbleHPad,
                        alignment: seatsRight ? .trailing : .leading
                    )
                    .foregroundStyle(isQuietBridge ? NativeAgentShell.secondary : NativeAgentShell.text)
                    .contextMenu {
                        // PATCH-2026-06-06: chat-upgrades — message-level actions
                        Button {
                            ChatClipboard.copy(ChatMarkdownCache.plainText(message.content))
                            showBubbleToast("Copied")
                        } label: { Label("Copy text", systemImage: "doc.on.doc") }

                        Button {
                            ChatClipboard.copy(ChatExportService.messageMarkdown(message))
                            showBubbleToast("Copied as Markdown")
                        } label: { Label("Copy as Markdown", systemImage: "doc.richtext") }

                        if !isUser {
                            Button {
                                toggleReadAloud()
                            } label: {
                                Label(isReadingThisMessage ? "Stop reading" : "Read aloud", systemImage: isReadingThisMessage ? "speaker.slash" : "speaker.wave.2")
                            }
                        }

                        if !isUser && isLastAssistant && message.metadata?.providerRefusal != true {
                            Button {
                                requestRetry()
                            } label: {
                                Label("Regenerate response", systemImage: "arrow.clockwise")
                            }
                        }

                        Divider()

                        Button {
                            Task {
                                showBubbleToast(await appModel.addMemoryFact(message.content).userMessage)
                            }
                        } label: { Label("Remember this", systemImage: "brain") }

                        Divider()

                        Button { showJSONSheet = true } label: {
                            Label("Show message data", systemImage: "curlybraces")
                        }
                    }
                // The room's trouble card carries Retry for a failed turn; the
                // bubble keeps it for a stopped turn and in detached panels.
                if !isUser, isLastAssistant,
                   !(troubleCardOwnsRetry && ChatShellTroubleState.isFailed(message)),
                   (message.metadata?.providerRefusalDraft == true
                    || (message.metadata?.providerRefusal != true && messageNeedsRetry)) {
                    Button {
                        requestRetry()
                    } label: {
                        Label(message.metadata?.providerRefusalDraft == true ? "Retry draft" : "Try again", systemImage: "arrow.clockwise")
                            .font(NativeAgentFont.label)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Bubble-local toast
                if let bt = bubbleToast {
                    NoticePill(text: bt)
                        .transition(NativeAgentMotion.reveal())
                }

            }
            // Hover must be LAYOUT-NEUTRAL (User, 2026-07-25): a row that
            // appears on hover changes the bubble's height, and every scroll
            // strategy shows that as a hop. Agent, 2026-09-02, named twice:
            // the bar must never land on words. Fluid glass A2: so it is an
            // overlay, not a reserved 30pt strip under every message — it
            // fades in over this message's bottom edge (a few points of its
            // padding) and hangs into the gap below, with the timestamp beside
            // it. Raised over the next row while it shows (zIndex below).
            .overlay(alignment: seatsRight ? .bottomTrailing : .bottomLeading) {
                if showsHoverBar {
                    HStack(spacing: NativeAgentSpacing.sm) {
                        if seatsRight { hoverTimestamp(timestamp) }
                        hoverBar
                            // The bar hangs below the row's own hover region;
                            // holding it keeps it.
                            .onHover { hovering in
                                withAnimation(NativeAgentMotion.quick) { isBarHovered = hovering }
                            }
                        if !seatsRight { hoverTimestamp(timestamp) }
                    }
                    .offset(y: NativeAgentShellLayout.hoverBarStrip - NativeAgentShellLayout.hoverBarOverlap)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
            .frame(
                maxWidth: NativeAgentShellLayout.roomColumn,
                alignment: seatsRight ? .trailing : .leading
            )
            .sheet(isPresented: $showJSONSheet) { MessageJSONSheet(message: message) }
            // User, 2026-09-02: the whole column, gaps included, is the hover
            // region, so moving the pointer from the words down onto the bar
            // keeps the bar; leaving the message anywhere drops it.
            // ...and reaches down over the hanging bar, so its buttons take clicks.
            .contentShape(HoverBarReach(below: NativeAgentShellLayout.hoverBarStrip - NativeAgentShellLayout.hoverBarOverlap))
            .onHover { hovering in
                withAnimation(NativeAgentMotion.quick) { isHovered = hovering }
            }

            if !seatsRight { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: seatsRight ? .trailing : .leading)
        // The hover bar hangs over the top edge of the next row; draw this
        // row above its neighbours while it shows.
        .zIndex(showsHoverBar ? 1 : 0)
        .animation(NativeAgentMotion.quick, value: bubbleToast)
        .modifier(MessageBubbleAccessibilityActions(
            isUser: isUser,
            isLastAssistant: isLastAssistant && message.metadata?.providerRefusal != true,
            onCopy: {
                ChatClipboard.copy(ChatMarkdownCache.plainText(message.content))
                showBubbleToast("Copied")
            },
            onReadAloud: toggleReadAloud,
            onRegenerate: {
                requestRetry()
            }
        ))
        .modifier(FailedTurnRetryConfirmation(
            failure: $retryConfirmation,
            onRetry: { Task { await appModel.regenerateAssistantMessage(message) } },
            onContinue: { Task { await appModel.continueFailedTurn(message) } }
        ))
        .onAppear { emitFirstRenderIfNeeded() }
        .onChange(of: hasVisibleContent) { emitFirstRenderIfNeeded() }
        // Read-aloud failures (trust denied / not configured / auth rejected)
        // land in voiceOutput.errorMessage, which nothing else reads — surface
        // them in the bubble toast. Cleared after showing so a repeat failure
        // re-fires.
        .onChange(of: voiceOutput.errorMessage) {
            if let msg = voiceOutput.consumeError(ownerID: speechOwnerID) {
                showBubbleToast(msg)
            }
        }
    }

    /// When and on which brain, beside the hover bar. Agent, 2026-09-03: the
    /// shell's secondary token, not SwiftUI's hierarchical fade, which
    /// measured 1.86:1 on the light room. It yields to the bubble toast, the
    /// one the person just triggered.
    private func hoverTimestamp(_ timestamp: String) -> some View {
        Text([timestamp, isUser ? nil : Self.brainLine(message.metadata)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(ShellType.caption)
            .lineLimit(1)
            .foregroundStyle(NativeAgentShell.secondary)
            .opacity(bubbleToast == nil ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// The per-message actions, overlaid on the message's bottom edge.
    private var hoverBar: some View {
        BubbleHoverBar(
            message: message,
            isLastAssistant: isLastAssistant && message.metadata?.providerRefusal != true,
            onCopy: {
                ChatClipboard.copy(ChatMarkdownCache.plainText(message.content))
                showBubbleToast("Copied")
            },
            onRegenerate: {
                requestRetry()
            },
            onReadAloud: {
                toggleReadAloud()
            }
        )
    }

    private func showBubbleToast(_ text: String) {
        withAnimation(NativeAgentMotion.standard) { bubbleToast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(NativeAgentMotion.standard) { bubbleToast = nil }
        }
    }

    private func toggleReadAloud() {
        if isReadingThisMessage {
            voiceOutput.stop()
            return
        }
        Task {
            await voiceOutput.speak(
                text: message.content,
                trust: appModel.engine.trust,
                ownerID: speechOwnerID
            )
        }
    }

    private func emitFirstRenderIfNeeded() {
        // Nobody is looking at this copy. A quiet read mounts the real bubble
        // offscreen, and claiming the "the person saw it" event from there
        // spends the receipt the window's own first render was going to claim.
        guard !quietOffscreenRead else { return }
        let eligibility = ChatFirstRenderTelemetry.eligibility(
            role: message.role,
            content: message.content,
            isLastAssistant: isLastAssistant,
            messageSessionID: message.sessionId,
            messageTurnID: message.metadata?.turnTraceId,
            activeSessionID: appModel.activeChatSessionId
        )
        guard case .eligible = eligibility else { return }
        Task {
            _ = await ChatFirstRenderTelemetry.emit(eligibility: eligibility)
        }
    }

    @ViewBuilder
    private var renderedMessageText: some View {
        // PATCH-2026-05-13: parallel-sessions — check streaming on the
        // message's own session, not the active session, so an in-flight
        // bubble in a non-active session still renders correctly when the
        // user switches back to view it.
        // Cheap row-local checks first (2026-09-22): only the tail bubble may
        // observe `streamingSessions`, or every row re-renders per turn.
        if isLastAssistant && message.role == "assistant" {
            // Fluid glass A1: her last reply swaps phases in place — streamed,
            // settled, settled with its notes folded — and each swap
            // crossfades instead of reflowing in one frame. The stack takes
            // the incoming phase's size, and the swap runs in one animated
            // transaction (below), so the height eases and a transcript
            // pinned to the bottom rides it.
            let live = isLiveReply || holdsLive
            let split: (commentary: String?, answer: String) = live ? (nil, "") : workingCommentarySplit
            let phase = live ? 0 : (split.commentary == nil ? 1 : 2)
            ChatCrossfadeStack(current: phase) {
                if live {
                    // Streaming skips the block split and the cache: the
                    // in-flight bubble changes on every coalesce tick. Each
                    // paragraph takes the settled reply's inline parse
                    // (2026-10-07), so `**` never shows and nothing snaps
                    // to bold at the settle.
                    //
                    // User, 2026-09-13 ("still a little bumpy"): and it is
                    // greedy while it streams. Without this the bubble HUGS
                    // its text, so the row's WIDTH was re-derived from the
                    // growing string on every chunk and every stack above it
                    // re-laid out to match. Greedy inside the enclosing
                    // `replyMaxWidth` cap pins the width at min(column, cap)
                    // from the first token — the same width the settled reply
                    // wraps at — so a chunk changes the height only. Glyphs do
                    // not move when the box shrinks to hug at settle: the text
                    // is leading-aligned and there is no bubble fill on a reply.
                    PacedStreamingText(text: displayContent, inline: ChatInlineMarkdown(ChatMarkdownCache.parse))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutValue(key: ChatCrossfadePhase.self, value: 0)
                        .transition(NativeAgentMotion.replyDissolve)
                } else if let commentary = split.commentary {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                        workingCommentaryFold(commentary)
                        settledContent(split.answer)
                    }
                    .layoutValue(key: ChatCrossfadePhase.self, value: 2)
                    .zIndex(2)
                    .transition(NativeAgentMotion.replyDissolve)
                } else {
                    settledContent(split.answer)
                        .layoutValue(key: ChatCrossfadePhase.self, value: 1)
                        .zIndex(1)
                        .transition(NativeAgentMotion.replyDissolve)
                }
            }
            // One frame late on purpose: the settle re-renders this row still
            // showing the stream, and the swap then runs inside
            // `withAnimation`, which is what lets the height change ease in
            // the rows and the scroll view around it, not only in here. The
            // notes fold arrives in its own animated write
            // (`setChatMessageWorkingCommentary`).
            .onChange(of: isLiveReply, initial: true) { _, now in
                if now {
                    holdsLive = true
                } else if holdsLive {
                    withAnimation(NativeAgentMotion.arrive) { holdsLive = false }
                }
            }
        } else {
            // Item 3 (third conversation pass): a multi-round turn persists the
            // narration it spoke before each tool round followed by its answer.
            // Every byte is still here — the commentary just starts folded, so
            // the settled bubble leads with the answer instead of with "I'll
            // check… now I'll read…". Single-round turns take the same path
            // they always did.
            let split = workingCommentarySplit
            if let commentary = split.commentary {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    workingCommentaryFold(commentary)
                    settledContent(split.answer)
                }
            } else {
                settledContent(split.answer)
            }
        }
    }

    /// Where the working commentary ends and the answer begins, per the
    /// engine's recorded offset. Anything that does not line up exactly (a
    /// bridge-stripped body, a bad offset, an empty half) falls back to the
    /// whole reply, unfolded.
    private var workingCommentarySplit: (commentary: String?, answer: String) {
        let text = displayContent
        guard message.role == "assistant",
              text == message.content,
              let offset = message.metadata?.workingCommentaryChars,
              offset > 0, offset < text.count
        else { return (nil, text) }
        let cut = text.index(text.startIndex, offsetBy: offset)
        let commentary = String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commentary.isEmpty, !answer.isEmpty else { return (nil, text) }
        return (commentary, answer)
    }

    @ViewBuilder
    private func workingCommentaryFold(_ commentary: String) -> some View {
        // Fluid glass A2: the transcript's one activity row.
        ChatActivityRow(title: "Working notes", isExpanded: $commentaryExpanded) {
            proseText(commentary)
        }
    }

    @ViewBuilder
    private func settledContent(_ content: String) -> some View {
        Group {
            // 658.13: one pass over cached blocks. Prose keeps the existing
            // cached inline-markdown path; fenced code becomes a real code
            // block instead of the newline-collapsed mangle it used to be.
            let blocks = ChatRichContentCache.blocks(content)
            if blocks.count == 1, case .prose(let only) = blocks[0] {
                // The overwhelmingly common case. Rendering it bare keeps the
                // pre-658.13 view tree exactly as it was — no extra VStack and
                // no ForEach per bubble across a long transcript, and the
                // bubble still HUGS its text instead of being stretched by a
                // full-width child.
                proseText(only)
            } else {
                VStack(alignment: seatsRight ? .trailing : .leading, spacing: NativeAgentSpacing.sm) {
                    // Positional identity: `blocks` is recomputed atomically
                    // from one content string, and a message may legitimately
                    // repeat the same snippet twice.
                    ForEach(blocks.indices, id: \.self) { index in
                        switch blocks[index] {
                        case .prose(let text):
                            proseText(text)
                        case .code(let language, let code):
                            ChatCodeBlockView(language: language, code: code)
                        }
                    }
                }
            }
        }
    }

    /// Prose runs through the existing cached inline-markdown path. No width
    /// frame: a `maxWidth: .infinity` child would stretch a short user bubble
    /// to its full 540 pt cap instead of letting it hug its content.
    ///
    /// Prose may also carry a Markdown table. Segmenting is a cached pure function
    /// with a no-pipe fast path, and the single-segment case renders exactly
    /// the pre-existing view tree — no extra container on an ordinary bubble.
    @ViewBuilder
    private func proseText(_ text: String) -> some View {
        let segments = ChatMarkdownTableParser.segments(text)
        if segments.count == 1, case .text(let only) = segments[0] {
            proseRows(only)
        } else {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(segments.indices, id: \.self) { index in
                    switch segments[index] {
                    case .text(let body): proseRows(body)
                    case .table(let table): ChatMarkdownTableView(table: table)
                    }
                }
            }
        }
    }

    private var bubbleLineSpacing: CGFloat { isUser ? 2 : NativeAgentShellLayout.replyLineSpacing }

    /// Wave 3 (Grok's rhythm): paragraphs sit a line gap plus 10pt apart, not
    /// a whole blank line apart, at the same breaks the stream splits at. Plain
    /// prose stays ONE `Text` (the gap is drawn inside it), so a drag still
    /// selects across paragraphs; prose with a list breaks only at the list,
    /// each run of plain paragraphs between lists still one `Text`.
    @ViewBuilder
    private func proseRows(_ text: String) -> some View {
        let paragraphs = StreamingParagraphText.paragraphs(text[...])
        let rows = ChatProseListParser.rows(text)
        if paragraphs.count > 1, rows.contains(where: { $0.marker != nil }) {
            // One width for every list in the message, as when it was one block.
            let markerWidth = CGFloat(rows.compactMap(\.marker).map(\.count).max() ?? 1) * 10
            let blocks = Self.listBlocks(paragraphs)
            VStack(alignment: .leading, spacing: bubbleLineSpacing + StreamingParagraphText.paragraphGap) {
                ForEach(blocks.indices, id: \.self) { index in
                    proseParagraph(blocks[index], markerWidth: markerWidth)
                }
            }
        } else {
            let markerWidth = CGFloat(rows.compactMap(\.marker).map(\.count).max() ?? 1) * 10
            proseParagraph(text.trimmingCharacters(in: .newlines), markerWidth: markerWidth)
        }
    }

    /// Paragraphs regrouped at list boundaries: a paragraph holding a list
    /// stands alone; adjacent plain ones rejoin at their blank lines.
    private static func listBlocks(_ paragraphs: [Substring]) -> [String] {
        var blocks: [String] = []
        var proseRun: [Substring] = []
        for paragraph in paragraphs {
            if ChatProseListParser.rows(String(paragraph)).contains(where: { $0.marker != nil }) {
                if !proseRun.isEmpty { blocks.append(proseRun.joined(separator: "\n\n")) }
                proseRun = []
                blocks.append(String(paragraph))
            } else {
                proseRun.append(paragraph)
            }
        }
        if !proseRun.isEmpty { blocks.append(proseRun.joined(separator: "\n\n")) }
        return blocks
    }

    @ViewBuilder
    private func proseParagraph(_ text: String, markerWidth: CGFloat) -> some View {
        let rows = ChatProseListParser.rows(text)
        if rows.contains(where: { $0.marker != nil }) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    if let marker = row.marker {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(marker)
                                .monospacedDigit()
                                .frame(width: max(20, markerWidth), alignment: .trailing)
                                .fixedSize()
                            inlineProseText(row.text)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.leading, CGFloat(row.indent) * 7)
                    } else if !row.text.isEmpty {
                        inlineProseText(row.text)
                    }
                }
            }
        } else {
            inlineProseText(text)
        }
    }

    @ViewBuilder
    private func inlineProseText(_ text: String) -> some View {
        Text(ChatParagraphGap.applied(
            ChatMarkdownCache.attributed(text) ?? AttributedString(text),
            content: text, lineSpacing: bubbleLineSpacing
        ))
    }

    /// Every retry and Regenerate on this bubble asks the one gate first: a
    /// failed turn that acted, or whose outcome is unknown, is confirmed
    /// before it runs again.
    private func requestRetry() {
        if let failure = appModel.retryNeedsConfirmation(for: message) {
            retryConfirmation = failure
        } else {
            Task { await appModel.regenerateAssistantMessage(message) }
        }
    }

    private var messageNeedsRetry: Bool {
        ChatShellTroubleState.isFailed(message) || message.metadata?.cancelled == true
    }
}

/// `.equatable()` at the call site makes this `==` the sole authority on
/// whether a row's body re-runs, so a streamed chunk re-renders the streaming
/// bubble and nothing else. Without it the settled rows re-ran bridge-tag
/// parsing (`BridgeRoutingPrefix.group`), the seat decision and attributed-text
/// layout on every tick.
extension MessageBubble: Equatable {
    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.isLastAssistant == rhs.isLastAssistant
            && drawsTheSame(lhs.message, rhs.message)
    }
}

/// VoiceOver actions for a transcript message. The pointer hover bar is hidden
/// from accessibility because it is opacity-zero until mouse hover; this is the
/// stable keyboard/VoiceOver surface for the same commands. Most importantly,
/// user-authored messages never advertise assistant-only actions that no-op.
private struct MessageBubbleAccessibilityActions: ViewModifier {
    let isUser: Bool
    let isLastAssistant: Bool
    let onCopy: () -> Void
    let onReadAloud: () -> Void
    let onRegenerate: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isUser {
            content
                .accessibilityAction(named: "Copy message", onCopy)
        } else if isLastAssistant {
            assistantActions(content)
                .accessibilityAction(named: "Regenerate response", onRegenerate)
        } else {
            assistantActions(content)
        }
    }

    private func assistantActions(_ content: Content) -> some View {
        content
            .accessibilityAction(named: "Copy message", onCopy)
            .accessibilityAction(named: "Read message aloud", onReadAloud)
    }
}

/// Sweep R4 C14: compact chip for an attachment the bubble cannot render inline
/// (PDF, CSV, any non-image file). Before this, those rows rendered nothing at
/// all — the transcript silently lost the fact that a file was sent.
private struct MessageAttachmentChipView: View {
    let attachment: PersistedAttachment

    private var displayName: String {
        let name = attachment.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        return "Attachment"
    }

    private var sizeText: String? {
        guard attachment.byteSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: attachment.byteSize, countStyle: .file)
    }

    private var symbol: String {
        let mime = attachment.mime.lowercased()
        if mime.hasPrefix("image/") { return "photo" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("csv") { return "doc.plaintext" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
            Text(displayName)
                .font(NativeAgentFont.label)
                .lineLimit(1)
                .truncationMode(.middle)
            if let sizeText {
                Text(sizeText)
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .houseInset(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(attachment.path ?? displayName)
        .contextMenu {
            if let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                Button {
                    ChatClipboard.copy(path)
                } label: { Label("Copy file path", systemImage: "doc.on.doc") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
    }
}

private struct MessageLocalImageAttachmentView: View {
    let attachment: PersistedAttachment

    @State private var loadedImage: NSImage?
    @State private var loadFailed = false

    private var imagePath: String? {
        guard let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }

    var body: some View {
        // 2026-09-13: the load used to hang off the LOADING branch only, so it
        // was torn down the moment the image arrived and re-armed whenever a
        // re-render put the placeholder back — `closure #4 in
        // MessageLocalImageAttachmentView.body` was 130 main-thread samples
        // while clicking through the rail. One `.task` per attachment identity,
        // on the row itself, runs once and stays run.
        imageBody
            .task(id: attachment.path) { await loadImage() }
    }

    @ViewBuilder
    private var imageBody: some View {
        // 2026-07-21 audit: NSImage(contentsOfFile:) used to run synchronously
        // in body on every re-render; the load is now cached in @State via .task.
        let state = ChatLocalImageAttachmentPresentation.state(
            path: imagePath,
            hasLoadedImage: loadedImage != nil,
            loadFailed: loadFailed
        )
        if state == .loaded, let image = loadedImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                }
                .contextMenu {
                    if let path = imagePath {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                        } label: {
                            Label("Copy image path", systemImage: "doc.on.doc")
                        }
                    }
                }
        } else if state == .loading {
            Color.clear
                .frame(width: 160, height: 120)
                .overlay { ProgressView().controlSize(.small) }
                .houseInset(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text("Image unavailable")
                    .font(NativeAgentFont.label.weight(.medium))
                Text(ChatLocalImageAttachmentPresentation.unavailableDetail(for: attachment))
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 160, height: 120)
            .houseInset(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Image attachment unavailable: "
                    + ChatLocalImageAttachmentPresentation.unavailableDetail(for: attachment)
            )
        }
    }

    private func loadImage() async {
        // The task now lives on the row, not on the placeholder, so a re-armed
        // task must not redo a decode that already landed.
        if loadedImage != nil { return }
        guard let path = imagePath else {
            loadFailed = true
            return
        }
        let url = URL(fileURLWithPath: path)
        let key = await Task.detached(priority: .userInitiated) {
            ChatImageCache.identityKey(for: url)
        }.value
        if let cached = ChatLocalImageAttachmentLoader.cachedImage(forKey: key) {
            loadedImage = cached
            return
        }
        // Keep the real disk read off the render actor. NSImage construction
        // stays on the view actor so an AppKit object never crosses a detached
        // task boundary.
        let imageData = await Task.detached(priority: .userInitiated) {
            ChatLocalImageAttachmentLoader.readData(at: url)
        }.value
        guard let imageData,
              let image = ChatLocalImageAttachmentLoader.decode(imageData, cacheKey: key) else {
            loadFailed = true
            return
        }
        loadedImage = image
    }
}

// PATCH-2026-05-09: chat-ux-polish — hover action bar shown on bubble hover
private struct BubbleHoverBar: View {
    var message: ChatMessage
    var isLastAssistant: Bool
    var onCopy: () -> Void
    var onRegenerate: () -> Void
    var onReadAloud: () -> Void

    private var isAssistant: Bool { message.role == "assistant" }

    var body: some View {
        HStack(spacing: NativeAgentSpacing.xs) {
            // Copy
            BubbleAction(icon: "doc.on.doc", help: "Copy text", action: onCopy)

            // Regenerate — only on last assistant message
            if isAssistant && isLastAssistant {
                BubbleAction(icon: "arrow.clockwise", help: "Regenerate", action: onRegenerate)
            }

            if isAssistant {
                BubbleAction(icon: "speaker.wave.2", help: "Read aloud", action: onReadAloud)
            }
        }
        .padding(.horizontal, NativeAgentSpacing.sm)
        .padding(.vertical, 4)
        .houseSurface(in: RoundedRectangle(cornerRadius: NativeAgentRadius.control))
    }
}

private struct BubbleAction: View {
    var icon: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Canonical debug projection used by the context-menu JSON sheet. Encoding
/// the model itself keeps this inspection surface aligned with the transcript
/// wire shape; a hand-maintained dictionary previously omitted
/// `metadata.origin` and made a bridge row look indistinguishable from a local
/// user row precisely where someone would inspect it.
enum ChatMessageDebugJSON {
    static func text(for message: ChatMessage) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(message),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

// PATCH-2026-05-08: polish-wave — JSON debug sheet for message context menu
private struct MessageJSONSheet: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    private var jsonText: String {
        ChatMessageDebugJSON.text(for: message)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Message data")
                    .font(NativeAgentFont.section)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            ScrollView {
                Text(jsonText)
                    .font(NativeAgentFont.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .padding(NativeAgentSpacing.xl)
        .frame(width: 540, height: 420)
        .houseSheet()
    }
}

struct AdvancedTextEditor: View {
    var title: String
    @Binding var text: String
    var minHeight: CGFloat = 82
    var isReadOnly: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .disabled(isReadOnly)
                .frame(minHeight: minHeight, maxHeight: minHeight + 44)
                .scrollContentBackground(.hidden)
                .padding(6)
        }
    }
}


private struct UserBubbleSurface: ViewModifier {
    let seatsRight: Bool
    let corners: RectangleCornerRadii

    func body(content: Content) -> some View {
        if seatsRight {
            content.houseSurface(in: UnevenRoundedRectangle(cornerRadii: corners, style: .continuous))
        } else {
            content
        }
    }
}

/// The message's hit region extended down by the distance its hover bar hangs.
private struct HoverBarReach: Shape {
    let below: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + max(0, below)))
    }
}
