import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import DeskCore
import SenseCore
import MindCore
import ProviderRouting
import MacNerves
// Blueprint: | `DeskActions+TaskLedgerTools.swift` | `SwiftToolDispatcher`; the shared paged task ledger |

// MARK: - Task ledger tools

extension SwiftToolDispatcher {
    /// The shared flock covers append, compaction and the newest-5000 cap; pin actor identity to prevent impersonation.
    func impl_task_ledger_post(input: TaskLedgerPostArgs) async throws -> JSONValue {
        let kindRaw = input.kind
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = TaskLedgerKind(rawValue: kindRaw) else {
            throw AutonomyGateError.toolDenied(
                reason: "task_ledger_post: unknown kind '\(kindRaw)' (expected one of \(TaskLedgerKind.allCases.map(\.rawValue).joined(separator: "/")))"
            )
        }
        // taskId is required for follow-up events; for `created` we mint one when omitted so the model can open a fresh task without a round-trip.
        let providedTaskId = input.taskID.trimmedNonEmpty
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
        let title = input.title.trimmedNonEmpty
        let note = input.note.trimmedNonEmpty
        let refs = (input.refs ?? []).compactMap(\.trimmedNonEmpty)

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
                guard let expectedTitle = nonblankDoorText(input.expectedTitle), !expectedTitle.isEmpty else {
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
    func impl_task_ledger_list(input: TaskLedgerListArgs) async throws -> JSONValue {
        let ledger = SwiftNativeTaskLedger(dataRoot: dataRoot)
        for (key, supplied) in [("limit", input.limit), ("offset", input.offset)] {
            guard let value = supplied else { continue }
            guard value >= (key == "limit" ? 1 : 0), value <= (key == "limit" ? 100 : 1_000_000) else {
                throw ToolFailureError("\(key) is outside its allowed range.", argumentPath: "$.\(key)", effects: .none, code: "invalid_input")
            }
        }
        let limit = input.limit ?? 25
        let offset = input.offset ?? 0
        // Input bounds above keep this sum at or below 1_000_100.
        let nextOffset = offset + limit
        let id = input.taskID.trimmedNonEmpty

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

        let includeDone = (input.includeDone ?? false)
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
