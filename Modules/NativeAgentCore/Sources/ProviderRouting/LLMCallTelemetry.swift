import Foundation
import NativeAgentShared
import NativeAgentCore
import os
import PersistenceCore
import TurnTrace
// Blueprint: | `LLMCallTelemetry.swift` | `LLMCallTraceRecorder`, `spent`: one receipt per request; partial output settles |

public extension Notification.Name {
    /// Publish session usage only after its exact receipt is durable.
    static let nativeAgentSessionProviderUsageDidChange = Notification.Name(
        "NativeAgent.sessionProviderUsageDidChange"
    )
}

// Calls carry their identity into TurnTrace; standalone calls use the shared feed. Recording faults cannot change provider results; preview privacy follows
// TurnTraceRedactor.
public final class LLMCallTraceRecorder: @unchecked Sendable {
    /// One request identity claims its first receipt, preventing adapter and router failure rows from double-counting.
    @TaskLocal public static var requestRecorded: OSAllocatedUnfairLock<Receipt>?
    /// The turn's tally counts only its own bound model rounds.
    public struct Spend: Sendable {
        public var knownTokens = 0
        public var complete = true
        public var total: Int? { complete ? knownTokens : nil }
        public init() {}
    }
    @TaskLocal public static var spent: OSAllocatedUnfairLock<Spend>?

    public struct Receipt: Sendable {
        public var recorded = false
        public var ttftMs: Int?
        /// Capture request size before send.
        public var requestBytes: Int?
        public var requestCharacters: Int?
        public var requestPlan: Data?
        public init() {}
    }

    /// Resolve the explicit root at append time so diagnostics stay with their body.
    private let dataRootOverride: URL?

    public init(dataRootOverride: URL? = nil) {
        self.dataRootOverride = dataRootOverride
    }

    /// Diagnostics from this adapter belong to the held call's selected body.
    func diagnosticDataRoot(call: LLMCall) -> URL {
        call.traceDataRoot ?? dataRootOverride ?? PersistenceCore.defaultDataRoot()
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
            // Counts on disk are evidence, not trusted arithmetic operands. Preserve a damaged receipt for repair rather than replacing it.
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
               existingObject["provider"] == pendingObject["provider"],
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
                    // Tool loops can make several provider requests in one turn. Keep comparing the final request to the preceding turn instead of
                    // resetting the delta after each tool.
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

    public func record(
        call: LLMCall,
        requestBody: Data? = nil,
        provider: String,
        model: String,
        streaming: Bool,
        usage: LLMUsage?,
        ttftMs: Int?,
        durationMs: Int,
        status: String = "ok",
        /// Only an actual ID rewrite sets substitutedFrom, keeping model substitutions visible.
        substitutedFrom: String? = nil,
        /// Read cache markers from the outgoing body in render order; receipts retain positions and TTLs, never prompt bytes.
        cacheMarkers: [LLMCacheMarker]? = nil,
        stopReason: String? = nil,
        errorDetail: String? = nil
    ) async {
        guard !call.preview else { return }
        if let claim = Self.requestRecorded, claim.withLock({ receipt in
            defer { receipt.recorded = true }
            if !receipt.recorded { receipt.ttftMs = ttftMs }
            return receipt.recorded
        }) { return }
        let accountingOverflow: Bool
        let measuredInput = usage?.logicalInputTokens(provider: provider)
        let measuredOutput = usage?.outputTokens
        let usageComplete = measuredInput != nil && measuredOutput != nil
        if let spent = Self.spent {
            accountingOverflow = spent.withLock { total in
                guard let input = measuredInput, let output = measuredOutput, output >= 0 else {
                    total.complete = false
                    return false
                }
                let (tokens, callOverflow) = input.addingReportingOverflow(output)
                let (sum, aggregateOverflow) = total.knownTokens.addingReportingOverflow(tokens)
                let overflow = callOverflow || aggregateOverflow
                if overflow { total.complete = false }
                else { total.knownTokens = sum }
                return overflow
            }
        } else { accountingOverflow = false }
        let purpose = call.purpose
        let routedSurface = call.surface
        let surface: String = {
            switch purpose {
            case "memory_interpret", "memory_held", "recall_judge", "kind_backfill": return "memory"
            case "digest", "probe": return purpose
            default: return routedSurface
            }
        }()
        // Bound calls join the turn's trace; background calls retain an unknown turn id.
        let turnId = call.turn?.id ?? "unknown"
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
        payload["tokenAccounting"] = .string(usageComplete && !accountingOverflow ? "complete" : "unavailable")
        if let bytes = Self.requestRecorded?.withLock({ $0.requestBytes }) { payload["requestBytes"] = .int(Int64(bytes)) }
        if let characters = Self.requestRecorded?.withLock({ $0.requestCharacters }) { payload["requestCharacters"] = .int(Int64(characters)) }
        // Only streamMessages calls carry a delivery kind.
        if let streamKind = LLMMessagesStreamKind.current {
            payload["streamKind"] = .string(streamKind.rawValue)
        }
        // Unbound callers omit prefix receipts; secondary calls explicitly report their shape as unmeasured.
        let prefix = await call.prefixMeasurement?.resolved()
        if let prefix {
            for (key, value) in prefix.payload { payload[key] = value }
        } else if call.requestShapeUnmeasured {
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
        if !call.requestShapeUnmeasured,
           let weight = call.prefixMeasurement?.toolWeight {
            payload["tools.floorSchemaBytes"] = .int(Int64(weight.floorBytes))
            payload["tools.appendedSchemaBytes"] = .int(Int64(weight.appendedBytes))
            payload["tools.wireSchemaBytes"] = .int(Int64(weight.wireBytes))
        }
        if let requestBody, let prefix {
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
        let row = TurnTraceEvent(
            kind: "llm.call", title: model, status: status,
            payload: .object(payload), createdAt: recordedAtISO,
            turnId: call.turn?.id, sessionId: call.session, surface: surface, turn: call.turn
        )
        let usageReceipt: SessionUsageReceiptWrite? = {
            guard status == "ok",
                  !call.requestShapeUnmeasured,
                  let request = Self.requestRecorded?.withLock({ $0 }),
                  let requestCharacters = request.requestCharacters,
                  let requestPlan = request.requestPlan,
                  let usage,
                  let logicalInputTokens = usage.logicalInputTokens(provider: provider),
                  let rawSessionID = call.session,
                  let sessionID = NativeAgentChatSessionID.normalizedPathComponent(rawSessionID) else {
                return nil
            }
            let root = diagnosticDataRoot(call: call)
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
                "requestCharacters": .int(Int64(requestCharacters)),
                "requestPlan": .string(requestPlan.base64EncodedString()),
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
        await write(row, usageReceipt: usageReceipt, call: call)
    }

    /// Record `provider.noReply` once: the bound turn's daily trace or a standalone receipt.
    public func recordNoReply(provider: String, seconds: Int, events: Int, surface: String, call: LLMCall) async {
        guard !call.preview else { return }
        let payload: [String: JSONValue] = [
            "provider": .string(provider), "seconds": .int(Int64(seconds)), "events": .int(Int64(events)),
            "surface": .string(surface), "turnId": .string(call.turn?.id ?? "unknown"),
        ]
        await write(TurnTraceEvent(kind: "provider.noReply", title: provider, status: "failed",
            payload: .object(payload), createdAt: ISO8601DateFormatter().string(from: Date()),
            turnId: call.turn?.id, sessionId: call.session, surface: surface, turn: call.turn), usageReceipt: nil, call: call)
    }

    /// Every whole-reply consumer records incomplete output before handing its original error to the caller. This is evidence, never a successful reply.
    func recordPartialReply(output: String, error: Error, call: LLMCall) async {
        guard !call.preview else { return }
        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        let row = TurnTraceEvent(
            kind: "llm.reply.partial", title: "Incomplete model reply",
            status: cancelled ? "cancelled" : "failed",
            payload: .object([
                "purpose": .string(call.purpose),
                "output": .string(TurnTraceRedactor.redactText(output)),
                "outputBytes": .int(Int64(output.utf8.count)),
                "error": .string(ProviderFailure.diagnosticDescription(error)),
                "cancelled": .bool(cancelled),
            ]), createdAt: ISO8601DateFormatter().string(from: Date()),
            turnId: call.turn?.id, sessionId: call.session, surface: call.surface, turn: call.turn
        )
        let root = diagnosticDataRoot(call: call)
        // Stop cancels the request, not saving what it produced. Use the trace owner's selected root even when this caller has no bound trace bus.
        await settle { await TurnTracePersistLane(dataRootOverride: root).append(row) }
    }

    private func write(_ row: TurnTraceEvent,
                       usageReceipt: SessionUsageReceiptWrite?, call: LLMCall) async {
        let root = call.traceDataRoot ?? dataRootOverride
        if call.turn != nil, let bus = TurnTraceContext.bus { TurnTraceBus.fire(row, on: bus) }
        else if let root { await TurnTracePersistLane(dataRootOverride: root).append(row) }
        else { TurnTraceBus.fire(row, on: .shared) }
        if let usageReceipt {
            if root != nil { await SessionUsageReceiptWriter.shared.write(usageReceipt) }
            else { Task.detached(priority: .utility) { await SessionUsageReceiptWriter.shared.write(usageReceipt) } }
        }
    }

}
