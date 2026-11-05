import Foundation
import NativeAgentCore
import PersistenceCore
import Desk
import TurnTrace
import MemoryV2
import PersonaEngine
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import Context
import SwarmRuns
// Blueprint: | `SwiftToolDispatcher+TaskLedgerTools.swift` | `SwiftToolDispatcher`; the shared paged task ledger |

// MARK: - Task ledger tools

extension SwiftToolDispatcher {
    /// The shared flock covers append, compaction and the newest-5000 cap; pin actor identity to prevent impersonation.
    func impl_task_ledger_post(input: [String: JSONValue]) async throws -> JSONValue {
        let kindRaw = try requireString(input, "kind")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = TaskLedgerKind(rawValue: kindRaw) else {
            throw AutonomyGateError.toolDenied(
                reason: "task_ledger_post: unknown kind '\(kindRaw)' (expected one of \(TaskLedgerKind.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        // taskId is required for follow-up events; for `created` we mint one when omitted so the model can open a fresh task without a round-trip.
        let providedTaskId = optionalString(input, "task_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let taskId: String
        if let providedTaskId, !providedTaskId.isEmpty {
            taskId = providedTaskId
        } else if kind == .created {
            taskId = UUID().uuidString
        } else {
            throw AutonomyGateError.toolDenied(
                reason: "task_ledger_post: task_id is required for kind '\(kind.rawValue)' (only 'created' may omit it)"
            )
        }
        let title = optionalString(input, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = optionalString(input, "note")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var refs: [String] = []
        if case .array(let arr)? = input["refs"] {
            refs = arr.compactMap { if case .string(let s) = $0 { return s.trimmingCharacters(in: .whitespacesAndNewlines) } else { return nil } }
                .filter { !$0.isEmpty }
        }

        let event = TaskLedgerEvent(
            taskId: taskId,
            actor: .agent,
            kind: kind,
            title: (title?.isEmpty == false) ? title : nil,
            note: (note?.isEmpty == false) ? note : nil,
            refs: refs
        )
        let ledger = SwiftNativeTaskLedger(dataRoot: dataRoot)
        do {
            let written: TaskLedgerEvent
            if kind == .deleted {
                guard let expectedTitle = optionalString(input, "expected_title"), !expectedTitle.isEmpty else {
                    throw AutonomyGateError.toolDenied(reason: "task_ledger_post: deleted requires expected_title from task_ledger_list")
                }
                guard try await ledger.delete(event, expectedTitle: expectedTitle) else {
                    return .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("task_not_found_or_changed"),
                                    "detail": .string("""
                                        No task matches that id and expected_title, so nothing was deleted. Read task_ledger_list and use its \
                                        exact values.
                                        """)])
                }
                written = event
            } else {
                written = try await ledger.append(event)
            }
            return .object([
                "status": .string("ok"),
                "event": written.toJSON(),
                "task_id": .string(written.taskId),
            ])
        } catch {
            return .object([
                "status": .string("failed"),
                "reason": .string("\(error.localizedDescription)"),
            ])
        }
    }

    /// Read derived task state and retained events without mutating the shared ledger.
    func impl_task_ledger_list(input: [String: JSONValue]) async throws -> JSONValue {
        let ledger = SwiftNativeTaskLedger(dataRoot: dataRoot)
        for key in ["limit", "offset"] where input[key] != nil {
            guard let value = Self.jsonInt(input[key]), value >= (key == "limit" ? 1 : 0), value <= (key == "limit" ? 100 : 1_000_000) else {
                throw ToolFailureError("\(key) is outside its allowed range.", argumentPath: "$.\(key)", effects: .none, code: "invalid_input")
            }
        }
        let limit = Self.jsonInt(input["limit"]) ?? 25
        let offset = Self.jsonInt(input["offset"]) ?? 0
        // Input bounds above keep this sum at or below 1_000_100.
        let nextOffset = offset + limit
        let id = optionalString(input, "task_id")?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let id, !id.isEmpty {
            let (state, forTask) = try await ledger.taskDetail(id: id)
            guard let state else {
                return .object([
                    "status": .string("not_found"),
                    "task_id": .string(id),
                    "reason": .string(forTask.isEmpty ? "no task with id \(id)" : "task_deleted"),
                    "detail": .string((forTask.isEmpty ? "No task has id \(id)" : "Task \(id) was deleted")
                        + "; app {action:\"ledger.list\"} lists the current tasks."),
                ])
            }
            return .object([
                "status": .string("ok"),
                "task": state.toJSON(),
                "events": .array(forTask.dropFirst(offset).prefix(limit).map { $0.toJSON() }),
                "total": .int(Int64(forTask.count)), "limit": .int(Int64(limit)), "offset": .int(Int64(offset)),
                "has_more": .bool(nextOffset < forTask.count),
                "next_offset": nextOffset < forTask.count ? .int(Int64(nextOffset)) : .null,
                "source": .string("shared_task_ledger"),
            ])
        }

        let includeDone = flag(input, "include_done")
        let tasks = try await ledger.listTasks(includeTerminal: includeDone)
        return .object([
            "status": .string("ok"),
            "tasks": .array(tasks.dropFirst(offset).prefix(limit).map { $0.toJSON() }),
            "source": .string("shared_task_ledger"),
            "total": .int(Int64(tasks.count)), "limit": .int(Int64(limit)), "offset": .int(Int64(offset)),
            "has_more": .bool(nextOffset < tasks.count),
            "next_offset": nextOffset < tasks.count ? .int(Int64(nextOffset)) : .null,
            "include_done": .bool(includeDone),
            "note": .string("This is the shared task ledger; desk.read reads your Desk. " + (includeDone ? "Includes open and finished ledger tasks."
                : "Only open ledger tasks are shown; include_done:true also shows finished tasks.")),
        ])
    }

}
