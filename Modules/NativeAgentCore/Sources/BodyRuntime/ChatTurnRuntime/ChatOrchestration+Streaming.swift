import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import MindCore
import ProviderRouting
import NativeAgentShared

// Blueprint: | `ChatOrchestration+Streaming.swift` | `TurnStreamEvent`; Transient display, never terminal evidence |

// MARK: - TurnStreamEvent

public enum TurnStreamEvent: Sendable {
    case delta(String)
    /// Reversible display state; never terminal or persistence evidence.
    case replyTextSettled(Bool)
    case toolUse(name: String, input: JSONValue)
    case toolResult(name: String, output: JSONValue)
    case unstartedStep(id: String, name: String, disposition: TurnFace.Step.Disposition)
    /// Live tool status from ToolNoticeBus is visible during dispatch and never enters the durable reply.
    case notice(kind: String, text: String)
    case final(TurnEngineResult)
    case error(String)
    /// Streamed bytes that are not words yet (a thought, held text, a named call's input). Movement only, never reply or evidence.
    case writing(TurnCallWriting?)
}

public extension TurnCallWriting {
    /// A streaming call shows the name its dispatch will show: an `app` call by its action once the input names it.
    init(streaming input: LLMStreamCallInput) {
        if let action = ChatTurnFailure.clippedActionID(input.head) {
            self.init(call: ToolNameAliases.shown(input.name, input: .object(["action": .string(action)])).name, bytes: input.bytes)
        } else {
            self.init(call: input.name, bytes: input.bytes)
        }
    }
}
