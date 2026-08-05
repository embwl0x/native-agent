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
        onNotice: (@Sendable (String, String) async -> Void)? = nil
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
        let safeInputJSON = Self.boundedRedactedToolReceipt(
            inputJSON,
            maximumCharacters: Self.persistedToolInputMaximumCharacters,
            label: "tool input"
        )
        let safeResultSummary = Self.boundedRedactedToolReceipt(
            resultSummary,
            maximumCharacters: Self.persistedToolResultMaximumCharacters,
            label: "tool result"
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
        let metadata: [String: JSONValue] = [
            "kind": .string("tool_use"),
            "toolName": .string(toolName),
            "inputJSON": .string(safeInputJSON),
            "resultSummary": .string(safeResultSummary),
            "ok": .bool(ok),
        ]
        record["metadata"] = .object(metadata)
        // Locked: see appendPartial — protects against the compactor/distiller
        // locked rewrite dropping a concurrent append. (Immutable binding: a
        // @Sendable closure cannot capture the mutable `record`.)
        let toolRow: JSONValue = .object(record)
        try await persistence.withFileLock(path) {
            try await persistence.appendJSONL(toolRow, to: path)
        }
        await observeCognitiveTool(
            sessionId: sessionId,
            runId: runId,
            toolName: toolName,
            resultSummary: safeResultSummary,
            ok: ok,
            cognitiveResult: cognitiveResult,
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

    /// User-visible message for the model. Attachments are NO LONGER
    /// stringified into the text — vision-capable adapters consume them as
    /// native image content blocks (see `imageBlocksFromAttachments` and
    /// `TurnContext.imageBlocks`); non-vision adapters get an honest note
    /// at the default-flatten tripwire (LLMClient+Real.swift). This helper
    /// is kept as a passthrough so the few remaining call sites can be
    /// retired incrementally without a churned diff.
    nonisolated static func composeMessage(
        message: String,
        attachments: [MultimodalAttachment]
    ) -> String {
        return message
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
        surface: String
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
            attachments: [],
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
                let priorTurnTraceID = Self.messageTurnTraceID(in: rows[index])
                var replaced = rows
                replaced[index] = messageRow
                try Self.writeJSONLAtomically(replaced, to: path)
                // A replacement is row-count neutral by construction: one row
                // swapped in place of exactly one match. `writeJSONLAtomically`
                // emits one non-blank line per row, which is precisely what
                // `countJSONLLines` counts.
                ChatTranscriptLineCountCache.shared.record(count: replaced.count, at: path)
                return priorTurnTraceID
            } else {
                let priorCount = ChatTranscriptLineCountCache.shared.count(
                    at: path,
                    recount: Self.countJSONLLines(at:)
                )
                try await persistence.appendJSONL(messageRow, to: path)
                // `appendJSONL` writes exactly one serialized line plus "\n".
                ChatTranscriptLineCountCache.shared.record(count: priorCount + 1, at: path)
                return nil
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
        try payload.write(to: path, options: .atomic)
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
        let compactor = ChatSessionAutocompactor(
            dataRoot: dataRoot,
            config: autocompactionConfig,
            now: clock
        )
        let outcome = try await compactor.compactIfNeeded(
            sessionId: sessionId,
            model: model,
            surface: surface,
            runId: runId
        )
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
        return outcome
    }

    static func shouldPersistFailureMessage(surface: String) -> Bool {
        surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "telegram"
    }

    static func resolveSessionId(_ sessionId: String?) throws -> String {
        let raw = sessionId ?? UUID().uuidString
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
            sourceClass = .userStated
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
        // Chat workload class comes from surface provenance, never from topic
        // words. An ordinary user asking about the scheduler/doctor/observatory
        // is still a live turn. The bridge's explicit provenance prefix may
        // classify diagnostic traffic as debug/verification; the runtime then
        // carries that class through the correlated run to tools and reply.
        let inferredTurnKind = CognitiveTurnKind.inferred(fromSignals: [
            source,
            redactedSummary,
        ])
        let turnKind: CognitiveTurnKind = switch inferredTurnKind {
        case .debug, .verification: inferredTurnKind
        case .live, .system: .live
        }
        let subject: CognitiveSubjectReference
        if normalizedRole == "assistant", kind == .assistantTurnCompleted {
            subject = CognitiveSubjectReference(
                type: "chat.assistant_turn",
                id: "\(sessionId):\(messageId)"
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
                id: "\(sessionId):\(messageId)"
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

    private func observeCognitiveTool(
        sessionId: String,
        runId: String?,
        toolName: String,
        resultSummary: String,
        ok: Bool,
        cognitiveResult: ChatToolOutcome.CognitiveResult?,
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
            let inputPreview = Self.compactCognitiveJSON(input, maxCharacters: 240)
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
            let outputPreview = Self.compactCognitiveJSON(output, maxCharacters: 300)
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

    nonisolated private static func compactCognitiveJSON(_ value: JSONValue, maxCharacters: Int) -> String {
        let serialized = (try? value.serialize(pretty: false)) ?? ""
        return String(serialized.prefix(max(0, maxCharacters)))
    }

    nonisolated private static func cognitiveDigest(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private nonisolated static func stringValue(_ value: JSONValue) -> String? {
        if case .string(let string) = value { return string }
        return nil
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
        let messageCount = ChatTranscriptLineCountCache.shared.count(
            at: messagesPath,
            recount: Self.countJSONLLines(at:)
        )
        let persistence = self.persistence
        let retentionClock = self.clock
        try await persistence.withFileLock(sessionsPath) {
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
                row["updatedAt"] = .string(timestamp)
                row["messageCount"] = .int(Int64(messageCount))
                if !preview.isEmpty { row["lastMessagePreview"] = .string(preview) }
                if let title,
                   Self.shouldReplaceSessionTitle(row["title"]) {
                    row["title"] = .string(title)
                }
                if source != "app" {
                    row["source"] = .string(source)
                    if row["sourceKey"] == nil, let sourceKey {
                        row["sourceKey"] = .string(sourceKey)
                    }
                }
                updated = row
            }

            if updated == nil {
                var row: [String: JSONValue] = [
                    "id": .string(sessionId),
                    "title": .string(title ?? "New Chat"),
                    "source": .string(source),
                    "createdAt": .string(timestamp),
                    "updatedAt": .string(timestamp),
                    "archived": .bool(false),
                    "messageCount": .int(Int64(messageCount)),
                    "summary": .string(""),
                ]
                if let sourceKey { row["sourceKey"] = .string(sourceKey) }
                if !preview.isEmpty { row["lastMessagePreview"] = .string(preview) }
                updated = row
            }

            if let updated {
                remaining.insert(updated, at: 0)
            }
            let out = try ChatSessionIndexFile.serializedData(for: remaining)
            try out.write(to: sessionsPath, options: .atomic)
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
            _ = try? ChatSessionRetention.enforce(dataRoot: dataRoot, now: retentionClock())
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

    private nonisolated static func sessionSourceKey(for sessionId: String, source: String) -> String? {
        switch source {
        case "telegram":
            return sessionId.hasPrefix("telegram:") ? sessionId : nil
        case "ios":
            return sessionId.hasPrefix("ios:") ? sessionId : nil
        case "app":
            return "app"
        default:
            return nil
        }
    }
}
