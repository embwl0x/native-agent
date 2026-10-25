import ApprovalInbox
import Transcripts
import ChatTurnRuntime
import ApprovalTransactions
import Foundation
import Observation
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `TranscriptReadProjection.swift` | transcript/read caches; `ChatShellConversationRow`: `isWorking`, `preview`, `isBridgeRouted`; conversation and running-session routes, turn card/trouble projection and native title-source classification. Stored human titles stay native; automated title prose is removed to the batched `presentation-copy.js` face before TranscriptsFacade publishes. No render-triggered naming or view-owned anchor reader |

/// A conversation row's two lines. The list must never show a machine id: a
/// Telegram chat id or an iOS session hash tells a person nothing, and the
/// bridge's `[from: …]` routing prefix is plumbing, not a title.
public enum ChatShellConversationRow {
    public static let bridgePrefix = BridgeRoutingPrefix.prefix
    public static let titleLimit = 30

    /// True for the bridge/agent sessions that collapse into one "Working" row.
    @MainActor
    public static func isWorking(_ session: NativeAgentShared.ChatSession) -> Bool {
        let source = session.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["bridge", "agent_bridge", "claude", "codex"].contains(source)
            || source.hasSuffix("-bridge")
            // Bridge turns can use the chat surface and persist as source "app".
            || ChatShellOpeningLine.shared.isBridgeRouted(for: session)
    }

    /// Whether the STORED row says it arrived through the agent bridge.
    ///
    /// 2026-09-06: the transcript renderer decided this from the TEXT alone, so
    /// a person who typed "[from: codex, via bridge] …" had their own words
    /// moved out of their seat, the prefix deleted, and the canonical
    /// provenance badge suppressed. Core already fixed the same class in
    /// `ChatTranscriptEvidenceRendering.isBridgeRouted`; this is the same rule
    /// at the presentation boundary. The bridge stamps `metadata.origin.surface`
    /// (`claude-bridge`, `codex-bridge`, `omp-bridge`) on everything it
    /// delivers; a row the person typed here has no origin record at all.
    public static func isBridgeRouted(_ origin: ChatMessageOriginMetadata?) -> Bool {
        guard let surface = origin?.surface?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !surface.isEmpty
        else { return false }
        return surface == "bridge" || surface.hasSuffix("-bridge")
    }

    public static func hasBridgePrefix(_ value: String?) -> Bool {
        guard let value else { return false }
        // Bounded: a routing group lives in the first 96 characters or nowhere,
        // so this must not copy a whole streaming reply to find out.
        return BridgeRoutingPrefix.hasGroup(value)
    }

    private static func bridgeGroup(_ trimmed: String) -> Substring? {
        BridgeRoutingPrefix.group(trimmed)
    }

    public static func stripBridgePrefix(_ text: String) -> String {
        BridgeRoutingPrefix.stripping(text)
    }

    /// The agent named by a `[from: <agent>, via bridge]` prefix, capitalized
    /// for the small tag above the bubble. nil when there is no such prefix.
    /// The value is length-capped and alphanumeric-only, so a hostile payload
    /// cannot smuggle control characters into the tag.
    public static func bridgeAgentTag(_ text: String) -> String? {
        // The group is capped at 96 characters, so the bounded head holds all
        // of it — and the whole message is never copied to read a 24-char name.
        let trimmed = BridgeRoutingPrefix.boundedHead(text)
        guard let group = bridgeGroup(trimmed) else { return nil }
        let close = trimmed.index(before: group.endIndex)
        let inside = trimmed[trimmed.index(trimmed.startIndex, offsetBy: bridgePrefix.count)..<close]
        let agent = inside.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A script is named as what it is, not as a squashed filename.
        if agent.lowercased() == "install_app.sh" { return "Install script" }
        let safe = agent.filter { $0.isLetter || $0.isNumber }
        guard !safe.isEmpty, safe.count <= 24 else { return nil }
        return safe.prefix(1).uppercased() + safe.dropFirst()
    }

    /// A stored title that is really a machine id, not a name a person chose.
    public static func isMachineTitle(_ title: String, session: NativeAgentShared.ChatSession) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == NativeAgentShared.ChatSession.placeholderTitle { return true }
        // Recovery names a session after the fact; it is a label, not a title.
        if value == "Recovered Chat" { return true }
        if session.source == "ios", value == "iOS chat \(session.id.prefix(8))" { return true }
        let key = (session.sourceKey ?? "").split(separator: ":")
        if session.source == "telegram", key.first == "telegram", key.count == 2 || key.count == 3 {
            let generated = "Telegram \(key[1])" + (key.count == 3 ? " topic \(key[2])" : "")
            return value == generated
        }
        if session.source == "slack", key.count >= 3 {
            if (key[0] == "conversation" || key[0] == "thread"), key[2].hasPrefix("D"),
               value.hasPrefix("Slack DM "), !value.dropFirst("Slack DM ".count).isEmpty { return true }
            if key[0] == "thread" { return value == "Slack Thread \(key[2])" }
            if key[0] == "conversation" {
                return value == "Slack \(key[2])" || value == "Slack MPIM \(key[2])"
            }
        }
        return false
    }

    /// The row's first line.
    ///
    /// Agent, 2026-09-02: this used to fall back to `lastMessagePreview`, so a
    /// conversation was renamed by whatever was said in it LAST — the row's
    /// name changed every turn, and forty morning briefs all read "Hey User 😊
    /// Good to see you…". A conversation is named ONCE, from how it opened.
    ///
    /// The source, in order:
    ///  1. The stored session title. Persistence writes it once, from the
    ///     first USER message (`shouldReplaceSessionTitle`), so it already IS
    ///     the first user line for every session that has one.
    ///  2. `openingLine` — the first user line read from the transcript, for
    ///     rows whose stored title is a machine id (`Telegram 1394548068`) or
    ///     the "New Chat" placeholder. A session with no user turn at all
    ///     (a proactive greeting or brief) supplies its first ASSISTANT line
    ///     here instead.
    ///  3. "New conversation".
    ///
    /// The last message is never a source. No summarizer, no model call.
    public static func titleSource(for session: NativeAgentShared.ChatSession, openingLine: String?) -> (text: String, automated: Bool) {
        let stored=stripBridgePrefix(session.title), opening=stripBridgePrefix(openingLine ?? "")
        let candidate = !isMachineTitle(stored,session:session) ? stored : opening
        if candidate.isEmpty { return ("New conversation",false) }
        let text=candidate.trimmingCharacters(in:.whitespacesAndNewlines)
        // Exact historical machine envelopes classify source identity. Human
        // titles keep the native title path; editable copy cannot rename them.
        let automated=text.hasPrefix("[Woken by ") || text.hasPrefix("Current standing instructions for ")
            || text.contains(/^Codex (replied to (your message|\d+ queued messages)|(wakeup failed|turn stalled|wakeup produced no reply)( for \d+ queued messages)?)\.(\s|$)/)
        return automated ? (text,true) : (clamp(plainText(candidate)),false)
    }

    public static func preview(for session: NativeAgentShared.ChatSession) -> String {
        plainText(stripBridgePrefix(session.lastMessagePreview ?? ""))
    }

    /// The row's second line: the last thing said, cut at a word to fit
    /// beside the time. Never the title (Agent, 2026-09-02, above), and empty
    /// when the last thing said IS the title, so the row keeps its old line.
    public static func listPreview(for session: NativeAgentShared.ChatSession, title: String) -> String {
        let said = preview(for: session)
        // A cut title matches on its words so far; a whole one, exactly.
        let repeats = title.hasSuffix("…")
            ? title.count > 1 && said.hasPrefix(title.dropLast())
            : said == title
        if repeats { return "" }
        return clamp(said, limit: previewLimit)
    }
    public static let previewLimit = 26

    /// Titles carry whatever the person typed, including markdown. A row is
    /// plain text: backticks, `**bold**`, list bullets and heading hashes are
    /// markup, not words, and reading them in a sidebar is noise.
    public static func plainText(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\n", with: " ")
        // A leading wrapper tag ("[Telegram voice message] …") is plumbing.
        while text.hasPrefix("["), let close = text.firstIndex(of: "]"),
              text.distance(from: text.startIndex, to: close) <= 40 {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        // A voice turn arrives as "Transcript: …"; the word is the pipeline's.
        if let range = text.range(of: #"^\W*transcript\W*"#, options: [.regularExpression, .caseInsensitive]) {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        for marker in ["```", "**", "__", "~~", "`", "*"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        // A leading line marker only: "# Title", "> quoted", "- item".
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = trimmed.first, first == "#" || first == ">" || first == "-" {
            trimmed = trimmed.dropFirst()
            while trimmed.first == " " { trimmed = trimmed.dropFirst() }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the conversation is happening, in the words a person uses.
    @MainActor
    public static func surface(for session: NativeAgentShared.ChatSession) -> String {
        if isWorking(session) { return "Connected agent" }
        switch session.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "telegram": return "Telegram"
        case "ios", "iphone", "ipad", "mobile", "icloud": return "iPhone"
        case "slack": return "Slack"
        case "bridge", "agent_bridge", "claude", "codex": return "Connected agent"
        default: return "Mac"
        }
    }

    /// Local conversations show only their age; other surfaces also name
    /// where the conversation happened.
    public static let localSurface = "Mac"

    /// Cut at a word boundary, never mid-word.
    static func clamp(_ value: String, limit: Int = titleLimit) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        // One character past the limit tells us whether the cut already fell
        // on a boundary; otherwise back up to the last space inside it.
        let window = flat.prefix(limit + 1)
        let head: Substring
        if let space = window.lastIndex(of: " ") {
            head = window[..<space]
        } else {
            head = flat.prefix(limit)
        }
        let word = head.trimmingCharacters(in: .whitespaces)
        return String((word.isEmpty ? String(flat.prefix(limit)) : word).trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?—-"))) + "…"
    }
}

/// A completion envelope: the routing slip a worker's reply arrives in
/// ("Originating message id: …", topic, status, then "--- Claude's reply ---").
/// The room shows the reply and folds the slip, the way tool traffic folds.
public enum ChatShellEnvelope {
    public static let replyMarkers = ["--- Claude's reply ---", "--- OMP's reply ---"]
    public static let endMarker = "--- end reply ---"
    public static let completionNotice = "this is an asynchronous completion event for work you delegated."

    public static func isEnvelope(_ content: String, envelope: ChatMessageOriginMetadata?) -> Bool {
        // 2026-09-28: Only a recorded built-in lane may fold; peers can write every body marker.
        // A row saved before envelopes were recorded has none, and folds on its opening alone.
        if let envelope {
            guard let agent = envelope.agent, ["codex", "claude", "omp"].contains(agent),
                  envelope.surface == agent + "-bridge" else { return false }
        }
        let head = ChatShellConversationRow.stripBridgePrefix(content).prefix(400).lowercased()
        return head.hasPrefix("originating message id:")
            || head.hasPrefix("[claude-wake]")
            || head.hasPrefix("[omp-wake]")
            // The delegation loop's own note about a lane's job (unverified delivery etc.).
            || head.hasPrefix("[delegation update from nativeagent")
            || codexTitle(content) != nil
    }

    private static func codexTitle(_ content: String) -> String? {
        let text = ChatShellConversationRow.stripBridgePrefix(content)
        let rows = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard rows.count == 3, rows[1].isEmpty,
              rows[2].prefix(completionNotice.count).lowercased() == completionNotice,
              text.contains("\nCodex result:\n") else { return nil }
        let title = String(rows[0]).lowercased()
        guard title.hasPrefix("codex replied to ") || title.hasPrefix("codex wakeup failed")
            || title.hasPrefix("codex turn stalled") || title.hasPrefix("codex wakeup produced no reply")
        else { return nil }
        return title
    }

    /// The completion result, or the words between the legacy reply markers.
    public static func reply(_ content: String) -> String {
        if codexTitle(content) != nil {
            guard let start = content.range(of: "\nCodex result:\n") else { return "" }
            var result = content[start.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if result.hasSuffix(" to ask whether Codex finished."),
               let footer = result.range(of: "\n\nNow give ", options: .backwards) {
                result = String(result[..<footer.lowerBound])
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var text = content
        if let start = replyMarkers.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            text = String(text[start.upperBound...])
        }
        if let end = text.range(of: endMarker) { text = String(text[..<end.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Completion status with the slip's duration, when present.
    public static func headline(_ content: String) -> String {
        // 2026-09-28: Codex records failure, stalls and missing replies in its title, without a status line.
        if let title = codexTitle(content), !title.hasPrefix("codex replied to ") {
            return "The connected agent didn't finish"
        }
        let text = ChatShellConversationRow.stripBridgePrefix(content)
        let boundary = (replyMarkers + ["\nCodex result:\n"])
            .compactMap { text.range(of: $0)?.lowerBound }.min() ?? text.endIndex
        let header = text[..<boundary]
        let line = header.split(whereSeparator: \.isNewline)
            .first { $0.lowercased().hasPrefix("duration:") }
            .map { $0.dropFirst("duration:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        let seconds = Int(line.filter(\.isNumber)) ?? 0
        if header.lowercased().hasPrefix("[claude-wake] [notice]") { return "Delivered to Claude" }
        let status = header.split(whereSeparator: \.isNewline)
            .first { $0.lowercased().hasPrefix("status:") }
            .map { $0.dropFirst("status:".count).trimmingCharacters(in: .whitespaces).lowercased() }
        if ["failed", "rejected", "stalled", "cancelled", "canceled"].contains(status ?? "") {
            return "The connected agent didn't finish"
        }
        guard seconds > 0 else { return "The connected agent finished" }
        return seconds < 90 ? "The connected agent finished · under a minute" : "The connected agent finished · \(seconds / 60) min"
    }
}

/// Opening words, recorded bridge provenance and the last turn's timestamp.
/// ChatTranscriptCache warms each generation/count before index publication;
/// renderers distinguish an unresolved row from an empty transcript.
@MainActor
@Observable
public final class ChatShellOpeningLine {
    public static let shared = ChatShellOpeningLine()

    /// How far in the scan will look for the first spoken line. Agent,
    /// 2026-09-02: a byte budget was the wrong ruler — one session opens with
    /// a 9 KB memory block and another says nothing human until row 21, 120 KB
    /// in, so both rows read "New conversation" while their real opening lines
    /// sat just past the cap. The scan is bounded by ROWS, with a byte ceiling
    /// only so a runaway file cannot be read whole.
    nonisolated private static let rowBudget = 200
    nonisolated private static let byteCeiling = 1 << 20
    /// Read granularity; a transcript row is rarely larger than this.
    nonisolated private static let chunkSize = 64 * 1024
    nonisolated private static let tailBytes = 8_192
    struct Projection: Sendable, Equatable {
        var revision = ""
        var line: String? = nil
        var isBridgeRouted = false
        var lastTurn: String? = nil
    }
    @ObservationIgnored private var cache: [String: Projection] = [:]
    @ObservationIgnored private let warmRead = LatestRead()
    public private(set) var revision: UInt64 = 0

    private init() {}

    /// The first user line of the session, or its first line of any role when
    /// no user ever spoke. nil when there is nothing to read.
    public func line(for session: NativeAgentShared.ChatSession) -> String? {
        projection(for: session).line
    }

    public func isBridgeRouted(for session: NativeAgentShared.ChatSession) -> Bool {
        projection(for: session).isBridgeRouted
    }

    public func stamp(for session: NativeAgentShared.ChatSession) -> String? {
        projection(for: session).lastTurn
    }

    public func prepare(_ sessions: [NativeAgentShared.ChatSession], dataRoot: URL) async throws {
        _ = try await prepareProjections(sessions, dataRoot: dataRoot)
    }

    func prepareProjections(_ sessions: [NativeAgentShared.ChatSession], dataRoot: URL) async throws -> [String: Projection] {
        try await warmRead.read({
            let projections = try await ChatTranscriptCache.shared.shellProjections(for: sessions, dataRoot: dataRoot, cached: cache)
            try Task.checkCancellation()
            return projections
        }, publish: { projections in
            guard cache != projections else { return }
            cache = projections
            revision &+= 1
        })
    }

    nonisolated static func revision(for session: NativeAgentShared.ChatSession) -> String {
        "\(session.transcriptGeneration ?? -1)#\(session.messageCount ?? -1)"
    }

    public func isPrepared(for session: NativeAgentShared.ChatSession) -> Bool {
        _ = revision
        return cache[session.id]?.revision == Self.revision(for: session)
    }

    private func projection(for session: NativeAgentShared.ChatSession) -> Projection {
        _ = self.revision
        let revision = Self.revision(for: session)
        if let hit = cache[session.id], hit.revision == revision { return hit }
        return Projection()
    }

    nonisolated static func read(sessionID: String, dataRoot: URL) -> Projection {
        guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            return Projection()
        }
        let url = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeID).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Projection() }
        defer { try? handle.close() }

        var firstBridge: String? = nil
        var projection = Projection()
        var buffer = Data()
        var read = 0
        var rows = 0
        let newline = UInt8(ascii: "\n")

        while rows < rowBudget, read < byteCeiling {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            read += chunk.count
            buffer.append(chunk)
            // Everything up to the last newline is whole rows; the remainder
            // is a partial row and waits for the next chunk.
            guard let lastBreak = buffer.lastIndex(of: newline) else { continue }
            let whole = buffer[..<lastBreak]
            buffer = Data(buffer[buffer.index(after: lastBreak)...])
            for line in whole.split(separator: newline) {
                rows += 1
                if rows > rowBudget { break }
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if let metadata = object["metadata"] as? [String: Any] {
                    // Recorded provenance only: a typed routing prefix is not evidence.
                    for key in ["origin", "envelope"] {
                        guard let provenance = metadata[key] as? [String: Any],
                              let surface = provenance["surface"] as? String else { continue }
                        if ChatShellConversationRow.isBridgeRouted(.init(surface: surface)) {
                            projection.isBridgeRouted = true
                        }
                    }
                }
                guard let spoken = spokenLine(object) else { continue }
                if !ChatShellConversationRow.hasBridgePrefix(spoken) {
                    projection.line = spoken
                    return projection
                } else if firstBridge == nil {
                    firstBridge = ChatShellConversationRow.stripBridgePrefix(spoken)
                }
            }
        }
        // Nobody human spoke, but an agent opened the thread: that line is
        // still a better name than "New conversation".
        projection.line = firstBridge
        return projection
    }

    /// One transcript row's user text, or nil when the row is not a person
    /// speaking (a system block, a tool result, her own turn) or does not
    /// parse — a clipped tail row is simply skipped.
    nonisolated private static func spokenLine(_ object: [String: Any]) -> String? {
        guard let content = object["content"] as? String
        else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let role = (object["role"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard role == "user" else { return nil }
        // A row that is nothing but a bracketed pipeline note — "[The user
        // sent an image with no caption…]" — carries no words to name a
        // conversation with. Keep looking.
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.contains("\n") {
            return nil
        }
        return trimmed
    }
    nonisolated static func readLastTurn(sessionID: String, dataRoot: URL) -> String? {
        guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else { return nil }
        let url = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeID).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // The first line of a mid-file read is a fragment; walk from the end
        // and take the newest row that parses.
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let stamp = (object["timestamp"] ?? object["createdAt"] ?? object["created_at"]) as? String, !stamp.isEmpty {
                return stamp
            }
        }
        return nil
    }
}

extension ChatShellConversationRow {
    /// A session with messages where no person ever spoke: her morning briefs
    /// and other things she started on her own.
    @MainActor
    public static func isHerOwn(_ session: NativeAgentShared.ChatSession) -> Bool {
        guard ChatShellOpeningLine.shared.isPrepared(for: session),
              isMachineTitle(stripBridgePrefix(session.title), session: session),
              (session.messageCount ?? 0) > 0 else { return false }
        return ChatShellOpeningLine.shared.line(for: session) == nil
    }

    /// Render the title already resolved by TranscriptsFacade.
    @MainActor
    public static func title(for session: NativeAgentShared.ChatSession) -> String {
        session.displayTitle
    }
}

extension TranscriptSearch {
    public static func documents(from messages: [ChatMessage]) -> [TranscriptSearchDocument] {
        messages.enumerated().compactMap { ordinal, message in
            document(from: message, ordinal: ordinal)
        }
    }

    public static func document(from message: ChatMessage, ordinal: Int) -> TranscriptSearchDocument? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role != "tool" else { return nil }
        guard !(role == "system" && message.content.hasPrefix("[tool:")) else { return nil }
        let visible = visibleText(of: message)
        guard !visible.isEmpty else { return nil }
        return TranscriptSearchDocument(
            messageID: message.id,
            ordinal: ordinal,
            content: visible
        )
    }

    /// 2026-09-06: search used to index the RAW row, so a hit inside a
    /// completion envelope's routing slip selected a row whose slip the room
    /// never renders — the transcript folds a bridge receipt into
    /// `ShellEnvelopeRow`, and even "Show" reveals only the extracted reply.
    /// The index now carries the substantive text, which is a subset of what
    /// the bubble displays, so a match is always
    /// reachable. The bridge-routed fences match the renderer's exactly (see
    /// `ChatShellConversationRow.isBridgeRouted`).
    public static func visibleText(of message: ChatMessage) -> String {
        let content = message.content
        guard ChatShellConversationRow.isBridgeRouted(message.metadata?.origin) else {
            return content
        }
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if role == "user", ChatShellEnvelope.isEnvelope(content, envelope: message.metadata?.envelope) {
            return ChatShellEnvelope.reply(content)
        }
        if role == "user", message.metadata?.origin?.surface?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "agent-bridge" {
            return ContactThread.bridgedText(content)
        }
        guard ChatShellConversationRow.hasBridgePrefix(content) else { return content }
        return ChatShellConversationRow.stripBridgePrefix(content)
    }

}

/// 658.14 — a reachable identity for each chat session that is running a turn
/// somewhere other than the foreground.
///
/// Before this, the "N other sessions running" banner offered exactly one
/// action once N exceeded 1: a bulk "Stop Others". The multi-session case —
/// the only case where you actually need to find the work — was the case with
/// no way to reach it, and the sole affordance was destructive.
///
/// Titles are attacker-influenced. A session title can be auto-derived from
/// message content, and message content includes untrusted bridge payloads, so
/// a title can carry newlines, control characters, bidi overrides, or
/// unbounded length. This projection therefore hard-bounds every title before
/// it reaches a menu: control characters removed (not replaced with something
/// that could re-parse), collapsed to a single line, and truncated. A session
/// with no usable title falls back to a short form of its id so the row is
/// still selectable rather than blank.
public struct MacChatRunningSessionRoute: Sendable, Equatable {
    public let sessionId: String
    /// Safe, bounded, single-line menu text. Never the raw stored title.
    public let title: String

    /// Total Unicode-scalar ceiling, including the truncation marker. A single
    /// extended grapheme may contain thousands of combining scalars, so
    /// `String.count`/`prefix` is not a data bound for attacker-influenced UI.
    public static let titleScalarLimit = 48

    /// Maximum input scalars inspected while deriving one title. Output was
    /// already bounded, but an all-format or all-combining-mark payload could
    /// previously make every banner render scan an arbitrarily large string
    /// before producing that small output.
    public static let titleInputScalarLimit = 512

    /// Build one route per running session id, skipping nothing. Known rows
    /// follow the canonical session-list order; stale ids sort by their stable
    /// identity so Set iteration cannot reorder the menu between renders.
    public static func routes(sessionIds: [String], sessions: [NativeAgentShared.ChatSession]) -> [MacChatRunningSessionRoute] {
        let sessionsById = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let canonicalOrder = Dictionary(
            sessions.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        let orderedIDs = sessionIds.filter { seen.insert($0).inserted }.sorted { lhs, rhs in
            let lhsOrder = canonicalOrder[lhs] ?? Int.max
            let rhsOrder = canonicalOrder[rhs] ?? Int.max
            return lhsOrder == rhsOrder ? lhs < rhs : lhsOrder < rhsOrder
        }
        let candidates = orderedIDs.map { sessionId in
            MacChatRunningSessionRoute(
                sessionId: sessionId,
                title: displayTitle(session: sessionsById[sessionId], sessionId: sessionId)
            )
        }

        // Every multi-route label gets an ordinal suffix, rather than only
        // labels that collide before suffixing. Otherwise a stored title such
        // as `X [1:a]` can collide with the generated label for another `X`
        // row. The ordinal is unique in this ordered projection and the suffix
        // is never truncated, so menu and VoiceOver labels stay distinct even
        // when titles are adversarially chosen.
        guard candidates.count > 1 else { return candidates }
        return candidates.enumerated().map { offset, route in
            return MacChatRunningSessionRoute(
                sessionId: route.sessionId,
                title: disambiguatedTitle(
                    route.title,
                    sessionId: route.sessionId,
                    ordinal: offset + 1
                )
            )
        }
    }

    public static func displayTitle(rawTitle: String?, sessionId: String) -> String {
        if let cleaned = sanitize(rawTitle), !cleaned.isEmpty {
            return cleaned
        }
        return fallbackTitle(sessionId: sessionId)
    }

    /// Bound the engine's resolved display title for a single menu line.
    private static func displayTitle(session: NativeAgentShared.ChatSession?, sessionId: String) -> String {
        guard let session else { return fallbackTitle(sessionId: sessionId) }
        return sanitize(session.displayTitle) ?? ""
    }

    /// Strip everything that could break out of a single menu line, collapse
    /// whitespace, and stop after a bounded number of Unicode scalars. Removal,
    /// not substitution — a replacement character is one more thing a spoofing
    /// payload can lean on.
    private static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(titleScalarLimit)
        var pendingSpace = false
        var truncated = false

        var examinedScalars = 0
        for scalar in raw.unicodeScalars {
            guard examinedScalars < titleInputScalarLimit else {
                truncated = true
                break
            }
            examinedScalars += 1
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || scalar.properties.generalCategory == .format {
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !scalars.isEmpty
                continue
            }
            // A leading combining/enclosing mark has no visible base and can
            // produce an apparently blank or misleading menu label. Marks are
            // retained only after a visible scalar has established a base.
            if scalars.isEmpty, isCombiningMark(scalar) {
                continue
            }
            if pendingSpace {
                // Leave room for both the collapsed space and this visible
                // scalar. Never emit a trailing space immediately before the
                // truncation marker.
                guard scalars.count + 1 < titleScalarLimit else {
                    truncated = true
                    break
                }
                scalars.append(Unicode.Scalar(0x20)!)
                pendingSpace = false
            }
            guard scalars.count < titleScalarLimit else {
                truncated = true
                break
            }
            scalars.append(scalar)
        }

        guard !scalars.isEmpty else { return nil }
        if truncated {
            let ellipsis = Unicode.Scalar(0x2026)!
            if scalars.count == titleScalarLimit {
                scalars[scalars.index(before: scalars.endIndex)] = ellipsis
            } else {
                scalars.append(ellipsis)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    /// A menu containing indistinguishable labels is technically clickable but
    /// not navigable in practice or through VoiceOver, so multi-route menus
    /// receive a bounded, deterministic identity suffix.
    private static func disambiguatedTitle(
        _ title: String,
        sessionId: String,
        ordinal: Int
    ) -> String {
        let token = safeSessionIDTail(sessionId) ?? String(ordinal)
        let suffix = " [\(ordinal):\(token)]"
        let suffixScalars = Array(suffix.unicodeScalars)
        guard suffixScalars.count < titleScalarLimit else { return "Running session \(ordinal)" }
        let baseLimit = titleScalarLimit - suffixScalars.count
        var baseScalars = Array(title.unicodeScalars.prefix(baseLimit))
        while baseScalars.last.map({ CharacterSet.whitespacesAndNewlines.contains($0) }) == true {
            baseScalars.removeLast()
        }
        return String(String.UnicodeScalarView(baseScalars + suffixScalars))
    }

    /// A short, stable stand-in that is always non-empty, so the menu row stays
    /// clickable even for an untitled or unknown session.
    private static func fallbackTitle(sessionId: String) -> String {
        guard let tail = safeSessionIDTail(sessionId) else { return "Untitled session" }
        return "Session " + tail
    }

    private static func safeSessionIDTail(_ sessionId: String) -> String? {
        var safeTail: [Unicode.Scalar] = []
        safeTail.reserveCapacity(8)
        var examinedScalars = 0
        for scalar in sessionId.unicodeScalars {
            guard examinedScalars < titleInputScalarLimit else { break }
            examinedScalars += 1
            guard isSafeSessionIDScalar(scalar) else { continue }
            if safeTail.count == 8 { safeTail.removeFirst() }
            safeTail.append(scalar)
        }
        guard !safeTail.isEmpty else { return nil }
        return String(String.UnicodeScalarView(safeTail))
    }

    private static func isSafeSessionIDScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122: // 0-9, A-Z, a-z
            return true
        case 45, 58, 95: // -, :, _
            return true
        default:
            return false
        }
    }
}

/// Process-local FIFO storage; callers own parsing and admission outside the lock.
public final class ChatContentCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Value] = [:]
    private var order: [String] = []
    private var totalChars = 0
    private let capacity = 300
    private let charBudget = 4_000_000

    public init() {}

    public func lookup(_ content: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return cache[content]
    }

    public func insertIfAbsent(_ parsed: Value, for content: String) {
        lock.lock()
        defer { lock.unlock() }
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
    }
}
/// Display-only projection of one accepted turn. Every field is derived; none
/// is stored, mutated, or remembered by the view layer.
public struct MacChatTurnCardModel: Sendable, Equatable {
    /// Visual register. Deliberately separate from phase so that
    /// outcome-unknown can never be rendered with the success or failure
    /// treatment even if a future phase is added to the working family.
    public enum Tone: Sendable, Equatable {
        /// The turn is moving. Accent, live indicator.
        case working
        /// Observationally stuck or blocked. Warm, but not an error.
        case attention
        /// Terminal and honest about not knowing. Neither green nor red.
        case unresolved
        /// Terminal failure asserted by typed evidence.
        case failed
        /// Terminal stop acknowledged by typed evidence.
        case canceled
    }

    public let identity: MacChatTurnIdentity
    /// The effective phase, including the derived observational `.stalled`.
    public let phase: TurnPresentationPhase
    public let title: String
    public let detail: String?
    public let delegateName: String?
    public let tone: Tone
    public let symbolName: String
    public let isTerminal: Bool
    public let showsLiveIndicator: Bool
    /// Wall time the turn has been open (live) or was open (terminal).
    public let elapsed: TimeInterval
    /// Seconds since the last observed movement; `nil` once terminal, because
    /// a settled turn has nothing left to move.
    public let secondsSinceMovement: TimeInterval?
    /// A stop was requested and no terminal evidence has arrived yet.
    /// Requesting a stop is not proof the turn stopped.
    public let cancellationPending: Bool
    /// The canonical approval this turn asked for, if any. Projected from the
    /// ApprovalInbox rows the app already holds — the card stores no approval
    /// state of its own and decides nothing.
    public let approval: MacChatTurnCardApproval?

    /// The timestamps the trailing readout is derived from, so the one-second
    /// readout can advance itself without the whole card being re-projected.
    /// `nil` means "no live clock": the card renders the frozen `elapsed` and
    /// `secondsSinceMovement` it was projected with, which is what a terminal
    /// turn (and every test that builds a model by hand) wants.
    public var clock: Clock? = nil

    /// Fluid glass A1: she is thinking and nothing has been said or done
    /// yet. The title line becomes "Thinking… 0:08", counting from here.
    public var thinkingSince: Date? = nil
    /// Her reply text is arriving and nothing else is going on: the line
    /// that said "Thinking…" says how long she thought.
    public var thoughtFor: TimeInterval? = nil

    /// Raw inputs for the trailing readout. Deliberately the same three
    /// timestamps the projection uses, so the self-advancing readout and a
    /// re-projection can never disagree about what second it is.
    public struct Clock: Equatable, Sendable {
        public let startedAt: Date
        public let endedAt: Date?
        public let lastMovementAt: Date
        public let isTerminal: Bool

        /// Whole seconds, matching `MacChatTurnCardProjection.wholeSeconds`:
        /// the readout shows seconds, so sub-second churn would re-render the
        /// text at token rate for a string that never changes.
        public static func wholeSeconds(_ interval: TimeInterval) -> TimeInterval {
            guard interval.isFinite, interval > 0 else { return 0 }
            return interval.rounded(.down)
        }

        public func elapsed(at instant: Date) -> TimeInterval {
            Self.wholeSeconds((endedAt ?? instant).timeIntervalSince(startedAt))
        }

        public func secondsSinceMovement(at instant: Date) -> TimeInterval? {
            isTerminal ? nil : Self.wholeSeconds(instant.timeIntervalSince(lastMovementAt))
        }
    }

    /// True only while the card still offers something to click. A settled
    /// card with no pending decision floats over the transcript and must be
    /// inert; one holding a live approval must not be.
    public var hasControls: Bool {
        !isTerminal || approval?.isActionable == true
    }

    /// Spoken form of the trailing timing readout. The visual string joins its
    /// parts with a middle dot and uses monospaced digits; read verbatim by
    /// VoiceOver that becomes punctuation noise, so the same facts are spoken
    /// as a sentence instead.
    public var spokenMeta: String {
        MacChatTurnCardFormat.metaLine(
            elapsed: elapsed,
            secondsSinceMovement: secondsSinceMovement,
            isTerminal: isTerminal,
            separator: ", "
        )
    }
}

public enum MacChatTurnCardProjection {
    /// Threshold at which "no movement" becomes worth saying out loud. Below
    /// the stall threshold this is informational only, not a verdict.
    public static let movementNoticeAfter: TimeInterval = 20

    /// The single projection seam. Returns `nil` when there is nothing left to
    /// say — no turn, a turn belonging to another session, or a turn whose
    /// outcome the transcript already carries.
    ///
    /// A card has no dismiss affordance and nothing clears a settled turn
    /// except the next turn in that session, so anything left visible here is
    /// permanent chrome floating over the transcript until the user sends
    /// again. That is only worth paying for a state the transcript CANNOT
    /// express. It can express all three proven terminals: `.completed` is the
    /// answer itself, `.failed` always lands with its error bubble, and
    /// `.canceled` leaves the partial reply the user stopped. `.outcomeUnknown`
    /// is the one terminal with no transcript representation — the whole point
    /// of the evidence work is that "we do not know how this ended" gets said
    /// out loud — so it alone keeps its card.
    ///
    /// Time-invariant visibility. Whether a card exists at all depends only on
    /// identity and settled phase, never on the clock — so layout gating and
    /// the card itself can never disagree for a frame.
    public static func isVisible(_ state: MacChatTurnLifecycleState?, sessionId: String) -> Bool {
        guard let state, !sessionId.isEmpty,
              state.identity.sessionId == sessionId else { return false }
        if state.replyTextSettled { return false }
        switch state.presentation.phase {
        case .completed, .failed, .canceled:
            return false
        case .acknowledged, .working, .tool, .delegation, .retrying,
             .waiting, .blocked, .stalled, .outcomeUnknown:
            return true
        }
    }

    /// Visibility including the turn's approval (Desk 658.12). A turn that
    /// finished cleanly still keeps its card while the approval it asked for is
    /// pending or ended unproven — those are precisely the states the
    /// transcript cannot express. A proven approve/deny adds no chrome.
    ///
    /// Still time-invariant: nothing here reads a clock.
    public static func isVisible(
        _ state: MacChatTurnLifecycleState?,
        sessionId: String,
        approvals: [ApprovalRecord],
        parseTimestamp: (String) -> Date?
    ) -> Bool {
        if isVisible(state, sessionId: sessionId) { return true }
        guard let state, !sessionId.isEmpty,
              state.identity.sessionId == sessionId else { return false }
        return approval(for: state, approvals: approvals, parseTimestamp: parseTimestamp)?.keepsCardVisible == true
    }

    public static func approval(
        for state: MacChatTurnLifecycleState,
        approvals: [ApprovalRecord],
        parseTimestamp: (String) -> Date?
    ) -> MacChatTurnCardApproval? {
        MacChatTurnApprovalProjection.approval(
            sessionId: state.identity.sessionId,
            turnStartedAt: state.presentation.startedAt,
            approvals: approvals,
            requester: NativeAgentChatApprovalFiler.requester(inTitle:),
            parseTimestamp: parseTimestamp
        )
    }

    public static func card(
        for state: MacChatTurnLifecycleState?,
        sessionId: String,
        personaName: String,
        at instant: Date,
        approvals: [ApprovalRecord] = [],
        parseTimestamp: (String) -> Date?,
        stalledAfter: TimeInterval = TurnPresentationReducer.defaultStalledAfter
    ) -> MacChatTurnCardModel? {
        // Identity fence. A card belongs to exactly one session and one turn;
        // a state routed to the wrong surface renders nothing rather than
        // cross-rendering another conversation's work.
        guard let state,
              isVisible(state, sessionId: sessionId, approvals: approvals, parseTimestamp: parseTimestamp) else { return nil }

        let approval = approval(for: state, approvals: approvals, parseTimestamp: parseTimestamp)
        let presentation = state.presentation
        let isTerminal = presentation.isTerminal
        let phase = isTerminal
            ? presentation.phase
            : state.effectivePhase(at: instant, stalledAfter: stalledAfter)
        // A completed turn keeps a card only for an approval whose outcome is
        // not proven; the approval then owns what the card says.
        let approvalOwnsCard = approval?.outcome == .pending
            || (phase == .completed && approval?.keepsCardVisible == true)
        guard phase != .completed || approvalOwnsCard else { return nil }

        // Quantized to whole seconds on purpose. `lastMovementAt` advances on
        // every streamed token; without this the projected model would differ
        // on every token and re-render the glass card at token rate instead of
        // at the one-second cadence the card actually displays.
        let sinceMovement = isTerminal
            ? nil
            : wholeSeconds(instant.timeIntervalSince(presentation.lastMovementAt))
        let elapsedEnd = presentation.endedAt ?? instant
        let elapsed = wholeSeconds(elapsedEnd.timeIntervalSince(presentation.startedAt))
        let cancellationPending = !isTerminal && state.cancellationRequestedAt != nil

        // Keep the decision reachable, but acknowledge Stop until the turn
        // actually settles even when an approval is still pending.
        let ownedApproval = approvalOwnsCard && !cancellationPending ? approval : nil
        // Plain work: no approval, no Stop pending, no tool or delegate line.
        let plain = !isTerminal && ownedApproval == nil && !cancellationPending
            && presentation.currentAction == nil
            && (phase == .acknowledged || phase == .working)
        return MacChatTurnCardModel(
            identity: state.identity,
            phase: phase,
            title: ownedApproval.map(approvalTitle(for:)) ?? title(
                phase: phase,
                personaName: personaName,
                delegateName: presentation.delegateName,
                cancellationPending: cancellationPending
            ),
            detail: cancellationPending ? "Waiting for this response to stop."
                : ownedApproval.map(approvalDetail(for:))
                    ?? detail(phase: phase, currentAction: presentation.currentAction),
            delegateName: presentation.delegateName,
            tone: ownedApproval.map(tone(forApproval:)) ?? tone(for: phase),
            symbolName: ownedApproval.map(symbolName(forApproval:)) ?? symbolName(for: phase),
            isTerminal: isTerminal,
            // A turn waiting on a person is not moving, whatever its last
            // lifecycle event was.
            showsLiveIndicator: ownedApproval == nil && !isTerminal && !cancellationPending && isMoving(phase),
            elapsed: elapsed,
            secondsSinceMovement: sinceMovement,
            cancellationPending: cancellationPending,
            approval: approval,
            clock: MacChatTurnCardModel.Clock(
                startedAt: presentation.startedAt,
                endedAt: presentation.endedAt,
                lastMovementAt: presentation.lastMovementAt,
                isTerminal: isTerminal
            ),
            thinkingSince: plain && presentation.streamedTextLength == 0 ? presentation.startedAt : nil,
            thoughtFor: plain && presentation.streamedTextLength > 0
                ? presentation.firstReplyAt.map { $0.timeIntervalSince(presentation.startedAt) } : nil
        )
    }

    /// The approval's own words, used when the approval owns the card.
    public static func approvalTitle(for approval: MacChatTurnCardApproval) -> String {
        switch approval.outcome {
        case .pending:
            // WHO is the first thing the person needs when the asker is not
            // them: "Approve shell?" reads like her own request.
            if let requester = approval.requester {
                return "\(requester) asked: approve \(approval.toolName)?"
            }
            return "Approve \(approval.toolName)?"
        case .approved: return "Approved \(approval.toolName)"
        case .denied: return "Denied \(approval.toolName)"
        case .expired: return "Approval expired"
        case .unresolved: return "Approval outcome unknown"
        }
    }

    public static func approvalDetail(for approval: MacChatTurnCardApproval) -> String {
        switch approval.outcome {
        case .pending:
            if let reason = approval.reason {
                return "\(reason) \u{2014} the tool has not run."
            }
            return "This tool has not run. It is waiting for your decision."
        case .approved:
            return "You approved this. It runs through the usual safety checks."
        case .denied:
            return "You denied this. The tool did not run."
        case .expired:
            return "This request ended before anyone decided. The tool did not run."
        case .unresolved:
            return "This request settled without a readable decision. Whether the tool ran cannot be proven from here."
        }
    }

    public static func tone(forApproval approval: MacChatTurnCardApproval) -> MacChatTurnCardModel.Tone {
        switch approval.outcome {
        case .pending: return .attention
        case .approved: return .working
        case .denied: return .canceled
        // An unproven outcome is neither success nor error.
        case .expired, .unresolved: return .unresolved
        }
    }

    public static func symbolName(forApproval approval: MacChatTurnCardApproval) -> String {
        switch approval.outcome {
        case .pending: return "lock.shield"
        case .approved: return "checkmark.shield"
        case .denied: return "xmark.shield"
        case .expired: return "clock.badge.xmark"
        case .unresolved: return "questionmark.circle"
        }
    }

    private static func wholeSeconds(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return 0 }
        return interval.rounded(.down)
    }

    /// Phases in which the turn is understood to be actively moving.
    private static func isMoving(_ phase: TurnPresentationPhase) -> Bool {
        switch phase {
        case .acknowledged, .working, .tool, .delegation, .retrying:
            return true
        // `.waiting` is deliberately NOT "moving": the shared kernel refuses to
        // let a waiting turn become stalled, so a live pulse here would animate
        // forever with no escape and claim motion that is not happening.
        case .waiting, .blocked, .stalled, .completed, .failed, .canceled, .outcomeUnknown:
            return false
        }
    }

    public static func title(
        phase: TurnPresentationPhase,
        personaName: String,
        delegateName: String?,
        cancellationPending: Bool
    ) -> String {
        let persona = personaName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = persona.isEmpty ? "The agent" : persona
        if cancellationPending, !phase.isTerminal {
            return "Stopping\u{2026}"
        }
        switch phase {
        case .acknowledged:
            return "\(who) is starting\u{2026}"
        case .working:
            return "\(who) is working\u{2026}"
        case .tool:
            return "\(who) is using a tool"
        case .delegation:
            if let delegateName, !delegateName.isEmpty {
                return "\(who) is working with \(delegateName)"
            }
            return "\(who) is delegating"
        case .retrying:
            return "\(who) is retrying\u{2026}"
        case .waiting:
            return "\(who) is waiting\u{2026}"
        case .blocked:
            return "\(who) is blocked"
        case .stalled:
            return "No movement from \(who)"
        case .completed:
            // Never rendered: `card(for:)` returns nil for a completed turn.
            return "Done"
        case .failed:
            return "This turn failed"
        case .canceled:
            return "This turn was stopped"
        case .outcomeUnknown:
            return "Not sure that finished."
        }
    }

    public static func detail(phase: TurnPresentationPhase, currentAction: String?) -> String? {
        let action = currentAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let action, !action.isEmpty { return action }
        switch phase {
        case .stalled:
            return "Nothing has moved for a while. This is an observation, not a verdict \u{2014} it clears on the next sign of work."
        case .outcomeUnknown:
            return "This reply did not finish before the app restarted."
        default:
            return nil
        }
    }

    public static func tone(for phase: TurnPresentationPhase) -> MacChatTurnCardModel.Tone {
        switch phase {
        case .acknowledged, .working, .tool, .delegation, .retrying, .waiting, .completed:
            return .working
        case .blocked, .stalled:
            return .attention
        case .failed:
            return .failed
        case .canceled:
            return .canceled
        case .outcomeUnknown:
            return .unresolved
        }
    }

    public static func symbolName(for phase: TurnPresentationPhase) -> String {
        switch phase {
        case .acknowledged: return "sparkles"
        case .working: return "gearshape"
        case .tool: return "wrench.and.screwdriver"
        case .delegation: return "person.2"
        case .retrying: return "arrow.clockwise"
        case .waiting: return "hourglass"
        case .blocked: return "hand.raised"
        case .stalled: return "clock.badge.questionmark"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .canceled: return "stop.circle"
        case .outcomeUnknown: return "questionmark.circle"
        }
    }
}

public enum MacChatTurnCardFormat {
    /// Compact, calm duration. Seconds under a minute, then m/s, then h/m.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 {
            let minutes = total / 60
            let rest = total % 60
            return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    public static func elapsedPhrase(_ seconds: TimeInterval, isTerminal: Bool) -> String {
        isTerminal ? "Ran for \(duration(seconds))" : "\(duration(seconds)) elapsed"
    }

    /// Only worth saying once movement has actually gone quiet.
    /// The one place the timing readout is assembled, so the visual line, the
    /// spoken line, and the model's own `spokenMeta` cannot drift apart.
    public static func metaLine(
        elapsed: TimeInterval,
        secondsSinceMovement: TimeInterval?,
        isTerminal: Bool,
        separator: String
    ) -> String {
        var parts = [elapsedPhrase(elapsed, isTerminal: isTerminal)]
        if let movement = movementPhrase(secondsSinceMovement) {
            parts.append(movement)
        }
        return parts.joined(separator: separator)
    }

    public static func movementPhrase(_ secondsSinceMovement: TimeInterval?) -> String? {
        guard let secondsSinceMovement,
              secondsSinceMovement >= MacChatTurnCardProjection.movementNoticeAfter else {
            return nil
        }
        return "no movement for \(duration(secondsSinceMovement))"
    }
}

// MARK: - View

/// The banner's live-state projection. It is deliberately derived from the
/// runtime streaming set rather than session-list membership: a turn may still
/// be real while its index row is refreshing, and the user needs a route/Stop
/// affordance for that adverse state instead of a silently missing banner.
public enum MacChatOtherSessionsProjection {
    public static func otherRunning(
        streamingSessionIDs: Set<String>,
        activeSessionID: String,
        canonicalSessionIDs: [String]
    ) -> [String] {
        let active = activeSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let running = Set(streamingSessionIDs.compactMap { rawID -> String? in
            let sessionID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionID.isEmpty, sessionID != active else { return nil }
            return sessionID
        })
        let knownOrder = Dictionary(
            canonicalSessionIDs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return running.sorted { lhs, rhs in
            let lhsOrder = knownOrder[lhs] ?? Int.max
            let rhsOrder = knownOrder[rhs] ?? Int.max
            return lhsOrder == rhsOrder ? (lhs < rhs) : (lhsOrder < rhsOrder)
        }
    }
}

public enum ChatTurnToolPlacement {
    /// `local` with the running turn's persisted rows placed just above the
    /// live reply, in disk order: its tool rows, and any steering message it
    /// took between them (a user row of its own run id, which splits the fold
    /// exactly as the reload will). Nil when nothing is new. The turn's rows
    /// share its run id, which the newest tool row carries; its own user row
    /// is already on screen. An approval waiting on User stays on the turn
    /// card until the reload; a mirrored card is never a tool row.
    public static func placing(disk: [ChatMessage], into local: [ChatMessage], before bubbleId: String) -> [ChatMessage]? {
        guard let run = disk.last(where: { $0.role == "tool" })?.runId,
              let start = disk.firstIndex(where: { $0.runId == run }) else { return nil }
        let rows = disk[start...].filter { row in
            row.role == "tool"
                ? row.metadata?.isPendingApproval != true && row.metadata?.interactionMirror == nil
                : row.role == "user" && row.runId != run
        }
        let ids = Set(rows.map(\.id))
        // A slower read of an older file never takes rows away.
        guard !ids.isSubset(of: Set(local.map(\.id))) else { return nil }
        var placed = local.filter { !ids.contains($0.id) }
        guard let reply = placed.firstIndex(where: { $0.id == bubbleId }) else { return nil }
        placed.insert(contentsOf: rows, at: reply)
        return placed
    }
}

/// Whether the room is showing trouble, and how stuck she is. Derived from the
/// transcript that is already loaded — no counter, no new state to go stale.
public enum ChatShellTroubleState {
    /// A turn that failed or was cut off. 2026-09-06: a turn the person
    /// STOPPED is not trouble — pressing Stop is an answer, not a fault, and
    /// it must not raise the orange card. The cancel writer stamps `partial`
    /// alongside `cancelled`, so the cancelled flag has to be read first or
    /// every Stop still reads as a failure.
    /// The engine's persisted failure row (`mechanicalKind: systemRow`) is a
    /// failed turn too; without it the card never showed for the failure the
    /// core itself wrote down.
    public static func isFailed(_ message: ChatMessage) -> Bool {
        if message.metadata?.cancelled == true { return false }
        return message.metadata?.error?.isEmpty == false
            || message.metadata?.partial == true
            || message.metadata?.mechanicalKind == "systemRow"
    }

    /// The run of failed assistant turns at the tail of the transcript. Zero
    /// means the last thing the agent said landed cleanly.
    ///
    /// 2026-09-06: a user message BETWEEN two failures no longer ends the run.
    /// Failures arrive one per turn and each turn begins with the person
    /// asking again, so stopping at the first user row could only ever return
    /// 1 — and the "Still stuck?" link, which needs two, never appeared. A
    /// user row at the very tail still ends it: that turn has not answered
    /// yet, so there is nothing to call trouble. A clean assistant reply ends
    /// it too, which is the real boundary.
    public static func consecutiveFailures(_ messages: [ChatMessage]) -> Int {
        var count = 0
        var sawAssistant = false
        for message in messages.reversed() {
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if role == "user", !sawAssistant { break }
            guard role == "assistant" else { continue }
            sawAssistant = true
            guard isFailed(message) else { break }
            count += 1
        }
        return count
    }

    public static func showsStuckLink(_ messages: [ChatMessage]) -> Bool {
        consecutiveFailures(messages) >= 2
    }
}

extension ChatShellConversationRow {
    @MainActor
    public static func subtitle(for session: NativeAgentShared.ChatSession, relativeTimestamp: (String) -> String) -> String {
        // The row's time is when someone last spoke, read from the transcript's
        // tail; the index stamp is the fallback. A rename or a migration can
        // touch the stamp; it cannot touch the transcript.
        let stamp = ChatShellOpeningLine.shared.stamp(for: session) ?? session.updatedAt ?? session.createdAt
        let relative = relativeTimestamp(stamp)
        let place = surface(for: session)
        guard !relative.isEmpty else { return place }
        guard place != localSurface else { return relative }
        return "\(place) · \(relative)"
    }
}
