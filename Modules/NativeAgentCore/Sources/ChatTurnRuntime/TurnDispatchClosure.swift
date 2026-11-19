import Foundation
import NativeAgentCore
import TurnTrace
// Blueprint: | `TurnDispatchClosure.swift` | `TurnDispatchClosure.withTurn`: dispatch coverage closes after the turn's deferred work or abandonment, through Stop-safe settlement |

enum TurnDispatchClosure {
    /// Capture the trace before crossing `settle`: Stop cancels work, never closure.
    nonisolated(nonsending) static func withTurn<T>(dataRoot: URL?, turn: Turn,
        afterReply: (T) -> AfterReply? = { _ in nil }, _ operation: () async throws -> T
    ) async rethrows -> T {
        guard dataRoot != nil else { return try await operation() }
        let bus = TurnTraceContext.bus
        let close: @Sendable () async -> Void = { [turn] in
            await NativeAgentCore.settle {
                await TurnTraceContext.$bus.withValue(bus) {
                    await TurnTraceContext.$turnId.withValue(turn.id) {
                        TurnTraceBus.fireFromContext(kind: "tool.dispatch.closed", turn: turn)
                    }
                }
            }
        }
        do {
            let result = try await operation()
            if let continuation = afterReply(result) { continuation.onSettled(close) }
            else { await close() }
            return result
        } catch {
            await close()
            throw error
        }
    }
}
