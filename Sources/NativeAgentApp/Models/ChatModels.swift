import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var sessionId: String? = nil
    // FIX: safe defaults so one message missing role/content doesn't fail the
    // whole getChatMessages decode and blank the primary chat surface.
    var role: String = "assistant"
    var content: String = ""
    var createdAt: String = ISO8601DateFormatter().string(from: Date())
    var runId: String? = nil
    var source: String? = nil
    var metadata: ChatMessageMetadata? = nil

    init(
        id: String = UUID().uuidString,
        sessionId: String? = nil,
        role: String = "assistant",
        content: String = "",
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        runId: String? = nil,
        source: String? = nil,
        metadata: ChatMessageMetadata? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.runId = runId
        self.source = source
        self.metadata = metadata
    }

    // FIX-2026-05-28: Swift's synthesized Decodable calls decode(_:forKey:) for
    // non-optional stored properties and throws keyNotFound even when a Swift
    // default exists — so the pass-1 defaults above were dead for decoding. This
    // explicit init uses decodeIfPresent ?? default so a message missing role/
    // content/createdAt no longer fails the whole getChatMessages decode and
    // blanks the chat surface. Encodable stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A malformed advisory sibling must not make the caller fall back to
        // role/content-only projection and thereby discard a valid
        // metadata.origin trust signal. Each field degrades independently.
        self.id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        self.sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        self.content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        self.createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt))
            ?? ISO8601DateFormatter().string(from: Date())
        self.runId = try? c.decodeIfPresent(String.self, forKey: .runId)
        self.source = try? c.decodeIfPresent(String.self, forKey: .source)

        // Missing/null metadata is the normal historical shape. A PRESENT
        // container of the wrong JSON type is different: silently turning it
        // into nil would make a user/source=app row look human even though its
        // provenance envelope was unreadable. Preserve that distinction with
        // the same closed, non-rendered sentinel used for malformed `origin`.
        if !c.contains(.metadata) || (try? c.decodeNil(forKey: .metadata)) == true {
            self.metadata = nil
        } else if let decoded = try? c.decode(ChatMessageMetadata.self, forKey: .metadata) {
            self.metadata = decoded
        } else {
            var unreadable = ChatMessageMetadata()
            unreadable.origin = ChatMessageOriginMetadata(surface: "unreadable")
            self.metadata = unreadable
        }

        let decodedRole = try? c.decodeIfPresent(String.self, forKey: .role)
        let normalizedRole = decodedRole?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if self.metadata?.origin != nil, normalizedRole != "user" {
            // Canonical writers put origin only on user rows. A contradictory
            // or unreadable role must not suppress the warning and attribute
            // the row to Agent, so fail closed toward the provenance-bearing
            // user presentation.
            self.role = "user"
        } else {
            self.role = decodedRole ?? "assistant"
        }
    }
}

struct ChatMessageMetadata: Codable, Hashable {
    // Assistant brain metadata
    var model: String?
    var requestedModel: String?
    var reasoningEffort: String?
    var fileAccessMode: String?
    var codexSandbox: String?
    var error: String?
    // Truncated-turn markers — written by persistPartialIfNeeded when a turn
    // fails or is cancelled mid-stream. Decoded so the UI can distinguish a
    // partial/cancelled row from a completed reply; otherwise a persisted
    // partial counts as "assistant landed" and suppresses the failure bubble
    // (audit finding #2, 2026-06-14).
    var partial: Bool? = nil
    var cancelled: Bool? = nil
    // PATCH-2026-05-08: wave2-chat-ux Tool-use pill metadata (role=tool messages)
    var kind: String?          // "tool_use" | "approval_pending"
    var toolName: String?      // e.g. "read_file"
    // Input dict serialized as JSON string for Codable simplicity
    var inputJSON: String?
    var resultSummary: String?
    var ok: Bool?
    var durationMs: Int?
    // write_file diff support
    var beforeContent: String?
    var afterContent: String?
    // approval_pending
    var approvalId: String?
    // eval3/T3: attachments persisted under metadata.attachments by
    // ChatOrchestrationClient.appendMessage (NativeAgentCore). Round-tripped
    // here so getChatMessages → MacSyncEngine snapshot → iOS refreshChatHistory
    // preserves attachments instead of dropping them at the snapshot edge.
    var attachments: [PersistedAttachment]?
    /// 658.14 session provenance. Present on user rows that did NOT originate
    /// from the human at this Mac (bridge wakes and automated injections).
    /// Absent means "no claim recorded", never "trusted human" — see
    /// MacChatMessageProvenance for how absence is rendered.
    var origin: ChatMessageOriginMetadata?

    // Custom CodingKeys to map snake_case daemon keys → camelCase Swift properties
    enum CodingKeys: String, CodingKey {
        case model, requestedModel, reasoningEffort, fileAccessMode, codexSandbox, error, partial, cancelled
        case kind
        case toolName = "tool_name"
        case toolNameCamel = "toolName"   // streamed/persisted rows use camelCase
        case resultSummary = "result_summary"
        case ok
        case durationMs = "duration_ms"
        case beforeContent = "before_content"
        case afterContent = "after_content"
        case approvalId = "approval_id"
        case inputJSON = "input"
        case attachments
        case origin
    }

    /// Empty metadata. Declaring `init(from:)` in the body suppresses the
    /// synthesized memberwise init, so callers that need to stamp a single
    /// field (the synthetic-error bubbles below) had no way to build one.
    init() {}

    /// Metadata for an in-memory synthetic failure bubble. `error` is the field
    /// `messageNeedsRetry` (ChatMessageListView) reads, so stamping it is what
    /// makes the "Try again" affordance the bubble's own copy names actually
    /// render (sweep R4 C7). `userRowPersisted` records whether the ORIGINAL
    /// turn wrote the user's message to the transcript before failing — the
    /// no-provider guard bails out before client.chat ever runs, so retrying
    /// that bubble with suppressUserAppend would lose the user's message from
    /// the persisted thread (gpt-5.5 review 2026-08-06, blocking). In-memory
    /// only: deliberately NOT in CodingKeys, so it never touches the wire.
    static func syntheticError(
        _ message: String,
        userRowPersisted: Bool = true,
        inputHadAttachments: Bool = false
    ) -> ChatMessageMetadata {
        var metadata = ChatMessageMetadata()
        metadata.error = message
        metadata.syntheticUserRowPersisted = userRowPersisted
        metadata.syntheticInputHadAttachments = inputHadAttachments
        return metadata
    }

    /// See `syntheticError(_:userRowPersisted:)`. Nil on every decoded row —
    /// only synthetic in-memory bubbles carry it.
    var syntheticUserRowPersisted: Bool?
    /// Payload-free retry guard for a synthetic failure whose optimistic user
    /// row never reached canonical persistence. Attachment bytes are never
    /// retained here; this records only that text-only regeneration is unsafe.
    var syntheticInputHadAttachments: Bool?

    // Decode `input` dict as JSON string so we stay Codable without Any.
    // PATCH-2026-05-08: review-fix-B Cap big strings at decode time so a tool
    // returning a 500KB blob doesn't blow up SwiftUI rendering or memory.
    private static func _capString(_ s: String?, _ limit: Int) -> String? {
        guard let s, s.count > limit else { return s }
        return String(s.prefix(limit)) + "\n…(truncated)"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Metadata is display/advisory data. One wrong-typed sibling must not
        // discard the whole message (and with it a valid authority-bearing
        // origin object) through NativeClient's role/content fallback.
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        requestedModel = try? c.decodeIfPresent(String.self, forKey: .requestedModel)
        reasoningEffort = try? c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        fileAccessMode = try? c.decodeIfPresent(String.self, forKey: .fileAccessMode)
        codexSandbox = try? c.decodeIfPresent(String.self, forKey: .codexSandbox)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        partial = try? c.decodeIfPresent(Bool.self, forKey: .partial)
        cancelled = try? c.decodeIfPresent(Bool.self, forKey: .cancelled)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        toolName = (try? c.decodeIfPresent(String.self, forKey: .toolName))
            ?? (try? c.decodeIfPresent(String.self, forKey: .toolNameCamel))
        resultSummary = Self._capString(
            try? c.decodeIfPresent(String.self, forKey: .resultSummary),
            4_000
        )
        ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        durationMs = try? c.decodeIfPresent(Int.self, forKey: .durationMs)
        beforeContent = Self._capString(
            try? c.decodeIfPresent(String.self, forKey: .beforeContent),
            16_000
        )
        afterContent = Self._capString(
            try? c.decodeIfPresent(String.self, forKey: .afterContent),
            16_000
        )
        approvalId = try? c.decodeIfPresent(String.self, forKey: .approvalId)
        attachments = try? c.decodeIfPresent([PersistedAttachment].self, forKey: .attachments)
        // 658.14: this decode is the whole badge. A CodingKey alone does
        // nothing here — the synthesized decoder is suppressed by this custom
        // init(from:), so an unlisted field is silently always nil.
        //
        // Non-throwing on purpose, and it degrades in the honest direction. A
        // strict decode would let one malformed `origin` throw out of
        // ChatMessageMetadata, out of ChatMessage, and blank the whole
        // transcript (the 2026-05-28 failure above, again). But degrading to
        // nil would render an unreadable row as if User had typed it, which is
        // the exact trust leak this feature exists to close. So a PRESENT but
        // undecodable origin becomes an unrecognized one, which
        // MacChatMessageProvenance renders as "Automated": no blanking, and
        // never a false human. Absent stays absent.
        if let decoded = try? c.decodeIfPresent(ChatMessageOriginMetadata.self, forKey: .origin) {
            origin = decoded
        } else if c.contains(.origin) {
            origin = ChatMessageOriginMetadata(surface: "unreadable")
        } else {
            origin = nil
        }
        // input may be a dict — decode to JSON string for display
        if let rawInput = try? c.decodeIfPresent([String: AnyDecodable].self, forKey: .inputJSON) {
            let dict = rawInput.mapValues { $0.value }
            let json = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) }
            inputJSON = Self._capString(json, 4_000)
        } else {
            inputJSON = Self._capString(
                try? c.decodeIfPresent(String.self, forKey: .inputJSON),
                4_000
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(requestedModel, forKey: .requestedModel)
        try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try c.encodeIfPresent(fileAccessMode, forKey: .fileAccessMode)
        try c.encodeIfPresent(codexSandbox, forKey: .codexSandbox)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(partial, forKey: .partial)
        try c.encodeIfPresent(cancelled, forKey: .cancelled)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encodeIfPresent(resultSummary, forKey: .resultSummary)
        try c.encodeIfPresent(ok, forKey: .ok)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encodeIfPresent(beforeContent, forKey: .beforeContent)
        try c.encodeIfPresent(afterContent, forKey: .afterContent)
        try c.encodeIfPresent(approvalId, forKey: .approvalId)
        try c.encodeIfPresent(inputJSON, forKey: .inputJSON)
        try c.encodeIfPresent(attachments, forKey: .attachments)
        // Must survive Mac-side re-encoding and snapshot emission. The current
        // iOS receiver intentionally ignores this additive field (658.14 adds
        // no phone badge), but the Mac encoder must not silently erase it.
        try c.encodeIfPresent(origin, forKey: .origin)
    }
}

/// Per-message persisted attachment summary (no bytes — bytes live elsewhere).
/// Mirrors the dict that `ChatOrchestrationClient.appendMessage` writes into
/// `metadata.attachments` in `chat/messages/<sid>.jsonl`. Encoded on the Mac
/// `ChatMessage.metadata`, snapshotted into iCloud `chat_transcripts.json`,
/// and decoded by iOS into `ChatMessageRecord.metadata.attachments`.
struct PersistedAttachment: Codable, Hashable {
    var id: String
    var type: String
    var mime: String
    var name: String?
    var byteSize: Int64
    var path: String?

    init(id: String, type: String, mime: String, name: String?, byteSize: Int64, path: String? = nil) {
        self.id = id; self.type = type; self.mime = mime; self.name = name; self.byteSize = byteSize; self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "file"
        mime = try c.decodeIfPresent(String.self, forKey: .mime) ?? "application/octet-stream"
        name = try c.decodeIfPresent(String.self, forKey: .name)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        if let n = try? c.decode(Int64.self, forKey: .byteSize) { byteSize = n }
        else if let n = try? c.decode(Int.self, forKey: .byteSize) { byteSize = Int64(n) }
        else { byteSize = 0 }
    }
    enum CodingKeys: String, CodingKey { case id, type, mime, name, byteSize, path }
}

/// Wraps Any-typed JSON values so ChatMessageMetadata can stay Codable.
struct AnyDecodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)   { value = v; return }
        if let v = try? c.decode(Int.self)    { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        value = ""
    }
}

// ChatSession, RuntimeHealth, RunRecord, MemoryRecord moved to NativeAgentShared.


/// Decoded twin of the `metadata.origin` object written by
/// ChatOrchestrationClient.appendMessage. Deliberately dumb: it carries the
/// raw recorded strings and makes no display decisions. All allowlisting and
/// sanitizing happens in MacChatMessageProvenance, at the render boundary.
struct ChatMessageOriginMetadata: Codable, Hashable {
    var surface: String?
    var agent: String?
}
