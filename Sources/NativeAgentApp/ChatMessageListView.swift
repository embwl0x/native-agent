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
    }
}

struct MessageGroup: Identifiable {
    var id: String
    var messages: [ChatMessage]
    var isToolGroup: Bool
}

enum ChatTranscriptWindow {
    static func range(count: Int, start: Int? = nil) -> Range<Int> {
        let count = max(0, count)
        let size = ChatMessageListView.windowSize
        let lower = min(max(0, start ?? (count - size)), max(0, count - size))
        return lower..<min(count, lower + size)
    }
}

enum ChatTranscriptPresentation {
    static func hasVisibleText(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    static func liveToolGroupID(
        groups: [MessageGroup],
        isStreaming: Bool,
        lastMessage: ChatMessage?
    ) -> String? {
        let assistantStarted = lastMessage?.role == "assistant"
            && lastMessage.map { hasVisibleText($0.content) } == true
        guard isStreaming, !assistantStarted else { return nil }
        return groups.last(where: { $0.isToolGroup })?.id
    }
}

/// The mounted assistant bubble owns the only honest first-render boundary: a
/// non-empty final assistant bubble has become visible to the person using the
/// Mac app. The registry supplies correlation and claim-once behavior; this
/// type keeps eligibility/refusal observable without making a visual render
/// depend on telemetry delivery.
enum ChatFirstRenderTelemetry {
    enum Eligibility: Equatable, Sendable {
        case eligible(sessionID: String)
        case notAssistant
        case notLastAssistant
        case emptyContent
        case missingSessionID
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
        activeSessionID: String
    ) -> Eligibility {
        guard role == "assistant" else { return .notAssistant }
        guard isLastAssistant else { return .notLastAssistant }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .emptyContent
        }
        // A present-but-blank message session is malformed; do not fall back
        // to the active tab and attach its first render to the wrong turn.
        let sessionID = messageSessionID ?? activeSessionID
        let cleanSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSessionID.isEmpty else { return .missingSessionID }
        return .eligible(sessionID: cleanSessionID)
    }

    static func emit(
        eligibility: Eligibility,
        registry: TurnFirstRenderRegistry = .shared,
        bus: TurnTraceBus = .shared
    ) async -> Outcome {
        guard case .eligible(let sessionID) = eligibility else {
            return .ineligible(eligibility)
        }
        guard let event = await registry.claimFirstRenderEvent(
            sessionId: sessionID,
            observedBy: "NativeAgentApp.MessageBubble"
        ) else {
            return .noPendingTurn
        }
        TurnTraceBus.fire(event, on: bus)
        return .emitted(event)
    }
}

enum ToolPillPresentation {
    enum Outcome: Equatable {
        case pending
        case succeeded
        case failed

        var icon: String {
            switch self {
            case .pending: "clock"
            case .succeeded: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .pending: .secondary
            case .succeeded: .green
            case .failed: .red
            }
        }
    }

    static func outcome(ok: Bool?) -> Outcome {
        guard let ok else { return .pending }
        return ok ? .succeeded : .failed
    }

    /// ui-simplify 2026-09-02: an absent duration used to render the words
    /// "unknown duration" beside every streamed tool call — a confession the
    /// reader could do nothing with. A missing duration now says nothing at
    /// all; the pill's outcome glyph still distinguishes pending from done.
    static func durationText(_ durationMs: Int?) -> String {
        guard let durationMs else { return "" }
        return "\(durationMs)ms"
    }
}

enum ToolCallGroupPresentation {
    static func skillToolNames(catalog: ChatToolCatalogSnapshot?) -> Set<String> {
        catalog?.skillReaderToolNames ?? SwiftToolDispatcher.skillReaderToolNames
    }

    static func expandsInline(messages: [ChatMessage]) -> Bool {
        messages.contains { $0.metadata?.isPendingApproval == true }
    }
}

enum ToolDiffPresentation {
    static func lines(before: String, after: String, limit: Int = 60) -> [String] {
        let beforeLines = before.split(separator: "\n", maxSplits: 1001, omittingEmptySubsequences: false).map(String.init)
        let afterLines = after.split(separator: "\n", maxSplits: 1001, omittingEmptySubsequences: false).map(String.init)
        let rows = alignedRows(before: beforeLines, after: afterLines)
        let displayed = Array(rows.prefix(limit))
        guard rows.count > displayed.count else { return displayed }
        return displayed + ["... (\(rows.count - displayed.count) more lines)"]
    }

    private static func alignedRows(before: [String], after: [String]) -> [String] {
        let m = before.count
        let n = after.count
        var lengths = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0, n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    lengths[i][j] = before[i] == after[j]
                        ? lengths[i + 1][j + 1] + 1
                        : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }
        var rows: [String] = []
        var i = 0
        var j = 0
        while i < m, j < n {
            if before[i] == after[j] {
                rows.append(" \(before[i])")
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                rows.append("-\(before[i])")
                i += 1
            } else {
                rows.append("+\(after[j])")
                j += 1
            }
        }
        while i < m { rows.append("-\(before[i])"); i += 1 }
        while j < n { rows.append("+\(after[j])"); j += 1 }
        return rows
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

/// The inline approval card is a safety control, so it has an explicit state
/// for missing authority rather than presenting disabled actions as though the
/// card were merely busy. This also keeps an absent/stale approvals refresh
/// from turning a still-pending request into a resolved-looking card.
enum InlineApprovalPresentation {
    enum State: Equatable {
        case unavailable
        case pending
        case resolved(decision: String)
    }

    static func state(
        approvalID: String,
        locallyResolved: Bool,
        localDecision: String,
        externalStatus: String?
    ) -> State {
        guard !approvalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        let externalDecision = externalStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if locallyResolved {
            return .resolved(decision: localDecision)
        }
        guard let externalDecision,
              !externalDecision.isEmpty,
              externalDecision != "pending" else {
            return .pending
        }
        return .resolved(decision: externalDecision)
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
        /// 2026-09-06: `AppModel.chatMessagesStructureVersion` as of the
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
            if msg.role == "tool" {
                toolRun.append(msg)
            } else {
                flushTools()
                result.append(MessageGroup(id: msg.id, messages: [msg], isToolGroup: false))
            }
        }
        flushTools()
        return result
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
    /// True while THIS session is streaming a turn. Sweep R4 C16: detached
    /// panels never passed it, so `ToolCallGroup(isLive:)` defaulted to false
    /// and a tool call that was still running rendered as a finished, static
    /// "N tools used" summary. Callers that genuinely have no live state (the
    /// default) keep the old behaviour.
    var isStreaming: Bool = false
    /// The current transcript-search result. Highlighting is projection-only;
    /// it never changes or filters canonical messages.
    var highlightedMessageID: String? = nil
    /// False while the reader has scrolled up: an entrance nobody is looking at
    /// is motion for nothing, and the "Latest" pill leads the eye instead.
    var animatesArrival: Bool = true
    var latestRequest: Int = 0
    /// 2026-09-06: the grouper cache keys on the transcript's mutation
    /// version, so the list needs the model, not just the rows it was handed.
    @Environment(AppModel.self) private var appModel
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false

    /// Rows shown at once. User, 2026-09-04: the transcript is a plain VStack
    /// (no LazyVStack, no prefetch loop), so every shown row is resident —
    /// about 1.5 MB each with selectable text. A long thread shows its last
    /// `windowSize` rows and one row above them that reveals the next page.
    nonisolated static let windowSize = 300
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

    var body: some View {
        let lastAssistantId = messages.last(where: { $0.role == "assistant" })?.id
        let allGroups = MessageGrouper.projection(
            for: messages,
            sessionId: sessionId,
            structureVersion: appModel.chatMessagesStructureVersion
        )
        let range = windowRange(for: allGroups)
        let hidden = range.lowerBound
        let groups = Array(allGroups[range])
        // Same rule as the main window (ChatView): the live flip-box is the LAST
        // tool group while the session is still working and the reply text has
        // not started arriving yet.
        let liveToolGroupId = ChatTranscriptPresentation.liveToolGroupID(
            groups: groups,
            isStreaming: isStreaming,
            lastMessage: messages.last
        )
        if hidden > 0 {
            ChatEarlierMessagesRow(hidden: hidden) {
                revealedSessionId = sessionId
                pagedSearchID = highlightedMessageID
                pageAnchorID = allGroups[max(0, range.lowerBound - Self.windowSize)].id
            }
        }
        ForEach(groups) { group in
            if group.isToolGroup {
                if group.messages.count == 1 {
                    let msg = group.messages[0]
                    if msg.metadata?.isPendingApproval == true {
                        InlineApprovalCard(message: msg)
                            .transcriptLayoutProbe(rowID: msg.id, kind: .approval)
                    } else if !classicShell {
                        ShellToolRow(messages: [msg])
                            .transcriptLayoutProbe(rowID: msg.id, kind: .toolRow)
                    } else {
                        ToolPillView(message: msg)
                            .transcriptLayoutProbe(rowID: msg.id, kind: .toolPill)
                    }
                } else {
                    ToolCallGroup(
                        messages: group.messages,
                        isLive: liveToolGroupId != nil && group.id == liveToolGroupId
                    )
                    .transcriptLayoutProbe(rowID: group.id, kind: .toolGroup)
                }
            } else {
                let msg = group.messages[0]
                MessageBubble(
                    message: msg,
                    isLastAssistant: msg.role == "assistant" && msg.id == lastAssistantId
                )
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
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .identity)
                    : .identity)
            }
        }
        .onChange(of: latestRequest) { _, _ in
            revealedSessionId = sessionId
            pagedSearchID = highlightedMessageID
            pageAnchorID = nil
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
                        .strokeBorder(NativeAgentBrand.accent, lineWidth: 2)
                        .padding(-5)
                        .accessibilityHidden(true)
                }
                .accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}

// PATCH-2026-05-08: wave2-chat-ux — ToolPillView for role=tool messages
struct ToolPillView: View {
    var message: ChatMessage
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var meta: ChatMessageMetadata? { message.metadata }
    private var toolName: String { meta?.toolName ?? "tool" }
    private var outcome: ToolPillPresentation.Outcome {
        ToolPillPresentation.outcome(ok: meta?.ok)
    }
    private var durationText: String { ToolPillPresentation.durationText(meta?.durationMs) }
    private var resultSummary: String { meta?.resultSummary ?? "" }

    private var icon: String {
        switch toolName {
        case "read_file", "list_dir": return "doc.text.magnifyingglass"
        case "write_file": return "square.and.pencil"
        case "bash": return "terminal"
        case "grep": return "magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    private var inputOneLiner: String {
        guard let json = meta?.inputJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        let parts = obj.map { k, v in "\(k)=\(v)" }.joined(separator: " ")
        return parts.truncated(to: 80, keeping: 77)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed pill
            Button {
                withAnimation(NativeAgentMotion.respecting(
                    .easeOut(duration: 0.15), reduceMotion: reduceMotion
                )) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(toolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !inputOneLiner.isEmpty {
                        Text(inputOneLiner)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // Duration badge — omitted entirely when unknown.
                    if !durationText.isEmpty {
                        Text(durationText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    // A missing outcome is pending/unknown, never implicit success.
                    Image(systemName: outcome.icon)
                        .font(.caption2)
                        .foregroundStyle(outcome.color)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: 560, alignment: .leading)

            // Expanded detail card
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let json = meta?.inputJSON {
                        // Fix 4: cap display strings so large payloads don't materialise fully in the view
                        let displayJSON = json.truncated(to: 8000, suffix: "\n…[truncated]")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(displayJSON)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    if !resultSummary.isEmpty {
                        let displayResult = resultSummary.truncated(to: 8000, suffix: "\n…[truncated]")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Result")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(displayResult)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    // Inline diff for write_file
                    if toolName == "write_file", let before = meta?.beforeContent, let after = meta?.afterContent {
                        ToolDiffView(before: before, after: after)
                    }
                }
                .padding(10)
                .frame(maxWidth: 560, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 24) // indent tool pills from left margin
    }
}

// PATCH-2026-05-08: wave2-chat-ux — unified diff viewer for write_file expanded view
struct ToolDiffView: View {
    var before: String
    var after: String

    private var diffLines: [String] {
        ToolDiffPresentation.lines(before: before, after: after)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Diff")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        toolDiffLine(line)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private func toolDiffLine(_ line: String) -> some View {
        if line.hasPrefix("+") {
            Text(line)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.07))
        } else if line.hasPrefix("-") {
            Text(line)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07))
        } else {
            Text(line)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// PATCH-2026-05-08: wave2-chat-ux — inline approval card for kind=approval_pending
struct InlineApprovalCard: View {
    var message: ChatMessage
    @Environment(AppModel.self) private var appModel
    @State private var resolving = false
    @State private var resolved = false
    @State private var resolvedDecision = ""
    @State private var resolveError: String? = nil
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false
    @State private var showingDraft = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var meta: ChatMessageMetadata? { message.metadata }
    private var approvalId: String { meta?.approvalId ?? "" }

    /// The daemon's own view of this approval, so a card recreated by a
    /// re-render cannot offer a second click on an already-resolved request.
    private var externalDecision: String? {
        appModel.approvals.first(where: { $0.id == approvalId })?.status.lowercased()
    }

    private var state: InlineApprovalPresentation.State {
        InlineApprovalPresentation.state(
            approvalID: approvalId,
            locallyResolved: resolved,
            localDecision: resolvedDecision,
            externalStatus: externalDecision
        )
    }

    var body: some View {
        if classicShell {
            classicBody
        } else {
            shellBody
        }
    }

    // MARK: - The shell card
    //
    // ui-simplify 2026-09-02 (Lane A): the same component, restyled. Teal is
    // reserved for exactly this — she is waiting on you — so the border is the
    // only teal on the page. The title is plain, the detail line carries the
    // full recipient/address (never truncated: that is the thing being
    // approved), and the draft opens in place rather than in a sheet.
    private var shellBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .foregroundStyle(NativeAgentShell.needsYou)
                Text(ChatShellApprovalCopy.title(message.content))
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 0)
            }

            let detail = ChatShellApprovalCopy.detail(message.content)
            if !detail.isEmpty {
                Text(detail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            switch state {
            case .resolved(let decision):
                let approved = decision == "approved"
                let rejected = decision == "denied" || decision == "rejected"
                Text(approved ? "Done." : (rejected ? "Left alone." : "Resolved."))
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.secondary)
            case .pending:
                HStack(spacing: 8) {
                    Button {
                        Task { await resolve("approved") }
                    } label: {
                        Text(ChatShellApprovalCopy.approve(for: message.content))
                            .font(ShellType.labelSemibold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                NativeAgentShell.needsYou,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .foregroundStyle(Color(hex: 0x0B1013))
                    }
                    .buttonStyle(.plain)
                    .disabled(resolving || approvalId.isEmpty)

                    Button {
                        Task { await resolve("denied") }
                    } label: {
                        Text(ChatShellApprovalCopy.decline)
                            .font(ShellType.labelSemibold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                NativeAgentShell.softFill,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .foregroundStyle(NativeAgentShell.text)
                    }
                    .buttonStyle(.plain)
                    .disabled(resolving || approvalId.isEmpty)

                    Button {
                        withAnimation(NativeAgentMotion.respecting(
                            .easeOut(duration: 0.15), reduceMotion: reduceMotion
                        )) { showingDraft.toggle() }
                    } label: {
                        Text(showingDraft
                            ? ChatShellApprovalCopy.hideDraft
                            : ChatShellApprovalCopy.showDraft)
                            .font(ShellType.label)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                    .buttonStyle(.plain)
                }
            case .unavailable:
                Label("Approval details unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.trouble)
            }

            if showingDraft {
                Text(message.content)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            if let resolveError {
                Text(resolveError)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        .background(
            NativeAgentShell.quietFill,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(NativeAgentShell.needsYou.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.shell.approval-card")
    }

    private var classicBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                Text("Action needs approval")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            Text(message.content)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            // S.7: treat as resolved if local @State says so OR if the daemon
            // no longer lists this approval as pending (prevents second-click
            // after the view is recreated by a re-render).
            let externalDecision = appModel.approvals
                .first(where: { $0.id == approvalId })?
                .status
                .lowercased()
            switch InlineApprovalPresentation.state(
                approvalID: approvalId,
                locallyResolved: resolved,
                localDecision: resolvedDecision,
                externalStatus: externalDecision
            ) {
            case .resolved(let decision):
                let approved = decision == "approved"
                let rejected = decision == "denied" || decision == "rejected"
                let badge = approved ? "Approved" : (rejected ? "Rejected" : "Resolved")
                let icon = approved ? "checkmark.circle.fill" : (rejected ? "xmark.circle.fill" : "checkmark.circle")
                Label(badge, systemImage: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(approved ? Color.green : (rejected ? Color.red : Color.secondary))
            case .pending:
                HStack(spacing: 8) {
                    Button {
                        Task { await resolve("approved") }
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(resolving || approvalId.isEmpty)

                    Button {
                        Task { await resolve("denied") }
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(resolving || approvalId.isEmpty)
                }
            case .unavailable:
                Label("Approval details unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            // B.3: show daemon error inline; card stays actionable
            if let err = resolveError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: 440, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
        .padding(.leading, 24)
    }

    private func resolve(_ decision: String) async {
        guard !approvalId.isEmpty else { return }
        resolving = true
        resolveError = nil
        defer { resolving = false }
        do {
            // B.3: call the typed endpoint so we catch daemon errors
            _ = try await appModel.resolveApproval(id: approvalId, decision: decision)
            resolvedDecision = decision
            resolved = true
            // S.4: refresh the global approvals list so other inline cards
            // for the same approval ID reflect the new state immediately.
            await appModel.loadHealthCard()
        } catch {
            // B.3: daemon returned an error — keep card actionable
            resolveError = error.localizedDescription
        }
    }
}

// PATCH-2026-05-08: wave2-chat-ux — collapsible tool-call group for consecutive tool messages
struct ToolCallGroup: View {
    @Environment(AppModel.self) private var appModel
    var messages: [ChatMessage]
    /// True only for the currently-streaming last group: show the live
    /// flip-through box. Otherwise collapse to an "N tools used" summary.
    var isLive: Bool = false
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false
    @State private var toolsExpanded = false
    @State private var skillsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Skill use shows up as these tool calls — split them into their own
    // "N skills used" box, separate from regular tools. The checked catalog
    // owns the classification; the dispatcher taxonomy is only the startup
    // fallback before this surface has a catalog snapshot.
    private var skillToolNames: Set<String> {
        ToolCallGroupPresentation.skillToolNames(catalog: appModel.chatToolCatalog)
    }
    private func isSkill(_ msg: ChatMessage) -> Bool {
        skillToolNames.contains(msg.metadata?.toolName ?? "")
    }
    private var skillMsgs: [ChatMessage] { messages.filter(isSkill) }
    private var toolMsgs: [ChatMessage] { messages.filter { !isSkill($0) } }

    // An unresolved approval must never be hidden behind a collapsed summary.
    private var hasPendingApproval: Bool {
        ToolCallGroupPresentation.expandsInline(messages: messages)
    }

    var body: some View {
        if hasPendingApproval {
            fullList
        } else if isLive {
            liveBox
        } else if !classicShell {
            // ui-simplify 2026-09-02: one quiet row for the whole turn's tool
            // traffic — tools and skills together — instead of two collapsed
            // boxes of raw tool names.
            ShellToolRow(messages: messages)
        } else {
            collapsedBox
        }
    }

    // While she's working: one box showing the latest tool, flipping as each
    // new one fires (instead of spanning every call out on its own line).
    private var liveBox: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Group {
                if let latest = messages.last {
                    ToolPillView(message: latest)
                        .id(latest.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .animation(
            NativeAgentMotion.respecting(.easeOut(duration: 0.22), reduceMotion: reduceMotion),
            value: messages.last?.id
        )
    }

    // When done: separate "N tools used" / "N skills used" boxes, each
    // independently click-to-expand.
    private var collapsedBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !toolMsgs.isEmpty {
                summaryRow(items: toolMsgs, noun: "tool",
                           icon: "wrench.and.screwdriver", expanded: $toolsExpanded)
            }
            if !skillMsgs.isEmpty {
                summaryRow(items: skillMsgs, noun: "skill",
                           icon: "text.book.closed", expanded: $skillsExpanded)
            }
        }
    }

    @ViewBuilder
    private func summaryRow(items: [ChatMessage], noun: String, icon: String,
                            expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(NativeAgentMotion.respecting(
                    .easeOut(duration: 0.15), reduceMotion: reduceMotion
                )) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
                    Text("\(items.count) \(noun)\(items.count == 1 ? "" : "s") used")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.leading, 24)
            }
            .buttonStyle(.borderless)
            if expanded.wrappedValue {
                ForEach(items) { msg in
                    if msg.metadata?.isPendingApproval == true { InlineApprovalCard(message: msg) }
                    else { ToolPillView(message: msg) }
                }
            }
        }
    }

    private var fullList: some View {
        VStack(alignment: .leading, spacing: 4) {
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

// PATCH-2026-05-08: wave2-chat-ux — slash command menu popover
// PATCH-Phase6b: extraTools — dynamic tool entries from CapabilitiesStore appended after hardcoded ones.
struct SlashCommandMenu: View {
    var filter: String
    var onSelect: (String) -> Void
    // S.8: called when user presses Escape to dismiss the popover
    var onDismiss: (() -> Void)? = nil
    // PATCH-Phase6b: read-only tools to show as dynamic slash-command entries
    var extraTools: [ToolCapability] = []
    @AppStorage("showDeveloperSurfaces") private var showDeveloperSurfaces = false

    private struct SlashCmd: Identifiable {
        var id: String { command }
        var command: String
        var description: String
        var placeholder: String
        var isToolEntry: Bool = false
    }

    private var hardcodedCommands: [SlashCmd] {
        ChatSlashCommandRegistry.visible(
            showDeveloperSurfaces: NativeAgentShellPreference.developerSurfacesShown(showDeveloperSurfaces)
        ).map {
            SlashCmd(command: $0.command, description: $0.description, placeholder: $0.placeholder)
        }
    }

    // All commands: hardcoded entries + dynamic tool entries (tools not already covered by hardcoded names)
    private var allCommands: [SlashCmd] {
        let hardcodedNames = Set(hardcodedCommands.map { $0.command })
        let dynamic = extraTools
            .filter { !hardcodedNames.contains($0.name) }
            .map { SlashCmd(command: $0.name, description: $0.description, placeholder: "", isToolEntry: true) }
        return hardcodedCommands + dynamic
    }

    private var filtered: [SlashCmd] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allCommands }
        return allCommands.filter { $0.command.hasPrefix(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { cmd in
                    Button {
                        let text = cmd.placeholder.isEmpty ? cmd.command : cmd.command + " "
                        onSelect(text)
                    } label: {
                        HStack(spacing: 8) {
                            Text("/" + (cmd.placeholder.isEmpty ? cmd.command : cmd.placeholder))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text(cmd.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            // PATCH-Phase6b: tool badge for dynamically injected tool entries
                            if cmd.isToolEntry {
                                Text("tool")
                                    .font(.caption2)
                                    .foregroundStyle(Color.blue)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(minWidth: 320, maxHeight: 280)
        .padding(.vertical, 4)
        // S.8: hidden Escape button closes the slash-command popover
        .background(
            Button("") { onDismiss?() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        )
    }
}

// PATCH-2026-05-09: chat-ux-polish — polished MessageBubble
// User: purple→pink gradient, white text, rounded-right corners
// Assistant: glass-card style, soft border, primary text
// Hover actions: copy, regenerate (last assistant only), thumbs up/down
// chat-smoothness phase 1 (2026-06-12): finished bubbles re-parsed their
// markdown on EVERY body re-evaluation — during streaming that's every
// visible bubble, every coalesce tick. Parse once per content string;
// FIFO-evict to bound memory. Thread-safe (bubbles render on main, but the
// cache shouldn't care).
final class ChatMarkdownCache: @unchecked Sendable {
    static let shared = ChatMarkdownCache()
    private let lock = NSLock()
    private var cache: [String: AttributedString] = [:]
    private var order: [String] = []
    private var totalChars = 0
    private let capacity = 300
    // Byte-ish budget alongside the entry cap: keys are full content strings,
    // so 300 giant messages could hold real memory. ~4M chars ≈ a few MB.
    private let charBudget = 4_000_000

    static func attributed(_ content: String) -> AttributedString? {
        shared._attributed(content)
    }

    private func _attributed(_ content: String) -> AttributedString? {
        lock.lock()
        if let hit = cache[content] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        RenderAudit.bump("markdown.parse")
        guard let raw = try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
        // Untrusted content: drop live links for any scheme outside the
        // allowlist before the string is ever handed to a Text view.
        let parsed = ChatLinkPolicy.sanitized(raw)
        lock.lock()
        if cache[content] == nil {
            cache[content] = parsed
            order.append(content)
            totalChars += content.count
            while order.count > capacity || (totalChars > charBudget && order.count > 1) {
                let evicted = order.removeFirst()
                totalChars -= evicted.count
                cache.removeValue(forKey: evicted)
            }
        }
        lock.unlock()
        return parsed
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

    @State private var voiceOutput = VoiceOutputController.sharedMessagePlayback
    @Environment(AppModel.self) private var appModel
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false
    @State private var showJSONSheet = false
    @State private var bubbleToast: String? = nil
    @State private var isHovered = false

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
    private var displayRole: String {
        switch normalizedRole {
        case "user": "You"
        // The configured persona profile name — NOT the
        // chatPersona style quick-switch, which can read "Custom"/"AI".
        case "assistant": appModel.agentDisplayName
        default: message.role.capitalized
        }
    }

    private var userCorners: RectangleCornerRadii {
        shellChrome
            ? NativeAgentShellLayout.userBubbleCorners
            : .init(topLeading: 8, bottomLeading: 8, bottomTrailing: 3, topTrailing: 8)
    }

    // ui-simplify 2026-09-02 (Lane A): her replies are prose, not chat
    // furniture — plain text at 16pt on a 1.6 line height inside 600pt, with
    // the user's own words in one soft bubble opposite. The classic bubble
    // (accent fill, white text, 8pt corners) survives behind the kill switch.
    private var shellChrome: Bool { !classicShell }

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

    private var bridgeTag: String? {
        guard shellChrome, isUser, isBridgeRouted else { return nil }
        return ChatShellConversationRow.bridgeAgentTag(message.content)
    }

    /// Agent, 2026-09-02: a bridge message is another AGENT talking. It
    /// carries the user role only because that is the seat the runtime hands
    /// an inbound turn — it was never User. Rendering it in the right-hand
    /// bubble put Claude's and Codex's words in User's seat, so the room read
    /// as though he had said them. User's seat is User's only.
    private var isBridgeMessage: Bool { bridgeTag != nil }

    /// Which side of the room this message sits on. Only the human's own
    /// words take the right.
    private var seatsRight: Bool { isUser && !isBridgeMessage }

    /// A bridge message renders on the left and QUIETER than her replies:
    /// smaller, secondary, and with no bubble behind it, so it reads as
    /// traffic passing through the room rather than as either voice in it.
    private var isQuietBridge: Bool { shellChrome && isBridgeMessage }

    private var displayContent: String {
        guard shellChrome, isBridgeRouted,
              ChatShellConversationRow.hasBridgePrefix(message.content)
        else {
            return message.content
        }
        return ChatShellConversationRow.stripBridgePrefix(message.content)
    }

    var body: some View {
        // Agent, 2026-09-02: a worker's completion envelope is a note to her,
        // not a conversation for User. In the new shell it folds like tools.
        // 2026-09-06: `isBridgeRouted` for the same reason as `bridgeTag` — a
        // person who quotes a routing slip must not have their own message
        // folded away into a worker receipt.
        if shellChrome, isUser, isBridgeRouted, ChatShellEnvelope.isEnvelope(message.content) {
            ShellEnvelopeRow(content: message.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
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
                if !isUser, !shellChrome {
                    HStack(spacing: NativeAgentSpacing.xs) {
                    Text(displayRole)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                        if let brainLine {
                        Text(brainLine)
                            .font(NativeAgentFont.tag)
                            .foregroundStyle(.tertiary)
                                .opacity(isHovered ? 1 : 0)
                        }
                    }
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
                    if hasVisibleContent {
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
                    .font(shellChrome
                        ? (isQuietBridge ? ShellType.label : ShellType.body)
                        : NativeAgentFont.body)
                    .textSelection(.enabled)
                    .lineSpacing(shellChrome && !isUser
                        ? NativeAgentShellLayout.replyLineSpacing
                        : 2)
                    .frame(
                        maxWidth: shellChrome
                            ? (seatsRight
                                ? NativeAgentShellLayout.userBubbleMaxWidth
                                : NativeAgentShellLayout.replyMaxWidth)
                            : (isUser ? 540 : NativeAgentLayout.maxReadableChatWidth),
                        alignment: seatsRight ? .trailing : .leading
                    )
                    .padding(.horizontal, seatsRight ? (shellChrome ? 16 : NativeAgentSpacing.md) : 0)
                    .padding(.vertical, seatsRight ? (shellChrome ? 12 : NativeAgentSpacing.sm + 2) : NativeAgentSpacing.xs)
                    .background {
                        if seatsRight {
                            UnevenRoundedRectangle(cornerRadii: userCorners, style: .continuous)
                                .fill(shellChrome
                                    ? AnyShapeStyle(NativeAgentShell.softFill)
                                    : AnyShapeStyle(NativeAgentBrand.accentDeep))
                        }
                    }
                    .overlay {
                        if isUser, !shellChrome {
                            UnevenRoundedRectangle(cornerRadii: userCorners, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                        }
                    }
                    .foregroundStyle(shellChrome
                        ? (isQuietBridge ? NativeAgentShell.secondary : NativeAgentShell.text)
                        : (isUser ? Color.white : Color.primary))
                    .contextMenu {
                        // PATCH-2026-06-06: chat-upgrades — message-level actions
                        Button {
                            ChatClipboard.copy(message.content)
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

                        if !isUser && isLastAssistant {
                            Button {
                                Task { await appModel.regenerateAssistantMessage(message) }
                            } label: {
                                Label("Regenerate response", systemImage: "arrow.clockwise")
                            }
                        }

                        Divider()

                        Button {
                            Task {
                                _ = await appModel.addMemoryFact(message.content)
                                showBubbleToast(appModel.statusText)
                            }
                        } label: { Label("Remember this", systemImage: "brain") }

                        Divider()

                        Button { showJSONSheet = true } label: {
                            Label("Show as JSON", systemImage: "curlybraces")
                        }
                    }
                    // The classic shell keeps the floating bar exactly where it
                    // was. The new shell does NOT — see the strip below.
                    .overlay(alignment: seatsRight ? .topTrailing : .topLeading) {
                        if !shellChrome {
                            hoverBar
                                .padding(.horizontal, 8)
                                .offset(y: -14)
                                .opacity(isHovered ? 1 : 0)
                                .scaleEffect(
                                    isHovered ? 1 : 0.96,
                                    anchor: seatsRight ? .topTrailing : .topLeading
                                )
                                .allowsHitTesting(isHovered)
                                // This is a pointer-only duplicate of the
                                // message's accessibility actions below.
                                // Keeping an opacity-zero button row in the AX
                                // tree creates phantom focus stops.
                                .accessibilityHidden(true)
                                .animation(NativeAgentMotion.snappy, value: isHovered)
                        }
                    }

                // Agent, 2026-09-02, named twice: the floating bar overlapped
                // the top of the bubble and landed ON the first line of the
                // message next to it — copy, speaker and thumbs sitting over
                // her words. It must never cover text, so in the new shell it
                // has its own strip UNDER the message.
                //
                // The strip is reserved whether or not the pointer is here.
                // That keeps hover LAYOUT-NEUTRAL (User, 2026-07-25): a row
                // that appears on hover changes the bubble's height, and every
                // scroll strategy shows that as a hop.
                if shellChrome {
                    hoverBar
                        .frame(height: NativeAgentShellLayout.hoverBarStrip, alignment: .center)
                        .opacity(isHovered ? 1 : 0)
                        .allowsHitTesting(isHovered)
                        .accessibilityHidden(true)
                        .animation(NativeAgentMotion.snappy, value: isHovered)
                }

                if !isUser, isLastAssistant, messageNeedsRetry {
                    Button {
                        Task { await appModel.regenerateAssistantMessage(message) }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(NativeAgentFont.label)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Hover must be LAYOUT-NEUTRAL (User, 2026-07-25, detached-panel
                // round 3): inserting this row on hover changed the bubble's
                // height, and any scroll strategy shows that as a hop — the
                // un-hover shrink was the "scrolls up when I move to the
                // composer" bug. Zero-height frame keeps the timestamp out of
                // layout permanently; the text overflow-draws into the
                // inter-bubble gap (where the inserted row used to render) and
                // only its opacity tracks hover.
                // Agent, 2026-09-03: measured 1.86:1 on the light room —
                // SwiftUI's hierarchical .tertiary over behind-window glass is
                // not a colour, it is a fade, and it failed the 4.5:1 floor by
                // a factor of 2.4. The shell's own tertiary token clears it in
                // both appearances; 10pt (the HIG floor) is kept.
                Text(timestamp)
                    .font(shellChrome ? ShellType.caption : NativeAgentFont.tag)
                    .foregroundStyle(shellChrome
                        ? AnyShapeStyle(NativeAgentShell.secondary)
                        : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    // Yield to bubbleToast below — both draw into the same
                    // gap, and the toast is the one the user just triggered.
                    .opacity(isHovered && bubbleToast == nil ? 1 : 0)
                    .frame(height: 0, alignment: .top)
                    .allowsHitTesting(false)

                // Bubble-local toast
                if let bt = bubbleToast {
                    Text(bt)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

            }
            .frame(
                maxWidth: shellChrome
                    ? NativeAgentShellLayout.roomColumn
                    : NativeAgentLayout.maxReadableChatWidth,
                alignment: seatsRight ? .trailing : .leading
            )
            .sheet(isPresented: $showJSONSheet) { MessageJSONSheet(message: message) }
            // User, 2026-09-02: the whole column, gaps included, is the hover
            // region, so moving the pointer from the words down onto the bar
            // keeps the bar; leaving the message anywhere drops it.
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(NativeAgentMotion.snappy) { isHovered = hovering }
            }

            if !seatsRight { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: seatsRight ? .trailing : .leading)
        .animation(NativeAgentMotion.snappy, value: bubbleToast)
        .modifier(MessageBubbleAccessibilityActions(
            isUser: isUser,
            isLastAssistant: isLastAssistant,
            onCopy: {
                ChatClipboard.copy(message.content)
                showBubbleToast("Copied")
            },
            onReadAloud: toggleReadAloud,
            onRegenerate: {
                Task { await appModel.regenerateAssistantMessage(message) }
            },
            onFeedback: { rating in
                postFeedback(messageId: message.id, rating: rating)
            }
        ))
        .onAppear { emitFirstRenderIfNeeded() }
        .onChange(of: message.content) { emitFirstRenderIfNeeded() }
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

    /// The per-message actions. One construction, two placements: floating
    /// over the bubble in the classic shell, in its own reserved strip under
    /// the message in the new one.
    private var hoverBar: some View {
        BubbleHoverBar(
            message: message,
            isLastAssistant: isLastAssistant,
            onCopy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                showBubbleToast("Copied")
            },
            onRegenerate: {
                Task { await appModel.regenerateAssistantMessage(message) }
            },
            onReadAloud: {
                toggleReadAloud()
            },
            onFeedback: { rating in
                postFeedback(messageId: message.id, rating: rating)
            }
        )
    }

    private func showBubbleToast(_ text: String) {
        withAnimation { bubbleToast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { bubbleToast = nil }
        }
    }

    private func toggleReadAloud() {
        if isReadingThisMessage {
            voiceOutput.stop()
            return
        }
        voiceOutput.nativeBaseURL = appModel.nativeBaseURL
        Task {
            await voiceOutput.speak(
                text: message.content,
                resolution: VoiceOutputModeSelection.resolve(for: appModel.trustPolicy),
                ownerID: speechOwnerID
            )
        }
    }

    private func emitFirstRenderIfNeeded() {
        let eligibility = ChatFirstRenderTelemetry.eligibility(
            role: message.role,
            content: message.content,
            isLastAssistant: isLastAssistant,
            messageSessionID: message.sessionId,
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
        if appModel.isSessionStreaming(message.sessionId ?? appModel.activeChatSessionId) && isLastAssistant && message.role == "assistant" {
            // Streaming stays raw: the in-flight bubble changes on every
            // coalesce tick, so neither the block split nor the markdown parse
            // may run here. Rich content resolves once the turn settles.
            Text(displayContent)
        } else {
            // 658.13: one pass over cached blocks. Prose keeps the existing
            // cached inline-markdown path; fenced code becomes a real code
            // block instead of the newline-collapsed mangle it used to be.
            let blocks = ChatRichContentCache.blocks(displayContent)
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
    @ViewBuilder
    private func proseText(_ text: String) -> some View {
        if let attributed = ChatMarkdownCache.attributed(text) {
            Text(attributed)
        } else {
            Text(text)
        }
    }

    private var messageNeedsRetry: Bool {
        message.metadata?.error?.isEmpty == false
            || message.metadata?.partial == true
            || message.metadata?.cancelled == true
    }

    private func postFeedback(messageId: String, rating: String) {
        // appModel.recordMessageFeedback doesn't exist yet — POST to context feedback,
        // otherwise no-op with a toast so the UI still works.
        let persona = appModel.chatPersona
        Task {
            do {
                try await appModel
                    .postContextFeedback(
                        messageId: messageId,
                        sessionId: message.sessionId ?? appModel.activeChatSessionId,
                        rating: rating,
                        persona: persona
                    )
                await MainActor.run { showBubbleToast(rating == "up" ? "Thanks for the thumbs up" : "Noted — will improve") }
            } catch {
                // ui-honesty 2026-06-10: nothing is stored on this path —
                // "Feedback noted (offline mode)" claimed success while
                // dropping the rating. Say it failed.
                await MainActor.run { showBubbleToast("Feedback failed to send") }
            }
        }
    }

    private var brainLine: String? {
        guard let metadata = message.metadata else { return nil }
        let model = metadata.model ?? metadata.requestedModel
        let effort = metadata.reasoningEffort
        let access = metadata.fileAccessMode
        if let model, let effort {
            return [model, effort, access].compactMap { $0 }.joined(separator: " / ")
        }
        return model ?? effort
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
    let onFeedback: (String) -> Void

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
            .accessibilityAction(named: "Mark response helpful") { onFeedback("up") }
            .accessibilityAction(named: "Mark response not helpful") { onFeedback("down") }
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
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        }
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: 160, height: 120)
                .overlay { ProgressView().controlSize(.small) }
                .task(id: attachment.path) { await loadImage() }
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
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Image attachment unavailable: "
                    + ChatLocalImageAttachmentPresentation.unavailableDetail(for: attachment)
            )
        }
    }

    private func loadImage() async {
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
    var onFeedback: (String) -> Void

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

            // Thumbs up/down — assistant messages only
            if isAssistant {
                BubbleAction(icon: "hand.thumbsup", help: "Good response", action: { onFeedback("up") })
                BubbleAction(icon: "hand.thumbsdown", help: "Bad response", action: { onFeedback("down") })
            }
        }
        .padding(.horizontal, NativeAgentSpacing.sm)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.control))
        .overlay(
            RoundedRectangle(cornerRadius: NativeAgentRadius.control)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
        )
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
                Text("Message JSON")
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
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(NativeAgentSpacing.xl)
        .frame(width: 540, height: 420)
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
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }
}
