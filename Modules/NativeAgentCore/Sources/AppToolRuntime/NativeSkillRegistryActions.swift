import Foundation
import PersistenceCore
import Senses
import ToolExecution
import NativeAgentCore
import ChatTurnContracts
import ChatToolParsing
// Blueprint: | `NativeSkillRegistryActions.swift` | owner-facing enable/disable through `Parts`; `enableSkill`, `disableSkill` |

/// Every owner-facing install, approval and improvement apply shares the Parts lifecycle.
public enum NativeSkillRegistryActions {

    /// Keep only the exact reviewedDigest; a version changed since review requires a new decision.
    public static func enableSkill(name: String, dataRoot: URL, reviewedDigest: String?, turn: Turn,
                                   execution: AppActionExecution) async throws {
        let outcome = await Parts(root: dataRoot).enable(name, version: reviewedDigest,
            fullMac: false, ownerAuthorized: true, invocation: execution.partInvocation(turn: turn, surface: "ability.enable"))
        guard outcome.ok else {
            let reply = ToolResult(.object(outcome.fields))
            throw ToolFailureError(outcome.text,
                effects: reply.effects == .some(.none) ? .none : .unknown,
                code: "part_enable_incomplete")
        }
    }

    public static func disableSkill(name: String, dataRoot: URL, turn: Turn) async throws {
        let outcome = Parts(root: dataRoot).disable(name, reason: nil, fullMac: false, ownerAuthorized: true, turn: turn)
        guard outcome.ok else {
            let reply = ToolResult(.object(outcome.fields))
            throw ToolFailureError(outcome.text,
                effects: reply.effects == .some(.none) ? .none : .unknown,
                code: "part_disable_incomplete")
        }
    }
}
