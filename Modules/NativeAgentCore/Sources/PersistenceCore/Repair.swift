import Foundation
import NativeAgentCore
// Blueprint: | `Repair.swift` | Shared repair, reconciliation, terminal and person-decision shapes; ToolFailureError.call builds native calls, while fileRepairInstruction owns byte-preserving person recovery prose for damaged files, without executable coding requests |

/// The one shape of a fixable no. Every refusal or
/// failure whose cause lies outside the call's own input names what decided it
/// and carries its lever: her native call, or the person's recovery step.
/// A failure that carries one owes repair until that
/// operation works again or she lets it go with a reason.
public enum Repair {
    /// A tool result's `remedy` for an owned no. Carry the owner's whole
    /// lever: the call first, then the person's control when both are supplied.
    /// Missing evidence never settles a repair.
    public static func remedy(owner: String, nextCall: JSONValue?, tap: String?, instruction: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "kind": .string("repair"), "owner": .string(owner),
        ]
        if let tap {
            fields["tap"] = .string(tap)
            fields["next_call"] = nextCall ?? .null
            if let nextCall, nextCall != .null {
                fields["instruction"] = .string("Use next_call first. " + (instruction ?? "Then ask the person to use \(clause(tap)) for \(clause(owner))."))
            } else {
                fields["instruction"] = .string(instruction ?? "Ask the person to open \(clause(tap)) for \(clause(owner)).")
            }
        } else if let nextCall, nextCall != .null {
            fields["next_call"] = nextCall
            fields["instruction"] = .string(instruction ?? "Use next_call for \(clause(owner)).")
        } else {
            fields["instruction"] = .string(instruction ?? "No recovery lever was supplied; this repair remains open.")
        }
        return .object(fields)
    }

    /// Why a lawful decision went the way it did, and the person's exact
    /// control over it, with no debt: a Trust ask or block, a posture, a
    /// saved entry or a peer's elevation is the law working, not a dead end.
    /// She can tell the person precisely where it is decided; nothing is owed.
    public static func why(owner: String, tap: String, instruction: String? = nil) -> JSONValue {
        .object([
            "kind": .string("person_decides"), "owner": .string(owner), "tap": .string(tap), "next_call": .null,
            "instruction": .string(instruction ?? "Only the person can change \(clause(owner)), at \(clause(tap))."),
        ])
    }

    /// Read the named state to settle uncertain effects before another change.
    public static func reconcile(instruction: String, nextCall: JSONValue) -> JSONValue {
        .object(["kind": .string("reconcile"), "instruction": .string(instruction), "next_call": nextCall])
    }

    /// The owner explains why no further call is appropriate.
    public static func terminal(instruction: String) -> JSONValue {
        .object(["kind": .string("terminal"), "instruction": .string(instruction), "next_call": .null])
    }

    /// An owner inside a sentence: one that is itself a step ("… → Save
    /// token.") keeps no stop of its own, so the instruction reads as one.
    private static func clause(_ owner: String) -> String {
        owner.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
    }
}

public extension ToolFailureError {
    var failureCode: String? { code ?? (argumentPath == nil ? nil : "invalid_arguments") }

    func failureEvidence(defaultCode: String, defaultOwner: String? = nil) -> [String: JSONValue] {
        let cause = failureCode ?? defaultCode
        return ["status": .string(status.rawValue), "reason": .string(cause), "failure_code": .string(cause),
                "effects": .string(effects.rawValue), "argument_path": argumentPath.map(JSONValue.string) ?? .null,
                "accepted": accepted.map(JSONValue.string) ?? .null, "remedy": remedy(defaultOwner: defaultOwner)]
    }

    /// Recovery meaning belongs to the failure owner, before any surface redacts it.
    func remedy(defaultOwner: String? = nil) -> JSONValue {
        let owner = owner ?? defaultOwner
        let parsed = nextCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }
        let call: JSONValue? = if case .object? = parsed { parsed } else { nil }
        let instruction = instruction ?? message
        var value: JSONValue
        if recovery == .terminal { value = Repair.terminal(instruction: instruction) }
        else if personDecides, let tap { value = Repair.why(owner: owner ?? "This action", tap: tap, instruction: instruction) }
        else if recovery == .reconcile, let call { value = Repair.reconcile(instruction: instruction, nextCall: call) }
        else if let owner, recovery == nil || recovery == .repair {
            value = Repair.remedy(owner: owner, nextCall: call, tap: tap, instruction: instruction)
        } else if let recovery {
            value = .object(["kind": .string(recovery.rawValue), "instruction": .string(instruction), "next_call": call ?? .null])
        } else if let tap { value = Repair.why(owner: owner ?? "This action", tap: tap, instruction: instruction) }
        else if let call {
            value = .object(["kind": .string(argumentPath == nil ? "inspect" : "correct_arguments"),
                             "instruction": .string(instruction), "next_call": call])
        } else if let argumentPath {
            value = .object(["kind": .string("correct_arguments"), "argument_path": .string(argumentPath),
                "accepted": accepted.map(JSONValue.string) ?? .null, "instruction": .string(instruction)])
        } else { return .null }
        if let owner, case .object(var fields) = value { fields["owner"] = .string(owner); value = .object(fields) }
        return value
    }

    /// Her lever for `nextCall`: the call with its input.
    static func call(_ tool: String, _ input: [String: JSONValue] = [:]) -> String {
        (try? JSONValue.object(["tool": .string(tool), "input": .object(input)]).serialize(pretty: false)) ?? ""
    }

    /// The person's recovery step for damaged saved state. `shape` says what
    /// the file must hold; no coding request is executable recovery.
    static func fileRepairInstruction(_ file: URL,
        shape: String) -> String {
        "Ask the person to repair only \(file.path), preserving its original bytes in a sibling recovery copy before editing. "
            + "Inspect its actual bytes and permissions. \(shape) "
            + "Never invent records, discard an unreadable record or reset the file. "
            + "If a record cannot be recovered, report the exact remaining damage and leave the original intact. "
            + "Do not read or change memory, persona, credentials or Trust, or touch another installation or worktree; "
            + "do not change source code, run tests, build, install or restart the app."
    }
}
