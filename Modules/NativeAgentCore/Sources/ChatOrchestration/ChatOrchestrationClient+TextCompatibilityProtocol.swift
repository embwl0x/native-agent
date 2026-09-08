import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

extension SwiftNativeChatOrchestrationClient {
    nonisolated static func textCompatibilityCalls(
        nativeCalls: [LLMStreamToolCall],
        ridesNativeTools: Bool,
        iterAccumulated: String
    ) -> [ParsedToolCall] {
        ridesNativeTools
                ? nativeCalls.map { call in
                    var input: [String: JSONValue] = [:]
                    if let parsed = try? JSONValue.parse(call.inputJSON),
                       case .object(let obj) = parsed {
                        input = obj
                    }
                    return ParsedToolCall(id: call.id, name: call.name, input: input)
                }
                : ToolCallParser.parse(iterAccumulated)
    }

    /// User, 2026-09-06: the turn's VISIBLE prose, round by round. `accumulated`
    /// used to absorb only the round that ended call-free, so every narrated
    /// tool round's prose was dropped — and the exhaustion composition, which
    /// reads `accumulated`, found it empty and persisted the fallback line
    /// alone. Rounds are joined by a blank line because they are separate
    /// paragraphs of the same reply, not one run-on string.
    nonisolated static func absorbingVisibleRound(
        _ accumulated: String, _ round: String
    ) -> String {
        let trimmed = round.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return accumulated }
        if accumulated.isEmpty { return trimmed }
        return accumulated + "\n\n" + trimmed
    }

    @discardableResult
    nonisolated static func flushCompatibilityDeltaBuffer(
        _ pending: inout String,
        force: Bool,
        continuation: AsyncThrowingStream<TurnStreamEvent, Error>.Continuation
    ) -> Bool {
        guard !pending.isEmpty else { return false }
        // Final flush: stream EVERYTHING that remains. A real tool marker is
        // discarded via pendingDelta.removeAll() on the tool-call path BEFORE any
        // force flush runs, so when we reach here the iteration finished
        // tool-free and any "<tool"-looking text is prose that must be shown.
        // (Previously this short-circuited on "<tool" even when force==true, so a
        // reply merely MENTIONING "<tool" never streamed — frozen bubble then an
        // instant dump via .final. audit #6, 2026-06-14.)
        if force {
            continuation.yield(.delta(pending))
            pending = ""
            return true
        }
        // Non-force: stream prose up to the earliest point that could begin a
        // tool marker or Markdown pseudo-call, holding that candidate until the
        // iteration end disambiguates it (real marker -> parsed, malformed block
        // -> bounced, ordinary prose -> shown by the force pass). Keep a <=16-char
        // cross-chunk tail so a candidate forming at the boundary is not split.
        let holdFrom: String.Index
        if let r = ToolCallParser.earliestPotentialProtocolMarker(in: pending) {
            holdFrom = r.lowerBound
        } else {
            let tail = min(16, pending.count)
            holdFrom = pending.index(pending.endIndex, offsetBy: -tail)
        }
        guard holdFrom > pending.startIndex else { return false }
        let flush = String(pending[..<holdFrom])
        pending = String(pending[holdFrom...])
        if !flush.isEmpty {
            continuation.yield(.delta(flush))
            return true
        }
        return false
    }

    nonisolated static func turnResult(
        _ result: TurnEngineResult,
        replacingToolDispatchesWith dispatches: [TurnEngineResult.ToolDispatchRecord],
        rawLLMResponse: String,
        providerCallCount: Int,
        elapsedMs: Int,
        replyOverride: String? = nil
    ) -> TurnEngineResult {
        TurnEngineResult(
            reply: replyOverride ?? result.reply,
            modelUsed: result.modelUsed,
            recalledIds: result.recalledIds,
            toolDispatches: dispatches,
            elapsedMs: elapsedMs,
            rawLLMResponse: rawLLMResponse,
            providerCallCount: providerCallCount,
            terminalObservation: result.terminalObservation,
            completionState: result.completionState
        )
    }

}
