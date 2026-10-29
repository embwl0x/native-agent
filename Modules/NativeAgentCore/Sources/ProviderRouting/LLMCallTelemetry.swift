import Foundation
import NativeAgentShared
import NativeAgentCore
import os
import PersistenceCore
import TurnTrace
// Blueprint: | `LLMCallTelemetry.swift` | `LLMCallTraceRecorder`; successful/failed call receipts with full/delta context byte sizes, keyframe status, purpose, timing, provider identity and redacted underlying failure detail; memory, digest and probe telemetry retain their own surfaces when routing inherits Chat; a bound `spent` tally adds each row's usage (their turn's own rounds) |

public extension Notification.Name {
    /// Posted after the exact per-session provider usage receipt is durable.
    /// `object` is the normalized chat session id.
    static let nativeAgentSessionProviderUsageDidChange = Notification.Name(
        "NativeAgent.sessionProviderUsageDidChange"
    )
}

// TurnTrace owns bound model calls; standalone calls use traces/events.jsonl.
// Session usage receipts remain independently owned by their current writer.
//
// Preview privacy follows TurnTraceRedactor; model-call receipts can retain headPreviews.
// Recording failures are diagnostic and leave the provider result unchanged.
public final class LLMCallTraceRecorder: @unchecked Sendable {
    /// One `llm.call` row per provider request. The router binds a fresh
    /// receipt as the request's identity; the first row written under it (the
    /// adapter's or the router's failure row) claims it, leaves its `ttftMs`
    /// there for the router's lifecycle, and any later row drops.
    @TaskLocal public static var requestRecorded: OSAllocatedUnfairLock<Receipt>?
    /// What her turn's own model rounds read and wrote, in tokens: the stem
    /// binds it around its calls, and each row's usage adds to it.
    @TaskLocal public static var spent: OSAllocatedUnfairLock<Int>?

    public struct Receipt: Sendable {
        public var recorded = false
        public var ttftMs: Int?
        /// What the request asked the provider to read, set before it is sent.
        public var requestBytes: Int?
        public init() {}
    }

    /// An explicit root overrides live data-root resolution at append time.
    private let dataRootOverride: URL?

    public init(dataRootOverride: URL? = nil) {
        self.dataRootOverride = dataRootOverride
    }

    private struct SessionUsageReceiptWrite: Sendable {
        let path: URL
        let sessionId: String
        let value: JSONValue
        let recordedAtEpochMicros: Int64
    }

    private actor SessionUsageReceiptWriter {
        static let shared = SessionUsageReceiptWriter()



        func write(_ pending: SessionUsageReceiptWrite) async {
            do {
                try await SwiftNativePersistenceCore.withFileLock(pending.path) {
                    await self.writeLocked(pending)
                }
            } catch {
                ModuleLog(category: "LLMCallTraceRecorder")("session usage receipt lock failed: \(error)", level: .error)
            }
        }

        private func writeLocked(_ pending: SessionUsageReceiptWrite) async {
            let existing: JSONValue
            do {
                existing = try await SwiftNativePersistenceCore.readJSON(pending.path, ifMissing: .object([:]))
            } catch {
                // Never write over a receipt that did not read back.
                ModuleLog(category: "LLMCallTraceRecorder")("session usage receipt read failed: \(error)", level: .error)
                return
            }
            // Counts on disk are evidence, not trusted arithmetic operands.
            // Preserve a damaged receipt for repair rather than replacing it.
            if case .object(let object) = existing {
                for field in ["lastRequestInputTokens", "previousTurnInputTokens"] {
                    if let value = object[field] {
                        guard case .int(let count) = value, count >= 0 else {
                            ModuleLog(category: "LLMCallTraceRecorder")("invalid \(field) in \(pending.path.path); receipt preserved", level: .error)
                            return
                        }
                    }
                }
            }
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
                let (delta, overflow) = pendingTokens.subtractingReportingOverflow(baselineTokens)
                guard pendingTokens >= 0, !overflow else {
                    ModuleLog(category: "LLMCallTraceRecorder")("invalid input delta for \(pending.path.path); receipt preserved", level: .error)
                    return
                }
                nextObject["previousTurnInputTokens"] = .int(baselineTokens)
                nextObject["turnInputDeltaTokens"] = .int(delta)
                persistedValue = .object(nextObject)
            }
            do {
                try await SwiftNativePersistenceCore.writeJSON(persistedValue, to: pending.path)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .nativeAgentSessionProviderUsageDidChange,
                        object: pending.sessionId
                    )
                }
            } catch {
                ModuleLog(category: "LLMCallTraceRecorder")("session usage receipt write failed: \(error)", level: .error)
            }
        }
    }

    /// Append one `llm.call` row under the task-local `LLMCallContext.surface`.
    public func record(
        requestBody: Data? = nil,
        provider: String,
        model: String,
        streaming: Bool,
        usage: LLMUsage?,
        ttftMs: Int?,
        durationMs: Int,
        status: String = "ok",
        /// Set ONLY when an enumerated model remap actually rewrote the
        /// caller's requested id (e.g. the OAuth-direct adapters' Claude→GPT
        /// table or an `openai/` namespace strip).
        substitutedFrom: String? = nil,
        /// Every `cache_control` marker ACTUALLY present on the outgoing
        /// request body, in render order (tools → system → messages).
        /// Positions and TTLs only, never prompt bytes; absent unless supplied.
        cacheMarkers: [LLMCacheMarker]? = nil,
        /// Provider stop reason (end_turn, max_tokens, tool_use…). Additive.
        stopReason: String? = nil,
        errorDetail: String? = nil
    ) async {
        if let claim = Self.requestRecorded, claim.withLock({ receipt in
            defer { receipt.recorded = true }
            if !receipt.recorded { receipt.ttftMs = ttftMs }
            return receipt.recorded
        }) { return }
        var accountingOverflow = false
        if let usage, let spent = Self.spent {
            let (tokens, callOverflow) = (usage.logicalInputTokens(provider: provider) ?? 0)
                .addingReportingOverflow(max(0, usage.outputTokens ?? 0))
            accountingOverflow = spent.withLock { total in
                let (sum, aggregateOverflow) = total.addingReportingOverflow(callOverflow ? Int.max : tokens)
                total = aggregateOverflow ? Int.max : sum
                return callOverflow || aggregateOverflow
            }
        }
        let purpose = LLMCallContext.purpose
        let routedSurface = LLMCallContext.surface ?? "unknown"
        let surface: String = {
            switch purpose {
            case "memory_interpret", "memory_held", "recall_judge", "kind_backfill": return "memory"
            case "digest", "probe": return purpose
            default: return routedSurface
            }
        }()
        // Bound calls join the turn's trace; background calls retain an unknown turn id.
        let turnId = TurnTraceContext.turnId ?? "unknown"
        let recordedAt = Date()
        let recordedAtISO = ISO8601DateFormatter().string(from: recordedAt)
        let receiptOrder = Int64(recordedAt.timeIntervalSince1970 * 1_000_000)
        var payload: [String: JSONValue] = [
            "provider": .string(provider),
            "model": .string(model),
            "surface": .string(surface),
            "purpose": .string(purpose),
            "streaming": .bool(streaming),
            "durationMs": .int(Int64(durationMs)),
            "status": .string(status),
            "turnId": .string(turnId),
        ]
        if let ttftMs { payload["ttftMs"] = .int(Int64(ttftMs)) }
        if accountingOverflow { payload["tokenAccountingOverflow"] = .bool(true) }
        if let bytes = Self.requestRecorded?.withLock({ $0.requestBytes }) { payload["requestBytes"] = .int(Int64(bytes)) }
        // How the adapter's streamMessages delivered this call; absent on
        // calls that did not come through streamMessages.
        if let streamKind = LLMMessagesStreamKind.current {
            payload["streamKind"] = .string(streamKind.rawValue)
        }
        // Unbound callers omit prefix receipts; secondary calls explicitly report their shape as unmeasured.
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
        // Secondary calls carry their own unmeasured request binding.
        if !ConversationPrefixTelemetry.requestShapeUnmeasured,
           let weight = ConversationPrefixTelemetry.sink?.toolWeight {
            payload["tools.floorSchemaBytes"] = .int(Int64(weight.floorBytes))
            payload["tools.appendedSchemaBytes"] = .int(Int64(weight.appendedBytes))
            payload["tools.wireSchemaBytes"] = .int(Int64(weight.wireBytes))
        }
        if let requestBody, let prefix = ConversationPrefixTelemetry.current {
            do {
                payload.merge(try RequestPrefixReceipt.payload(requestBody, prefix: prefix)) { _, actual in actual }
            } catch {
                payload["prefixReceiptError"] = .string(error.localizedDescription)
            }
        }
        if let stopReason { payload["stopReason"] = .string(stopReason) }
        if let errorDetail {
            payload["error"] = .string(String(ContextSecretContentPolicy.redactedFragment(errorDetail).prefix(4096)))
        }
        if let usage {
            payload["additiveInputCounters"] = .bool(usage.additiveInputCounters)
            if let v = usage.inputTokens { payload["inputTokens"] = .int(Int64(v)) }
            if let v = usage.outputTokens { payload["outputTokens"] = .int(Int64(v)) }
            if let v = usage.cacheReadInputTokens {
                payload["cacheReadInputTokens"] = .int(Int64(v))
            }
            if let v = usage.cacheCreationInputTokens {
                payload["cacheCreationInputTokens"] = .int(Int64(v))
            }
            if let v = usage.cacheWriteInputTokens { payload["cacheWriteInputTokens"] = .int(Int64(v)) }
            if let v = usage.cacheWrite30mInputTokens { payload["cacheWrite30mInputTokens"] = .int(Int64(v)) }
            if let v = usage.cacheWrite12hInputTokens { payload["cacheWrite12hInputTokens"] = .int(Int64(v)) }
        }
        // Bound calls use the bus and daily trace; unbound calls use the shared feed.
        TurnTraceBus.fireFromContext(
            kind: "llm.call",
            sessionId: LLMCallContext.sessionId,
            surface: surface,
            payload: .object(payload)
        )
        let row: TurnTraceEvent? = TurnTraceContext.turnId == nil ? TurnTraceEvent(
            kind: "llm.call", title: model, status: status,
            payload: .object(payload), createdAt: recordedAtISO
        ) : nil
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
                "additiveInputCounters": .bool(usage.additiveInputCounters),
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
            if let count = usage.cacheWriteInputTokens { value["cacheWriteInputTokens"] = .int(Int64(max(0, count))) }
            if let count = usage.cacheWrite30mInputTokens { value["cacheWrite30mInputTokens"] = .int(Int64(max(0, count))) }
            if let count = usage.cacheWrite12hInputTokens { value["cacheWrite12hInputTokens"] = .int(Int64(max(0, count))) }
            return SessionUsageReceiptWrite(
                path: path,
                sessionId: sessionID,
                value: .object(value),
                recordedAtEpochMicros: receiptOrder
            )
        }()
        await write(row, usageReceipt: usageReceipt)
    }

    /// Record `provider.noReply` once: the bound turn's daily trace or a standalone receipt.
    public func recordNoReply(provider: String, seconds: Int, events: Int, surface: String) async {
        let payload: [String: JSONValue] = [
            "provider": .string(provider), "seconds": .int(Int64(seconds)), "events": .int(Int64(events)),
            "surface": .string(surface), "turnId": .string(TurnTraceContext.turnId ?? "unknown"),
        ]
        TurnTraceBus.fireFromContext(kind: "provider.noReply", surface: surface, payload: .object(payload))
        guard TurnTraceContext.turnId == nil else { return }
        await write(TurnTraceEvent(kind: "provider.noReply", title: provider, status: "failed",
            payload: .object(payload), createdAt: ISO8601DateFormatter().string(from: Date())), usageReceipt: nil)
    }

    private func write(_ row: TurnTraceEvent?,
                       usageReceipt: SessionUsageReceiptWrite?) async {
        if let row {
            if let dataRootOverride { await TurnTracePersistLane(dataRootOverride: dataRootOverride).append(row) }
            else { TurnTraceBus.fire(row, on: .shared) }
        }
        if let usageReceipt {
            if dataRootOverride != nil { await SessionUsageReceiptWriter.shared.write(usageReceipt) }
            else { Task.detached(priority: .utility) { await SessionUsageReceiptWriter.shared.write(usageReceipt) } }
        }
    }

}
