import Transcripts
import Foundation
import Observation
import AgentWorkspace
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ApprovalInbox
import ChatTurnRuntime
import ApprovalTransactions
import ChatSessionWork
// Blueprint: | `ConversationRows.swift` | `ChatShellConversationRow`, `ChatShellEnvelope` and running-session routes project conversation identity and visible rows; `ChatShellOpeningLine` owns bounded preparation, cached revisions and `LatestRead` publication per standardized data root; classification and subtitles use that owner; human titles stay native and automated title prose is prepared by the batched presentation face; trouble derives from loaded messages |

/// A conversation row's two lines. The list must never show a machine id: a
/// Telegram chat id or an iOS session hash tells a person nothing, and the
/// bridge's `[from: …]` routing prefix is plumbing, not a title.
public enum ChatShellConversationRow {
    public static let bridgePrefix = BridgeRoutingPrefix.prefix
    public static let titleLimit = 30

    /// True for her conversations that are not his own with her — with other
    /// agents and with her helpers. The row's recorded kind decides their
    /// section, using the same rule that decides his default chat.
    public static func isWorking(_ session: NativeAgentShared.ChatSession) -> Bool {
        !SessionConversation.kind(session).isHisConversation
    }

    /// Recorded origin decides bridge routing; typed routing prefixes cannot establish provenance.
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
    /// The source, in order:
    ///  1. The stored session title. Persistence writes it once, from the
    ///     first user message (`shouldReplaceSessionTitle`).
    ///  2. `openingLine` — usable user speech from ChatShellOpeningLine's scan,
    ///     when the stored title is a machine id or placeholder.
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

    /// The last thing said, cut at a word; empty when it repeats the title.
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
    public static func isEnvelope(_ content: String, envelope: ChatMessageOriginMetadata?) -> Bool {
        // Recorded envelopes require a built-in bridge origin; historical rows without envelopes fold on their opening.
        if let envelope {
            guard let agent = envelope.agent, ["codex", "claude", "omp"].contains(agent),
                  envelope.surface == agent + "-bridge" else { return false }
        }
        return DelegatedReplyEnvelope(content).isHistorical
    }

    /// Completion status with the slip's duration, when present.
    public static func headline(_ content: String) -> String {
        let decoded = DelegatedReplyEnvelope(content)
        // Codex completion titles carry failure, stalls and missing replies without a status line.
        if let title = decoded.codexTitle, !title.hasPrefix("codex replied to ") {
            return "The connected agent didn't finish"
        }
        let header = decoded.header
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

/// Opening words and the last turn's timestamp.
/// ChatTranscriptCache warms each generation/count before index publication;
/// renderers distinguish an unresolved row from an empty transcript.
@MainActor
@Observable
public final class ChatShellOpeningLine {
    private static var owners: [URL: ChatShellOpeningLine] = [:]

    public static func forRoot(_ dataRoot: URL) -> ChatShellOpeningLine {
        let root = dataRoot.standardizedFileURL
        if let owner = owners[root] { return owner }
        let owner = ChatShellOpeningLine(dataRoot: root)
        owners[root] = owner
        return owner
    }

    /// Scan by rows so large context blocks do not hide user speech; the byte
    /// ceiling prevents reading a runaway file whole.
    nonisolated private static let rowBudget = 200
    nonisolated private static let byteCeiling = 1 << 20
    /// Read granularity; a transcript row is rarely larger than this.
    nonisolated private static let chunkSize = 64 * 1024
    nonisolated private static let tailBytes = 8_192
    struct OpeningLine: Sendable, Equatable {
        var revision = ""
        var line: String? = nil
        var lastTurn: String? = nil
    }
    @ObservationIgnored private var cache: [String: OpeningLine] = [:]
    @ObservationIgnored private let warmRead = LatestRead()
    public private(set) var revision: UInt64 = 0

    private let dataRoot: URL
    private init(dataRoot: URL) { self.dataRoot = dataRoot }

    /// Scan usable user speech, preferring the first line without a bridge
    /// prefix, with the first bridge-prefixed user line as fallback.
    /// nil when the bounded scan finds no usable user speech.
    public func line(for session: NativeAgentShared.ChatSession) -> String? {
        projection(for: session).line
    }

    public func stamp(for session: NativeAgentShared.ChatSession) -> String? {
        projection(for: session).lastTurn
    }

    public func prepare(_ sessions: [NativeAgentShared.ChatSession]) async throws {
        _ = try await prepareProjections(sessions)
    }

    func prepareProjections(_ sessions: [NativeAgentShared.ChatSession]) async throws -> [String: OpeningLine] {
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

    private func projection(for session: NativeAgentShared.ChatSession) -> OpeningLine {
        _ = self.revision
        let revision = Self.revision(for: session)
        if let hit = cache[session.id], hit.revision == revision { return hit }
        return OpeningLine()
    }

    nonisolated static func read(sessionID: String, dataRoot: URL) -> OpeningLine {
        guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            return OpeningLine()
        }
        let url = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeID).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return OpeningLine() }
        defer { try? handle.close() }

        var firstBridge: String? = nil
        var projection = OpeningLine()
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
                guard let spoken = spokenLine(object) else { continue }
                if !ChatShellConversationRow.hasBridgePrefix(spoken) {
                    projection.line = spoken
                    return projection
                } else if firstBridge == nil {
                    firstBridge = ChatShellConversationRow.stripBridgePrefix(spoken)
                }
            }
        }
        // Only bridge-prefixed user speech was found.
        projection.line = firstBridge
        return projection
    }

    /// Usable user text; other roles, empty text and bracketed pipeline notes
    /// cannot name the conversation.
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
        guard let read = try? SwiftNativePersistenceCore.tailPhysicalLines(url, limit: .max, maxBytes: tailBytes)
        else { return nil }
        // Include the leading fragment: the newest row that parses supplies the timestamp.
        for line in read.lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let stamp = (object["timestamp"] ?? object["createdAt"] ?? object["created_at"]) as? String, !stamp.isEmpty {
                return stamp
            }
        }
        return nil
    }
}

extension ChatShellConversationRow {
    /// A prepared, nonempty session with a machine title and no user opening
    /// in the bounded scan, including her morning briefs and own starts.
    @MainActor
    public static func isHerOwn(_ session: NativeAgentShared.ChatSession, openingLines: ChatShellOpeningLine) -> Bool {
        guard openingLines.isPrepared(for: session),
              isMachineTitle(stripBridgePrefix(session.title), session: session),
              (session.messageCount ?? 0) > 0 else { return false }
        return openingLines.line(for: session) == nil
    }

    /// Render the title already resolved by TranscriptsFacade.
    @MainActor
    public static func title(for session: NativeAgentShared.ChatSession) -> String {
        session.displayTitle
    }
}

/// A reachable identity for each chat session running outside the foreground.
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

    /// Maximum input scalars inspected while deriving one title.
    public static let titleInputScalarLimit = 512

    /// Preserve OtherRunningChats' ordered, unique IDs while preparing safe labels.
    public static func routes(sessionIds: [String], sessions: [NativeAgentShared.ChatSession]) -> [MacChatRunningSessionRoute] {
        let sessionsById = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = sessionIds.map { sessionId in
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
                scalars.append(" ")
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
            let ellipsis: Unicode.Scalar = "…"
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

/// The banner's live-state projection. It is deliberately derived from the
/// runtime streaming set rather than session-list membership: a turn may still
/// be real while its index row is refreshing, and the user needs a route/Stop
/// affordance for that adverse state instead of a silently missing banner.
public enum OtherRunningChats {
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

/// Whether the room is showing trouble, and how stuck she is. Derived from the
/// transcript that is already loaded — no counter, no new state to go stale.
public enum ChatShellTroubleState {
    /// Cancellation takes precedence over partial/error flags because Stop is not failure.
    /// Persisted `mechanicalKind: systemRow` rows also count as failed turns.
    public static func isFailed(_ message: ChatMessage) -> Bool {
        if message.metadata?.cancelled == true { return false }
        return message.metadata?.error?.isEmpty == false
            || message.metadata?.partial == true
            || message.metadata?.mechanicalKind == "systemRow"
    }

    /// Count trailing assistant failures across user retries; a pending user turn or clean assistant reply ends the run.
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
    public static func subtitle(for session: NativeAgentShared.ChatSession, openingLines: ChatShellOpeningLine,
                                relativeTimestamp: (String) -> String) -> String {
        // The row's time is when someone last spoke, read from the transcript's
        // tail; the index stamp is the fallback. A rename or a migration can
        // touch the stamp; it cannot touch the transcript.
        let stamp = openingLines.stamp(for: session) ?? session.updatedAt ?? session.createdAt
        let relative = relativeTimestamp(stamp)
        let place = surface(for: session)
        guard !relative.isEmpty else { return place }
        guard place != localSurface else { return relative }
        return "\(place) · \(relative)"
    }
}
