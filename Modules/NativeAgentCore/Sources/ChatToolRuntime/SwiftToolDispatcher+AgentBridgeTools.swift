import AgentWorkspace
import Foundation
import NativeAgentShared
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import Desk
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import MacIntegration
import ToolRegistry
// Blueprint: | `SwiftToolDispatcher+AgentBridgeTools.swift` | `SwiftToolDispatcher`: Recheck program authority before launch. |

/// SecurityCenter's launch decision for the real origin and re-verified approved program.
enum DrivenAgentLaunch: Sendable {
    struct Program: Sendable {
        let permission: DrivenAgentLaunchPermission
        let executable: String
        let arguments: [String]
        var receipt: JSONValue {
            .object(["permission": .string(permission == .fullMac ? "full_mac" : "restricted")])
        }
    }
    case admitted(Program)
    case refused(JSONValue)

    static func refusal(_ reason: String, remedy: JSONValue? = nil) -> Self {
        var result: [String: JSONValue] = ["status": .string("failed"), "reason": .string("launch_blocked"),
            "sent": .bool(false), "ran": .bool(false), "completed": .bool(false),
            "detail": .string("Nothing was launched: \(reason).")]
        if let remedy { result["remedy"] = remedy }
        return .refused(.object(result))
    }

    var receipt: JSONValue {
        switch self {
        case .admitted(let program): return program.receipt
        case .refused(let result): return result
        }
    }
}

extension SwiftToolDispatcher {

    /// `contact` carries the approved program's receipt: the contact itself for agent_message, otherwise the connected contact for that agent.
    static func drivenAgentLaunch(turn: Turn, surface: String, contact: AgentPeerContact?,
                                  name: String, dataRoot: URL) async -> DrivenAgentLaunch {
        let origin = SecurityOriginContext.currentTurn(turn: turn,
            surface: surface)
        let permission = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .drivenAgentLaunchPermission(origin: origin, turn: turn)
        if case .denied(let reason) = permission { return .refusal(reason) }
        // Rebinding follows the installation without changing the launch's authority.
        let store = AgentPeerStore(dataRoot: dataRoot)
        var problem = "\(name)'s installed executable could not be bound to its contact"
        do {
            if let contact, let current = try store.list().first(where: { $0.id == contact.id }),
               let row = AgentPeerStore.hostRowID(current.endpoint).flatMap(AgentHostDirectory.row(named:)),
               let line = row.commandLine, let installed = row.resolveExecutable(line.executable) {
                if installed != current.verifiedExecutablePath {
                    guard try store.approveExecutable(peerID: current.id, path: installed) else {
                        throw AgentCommunicationError.invalid("the contact was disconnected")
                    }
                }
                if let path = try store.list().first(where: { $0.id == current.id })?.verifiedExecutablePath {
                    return .admitted(.init(permission: permission, executable: path,
                        arguments: line.permissionFlags.map(permission.arguments) ?? []))
                }
            }
        } catch {
            problem = "\(name)'s executable binding could not be reconciled: \(error.localizedDescription)"
        }
        return .refusal(problem,
            remedy: Repair.remedy(owner: "agents/peers.json peer:" + (contact?.id ?? name),
                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("agent.connect"),
                    "args": .object(["name": .string(contact.map { "peer:" + $0.id } ?? name)])])]), tap: nil))
    }
}
