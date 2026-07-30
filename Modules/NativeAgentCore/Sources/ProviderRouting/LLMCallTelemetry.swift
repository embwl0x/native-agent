import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - LLMUsage
//
// U1 step 1 (2026-06-10) — provider token-usage capture. Both providers
// report usage on every successful call; before this file the numbers were
// parsed-and-DISCARDED (Anthropic) or never parsed at all (OpenAI), so the
// cache_control / prompt_cache_key work in steps 3-4 had no measurement gate.
//
// Field names are Anthropic-canonical; the OpenAI parsers map equivalents:
//   - Responses API: input_tokens / output_tokens /
//     input_tokens_details.cached_tokens → cacheReadInputTokens
//   - Chat Completions: prompt_tokens / completion_tokens /
//     prompt_tokens_details.cached_tokens → cacheReadInputTokens
// OpenAI has no cache-creation counter (implicit caching) → nil.
public struct LLMUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadInputTokens: Int?
    public var cacheCreationInputTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    public var isEmpty: Bool {
        inputTokens == nil && outputTokens == nil
            && cacheReadInputTokens == nil && cacheCreationInputTokens == nil
    }

    /// Logical input occupancy for one provider request.
    ///
    /// Anthropic reports uncached, cache-read, and cache-created input as
    /// disjoint counters. OpenAI-compatible APIs report `inputTokens` as the
    /// total and expose cached tokens only as a subset, so adding that subset
    /// would double-count it.
    public func logicalInputTokens(provider: String) -> Int? {
        let providerID = provider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasAnyInput = inputTokens != nil
            || cacheReadInputTokens != nil
            || cacheCreationInputTokens != nil
        guard hasAnyInput else { return nil }

        if providerID.contains("anthropic") || cacheCreationInputTokens != nil {
            return max(0, inputTokens ?? 0)
                + max(0, cacheReadInputTokens ?? 0)
                + max(0, cacheCreationInputTokens ?? 0)
        }
        return max(0, inputTokens ?? 0)
    }

    /// NSNumber-tolerant int read (JSONSerialization yields Int or Double
    /// depending on the wire literal).
    static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        return nil
    }

    /// Anthropic Messages API `usage` object (non-streaming response body,
    /// or streaming `message_start.message.usage` / `message_delta.usage`).
    public static func fromAnthropic(_ obj: [String: Any]?) -> LLMUsage {
        guard let obj else { return LLMUsage() }
        return LLMUsage(
            inputTokens: intValue(obj["input_tokens"]),
            outputTokens: intValue(obj["output_tokens"]),
            cacheReadInputTokens: intValue(obj["cache_read_input_tokens"]),
            cacheCreationInputTokens: intValue(obj["cache_creation_input_tokens"])
        )
    }

    /// OpenAI Responses API `response.usage` (arrives on the
    /// `response.completed` SSE event).
    public static func fromOpenAIResponses(_ obj: [String: Any]?) -> LLMUsage {
        guard let obj else { return LLMUsage() }
        let details = obj["input_tokens_details"] as? [String: Any]
        return LLMUsage(
            inputTokens: intValue(obj["input_tokens"]),
            outputTokens: intValue(obj["output_tokens"]),
            cacheReadInputTokens: intValue(details?["cached_tokens"]),
            cacheCreationInputTokens: nil
        )
    }

    /// OpenAI Chat Completions `usage` (api-key adapter, non-streaming).
    public static func fromOpenAIChatCompletions(_ obj: [String: Any]?) -> LLMUsage {
        guard let obj else { return LLMUsage() }
        let details = obj["prompt_tokens_details"] as? [String: Any]
        return LLMUsage(
            inputTokens: intValue(obj["prompt_tokens"]),
            outputTokens: intValue(obj["completion_tokens"]),
            cacheReadInputTokens: intValue(details?["cached_tokens"]),
            cacheCreationInputTokens: nil
        )
    }

    /// Streaming accumulator: Anthropic splits usage across `message_start`
    /// (input + cache fields) and `message_delta` (output_tokens). Later
    /// non-nil fields win; nil never clobbers a captured value.
    public mutating func merge(_ other: LLMUsage) {
        if let v = other.inputTokens { inputTokens = v }
        if let v = other.outputTokens { outputTokens = v }
        if let v = other.cacheReadInputTokens { cacheReadInputTokens = v }
        if let v = other.cacheCreationInputTokens { cacheCreationInputTokens = v }
    }
}

public extension Notification.Name {
    /// Posted after the exact per-session provider usage receipt is durable.
    /// `object` is the normalized chat session id.
    static let nativeAgentSessionProviderUsageDidChange = Notification.Name(
        "NativeAgent.sessionProviderUsageDidChange"
    )
}

// MARK: - LLMCallTraceRecorder
//
// Appends ONE `llm.call` row per successful provider call to
// `<dataRoot>/traces/events.jsonl` — the SAME feed ChatToolDispatchTracer
// (ChatOrchestration/ChatToolDispatchTrace.swift) writes `tool.dispatch`
// rows to. The writer is duplicated here rather than shared because the
// module graph points the other way (ChatOrchestration depends on
// ProviderRouting); the flock + non-fatal + tail-trim discipline is a
// 1:1 mirror of ChatToolDispatchTracer so the two writers stay
// interleaving-safe on the same file.
//
// PRIVACY (hard constraint, same as the tool tracer): rows carry token
// COUNTS, timings, model/provider/surface identifiers only — never prompt
// or completion content.
//
// Recording is non-fatal: an IO failure logs to stderr and the provider
// call's result reaches the caller unchanged.
public final class LLMCallTraceRecorder: @unchecked Sendable {
    /// Cap mirrors ChatToolDispatchTracer.maxTraceLines.
    static let maxTraceLines = 5000
    // Public: referenced from the public init's default argument value.
    public static let defaultTrimCheckInterval = 32
    private static let trimByteTrigger = 4 * 1024 * 1024
    private static let counterLock = NSLock()
    // nonisolated(unsafe): every access is guarded by counterLock.
    nonisolated(unsafe) private static var appendCounter = 0

    /// Test injection. Production leaves nil and the path resolves through
    /// `PersistenceCore.defaultDataRoot()` at append time (so the env-var /
    /// stamped-repo / cwd-walkup resolution happens in the live process,
    /// not at adapter-construction time).
    private let dataRootOverride: URL?
    private let persistence = SwiftNativePersistenceCore()
    private let trimCheckInterval: Int
    /// Review nit (2026-06-10): the flock + append + possible tail-trim used
    /// to sit ON the provider call's return path — pure latency coupling for
    /// a telemetry row. Production now writes fire-and-forget on a detached
    /// utility task; tests need the write completed when `record` returns,
    /// so the seam is: explicit `synchronousWrites` wins, otherwise a
    /// non-nil `dataRootOverride` (itself a test-only injection) implies
    /// synchronous. Same inject-a-synchronous-mode seam as the rest of the
    /// trace/persistence stack.
    private let synchronousWrites: Bool

    public init(
        dataRootOverride: URL? = nil,
        trimCheckInterval: Int = LLMCallTraceRecorder.defaultTrimCheckInterval,
        synchronousWrites: Bool? = nil
    ) {
        self.dataRootOverride = dataRootOverride
        self.trimCheckInterval = max(1, trimCheckInterval)
        self.synchronousWrites = synchronousWrites ?? (dataRootOverride != nil)
    }

    private var tracesPath: URL {
        (dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private struct SessionUsageReceiptWrite: Sendable {
        let path: URL
        let sessionId: String
        let value: JSONValue
        let recordedAtEpochMicros: Int64
    }

    private actor SessionUsageReceiptWriter {
        static let shared = SessionUsageReceiptWriter()


        private let persistence = SwiftNativePersistenceCore()

        func write(_ pending: SessionUsageReceiptWrite) async {
            let existing = await persistence.readJSON(
                pending.path,
                defaultValue: .object([:])
            )
            if case .object(let object) = existing,
               case .int(let existingOrder)? = object["recordedAtEpochMicros"],
               existingOrder > pending.recordedAtEpochMicros {
                return
            }

            var persistedValue = pending.value
            if case .object(let existingObject) = existing,
               case .object(let pendingObject) = pending.value,
               case .string(let existingModel)? = existingObject["model"],
               case .string(let pendingModel)? = pendingObject["model"],
               existingModel.caseInsensitiveCompare(pendingModel) == .orderedSame,
               case .int(let existingTokens)? = existingObject["lastRequestInputTokens"],
               case .int(let pendingTokens)? = pendingObject["lastRequestInputTokens"] {
                var nextObject = pendingObject
                let isSameBoundTurn: Bool = {
                    guard case .string(let existingTurn)? = existingObject["turnId"],
                          case .string(let pendingTurn)? = pendingObject["turnId"],
                          pendingTurn != "unknown" else {
                        return false
                    }
                    return existingTurn == pendingTurn
                }()
                let baselineTokens: Int64
                if isSameBoundTurn,
                   case .int(let preservedBaseline)? = existingObject["previousTurnInputTokens"] {
                    // Tool loops can make several provider requests in one
                    // turn. Keep comparing the final request to the preceding
                    // turn instead of resetting the delta after each tool.
                    baselineTokens = preservedBaseline
                } else {
                    baselineTokens = existingTokens
                }
                nextObject["previousTurnInputTokens"] = .int(baselineTokens)
                nextObject["turnInputDeltaTokens"] = .int(pendingTokens - baselineTokens)
                persistedValue = .object(nextObject)
            }
            do {
                try await persistence.writeJSON(persistedValue, to: pending.path)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .nativeAgentSessionProviderUsageDidChange,
                        object: pending.sessionId
                    )
                }
            } catch {
                FileHandle.standardError.write(
                    Data("LLMCallTraceRecorder: session usage receipt write failed: \(error)\n".utf8)
                )
            }
        }
    }

    /// Append one `llm.call` row. `surface` defaults to the task-local
    /// LLMCallContext.surface (bound by SwiftNativeLLMClient); pass
    /// explicitly only in tests.
    public func record(
        provider: String,
        model: String,
        streaming: Bool,
        usage: LLMUsage?,
        ttftMs: Int?,
        durationMs: Int,
        status: String = "ok"
    ) async {
        let surface = LLMCallContext.surface ?? "unknown"
        // Turn Inspector W1: tag with the per-turn trace id so the Inspector
        // can join this llm.call to the rest of the turn's story. Unbound
        // (non-turn caller — a background loop's LLM call) → "unknown".
        let turnId = TurnTraceContext.turnId ?? "unknown"
        let recordedAt = Date()
        let recordedAtISO = ISO8601DateFormatter().string(from: recordedAt)
        let receiptOrder = Int64(recordedAt.timeIntervalSince1970 * 1_000_000)
        var payload: [String: JSONValue] = [
            "provider": .string(provider),
            "model": .string(model),
            "surface": .string(surface),
            "streaming": .bool(streaming),
            "durationMs": .int(Int64(durationMs)),
            "turnId": .string(turnId),
        ]
        if let ttftMs { payload["ttftMs"] = .int(Int64(ttftMs)) }
        if let usage {
            if let v = usage.inputTokens { payload["inputTokens"] = .int(Int64(v)) }
            if let v = usage.outputTokens { payload["outputTokens"] = .int(Int64(v)) }
            if let v = usage.cacheReadInputTokens {
                payload["cacheReadInputTokens"] = .int(Int64(v))
            }
            if let v = usage.cacheCreationInputTokens {
                payload["cacheCreationInputTokens"] = .int(Int64(v))
            }
        }
        // Turn Inspector W1: mirror onto the in-process bus (fire-and-forget,
        // drop-on-backpressure, NEVER awaited) + the per-day turn_traces
        // persist lane. Skipped entirely when no turn is bound. The `payload`
        // here is already counts/timings/identifiers only — same redaction
        // discipline as the events.jsonl row (no prompt/completion bodies).
        TurnTraceBus.fireFromContext(
            kind: "llm.call",
            sessionId: LLMCallContext.sessionId,
            surface: surface,
            payload: .object(payload)
        )
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()),
            "kind": .string("llm.call"),
            "title": .string(model),
            "status": .string(status),
            "payload": .object(payload),
            "createdAt": .string(recordedAtISO),
        ])
        let usageReceipt: SessionUsageReceiptWrite? = {
            guard status == "ok",
                  let usage,
                  let logicalInputTokens = usage.logicalInputTokens(provider: provider),
                  let rawSessionID = LLMCallContext.sessionId,
                  let sessionID = NativeAgentChatSessionID.normalizedPathComponent(rawSessionID) else {
                return nil
            }
            let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let path = root
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("session_state", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("provider_usage.json")
            var value: [String: JSONValue] = [
                "schema": .string("session.provider_usage.v1"),
                "sessionId": .string(sessionID),
                "turnId": .string(turnId),
                "surface": .string(surface),
                "provider": .string(provider),
                "model": .string(model),
                "lastRequestInputTokens": .int(Int64(logicalInputTokens)),
                "recordedAt": .string(recordedAtISO),
                "recordedAtEpochMicros": .int(receiptOrder),
            ]
            if let count = usage.inputTokens {
                value["reportedInputTokens"] = .int(Int64(max(0, count)))
            }
            if let count = usage.cacheReadInputTokens {
                value["cacheReadInputTokens"] = .int(Int64(max(0, count)))
            }
            if let count = usage.cacheCreationInputTokens {
                value["cacheCreationInputTokens"] = .int(Int64(max(0, count)))
            }
            return SessionUsageReceiptWrite(
                path: path,
                sessionId: sessionID,
                value: .object(value),
                recordedAtEpochMicros: receiptOrder
            )
        }()
        let path = tracesPath
        let counterTripped: Bool = {
            Self.counterLock.lock()
            defer { Self.counterLock.unlock() }
            Self.appendCounter &+= 1
            return Self.appendCounter % trimCheckInterval == 0
        }()
        if synchronousWrites {
            await Self.performWrite(
                row: row, path: path, counterTripped: counterTripped,
                persistence: persistence, provider: provider, model: model,
                usageReceipt: usageReceipt
            )
        } else {
            // Fire-and-forget: the flock/append/trim happens OFF the
            // provider call's return path. Telemetry rows are advisory —
            // a row lost to process exit is acceptable; added latency on
            // every LLM call is not.
            // 2026-07-21 audit: route the detached write through ONE shared
            // actor queue. Concurrent provider calls used to each spawn a
            // detached task that serialized on the events.jsonl flock in
            // nondeterministic order — a racing trimLocked could drop a
            // sibling's fresh row. The actor makes append/trim order
            // deterministic FIFO across every recorder instance (adapters
            // hold their own recorder but share this queue), mirroring the
            // SessionUsageReceiptWriter pattern.
            let persistence = self.persistence
            Task.detached(priority: .utility) {
                await TraceWriteQueue.shared.enqueue(
                    row: row, path: path, counterTripped: counterTripped,
                    persistence: persistence, provider: provider, model: model,
                    usageReceipt: usageReceipt
                )
            }
        }
    }

    /// Single-process FIFO queue for fire-and-forget trace writes (see the
    /// 2026-07-21 audit note at the call site). One actor, shared across all
    /// recorder instances, so the append→trim sequence for one row is never
    /// interleaved with another row's flock turn.
    private actor TraceWriteQueue {
        static let shared = TraceWriteQueue()

        func enqueue(
            row: JSONValue,
            path: URL,
            counterTripped: Bool,
            persistence: SwiftNativePersistenceCore,
            provider: String,
            model: String,
            usageReceipt: SessionUsageReceiptWrite?
        ) async {
            await LLMCallTraceRecorder.performWrite(
                row: row, path: path, counterTripped: counterTripped,
                persistence: persistence, provider: provider, model: model,
                usageReceipt: usageReceipt
            )
        }
    }

    private static func performWrite(
        row: JSONValue,
        path: URL,
        counterTripped: Bool,
        persistence: SwiftNativePersistenceCore,
        provider: String,
        model: String,
        usageReceipt: SessionUsageReceiptWrite?
    ) async {
        do {
            try await persistence.withFileLock(path) {
                try await persistence.appendJSONL(row, to: path)
                if counterTripped || Self.fileSize(path) > Self.trimByteTrigger {
                    Self.trimLocked(path, keepLast: Self.maxTraceLines)
                }
            }
        } catch {
            FileHandle.standardError.write(
                Data("LLMCallTraceRecorder: trace append failed (\(provider)/\(model)): \(error)\n".utf8)
            )
        }
        if let usageReceipt {
            await SessionUsageReceiptWriter.shared.write(usageReceipt)
        }
    }

    private static func fileSize(_ path: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else {
            return 0
        }
        return (attrs[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Tail-trim to `keepLast` physical lines. Caller MUST hold the
    /// events.jsonl flock. Mirrors ChatToolDispatchTracer.trimLocked.
    private static func trimLocked(_ path: URL, keepLast: Int) {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count > keepLast else { return }
        let trimmed = lines.suffix(keepLast).joined(separator: "\n") + "\n"
        let tmp = path.appendingPathExtension("tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let out = trimmed.data(using: .utf8) else { return }
        do {
            try out.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } catch {
            FileHandle.standardError.write(
                Data("LLMCallTraceRecorder: trace trim failed: \(error)\n".utf8)
            )
        }
    }
}
