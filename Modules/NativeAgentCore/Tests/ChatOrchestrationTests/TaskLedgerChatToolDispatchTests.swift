import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// MARK: - task_ledger_post / task_ledger_list dispatcher-surface tests (U6)
//
// The cross-agent task ledger chat lane. task_ledger_post is a medium WRITE
// (appends an event under the shared flock; bridge-DENIED); task_ledger_list is
// a read (bridge-ALLOWED). Classified LAZY-LOAD (catalog-visible +
// builtInToolNames, NOT alwaysOnCoreNames), same shape as the mission tools.

@Suite("TaskLedgerChatToolDispatch")
struct TaskLedgerChatToolDispatchTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskLedgerChatTool-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func dispatcher(_ root: URL) -> SwiftToolDispatcher {
        SwiftToolDispatcher(dataRoot: root)
    }

    // MARK: Catalog + schema

    @Test func catalogAdvertisesLedgerToolsInAlwaysOnBlock() async throws {
        let d = dispatcher(hermeticRoot())
        let schemas = d.builtInToolSchemas(includeFullMacFileTools: false)

        let post = try #require(schemas.first { $0.name == "task_ledger_post" })
        let postParsed = try JSONValue.parse(post.parametersJSON)
        guard case .object(let po) = postParsed,
              case .object(let pprops)? = po["properties"],
              case .array(let preq)? = po["required"] else {
            Issue.record("task_ledger_post schema malformed"); return
        }
        #expect(preq == [.string("kind")])
        #expect(pprops["task_id"] != nil)
        #expect(pprops["refs"] != nil)

        let list = try #require(schemas.first { $0.name == "task_ledger_list" })
        let listParsed = try JSONValue.parse(list.parametersJSON)
        guard case .object(let lo) = listParsed, case .array(let lreq)? = lo["required"] else {
            Issue.record("task_ledger_list schema malformed"); return
        }
        #expect(lreq == [])  // task_id optional
    }

    @Test func ledgerToolsAreLazyLoadedBuiltIns() {
        #expect(SwiftToolDispatcher.builtInToolNames.contains("task_ledger_post"))
        #expect(SwiftToolDispatcher.builtInToolNames.contains("task_ledger_list"))
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("task_ledger_post"))
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("task_ledger_list"))
    }

    // MARK: post → list round-trip

    @Test func postThenListReadsItBack() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        // created mints a task id when omitted.
        let created = try await d.impl_task_ledger_post(input: [
            "kind": .string("created"),
            "title": .string("Ship U6"),
        ])
        guard case .object(let c) = created, c["status"] == .string("ok"),
              case .string(let taskId)? = c["task_id"], !taskId.isEmpty else {
            Issue.record("post created malformed: \(created)"); return
        }

        // An update on the same task.
        _ = try await d.impl_task_ledger_post(input: [
            "kind": .string("update"),
            "task_id": .string(taskId),
            "note": .string("wiring done"),
            "refs": .array([.string("SwarmExecutor.swift")]),
        ])

        // The event posts AS agent (the in-app tool can't impersonate others).
        let list = try await d.impl_task_ledger_list(input: [:])
        guard case .object(let l) = list, case .array(let tasks)? = l["tasks"] else {
            Issue.record("list malformed: \(list)"); return
        }
        let mine = try #require(tasks.first {
            if case .object(let o) = $0, o["taskId"] == .string(taskId) { return true }
            return false
        })
        guard case .object(let t) = mine else { Issue.record("task not object"); return }
        #expect(t["status"] == .string("update"))
        #expect(t["title"] == .string("Ship U6"))
        #expect(t["lastNote"] == .string("wiring done"))

        // Detail branch returns the event timeline.
        let detail = try await d.impl_task_ledger_list(input: ["task_id": .string(taskId)])
        guard case .object(let det) = detail, det["status"] == .string("ok"),
              case .array(let events)? = det["events"] else {
            Issue.record("detail malformed: \(detail)"); return
        }
        #expect(events.count == 2)
        // Both events are posted as the in-app assistant.
        for ev in events {
            if case .object(let o) = ev { #expect(o["actor"] == .string("assistant")) }
        }
    }

    // MARK: honest refusals

    @Test func postUnknownKindRejected() async throws {
        let d = dispatcher(hermeticRoot())
        await #expect(throws: (any Error).self) {
            _ = try await d.impl_task_ledger_post(input: ["kind": .string("frobnicate")])
        }
    }

    @Test func nonCreatedKindRequiresTaskId() async throws {
        let d = dispatcher(hermeticRoot())
        await #expect(throws: (any Error).self) {
            _ = try await d.impl_task_ledger_post(input: ["kind": .string("update")])
        }
    }

    @Test func listUnknownTaskReturnsNotFound() async throws {
        let d = dispatcher(hermeticRoot())
        let res = try await d.impl_task_ledger_list(input: ["task_id": .string("nope-\(UUID().uuidString)")])
        guard case .object(let o) = res else { Issue.record("not object"); return }
        #expect(o["status"] == .string("not_found"))
    }

    @Test func listEmptyLedgerReturnsEmptyTasks() async throws {
        let d = dispatcher(hermeticRoot())
        let res = try await d.impl_task_ledger_list(input: [:])
        guard case .object(let o) = res, case .array(let tasks)? = o["tasks"] else {
            Issue.record("malformed: \(res)"); return
        }
        #expect(o["status"] == .string("ok"))
        #expect(tasks.isEmpty)
    }
}
