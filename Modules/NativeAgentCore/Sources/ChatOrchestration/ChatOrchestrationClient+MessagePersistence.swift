import Foundation
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate

/// Wire vocabulary for tool receipts that have a special transcript
/// presentation. The writer classifies a non-blocking approval result here;
/// app surfaces consume these exact values rather than independently guessing
/// from a result-summary string.
public enum ChatTranscriptToolMessageKind {
    public static let toolUse = "tool_use"
    public static let approvalPending = "approval_pending"

    /// Returns an approval identifier only for the canonical result emitted by
    /// `NonBlockingApprovalFiler`. A malformed result, a differently named
    /// status, or an empty identifier remains an ordinary tool receipt: it
    /// must not surface an actionable approval card without an authority.
    public static func pendingApprovalID(in resultSummary: String) -> String? {
        guard let value = try? JSONValue.parse(Data(resultSummary.utf8)) else { return nil }
        return pendingApprovalID(in: value)
    }

    static func pendingApprovalID(in value: JSONValue) -> String? {
        guard case .object(let object) = value,
              case .string("waiting_approval")? = object["status"],
              case .string(let rawID)? = object["approvalId"] ?? object["approval_id"]
        else { return nil }

        let approvalID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return approvalID.isEmpty ? nil : approvalID
    }
}

/// Process-wide, stat-validated line count for chat transcript JSONL files.
///
/// The session index needs one number per persisted message: how many rows the
/// transcript now holds. Deriving it by reading every byte of the file is
/// correct but costs O(session bytes) per append and gets slower every day the
/// session lives. Writers in THIS process know the delta exactly (+1 per
/// appended row), so the count is carried forward instead of rediscovered.
///
/// The safety property is that a cached count is only ever served for a file
/// that is byte-for-byte the one it was measured against: every entry carries
/// the `(device, inode, size, mtime)` stamp observed at record time, and any
/// mismatch — an external writer, a compaction rewrite, a truncation, a
/// deletion, a restore — falls back to a full recount. A stale cache cannot be
/// served; the worst case is that it is discarded and we pay what we used to.
///
/// Correctness of the count itself relies on callers doing their read/append/
/// record under the transcript's cross-process `flock`, which they do.
final class ChatTranscriptLineCountCache: @unchecked Sendable {
    /// Identity + content stamp. Any field changing means "not the same bytes".
    struct Stamp: Equatable, Sendable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
    }

    private struct Entry {
        var stamp: Stamp
        var count: Int
    }

    static let shared = ChatTranscriptLineCountCache()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var fullRecounts: [String: Int] = [:]

    /// Current line count for `path`, recomputing only when the file on disk is
    /// not the one this cache last measured.
    func count(at path: URL, recount: (URL) -> Int) -> Int {
        let key = path.path
        let before = Self.stamp(of: path)
        if let before {
            lock.lock()
            let cached = entries[key]
            lock.unlock()
            if let cached, cached.stamp == before {
                return cached.count
            }
        }
        let counted = recount(path)
        lock.lock()
        fullRecounts[key, default: 0] += 1
        // Only cache when the file did not move under the read. If it did, the
        // pairing of (count, stamp) would be a lie — drop it and let the next
        // caller recount.
        if let before, let after = Self.stamp(of: path), before == after {
            entries[key] = Entry(stamp: after, count: counted)
        } else {
            entries[key] = nil
        }
        lock.unlock()
        return counted
    }

    /// Record a count the caller established authoritatively (it just wrote the
    /// file under the lock). Returns the same count for call-site chaining.
    @discardableResult
    func record(count: Int, at path: URL) -> Int {
        let key = path.path
        lock.lock()
        if let stamp = Self.stamp(of: path) {
            entries[key] = Entry(stamp: stamp, count: count)
        } else {
            entries[key] = nil
        }
        lock.unlock()
        return count
    }

    func invalidate(at path: URL) {
        lock.lock()
        entries[path.path] = nil
        lock.unlock()
    }

    /// Test/diagnostic probe: how many full byte scans this cache has paid for
    /// `path`. A cache that is working keeps this at 1 for a hot session.
    func fullRecountCount(at path: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return fullRecounts[path.path] ?? 0
    }

    func resetForTesting() {
        lock.lock()
        entries.removeAll()
        fullRecounts.removeAll()
        lock.unlock()
    }

    private static func stamp(of path: URL) -> Stamp? {
        var info = stat()
        guard stat(path.path, &info) == 0 else { return nil }
        return Stamp(
            device: info.st_dev,
            inode: info.st_ino,
            size: Int64(info.st_size),
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}

/// Request-scoped transcript intent. Regenerate/retry callers provide the
/// assistant row they mean to replace without widening every provider/tool-loop
/// protocol. Only the final successful assistant append opts into consuming it;
/// user rows, partial recovery rows, and persisted failures remain append-only.
public enum ChatPersistenceContext {
    @TaskLocal public static var replacementAssistantMessageID: String?
    @TaskLocal public static var codexCompletionBinding: CodexCompletionTranscriptBinding?
    /// Ack-on-enqueue (2026-07-25): the runId `enqueueUserMessage` stamped on
    /// the pre-appended user row. A turn that runs with
    /// `suppressUserAppend: true` adopts this as ITS runId, so the history
    /// builder's `excludeHistoryRunId` drops the pre-appended row exactly as
    /// it drops the normal path's own append — without it the current message
    /// enters the prompt twice (once from history, once as the live turn).
    /// Honored ONLY on suppressed-append turns: a nested full-chat dispatch
    /// inside the same task tree uses suppressUserAppend:false and must mint
    /// its own runId rather than inherit this one.
    @TaskLocal public static var pinnedTurnRunID: String?
    /// Session provenance (658.14): the ORIGIN of an inbound message, on its
    /// own channel. Deliberately NOT the `surface` parameter — `surface` is
    /// also the tool-authorization surface (the claude/codex bridges run with
    /// `surface: "chat"` on purpose, per User's 2026-06-13 call that the bridge
    /// gets the same tool surface as chat), so retagging it to carry origin
    /// would silently change what the bridge is allowed to do. Stamped onto
    /// the USER row's metadata only; assistant rows are always hers.
    @TaskLocal public static var originProvenance: ChatMessageOrigin?
}

/// Where an inbound chat message actually came from, recorded out-of-band so a
/// reader does not have to trust an in-band `[from: ...]` prefix that both the
/// human and the untrusted payload can type verbatim.
public struct ChatMessageOrigin: Sendable, Equatable, Codable {
    /// Transport the message arrived on, e.g. "claude-bridge", "codex-bridge".
    public let surface: String
    /// Server-selected bridge lane, e.g. "claude", "codex". This records the
    /// authenticated request route; the bridge's shared bearer does not provide
    /// a separate cryptographic attestation of the calling process. Nil when
    /// the lane is unattributed.
    public let agent: String?
    /// Item 8 (2026-09-02). The lane's own statement that the AGENT composed
    /// this text, rather than the bridge carrying the human's words through it.
    ///
    /// `surface` and `agent` describe the ROUTE, and a route cannot answer the
    /// question the affect layer has to ask. Claude relaying "User says: ship
    /// it" arrives on the same surface, from the same agent, as Claude saying
    /// something herself — and only one of those is another person moving her.
    /// Nil means unstated, which is read as the human: the honest default when
    /// nobody has claimed authorship, and the same direction the render
    /// allowlist fails in.
    ///
    /// Set ONLY by a lane that knows it is transcribing its own agent's output.
    /// A future forwarding lane must leave it nil.
    public let authored: ChatMessageAuthorship?

    public init(
        surface: String,
        agent: String? = nil,
        authored: ChatMessageAuthorship? = nil
    ) {
        self.surface = surface
        self.agent = agent
        self.authored = authored
    }
}

/// Who composed the text on an out-of-band-origin row. Deliberately a closed
/// two-case enum rather than a free string: this is a trust input, and the one
/// value that grants anything (`agent`) must not be spellable by accident.
public enum ChatMessageAuthorship: String, Sendable, Equatable, Codable {
    /// The agent named by `origin.agent` wrote these words itself.
    case agent
    /// The lane carried a human's words. Same route, different speaker.
    case human
}

/// Request-scoped identity stamped on the canonical assistant row before the
/// bridge receives its `ChatResponse`. It lets the existing completion owner
/// recover a response after a crash between transcript append and lifecycle
/// cache commit without starting Agent a second time.
public struct CodexCompletionTranscriptBinding: Sendable, Equatable {
    public let deliveryId: String
    public let requestDigest: String
    public let model: String
    public let reasoningEffort: String?

    public init(
        deliveryId: String,
        requestDigest: String,
        model: String,
        reasoningEffort: String?
    ) {
        self.deliveryId = deliveryId
        self.requestDigest = requestDigest
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public enum CodexCompletionTranscriptEvidence {
    public enum RecoveryError: Error, Equatable {
        case corruptBinding
        case ambiguousBinding
    }

    public static func responseDigest(
        sessionId: String,
        runId: String,
        content: String,
        attachments: [MultimodalAttachment]
    ) -> String {
        let attachmentRows: [JSONValue] = attachments.map { attachment in
            var row: [String: JSONValue] = [
                "id": .string(attachment.id),
                "type": .string(attachment.type),
                "mime": .string(attachment.mime),
                "name": .string(attachment.name ?? ""),
                "byteSize": .int(Int64(attachment.byteSize)),
            ]
            if let path = attachment.path, !path.isEmpty { row["path"] = .string(path) }
            return .object(row)
        }
        let payload: JSONValue = .object([
            "attachments": .array(attachmentRows),
            "content": .string(content),
            "runId": .string(runId),
            "sessionId": .string(sessionId),
        ])
        let bytes = (try? payload.serializedData(pretty: false)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func recoverResponse(
        from rows: [JSONValue],
        deliveryId: String,
        requestDigest: String,
        sessionId: String
    ) throws -> ChatResponse? {
        var matches: [ChatResponse] = []
        for row in rows {
            guard case .object(let object) = row,
                  case .string(let role)? = object["role"], role == "assistant",
                  case .string(let rowSession)? = object["sessionId"], rowSession == sessionId,
                  case .string(let content)? = object["content"],
                  case .string(let runId)? = object["runId"],
                  case .object(let metadata)? = object["metadata"],
                  case .object(let binding)? = metadata["codexCompletion"],
                  case .string(let rowDelivery)? = binding["deliveryId"],
                  rowDelivery == deliveryId,
                  case .string(let rowRequestDigest)? = binding["requestDigest"],
                  rowRequestDigest == requestDigest,
                  case .string(let model)? = binding["model"],
                  case .string(let storedResponseDigest)? = binding["responseDigest"]
            else { continue }
            let attachments = try decodeAttachments(metadata["attachments"])
            guard responseDigest(
                sessionId: sessionId,
                runId: runId,
                content: content,
                attachments: attachments
            ) == storedResponseDigest else {
                throw RecoveryError.corruptBinding
            }
            let effort: String?
            if case .string(let value)? = binding["reasoningEffort"] { effort = value }
            else { effort = nil }
            matches.append(ChatResponse(
                runId: runId,
                model: model,
                reasoningEffort: effort,
                output: content,
                sessionId: sessionId,
                attachments: attachments.isEmpty ? nil : attachments
            ))
        }
        guard matches.count <= 1 else { throw RecoveryError.ambiguousBinding }
        return matches.first
    }

    private static func decodeAttachments(_ value: JSONValue?) throws -> [MultimodalAttachment] {
        guard let value else { return [] }
        guard case .array(let rows) = value else { throw RecoveryError.corruptBinding }
        return try rows.map { row in
            guard case .object(let object) = row,
                  case .string(let id)? = object["id"],
                  case .string(let type)? = object["type"],
                  case .string(let mime)? = object["mime"],
                  case .string(let name)? = object["name"],
                  case .int(let byteSize)? = object["byteSize"],
                  byteSize >= 0, byteSize <= Int64(Int.max)
            else { throw RecoveryError.corruptBinding }
            let path: String?
            if case .string(let value)? = object["path"], !value.isEmpty { path = value }
            else { path = nil }
            return MultimodalAttachment(
                id: id,
                type: type,
                base64: "",
                mime: mime,
                name: name.isEmpty ? nil : name,
                byteSize: Int(byteSize),
                path: path
            )
        }
    }
}

extension SwiftNativeChatOrchestrationClient {
    /// Tool results are live-turn data, not durable context. Persist only a
    /// bounded, redacted receipt so tool_catalog/read_file/bash outputs cannot
    /// inflate every future transcript read. The full value remains available
    /// to the provider during the tool loop that produced it.
    private static let persistedToolInputMaximumCharacters = 4_000
    private static let persistedToolResultMaximumCharacters = 8_000

    /// Fail-loud reporter for transcript-write failures (M1/M2, honesty sweep
    /// 2026-07-09). A dropped transcript write is exactly the silent loss these
    /// writes exist to prevent, so it must never be swallowed: it is always
    /// NSLogged, and it is surfaced to the user through the turn-notice channel
    /// — `onNotice` when the caller holds the live stream continuation, else the
    /// `ToolNoticeBus` task-local the tool loop binds. When neither is available
    /// (background loops, tests) the log is the receipt.
    static func reportTranscriptWriteFailure(
        label: String,
        path: URL,
        error: Error,
        userText: String,
        onNotice: (@Sendable (String, String) async -> Void)?
    ) async {
        NSLog("%@: transcript write FAILED for %@: %@",
              label, path.lastPathComponent, String(describing: error))
        let emit = onNotice ?? ToolNoticeBus.emit
        await emit?("transcript_write_failed", userText)
    }

    /// Persist a partial assistant reply with a `cancelled: true` marker on the
    /// record's metadata so downstream readers can distinguish completed turns
    /// from truncated ones.
    ///
    /// M1 (2026-07-09): this write is the partial-reply RESCUE — a `try?` here
    /// meant the one write whose entire purpose is to stop silent loss could
    /// itself lose silently. Failure now logs and raises a turn notice.
    func persistPartialIfNeeded(
        sessionId: String,
        runId: String,
        text: String,
        cancelled: Bool,
        source: String = "app",
        outcomeContext: TurnContext? = nil,
        outcomeInterventionAssignment: CausalInterventionAssignment? = nil,
        onNotice: @escaping @Sendable (String, String) async -> Void
    ) async {
        guard !text.isEmpty else { return }
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { return }
        let messageSource = Self.messageSource(for: source)
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let persistedAt = clock()
        let createdAt = Self.iso8601(persistedAt)
        let messageId = UUID().uuidString
        let outcomeObservation = ResponseOutcomeObservationV2.make(
            turnID: TurnTraceContext.turnId ?? runId,
            messageID: messageId,
            sessionID: sessionId,
            surface: messageSource,
            observedAt: persistedAt,
            responsePersistence: cancelled ? "cancelled" : "partial",
            context: outcomeContext,
            interventionAssignment: outcomeInterventionAssignment
        )
        var partialMetadata: [String: JSONValue] = [
            "cancelled": .bool(cancelled),
            "partial": .bool(true),
        ]
        if let outcomeObservation {
            partialMetadata["outcomeObservation"] = outcomeObservation.jsonValue
            partialMetadata["turnTraceId"] = .string(outcomeObservation.turnID)
        }
        let record: JSONValue = .object([
            "id": .string(messageId),
            "sessionId": .string(sessionId),
            "role": .string("assistant"),
            "content": .string(text),
            "createdAt": .string(createdAt),
            "source": .string(messageSource),
            "runId": .string(runId),
            "cancelled": .bool(cancelled),
            "metadata": .object(partialMetadata),
        ])
        // Under the transcript's sidecar lock: compaction + the async distiller
        // do locked read-modify-rewrite of this file; an unlocked append racing
        // that rewrite would be silently dropped by the atomic rename.
        do {
            try await persistence.withFileLock(path) {
                // FAST PATH, deliberately (sweep R4 item 4). This row is a
                // STREAMING PARTIAL: superseded by the terminal assistant row
                // the moment the turn finishes, and written often enough that a
                // per-row F_FULLFSYNC would be felt on every turn. Losing the
                // newest partial to a power cut costs a fragment of a reply
                // that never committed; losing a user row or a tool receipt
                // costs a turn that did. Those go durable — see appendMessage
                // and appendToolMessage below.
                try await persistence.appendJSONL(record, to: path)
            }
        } catch {
            await Self.reportTranscriptWriteFailure(
                label: "persistPartialIfNeeded",
                path: path,
                error: error,
                userText: "Couldn't save this turn's partial reply - it may be missing when the conversation reloads.",
                onNotice: onNotice
            )
            return
        }
    }

    /// Persist a role="tool" message capturing one tool dispatch (name,
    /// inputJSON, resultSummary, ok) in the daemon's per-line JSON shape so
    /// getChatMessages can render it as a tool pill in the Mac UI.
    func appendToolMessage(
        sessionId: String,
        runId: String?,
        toolName: String,
        inputJSON: String,
        resultSummary: String,
        ok: Bool,
        cognitiveResult: ChatToolOutcome.CognitiveResult? = nil,
        source: String = "app"
    ) async throws {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        let messageSource = Self.messageSource(for: source)
        // W2/W3-FIX-R2 2/3 — this row is PERSISTED to the transcript and read
        // back by every surface (Mac, iOS, Telegram, bridge). For an injection
        // tool `inputJSON` is the literal characters about to be typed and
        // `resultSummary` can echo the value an `ax_act` wrote;
        // `boundedRedactedToolReceipt` only catches secret-SHAPED strings, and
        // a password is not shaped like anything. Redact by TOOL first.
        // Approval detection already requires the original envelope. Share that
        // one parse with the exact outcome tag before rendering a bounded body.
        let originalResult = try? JSONValue.parse(Data(resultSummary.utf8))
        let safeInputJSON = Self.boundedRedactedToolReceipt(
            Self.injectionRedactedArgJSON(tool: toolName, json: inputJSON),
            maximumCharacters: Self.persistedToolInputMaximumCharacters,
            label: "tool input"
        )
        // W3.5-FIX 3 — and for `mac_view` the RESULT is a base64 screenshot of
        // the whole window. The persisted transcript is read back by every
        // surface and syncs; the pixels come out here and leave the digest.
        let safeResultSummary = Self.boundedRedactedToolReceipt(
            Self.injectionRedactedResultJSON(
                tool: toolName,
                json: Self.screenViewRedactedResultJSON(tool: toolName, json: resultSummary)
            ),
            maximumCharacters: Self.persistedToolResultMaximumCharacters,
            label: "tool result"
        )
        let canonicalRiskInput: [String: JSONValue] = {
            guard let parsed = try? JSONValue.parse(Data(inputJSON.utf8)),
                  case .object(let object) = parsed
            else { return [:] }
            return object
        }()
        let canonicalToolRisk = SwiftNativeSecurityCenter.canonicalToolRisk(
            tool: toolName,
            input: canonicalRiskInput,
            dataRoot: dataRoot
        )
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let messageId = UUID().uuidString
        let persistedAt = clock()
        let createdAt = Self.iso8601(persistedAt)
        var record: [String: JSONValue] = [
            "id": .string(messageId),
            "sessionId": .string(sessionId),
            "role": .string("tool"),
            "content": .string(""),
            "createdAt": .string(createdAt),
            "source": .string(messageSource),
        ]
        if let runId { record["runId"] = .string(runId) }
        let pendingApprovalID = originalResult.flatMap { ChatTranscriptToolMessageKind.pendingApprovalID(in: $0) }
        var metadata: [String: JSONValue] = [
            "kind": .string(
                pendingApprovalID == nil
                    ? ChatTranscriptToolMessageKind.toolUse
                    : ChatTranscriptToolMessageKind.approvalPending
            ),
            "toolName": .string(toolName),
            "inputJSON": .string(safeInputJSON),
            "resultSummary": .string(safeResultSummary),
            "ok": .bool(ok),
            // A tool receipt is the record of an EXTERNAL EFFECT, read back by
            // every surface. It gets the same durable envelope the
            // conversational rows get, so "which surface's turn caused this
            // effect, and where did that turn's reply go" survives on the row
            // rather than being re-derived later from the session's current
            // surface — a thing that stops being well-defined the moment more
            // than one surface writes a transcript.
            //
            // Streaming PARTIALS deliberately do not carry it: they are
            // superseded by the terminal assistant row within the same turn,
            // and they take the fast append precisely to stay off the hot path.
            "envelope": TurnEnvelope.current(surface: messageSource).persistedMetadata(),
        ]
        if let pendingApprovalID {
            // The post-resolution writer locates and replaces this row by the
            // same durable identifier, so the inline card never loses its
            // transition to a settled tool receipt.
            metadata["approvalId"] = .string(pendingApprovalID)
        }
        // Preserve only the existing classifier's exact outcome tag before
        // receipt clipping/redaction can remove the envelope's status. `ok`
        // remains transport success; no-status legacy results stay unchanged.
        if let result = originalResult,
           case .object(let object) = result,
           case .string(let recordedStatus)? = object["status"] {
            metadata["resultClass"] = .string(ChatToolOutcome.exactResultClass(result).rawValue)
            // The class alone cannot tell "queued" from "accepted" from
            // "running" — they all collapse to `.unknown`, which the renderer
            // then reported as "completion unconfirmed" even when the envelope
            // plainly said what state the work reached. Keep the exact word
            // beside the class so the receipt can say what is actually known.
            metadata["resultStatus"] = .string(recordedStatus)
        }
        record["metadata"] = .object(metadata)
        // Locked: see appendPartial — protects against the compactor/distiller
        // locked rewrite dropping a concurrent append. (Immutable binding: a
        // @Sendable closure cannot capture the mutable `record`.)
        let toolRow: JSONValue = .object(record)
        try await persistence.withFileLock(path) {
            // DURABLE (sweep R4 item 4). A tool receipt is the transcript's
            // only record that an EXTERNAL EFFECT happened — a file written, a
            // message sent, a command run. If a power cut drops it, the effect
            // still happened in the world but the conversation no longer says
            // so, and the next turn can redo it. That asymmetry is what buys
            // the flush; partial rows (above) have no such counterpart.
            try await persistence.appendJSONLDurable(toolRow, to: path)
        }
        await observeCognitiveTool(
            sessionId: sessionId,
            runId: runId,
            toolName: toolName,
            resultSummary: safeResultSummary,
            ok: ok,
            cognitiveResult: cognitiveResult,
            canonicalToolRisk: canonicalToolRisk,
            source: messageSource,
            createdAt: createdAt,
            messageId: messageId
        )
    }

    // MARK: helpers

    nonisolated static func redactedProgressEvent(_ event: TurnStreamEvent) -> TurnStreamEvent {
        switch event {
        case .toolUse(let name, let input):
            return .toolUse(name: name, input: ChatSecretRedactor.redactValue(input))
        case .toolResult(let name, let output):
            return .toolResult(name: name, output: ChatSecretRedactor.redactValue(output))
        case .error(let message):
            return .error(ChatSecretRedactor.redactText(message))
        default:
            return event
        }
    }

    /// Convert delivered `MultimodalAttachment`s into native `.image` content
    /// blocks. Skips non-image types (audio/file/etc.) and entries with empty
    /// base64. Returns `[]` when nothing actionable — callers stay on the
    /// pre-multimodal `.user(text)` shape (byte-identical wire body).
    nonisolated static func imageBlocksFromAttachments(
        _ attachments: [MultimodalAttachment]
    ) -> [LLMContentBlock] {
        var out: [LLMContentBlock] = []
        for a in attachments {
            let type = a.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "image" else { continue }
            guard !a.base64.isEmpty else { continue }
            out.append(.image(
                mediaType: a.mime,
                base64: a.base64,
                name: a.name,
                byteSize: a.byteSize
            ))
        }
        return out
    }

    // MARK: - Trust ▸ Multimodal, at the point of use (2026-09-06)
    //
    // "Allow vision API calls" and "Allow PDF file ingestion" round-tripped to
    // <dataRoot>/trust/policy.json and NOTHING read them: every attached image
    // reached the provider with the switch off, and no PDF ever reached it with
    // the switch on. These two readers close both halves.
    //
    // FRESH ON EVERY TURN, deliberately, the way MemoryPolicyGate reads the
    // memory switches: no launch-time snapshot, so a flip in Trust lands on the
    // next turn. The file is small and this runs once per turn.

    /// One boolean out of `multimodalPolicy`. Missing file / missing key →
    /// `fallback` (matching the shipped defaults in TrustCenter+Defaults, so
    /// the gate and the switch can never disagree about "unset"). A file that
    /// exists but cannot be read or parsed, a wrongly-typed `multimodalPolicy`
    /// block, or a non-Bool value is policy TrustCenter itself rejects — those
    /// fail CLOSED rather than quietly running the default.
    nonisolated static func multimodalPolicyAllows(
        _ key: String,
        default fallback: Bool,
        dataRoot: URL
    ) -> Bool {
        let path = dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return fallback }
        guard let data = try? Data(contentsOf: path) else { return false }
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let present = top["multimodalPolicy"]
        if present != nil, !(present is [String: Any]) { return false }
        guard let block = present as? [String: Any] else { return fallback }
        guard let raw = block[key] else { return fallback }
        guard let value = raw as? Bool else { return false }
        return value
    }

    /// Characters of extracted document text one attachment contributes to a
    /// turn. A contract is worth reading; a 400-page appendix is not worth a
    /// turn's whole context, and the note SAYS when the cut happened.
    /// 2026-09-06: one cap for PDFs and plain text — an attached .md is as
    /// capable of eating a turn's context as an attached .pdf.
    static let documentIngestionCharacterCap = 40_000

    /// Characters of extracted document text ALL of a turn's attachments may
    /// contribute between them. 2026-09-06: the per-attachment cap was the only
    /// bound, and both file pickers allow unlimited multiple selection — ten
    /// documents were ten times 40k, and the turn's context went with them. The
    /// budget is spent in attachment order; once it is gone the remaining
    /// documents are skipped and the model is told how many and why.
    static let turnDocumentCharacterBudget = 120_000

    /// What the model gets for this turn's attachments: the image blocks it is
    /// allowed to see, and the user message with an honest note appended for
    /// anything that was skipped or read out of a document.
    struct TurnAttachmentInput: Sendable {
        let imageBlocks: [LLMContentBlock]
        let userMessage: String
    }

    nonisolated static func turnAttachmentInput(
        message: String,
        attachments: [MultimodalAttachment],
        dataRoot: URL
    ) -> TurnAttachmentInput {
        guard !attachments.isEmpty else {
            return TurnAttachmentInput(imageBlocks: [], userMessage: message)
        }
        var notes: [String] = []

        // "Allow vision API calls". Off → the images never become blocks, and
        // the model is told so in the same shape LLMClient+Real uses when a
        // non-vision adapter drops them: honest, and explicitly not licence to
        // describe what it did not see.
        let visionAllowed = multimodalPolicyAllows("vision_api_calls", default: true, dataRoot: dataRoot)
        let imageBlocks = visionAllowed ? imageBlocksFromAttachments(attachments) : []
        if !visionAllowed {
            let skipped = imageBlocksFromAttachments(attachments).count
            if skipped > 0 {
                notes.append(
                    "[NOTE TO ASSISTANT: the user attached \(skipped) image(s), but "
                    + "\"Allow vision API calls\" is off in Trust Center ▸ Permissions, so the "
                    + "image(s) were skipped and NOT sent. Tell the user honestly that you could "
                    + "not view them and that the switch is what stopped it — do NOT guess or "
                    + "pretend to describe them.]")
            }
        }

        // 2026-09-06: a .txt/.md attachment reached the model as nothing at all
        // — it attaches as type "file", never became a content block, and no
        // lane read it. Same road as the PDF text, no switch: nothing in Trust
        // claims to govern plain text. PDFs and plain text share one pass so
        // they also share one per-turn character budget.
        notes.append(contentsOf: documentAttachmentNotes(attachments, dataRoot: dataRoot))

        guard !notes.isEmpty else {
            return TurnAttachmentInput(imageBlocks: imageBlocks, userMessage: message)
        }
        let composed = ([message] + notes)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return TurnAttachmentInput(imageBlocks: imageBlocks, userMessage: composed)
    }

    /// Every document attachment of a turn — PDFs under "Allow PDF file
    /// ingestion", plain text under no switch (none claims to govern it) — read
    /// in ONE pass, in attachment order, through the same extractors the `read`
    /// organ uses. Anything skipped, cut, or unreadable is named to the model
    /// rather than being left as a filename it can invent contents for.
    ///
    /// 2026-09-06: this was two passes with a 40k cap each and no ceiling on
    /// how many attachments could claim one. One pass, one budget: each
    /// document takes at most `documentIngestionCharacterCap`, and no more than
    /// what is left of `turnDocumentCharacterBudget`; when the budget is spent
    /// the rest are skipped and counted in a note that names the budget.
    nonisolated static func documentAttachmentNotes(
        _ attachments: [MultimodalAttachment],
        dataRoot: URL
    ) -> [String] {
        let pdfCount = attachments.filter { isPDFAttachment($0) }.count
        var notes: [String] = []
        let pdfAllowed = pdfCount == 0
            || multimodalPolicyAllows("file_ingestion_pdf", default: true, dataRoot: dataRoot)
        if pdfCount > 0, !pdfAllowed {
            notes.append(
                "[NOTE TO ASSISTANT: \(pdfCount) PDF attachment(s) were skipped — "
                + "\"Allow PDF file ingestion\" is off in Trust Center ▸ Permissions. Say so "
                + "plainly; do NOT guess at what the document(s) say.]")
        }

        var remainingBudget = turnDocumentCharacterBudget
        var skippedForBudget = 0
        for attachment in attachments {
            let isPDF = isPDFAttachment(attachment)
            if isPDF, !pdfAllowed { continue }
            guard isPDF || isPlainTextAttachment(attachment) else { continue }
            let label = isPDF ? "PDF" : "text file"
            let name = attachment.name ?? (isPDF ? "attachment.pdf" : "attachment.txt")
            guard let data = Data(base64Encoded: attachment.base64), !data.isEmpty else {
                notes.append(
                    "[NOTE TO ASSISTANT: the \(label) \"\(name)\" was attached but its bytes could "
                    + "not be read, so it was skipped. Say so; do NOT guess at its contents.]")
                continue
            }
            // 2026-09-06: MacDocumentRead.decodeText rejects only a NUL in the
            // first 4 KiB and then falls back to ISO-8859-1, which decodes ANY
            // byte sequence — so a renamed binary with a .txt extension arrived
            // as a page of mojibake presented as a document. The read organ
            // keeps that latitude (a person named that file by path); a chat
            // attachment named itself, so here the bytes must really be text.
            if !isPDF, !attachmentBytesAreText(data) {
                notes.append(
                    "[NOTE TO ASSISTANT: the \(label) \"\(name)\" was skipped — "
                    + "\(textSkipReason(.unreadableDocument)). Say so; do NOT guess at its "
                    + "contents.]")
                continue
            }
            switch MacDocumentRead.extract(data: data, kind: isPDF ? .pdf : .text) {
            case .failure(let failure):
                let reason = isPDF ? pdfSkipReason(failure) : textSkipReason(failure)
                notes.append(
                    "[NOTE TO ASSISTANT: the \(label) \"\(name)\" was skipped — \(reason). Say so; "
                    + "do NOT guess at its contents.]")
            case .success(let extracted):
                guard remainingBudget > 0 else {
                    skippedForBudget += 1
                    continue
                }
                var text = extracted.text
                var cut = extracted.truncated
                let allowance = min(documentIngestionCharacterCap, remainingBudget)
                if text.count > allowance {
                    text = String(text.prefix(allowance))
                    cut = true
                }
                remainingBudget -= text.count
                let subject = isPDF ? "the attached PDF" : "the attached file"
                let header = cut
                    ? "[Text of \(subject) \"\(name)\", cut off after the first "
                        + "\(text.count) characters — there is more you were not given:]"
                    : "[Text of \(subject) \"\(name)\":]"
                notes.append(header + "\n" + text)
            }
        }
        if skippedForBudget > 0 {
            notes.append(
                "[NOTE TO ASSISTANT: \(skippedForBudget) further document attachment(s) were not "
                + "read at all — this turn's \(turnDocumentCharacterBudget)-character budget for "
                + "attached documents was already spent by the ones above. Say so, and offer to "
                + "take them one at a time; do NOT guess at their contents.]")
        }
        return notes
    }

    nonisolated static func isPDFAttachment(_ attachment: MultimodalAttachment) -> Bool {
        let mime = attachment.mime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = (attachment.name ?? "").lowercased()
        return mime == "application/pdf" || name.hasSuffix(".pdf")
    }

    /// UTF-8, or UTF-16 announced by a BOM. Deliberately narrower than
    /// `MacDocumentRead.decodeText`, whose ISO-8859-1 fallback never fails and
    /// so cannot tell a text file from a renamed binary.
    nonisolated static func attachmentBytesAreText(_ data: Data) -> Bool {
        if String(data: data, encoding: .utf8) != nil { return true }
        let bom = [UInt8](data.prefix(2))
        guard bom.count == 2, bom == [0xFF, 0xFE] || bom == [0xFE, 0xFF] else { return false }
        return String(data: data, encoding: .utf16) != nil
    }

    /// Text by EXTENSION first (the same allow-list the `read` organ uses — a
    /// .png decodes to garbage that looks like a short document), then by mime
    /// for the surfaces that deliver a file without a usable name. Images and
    /// PDFs are somebody else's job.
    nonisolated static func isPlainTextAttachment(_ attachment: MultimodalAttachment) -> Bool {
        let type = attachment.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard type != "image" else { return false }
        let mime = attachment.mime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = (attachment.name ?? "").lowercased()
        guard mime != "application/pdf", !name.hasSuffix(".pdf") else { return false }
        if !name.isEmpty, MacDocumentRead.kind(forPath: name) == .text { return true }
        if mime.hasPrefix("text/") { return true }
        return mime == "application/json" || mime == "application/xml"
    }

    nonisolated static func textSkipReason(_ failure: MacDocumentRead.ExtractionFailure) -> String {
        switch failure {
        case .fileTooLarge: return "it is too large to read in one go"
        case .unreadableDocument: return "its bytes are not readable text"
        case .noTextInDocument: return "it is empty"
        default: return "its text could not be extracted"
        }
    }

    nonisolated static func pdfSkipReason(_ failure: MacDocumentRead.ExtractionFailure) -> String {
        switch failure {
        case .fileTooLarge: return "it is too large to read in one go"
        case .encryptedDocument: return "it is password-protected"
        case .noTextInDocument: return "it has no text layer — it is pictures of pages, not characters"
        default: return "its text could not be extracted"
        }
    }

    /// Ack-on-enqueue seam (wake-delivery-classification, 2026-07-25): durably
    /// append the user row and return. The turn that consumes it runs later
    /// with `suppressUserAppend: true`, producing the same on-disk state the
    /// normal path has at context-build time (structured chat appends the user
    /// row FIRST, then builds context from the transcript — so a pre-appended
    /// row is indistinguishable to the engine).
    ///
    /// Failure semantics callers must respect: `appendMessage` performs
    /// post-append bookkeeping (session index sync, cognitive observation)
    /// that can throw AFTER the row is durably on disk. A thrown error from
    /// this method therefore means "not proven enqueued", never "proven not
    /// enqueued" — transports must settle ambiguity against the store itself.
    public func enqueueUserMessage(
        message: String,
        sessionId: String?,
        persona: String?,
        surface: String,
        attachments: [MultimodalAttachment] = []
    ) async throws -> EnqueuedUserMessage {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }
        let resolvedSession = try Self.resolveSessionId(sessionId)
        let runId = UUID().uuidString
        try await appendMessage(
            sessionId: resolvedSession,
            role: "user",
            content: message,
            runId: runId,
            attachments: attachments,
            persona: persona,
            source: surface
        )
        return EnqueuedUserMessage(sessionId: resolvedSession, runId: runId)
    }

    /// Append one chat message in the daemon's per-line JSON shape so a
    /// future reader (Python or SwiftNative SessionHistoryReader) round-trips
    /// the record. Mirrors `append_chat_message` in the retired daemon.
    /// `recalledMemoryIds` (mind-into-circulation, 2026-07-10): the MemoryV2
    /// record ids this turn actually recalled. Stamped onto the assistant
    /// turn's cognitive event as `memoryRecordIds` metadata — the convention
    /// `attentionSignals(at:)` reads to feed felt-memory activation back into
    /// Fluid Context selection. Without this stamp that channel is inert.
    func appendMessage(
        sessionId: String,
        role: String,
        content: String,
        runId: String?,
        attachments: [MultimodalAttachment],
        persona: String? = nil,
        source: String = "app",
        recalledMemoryIds: [String] = [],
        canonicalAssistantCompletion: Bool = false,
        outcomeResult: TurnEngineResult? = nil,
        outcomeContext: TurnContext? = nil,
        outcomeTurnID: String? = nil,
        responseOutcomeStatus: String? = nil,
        outcomeInterventionAssignment: CausalInterventionAssignment? = nil
    ) async throws {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        let messageSource = Self.messageSource(for: source)
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        // Reject a damaged shared index before creating an orphan transcript.
        // The locked sync below remains authoritative; this preflight keeps the
        // common stable-corruption case fully fail-closed across both files.
        _ = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let persistedAt = clock()
        let createdAt = Self.iso8601(persistedAt)
        let messageId = UUID().uuidString
        // Precompute and encode the complete payload-free observation before
        // entering the transcript lock. The lock performs no awaits and no
        // future-state lookup; it only appends/replaces immutable bytes.
        let responseStatus = responseOutcomeStatus
            ?? (canonicalAssistantCompletion && role == "assistant" ? "persisted" : nil)
        let outcomeObservation = responseStatus.flatMap {
            ResponseOutcomeObservationV2.make(
                turnID: outcomeTurnID ?? TurnTraceContext.turnId ?? runId,
                messageID: messageId,
                sessionID: sessionId,
                surface: messageSource,
                observedAt: persistedAt,
                responsePersistence: $0,
                result: outcomeResult,
                context: outcomeContext,
                interventionAssignment: outcomeInterventionAssignment
            )
        }
        var record: [String: JSONValue] = [
            "id": .string(messageId),
            "sessionId": .string(sessionId),
            "role": .string(role),
            "content": .string(content),
            "createdAt": .string(createdAt),
            "source": .string(messageSource),
        ]
        if let runId { record["runId"] = .string(runId) }
        var metadata: [String: JSONValue] = [:]
        if !attachments.isEmpty {
            // Stash attachment metadata (not bytes) so a future consolidation
            // pass can correlate. Including base64 inline would explode the
            // JSONL — daemon practice is to keep blobs out of this file.
            var arr: [JSONValue] = []
            for a in attachments {
                var item: [String: JSONValue] = [
                    "id": .string(a.id),
                    "type": .string(a.type),
                    "mime": .string(a.mime),
                    "name": .string(a.name ?? ""),
                    "byteSize": .int(Int64(a.byteSize)),
                ]
                if let path = a.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    item["path"] = .string(path)
                }
                arr.append(.object(item))
            }
            metadata["attachments"] = .array(arr)
        }
        if let persona, !persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["persona"] = .string(persona)
        }
        // Session provenance (658.14). Durable, out-of-band origin marking for
        // messages that did NOT come from the human at this Mac. Only the user
        // row carries it: an assistant row is hers by construction, and
        // stamping origin there would imply the reply came from the bridge.
        let originProvenance = role == "user"
            ? ChatPersistenceContext.originProvenance
            : nil
        if let origin = originProvenance {
            var originObject: [String: JSONValue] = [
                "surface": .string(origin.surface),
            ]
            if let agent = origin.agent,
               !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                originObject["agent"] = .string(agent)
            }
            metadata["origin"] = .object(originObject)
        }
        // `metadata.envelope` — the turn's surface identity and return route,
        // durable on the row (one-thread-many-surfaces plan §2.3).
        //
        // WHY IT IS BROADER THAN `metadata.origin`, which stays exactly as it
        // is above:
        //
        //   * origin is USER-ROW ONLY and deliberately so — an assistant row
        //     is hers by construction, and stamping origin there would imply
        //     the reply came from the bridge. The envelope has the opposite
        //     job: it records WHERE THIS ROW'S TURN WAS SPOKEN AND WHERE ITS
        //     REPLY WENT, which is a fact about the assistant row too.
        //   * origin carries {surface, agent}. The envelope also carries the
        //     verified identities and the delivery route, so a completion that
        //     arrives after the originating loop has moved on can still find
        //     its destination without re-deriving it from "the session's
        //     surface" — which, with several surfaces writing one transcript,
        //     is no longer a thing that exists.
        //
        // Both are written for one release (plan §6: rollback is only cheap
        // while dual-write is on). The readers at MemoryV2+AdaptivePromoter
        // and MacChatMessageProvenance keep reading `origin` untouched.
        //
        // NO TRUST VERDICT IS PERSISTED HERE, ever. See `TurnEnvelope`: a tool
        // call's authority comes from the CURRENT turn's envelope, never from
        // one in history. This row is a label a reader can trust to be honest
        // about provenance, and it grants nothing.
        let turnEnvelope: TurnEnvelope = {
            let live = TurnEnvelope.current(surface: messageSource)
            guard let origin = originProvenance else { return live }
            // A bridged turn's honest surface is the bridge it arrived on, and
            // its lane is the agent. `messageSource` is the TOOL-AUTHORIZATION
            // surface (the bridges deliberately run as "chat"), so the two
            // must not be conflated on a provenance row.
            return TurnEnvelope(
                surface: origin.surface,
                agent: origin.agent,
                verifiedChatId: live.verifiedChatId,
                verifiedUserId: live.verifiedUserId,
                commandSignatureVerified: live.commandSignatureVerified,
                deliveryRoute: live.deliveryRoute,
                declaredRemote: live.declaredRemote
            )
        }()
        metadata["envelope"] = turnEnvelope.persistedMetadata()
        if canonicalAssistantCompletion,
           role == "assistant",
           let binding = ChatPersistenceContext.codexCompletionBinding,
           !binding.deliveryId.isEmpty,
           !binding.requestDigest.isEmpty {
            let executedModel = outcomeContext?.modelId
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let completionModel = executedModel?.isEmpty == false
                ? executedModel!
                : binding.model
            let completionEffort = outcomeContext?.reasoningEffort
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var completion: [String: JSONValue] = [
                "deliveryId": .string(binding.deliveryId),
                "requestDigest": .string(binding.requestDigest),
                // The successful turn context is the execution truth. A shell
                // may bind blank/stale request evidence before admission, but
                // crash recovery must cache the tuple that actually produced
                // this canonical assistant row.
                "model": .string(completionModel),
                "responseDigest": .string(CodexCompletionTranscriptEvidence.responseDigest(
                    sessionId: sessionId,
                    runId: runId ?? "",
                    content: content,
                    attachments: attachments
                )),
            ]
            if let effort = completionEffort?.isEmpty == false
                ? completionEffort
                : binding.reasoningEffort {
                completion["reasoningEffort"] = .string(effort)
            }
            metadata["codexCompletion"] = .object(completion)
        }
        // Payload-free outcome correlation: canonical assistant completions
        // retain the opaque turn receipt identity that produced them. This is
        // not prompt context and is never reconstructed from message prose.
        // It lets an explicit regenerate replacement name the exact earlier
        // turn rather than guessing that the preceding assistant row was it.
        if let outcomeObservation, role == "assistant" {
            metadata["turnTraceId"] = .string(outcomeObservation.turnID)
            metadata["outcomeObservation"] = outcomeObservation.jsonValue
        }
        if !metadata.isEmpty {
            record["metadata"] = .object(metadata)
        }
        // Locked: see appendPartial — protects against the compactor/distiller
        // locked rewrite dropping a concurrent append. (Immutable binding: a
        // @Sendable closure cannot capture the mutable `record`.)
        let messageRow: JSONValue = .object(record)
        // Line-count bookkeeping happens INSIDE this lock, on purpose. Both
        // branches below know exactly how many rows the transcript holds when
        // they commit — the append branch adds one line to whatever was there,
        // the replacement branch rewrites a known row set — so the session
        // index sync below can validate that count with a stat instead of
        // re-deriving it by reading every byte of the file. Doing it under the
        // same lock that guards the write is what makes the recorded count
        // trustworthy: no other lock-respecting writer, in this process or
        // another, can slip a row in between the read and the record.
        let replacedTurnTraceID: String? = try await persistence.withFileLock(path) {
            if canonicalAssistantCompletion,
               role == "assistant",
               let replacementID = ChatPersistenceContext.replacementAssistantMessageID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !replacementID.isEmpty {
                let rows = try await persistence.readJSONL(path)
                let matching = rows.indices.filter { index in
                    Self.messageID(in: rows[index]) == replacementID
                }
                guard matching.count == 1 else {
                    throw ChatOrchestrationError.underlying(
                        "regenerate replacement target must identify exactly one persisted message"
                    )
                }
                let index = matching[0]
                guard Self.messageRole(in: rows[index]) == "assistant" else {
                    throw ChatOrchestrationError.underlying(
                        "regenerate replacement target is not an assistant message"
                    )
                }
                // Retry may already have persisted its own tool receipts. They
                // are not a newer conversational turn, but must stay ahead of
                // its final answer. No foreign or untyped trailing row qualifies.
                let onlyOwnRetryReceipts = rows[(index + 1)...].allSatisfy { row in
                    guard let runId, !runId.isEmpty,
                          case .object(let object) = row,
                          object["role"] == .string("tool"),
                          object["runId"] == .string(runId),
                          object["sessionId"] == .string(sessionId),
                          case .string(let rowID)? = object["id"], !rowID.isEmpty,
                          case .object(let metadata)? = object["metadata"],
                          case .string(let toolName)? = metadata["toolName"], !toolName.isEmpty,
                          case .string(let kind)? = metadata["kind"]
                    else { return false }
                    return kind == ChatTranscriptToolMessageKind.toolUse
                        || kind == ChatTranscriptToolMessageKind.approvalPending
                }
                guard onlyOwnRetryReceipts else {
                    throw ChatOrchestrationError.underlying(
                        "regenerate replacement target is no longer the transcript tail"
                    )
                }
                let priorTurnTraceID = Self.messageTurnTraceID(in: rows[index])
                var replaced = rows
                replaced.remove(at: index)
                replaced.append(messageRow)
                try Self.writeJSONLAtomically(replaced, to: path)
                // A replacement is row-count neutral by construction: one row
                // replaces exactly one match, after its receipts. `writeJSONLAtomically`
                // emits one non-blank line per row, which is precisely what
                // `countJSONLLines` counts.
                ChatTranscriptLineCountCache.shared.record(count: replaced.count, at: path)
                return priorTurnTraceID
            } else {
                let priorCount = ChatTranscriptLineCountCache.shared.count(
                    at: path,
                    recount: Self.countJSONLLines(at:)
                )
                // DURABLE (sweep R4 item 4). Every row that reaches this
                // function is a COMMITTED turn boundary: `role` is "user" at
                // three call sites and "assistant" at four, and the assistant
                // ones are terminal completions or the terminal failure row —
                // streaming partials never come here (persistPartialIfNeeded
                // owns those and stays on the fast path). A user row lost to
                // power loss is a question the user watched land and then
                // vanish; a terminal assistant row lost is the answer to it.
                // Cost is one F_FULLFSYNC per committed turn boundary (~2 per
                // turn), which is the budget PersistenceCore's own note on
                // appendJSONLDurable reserves for "feeds that ARE the state of
                // record".
                try await persistence.appendJSONLDurable(messageRow, to: path)
                // `appendJSONLDurable` writes exactly one serialized line plus "\n".
                ChatTranscriptLineCountCache.shared.record(count: priorCount + 1, at: path)
                return nil
            }
        }
        if role == "user" {
            do {
                _ = try await OutcomeFeedbackStore(
                    dataRoot: dataRoot,
                    persistence: persistence,
                    clock: { persistedAt }
                ).recordConversationContinuation(
                    sessionID: safeSessionId,
                    reactionMessageID: messageId
                )
            } catch {
                // The user row is already durable state. Reaction learning is
                // additive evidence and cannot roll the user's message back.
                NSLog("OutcomeFeedbackStore: continuation receipt failed: \(error)")
            }
        }
        // This receipt means exactly one thing: the locked canonical transcript
        // replacement committed. It does not call the retry a correction, say
        // that the old response was bad, or give the shadow any control.
        if let targetTurnID = OutcomeTraceIdentity.normalized(replacedTurnTraceID),
           let reactionTurnID = OutcomeTraceIdentity.normalized(TurnTraceContext.turnId),
           targetTurnID != reactionTurnID {
            TurnTraceBus.fire(TurnTraceEvent(
                turnId: reactionTurnID,
                kind: "turn.reaction",
                sessionId: sessionId,
                surface: source,
                payload: .object([
                    "schema": .string("metacognition.reaction.v1"),
                    "controlAuthority": .bool(false),
                    "reaction": .string("explicit_retry"),
                    "targetTurnId": .string(targetTurnID),
                    "observedBy": .string("transcript.regenerate_replacement"),
                ])
            ), on: turnTraceBus)
        }
        try await syncSessionIndex(
            sessionId: sessionId,
            role: role,
            content: content,
            timestamp: createdAt,
            messagesPath: path,
            source: messageSource
        )
        await observeCognitiveMessage(
            sessionId: sessionId,
            role: role,
            content: content,
            runId: runId,
            source: messageSource,
            createdAt: createdAt,
            messageId: messageId,
            origin: originProvenance,
            recalledMemoryIds: recalledMemoryIds
        )
    }

    private static func messageID(in row: JSONValue) -> String? {
        guard case .object(let object) = row else { return nil }
        if case .string(let id)? = object["id"] { return id }
        if case .string(let id)? = object["message_id"] { return id }
        return nil
    }

    private static func messageRole(in row: JSONValue) -> String? {
        guard case .object(let object) = row,
              case .string(let role)? = object["role"] else { return nil }
        return role
    }

    private static func messageTurnTraceID(in row: JSONValue) -> String? {
        guard case .object(let object) = row,
              case .object(let metadata)? = object["metadata"],
              case .string(let raw)? = metadata["turnTraceId"]
        else { return nil }
        return OutcomeTraceIdentity.normalized(raw)
    }

    private static func writeJSONLAtomically(_ rows: [JSONValue], to path: URL) throws {
        var payload = Data()
        for row in rows {
            payload.append(contentsOf: try row.serialize(pretty: false).utf8)
            payload.append(0x0A)
        }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Durable replacement, not bare .atomic: this writer's one production
        // caller swaps a terminal assistant row in place (regenerate). Losing
        // that rewrite to power loss while the session index already durably
        // recorded it would roll the transcript back behind its own index
        // (gpt-5.5 review 2026-08-06, blocking #2). Same temp-fsync + rename
        // + parent-dir-fsync contract as every other state-of-record write.
        try SwiftNativePersistenceCore.writeDataAtomicDurable(payload, to: path)
        _ = chmod(path.path, 0o600)
    }

    func appendFailureMessageIfNeeded(
        sessionId: String,
        runId: String?,
        errorMessage: String,
        persona: String?,
        outcomeContext: TurnContext? = nil,
        outcomeTurnID: String? = nil,
        outcomeInterventionAssignment: CausalInterventionAssignment? = nil
    ) async throws {
        let trimmed = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = trimmed.hasPrefix("Chat error:")
            ? trimmed
            : "Chat error: \(trimmed.isEmpty ? "unknown provider failure" : trimmed)"
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return
        }
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        if await Self.sessionAlreadyHasAssistantMessage(path: path, runId: runId) {
            return
        }
        try await appendMessage(
            sessionId: sessionId,
            role: "assistant",
            content: content,
            runId: runId,
            attachments: [],
            persona: persona,
            outcomeContext: outcomeContext,
            outcomeTurnID: outcomeTurnID,
            responseOutcomeStatus: "failed",
            outcomeInterventionAssignment: outcomeInterventionAssignment
        )
    }

    @discardableResult
    func compactSessionBeforeContextIfNeeded(
        sessionId: String,
        model: String,
        surface: String,
        runId: String?
    ) async throws -> ChatSessionCompactionOutcome {
        // A pre-seeding provider call is never a prefix-shaped request: this
        // runs BEFORE the turn's context is built and its messages are seeded,
        // so there is no replayed prefix for a v2 wire layout to describe.
        // Binding here covers every caller of this entry point — the
        // text-compat lane and both structured-chat sites.
        try await ConversationPrefixShape.$override.withValue(.v1Legacy) {
            try await compactSession(
                sessionId: sessionId,
                model: model,
                surface: surface,
                runId: runId,
                providerID: LLMCallContext.providerId,
                trigger: "auto_threshold",
                force: false
            )
        }
    }

    /// Explicit user-requested compaction through the same canonical owner as
    /// automatic pre-turn compaction. `force` bypasses only the automatic
    /// enable/threshold gates; validation, verified backup, keep-tail,
    /// durable replacement, trace projection, and optional distillation remain
    /// identical.
    @discardableResult
    public func compactSession(
        sessionId: String,
        model: String,
        surface: String = "chat",
        runId: String? = nil,
        providerID: String? = nil,
        force: Bool = true
    ) async throws -> ChatSessionCompactionOutcome {
        try await compactSession(
            sessionId: sessionId,
            model: model,
            surface: surface,
            runId: runId,
            providerID: providerID,
            trigger: force ? "manual_request" : "manual_threshold",
            force: force
        )
    }

    private func compactSession(
        sessionId: String,
        model: String,
        surface: String,
        runId: String?,
        providerID: String?,
        trigger: String,
        force: Bool
    ) async throws -> ChatSessionCompactionOutcome {
        let compactor = ChatSessionAutocompactor(
            dataRoot: dataRoot,
            config: autocompactionConfig,
            now: clock
        )
        let outcome = try await compactor.compactIfNeeded(
            sessionId: sessionId,
            model: model,
            surface: surface,
            runId: runId,
            providerID: providerID,
            trigger: trigger,
            force: force
        )
        // 2026-09-06: compaction rewrites the transcript, so it is a transcript
        // write like any other and has to advance the session's transcript
        // version. Outside the compactor's own message-file lock — this takes
        // the index lock, and the two are never nested.
        if outcome.compacted {
            await bumpSessionTranscriptGeneration(sessionId: outcome.sessionId)
        }
        // Fire-and-forget LLM distillation of the mechanical summary. Only when
        // distill is enabled AND a backup was taken (both encoded in the outcome
        // via a non-nil summaryRowId/backupPath). Never delays or fails the turn;
        // any distiller failure leaves the mechanical summary standing.
        if autocompactionConfig.distillEnabled,
           outcome.compacted,
           let rowId = outcome.summaryRowId,
           let backupPath = outcome.backupPath {
            let dataRoot = self.dataRoot   // let/Sendable — nonisolated capture
            let llm = self.llm
            let clock = self.clock
            let messagesReplaced = outcome.messagesReplaced
            Task.detached(priority: .background) {
                let distiller = ChatCompactionDistiller(
                    dataRoot: dataRoot,
                    pinnedModelResolver: { surface in
                        await SwiftNativeProviderRouting(
                            dataRoot: dataRoot,
                            surfacesPathOverride: dataRoot
                                .appendingPathComponent("providers", isDirectory: true)
                                .appendingPathComponent("surfaces.json"),
                            activeProviderPathOverride: dataRoot
                                .appendingPathComponent("providers", isDirectory: true)
                                .appendingPathComponent("active.json")
                        ).pinnedModelStringForSurface(surface)
                    },
                    llmComplete: { model, prompt in
                        try await llm.complete(
                            prompt: prompt,
                            system: ChatCompactionDistiller.distillSystem,
                            model: model,
                            surface: ChatCompactionDistiller.distillSurface
                        )
                    },
                    now: clock
                )
                // `Task.detached` inherits no task-locals, so the caller's
                // binding cannot reach here — and the distiller's own LLM call
                // is a plain prompt with no replayed prefix. Say v1 outright
                // rather than depending on unbound-means-legacy, which holds
                // only while the adapters read `override` and not `.effective`.
                await ConversationPrefixShape.$override.withValue(.v1Legacy) {
                    await distiller.distill(
                        sessionId: sessionId,
                        summaryRowId: rowId,
                        backupPath: backupPath,
                        messagesReplaced: messagesReplaced,
                        turnModel: model,
                        surface: surface,
                        runId: runId
                    )
                }
            }
        }
        return outcome
    }

    static func shouldPersistFailureMessage(surface: String) -> Bool {
        surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "telegram"
    }

    /// The one public boundary that admits an identity to durable chat state.
    /// Mounted surfaces creating a new conversation must generate and retain an
    /// ID before calling this; persistence itself never manufactures one.
    public static func resolveSessionId(_ sessionId: String?) throws -> String {
        // A transcript operation may never invent an identity. A caller that
        // lost its session id must fail at this boundary instead of silently
        // creating an orphan transcript and sessions.json row that no visible
        // conversation owns. New-session creation belongs to the mounted
        // surface before it calls into persistence, where it can retain and
        // display the generated identity.
        guard let raw = sessionId else {
            throw ChatOrchestrationError.underlying("missing chat session id")
        }
        guard let safe = NativeAgentChatSessionID.normalizedPathComponent(raw) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        return safe
    }

    private static func sessionAlreadyHasAssistantMessage(path: URL, runId: String?) async -> Bool {
        guard let runId, !runId.isEmpty else { return false }
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = String(rawLine).data(using: .utf8),
                  let parsed = try? JSONValue.parse(lineData),
                  case .object(let obj) = parsed else {
                continue
            }
            if case .string(let rowRunId)? = obj["runId"], rowRunId != runId {
                continue
            }
            if case .string(let rowRunId)? = obj["runId"], rowRunId == runId,
               case .string(let role)? = obj["role"], role == "assistant" {
                // A persisted PARTIAL/cancelled row (mid-stream failure or cancel)
                // is NOT a completed turn — it must not suppress the failure row
                // that surfaces the error on non-Mac surfaces (audit #5 follow-up;
                // mirrors NativeClient.isCompletedAssistant). gpt-5.5 review.
                if case .bool(true)? = obj["cancelled"] { continue }
                if case .object(let meta)? = obj["metadata"] {
                    if case .bool(true)? = meta["partial"] { continue }
                    if case .bool(true)? = meta["cancelled"] { continue }
                }
                return true
            }
        }
        return false
    }

    private func observeCognitiveMessage(
        sessionId: String,
        role: String,
        content: String,
        runId: String?,
        source: String,
        createdAt: String,
        messageId: String,
        origin: ChatMessageOrigin? = nil,
        recalledMemoryIds: [String] = []
    ) async {
        guard let cognitiveObserver else { return }
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind: CognitiveEventKind
        let sourceClass: CognitiveSourceClass
        let importance: Double
        switch normalizedRole {
        case "user":
            kind = .userMessageReceived
            // A bridge worker is not the human. Out-of-band origin, never its
            // forgeable text prefix, decides this trust class.
            sourceClass = origin == nil ? .userStated : .imported
            importance = 0.65
        case "assistant":
            if content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("chat error:") {
                kind = .providerFailure
                sourceClass = .observed
                importance = 0.85
            } else {
                kind = .assistantTurnCompleted
                sourceClass = .selfReported
                importance = 0.55
            }
        default:
            return
        }
        let redactedSummary = ChatSecretRedactor.redactText(content)
        var metadata: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "messageId": .string(messageId),
            "role": .string(normalizedRole),
            "source": .string(source),
        ]
        if normalizedRole == "user", let origin {
            // Keep the cognitive ledger correlated with the canonical
            // transcript without copying attacker-sized TaskLocal strings.
            // This is recorded route provenance, not a named-agent identity
            // attestation (the bridge currently uses one shared bearer).
            var cognitiveOrigin: [String: JSONValue] = [
                "surface": .string(String(origin.surface.unicodeScalars.prefix(80))),
            ]
            if let agent = origin.agent {
                let boundedAgent = String(agent.unicodeScalars.prefix(80))
                if !boundedAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cognitiveOrigin["agent"] = .string(boundedAgent)
                }
            }
            // Item 8: forwarded ONLY when the lane stated it. Route provenance
            // alone cannot say whether the agent spoke or merely carried the
            // human's words, and the affect layer needs that distinction before
            // it will let anyone other than the user move her.
            if let authored = origin.authored {
                cognitiveOrigin["authored"] = .string(authored.rawValue)
            }
            metadata["origin"] = .object(cognitiveOrigin)
        }
        if let runId { metadata["runId"] = .string(runId) }
        if kind == .providerFailure, providerLifecycleObserverInstalled {
            metadata[CognitiveSomaticSignalAdapter.somaticOwnerMetadataKey] = .string(
                CognitiveSomaticSignalAdapter.providerLifecycleSomaticOwner
            )
        }
        // Mind-into-circulation (2026-07-10): stamp the turn's recalled MemoryV2
        // record ids so the node this event becomes carries them — the substrate's
        // attentionSignals read maps them to felt-memory activation. Assistant
        // turns only (that's the turn that USED the recalls), deduped, bounded.
        if normalizedRole == "assistant", kind == .assistantTurnCompleted, !recalledMemoryIds.isEmpty {
            let bounded = Array(Set(recalledMemoryIds)).sorted().prefix(32)
            metadata["memoryRecordIds"] = .array(bounded.map { .string($0) })
        }
        if normalizedRole == "assistant", kind == .assistantTurnCompleted {
            // The event summary is deliberately capped below, but delivery-
            // envelope telemetry needs the length of the actual redacted
            // reply. Carry only that bounded count; never duplicate content.
            metadata[CognitiveSubstrate.replyCharacterCountMetadataKey] =
                .int(Int64(redactedSummary.count))
        }
        let turnKind = Self.cognitiveMessageTurnKind(
            role: normalizedRole, source: source,
            redactedContent: redactedSummary, origin: origin
        )
        let subject: CognitiveSubjectReference
        if normalizedRole == "assistant", kind == .assistantTurnCompleted {
            subject = CognitiveSubjectReference(
                type: "chat.assistant_turn",
                id: "\(sessionId):\(messageId)",
                // Her own turns get a topic too (2026-09-02): a felt moment
                // that read `chat.assistant_turn` pointed at nothing.
                label: CognitiveSubstrate.feltTopicLabel(from: redactedSummary)
            )
        } else if kind == .userMessageReceived || kind == .userCorrection {
            // Audit C2 (2026-07-09): user turns get PER-TURN subjects, mirroring the
            // assistant branch. The old per-session subject collapsed every user turn
            // onto ONE field node whose asymmetric reconsolidation (up 0.5 / down 0.15)
            // ratcheted positive — a criticism blended into a warm session node instead
            // of stamping a fresh stung one, defeating the felt fingerprint's sting
            // path in production while per-turn-shaped tests passed. Session-level
            // continuity still reads through sessionId metadata (the semantic
            // appraisal's same-session evidence), not through node identity.
            subject = CognitiveSubjectReference(
                type: "chat.user_turn",
                id: "\(sessionId):\(messageId)",
                // 2026-09-02 — the turn's TOPIC, so the felt line can say what
                // it is about ("on edge — about deploy pipeline") instead of
                // carrying a feeling with no sky. Up to three salient content
                // words, from the REDACTED summary and through the same
                // extractor Fluid Context uses for attention terms; nil when
                // the turn has no salient term, and then the line simply has
                // no object. Never the message itself: stopwords, pronouns,
                // punctuation, grammar and digits do not survive it.
                label: CognitiveSubstrate.feltTopicLabel(from: redactedSummary)
            )
        } else {
            subject = CognitiveSubjectReference(type: "chat.session", id: sessionId)
        }
        await cognitiveObserver.observe(CognitiveEvent(
            id: "chat:\(sessionId):\(messageId)",
            kind: kind,
            subject: subject,
            sourceClass: sourceClass,
            occurredAt: Self.dateFromISO8601(createdAt) ?? clock(),
            summary: String(redactedSummary.prefix(500)),
            importance: importance,
            turnKind: turnKind,
            metadata: metadata
        ))
    }

    /// One workload-class boundary for accepted events and their capsules.
    /// Capsule preparation must not reinterpret admitted live prose as debug.
    nonisolated static func cognitiveMessageTurnKind(
        role: String,
        source: String,
        redactedContent: String,
        origin: ChatMessageOrigin?
    ) -> CognitiveTurnKind {
        // Chat workload class comes from surface provenance, never from topic
        // words. An ordinary user asking about the scheduler/doctor/observatory
        // is still a live turn. Verified out-of-band bridge origin makes
        // bounded content markers eligible to classify diagnostic traffic as
        // debug/verification; the runtime then carries that class through the
        // correlated run to tools and reply.
        let classificationSignals: [String]
        if role == "user", let origin, Self.isTrustedBridgeOrigin(origin) {
            // Content markers are eligible only behind a server-bound bridge
            // lane. This is transport provenance, not a claim inferred from
            // prose supplied by the human.
            // The synthetic prefix keeps the existing Codex debug classifier
            // behavior without trusting prose supplied by a Mac user.
            classificationSignals = [
                source,
                origin.surface,
                origin.agent.map { "[from: \($0), via bridge]" } ?? "",
                redactedContent,
            ]
        } else if role == "user" {
            classificationSignals = [source]
        } else {
            classificationSignals = [source, redactedContent]
        }
        let inferredTurnKind = CognitiveTurnKind.inferred(fromSignals: classificationSignals)
        return switch inferredTurnKind {
        case .debug, .verification: inferredTurnKind
        case .live, .system: .live
        }
    }

    private static func isTrustedBridgeOrigin(_ origin: ChatMessageOrigin) -> Bool {
        let surface = origin.surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let agent = origin.agent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch (surface, agent) {
        case ("claude-bridge", "claude"),
             ("codex-bridge", "codex"),
             ("omp-bridge", "omp"):
            return true
        default:
            return false
        }
    }

    private func observeCognitiveTool(
        sessionId: String,
        runId: String?,
        toolName: String,
        resultSummary: String,
        ok: Bool,
        cognitiveResult: ChatToolOutcome.CognitiveResult?,
        canonicalToolRisk: CanonicalToolRisk,
        source: String,
        createdAt: String,
        messageId: String
    ) async {
        guard let cognitiveObserver else { return }
        let exactCognitiveResult = cognitiveResult ?? (ok ? .succeeded : .failed)
        guard exactCognitiveResult != .unknown else { return }
        var metadata: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "messageId": .string(messageId),
            "toolName": .string(toolName),
            "ok": .bool(ok),
            "source": .string(source),
            "trustRisk": .string(canonicalToolRisk.rawValue),
        ]
        if let runId { metadata["runId"] = .string(runId) }
        let succeeded = exactCognitiveResult == .succeeded
        let status = succeeded ? "ok" : "failed"
        let summary = resultSummary.isEmpty
            ? "\(toolName) \(status)"
            : "\(toolName) \(status): \(resultSummary)"
        await cognitiveObserver.observe(CognitiveEvent(
            id: "chat-tool:\(sessionId):\(messageId)",
            kind: succeeded ? .toolSucceeded : .toolFailed,
            subject: CognitiveSubjectReference(type: "tool", id: toolName, label: toolName),
            sourceClass: .observed,
            occurredAt: Self.dateFromISO8601(createdAt) ?? clock(),
            summary: String(summary.prefix(500)),
            importance: succeeded ? 0.55 : 0.8,
            metadata: metadata
        ))
    }

    func observeCognitiveProgressEvent(
        sessionId: String,
        runId: String?,
        surface: String,
        event: TurnStreamEvent,
        toolResultAlreadyPersisted: Bool
    ) async {
        guard let cognitiveObserver else { return }
        let occurredAt = clock()
        switch event {
        case .toolUse(let name, let input):
            let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeName.isEmpty else { return }
            // Canonical motor owners emit their own exact action identity and
            // lifecycle. A generic start here cannot be correlated with that
            // terminal state and would leave false pending physiology.
            guard !ChatToolOutcome.hasCanonicalMotorOwner(safeName) else { return }
            // W2/W3-FIX-R2 2 — cognitive events are persisted physiology, so
            // the same by-tool redaction applies before the preview is cut.
            // (Injection tools take the canonical-motor-owner early return
            // above today; this must not depend on that staying true.)
            let inputPreview = Self.compactCognitiveJSON(
                MacInjectionArgRedaction.redactedPayload(tool: safeName, payload: input),
                maxCharacters: 240
            )
            var metadata: [String: JSONValue] = [
                "sessionId": .string(sessionId),
                "toolName": .string(safeName),
                "surface": .string(surface),
                "phase": .string("started"),
                "inputPreview": .string(inputPreview),
            ]
            if let runId { metadata["runId"] = .string(runId) }
            await cognitiveObserver.observe(CognitiveEvent(
                id: "chat-tool-start:\(sessionId):\(runId ?? "no-run"):\(safeName):\(Self.cognitiveDigest(inputPreview))",
                kind: .toolStarted,
                subject: CognitiveSubjectReference(type: "tool", id: safeName, label: safeName),
                sourceClass: .observed,
                occurredAt: occurredAt,
                summary: inputPreview.isEmpty
                    ? "\(safeName) started"
                    : "\(safeName) started: \(inputPreview)",
                importance: 0.45,
                metadata: metadata
            ))

        case .toolResult(let name, let output):
            guard !toolResultAlreadyPersisted else { return }
            let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeName.isEmpty else { return }
            let cognitiveResult = ChatToolOutcome.cognitiveResult(
                tool: safeName,
                output: output
            )
            guard cognitiveResult != .unknown else { return }
            let ok = cognitiveResult == .succeeded
            let outputPreview = Self.compactCognitiveJSON(
                MacInjectionResultRedaction.redacted(
                    tool: safeName,
                    result: MacScreenViewResultRedaction.redacted(tool: safeName, result: output)
                ),
                maxCharacters: 300
            )
            var metadata: [String: JSONValue] = [
                "sessionId": .string(sessionId),
                "toolName": .string(safeName),
                "surface": .string(surface),
                "phase": .string("result"),
                "ok": .bool(ok),
                "outputPreview": .string(outputPreview),
            ]
            if let runId { metadata["runId"] = .string(runId) }
            await cognitiveObserver.observe(CognitiveEvent(
                id: "chat-tool-result:\(sessionId):\(runId ?? "no-run"):\(safeName):\(Self.cognitiveDigest(outputPreview))",
                kind: ok ? .toolSucceeded : .toolFailed,
                subject: CognitiveSubjectReference(type: "tool", id: safeName, label: safeName),
                sourceClass: .observed,
                occurredAt: occurredAt,
                summary: outputPreview.isEmpty
                    ? "\(safeName) \(ok ? "ok" : "failed")"
                    : "\(safeName) \(ok ? "ok" : "failed"): \(outputPreview)",
                importance: ok ? 0.55 : 0.8,
                metadata: metadata
            ))

        case .error(let message):
            // The provider lifecycle observer owns exact correlated provider
            // physiology in production. Emitting this uncorrelated fallback as
            // well would double-count one failure. Custom/test clients without
            // that observer retain the legacy progress-only fallback.
            guard !providerLifecycleObserverInstalled else { return }
            let safe = ChatSecretRedactor.redactText(message)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safe.isEmpty else { return }
            var metadata: [String: JSONValue] = [
                "sessionId": .string(sessionId),
                "surface": .string(surface),
                "phase": .string("progress_error"),
            ]
            if let runId { metadata["runId"] = .string(runId) }
            await cognitiveObserver.observe(CognitiveEvent(
                id: "chat-provider-progress-error:\(sessionId):\(runId ?? "no-run"):\(Self.cognitiveDigest(safe))",
                kind: .providerFailure,
                subject: CognitiveSubjectReference(type: "chat.surface", id: surface, label: surface),
                sourceClass: .observed,
                occurredAt: occurredAt,
                summary: String(safe.prefix(500)),
                importance: 0.85,
                metadata: metadata
            ))

        case .delta, .final, .notice:
            return
        }
    }

    nonisolated private static func dateFromISO8601(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
    }

    /// W2/W3-FIX-R2 — redact an injection tool's ARGUMENT json before it is
    /// persisted or previewed. Works on the serialized string because that is
    /// what this layer is handed. A body that will not parse is dropped
    /// entirely for a secret-bearing tool: an unparseable payload we cannot
    /// redact is not a payload worth keeping.
    nonisolated static func injectionRedactedArgJSON(tool: String, json: String) -> String {
        guard MacInjectionArgRedaction.carriesSecretArgs(tool: tool) else { return json }
        guard let parsed = try? JSONValue.parse(Data(json.utf8)),
              case .object = parsed,
              let out = try? MacInjectionArgRedaction
                .redactedPayload(tool: tool, payload: parsed)
                .serialize(pretty: false) else {
            return "[redacted: \(tool) arguments]"
        }
        return out
    }

    /// Same, for an injection tool's RESULT (an `ax_act` re-reads and returns
    /// the value it just wrote).
    nonisolated static func injectionRedactedResultJSON(tool: String, json: String) -> String {
        guard MacInjectionToolNames.isInjectionTool(tool)
            || MacInjectionArgRedaction.carriesSecretArgs(tool: tool) else { return json }
        guard let parsed = try? JSONValue.parse(Data(json.utf8)),
              let out = try? MacInjectionResultRedaction
                .redacted(tool: tool, result: parsed)
                .serialize(pretty: false) else {
            // A non-JSON summary from an injection tool cannot be inspected for
            // the written value, so it is not kept verbatim.
            return json.contains("\"") || json.contains("{")
                ? "[redacted: \(tool) result]"
                : json
        }
        return out
    }

    /// W3.5-FIX 3 — strip `mac_view`'s base64 picture out of a serialized
    /// RESULT before it is persisted or previewed. Unlike the injection
    /// redactors this cannot fall back to "[redacted]" on a parse failure: a
    /// summary that will not parse also cannot contain a JSON `image` key we
    /// put there, and blanking every unparseable read result would destroy the
    /// transcript. A parse failure therefore leaves the (image-free) text.
    nonisolated static func screenViewRedactedResultJSON(tool: String, json: String) -> String {
        guard MacScreenViewResultRedaction.carriesImage(tool: tool) else { return json }
        guard let parsed = try? JSONValue.parse(Data(json.utf8)) else { return json }
        let stripped = MacScreenViewResultRedaction.redacted(tool: tool, result: parsed)
        guard let out = try? stripped.serialize(pretty: false) else {
            return "[redacted: \(tool) result]"
        }
        return out
    }

    nonisolated private static func compactCognitiveJSON(_ value: JSONValue, maxCharacters: Int) -> String {
        let serialized = (try? value.serialize(pretty: false)) ?? ""
        return String(serialized.prefix(max(0, maxCharacters)))
    }

    nonisolated private static func cognitiveDigest(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private func syncSessionIndex(
        sessionId: String,
        role: String,
        content: String,
        timestamp: String,
        messagesPath: URL,
        source: String
    ) async throws {
        let dataRoot = self.dataRoot
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let preview = Self.previewText(content)
        let title = normalizedRole == "user" ? Self.titleText(content) : nil
        let sourceKey = Self.sessionSourceKey(for: sessionId, source: source)
        // Same value, same moment, same definition as the old
        // `countJSONLLines(at: messagesPath)` that stood here — this count is
        // NOT advisory bookkeeping. `SessionDigestProvider.swift:243` renders
        // it into the next session's prompt ("Previous session "X" (N
        // messages) ended ..."), so it has to stay byte-exact. The cache only
        // removes the full byte scan when a stat proves the transcript is
        // still the one the count was measured against; anything else — an
        // external writer, a compaction rewrite, a truncation — recounts and
        // returns exactly what the scan would have.
        let persistence = self.persistence
        let retentionClock = self.clock
        // 2026-09-06: `timestamp` is the MESSAGE's createdAt, captured before
        // the transcript append. Stamping the index row's `updatedAt` with it
        // left every synced row permanently behind its own transcript's mtime,
        // and retention reads exactly that comparison as "this session has a
        // pending index sync" — so `.activeCap` archiving could never fire for
        // any ordinary session. The row's `updatedAt` says when the row was
        // last brought level with its transcript, so it is read HERE, after the
        // bytes are down. A new row's `createdAt` keeps the message stamp.
        let syncedAt = Self.iso8601(retentionClock())
        try await persistence.withFileLock(sessionsPath) {
            // 2026-09-06: READ UNDER THE INDEX LOCK. Taken before the lock, two
            // concurrent appenders could each measure the transcript, then
            // commit in the opposite order — the later writer stamping the
            // EARLIER count over the index. Measured here, the last writer to
            // hold this lock always measures a transcript that already contains
            // every row committed before it, so the index cannot go backwards.
            let messageCount = ChatTranscriptLineCountCache.shared.count(
                at: messagesPath,
                recount: Self.countJSONLLines(at:)
            )
            let parent = sessionsPath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)

            var updated: [String: JSONValue]? = nil
            var remaining: [[String: JSONValue]] = []
            for var row in rows {
                guard case .string(let id)? = row["id"], id == sessionId else {
                    remaining.append(row)
                    continue
                }
                row["updatedAt"] = .string(syncedAt)
                // 2026-09-06: a transcript write advances the session's
                // transcript version. The phone reads it to order published
                // transcripts; without a bump here, an empty snapshot built
                // before this append still looks as new as the rebuilt
                // transcript and would clear it on the phone.
                ChatSessionIndexFile.bumpTranscriptGeneration(in: &row)
                row["messageCount"] = .int(Int64(messageCount))
                if !preview.isEmpty { row["lastMessagePreview"] = .string(preview) }
                if let title,
                   Self.shouldReplaceSessionTitle(row["title"]) {
                    row["title"] = .string(title)
                }
                // §1.3, FIXED. This block used to read:
                //
                //     if source != "app" { row["source"] = .string(source) ... }
                //
                // i.e. the session index row's `source` was overwritten by
                // WHICHEVER SURFACE APPENDED MOST RECENTLY. `source` is
                // supposed to say what a conversation IS; last-writer-wins
                // made it say who touched it last, and every downstream reader
                // keyed on it (snapshot projection, iOS tab adoption, Doctor,
                // retention diagnostics) flapped with it.
                //
                // A row's `source` is now written ONCE, at creation, and never
                // restamped. What a later surface DOES contribute is the
                // per-message `source` on its own transcript row, which is
                // where per-turn provenance has always belonged and which the
                // envelope now makes complete.
                //
                // `sourceKey` keeps its backfill-only behavior (set when
                // absent, never overwritten) — it was already additive.
                if row["source"] == nil {
                    row["source"] = .string(source)
                }
                if row["sourceKey"] == nil, let sourceKey {
                    row["sourceKey"] = .string(sourceKey)
                }
                // Additive classification so readers stop having to infer a
                // conversation's nature from a field that describes traffic.
                // Backfill-only: a kind assigned once is not re-decided by a
                // later append, or we would have rebuilt the bug above.
                if row["threadKind"] == nil {
                    let existingSource: String = {
                        if case .string(let value)? = row["source"] { return value }
                        return source
                    }()
                    row["threadKind"] = .string(
                        ChatThreadKind.inferred(fromSource: existingSource).rawValue
                    )
                }
                updated = row
            }

            if updated == nil {
                var row: [String: JSONValue] = [
                    "id": .string(sessionId),
                    "title": .string(title ?? "New Chat"),
                    "source": .string(source),
                    "threadKind": .string(ChatThreadKind.inferred(fromSource: source).rawValue),
                    "createdAt": .string(timestamp),
                    "updatedAt": .string(syncedAt),
                    "archived": .bool(false),
                    "messageCount": .int(Int64(messageCount)),
                    "summary": .string(""),
                    ChatSessionIndexFile.transcriptGenerationKey: .int(1),
                ]
                if let sourceKey { row["sourceKey"] = .string(sourceKey) }
                if !preview.isEmpty { row["lastMessagePreview"] = .string(preview) }
                updated = row
            }

            if let updated {
                remaining.insert(updated, at: 0)
            }
            let out = try ChatSessionIndexFile.serializedData(for: remaining)
            // Sweep R4 item 5: was `out.write(to:options:.atomic)`. Atomic
            // replacement survives an app crash, but not power loss — the temp
            // file's bytes and the rename both sit unflushed. The transcript
            // rows this index describes are now durable (item 4), so the index
            // must be too, or a power cut leaves messages on disk that the
            // sidebar no longer lists. Same bytes, same lock, durable tail.
            try await persistence.writeDataAtomicDurable(out, to: sessionsPath)
            // Retention stays here, inside the lock and on every message, and
            // the perf audit's proposal to move or debounce it is REJECTED.
            // Two independent reasons:
            //
            // 1. Lock: it does its own read-modify-rewrite of this exact file,
            //    and its documented contract (ChatSessionRetention.swift:47)
            //    is that the caller holds the sessions lock. Outside it, it
            //    races the write two lines above.
            // 2. Prompt bytes: archiving REMOVES a row from `sessions.json`,
            //    and `SessionDigestProvider.latestPriorSession` (:293) picks
            //    the newest remaining row to render into the next session's
            //    prompt. Delaying an archive delays a row's disappearance from
            //    that candidate set, so a throttle is not byte-identical — it
            //    is a (small, self-healing) change in what the model sees.
            //
            // The waste the audit measured is real but lives one level down:
            // `pruneArchive` stats the whole archive tier on every pass, and
            // that part IS invisible to the prompt. Throttling belongs there,
            // in PersistenceCore, not at this call site.
            ChatSessionRetention.enforceBestEffort(
                dataRoot: dataRoot,
                now: retentionClock(),
                context: "ChatOrchestrationClient.syncSessionIndex"
            )
        }
    }

    /// 2026-09-06: advance a session's transcript version without touching any
    /// other index field. Used by transcript writers that rewrite the messages
    /// file without appending a message (compaction). Best effort: the version
    /// is remote-display ordering, never grounds to fail a turn that already
    /// wrote durable bytes.
    private func bumpSessionTranscriptGeneration(sessionId: String) async {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { return }
        let sessionsPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let persistence = self.persistence
        do {
            try await persistence.withFileLock(sessionsPath) {
                var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
                guard let index = rows.firstIndex(where: {
                    $0["id"] == .string(safeSessionId)
                }) else { return }
                ChatSessionIndexFile.bumpTranscriptGeneration(in: &rows[index])
                let out = try ChatSessionIndexFile.serializedData(for: rows)
                try await persistence.writeDataAtomicDurable(out, to: sessionsPath)
            }
        } catch {
            NSLog("ChatOrchestrationClient: transcript generation bump failed: \(error)")
        }
    }

    nonisolated static func errorText(_ error: ChatOrchestrationError) -> String {
        (error as LocalizedError).errorDescription ?? String(describing: error)
    }

    private nonisolated static func countJSONLLines(at path: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return 0 }
        defer { try? handle.close() }
        var count = 0
        var lineHasContent = false
        while true {
            guard let chunk = try? handle.read(upToCount: 256 * 1024),
                  !chunk.isEmpty else { break }
            for byte in chunk {
                if byte == 0x0A {
                    if lineHasContent { count += 1 }
                    lineHasContent = false
                } else if byte != 0x0D && byte != 0x20 && byte != 0x09 {
                    lineHasContent = true
                }
            }
        }
        if lineHasContent { count += 1 }
        return count
    }

    private nonisolated static func boundedRedactedToolReceipt(
        _ value: String,
        maximumCharacters: Int,
        label: String
    ) -> String {
        guard maximumCharacters > 0 else { return "" }
        let sourceCount = value.count
        guard sourceCount > maximumCharacters else {
            return ChatSecretRedactor.redactText(value)
        }
        // Redact a small guard window beyond the persisted boundary so a
        // secret beginning near the cutoff cannot be split into an unrecognized
        // fragment. Work remains O(the receipt cap), not O(tool output size).
        let redactionWindow = String(value.prefix(maximumCharacters + 512))
        let redacted = ChatSecretRedactor.redactText(redactionWindow)
        let omitted = sourceCount - maximumCharacters
        return String(redacted.prefix(maximumCharacters))
            + "\n[... \(label) truncated in transcript; \(omitted) characters omitted ...]"
    }

    private nonisolated static func previewText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(collapsed.prefix(180))
    }

    private nonisolated static func titleText(_ raw: String) -> String {
        let preview = previewText(raw)
        guard !preview.isEmpty else { return "New Chat" }
        return String(preview.prefix(60))
    }

    private nonisolated static func shouldReplaceSessionTitle(_ value: JSONValue?) -> Bool {
        guard case .string(let raw)? = value else { return true }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "New Chat"
    }

    private nonisolated static func messageSource(for surface: String) -> String {
        let normalized = surface
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "telegram":
            return "telegram"
        case "ios", "mobile", "iphone", "icloud":
            return "ios"
        case "app", "chat", "mac", "default", "":
            return "app"
        default:
            return normalized
        }
    }

    /// PARSE SITE 4 of 5, DELETED (one-thread-many-surfaces plan §1.2).
    ///
    /// This used to derive a session's `sourceKey` by asking whether the
    /// session id STRING started with `telegram:` or `ios:` — the same
    /// storage-key-as-identity mistake as the four trust sites, one layer down
    /// in persistence. It meant a `/new` Telegram session (a bare UUID) got no
    /// sourceKey at all, while an `app`-sourced row whose id happened to read
    /// `telegram:codex-probe` got one.
    ///
    /// The sourceKey now comes from the turn's own envelope — the routing
    /// facts the transport actually bound — or is left absent. Absent is
    /// honest; inferred was not. `app` remains the constant it always was,
    /// because a local Mac turn has one routing identity by construction.
    ///
    /// `sessionId` stays in the signature to keep the deletion legible at the
    /// call site rather than invisible.
    private nonisolated static func sessionSourceKey(for sessionId: String, source: String) -> String? {
        _ = sessionId
        if let bound = ChatToolSessionContext.envelope?.deliveryRoute?.sourceKey?
            .trimmingCharacters(in: .whitespacesAndNewlines), !bound.isEmpty {
            return bound
        }
        if let route = ChatToolSessionContext.replyRoute?.sourceKey?
            .trimmingCharacters(in: .whitespacesAndNewlines), !route.isEmpty {
            return route
        }
        return source == "app" ? "app" : nil
    }
}
