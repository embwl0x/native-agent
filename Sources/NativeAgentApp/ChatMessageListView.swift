import SwiftUI
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
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

// PATCH-2026-05-08: wave2-chat-ux — groups consecutive tool messages into collapsible stacks
// B.6: MessageGrouper — shared grouping logic exposed as a static helper so the
// ForEach can live directly in the outer LazyVStack (enabling proper lazy rendering).
struct MessageGroup: Identifiable {
    var id: String
    var messages: [ChatMessage]
    var isToolGroup: Bool
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
    private struct Slot {
        var key: String
        var stableKey: String
        var groups: [MessageGroup]
    }
    // chat-smoothness phase 1: one slot PER SESSION (FIFO-capped) — a detached
    // panel viewing another session must not thrash the active session's slot
    // back to O(n) recomputes every tick.
    private var slots: [String: Slot] = [:]
    private var slotOrder: [String] = []
    private let slotCap = 8
    private let lock = NSLock()
    // S.3: sessionId included in cache key to prevent cross-session collisions
    func groups(for messages: [ChatMessage], sessionId: String) -> [MessageGroup] {
        // chat-smoothness phase 1: content.count lives OUTSIDE the stable key.
        // During streaming only the last bubble's content grows — the old
        // single key missed on EVERY delta tick, re-walking the whole list
        // ~20x/sec. Same shape + grown content now patches the cached last
        // group in place (O(1)) instead.
        let stableKey = "\(sessionId):\(messages.count):\(messages.last?.id ?? ""):\(messages.last?.role ?? "")"
        // Include the complete last-row display value, not only content length.
        // Equal-length text replacement and metadata-only status updates must
        // invalidate the row, while the stable key still enables the O(1)
        // streaming-assistant patch below.
        let key = "\(stableKey):\(messages.last?.hashValue ?? 0)"
        lock.lock(); defer { lock.unlock() }
        if let slot = slots[sessionId], slot.key == key {
            return slot.groups
        }
        // Fast path is assistant-only: only the streaming assistant bubble's
        // content ever grows in place, and _compute's visibility rules
        // (e.g. hiding "[tool:" system rows) can change with CONTENT for other
        // roles — patching those could keep a row _compute would now hide.
        if var slot = slots[sessionId], slot.stableKey == stableKey,
           let last = messages.last, last.role == "assistant",
           let lastGroup = slot.groups.last, !lastGroup.isToolGroup,
           lastGroup.messages.count == 1, lastGroup.messages[0].id == last.id {
            RenderAudit.bump("grouper.patch")
            var patched = lastGroup
            patched.messages[0] = last
            slot.groups[slot.groups.count - 1] = patched
            slot.key = key
            slots[sessionId] = slot
            return slot.groups
        }
        RenderAudit.bump("grouper.compute")
        let computed = MessageGrouper._compute(for: messages)
        if slots[sessionId] == nil {
            slotOrder.append(sessionId)
            if slotOrder.count > slotCap {
                slots.removeValue(forKey: slotOrder.removeFirst())
            }
        }
        slots[sessionId] = Slot(key: key, stableKey: stableKey, groups: computed)
        return computed
    }
}

enum MessageGrouper {
    static func groups(for messages: [ChatMessage], sessionId: String = "") -> [MessageGroup] {
        return _MessageGroupCache.shared.groups(for: messages, sessionId: sessionId)
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

    var body: some View {
        let lastAssistantId = messages.last(where: { $0.role == "assistant" })?.id
        let groups = MessageGrouper.groups(for: messages, sessionId: sessionId)
        // Same rule as the main window (ChatView): the live flip-box is the LAST
        // tool group while the session is still working and the reply text has
        // not started arriving yet.
        let liveAssistantStarted = messages.last?.role == "assistant"
            && messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let liveToolGroupId = (isStreaming && !liveAssistantStarted)
            ? groups.last(where: { $0.isToolGroup })?.id : nil
        ForEach(groups) { group in
            if group.isToolGroup {
                if group.messages.count == 1 {
                    let msg = group.messages[0]
                    let kind = msg.metadata?.kind ?? ""
                    if kind == "approval_pending" {
                        InlineApprovalCard(message: msg)
                    } else {
                        ToolPillView(message: msg)
                    }
                } else {
                    ToolCallGroup(
                        messages: group.messages,
                        isLive: liveToolGroupId != nil && group.id == liveToolGroupId
                    )
                }
            } else {
                let msg = group.messages[0]
                MessageBubble(
                    message: msg,
                    isLastAssistant: msg.role == "assistant" && msg.id == lastAssistantId
                )
                // phase 6: entrance animates ONLY when the append seam
                // (appendChatMessage) supplies a transaction; removals and
                // wholesale replaces are .identity → instant (no animated
                // teardown on the end-of-turn id swap or session switch).
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 8)),
                    removal: .identity))
            }
        }
    }
}

// PATCH-2026-05-08: wave2-chat-ux — ToolPillView for role=tool messages
struct ToolPillView: View {
    var message: ChatMessage
    @State private var expanded = false

    private var meta: ChatMessageMetadata? { message.metadata }
    private var toolName: String { meta?.toolName ?? "tool" }
    private var outcome: ToolOutcome {
        guard let ok = meta?.ok else { return .pending }
        return ok ? .succeeded : .failed
    }
    private var durationMs: Int { meta?.durationMs ?? 0 }
    private var resultSummary: String { meta?.resultSummary ?? "" }

    private enum ToolOutcome {
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
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
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
                    // Duration badge
                    if durationMs > 0 {
                        Text("\(durationMs)ms")
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
        // Fix 4: use split(separator:maxSplits:) to avoid double-materialising the full array
        let beforeLines = before.split(separator: "\n", maxSplits: 1001, omittingEmptySubsequences: false).map(String.init)
        let afterLines = after.split(separator: "\n", maxSplits: 1001, omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        // Simple line-by-line diff (no LCS — good enough for inline preview)
        let maxLen = max(beforeLines.count, afterLines.count)
        for i in 0..<min(maxLen, 60) {
            let b = i < beforeLines.count ? beforeLines[i] : nil
            let a = i < afterLines.count ? afterLines[i] : nil
            if b == a {
                result.append(" \(b ?? "")")
            } else {
                if let b { result.append("-\(b)") }
                if let a { result.append("+\(a)") }
            }
        }
        if maxLen > 60 { result.append("... (\(maxLen - 60) more lines)") }
        return result
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

    private var meta: ChatMessageMetadata? { message.metadata }
    private var approvalId: String { meta?.approvalId ?? "" }

    var body: some View {
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
            let alreadyResolved = resolved || (externalDecision != nil && externalDecision != "pending")
            if alreadyResolved {
                let decision = resolvedDecision.isEmpty ? externalDecision : resolvedDecision
                let approved = decision == "approved"
                let rejected = decision == "denied" || decision == "rejected"
                let badge = approved ? "Approved" : (rejected ? "Rejected" : "Resolved")
                let icon = approved ? "checkmark.circle.fill" : (rejected ? "xmark.circle.fill" : "checkmark.circle")
                Label(badge, systemImage: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(approved ? Color.green : (rejected ? Color.red : Color.secondary))
            } else {
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
    var messages: [ChatMessage]
    /// True only for the currently-streaming last group: show the live
    /// flip-through box. Otherwise collapse to an "N tools used" summary.
    var isLive: Bool = false
    @State private var toolsExpanded = false
    @State private var skillsExpanded = false

    // Skill use shows up as these tool calls — split them into their own
    // "N skills used" box, separate from regular tools.
    private static let skillToolNames: Set<String> = ["read_skill", "list_skills"]
    private func isSkill(_ msg: ChatMessage) -> Bool {
        Self.skillToolNames.contains(msg.metadata?.toolName ?? "")
    }
    private var skillMsgs: [ChatMessage] { messages.filter(isSkill) }
    private var toolMsgs: [ChatMessage] { messages.filter { !isSkill($0) } }

    // An unresolved approval must never be hidden behind a collapsed summary.
    private var hasPendingApproval: Bool {
        messages.contains { ($0.metadata?.kind ?? "") == "approval_pending" }
    }

    var body: some View {
        if hasPendingApproval {
            fullList
        } else if isLive {
            liveBox
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
        .animation(.easeOut(duration: 0.22), value: messages.last?.id)
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
                withAnimation(.easeOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
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
                    let kind = msg.metadata?.kind ?? ""
                    if kind == "approval_pending" { InlineApprovalCard(message: msg) }
                    else { ToolPillView(message: msg) }
                }
            }
        }
    }

    private var fullList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(messages) { msg in
                let kind = msg.metadata?.kind ?? ""
                if kind == "approval_pending" {
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
        ChatSlashCommandRegistry.visible(showDeveloperSurfaces: showDeveloperSurfaces).map {
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
        guard let parsed = try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
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

struct MessageBubble: View {
    var message: ChatMessage
    /// Whether this is the last assistant message in the list (enables Regenerate action)
    var isLastAssistant: Bool = false

    @State private var voiceOutput = VoiceOutputController()
    @AppStorage("voiceUseOpenAI") private var voiceUseOpenAI = false
    @Environment(AppModel.self) private var appModel
    @State private var showJSONSheet = false
    @State private var bubbleToast: String? = nil
    @State private var isHovered = false

    private var isUser: Bool { message.role == "user" }
    private var displayRole: String {
        switch message.role {
        case "user": "You"
        // The configured persona profile name — NOT the
        // chatPersona style quick-switch, which can read "Custom"/"AI".
        case "assistant": appModel.agentDisplayName
        default: message.role.capitalized
        }
    }

    private var userCorners: RectangleCornerRadii {
        .init(topLeading: 8, bottomLeading: 8, bottomTrailing: 3, topTrailing: 8)
    }

    var body: some View {
        let _ = RenderAudit.bump("bubble.body")
        HStack(alignment: .bottom, spacing: NativeAgentSpacing.sm) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: NativeAgentSpacing.xs) {
                if !isUser {
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

                // Message content bubble
                VStack(alignment: isUser ? .trailing : .leading, spacing: NativeAgentSpacing.sm) {
                    if !trimmedContent.isEmpty {
                        renderedMessageText
                    } else if localImageAttachments.isEmpty && nonImageAttachments.isEmpty {
                        Text(" ")
                    }
                    ForEach(localImageAttachments, id: \.id) { attachment in
                        MessageLocalImageAttachmentView(attachment: attachment)
                    }
                    ForEach(nonImageAttachments, id: \.id) { attachment in
                        MessageAttachmentChipView(attachment: attachment)
                    }
                }
                    .font(NativeAgentFont.body)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: isUser ? 540 : NativeAgentLayout.maxReadableChatWidth, alignment: isUser ? .trailing : .leading)
                    .padding(.horizontal, isUser ? NativeAgentSpacing.md : 0)
                    .padding(.vertical, isUser ? NativeAgentSpacing.sm + 2 : NativeAgentSpacing.xs)
                    .background {
                        if isUser {
                            UnevenRoundedRectangle(cornerRadii: userCorners, style: .continuous)
                                .fill(NativeAgentBrand.accentDeep)
                        }
                    }
                    .overlay {
                        if isUser {
                            UnevenRoundedRectangle(cornerRadii: userCorners, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                        }
                    }
                    .foregroundStyle(isUser ? Color.white : Color.primary)
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
                                Label(voiceOutput.isSpeaking ? "Stop reading" : "Read aloud", systemImage: voiceOutput.isSpeaking ? "speaker.slash" : "speaker.wave.2")
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
                    .overlay(alignment: isUser ? .topTrailing : .topLeading) {
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
                        .padding(.horizontal, 8)
                        .offset(y: -14)
                        .opacity(isHovered ? 1 : 0)
                        .scaleEffect(isHovered ? 1 : 0.96, anchor: isUser ? .topTrailing : .topLeading)
                        .allowsHitTesting(isHovered)
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
                Text(displayTimestamp)
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.tertiary)
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
            .frame(maxWidth: NativeAgentLayout.maxReadableChatWidth, alignment: isUser ? .trailing : .leading)
            .sheet(isPresented: $showJSONSheet) { MessageJSONSheet(message: message) }
            .onHover { hovering in
                withAnimation(NativeAgentMotion.snappy) { isHovered = hovering }
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .animation(NativeAgentMotion.snappy, value: bubbleToast)
        .accessibilityAction(named: "Copy message") {
            ChatClipboard.copy(message.content)
            showBubbleToast("Copied")
        }
        .accessibilityAction(named: "Read message aloud") {
            if !isUser { toggleReadAloud() }
        }
        .onAppear { emitFirstRenderIfNeeded() }
        .onChange(of: message.content) { emitFirstRenderIfNeeded() }
        // Read-aloud failures (trust denied / not configured / auth rejected)
        // land in voiceOutput.errorMessage, which nothing else reads — surface
        // them in the bubble toast. Cleared after showing so a repeat failure
        // re-fires.
        .onChange(of: voiceOutput.errorMessage) {
            if let msg = voiceOutput.errorMessage {
                showBubbleToast(msg)
                voiceOutput.errorMessage = nil
            }
        }
    }

    private func showBubbleToast(_ text: String) {
        withAnimation { bubbleToast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { bubbleToast = nil }
        }
    }

    private func toggleReadAloud() {
        if voiceOutput.isSpeaking {
            voiceOutput.stop()
            return
        }
        voiceOutput.nativeBaseURL = appModel.nativeBaseURL
        Task {
            await voiceOutput.speak(
                text: message.content,
                mode: voiceUseOpenAI ? .openai : .local
            )
        }
    }

    private func emitFirstRenderIfNeeded() {
        guard message.role == "assistant",
              isLastAssistant,
              !trimmedContent.isEmpty else {
            return
        }
        let sessionId = message.sessionId ?? appModel.activeChatSessionId
        guard appModel.isSessionStreaming(sessionId) else { return }
        Task {
            if let event = await TurnFirstRenderRegistry.shared.claimFirstRenderEvent(
                sessionId: sessionId,
                observedBy: "NativeAgentApp.MessageBubble"
            ) {
                TurnTraceBus.fire(event)
            }
        }
    }

    @ViewBuilder
    private var renderedMessageText: some View {
        // PATCH-2026-05-13: parallel-sessions — check streaming on the
        // message's own session, not the active session, so an in-flight
        // bubble in a non-active session still renders correctly when the
        // user switches back to view it.
        if appModel.isSessionStreaming(message.sessionId ?? appModel.activeChatSessionId) && isLastAssistant && message.role == "assistant" {
            Text(message.content)
        } else if let attributed = ChatMarkdownCache.attributed(message.content) {
            Text(attributed)
        } else {
            Text(message.content)
        }
    }

    private var trimmedContent: String {
        message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var messageNeedsRetry: Bool {
        message.metadata?.error?.isEmpty == false
            || message.metadata?.partial == true
            || message.metadata?.cancelled == true
    }

    private var displayTimestamp: String {
        UserDisplayFormatters.chatTimestamp(message.createdAt)
    }

    private var localImageAttachments: [PersistedAttachment] {
        (message.metadata?.attachments ?? []).filter { attachment in
            attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
                && (attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }

    /// Sweep R4 C14: everything the image branch above filters OUT used to
    /// render NOTHING — attach a PDF and the bubble was blank. These get a
    /// compact chip so the transcript still shows what was sent. Deliberately
    /// includes image-typed rows with no local path: the bytes are gone, but
    /// the fact that an image was attached is not.
    private var nonImageAttachments: [PersistedAttachment] {
        (message.metadata?.attachments ?? []).filter { attachment in
            !(attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image"
                && (attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false))
        }
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
        if let image = loadedImage {
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
        } else if imagePath != nil && !loadFailed {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: 160, height: 120)
                .overlay { ProgressView().controlSize(.small) }
                .task(id: attachment.path) { await loadImage() }
        }
    }

    private func loadImage() async {
        guard let path = imagePath else { return }
        let url = URL(fileURLWithPath: path)
        // F10: consult the shared cache first. The stat stays off the main
        // actor like the read does — a hit costs one syscall instead of a full
        // file read + decode, and returns the identical decoded image.
        let key = await Task.detached(priority: .userInitiated) {
            ChatImageCache.identityKey(for: url)
        }.value
        if let key, let cached = ChatImageCache.image(forKey: key) {
            loadedImage = cached
            return
        }
        // Keep the disk read off the render path; NSImage decoding stays lazy.
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data, let image = NSImage(data: data) else {
            loadFailed = true
            return
        }
        // Only cache under a real file identity; an unstat-able file stays
        // uncached rather than being keyed on a guess.
        if let key { ChatImageCache.store(image, forKey: key) }
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

// PATCH-2026-05-08: polish-wave — JSON debug sheet for message context menu
private struct MessageJSONSheet: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    private var jsonText: String {
        var dict: [String: Any] = [
            "id": message.id,
            "role": message.role,
            "content": message.content,
        ]
        if let sid = message.sessionId { dict["session_id"] = sid }
        if let rid = message.runId { dict["run_id"] = rid }
        if let src = message.source { dict["source"] = src }
        dict["created_at"] = message.createdAt
        if let meta = message.metadata {
            var metaDict: [String: Any] = [:]
            if let m = meta.model { metaDict["model"] = m }
            if let k = meta.kind { metaDict["kind"] = k }
            if let t = meta.toolName { metaDict["tool_name"] = t }
            if let r = meta.resultSummary { metaDict["result_summary"] = r }
            if let ok = meta.ok { metaDict["ok"] = ok }
            dict["metadata"] = metaDict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
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
