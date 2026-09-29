import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter

// MARK: - TurnStreamEvent

public enum TurnStreamEvent: Sendable {
    case delta(String)
    /// Reversible display state; never terminal or persistence evidence.
    case replyTextSettled(Bool)
    case toolUse(name: String, input: JSONValue)
    case toolResult(name: String, output: JSONValue)
    /// In-turn user-visible status line (2026-06-09, the user: "if she freezes like
    /// that it should let me know not just hang"). Emitted mid-dispatch by
    /// long-running tools (invoke_claude start/heartbeat/timeout) via
    /// ToolNoticeBus. Surfaces render it as a live status; it is NEVER part
    /// of the durable reply. Consumers that don't care can ignore it.
    case notice(kind: String, text: String)
    case final(TurnEngineResult)
    case error(String)
}
