import Foundation
import NativeAgentCore
import PersistenceCore

/// One `cache_control` marker observed on an outgoing request body.
///
/// POSITIONS AND TTLs ONLY — never prompt bytes. Derived by WALKING THE
/// FINISHED BODY rather than by instrumenting the code that places markers,
/// so the row records what actually went on the wire, not what the placement
/// logic believed it did.
///
/// Anthropic renders `tools` → `system` → `messages`, and requires entries
/// with the LONGER TTL to appear before shorter ones. Reading a row's markers
/// in order is therefore enough to spot both failure modes behind a cache
/// regression: a breakpoint that never shipped, and a 5m marker sitting ahead
/// of a 1h one.
public struct LLMCacheMarker: Sendable, Equatable {
    /// `"tools[2]"`, `"system[1]"`, `"messages[7]"` — section plus index.
    public let position: String
    /// `"1h"` for an extended-TTL marker, `"5m"` for the default (which is
    /// the ABSENT `ttl` key on the wire, spelled out here so a row is
    /// readable without knowing that convention).
    public let ttl: String

    public init(position: String, ttl: String) {
        self.position = position
        self.ttl = ttl
    }

    var json: JSONValue {
        .object(["position": .string(position), "ttl": .string(ttl)])
    }
}

// MARK: - Conversation-prefix shape receipts (v2Prefix, 2026-09-01)
//
// ADDITIVE. The prefix shape is decided at the chat lane, several frames above
// any provider adapter, so it reaches the `llm.call` row the same way `surface`
// and `sessionId` do: a task-local bound for the turn, read at record time.
// Unbound → the row is byte-identical to before, which is what keeps every
// non-chat caller (dream, REM, executions) unchanged.
//
// SIZES AND DIGESTS ONLY. `prefixFingerprintSHA256` is a hash over the bytes
// that must be stable turn-to-turn for a provider cache to hit; it is the
// instrument that makes "did the prefix actually stay put" observable without
// putting one byte of prompt into a trace row.
public struct ConversationPrefixTelemetrySnapshot: Sendable, Equatable {
    public let shapeVersion: String
    public let prefixFingerprintSHA256: String
    public let historyMessageCount: Int
    public let historyMessageChars: Int
    public let volatileBlockChars: Int
    public let volatileDelivery: String
    public let windowCursorAdvanceCount: Int
    public let windowSlid: Bool
    /// PERMANENT DIAGNOSTIC. How many messages went on the wire, and a short
    /// digest of each of the first few — role plus serialized content, first 12
    /// hex of SHA-256.
    ///
    /// Head drift is the failure mode that keeps costing full-price input while
    /// every other receipt looks healthy: the cursor reports stable, the sizes
    /// look right, and the provider still re-reads the entire history because
    /// `messages[0]` is not the bytes it cached. SIZES CANNOT SHOW THAT — two
    /// different first messages have the same length. Digests can: two
    /// consecutive turns' rows simply differ where they should match.
    public let messageCount: Int
    public let messageDigests: [String]
    /// THE CACHE INVARIANT, made checkable. One digest per message of the
    /// cacheable prefix (everything before the current user message). Turn
    /// N+1 reused turn N's prefix iff turn N's list is a PREFIX of turn N+1's.
    /// `prefixFingerprintSHA256` hashes the whole prefix and therefore moves
    /// every turn by construction (each turn appends the last exchange), so
    /// it can never be compared between consecutive turns — this can.
    public let prefixMessageDigests: [String]
    /// The first few prefix messages, role plus the first 96 characters,
    /// so a digest that moved can be READ, not just counted. Bounded and
    /// payload-light by construction; the head of the prefix is persona and
    /// recollection, never a secret.
    public let headPreviews: [String]
    /// REQUEST-COMPONENT FINGERPRINTS. `prefixFingerprintSHA256` hashes the
    /// whole cacheable prefix, so when it moves it does not say WHICH part
    /// moved, and an audit is left inferring the cause from sizes. These three
    /// split it by component, so two consecutive turns' rows name the culprit
    /// on sight: the stable instruction prefix, the `tools` array, and the head
    /// of the projected history. Empty when the caller does not compute them.
    public let stablePrefixFingerprintSHA256: String
    public let toolsFingerprintSHA256: String
    public let historyHeadFingerprintSHA256: String
    /// Mid-conversation tool-change receipts (Anthropic structured lanes).
    /// nil on every lane that does not run the tool-change plan, so those rows
    /// decode exactly as before.
    public let toolChanges: ToolChangeReceipts?

    /// Sizes and one digest. `arrayFingerprintSHA256` hashes the `tools` ARRAY
    /// alone — the thing that must not move turn to turn — never the offered
    /// set, which is supposed to move.
    public struct ToolChangeReceipts: Sendable, Equatable {
        public let arrayFingerprintSHA256: String
        public let offeredCount: Int
        public let additionCount: Int
        public let removalCount: Int
        public let droppedUnknownCount: Int
        /// The session declaration's re-pin counter. The array is pinned per
        /// session, so this is the ONLY legitimate reason the array
        /// fingerprint moved between two turns of one session.
        public let declarationGeneration: Int

        public init(
            arrayFingerprintSHA256: String,
            offeredCount: Int,
            additionCount: Int,
            removalCount: Int,
            droppedUnknownCount: Int,
            declarationGeneration: Int = 0
        ) {
            self.arrayFingerprintSHA256 = arrayFingerprintSHA256
            self.offeredCount = offeredCount
            self.additionCount = additionCount
            self.removalCount = removalCount
            self.droppedUnknownCount = droppedUnknownCount
            self.declarationGeneration = declarationGeneration
        }

        public var payload: [String: JSONValue] {
            [
                "tools.arrayFingerprintSHA256": .string(arrayFingerprintSHA256),
                "tools.offeredCount": .int(Int64(offeredCount)),
                "tools.additionCount": .int(Int64(additionCount)),
                "tools.removalCount": .int(Int64(removalCount)),
                "tools.droppedUnknownCount": .int(Int64(droppedUnknownCount)),
                "tools.declarationGeneration": .int(Int64(declarationGeneration)),
            ]
        }
    }

    public init(
        shapeVersion: String,
        prefixFingerprintSHA256: String,
        historyMessageCount: Int,
        historyMessageChars: Int,
        volatileBlockChars: Int,
        volatileDelivery: String,
        windowCursorAdvanceCount: Int,
        windowSlid: Bool,
        messageCount: Int = 0,
        messageDigests: [String] = [],
        toolChanges: ToolChangeReceipts? = nil,
        prefixMessageDigests: [String] = [],
        stablePrefixFingerprintSHA256: String = "",
        toolsFingerprintSHA256: String = "",
        historyHeadFingerprintSHA256: String = "",
        headPreviews: [String] = []
    ) {
        self.shapeVersion = shapeVersion
        self.prefixFingerprintSHA256 = prefixFingerprintSHA256
        self.historyMessageCount = historyMessageCount
        self.historyMessageChars = historyMessageChars
        self.volatileBlockChars = volatileBlockChars
        self.volatileDelivery = volatileDelivery
        self.windowCursorAdvanceCount = windowCursorAdvanceCount
        self.windowSlid = windowSlid
        self.messageCount = messageCount
        self.messageDigests = messageDigests
        self.toolChanges = toolChanges
        self.prefixMessageDigests = prefixMessageDigests
        self.headPreviews = headPreviews
        self.stablePrefixFingerprintSHA256 = stablePrefixFingerprintSHA256
        self.toolsFingerprintSHA256 = toolsFingerprintSHA256
        self.historyHeadFingerprintSHA256 = historyHeadFingerprintSHA256
    }

    public var payload: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "shapeVersion": .string(shapeVersion),
            "prefixFingerprintSHA256": .string(prefixFingerprintSHA256),
            "historyMessageCount": .int(Int64(historyMessageCount)),
            "historyMessageChars": .int(Int64(historyMessageChars)),
            "volatileBlockChars": .int(Int64(volatileBlockChars)),
            "volatileDelivery": .string(volatileDelivery),
            "windowCursorAdvanceCount": .int(Int64(windowCursorAdvanceCount)),
            "windowSlid": .bool(windowSlid),
            "messageCount": .int(Int64(messageCount)),
            "messageDigests": .array(messageDigests.map { .string($0) }),
            "prefixMessageDigests": .array(prefixMessageDigests.map { .string($0) }),
            "headPreviews": .array(headPreviews.map { .string($0) }),
        ]
        if !stablePrefixFingerprintSHA256.isEmpty {
            out["component.stablePrefixSHA256"] = .string(stablePrefixFingerprintSHA256)
        }
        if !toolsFingerprintSHA256.isEmpty {
            out["component.toolsSHA256"] = .string(toolsFingerprintSHA256)
        }
        if !historyHeadFingerprintSHA256.isEmpty {
            out["component.historyHeadSHA256"] = .string(historyHeadFingerprintSHA256)
        }
        if let toolChanges {
            for (key, value) in toolChanges.payload { out[key] = value }
        }
        return out
    }
}

/// Write-once-per-turn mailbox for the receipts above.
///
/// A bare task-local value would have to be BOUND at the point the snapshot is
/// known — which is after the context build, inside the tool loop's own frame
/// — forcing the whole loop into a closure. The sink is bound EMPTY at the turn
/// boundary instead and filled in place, so the binding site and the knowing
/// site can be different frames.
public final class ConversationPrefixTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConversationPrefixTelemetrySnapshot?

    /// True when this binding exists to SHED an outer turn's receipts rather
    /// than to carry its own. Such a sink is permanently empty.
    public let marksRequestShapeUnmeasured: Bool

    /// The sink a secondary lane binds to detach the parent turn's shape. One
    /// shared value is safe because it is permanently empty by construction.
    public static let unmeasuredRequestShape =
        ConversationPrefixTelemetrySink(marksRequestShapeUnmeasured: true)

    public init(marksRequestShapeUnmeasured: Bool = false) {
        self.marksRequestShapeUnmeasured = marksRequestShapeUnmeasured
    }

    public func set(_ snapshot: ConversationPrefixTelemetrySnapshot) {
        // A shedding sink never holds a shape; filling it would re-create the
        // defect it exists to prevent.
        guard !marksRequestShapeUnmeasured else { return }
        lock.lock(); value = snapshot; lock.unlock()
    }

    public var current: ConversationPrefixTelemetrySnapshot? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

public enum ConversationPrefixTelemetry {
    /// Bound once per turn by the chat lane, alongside the shape task-local.
    @TaskLocal public static var sink: ConversationPrefixTelemetrySink?

    public static var current: ConversationPrefixTelemetrySnapshot? { sink?.current }

    /// Does the innermost binding say "this call's request shape is not the one
    /// in the sink"?
    public static var requestShapeUnmeasured: Bool { sink?.marksRequestShapeUnmeasured == true }

    /// Run a SECONDARY model call — one issued inside a chat turn but sending
    /// its own, unrelated request — with the turn's prefix receipts detached.
    ///
    /// Astra audit 2026-09-11 finding 7: the sink is bound for the WHOLE turn,
    /// and the memory manager's review runs inside it on a plain `await`, so its
    /// `llm.call` row inherited the chat prompt's receipts verbatim — 42 history
    /// messages, 54,089 history characters, the chat `headPreviews`, the tools
    /// and stable-prefix fingerprints — beside its own honest 475 input tokens.
    /// The numbers were right and the shape was a description of a prompt that
    /// call never sent.
    ///
    /// This keeps `turnId`, which is the correlation everyone actually wants,
    /// and replaces the borrowed shape with `requestShape: "unmeasured"` — said
    /// out loud, because plain absence is indistinguishable from a chat row
    /// recorded before the prefix was known.
    public static func withUnmeasuredRequestShape<T: Sendable>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $sink.withValue(.unmeasuredRequestShape) { try await body() }
    }
}

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
            // User, 2026-09-06: `intValue` clamps a malformed wire number to
            // Int.max, so plain `+` across three counters TRAPS on overflow —
            // the same provider input that used to crash the parse would crash
            // the sum instead. Saturate: a nonsense total is worth Int.max.
            // Every term is >= 0 here, so an overflow can only run positive.
            func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
                let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
                return overflowed ? Int.max : sum
            }
            var total = max(0, inputTokens ?? 0)
            total = saturatingAdd(total, max(0, cacheReadInputTokens ?? 0))
            total = saturatingAdd(total, max(0, cacheCreationInputTokens ?? 0))
            return total
        }
        return max(0, inputTokens ?? 0)
    }

    /// NSNumber-tolerant int read (JSONSerialization yields Int or Double
    /// depending on the wire literal).
    ///
    /// User, 2026-09-06: `Int(d)` TRAPS — not throws — on NaN, ±infinity and
    /// any magnitude outside `Int`'s range, and a usage field is provider
    /// input: `1e400` or `NaN` on the wire took the whole app down from a
    /// telemetry read. A malformed token count is worth nil or a clamp, never
    /// a crash.
    static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double {
            guard d.isFinite else { return nil }
            if d >= Double(Int.max) { return Int.max }
            if d <= Double(Int.min) { return Int.min }
            return Int(d)
        }
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
/// How heavy THIS turn's tool array actually is, in measured bytes.
///
/// Astra comb 4, lane3 finding 2: the per-tool breakdown the snapshot builds is
/// the first thing oversized-payload handling drops, so all 2,086 retained
/// `context.snapshot` rows carry totals without the array — and nothing anywhere
/// separated the 20 floor schemas from the 65 appended ones. The appended cost
/// was therefore unanswerable from the traces, and the only available arithmetic
/// (total input tokens ÷ 65) would have manufactured precision.
///
/// `tools.contract` now records the split directly, and the same totals are
/// folded onto every `llm.call` row of that turn, where the provider's REAL
/// `inputTokens` and `cacheReadInputTokens` sit — so the tools' share is a
/// division of two measured numbers on one row instead of an estimate.
///
/// These are SCHEMA-MATERIAL BYTES (name + description + parameter JSON, the
/// same convention `context.snapshot` uses), not HTTP body size and not tokens.
/// Nothing here retains a schema's content.
public enum ToolContractWeight {
    public struct Measurement: Sendable, Equatable {
        public let floorCount: Int
        public let appendedCount: Int
        public let floorBytes: Int
        public let appendedBytes: Int

        public init(floorCount: Int, appendedCount: Int, floorBytes: Int, appendedBytes: Int) {
            self.floorCount = floorCount
            self.appendedCount = appendedCount
            self.floorBytes = floorBytes
            self.appendedBytes = appendedBytes
        }

        public var wireBytes: Int { floorBytes + appendedBytes }
        /// nil rather than 0/0 when there is no tool material to divide.
        public var appendedShareOfWireBytes: Double? {
            wireBytes > 0 ? Double(appendedBytes) / Double(wireBytes) : nil
        }
    }

    /// Material bytes of one schema, the `context.snapshot` convention.
    public static func materialBytes(
        name: String, description: String, parameterBytes: Int
    ) -> Int {
        name.utf8.count + description.utf8.count + max(0, parameterBytes)
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var byTurn: [(turnId: String, measurement: Measurement)] = []
    /// Bounded on purpose: a handful of in-flight turns, never a growing map.
    private static let retainedTurns = 8

    public static func record(turnId: String, _ measurement: Measurement) {
        guard !turnId.isEmpty, turnId != "unknown" else { return }
        lock.lock()
        defer { lock.unlock() }
        byTurn.removeAll { $0.turnId == turnId }
        byTurn.append((turnId, measurement))
        if byTurn.count > retainedTurns { byTurn.removeFirst(byTurn.count - retainedTurns) }
    }

    public static func current(turnId: String) -> Measurement? {
        lock.lock()
        defer { lock.unlock() }
        return byTurn.last { $0.turnId == turnId }?.measurement
    }
}

// Appends ONE `llm.call` row per successful provider call to
// `<dataRoot>/traces/events.jsonl` — the SAME feed ChatToolDispatchTracer
// (ChatOrchestration/ChatToolDispatchTrace.swift) writes `tool.dispatch`
// rows to. PersistenceCore owns the shared path cap and flock so every writer
// observes one newest-N contract.
//
// PRIVACY (hard constraint, same as the tool tracer): rows carry token
// COUNTS, timings, model/provider/surface identifiers only — never prompt
// or completion content.
//
// Recording is non-fatal: an IO failure logs to stderr and the provider
// call's result reaches the caller unchanged.
public final class LLMCallTraceRecorder: @unchecked Sendable {
    /// Test injection. Production leaves nil and the path resolves through
    /// `PersistenceCore.defaultDataRoot()` at append time (so the env-var /
    /// stamped-repo / cwd-walkup resolution happens in the live process,
    /// not at adapter-construction time).
    private let dataRootOverride: URL?
    private let persistence = SwiftNativePersistenceCore()
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
        synchronousWrites: Bool? = nil
    ) {
        self.dataRootOverride = dataRootOverride
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
        status: String = "ok",
        /// Set ONLY when an enumerated model remap actually rewrote the
        /// caller's requested id (e.g. the OAuth-direct adapters' Claude→GPT
        /// table or an `openai/` namespace strip). Additive and optional:
        /// rows without it decode exactly as before.
        substitutedFrom: String? = nil,
        /// Every `cache_control` marker ACTUALLY present on the outgoing
        /// request body, in render order (tools → system → messages).
        /// Positions and TTLs only — no prompt bytes. This is what makes a
        /// cache-read regression provable per turn instead of inferred from
        /// token counts: a missing or mis-TTL'd breakpoint shows up here
        /// directly. Absent for callers that do not pass it, so those rows
        /// decode exactly as before.
        cacheMarkers: [LLMCacheMarker]? = nil
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
        // Additive, chat-only: absent for every caller that does not bind the
        // per-turn prefix receipts, so those rows decode exactly as before.
        //
        // A secondary lane running inside a chat turn (the memory manager) binds
        // a shedding sink, so it neither inherits the parent prompt's shape nor
        // goes silent about having one — Astra audit 2026-09-11 finding 7.
        if let prefix = ConversationPrefixTelemetry.current {
            for (key, value) in prefix.payload { payload[key] = value }
        } else if ConversationPrefixTelemetry.requestShapeUnmeasured {
            payload["requestShape"] = .string("unmeasured")
        }
        if let substitutedFrom, !substitutedFrom.isEmpty, substitutedFrom != model {
            payload["substitutedFrom"] = .string(substitutedFrom)
        }
        if let cacheMarkers {
            payload["cacheMarkerCount"] = .int(Int64(cacheMarkers.count))
            payload["cacheMarkers"] = .array(cacheMarkers.map(\.json))
        }
        // The turn's measured tool weight, next to the real token counts below
        // (lane3 finding 2). Absent for any caller with no tool contract, so
        // those rows decode exactly as before.
        // Only a call that carried the tool contract gets its weight; the
        // memory manager and moment extractor run tool-free under the same
        // parent turn and mark their shape unmeasured (e2 review r1).
        if !ConversationPrefixTelemetry.requestShapeUnmeasured,
           let weight = ToolContractWeight.current(turnId: turnId) {
            payload["tools.floorSchemaBytes"] = .int(Int64(weight.floorBytes))
            payload["tools.appendedSchemaBytes"] = .int(Int64(weight.appendedBytes))
            payload["tools.wireSchemaBytes"] = .int(Int64(weight.wireBytes))
        }
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
        if synchronousWrites {
            await Self.performWrite(
                row: row, path: path,
                persistence: persistence, provider: provider, model: model,
                usageReceipt: usageReceipt
            )
        } else {
            // Fire-and-forget: the path-owned append happens OFF the
            // provider call's return path. Telemetry rows are advisory —
            // a row lost to process exit is acceptable; added latency on
            // every LLM call is not.
            // 2026-07-21 audit: route the detached write through ONE shared
            // actor queue. Concurrent provider calls used to each spawn a
            // detached task that serialized on the events.jsonl flock in
            // nondeterministic order. The actor makes append order
            // deterministic FIFO across every recorder instance (adapters
            // hold their own recorder but share this queue), mirroring the
            // SessionUsageReceiptWriter pattern.
            let persistence = self.persistence
            Task.detached(priority: .utility) {
                await TraceWriteQueue.shared.enqueue(
                    row: row, path: path,
                    persistence: persistence, provider: provider, model: model,
                    usageReceipt: usageReceipt
                )
            }
        }
    }

    /// Single-process FIFO queue for fire-and-forget trace writes (see the
    /// 2026-07-21 audit note at the call site). One actor, shared across all
    /// recorder instances, so enqueue order is preserved before the shared
    /// path-owned append boundary serializes cross-process writers.
    private actor TraceWriteQueue {
        static let shared = TraceWriteQueue()

        func enqueue(
            row: JSONValue,
            path: URL,
            persistence: SwiftNativePersistenceCore,
            provider: String,
            model: String,
            usageReceipt: SessionUsageReceiptWrite?
        ) async {
            await LLMCallTraceRecorder.performWrite(
                row: row, path: path,
                persistence: persistence, provider: provider, model: model,
                usageReceipt: usageReceipt
            )
        }
    }

    private static func performWrite(
        row: JSONValue,
        path: URL,
        persistence: SwiftNativePersistenceCore,
        provider: String,
        model: String,
        usageReceipt: SessionUsageReceiptWrite?
    ) async {
        do {
            try await appendPathOwnedJSONL(
                row,
                to: path,
                using: persistence,
                logLabel: "LLMCallTraceRecorder"
            )
        } catch {
            FileHandle.standardError.write(
                Data("LLMCallTraceRecorder: trace append failed (\(provider)/\(model)): \(error)\n".utf8)
            )
        }
        if let usageReceipt {
            await SessionUsageReceiptWriter.shared.write(usageReceipt)
        }
    }

}
