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
// Blueprint: | `ConversationRows.swift` | `ChatShellConversationRow`, `ChatShellEnvelope`, `ChatShellOpeningLine`, `LatestRead` |

/// Hide machine ids and routing prefixes: they do not provide meaningful conversation titles.
public enum ChatShellConversationRow {
    public static let bridgePrefix = BridgeRoutingPrefix.prefix
    public static let titleLimit = 30

    /// Use recorded kind consistently for conversation grouping and the user’s default chat.
    public static func isWorking(_ session: NativeAgentShared.ChatSession) -> Bool {
        !SessionConversation.kind(session).isPersonConversation
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
        // Bound routing-prefix inspection to 96 characters to avoid copying streaming replies.
        return BridgeRoutingPrefix.hasGroup(value)
    }

    private static func bridgeGroup(_ trimmed: String) -> Substring? {
        BridgeRoutingPrefix.group(trimmed)
    }

    public static func stripBridgePrefix(_ text: String) -> String {
        BridgeRoutingPrefix.stripping(text)
    }

    /// Cap the routing tag to alphanumerics so hostile payloads cannot inject control characters.
    public static func bridgeAgentTag(_ text: String) -> String? {
        // The 96-character head contains the full routing group without copying the whole message.
        let trimmed = BridgeRoutingPrefix.boundedHead(text)
        guard let group = bridgeGroup(trimmed) else { return nil }
        let close = trimmed.index(before: group.endIndex)
        let inside = trimmed[trimmed.index(trimmed.startIndex, offsetBy: bridgePrefix.count)..<close]
        let agent = inside.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if agent.lowercased() == "install_app.sh" { return "Install script" }
        let safe = agent.filter { $0.isLetter || $0.isNumber }
        guard !safe.isEmpty, safe.count <= 24 else { return nil }
        return safe.prefix(1).uppercased() + safe.dropFirst()
    }

    /// A stored title that is really a machine id, not a name a person chose.
    public static func isMachineTitle(_ title: String, session: NativeAgentShared.ChatSession) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == NativeAgentShared.ChatSession.placeholderTitle { return true }
        // Recovery labels are not user titles.
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

    /// Resolve titles from the stored title, then usable opening speech, then "New conversation"; never summarize the last message.
    public static func titleSource(for session: NativeAgentShared.ChatSession, openingLine: String?) -> (text: String, automated: Bool) {
        let stored=stripBridgePrefix(session.title), opening=stripBridgePrefix(openingLine ?? "")
        let candidate = !isMachineTitle(stored,session:session) ? stored : opening
        if candidate.isEmpty { return ("New conversation",false) }
        let text=candidate.trimmingCharacters(in:.whitespacesAndNewlines)
        // Recorded machine envelopes classify identity; editable titles cannot rename that source.
        let automated=text.hasPrefix("[Woken by ") || text.hasPrefix("Current standing instructions for ")
            || text.contains(
                /^Codex (replied to (your message|\d+ queued messages)|(wakeup failed|turn stalled|wakeup produced no reply)( for \d+ queued messages)?)\.(\s|$)/)
        return automated ? (text,true) : (clamp(plainText(candidate)),false)
    }

    public static func preview(for session: NativeAgentShared.ChatSession) -> String {
        plainText(stripBridgePrefix(session.lastMessagePreview ?? ""))
    }

    public static func listPreview(for session: NativeAgentShared.ChatSession, title: String) -> String {
        let said = preview(for: session)
        // Compare a cut title by its words so far; compare a complete title exactly.
        let repeats = title.hasSuffix("…")
            ? title.count > 1 && said.hasPrefix(title.dropLast())
            : said == title
        if repeats { return "" }
        return clamp(said, limit: previewLimit)
    }
    public static let previewLimit = 26

    /// Rows render plain words, so strip Markdown from user-supplied titles.
    public static func plainText(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\n", with: " ")
        while text.hasPrefix("["), let close = text.firstIndex(of: "]"),
              text.distance(from: text.startIndex, to: close) <= 40 {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if let range = text.range(of: #"^\W*transcript\W*"#, options: [.regularExpression, .caseInsensitive]) {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        for marker in ["```", "**", "__", "~~", "`", "*"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = trimmed.first, first == "#" || first == ">" || first == "-" {
            trimmed = trimmed.dropFirst()
            while trimmed.first == " " { trimmed = trimmed.dropFirst() }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    public static func surface(for session: NativeAgentShared.ChatSession) -> String {
        if isWorking(session) { return "Connected agent" }
        switch session.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "telegram": return "Telegram"
        case "ios": return "iPhone"
        case "slack": return "Slack"
        case "agent-bridge": return "Connected agent"
        default: return "Mac"
        }
    }

    public static let localSurface = "Mac"

    static func clamp(_ value: String, limit: Int = titleLimit) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        // Inspect one extra character to preserve word boundaries when clipping.
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

/// Fold routing metadata separately so the room shows the worker’s reply.
public enum ChatShellEnvelope {
    public static func isEnvelope(_ content: String, envelope: ChatMessageOriginMetadata?) -> Bool {
        // Recorded envelopes require built-in bridge provenance; rows without envelopes classify by their opening.
        if let envelope {
            guard let agent = envelope.agent, ["codex", "claude", "omp"].contains(agent),
                  envelope.surface == agent + "-bridge" else { return false }
        }
        return DelegatedReplyEnvelope(content).isHistorical
    }

    public static func headline(_ content: String) -> String {
        let decoded = DelegatedReplyEnvelope(content)
        // Completion titles may carry failure or stalls without a status line.
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

/// Warm transcript generations before index publication; unresolved rows must remain distinct from empty transcripts.
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

    /// Scan by rows so context blocks cannot hide user speech; cap bytes to bound runaway files.
    nonisolated private static let rowBudget = 200
    nonisolated private static let byteCeiling = 1 << 20
    /// A row rarely exceeds this read granularity.
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

    /// Prefer unprefixed user speech for titles; return nil when the bounded scan finds no usable speech.
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

    nonisolated static func read(sessionID: String, dataRoot: URL) throws -> OpeningLine {
        guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let url = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeID).jsonl")
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as CocoaError where error.isFileAbsent { return OpeningLine() }
        defer { try? handle.close() }

        var firstBridge: String? = nil
        var projection = OpeningLine()
        var buffer = Data()
        var read = 0
        var rows = 0
        let newline = UInt8(ascii: "\n")

        while rows < rowBudget, read < byteCeiling {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            read += chunk.count
            buffer.append(chunk)
            // Keep partial rows for the next chunk rather than decoding incomplete bytes.
            guard let lastBreak = buffer.lastIndex(of: newline) else { continue }
            let whole = buffer[..<lastBreak]
            buffer = Data(buffer[buffer.index(after: lastBreak)...])
            for line in whole.split(separator: newline) {
                rows += 1
                if rows > rowBudget { break }
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
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
        projection.line = firstBridge
        return projection
    }

    /// Only usable user speech can name a conversation.
    nonisolated private static func spokenLine(_ object: [String: Any]) -> String? {
        guard let content = object["content"] as? String
        else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let role = (object["role"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard role == "user" else { return nil }
        // Bracketed pipeline notes contain no user words to name a conversation.
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.contains("\n") {
            return nil
        }
        return trimmed
    }
    nonisolated static func readLastTurn(sessionID: String, dataRoot: URL) throws -> String? {
        guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else { throw CocoaError(.fileReadInvalidFileName) }
        let url = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeID).jsonl")
        guard let read = try SwiftNativePersistenceCore.tailPhysicalLines(url, limit: .max, maxBytes: tailBytes)
        else { return nil }
        // A completed newest row cannot be stepped over to certify older speech.
        for line in read.lines.dropFirst(read.leadingFragment ? 1 : 0).reversed() {
            if line.isEmpty { continue }
            guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let stamp = object["createdAt"] as? String, !stamp.isEmpty {
                return stamp
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        return nil
    }
}

extension ChatShellConversationRow {
    @MainActor
    public static func isAgentOwn(_ session: NativeAgentShared.ChatSession, openingLines: ChatShellOpeningLine) -> Bool {
        guard openingLines.isPrepared(for: session),
              isMachineTitle(stripBridgePrefix(session.title), session: session),
              (session.messageCount ?? 0) > 0 else { return false }
        return openingLines.line(for: session) == nil
    }

    @MainActor
    public static func title(for session: NativeAgentShared.ChatSession) -> String {
        session.displayTitle
    }
}

/// Titles can contain untrusted payloads. Bound scalars, remove controls and collapse whitespace before menus; empty titles still need selectable
/// identity.
public struct MacChatRunningSessionRoute: Sendable, Equatable {
    public let sessionId: String
    /// Never expose raw stored titles in menus.
    public let title: String

    /// Bound Unicode scalars: one grapheme may contain thousands of combining marks, so `String.count` is not a data bound.
    public static let titleScalarLimit = 48

    public static let titleInputScalarLimit = 512

    /// Preserve the owner’s ordered, unique ids when deriving safe labels.
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

        // Suffix every multi-route label with an untruncated unique ordinal; hostile titles can otherwise collide with generated suffixes.
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

    private static func displayTitle(session: NativeAgentShared.ChatSession?, sessionId: String) -> String {
        guard let session else { return fallbackTitle(sessionId: sessionId) }
        return sanitize(session.displayTitle) ?? ""
    }

    /// Remove controls instead of substituting characters a spoofing payload could exploit; collapse and bound the remaining text.
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
            // Require a visible base before combining marks so labels cannot appear blank or misleading.
            if scalars.isEmpty, isCombiningMark(scalar) {
                continue
            }
            if pendingSpace {
                // Reserve space for the collapsed space and visible scalar; never leave a trailing space before truncation.
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

    /// Distinct bounded identity suffixes keep multi-route menus navigable visually and through VoiceOver.
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

    /// Untitled or unknown sessions still need a nonempty, clickable label.
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
        case 48...57, 65...90, 97...122:
            return true
        case 45, 58, 95:
            return true
        default:
            return false
        }
    }
}

/// Derive live banners from runtime streaming, not the refreshing index, so active turns always retain route and Stop controls.
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

/// Derive trouble from loaded transcripts so a second counter cannot drift.
public enum ChatShellTroubleState {
    /// Cancellation takes precedence over partial/error flags because Stop is not failure.
    /// Persisted `mechanicalKind: systemRow` rows also indicate failed turns.
    public static func isFailed(_ message: ChatMessage) -> Bool {
        if message.metadata?.cancelled == true { return false }
        return message.metadata?.error?.isEmpty == false
            || message.metadata?.partial == true
            || message.metadata?.mechanicalKind == "systemRow"
    }

    /// A pending user turn or clean assistant reply ends the trailing-failure run.
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
        // Use transcript speech time for row age; index stamps also change on renames and migration.
        let stamp = openingLines.stamp(for: session) ?? session.updatedAt ?? session.createdAt
        let relative = relativeTimestamp(stamp)
        let place = surface(for: session)
        guard !relative.isEmpty else { return place }
        guard place != localSurface else { return relative }
        return "\(place) · \(relative)"
    }
}
