import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter

// Blueprint: | `ChatOrchestration+Streaming.swift` | `TurnStreamEvent`: reversible streaming display and transient tool notices; never durable reply or terminal evidence |

// MARK: - TurnStreamEvent

public enum TurnStreamEvent: Sendable {
    case delta(String)
    /// Reversible display state; never terminal or persistence evidence.
    case replyTextSettled(Bool)
    case toolUse(name: String, input: JSONValue)
    case toolResult(name: String, output: JSONValue)
    /// Live tool status from ToolNoticeBus is visible during dispatch and never enters the durable reply.
    case notice(kind: String, text: String)
    case final(TurnEngineResult)
    case error(String)
}
