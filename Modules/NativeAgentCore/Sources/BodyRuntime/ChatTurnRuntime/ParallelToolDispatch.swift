import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import SenseCore
// Blueprint: | `ParallelToolDispatch.swift` | `ParallelToolDispatch`; `isParallelSafe` |

// MARK: - Parallel dispatch of independent tool calls
// Group consecutive certified-safe reads under the concurrency cap; run unsafe calls alone and retain original slot order.
// Slot failures never cancel siblings; turn cancellation cancels every child. Effect-time gates still apply.
// Keep one user result message per iteration because clearing counts messages, not individual result blocks.
public enum ParallelToolDispatch {
    /// Cap the live window and refill on completion so larger batches cannot create unbounded child work.
    static let maxConcurrentPerIteration = 4

    private static let certifiedBundledAppReads: [String: String] = [
        "mail.recent": "native-mail",
        "mail.search": "native-mail",
        "messages.recent": "native-messages",
        "notes.search": "native-notes",
    ]

    static func singleAppAction(_ input: [String: JSONValue]) -> (action: String, normalized: [String: JSONValue])? {
        let normalized = ToolNameAliases.doorCall("app", input)
        guard normalized["__undo_receipt"] == nil else { return nil }
        let present = normalized.filter { !$0.key.hasPrefix("__") && $0.value != .null }
        guard case .string(let raw)? = present["action"] else { return nil }
        let action = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !action.isEmpty else { return nil }
        guard present["preview"] == nil || present["preview"] == .bool(false) else { return nil }
        guard present["script"] == nil || present["script"] == .string("") else { return nil }
        guard present["args"] == nil || present["args"]?.objectValue != nil else { return nil }
        guard present.keys.allSatisfy({ ["action", "args", "because", "preview", "script"].contains($0) }) else { return nil }
        return (action, normalized)
    }

    public static func isParallelSafe(
        internalToolName name: String, input: [String: JSONValue] = [:], turn: Turn?, parts: AppActionBinding.PartLookup? = nil
    ) -> Bool {
        // This is a certificate for concurrent scheduling, not an effect
        // verdict. An unreadable policy supplies no certificate; admission
        // still checks that same owner and returns its failure before acting.
        do {
            guard try PermissionLaw.toolClass(name, input: input, turn: turn, parts: parts) == .read else { return false }
            let canonical = ToolNameAliases.canonical(name)
            // Working-tree git diff may rewrite .git/index, so it runs alone.
            if canonical == "git_diff" { return false }
            if canonical == "mac_calendar_list_upcoming" { return true }
            if canonical == "mac_reminders_list_due_today" {
                return try AppActionBinding.binding("authored.due-reminders", turn: turn, parts: parts)?.bundled == true
            }
            if canonical == "app" {
                guard let single = singleAppAction(input),
                      let part = certifiedBundledAppReads[single.action],
                      let binding = try AppActionBinding.action(input: single.normalized, turn: turn, parts: parts) else { return false }
                return binding.bundled && binding.tool == part && binding.fixedInput["verb"] == .string(single.action)
                    && binding.read && binding.toolClass == .read
            }
            return [.core, .fileOps].contains(AppActionBinding.declaredBucket(canonical) ?? .unclassified)
        } catch {
            TurnTraceBus.fireFromContext(kind: "tool.parallel_classification_unavailable", payload: .object([
                "tool": .string(name), "failure": .string(error.localizedDescription),
                "detail": .string("Concurrent scheduling is unverified. The action still requires its checked admission.")]), turn: turn)
            return false
        }
    }

    // MARK: Iteration planning

    /// Only groups of at least two safe calls run concurrently; single safe slots keep serial event order.
    /// Run groups in order and reassemble every result by original index.
    enum ExecutionGroup: Equatable {
        case concurrent([Int])
        case sequential(Int)
    }

    static func plan(parallelSafe: [Bool], forceSerial: Bool) -> [ExecutionGroup] {
        guard !forceSerial else {
            return parallelSafe.indices.map { .sequential($0) }
        }
        var groups: [ExecutionGroup] = []
        var run: [Int] = []
        func flushRun() {
            if run.count >= 2 {
                groups.append(.concurrent(run))
            } else {
                for idx in run { groups.append(.sequential(idx)) }
            }
            run = []
        }
        for (idx, safe) in parallelSafe.enumerated() {
            if safe {
                run.append(idx)
            } else {
                flushRun()
                groups.append(.sequential(idx))
            }
        }
        flushRun()
        return groups
    }
}
