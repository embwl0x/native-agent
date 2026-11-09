import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import ToolRegistry
// Blueprint: | `Parts+CallValidation.swift` | static call-fit against current declarations |

extension Parts {
    /// The runner turns a host call into an app action unless the broker owns that primitive. Save uses that same inventory, before any staged write.
    func checkedCallShapes(_ calls: OwnedProgram.Calls, id: String, actions: [String], selfSchema: JSONValue,
        invocation: Invocation) async throws -> JSONValue {
        guard let host = invocation.host else {
            throw PartError.invalid("Checking calls requires the originating app door. Nothing was saved.")
        }
        if let refusal = calls.refusals.first { throw PartError.invalid(refusal + " Nothing was saved.") }
        let declared = Set(try actions.map { try host.canonicalAction($0) })
        let primitives = ToolPrimitiveBroker.operations.union(["apps.call", "part.call"])
        var shapes: [String: JSONValue] = [:]
        func shape(_ action: String) throws -> JSONValue? {
            if let known = shapes[action] { return known }
            let value: JSONValue?
            if action == "authored." + id { value = .object(["self": .string(id)]) }
            else if let current = try host.dependencyShape(action) { value = current }
            else if action.hasPrefix("authored."), let stored = try row(action),
                    let part = Self.string(stored, "id"), action == "authored." + part,
                    let version = Self.string(stored, "codeFingerprint") ?? Self.string(stored, "candidateDigest") {
                // A saved part is a real name even before it is on. Pin that exact retained version; this never admits or enables its run.
                value = .object(["stored_part": .string(part), "version": .string(version)])
            } else { value = nil }
            shapes[action] = value
            return value
        }
        var checked: Set<String> = []
        for call in calls.literal {
            if call.primitive, primitives.contains(call.spelling) { continue }
            if let given = call.given, let problem = try host.callProblem(call.id, given: given, schema: call.id == "authored." + id ? selfSchema : nil) {
                var failure = Self.revisionFailure("stale_dependency",
                    "Call \(call.id) at line \(call.line): \(problem). Correct this call with ability.save, then keep the reviewed version.", id: id)
                var remedy = failure.remedy?.objectValue ?? [:]
                remedy["try_instead"] = try await host.callAdvice(call.id, given: given)
                failure.remedy = .object(remedy)
                throw failure
            }
            guard checked.insert(call.id).inserted else { continue }
            guard try shape(call.id) != nil else {
                let failure = try await unknownCall(call.id, line: call.line, host: host)
                throw failure
            }
            guard try declared.contains(host.canonicalAction(call.id)) else {
                let declaration = Set(actions + [call.id]).sorted()
                throw ToolFailureError("""
                    Literal call \(call.id) at line \(call.line) is missing from this ability's actions. Declare \(call.id) in actions (or its applicable \
                    reach) before saving. Nothing was saved.
                    """,
                    argumentPath: "actions", accepted: "declared app action ids", effects: .none,
                    nextCall: ToolFailureError.call("app", ["action": .string("ability.save"),
                        "args": .object(["id": .string(id), "actions": .array(declaration.map(JSONValue.string))])]),
                    code: "undeclared_dependency", status: .refused,
                    instruction: "Add the named dependency to this ability's actions, then save the revision.", recovery: .correctArguments)
            }
        }
        // Declarations themselves cannot name imaginary actions, even on a branch whose call name is computed and therefore invisible to this inspection.
        for action in actions where !checked.contains(action) && action != "authored." + id {
            guard try shape(action) != nil else {
                let failure = try await unknownCall(action, host: host)
                throw failure
            }
        }
        if actions.contains("authored." + id) { _ = try shape("authored." + id) }
        return .object(shapes.filter { actions.contains($0.key) })
    }

    private func unknownCall(_ action: String, line: Int? = nil, host: any OwnedProgramToolHost) async throws -> SenseFailure {
        SenseFailure(code: "unknown_dependency",
            message: "Unknown action \(action)\(line.map { " at line \($0)" } ?? ""). try_instead names current action shapes. Nothing was saved.",
            remedy: .object(["kind": .string("correct_arguments"), "instruction": .string(
                "Correct the named call or declaration with ability.save using a real action."),
                "next_call": .object(["tool": .string("app"), "input": .object(["find": .string(action)])]),
                "try_instead": try await host.callAdvice(action, given: nil)]))
    }
}
