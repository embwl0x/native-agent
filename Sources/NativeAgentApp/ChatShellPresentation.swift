import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// ui-simplify 2026-09-02 (Lane A): value-only presentation rules for the new
// shell. Everything here is a pure projection of state the app already owns —
// no new stores, no new settings, no network.

/// The one place a trust posture becomes a sentence a person can read.
///
/// Full Mac reads the same saved grant as Trust. It has no timer
/// (2026-09-10): it is on until the person turns it off.
enum ChatShellTrustPhrase: String, CaseIterable, Sendable {
    case strict
    case balanced
    case wideOpenWithReceipts
    case fullMac
    case unknown

    static func make(policy: TrustPolicy?, now: Date = Date()) -> Self {
        guard let policy else { return .unknown }
        if AppModel.fullMacGrantIsActive(policy) { return .fullMac }
        switch policy.permissionLevel {
        case "strict": return .strict
        case "balanced": return .balanced
        case "wide_open_receipts": return .wideOpenWithReceipts
        case "full_mac_os": return .balanced
        default: return .unknown
        }
    }

    /// Plain language, one line, no jargon and no raw policy token.
    var text: String {
        switch self {
        case .strict, .balanced: "Approval required"
        case .wideOpenWithReceipts: "Limited Mac access"
        case .fullMac: "Full Mac access"
        case .unknown: "Permissions unavailable"
        }
    }
}

/// What the single status dot says right now. Exactly one dot, one line, and
/// the teal is spent only on "waiting on you".
enum ChatShellStatus: Equatable, Sendable {
    /// Nothing is wrong; the line is her trust posture.
    case settled(ChatShellTrustPhrase)
    /// An approval is pending. This is the only place the teal is spent.
    case waitingOnYou
    /// The last turn failed or the runtime is unreachable.
    case trouble

    static func make(
        policy: TrustPolicy?,
        hasPendingApproval: Bool,
        hasTrouble: Bool
    ) -> Self {
        if hasPendingApproval { return .waitingOnYou }
        if hasTrouble { return .trouble }
        return .settled(.make(policy: policy))
    }

    var text: String {
        switch self {
        case .settled(let phrase): phrase.text
        case .waitingOnYou: "Waiting on you"
        // 2026-09-06: nothing here knows about retries, and nothing was
        // retrying. The dot says what is actually known.
        case .trouble: "That turn didn't finish"
        }
    }

    var color: Color {
        switch self {
        case .settled: NativeAgentShell.calm
        case .waitingOnYou: NativeAgentShell.needsYou
        case .trouble: NativeAgentShell.trouble
        }
    }
}

/// Copy for the room's three named states. Kept out of the views so the words
/// Agent and User agreed on live in one readable place.
enum ChatShellCopy {
    // 2026-09-06: the offline variant ("Keep typing. I'll send it when I'm
    // back.") promised a send that no queue state backed. One placeholder.
    static let composerPlaceholder = "Say anything"

    static func greetingTitle(_ name: String) -> String { "Hi, I'm \(name)." }
    static let greetingDetail =
        "I live on this Mac. Say hello, ask me anything, or hand me something to do."
    static let greetingChips = [
        "What can you do here?",
        "What did we talk about last time?",
        "Tell me about yourself",
    ]

    // 2026-09-06: the old title claimed a retry ("Trying again…") that no
    // retry loop was running, and the detail's "nothing was sent" was stated
    // even for a turn that had already run tools. The title says only what
    // the transcript proves; the detail is shown only when the turn's own
    // tool receipts show it dispatched nothing.
    static let errorTitle = "I didn't finish that one."
    static let errorDetail = "Your message is safe. Nothing was sent anywhere."
    static let errorStuckLink = "Still stuck? Settings"
    /// After this many failed turns in a row the quiet Settings link appears.
    static let stuckRetryThreshold = 2

    static let workingRowTitle = "Working"
    static let conversationsTitle = "Conversations"
    /// Sessions she opened herself and no person ever answered.
    static let briefsRowTitle = "Morning briefs"
}

/// A conversation row's two lines. The list must never show a machine id: a
/// Telegram chat id or an iOS session hash tells a person nothing, and the
/// bridge's `[from: …]` routing prefix is plumbing, not a title.
enum ChatShellConversationRow {
    static let bridgePrefix = BridgeRoutingPrefix.prefix
    static let titleLimit = 30

    /// True for the bridge/agent sessions that collapse into one "Working" row.
    static func isWorking(_ session: ChatSession) -> Bool {
        hasBridgePrefix(session.title) || hasBridgePrefix(session.lastMessagePreview)
            || isProbe(session.title)
    }

    /// Routing probes and tool-catalog prompts: a system spoke, not a person.
    static func isProbe(_ title: String?) -> Bool {
        guard let title else { return false }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("reply with exactly") || value.hasPrefix("use your tool catalog")
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
    static func isBridgeRouted(_ origin: ChatMessageOriginMetadata?) -> Bool {
        guard let surface = origin?.surface?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !surface.isEmpty
        else { return false }
        return surface == "bridge" || surface.hasSuffix("-bridge")
    }

    static func hasBridgePrefix(_ value: String?) -> Bool {
        guard let value else { return false }
        return bridgeGroup(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private static func bridgeGroup(_ trimmed: String) -> Substring? {
        BridgeRoutingPrefix.group(trimmed)
    }

    static func stripBridgePrefix(_ text: String) -> String {
        BridgeRoutingPrefix.stripping(text)
    }

    /// The agent named by a `[from: <agent>, via bridge]` prefix, capitalized
    /// for the small tag above the bubble. nil when there is no such prefix.
    /// The value is length-capped and alphanumeric-only, so a hostile payload
    /// cannot smuggle control characters into the tag.
    static func bridgeAgentTag(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    static func isMachineTitle(_ title: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == ChatSession.placeholderTitle { return true }
        // Recovery names a session after the fact; it is a label, not a title.
        if value.caseInsensitiveCompare("Recovered Chat") == .orderedSame { return true }
        // "Telegram 1394548068", "iOS chat 03108B46", "Slack C01ABCD".
        let words = value.split(separator: " ")
        if let last = words.last,
           words.count >= 2,
           last.count >= 5,
           last.allSatisfy({ $0.isHexDigit }) {
            return true
        }
        // A bare id with no prose at all.
        if words.count == 1, value.count >= 5, value.allSatisfy({ $0.isHexDigit }) { return true }
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
    static func title(for session: ChatSession, openingLine: String?) -> String {
        let stored = stripBridgePrefix(session.title)
        if !isMachineTitle(stored) { return clamp(plainText(stored)) }
        let opening = stripBridgePrefix(openingLine ?? "")
        if !opening.isEmpty { return clamp(plainText(opening)) }
        return "New conversation"
    }

    /// Titles carry whatever the person typed, including markdown. A row is
    /// plain text: backticks, `**bold**`, list bullets and heading hashes are
    /// markup, not words, and reading them in a sidebar is noise.
    static func plainText(_ value: String) -> String {
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
    static func surface(for session: ChatSession) -> String {
        if isWorking(session) { return "Claude" }
        switch session.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "telegram": return "Telegram"
        case "ios", "iphone", "ipad", "mobile", "icloud": return "iPhone"
        case "slack": return "Slack"
        case "bridge", "agent_bridge", "claude", "codex": return "Claude"
        default: return "Mac"
        }
    }

    /// "<Surface> · <relative time>", or just the time for this Mac.
    ///
    /// Agent, 2026-09-02: "Mac · 3w ago" spends a word on the machine the
    /// reader is holding. Where a conversation happened is only worth saying
    /// when it happened somewhere ELSE — "Telegram · 3w ago", "iPhone · 1d
    /// ago". A Mac session says the time and nothing more.
    static let localSurface = "Mac"

    @MainActor
    static func subtitle(for session: ChatSession) -> String {
        // The row's time is when someone last spoke, read from the transcript's
        // tail; the index stamp is the fallback. A rename or a migration can
        // touch the stamp; it cannot touch the transcript.
        let stamp = ChatShellLastTurn.shared.stamp(for: session) ?? session.updatedAt ?? session.createdAt
        let relative = UserDisplayFormatters.relativeISOTimestamp(
            stamp,
            unitsStyle: .abbreviated,
            fallback: ""
        )
        let place = surface(for: session)
        guard !relative.isEmpty else { return place }
        guard place != localSurface else { return relative }
        return "\(place) · \(relative)"
    }

    /// Cut at a word boundary, never mid-word.
    private static func clamp(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > titleLimit else { return flat }
        // One character past the limit tells us whether the cut already fell
        // on a boundary; otherwise back up to the last space inside it.
        let window = flat.prefix(titleLimit + 1)
        let head: Substring
        if let space = window.lastIndex(of: " ") {
            head = window[..<space]
        } else {
            head = flat.prefix(titleLimit)
        }
        let word = head.trimmingCharacters(in: .whitespaces)
        return String((word.isEmpty ? String(flat.prefix(titleLimit)) : word).trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?—-"))) + "…"
    }
}

/// A completion envelope: the routing slip a worker's reply arrives in
/// ("Originating message id: …", topic, status, then "--- Claude's reply ---").
/// The room shows the reply and folds the slip, the way tool traffic folds.
enum ChatShellEnvelope {
    static let replyMarker = "--- Claude's reply ---"
    static let endMarker = "--- end reply ---"

    static func isEnvelope(_ content: String) -> Bool {
        let head = content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400).lowercased()
        return head.hasPrefix("originating message id:")
            || head.hasPrefix("[claude-wake]")
            || head.contains("originating message id:")
            || content.contains(replyMarker)
    }

    /// The words between the markers, or the whole text when there are none.
    static func reply(_ content: String) -> String {
        var text = content
        if let start = text.range(of: replyMarker) { text = String(text[start.upperBound...]) }
        if let end = text.range(of: endMarker) { text = String(text[..<end.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Claude came back · 8 min" from the slip's Duration line, when present.
    static func headline(_ content: String) -> String {
        let line = content.split(whereSeparator: \.isNewline)
            .first { $0.lowercased().hasPrefix("duration:") }
            .map { $0.dropFirst("duration:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        let seconds = Int(line.filter(\.isNumber)) ?? 0
        let lowered = content.lowercased()
        if lowered.contains("status: failed") || lowered.contains("was rejected") {
            return "Claude didn't come back"
        }
        guard seconds > 0 else { return "Claude came back" }
        return seconds < 90 ? "Claude came back · under a minute" : "Claude came back · \(seconds / 60) min"
    }
}

/// The approval card's words.
///
/// The mockup's card is an email, and its primary button reads "Send it". A
/// button that says "Send it" over an approval to DELETE something would be a
/// lie the person acts on, so the verb is chosen from the request rather than
/// hard-coded: send-shaped requests get "Send it", everything else gets the
/// neutral "Go ahead". "Not now" and "Show me the draft" are constant.
enum ChatShellApprovalCopy {
    static let decline = "Not now"
    static let showDraft = "Show me the draft"
    static let hideDraft = "Hide the draft"

    static func approve(for content: String) -> String {
        // The verb is read from the request's opening word only. A delete
        // that mentions an email in passing must never be labelled "Send it".
        let firstLine = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let firstWord = firstLine.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "-" }).first.map(String.init) ?? ""
        let sendVerbs: Set<String> = ["send", "email", "e-mail", "mail", "message", "reply", "post", "text"]
        let destructive = ["delete", "remove", "erase", "wipe", "drop", "overwrite"]
        let lowered = content.lowercased()
        if destructive.contains(where: lowered.contains) { return "Go ahead" }
        return sendVerbs.contains(firstWord) ? "Send it" : "Go ahead"
    }

    /// The card's plain title: the first line of the request, no decoration.
    static func title(_ content: String) -> String {
        let first = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? content
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(AgentVoice.live.Subject) \(AgentVoice.live.verb("need")) a decision" : String(trimmed.prefix(120))
    }

    /// One line of detail. Recipients and addresses are NOT truncated — the
    /// whole point of the line is that the person can see where it is going.
    static func detail(_ content: String) -> String {
        let parts = content.split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }
}

/// Tool traffic in plain words. The room shows ONE quiet row per turn; opening
/// it shows what she actually touched. Raw JSON never renders here — it stays
/// available in Diagnostics, where a developer is looking for it.
enum ChatShellToolSummary {
    static let detailLimit = 4

    /// One line, e.g. "Looked something up · 2 tools".
    ///
    /// 2026-09-06: a failure shows in the closed row. The detail lines already
    /// say which call failed, but they are behind the fold — the headline read
    /// the same whether every call worked or none did, so a turn that failed
    /// looked like a turn that went fine until the user opened it.
    static func headline(count: Int, failed: Int = 0) -> String {
        let failed = max(0, min(failed, count))
        guard failed > 0 else {
            return "Looked something up · \(count) tool\(count == 1 ? "" : "s")"
        }
        if failed == count {
            return count == 1
                ? "That didn't work · 1 tool"
                : "That didn't work · all \(count) tools failed"
        }
        return "Looked something up · \(failed) of \(count) failed"
    }

    /// What a call did, and what it would have done. One switch for both, so
    /// the success sentence and the failure sentence can never end up
    /// describing different tools (2026-09-06).
    private static func phrases(_ toolName: String?) -> (did: String, attempted: String) {
        let raw = (toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "read_file", "file_excerpt": return ("Read a file", "read a file")
        case "write_file": return ("Wrote a file", "write a file")
        case "list_dir": return ("Looked through a folder", "look through a folder")
        case "grep", "search_files": return ("Searched the files", "search the files")
        case "bash", "run_command": return ("Ran a command", "run a command")
        case "web_search", "web_fetch": return ("Looked it up on the web", "look it up on the web")
        case "recall_memory", "memory_search":
            return (
                "Checked what \(AgentVoice.live.subject) \(AgentVoice.live.verb("remember"))",
                "check what \(AgentVoice.live.subject) \(AgentVoice.live.verb("remember"))"
            )
        case "commit_memory": return ("Saved something to memory", "save something to memory")
        case "desk_add_item": return ("Added it to the Desk", "add it to the Desk")
        case "inner_state":
            return (
                "Checked in with \(AgentVoice.live.possessive) inner state",
                "check in with \(AgentVoice.live.possessive) inner state"
            )
        case "": return ("Used a tool", "use a tool")
        default:
            let words = raw.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
            guard let first = words.first else { return ("Used a tool", "use a tool") }
            let rest = words.dropFirst().joined(separator: " ")
            let phrase = first + (rest.isEmpty ? "" : " " + rest)
            let sentence = phrase.prefix(1).uppercased() + phrase.dropFirst()
            return (String(sentence.prefix(48)), "run " + String(phrase.prefix(44)))
        }
    }

    /// A tool name a person can read. Unknown names are de-snake-cased rather
    /// than shown raw, and never interpolated with their arguments.
    static func plainName(_ toolName: String?) -> String {
        phrases(toolName).did
    }

    /// The same call when it did not work. "Wrote a file" asserts the very
    /// thing that did not happen, so a failed call gets its own sentence
    /// rather than the success one (2026-09-06).
    static func failedName(_ toolName: String?) -> String {
        "Couldn't \(phrases(toolName).attempted)"
    }

    /// The file a tool call touched, when its input names one. Returns the last
    /// path component only — the room is not a place for absolute paths.
    static func touchedFile(inputJSON: String?) -> String? {
        guard let inputJSON,
              let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["path", "file", "file_path", "filename", "target"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (value as NSString).lastPathComponent
            }
        }
        return nil
    }

    /// One readable line per tool call: "Read a file · SidebarModels.swift".
    /// `ok` is the call's recorded outcome; only a recorded FALSE says the
    /// call failed, since most rows record nothing (2026-09-06).
    static func detailLine(toolName: String?, inputJSON: String?, ok: Bool? = nil) -> String {
        let name = ok == false ? failedName(toolName) : plainName(toolName)
        guard let file = touchedFile(inputJSON: inputJSON) else { return name }
        return "\(name) · \(file)"
    }

    /// The trailer under a clipped detail list, or nil when nothing is hidden.
    static func overflowLine(total: Int, shown: Int) -> String? {
        guard total > shown else { return nil }
        return "and \(total - shown) more"
    }
}

/// Whether the room is showing trouble, and how stuck she is. Derived from the
/// transcript that is already loaded — no counter, no new state to go stale.
enum ChatShellTroubleState {
    /// A turn that failed or was cut off. 2026-09-06: a turn the person
    /// STOPPED is not trouble — pressing Stop is an answer, not a fault, and
    /// it must not raise the orange card. The cancel writer stamps `partial`
    /// alongside `cancelled`, so the cancelled flag has to be read first or
    /// every Stop still reads as a failure.
    static func isFailed(_ message: ChatMessage) -> Bool {
        if message.metadata?.cancelled == true { return false }
        return message.metadata?.error?.isEmpty == false
            || message.metadata?.partial == true
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
    static func consecutiveFailures(_ messages: [ChatMessage]) -> Int {
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

    /// Whether the failed turn at the tail actually dispatched a tool. The
    /// evidence is the turn's own tool receipts — the rows after the last
    /// thing the person said. Only a turn with none of them may be described
    /// as having sent nothing anywhere (2026-09-06).
    static func tailTurnDispatchedTools(_ messages: [ChatMessage]) -> Bool {
        for message in messages.reversed() {
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if role == "user" { return false }
            if role == "tool" { return true }
        }
        return false
    }

    static func showsStuckLink(_ messages: [ChatMessage]) -> Bool {
        consecutiveFailures(messages) >= ChatShellCopy.stuckRetryThreshold
    }
}

/// How a conversation OPENED, for the rows whose stored title cannot say.
///
/// Persistence titles a session once, from its first user message, so this is
/// only consulted for the two rows that have no such title: a provider row
/// stamped with a machine id (`Telegram 1394548068`) and a session that never
/// had a user turn at all (a proactive greeting or brief). For those the
/// answer lives in the transcript and nowhere cheaper — `ChatSession` carries
/// only the LAST message preview, which is the very thing that made a row's
/// name change every turn.
///
/// The read is bounded and memoized: the first 200 rows of
/// `<dataRoot>/chat/messages/<id>.jsonl`, keyed by session id AND message
/// count, so a session is read once and re-read only when its transcript
/// actually moved. Misses are cached too — a failed read must not become a
/// file open on every render pass.
@MainActor
final class ChatShellOpeningLine {
    static let shared = ChatShellOpeningLine()

    /// How far in the scan will look for the first spoken line. Agent,
    /// 2026-09-02: a byte budget was the wrong ruler — one session opens with
    /// a 9 KB memory block and another says nothing human until row 21, 120 KB
    /// in, so both rows read "New conversation" while their real opening lines
    /// sat just past the cap. The scan is bounded by ROWS, with a byte ceiling
    /// only so a runaway file cannot be read whole.
    private static let rowBudget = 200
    private static let byteCeiling = 1 << 20
    /// Read granularity; a transcript row is rarely larger than this.
    private static let chunkSize = 64 * 1024
    private var cache: [String: String] = [:]

    private init() {}

    /// The first user line of the session, or its first line of any role when
    /// no user ever spoke. nil when there is nothing to read.
    func line(for session: ChatSession) -> String? {
        let key = "\(session.id)#\(session.messageCount ?? -1)"
        if let hit = cache[key] { return hit.isEmpty ? nil : hit }
        let resolved = Self.read(sessionID: session.id) ?? ""
        cache[key] = resolved
        return resolved.isEmpty ? nil : resolved
    }

    private static func read(sessionID: String) -> String? {
        guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            return nil
        }
        let url = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeID).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var firstBridge: String? = nil
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
                guard let spoken = spokenLine(line) else { continue }
                if !ChatShellConversationRow.hasBridgePrefix(spoken) { return spoken }
                if firstBridge == nil {
                    firstBridge = ChatShellConversationRow.stripBridgePrefix(spoken)
                }
            }
        }
        // Nobody human spoke, but an agent opened the thread: that line is
        // still a better name than "New conversation".
        return firstBridge
    }

    /// One transcript row's user text, or nil when the row is not a person
    /// speaking (a system block, a tool result, her own turn) or does not
    /// parse — a clipped tail row is simply skipped.
    private static func spokenLine(_ line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line))
                as? [String: Any],
              let content = object["content"] as? String
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
}

/// The last turn's timestamp, read from the tail of the transcript file and
/// cached per session id + message count, so the list's times come from the
/// conversation itself and not from whatever last touched the index row.
@MainActor
final class ChatShellLastTurn {
    static let shared = ChatShellLastTurn()
    private var cache: [String: String] = [:]
    private let tailBytes = 8_192

    func stamp(for session: ChatSession) -> String? {
        let key = "\(session.id)#\(session.messageCount ?? -1)"
        if let hit = cache[key] { return hit.isEmpty ? nil : hit }
        let resolved = readTail(sessionID: session.id) ?? ""
        cache[key] = resolved
        return resolved.isEmpty ? nil : resolved
    }

    private func readTail(sessionID: String) -> String? {
        guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else { return nil }
        let url = PersistenceCore.defaultDataRoot()
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

/// Writes a resolved opening line back as the session's title, once per
/// session per process, through the same rename path the row's context menu
/// uses. Nothing is written for a session that already has a real title.
@MainActor
enum ChatShellNaming {
    private static var settled = Set<String>()

    static func settle(_ session: ChatSession, appModel: AppModel) {
        guard !settled.contains(session.id),
              ChatShellConversationRow.isMachineTitle(
                ChatShellConversationRow.stripBridgePrefix(session.title)),
              let line = ChatShellOpeningLine.shared.line(for: session)
        else { return }
        settled.insert(session.id)
        let title = ChatShellConversationRow.plainText(
            ChatShellConversationRow.stripBridgePrefix(line))
        guard !title.isEmpty else { return }
        Task { await appModel.renameChatSession(id: session.id, title: title) }
    }
}

extension ChatShellConversationRow {
    /// A session with messages where no person ever spoke: her morning briefs
    /// and other things she started on her own.
    @MainActor
    static func isHerOwn(_ session: ChatSession) -> Bool {
        guard isMachineTitle(stripBridgePrefix(session.title)),
              (session.messageCount ?? 0) > 0 else { return false }
        return ChatShellOpeningLine.shared.line(for: session) == nil
    }

    /// The view-side entry point: resolves the opening line only for the rows
    /// that need one, and leaves every other row on its stored title.
    @MainActor
    static func title(for session: ChatSession) -> String {
        let stored = stripBridgePrefix(session.title)
        guard isMachineTitle(stored) else { return title(for: session, openingLine: nil) }
        return title(for: session, openingLine: ChatShellOpeningLine.shared.line(for: session))
    }
}
