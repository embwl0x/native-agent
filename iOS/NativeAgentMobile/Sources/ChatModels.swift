import SwiftUI
import UIKit
import NativeAgentShared

// MARK: - Models

/// 2026-09-06: "the Mac published no transcript for this session" and "the Mac
/// published an EMPTY transcript for this session" are different facts, and
/// only the second one is authority to clear the phone's copy. Every layer
/// used to carry them as one `[ChatMessage]?` and collapse empty to nil, so a
/// chat cleared on the Mac stayed on the phone forever with no way to say so.
enum MacTranscriptRead: Equatable {
    /// No row for this session in the newest snapshot (still downloading, the
    /// session is not in the published set, or the read failed). Hold last-good.
    case unavailable
    /// The Mac's transcript for this session, possibly empty. `generation` is
    /// the session's transcript version at publication — a counter the Mac
    /// bumps on every clear and every transcript write. An empty transcript
    /// only clears the phone when that counter is strictly greater than the
    /// last one applied for the session.
    case published([ChatMessage], generation: Int?)

    /// The rows the Mac published — empty both for `.unavailable` and for an
    /// explicit empty transcript, so never branch on this alone.
    var messages: [ChatMessage] {
        guard case .published(let messages, _) = self else { return [] }
        return messages
    }
}

struct ChatAttachmentSummary: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var type: String
    var mime: String?
    var base64: String?
    var byteSize: Int?

    init(
        id: String = UUID().uuidString,
        name: String,
        type: String,
        mime: String? = nil,
        base64: String? = nil,
        byteSize: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.mime = mime
        self.base64 = base64
        self.byteSize = byteSize
    }
}

/// One tool (or skill) firing during an assistant turn. Collected live from
/// the Mac's `tool_use` progress events so iOS can render the "flip-through"
/// box and the collapsed "N tools used" summary, the same as the Mac chat.
/// `seq` is the Mac-side monotonic `toolSeq` — used for ordering and de-duping
/// out-of-order / duplicate iCloud KVS delivery.
struct ToolEvent: Codable, Equatable, Identifiable {
    var id: String { "\(seq)-\(name)" }
    let name: String
    let seq: Int
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
    var isStreaming: Bool = false
    var attachments: [ChatAttachmentSummary] = []
    /// Tools/skills this assistant turn used (assistant messages only). Drives
    /// the live flip-box while streaming and the collapsed summary when done.
    var toolEvents: [ToolEvent] = []

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isStreaming: Bool = false,
        attachments: [ChatAttachmentSummary] = [],
        toolEvents: [ToolEvent] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.attachments = attachments
        self.toolEvents = toolEvents
    }

    enum CodingKeys: String, CodingKey {
        case id, role, text, isStreaming, attachments, toolEvents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        attachments = try c.decodeIfPresent([ChatAttachmentSummary].self, forKey: .attachments) ?? []
        toolEvents = try c.decodeIfPresent([ToolEvent].self, forKey: .toolEvents) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encode(isStreaming, forKey: .isStreaming)
        try c.encode(attachments, forKey: .attachments)
        if !toolEvents.isEmpty { try c.encode(toolEvents, forKey: .toolEvents) }
    }
}

struct PendingPhotoAttachment: Identifiable, Equatable {
    let id: String
    var attachment: MultimodalAttachment
    var thumbnail: UIImage

    static func == (lhs: PendingPhotoAttachment, rhs: PendingPhotoAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

struct ChatSessionTab: Identifiable, Hashable {
    enum Kind: Hashable {
        case main
        case pinned(String)
        /// The derived conversation-anchor tab. It is NOT a pin: nobody wrote it
        /// into a pin list, so there is nothing to unpin and no close control.
        case anchor(String)
    }

    var id: String
    var title: String
    var systemImage: String
    var sessionID: String?
    var kind: Kind

    /// The session a close control may unpin — real Mac-owned pins only.
    /// The anchor tab returns nil: an unpin request for it would name a row
    /// the human may never have pinned, and would drop the live conversation
    /// off the strip until the next publish put it back.
    var closableSessionID: String? {
        if case .pinned(let sessionID) = kind { return sessionID }
        return nil
    }
}

/// The conversation anchor as the phone consumes it: the session the human is
/// currently active in on a direct remote surface (Telegram today; Signal or
/// WhatsApp later), published by the Mac as `chat_anchor.json` in the same
/// `.core` snapshot group as `sessions.json`.
///
/// Field-for-field mirror of `PersistenceCore.ConversationAnchorPin`, declared
/// here because the phone links only `NativeAgentShared`. `source` and
/// `updatedAt` are display/diagnostics ONLY — nothing on this side may branch
/// on which surface published the anchor. Both are optional so an older or
/// partial file still yields a usable anchor.
struct ConversationAnchorPin: Codable, Equatable, Sendable {
    var sessionId: String
    var source: String?
    var updatedAt: String?

    /// The id, or nil when the file names none. Same discipline as the Mac's
    /// `readUnlocked`: an empty id is no anchor.
    var cleanSessionId: String? {
        let clean = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

/// The phone's half of the anchor rules — the same two pure functions the Mac
/// consumes (`ConversationAnchor.merged` / `.shouldAdoptAnchor`), over the
/// phone's own row type.
enum MobileConversationAnchor {
    /// The anchor at the FRONT of the pinned rows, never duplicated.
    ///
    /// A DERIVED view, exactly as on the Mac: the phone never writes the anchor
    /// into anyone's pin list and never syncs a pin back to the Mac. When the
    /// anchor is absent the list is returned untouched.
    static func merged(_ anchor: ChatSession?, into pinnedSessions: [ChatSession]) -> [ChatSession] {
        guard let anchor, anchor.archived != true else { return pinnedSessions }
        return [anchor] + pinnedSessions.filter { $0.id != anchor.id }
    }

    /// Whether the chat screen should adopt the anchor as its selection.
    ///
    /// THE RULE, copied from the Mac verbatim: default to the anchor, but never
    /// take the human off a session they chose. `liveSessionIds` keeps a stale
    /// anchor from selecting a session the phone cannot show.
    static func shouldAdoptAnchor(
        anchorSessionId: String?,
        currentSelection: String?,
        userChoseThisLaunch: Bool,
        liveSessionIds: Set<String>
    ) -> Bool {
        guard !userChoseThisLaunch else { return false }
        guard let anchor = anchorSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !anchor.isEmpty,
              liveSessionIds.contains(anchor) else { return false }
        let selection = (currentSelection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return selection != anchor
    }
}

/// Whether the human has explicitly picked a chat session since this launch.
/// Process-scoped for the same reason as the Mac's `MacChatSelectionIntent`:
/// "this launch" is the window in which their choice is still current.
@MainActor
enum MobileChatSelectionIntent {
    private(set) static var userChoseThisLaunch = false

    /// 2026-09-06: the conversation a tapped reply notification opened. It is
    /// an explicit selection, not a pinned tab, so the externally-removed-pin
    /// reconciler must not read its absence from the pinned snapshot as a pin
    /// the Mac took away and bounce the user back to the main chat. Cleared the
    /// moment the human picks any other session.
    private(set) static var notifiedSessionID: String?

    /// Called wherever the human's own intent selects a session — tapping a
    /// tab, or starting a new chat.
    static func noteUserChoice() {
        userChoseThisLaunch = true
        notifiedSessionID = nil
    }

    /// A tapped reply notification chose this session.
    static func noteNotifiedSelection(_ sessionID: String?) {
        userChoseThisLaunch = true
        let clean = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        notifiedSessionID = (clean?.isEmpty == false) ? clean : nil
    }

    /// Test seam. Production never calls this; a launch has exactly one start.
    static func resetForTesting() {
        userChoseThisLaunch = false
        notifiedSessionID = nil
    }
}

/// Pure projection for the iOS tab strip. The phone has one current mobile
/// session plus the exact ordered Mac-owned pinned snapshot—never a second
/// source-based definition of what counts as a tab. The conversation anchor,
/// when there is one, rides at the front of the pinned run as a derived tab.
enum ChatSessionTabProjection {
    static func make(
        mainSessionID: String?,
        mainTitle: String,
        pinnedSessions: [ChatSession],
        anchorSession: ChatSession? = nil
    ) -> [ChatSessionTab] {
        var tabs: [ChatSessionTab] = [
            ChatSessionTab(
                id: "ios-main",
                title: cleanTitle(mainTitle, fallback: "iPhone"),
                systemImage: "iphone",
                sessionID: mainSessionID,
                kind: .main
            )
        ]
        var seen = Set([mainSessionID].compactMap { $0 })
        let ordered = MobileConversationAnchor.merged(anchorSession, into: pinnedSessions)
        // The anchor row is `.anchor`, never `.pinned`, even when it also
        // appears in the published pinned rows: the Mac merges the anchor into
        // `pinned_chat_sessions.json` itself, so presence there is not evidence
        // that the human pinned it, and a close control offered on that guess
        // would fire an unpin for a row they never pinned.
        let anchorID = anchorSession.flatMap { $0.archived == true ? nil : $0.id }
        for session in ordered where session.archived != true {
            guard seen.insert(session.id).inserted else { continue }
            let isAnchor = session.id == anchorID
            tabs.append(ChatSessionTab(
                id: session.id,
                title: cleanTitle(session.displayTitle, fallback: "Chat"),
                systemImage: "pin.fill",
                sessionID: session.id,
                kind: isAnchor ? .anchor(session.id) : .pinned(session.id)
            ))
        }
        return tabs
    }

    private static func cleanTitle(_ title: String, fallback: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }
}
