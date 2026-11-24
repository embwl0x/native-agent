import Foundation
import NativeAgentCore
import PersistenceCore
import SenseCore
import ProviderRouting
import DeskCore
import Synchronization
import MacNerves
// Blueprint: | `ToolLoopSupport.swift` | `ToolLoopTraceObservation`: retained loop evidence |

/// Retains loop evidence across a throw without changing the public error carriers.
final class ToolLoopTraceObservation: Sendable {
    private let state = Mutex<(payload: [String: JSONValue], dispatches: [TurnEngineResult.ToolDispatchRecord], prose: String)>(([:], [], ""))

    func record(_ counters: TurnEngineResult.LoopCounters, dispatches: [TurnEngineResult.ToolDispatchRecord], reply: String) {
        state.withLock {
            $0.payload = counters.tracePayload
            $0.payload.merge(Self.toolCounts(dispatches), uniquingKeysWith: { _, new in new })
            $0.dispatches = dispatches
            $0.prose = reply
        }
    }

    var partialReply: String { state.withLock { $0.prose } }
    var toolDispatches: [TurnEngineResult.ToolDispatchRecord] { state.withLock { $0.dispatches } }
    var tracePayload: [String: JSONValue] { state.withLock { $0.payload } }

    static func toolCounts(_ dispatches: [TurnEngineResult.ToolDispatchRecord]) -> [String: JSONValue] {
        let attempts = dispatches.filter {
            let reply = ToolResult($0.result)
            return !ChatToolOutcome.neverRan(reply.payload)
                && !ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome)
        }
        return [
            "toolAttemptCount": .int(Int64(attempts.count)),
            "failedToolAttemptCount": .int(Int64(dispatches.filter { isFailedAttempt($0.result) }.count)),
            "skippedToolSlotCount": .int(Int64(dispatches.filter {
                ChatToolOutcome.neverRan($0.result)
            }.count)),
        ]
    }

    static func isFailedAttempt(_ output: JSONValue) -> Bool {
        let reply = ToolResult(output)
        return !ChatToolOutcome.neverRan(reply.payload) && [.failed, .refused, .timeout].contains(reply.outcome)
            && !ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome)
    }
}
extension TurnEngineResult.LoopCounters {
    var tracePayload: [String: JSONValue] {
        [
            "providerAttemptCount": .int(Int64(providerAttemptCount)),
            "failedProviderAttemptCount": .int(Int64(failedProviderAttemptCount)),
            "providerRoundCount": .int(Int64(providerRoundCount)),
            "toolRoundCount": .int(Int64(toolRoundCount)),
            "roundsAfterToolFailureCount": .int(Int64(roundsAfterToolFailureCount)),
            "protocolViolationRoundCount": .int(Int64(protocolViolationRoundCount)),
            "emptyReplyRoundCount": .int(Int64(emptyReplyRoundCount)),
        ]
    }
}
