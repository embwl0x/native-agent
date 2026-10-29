import Foundation
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#endif
// Blueprint: | `ConversationModels.swift` | Shared conversations and `ChatThreadKind` declarations, navigation, tool evidence, transcripts, attachments and oriented thumbnail decoding; engine-resolved display titles default to title; Mac-owned navigation retains pin/anchor order, thread kind and exact helper owner |

public struct MultimodalAttachment: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var base64: String
    public var mime: String
    public var name: String?
    public var byteSize: Int
    public var path: String?
    public var utterance: SpeechUtterance?

    public init(id: String = UUID().uuidString, type: String, base64: String, mime: String, name: String? = nil, byteSize: Int = 0, path: String? = nil, utterance: SpeechUtterance? = nil) {
        self.id = id
        self.type = type
        self.base64 = base64
        self.mime = mime
        self.name = name
        self.byteSize = byteSize
        self.path = path
        self.utterance = utterance
    }
}

/// Tool evidence ordered by the Mac's monotonic sequence; older snapshots can omit activity.
public struct ToolEvent: Codable, Hashable, Sendable {
    public let name: String
    public let seq: Int
    public var activity: String?
    public var outcome: String?
    public var resultDetail: String?

    public init(name: String, seq: Int, activity: String? = nil, outcome: String? = nil, resultDetail: String? = nil) {
        self.name = name
        self.seq = seq
        self.activity = activity
        self.outcome = outcome
        self.resultDetail = resultDetail
    }
}

public struct TranscriptAttachmentPreview: Codable, Hashable, Sendable {
    public let png: Data?
    public init(png: Data?) { self.png = png }

    public static func thumbnail(from source: CGImageSource, maxDimension: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary)
    }
}

/// What KIND of conversation a chat session row is — recorded on the session
/// index row by its creator. Readers use `SessionConversation` in Transcripts,
/// never the ID's shape. Rows without a kind still read by their source.
///
/// Only its owner may correct a session's conversation kind.
/// Anchoring is a temporary role (`ChatAnchorPin`), not a conversation kind.
///
/// `legacy` is the honest label for a row minted without a thread
/// classification. Rows keep it until something classifies them.
public enum ChatThreadKind: String, Sendable, Equatable, CaseIterable, Codable {
    /// A private conversation between User and her, on any surface.
    case direct
    /// A Slack channel or Slack-threaded reply — other humans are present.
    case channel
    /// Her conversation with another agent or helper. User may talk
    /// in it; it is still not his conversation with her.
    case agent
    /// Her own work: resident wakes, workers and builder work, with no person.
    case builder
    /// An unrouted bridge probe. Diagnostic traffic.
    case ephemeral
    /// Minted with no classification behind it.
    case legacy

    public var isHisConversation: Bool { self == .direct }
    public var isPeerConversation: Bool { self == .agent }
    public var isOwnWork: Bool { self == .builder }

    public static func parse(_ raw: String?) -> ChatThreadKind? {
        guard let raw else { return nil }
        return ChatThreadKind(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Creator-owned conversation keys carry the same declaration as today's
    /// minting boundary. They correct historical kinds on read, without using
    /// session-ID spelling or the last surface to append a message.
    public static func creatorDeclaration(source: String?, sourceKey: String?) -> ChatThreadKind? {
        guard let source, let sourceKey else { return nil }
        let fields = sourceKey.split(separator: ":", omittingEmptySubsequences: false)
        switch source {
        case "telegram":
            guard (fields.count == 2 || fields.count == 3), fields[0] == "telegram",
                  let chat = Int64(fields[1]), chat != 0 else { return nil }
            if fields.count == 3 {
                guard let topic = Int64(fields[2]), topic > 0 else { return nil }
                return .channel
            }
            return chat > 0 ? .direct : .channel
        case "slack":
            guard (fields.count == 3 && fields[0] == "conversation")
                    || (fields.count == 4 && fields[0] == "thread"),
                  !fields[1].isEmpty, let prefix = fields[2].first,
                  "DCG".contains(prefix) else { return nil }
            return prefix == "D" ? .direct : .channel
        default: return nil
        }
    }

    /// The kind implied by a session row's `source`, used when a row is
    /// read without a kind. Deliberately conservative: it classifies only what the source
    /// actually proves. Mixed-purpose transports need a recorded kind or
    /// creator key; their source alone proves neither a private chat nor a room.
    public static func inferred(fromSource source: String) -> ChatThreadKind {
        switch normalizedSource(source) {
        case "ios", "app": return .direct
        case "bot", "agent-bridge", "codex-bridge", "claude-bridge", "omp-bridge",
             "agent_bridge", "codex_bridge", "claude_bridge", "omp_bridge",
             "bridge", "claude", "codex", "omp": return .agent
        case "resident-wake", "builder", "worker": return .builder
        default: return .legacy
        }
    }

    /// Canonical transcript source, shared by persistence and identity comparisons.
    public static func normalizedSource(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "telegram": return "telegram"
        case "ios", "mobile", "iphone", "icloud": return "ios"
        case "app", "chat", "mac", "default", "": return "app"
        default: return normalized
        }
    }
}

public struct ChatSession: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// TranscriptsFacade resolves display titles; canonical index rows omit this field and decode with `title`.
    public var displayTitle: String
    public var source: String?
    public var sourceKey: String?
    public var createdAt: String
    public var updatedAt: String?
    public var archived: Bool?
    public var messageCount: Int?
    public var firstMessageAt: String? = nil
    public var lastMessageAt: String? = nil
    public var lastMessagePreview: String?
    public var summary: String?
    /// Lineage/project metadata on the canonical session row; never another transcript or session store.
    public var parentSessionId: String? = nil
    public var rootSessionId: String? = nil
    public var forkedAtMessageId: String? = nil
    public var projectSpaceId: String? = nil
    public var worktreePath: String? = nil
    public var providerId: String? = nil
    public var modelId: String? = nil
    /// Monotonic transcript write/clear generation; never clock-derived, nil on unversioned rows.
    public var transcriptGeneration: Int? = nil
    /// Only the creator corrects conversation kind; Transcripts' SessionConversation owns its read rule.
    public var threadKind: String? = nil
    /// Exact helper owner, when this agent conversation belongs to a helper.
    public var helperID: String? = nil
    /// Engine classification; the phone never infers bridge provenance from titles or reclassifies sources.
    public var isWorkingConversation: Bool? = nil

    public init(
        id: String, title: String, source: String? = nil, sourceKey: String? = nil,
        createdAt: String, updatedAt: String? = nil, archived: Bool? = nil,
        messageCount: Int? = nil, lastMessagePreview: String? = nil, summary: String? = nil,
        parentSessionId: String? = nil, rootSessionId: String? = nil,
        forkedAtMessageId: String? = nil, projectSpaceId: String? = nil,
        worktreePath: String? = nil, providerId: String? = nil, modelId: String? = nil,
        transcriptGeneration: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.displayTitle = title
        self.source = source
        self.sourceKey = sourceKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
        self.messageCount = messageCount
        self.lastMessagePreview = lastMessagePreview
        self.summary = summary
        self.parentSessionId = parentSessionId
        self.rootSessionId = rootSessionId
        self.forkedAtMessageId = forkedAtMessageId
        self.projectSpaceId = projectSpaceId
        self.worktreePath = worktreePath
        self.providerId = providerId
        self.modelId = modelId
        self.transcriptGeneration = transcriptGeneration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        displayTitle = try c.decodeIfPresent(String.self, forKey: .displayTitle) ?? title
        source = try c.decodeIfPresent(String.self, forKey: .source)
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount)
        firstMessageAt = try c.decodeIfPresent(String.self, forKey: .firstMessageAt)
        lastMessageAt = try c.decodeIfPresent(String.self, forKey: .lastMessageAt)
        lastMessagePreview = try c.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        parentSessionId = try c.decodeIfPresent(String.self, forKey: .parentSessionId)
        rootSessionId = try c.decodeIfPresent(String.self, forKey: .rootSessionId)
        forkedAtMessageId = try c.decodeIfPresent(String.self, forKey: .forkedAtMessageId)
        projectSpaceId = try c.decodeIfPresent(String.self, forKey: .projectSpaceId)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        providerId = try c.decodeIfPresent(String.self, forKey: .providerId)
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        transcriptGeneration = try c.decodeIfPresent(Int.self, forKey: .transcriptGeneration)
        threadKind = try c.decodeIfPresent(String.self, forKey: .threadKind)
        helperID = try c.decodeIfPresent(String.self, forKey: .helperID)
        isWorkingConversation = try c.decodeIfPresent(Bool.self, forKey: .isWorkingConversation)
    }
}

public extension ChatSession {
    /// Display and persistence share this exact default title for new sessions.
    static let placeholderTitle = "New Chat"
}

public struct ConversationAnchorPin: Sendable, Equatable, Codable {
    public let sessionId: String
    public let source: String
    public let updatedAt: String
    public init(sessionId: String, source: String, updatedAt: String) {
        self.sessionId = sessionId; self.source = source; self.updatedAt = updatedAt
    }
    public var cleanSessionId: String? { sessionId.isEmpty ? nil : sessionId }
}

public struct ChatSessionNavigation: Codable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable {
        public let session: ChatSession
        public let isPinned: Bool
        public let isAnchor: Bool
        public init(session: ChatSession, isPinned: Bool, isAnchor: Bool) {
            self.session = session; self.isPinned = isPinned; self.isAnchor = isAnchor
        }
    }
    public let rows: [Row]
    public let pinnedSessionIDs: [String]
    public let anchor: ConversationAnchorPin?
    public init(rows: [Row], pinnedSessionIDs: [String], anchor: ConversationAnchorPin?) {
        self.rows = rows; self.pinnedSessionIDs = pinnedSessionIDs; self.anchor = anchor
    }
}

public struct ChatMessageRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var sessionId: String? = nil
    public var role: String
    public var content: String
    public var createdAt: String = NativeTimestampFormat.plainZulu(Date())
    public var runId: String? = nil
    public var source: String? = nil
    // Mac metadata.attachments preserves attachment summaries across transcript refreshes.
    public var metadata: ChatMessageMetadata? = nil
    public var interactionJSON: String? = nil
    public var interactionDescriptorJSON: String? = nil
    public var interactionSessionID: String? = nil
    public var toolEvents: [ToolEvent]? = nil
    public init(id: String, sessionId: String?, role: String, content: String, createdAt: String,
                runId: String?, source: String?, metadata: ChatMessageMetadata?, isPersonVisible: Bool) {
        self.id = id; self.sessionId = sessionId; self.role = role; self.content = content
        self.createdAt = createdAt; self.runId = runId; self.source = source; self.metadata = metadata
        self.isPersonVisible = isPersonVisible
    }
    /// Local paging evidence, excluded from the transport bytes.
    public var isPersonVisible = true
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, role, content, createdAt, runId, source, metadata
        case interactionJSON, interactionDescriptorJSON, interactionSessionID, toolEvents
    }
    public mutating func omitAttachmentPreviews() {
        guard let attachments = metadata?.attachments else { return }
        metadata?.attachments = attachments.map { value in
            var copy = value; copy.preview = nil; return copy
        }
    }
}

public struct ChatTranscriptSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: String { sessionId }
    public var sessionId: String
    public var messages: [ChatMessageRecord]
    public var readError: String? = nil
    /// A newer Mac write/clear counter authorizes empty transcripts; unversioned empty rows stay inert.
    public var transcriptGeneration: Int? = nil
    /// The Mac holds rows older than this window. Absent on older Mac builds.
    public var hasOlder: Bool? = nil
    /// Reading copies beside the transcript, never canonical chat messages.
    public var otherRooms: [OtherRoomExchange]? = nil
    public init(sessionId: String, messages: [ChatMessageRecord], transcriptGeneration: Int?, hasOlder: Bool = false) {
        self.sessionId = sessionId; self.messages = messages
        self.transcriptGeneration = transcriptGeneration; self.hasOlder = hasOlder
    }
    public func omittingAttachmentPreviews() -> Self {
        var copy = self
        for index in copy.messages.indices { copy.messages[index].omitAttachmentPreviews() }
        return copy
    }
}

public struct ChatMessageMetadata: Codable, Hashable, Sendable {
    // Assistant brain metadata
    public var model: String?
    public var requestedModel: String?
    public var reasoningEffort: String?
    public var fileAccessMode: String?
    public var codexSandbox: String?
    public var error: String?
    /// Refusals never regenerate directly; a proven pre-dispatch refusal may prepare a draft.
    public var providerRefusal: Bool? = nil
    public var providerRefusalDraft: Bool? = nil
    // Partial or cancelled assistant rows never count as completed replies or hide the failure bubble.
    public var partial: Bool? = nil
    public var cancelled: Bool? = nil
    /// Exact saved turn outcome prevents duplicate reply bubbles on the phone.
    public var completionState: String?
    // Tool-use pill metadata (role=tool messages).
    public var kind: String?          // "tool_use" | `approvalPendingKind`
    public var toolName: String?      // e.g. "read_file"
    // Input dict serialized as JSON string for Codable simplicity
    public var inputJSON: String?
    public var resultSummary: String?
    /// Row settlement, locked with its receipt; the tool fold trusts it over the receipt envelope.
    public var resultStatus: String?
    /// Decode-only interaction state outranks stale receipts when `result_status` is absent; never re-encoded.
    public var interactionState: String?
    public var ok: Bool?
    public var durationMs: Int?
    // write_file diff support
    public var beforeContent: String?
    public var afterContent: String?
    // approval_pending
    public var approvalId: String?

    /// Decode-only origin of a cross-conversation card (`ApprovalChatCards.interactionMirrorKind`).
    public var mirrorInteractionId: String?
    public var mirrorInteractionSessionId: String?
    public var interactionMirror: (sessionID: String, interactionID: String)? {
        guard kind == "interaction_mirror", let mirrorInteractionId, let mirrorInteractionSessionId
        else { return nil }
        return (mirrorInteractionSessionId, mirrorInteractionId)
    }
    /// Round-trip transcript attachments through Mac snapshots and iOS history.
    public var attachments: [PersistedAttachment]?
    /// Origin of user rows not authored by the human at this Mac; absence is never proof of human trust.
    public var origin: ChatMessageOriginMetadata?
    /// Decode-only surface/agent projection of the recorded turn envelope for presentation.
    public var envelope: ChatMessageOriginMetadata?
    /// Engine-stamped leading working-commentary characters, folded away by the settled bubble.
    /// Absent on single-round turns and user rows.
    public var workingCommentaryChars: Int?
    /// Opaque identity of the turn that produced this assistant row.
    public var turnTraceId: String?
    /// Decode-only engine stamp: `systemRow` marks a persisted turn-failure notice, never a reply.
    public var mechanicalKind: String?
    /// Failed-turn effects: `ProviderFailure.WorkState` raw value, or "not sent" with proof it never left the Mac.
    /// Decode-only on saved rows, stamped on synthetic bubbles; Retry must preserve possible effects.
    public var failureWork: String?

    // Preserve persisted key spellings on the wire.
    enum CodingKeys: String, CodingKey {
        case model, requestedModel, reasoningEffort, fileAccessMode, codexSandbox, error, partial, cancelled, completionState, failureWork
        case providerRefusal = "provider_refusal"
        case providerRefusalDraft = "provider_refusal_draft"
        case kind
        case toolName = "tool_name"
        case resultSummary = "result_summary"
        case resultStatus = "result_status"
        case ok
        case durationMs = "duration_ms"
        case beforeContent = "before_content"
        case afterContent = "after_content"
        case approvalId = "approval_id"
        case inputJSON = "input"
        case attachments
        case origin
        case workingCommentaryChars
        case turnTraceId
    }

    /// Empty metadata for callers that stamp individual fields.
    public init() {}

    /// Only `syntheticError(_:userRowPersisted:)` bubbles carry this; nil on decoded rows.
    public var syntheticUserRowPersisted: Bool?
    /// Payload-free guard against text-only regeneration when an unsaved user row had attachments.
    public var syntheticInputHadAttachments: Bool?

    /// Transport decoding is strict for the phone's consumed fields; canonical parsing is separate.
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        turnTraceId = try fields.decodeIfPresent(String.self, forKey: .turnTraceId)
        attachments = try fields.decodeIfPresent([PersistedAttachment].self, forKey: .attachments)
        completionState = try fields.decodeIfPresent(String.self, forKey: .completionState)
        failureWork = try fields.decodeIfPresent(String.self, forKey: .failureWork)
        error = try fields.decodeIfPresent(String.self, forKey: .error)
        partial = try fields.decodeIfPresent(Bool.self, forKey: .partial)
        cancelled = try fields.decodeIfPresent(Bool.self, forKey: .cancelled)
    }
}

public struct PersistedAttachment: Codable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var mime: String?
    public var name: String?
    public var byteSize: Int64?
    public var path: String?
    public var utterance: SpeechUtterance?
    public var preview: TranscriptAttachmentPreview?

    public init(id: String, type: String, mime: String, name: String?, byteSize: Int64, path: String? = nil) {
        self.id = id; self.type = type; self.mime = mime; self.name = name; self.byteSize = byteSize; self.path = path
    }

}

public struct ChatMessageOriginMetadata: Encodable, Hashable, Sendable {
    public var surface: String?
    public var agent: String?
    public var authored: String?
    public var peerSources: [String]?
    public var elevatedPeerSources: [String]?
    /// Recorded envelope identity for attribution only; never current authority.
    public var verifiedUserId: String?

    public init(surface: String? = nil, agent: String? = nil) {
        self.surface = surface
        self.agent = agent
    }
}
