import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import TrustCenter
import Skills
import Senses
import ChatTurnContracts

extension SwiftToolDispatcher {
    func impl_list_skills(input: [String: JSONValue]) async throws -> JSONValue {
        .array(try InstalledSkillInventory.entries(dataRoot: dataRoot).map(\.summary))
    }

    func impl_read_skill(input: [String: JSONValue]) async throws -> JSONValue {
        guard input["content"] != .bool(true) else {
            throw AutonomyGateError.toolDenied(reason: "Guidance bodies are retained history. Use skill.run for the converted routine, or source:true to review its code.")
        }
        let client = SwiftNativeSkillsClient(root: dataRoot)
        let read = try client.readSkill(name: requireString(input, "name"),
            source: input["source"] == .bool(true))
        return read
    }

    func impl_save_skill(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let name = try requireString(input, "name").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = try requireString(input, "description").trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .object(var raw)? = input["script"], let host = OwnedProgramInvocation.host else {
            throw AutonomyGateError.toolDenied(reason: "skill.save requires a JavaScript run(input) routine and the originating app door.")
        }
        raw["entry"] = .string("run")
        let script = try SkillScript.normalized(.object(raw))
        let actions: [JSONValue] = if case .object(let fields) = script, case .array(let ids)? = fields["actions"] { ids } else { [] }
        var pins: [String: JSONValue] = [:]
        for case .string(let id) in actions {
            guard let pin = host.dependencyPin(id) else {
                throw AutonomyGateError.toolDenied(reason: "Declare an available app action; \(id) is unavailable.")
            }
            pins[id] = .string(pin)
        }
        let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: ChatToolSessionContext.envelope?.verifiedUserId)
        let saved = try await SwiftNativeSkillsClient(root: dataRoot).createSkill(body: .object([
            "name": .string(name), "description": .string(description), "triggers": input["triggers"] ?? .array([]),
            "script": script, "fixtures": input["fixtures"] ?? .array([]), "dependencyShapes": .object(pins),
            "converts": input["converts"] ?? .array([]),
            "overrides": input["overrides"] ?? .null,
        ]), steer: SkillScript.origin(steeredBy: steer.sources + steer.elevated))
        let row: [String: JSONValue] = if case .object(let fields) = saved { fields } else { [:] }
        return .object(["status": .string("saved"), "skill": .string(name), "candidate_digest": row["candidateDigest"] ?? .null,
            "selected_version": row["codeFingerprint"] ?? .null, "skill_status": row["status"] ?? .null,
            "next_call": .object(["action": .string("skill.validate"), "args": .object(["name": .string(name)])]),
            "authority": .string("Every routine call takes the ordinary turn's dispatch chain; a skill grants no authority.")])
    }
}
