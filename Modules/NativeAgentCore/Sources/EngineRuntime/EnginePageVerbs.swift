import AuthoredCapabilities
import Foundation
import NativeAgentShared
import PersistenceCore
// Blueprint: | `EnginePageVerbs.swift` | Packet key calls and page-owned verbs through the person's app door |

/// One action a page packet's key declares: its id and role, and what it does — a door call, or a place it opens. A place only the Mac
/// opens (an editor, the clipboard) names the Mac as its one door, so no other door draws it.
struct PageKeyAction {
    let id: String
    var role: PartFace.Action.Role?
    var doors: [String]?
    var call: PartFace.Call?
    var open: String?

    static func calls(_ id: String, role: PartFace.Action.Role? = nil, _ action: String, _ args: [String: PartFace.Value] = [:]) -> Self {
        .init(id: id, role: role, call: PartFace.Call(action, args))
    }

    static func mac(_ id: String, opens link: String) -> Self { .init(id: id, doors: ["mac"], open: link) }

    /// The action as a packet's key declares it (`PartFace.Keys`).
    var json: JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id)]
        if let role { fields["role"] = .string(role.rawValue) }
        if let doors { fields["doors"] = .array(doors.map(JSONValue.string)) }
        if let call { fields["call"] = .object(call.input) }
        if let open { fields["open"] = .string(open) }
        return .object(fields)
    }
}

extension NativeAgentEngine {
    /// The page buttons' host (`upkeep`) runs a verb the agent's pages declare (`AppActions.agentPageVerbs`) with its page owner's code, for
    /// the person's tap and the agent's call alike; who may run it was decided at the door. An owner's no comes back as its code and words.
    @MainActor public func pageVerb(_ verb: String, input: [String: JSONValue]) async -> (ok: Bool, detail: String, fields: [String: JSONValue]) {
        do {
            let words: String
            switch verb {
            case "desk_refresh": words = await deskRefresh()
            case "desk_remind": words = try await deskRemind(input)
            case "desk_veto": words = try await deskVeto(input)
            case "memories_search": words = try await memoriesSearch(input)
            case "memories_refresh": words = try await memoriesRefresh()
            case "graph_refresh":
                await memory.loadGraph()
                if let error = memory.graphLoadError ?? memory.graphObservationError {
                    throw PartCallError(code: "graph_unavailable", message: error)
                }
                await pages.refresh(page: "knowledge")
                words = "Knowledge Graph refreshed."
            case "graph_apply":
                do {
                    guard let token = input["previewToken"]?.stringValue, case .array(let rawIDs)? = input["expectedIDs"] else {
                        throw PartCallError(code: "graph_review_required", message: "Open Graph upkeep and review the candidates before applying.")
                    }
                    let ids = try rawIDs.map { raw -> String in
                        guard case .string(let id) = raw else {
                            throw PartCallError(code: "graph_review_invalid", message: "The review has an invalid entity identity.")
                        }
                        return id
                    }
                    words = try await graphUpkeep.apply(expectedIDs: ids, token: token)
                    await pages.refresh(page: "knowledge")
                } catch let refused as PartCallError {
                    return (false, refused.message, ["reason": .string(refused.code), "effects": .string("none")])
                }
            case "personality_mind": words = try await personalityChooseMind(input["value"]?.stringValue)
            case "personality_reset": words = try await personalityReset()
            case "bots_check": words = try await BotsFace.check(self, input)
            case "bots_paused": words = try await BotsFace.paused(self, input)
            default: return (false, "No upkeep button is called \(verb).", [:])
            }
            return (true, words, [:])
        } catch let refused as PartCallError {
            return (false, refused.message, ["reason": .string(refused.code)])
        } catch {
            return (false, error.localizedDescription, [:])
        }
    }
}
