import SenseCore
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
    @MainActor public func pageVerb(_ verb: String, input: [String: JSONValue], surface: String?) async
        -> (ok: Bool, detail: String, fields: [String: JSONValue]) {
        let effect: HostVerbEffect
        do {
            guard let prepared = try await preparePageVerb(verb, input, surface: surface) else {
                return (false, "No upkeep button is called \(verb).", [:])
            }
            effect = prepared
        } catch {
            var refusal = Self.prepareRefusal(error, verb: verb).objectValue ?? [:]
            return (false, refusal.removeValue(forKey: "detail")?.stringValue ?? "", refusal)
        }
        do {
            return (true, try await effect() ?? "", [:])
        } catch let refused as PartCallError {
            // Graph Apply's no says nothing was removed.
            return (false, refused.message, verb == "graph_apply" ? ["reason": .string(refused.code), "effects": .string("none")]
                : ["reason": .string(refused.code)])
        } catch {
            return (false, error.localizedDescription, [:])
        }
    }

    /// The gate's check before any card: the page verb's own `prepare`, its effect not run. Nil when every lookup holds, and for a verb that
    /// is not a page's.
    @MainActor public func pageVerbFence(_ verb: String, input: [String: JSONValue], surface: String?) async -> JSONValue? {
        do {
            _ = try await preparePageVerb(verb, input, surface: surface)
            return nil
        } catch { return Self.prepareRefusal(error, verb: verb) }
    }

    /// The page verbs' one switch: every lookup a verb needs (the value, item, review or helper it names, read now) throws its owner's
    /// refusal, or the verb's effect comes back to run. Nil for a verb that is not a page's.
    @MainActor func preparePageVerb(_ verb: String, _ input: [String: JSONValue], surface: String?) async throws -> HostVerbEffect? {
        switch verb {
        case "desk_refresh": return { [self] in await deskRefresh() }
        case "desk_remind": return try await deskRemind(input)
        case "desk_veto": return try await deskVeto(input)
        case "memories_search": return try memoriesSearch(input, surface: surface)
        case "memories_refresh": return { [self] in try await memoriesRefresh() }
        case "memories_bring_back": return try await memoriesBringBack(input)
        case "graph_refresh":
            return { [self] in
                await memory.loadGraph()
                if let error = memory.graphLoadError ?? memory.graphObservationError {
                    throw PartCallError(code: "graph_unavailable", message: error)
                }
                await pages.refresh(page: "knowledge")
                return "Knowledge Graph refreshed."
            }
        case "graph_apply":
            let (ids, token) = try graphApplyRequest(input)
            _ = try await graphUpkeep.applyCandidates(expectedIDs: ids, token: token)
            return { [self] in
                let words = try await graphUpkeep.apply(expectedIDs: ids, token: token)
                await pages.refresh(page: "knowledge")
                return words
            }
        case "personality_mind":
            let save = try await personalityMindChoice(input["value"]?.stringValue)
            return { try await save() }
        case "personality_reset": return { [self] in try await personalityReset() }
        case "bots_check": return try await BotsFace.check(self, input)
        case "bots_paused": return try await BotsFace.paused(self, input)
        default: return nil
        }
    }

    /// `graph.apply`'s call: the review token and the entity ids the review showed, a lookup of its `prepare`.
    func graphApplyRequest(_ input: [String: JSONValue]) throws -> (ids: [String], token: String) {
        guard let token = input["previewToken"]?.stringValue, case .array(let rawIDs)? = input["expectedIDs"] else {
            throw PartCallError(code: "graph_review_required", message: "Open Graph upkeep and review the candidates before applying.")
        }
        let ids = try rawIDs.map { raw -> String in
            guard case .string(let id) = raw else {
                throw PartCallError(code: "graph_review_invalid", message: "The review has an invalid entity identity.")
            }
            return id
        }
        return (ids, token)
    }
}
