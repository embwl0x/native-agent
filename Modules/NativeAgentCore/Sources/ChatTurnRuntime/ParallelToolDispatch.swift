import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import TrustCenter
import TurnTrace
// Blueprint: | `ParallelToolDispatch.swift` | `ParallelToolDispatch`; `isSerialFallbackForced`; `isParallelSafe` |

// MARK: - Parallel dispatch of independent tool calls
// Group consecutive certified-safe reads under the concurrency cap; run unsafe calls alone and retain original slot order.
// Slot failures never cancel siblings; turn cancellation cancels every child. Effect-time gates still apply.
// Keep one user result message per iteration because clearing counts messages, not individual result blocks.
public enum ParallelToolDispatch {
    /// Cap the live window and refill on completion so larger batches cannot create unbounded child work.
    static let maxConcurrentPerIteration = 4

    /// Read the serial override once per process so dispatch policy stays stable.
    static let serialFallbackEnvVar = "NATIVE_AGENT_SERIAL_TOOL_DISPATCH"

    static func isSerialFallbackForced(env: [String: String]) -> Bool {
        guard let raw = env[serialFallbackEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    static let effectiveForceSerial =
        isSerialFallbackForced(env: ProcessInfo.processInfo.environment)

    /// Trust's declared class and catalog bucket certify parallel reads. Device, app-door and unplaced reads share one serial pair of hands.
    /// Writes always run alone.
    public static func isParallelSafe(internalToolName name: String, input: [String: JSONValue] = [:], turn: Turn?) -> Bool {
        // This is a certificate for concurrent scheduling, not an effect
        // verdict. An unreadable policy supplies no certificate; admission
        // still checks that same owner and returns its failure before acting.
        do { guard try PermissionLaw.toolClass(name, input: input, turn: turn) == .read else { return false } }
        catch {
            TurnTraceBus.fireFromContext(kind: "tool.parallel_classification_unavailable", payload: .object([
                "tool": .string(name), "failure": .string(error.localizedDescription),
                "detail": .string("Concurrent scheduling is unverified. The action still requires its checked admission.")]), turn: turn)
            return false
        }
        let canonical = ToolNameAliases.canonical(name)
        // Working-tree git diff may rewrite .git/index, so it runs alone.
        if canonical == "git_diff" { return false }
        return [.core, .fileOps].contains(AppActionBinding.declaredBucket(canonical) ?? .unclassified)
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
