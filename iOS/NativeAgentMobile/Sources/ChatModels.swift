// PATCH-2026-05-06: ios-companion chat interface
// PATCH-2026-05-09: voice-io — push-to-talk input + TTS output
// PATCH-2026-05-30: streaming wired via text_delta BridgeMessage path
//                   (see ChatStore text_delta handling lines ~434-525).
import SwiftUI
import UIKit
import Speech
import PhotosUI
import NativeAgentShared

// MARK: - Models

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

struct ChatMessage: Identifiable, Codable {
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
    }

    var id: String
    var title: String
    var systemImage: String
    var sessionID: String?
    var kind: Kind
}

/// Pure projection for the iOS tab strip. The phone has one current mobile
/// session plus the exact ordered Mac-owned pinned snapshot—never a second
/// source-based definition of what counts as a tab.
enum ChatSessionTabProjection {
    static func make(
        mainSessionID: String?,
        mainTitle: String,
        pinnedSessions: [ChatSession]
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
        for session in pinnedSessions where session.archived != true {
            guard seen.insert(session.id).inserted else { continue }
            tabs.append(ChatSessionTab(
                id: session.id,
                title: cleanTitle(session.displayTitle, fallback: "Chat"),
                systemImage: "pin.fill",
                sessionID: session.id,
                kind: .pinned(session.id)
            ))
        }
        return tabs
    }

    private static func cleanTitle(_ title: String, fallback: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }
}
