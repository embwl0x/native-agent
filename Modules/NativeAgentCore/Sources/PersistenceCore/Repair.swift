import Foundation
import NativeAgentCore

/// The one shape of a fixable no (User 10-18: "No fallbacks: it works and it
/// works right, and never can the agent say I can't fix it"). Every refusal or
/// failure whose cause lies outside the call's own input names what decided it
/// and carries its lever: her call, or the person's exact control where the law
/// gives him the decision. A failure that carries one owes repair until that
/// operation works again or she lets it go with a reason.
public enum Repair {
    /// A tool result's `remedy` for an owned no.
    public static func remedy(owner: String, nextCall: JSONValue?, tap: String?) -> JSONValue {
        var fields: [String: JSONValue] = [
            "kind": .string("repair"), "owner": .string(owner), "next_call": nextCall ?? .null,
        ]
        if let tap {
            fields["tap"] = .string(tap)
            fields["instruction"] = .string("\(owner) decided this, and it is the person's to change: ask them to open \(tap).")
        } else {
            fields["instruction"] = .string("\(owner) decided this. Call next_call to change it, then do what you meant again.")
        }
        return .object(fields)
    }

    /// Why a lawful decision went the way it did, and the person's exact
    /// control over it, with no debt: a Trust ask or block, a posture, a
    /// saved entry or a peer's elevation is the law working, not a dead end.
    /// She can tell the person precisely where it is decided; nothing is owed.
    public static func why(owner: String, tap: String) -> JSONValue {
        .object([
            "kind": .string("person_decides"), "owner": .string(owner), "tap": .string(tap), "next_call": .null,
            "instruction": .string("\(owner) decides this, by the person's choice. If it should change, tell them where: \(tap)."),
        ])
    }
}

public extension ToolFailureError {
    /// Her lever for `nextCall`: the call with its input.
    static func call(_ tool: String, _ input: [String: JSONValue] = [:]) -> String {
        (try? JSONValue.object(["tool": .string(tool), "input": .object(input)]).serialize(pretty: false)) ?? ""
    }

    /// Her lever for a damaged file of hers: one bounded repair that keeps the
    /// original bytes, recovers only what the retained bytes support and
    /// changes nothing else. `shape` says what the file must hold.
    static func fileRepairCall(_ file: URL, dataRoot: URL, shape: String) -> String {
        call("app", ["action": .string("codex.invoke"), "args": .object([
            "cwd": .string(dataRoot.path), "skip_git_repo_check": .bool(true), "text": .string(
                "Repair only \(file.path), preserving its original bytes in a sibling recovery copy before editing. "
                + "Inspect its actual bytes and permissions. \(shape) "
                + "Never invent records, discard an unreadable record or reset the file. "
                + "If a record cannot be recovered, report the exact remaining damage and leave the original intact. "
                + "Do not read or change memory, persona, credentials or Trust, or touch another installation or worktree; "
                + "do not change source code, run tests, build, install or restart the app."),
        ])])
    }
}
