import Foundation
import PersistenceCore
import TurnTrace

/// Structured chat can run beneath an outer streaming task that already owns
/// the turn trace identity. Reusing that ambient identity is required so the
/// plan, provider call, tool dispatches, and outcome remain one story.
/// Direct non-streaming callers still mint one identity.
enum StructuredTurnTraceIdentity {
    static func currentOrMint() -> String {
        TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()
    }
}
