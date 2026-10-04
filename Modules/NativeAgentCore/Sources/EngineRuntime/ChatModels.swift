import DeviceSync
import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import ChatOrchestration

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var sessionId: String? = nil
    // FIX: safe defaults so one message missing role/content doesn't fail the
    // whole transcript read and blank the primary chat surface.
    public var role: String = "assistant"
    public var content: String = ""
    public var createdAt: String = ISO8601DateFormatter().string(from: Date())
    public var runId: String? = nil
    public var source: String? = nil
    public var metadata: ChatMessageMetadata? = nil

    public init(
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

    /// One transcript row, read straight from its parsed object (the
    /// transcript reader's `extras`). A message missing role/content/createdAt
    /// must not fail the transcript and blank the chat surface, and a malformed
    /// advisory sibling must not discard a valid metadata.origin trust signal:
    /// each field degrades independently to its default.
    public init(row o: [String: JSONValue]) {
        self.id = chatRowString(o["id"]) ?? UUID().uuidString
        self.sessionId = chatRowString(o["sessionId"])
        self.content = chatRowString(o["content"]) ?? ""
        self.createdAt = chatRowString(o["createdAt"])
            ?? ISO8601DateFormatter().string(from: Date())
        self.runId = chatRowString(o["runId"])
        self.source = chatRowString(o["source"])

        // Missing/null metadata is the normal historical shape. A PRESENT
        // value of the wrong JSON type is different: silently turning it
        // into nil would make a user/source=app row look human even though its
        // provenance envelope was unreadable. Preserve that distinction with
        // the same closed, non-rendered sentinel used for malformed `origin`.
        switch o["metadata"] {
        case nil, .null?:
            self.metadata = nil
        case .object(let fields)?:
            self.metadata = ChatMessageMetadata(fields: fields)
        default:
            var unreadable = ChatMessageMetadata()
            unreadable.origin = ChatMessageOriginMetadata(surface: "unreadable")
            self.metadata = unreadable
        }

        let decodedRole = chatRowString(o["role"])
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

    /// The same row contract for a Codable container (the phone snapshot's
    /// own type is Codable). Encodable stays synthesized.
    public init(from decoder: Decoder) throws {
        guard case .object(let o) = try JSONValue(from: decoder) else {
            throw DecodingError.typeMismatch(
                ChatMessage.self,
                .init(codingPath: decoder.codingPath, debugDescription: "A chat message is a JSON object.")
            )
        }
        self.init(row: o)
    }
}

public typealias NativeAppChatMessage = ChatMessage

public struct ChatMessageMetadata: Encodable, Hashable, Sendable {
    /// Shared transcript vocabulary for an approval awaiting a human decision.
    /// Producers must mint this value and transcript grouping/rendering must
    /// consume it through `isPendingApproval`; a literal drift must never hide
    /// an actionable card behind a collapsed tool summary.
    public static let approvalPendingKind = ChatTranscriptToolMessageKind.approvalPending

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
    // Truncated-turn markers — written by persistPartialIfNeeded when a turn
    // fails or is cancelled mid-stream. Decoded so the UI can distinguish a
    // partial/cancelled row from a completed reply; otherwise a persisted
    // partial counts as "assistant landed" and suppresses the failure bubble
    // (audit finding #2, 2026-06-14).
    public var partial: Bool? = nil
    public var cancelled: Bool? = nil
    /// Exact engine outcome of a persisted assistant turn.
    public var completionState: String?
    // PATCH-2026-05-08: wave2-chat-ux Tool-use pill metadata (role=tool messages)
    public var kind: String?          // "tool_use" | `approvalPendingKind`
    public var toolName: String?      // e.g. "read_file"
    // Input dict serialized as JSON string for Codable simplicity
    public var inputJSON: String?
    public var resultSummary: String?
    /// The row's own settled state ("pending", "superseded", "declined", …),
    /// written beside the receipt by the same locked write. Read by the tool
    /// fold, which trusts it over the envelope when both are present.
    public var resultStatus: String?
    /// The state of the row's own `metadata.interaction`, lifted out at decode
    /// time. Decode-only: `interaction` itself has never round-tripped through
    /// this model, and re-encoding a lifted copy would put a second, divergent
    /// answer on the wire.
    ///
    /// It is what classifies a row written BEFORE `result_status` existed.
    /// Superseding rewrote the interaction on those rows but not the receipt,
    /// so they still carry a stale `needs_input` envelope and counted as open
    /// forever.
    public var interactionState: String?
    public var ok: Bool?
    public var durationMs: Int?
    // write_file diff support
    public var beforeContent: String?
    public var afterContent: String?
    // approval_pending
    public var approvalId: String?

    public var isPendingApproval: Bool {
        kind == Self.approvalPendingKind
    }
    /// Decode-only: a mirror of a card raised in another conversation
    /// (`ApprovalChatCards.interactionMirrorKind`) — where the original is.
    public var mirrorInteractionId: String?
    public var mirrorInteractionSessionId: String?
    public var interactionMirror: (sessionID: String, interactionID: String)? {
        guard kind == "interaction_mirror", let mirrorInteractionId, let mirrorInteractionSessionId
        else { return nil }
        return (mirrorInteractionSessionId, mirrorInteractionId)
    }
    // eval3/T3: attachments persisted under metadata.attachments by
    // ChatOrchestrationClient.appendMessage (NativeAgentCore). Round-tripped
    // here so the transcript read → MacSyncEngine snapshot → iOS refreshChatHistory
    // preserves attachments instead of dropping them at the snapshot edge.
    public var attachments: [PersistedAttachment]?
    /// 658.14 session provenance. Present on user rows that did NOT originate
    /// from the human at this Mac (bridge wakes and automated injections).
    /// Absent means "no claim recorded", never "trusted human" — see
    /// MacChatMessageProvenance for how absence is rendered.
    public var origin: ChatMessageOriginMetadata?
    // 2026-09-28: Decode-only surface/agent projection of the recorded turn envelope for presentation.
    public var envelope: ChatMessageOriginMetadata?
    /// How many LEADING characters of this assistant row are the working
    /// commentary the model spoke between tool rounds, rather than its answer.
    /// Written by the engine; the settled bubble folds that prefix away instead
    /// of leaving "I'll check… now I'll read… here's what I found" as one
    /// permanent answer. Absent on single-round turns and on every user row.
    public var workingCommentaryChars: Int?
    /// Opaque identity of the turn that produced this assistant row.
    public var turnTraceId: String?
    /// The engine's `mechanicalKind` stamp. Decode-only: `systemRow` marks a
    /// persisted turn-failure notice, which is not a reply.
    public var mechanicalKind: String?

    // Custom CodingKeys to map camelCase Swift properties → snake_case daemon keys
    enum CodingKeys: String, CodingKey {
        case model, requestedModel, reasoningEffort, fileAccessMode, codexSandbox, error, partial, cancelled, completionState
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

    /// Empty metadata. Declaring `init(from:)` in the body suppresses the
    /// synthesized memberwise init, so callers that need to stamp a single
    /// field (the synthetic-error bubbles below) had no way to build one.
    public init() {}

    /// Metadata for an in-memory synthetic failure bubble. `error` is the field
    /// `messageNeedsRetry` (ChatMessageListView) reads, so stamping it is what
    /// makes the "Try again" affordance the bubble's own copy names actually
    /// render (sweep R4 C7). `userRowPersisted` records whether the ORIGINAL
    /// turn wrote the user's message to the transcript before failing — the
    /// no-provider guard bails out before client.chat ever runs, so retrying
    /// that bubble with suppressUserAppend would lose the user's message from
    /// the persisted thread (gpt-5.5 review 2026-08-06, blocking). In-memory
    /// only: deliberately NOT in CodingKeys, so it never touches the wire.
    public static func syntheticError(
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
    public var syntheticUserRowPersisted: Bool?
    /// Payload-free retry guard for a synthetic failure whose optimistic user
    /// row never reached canonical persistence. Attachment bytes are never
    /// retained here; this records only that text-only regeneration is unsafe.
    public var syntheticInputHadAttachments: Bool?

    private static func _capString(_ s: String?, _ limit: Int) -> String? {
        guard let s, s.count > limit else { return s }
        return String(s.prefix(limit)) + "\n…(truncated)"
    }

    /// The row's `metadata` object. Metadata is display/advisory data: one
    /// wrong-typed sibling reads as absent and never discards the whole message
    /// (and with it a valid authority-bearing origin object). Streamed and
    /// persisted rows spell some keys in camelCase, the daemon in snake_case;
    /// the snake_case spelling wins.
    /// PATCH-2026-05-08: review-fix-B Cap big strings at read time so a tool
    /// returning a 500KB blob doesn't blow up SwiftUI rendering or memory.
    public init(fields o: [String: JSONValue]) {
        model = chatRowString(o["model"])
        turnTraceId = chatRowString(o["turnTraceId"])
        requestedModel = chatRowString(o["requestedModel"])
        reasoningEffort = chatRowString(o["reasoningEffort"])
        fileAccessMode = chatRowString(o["fileAccessMode"])
        codexSandbox = chatRowString(o["codexSandbox"])
        error = chatRowString(o["error"])
        providerRefusal = chatRowBool(o["provider_refusal"])
        providerRefusalDraft = chatRowBool(o["provider_refusal_draft"])
        partial = chatRowBool(o["partial"])
        cancelled = chatRowBool(o["cancelled"])
        completionState = chatRowString(o["completionState"])
        kind = chatRowString(o["kind"])
        toolName = chatRowString(o["tool_name"]) ?? chatRowString(o["toolName"])
        resultSummary = Self._capString(
            chatRowString(o["result_summary"]) ?? chatRowString(o["resultSummary"]),
            4_000
        )
        resultStatus = chatRowString(o["result_status"]) ?? chatRowString(o["resultStatus"])
        // Just the interaction's state name: the one field every build has
        // written since v1, so a shape this build does not understand still
        // yields it.
        if case .object(let interaction)? = o["interaction"],
           case .object(let state)? = interaction["state"] {
            switch state["name"] {
            case .string(let name)?: interactionState = name
            default: interactionState = nil
            }
        } else {
            interactionState = nil
        }
        ok = chatRowBool(o["ok"])
        durationMs = chatRowInt(o["duration_ms"])
        beforeContent = Self._capString(chatRowString(o["before_content"]), 16_000)
        afterContent = Self._capString(chatRowString(o["after_content"]), 16_000)
        approvalId = chatRowString(o["approval_id"]) ?? chatRowString(o["approvalId"])
        mirrorInteractionId = chatRowString(o["interactionId"])
        mirrorInteractionSessionId = chatRowString(o["interactionSessionId"])
        attachments = PersistedAttachment.list(o["attachments"])
        if case .object(let fields)? = o["envelope"] {
            envelope = ChatMessageOriginMetadata(fields: fields)
        }
        // 658.14: this read is the whole badge. It degrades in the honest
        // direction: a PRESENT but unreadable origin (null included) becomes
        // an unrecognized one, which MacChatMessageProvenance renders as
        // "Automated" — no blanking, and never a false human. Absent stays
        // absent.
        switch o["origin"] {
        case nil:
            origin = nil
        case .object(let fields)?:
            origin = ChatMessageOriginMetadata(fields: fields)
                ?? ChatMessageOriginMetadata(surface: "unreadable")
        default:
            origin = ChatMessageOriginMetadata(surface: "unreadable")
        }
        workingCommentaryChars = chatRowInt(o["workingCommentaryChars"])
        mechanicalKind = chatRowString(o["mechanicalKind"])
        // A legacy `input` object is shown as its JSON text; otherwise the
        // text the writer stored.
        if case .object(let rawInput)? = o["input"] {
            var dict: [String: Any] = [:]
            for key in rawInput.keys.sorted() {
                dict[key] = Self.displayValue(rawInput[key]!)
            }
            let json = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) }
            inputJSON = Self._capString(json, 4_000)
        } else {
            inputJSON = Self._capString(
                chatRowString(o["input"]) ?? chatRowString(o["inputJSON"]),
                4_000
            )
        }
    }

    /// A legacy input value as display JSON: scalars keep their type (an
    /// integral number reads as an integer); nested values read as "".
    private static func displayValue(_ value: JSONValue) -> Any {
        switch value {
        case .bool(let b): return b
        case .int(let n): return Int(n)
        case .double(let d): return Int(exactly: d).map { $0 as Any } ?? d
        case .string(let s): return s
        case .null, .array, .object: return ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(turnTraceId, forKey: .turnTraceId)
        try c.encodeIfPresent(requestedModel, forKey: .requestedModel)
        try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try c.encodeIfPresent(fileAccessMode, forKey: .fileAccessMode)
        try c.encodeIfPresent(codexSandbox, forKey: .codexSandbox)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(providerRefusal, forKey: .providerRefusal)
        try c.encodeIfPresent(providerRefusalDraft, forKey: .providerRefusalDraft)
        try c.encodeIfPresent(partial, forKey: .partial)
        try c.encodeIfPresent(cancelled, forKey: .cancelled)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encodeIfPresent(resultSummary, forKey: .resultSummary)
        try c.encodeIfPresent(resultStatus, forKey: .resultStatus)
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
        try c.encodeIfPresent(workingCommentaryChars, forKey: .workingCommentaryChars)
    }
}

/// Per-message persisted attachment summary (no bytes — bytes live elsewhere).
/// Mirrors the dict that `ChatOrchestrationClient.appendMessage` writes into
/// `metadata.attachments` in `chat/messages/<sid>.jsonl`. Encoded on the Mac
/// `ChatMessage.metadata`, snapshotted into iCloud `chat_transcripts.json`,
/// and decoded by iOS into `ChatMessageRecord.metadata.attachments`.
public struct PersistedAttachment: Encodable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var mime: String
    public var name: String?
    public var byteSize: Int64
    public var path: String?

    public init(id: String, type: String, mime: String, name: String?, byteSize: Int64, path: String? = nil) {
        self.id = id; self.type = type; self.mime = mime; self.name = name; self.byteSize = byteSize; self.path = path
    }

    /// One `metadata.attachments` element. A non-object, or a string field
    /// holding another type, is unreadable; a missing or non-integral
    /// byteSize reads as 0.
    public init?(value: JSONValue) {
        guard case .object(let o) = value else { return nil }
        func field(_ key: String) -> String?? {
            switch o[key] {
            case nil, .null?: return .some(nil)
            case .string(let s)?: return .some(s)
            default: return nil
            }
        }
        guard let id = field("id"), let type = field("type"), let mime = field("mime"),
              let name = field("name"), let path = field("path") else { return nil }
        self.id = id ?? UUID().uuidString
        self.type = type ?? "file"
        self.mime = mime ?? "application/octet-stream"
        self.name = name
        self.path = path
        switch o["byteSize"] {
        case .int(let n)?: byteSize = n
        case .double(let d)?: byteSize = Int64(exactly: d) ?? 0
        default: byteSize = 0
        }
    }

    /// Every element, or nil when the value is not an array or any element is
    /// unreadable.
    public static func list(_ value: JSONValue?) -> [PersistedAttachment]? {
        guard case .array(let elements)? = value else { return nil }
        var out: [PersistedAttachment] = []
        for element in elements {
            guard let attachment = PersistedAttachment(value: element) else { return nil }
            out.append(attachment)
        }
        return out
    }
    enum CodingKeys: String, CodingKey { case id, type, mime, name, byteSize, path }
}

// ChatSession, RuntimeHealth, RunRecord, MemoryRecord moved to NativeAgentShared.

/// Decoded twin of the `metadata.origin` object written by
/// ChatOrchestrationClient.appendMessage. Deliberately dumb: it carries the
/// raw recorded strings and makes no display decisions. All allowlisting and
/// sanitizing happens in MacChatMessageProvenance, at the render boundary.
public struct ChatMessageOriginMetadata: Encodable, Hashable, Sendable {
    public var surface: String?
    public var agent: String?
    public var authored: String?
    public var peerSources: [String]?
    public var elevatedPeerSources: [String]?

    public init(surface: String? = nil, agent: String? = nil) {
        self.surface = surface
        self.agent = agent
    }

    /// The recorded strings, or nil when either is present with another type.
    public init?(fields o: [String: JSONValue]) {
        for key in ["surface", "agent"] {
            switch o[key] {
            case nil, .null?, .string?: continue
            default: return nil
            }
        }
        surface = chatRowString(o["surface"])
        agent = chatRowString(o["agent"])
        authored = chatRowString(o["authored"])
        if case .array(let values)? = o["peerSources"] {
            peerSources = values.compactMap { chatRowString($0) }
        }
        if case .array(let values)? = o["elevatedPeerSources"] {
            elevatedPeerSources = values.compactMap { chatRowString($0) }
        }
    }
}

// MARK: - Transcript row fields

/// A string field; any other JSON type reads as absent.
private func chatRowString(_ value: JSONValue?) -> String? {
    if case .string(let s)? = value { return s }
    return nil
}

private func chatRowBool(_ value: JSONValue?) -> Bool? {
    if case .bool(let b)? = value { return b }
    return nil
}

/// An integer field; an integral JSON float reads as its integer.
private func chatRowInt(_ value: JSONValue?) -> Int? {
    switch value {
    case .int(let n)?: return Int(exactly: n)
    case .double(let d)?: return Int(exactly: d)
    default: return nil
    }
}

extension ChatMessage: DeviceSyncTranscriptMessage {}

extension ChatMessage: MacChatRetryMessage {
    public var retryOrigin: ChatMessageOrigin? {
        guard let recorded = metadata?.origin else { return nil }
        var origin = ChatMessageOrigin(surface: recorded.surface ?? "unreadable", agent: recorded.agent,
            authored: recorded.authored.flatMap(ChatMessageAuthorship.init(rawValue:))
                ?? (recorded.agent == nil ? nil : .agent))
        origin.peerSources = recorded.peerSources
        origin.elevatedPeerSources = recorded.elevatedPeerSources
        if origin.peerSources == nil, origin.authored == .agent, recorded.agent != "self" {
            origin.peerSources = [recorded.agent ?? "an agent"]
        }
        return origin
    }
    public var retryHasAttachments: Bool { metadata?.attachments?.isEmpty == false }
    public var retryUserRowPersisted: Bool? { metadata?.syntheticUserRowPersisted }
    public var retryInputHadAttachments: Bool? { metadata?.syntheticInputHadAttachments }
}

extension ChatMessage: FirstRunWelcomeMessage {
    public var firstRunMechanicalKind: String? { metadata?.mechanicalKind }
    public var firstRunTurnCompleted: Bool {
        metadata?.completionState == "completed"
            && metadata?.partial != true && metadata?.cancelled != true
    }
}
