import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import WorkshopExecution

// MARK: - workshop_submit / workshop_status dispatcher-surface tests (U5 W-I)
//
// The agent's directed execution chat lane: it could neither submit nor check an execution from
// chat (zero mission_* hits anywhere in ChatOrchestration; her own honest
// refusal caught it). These are STANDARD tools — no Process spawn —
// classified LAZY-LOAD (catalog-visible + builtInToolNames, NOT
// alwaysOnCoreNames), the same shape as scheduler_create_job.
//
// workshop_submit is a thin shim into SwiftNativeWorkshopRunner.submit pointed
// at THIS dispatcher's dataRoot. In a no-credentials test env the production
// planner throws and the runner falls back to a stub plan, so submit() still
// enqueues hermetically against the tmp root — the queue lands under
// <dataRoot>/workshop/executions/. workshop_status reads that same on-disk queue.

@Suite("WorkshopChatToolDispatch")
struct WorkshopExecutionChatToolDispatchTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopChatToolDispatch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func hermeticDispatcher(_ root: URL) -> SwiftToolDispatcher {
        SwiftToolDispatcher(dataRoot: root)
    }

    // MARK: Catalog + schema

    @Test func catalogAdvertisesWorkshopToolsInAlwaysOnBlock() async throws {
        let dispatcher = hermeticDispatcher(hermeticRoot())
        // includeFullMacFileTools=false → only the ALWAYS-ON catalog block.
        // Both Workshop execution tools must appear here (standard tools, NOT Full-Mac
        // gated). "Always-on catalog block" ≠ "always-LOADED" — lazy-load is
        // governed by alwaysOnCoreNames membership, asserted separately below.
        let schemas = dispatcher.builtInToolSchemas(includeFullMacFileTools: false)

        let submit = try #require(schemas.first { $0.name == "workshop_submit" })
        #expect(submit.description.contains("Desk's execution lane"))
        #expect(submit.description.contains("retained for compatibility"))
        #expect(!submit.description.contains("user-directed Workshop task"))
        let submitParsed = try JSONValue.parse(submit.parametersJSON)
        guard case .object(let so) = submitParsed,
              case .object(let sprops)? = so["properties"],
              case .array(let sreq)? = so["required"] else {
            Issue.record("workshop_submit schema is not a well-formed object"); return
        }
        #expect(sreq == [.string("text")])
        #expect(sprops["text"] != nil)
        #expect(sprops["context"] != nil)
        guard case .object(let operationSchema)? = sprops["operation"],
              case .array(let operationValues)? = operationSchema["enum"] else {
            Issue.record("workshop_submit operation is not enum-constrained"); return
        }
        #expect(operationValues == [.string("copy_workspace_file")])
        guard case .object(let procedureSchema)? = sprops["procedure"],
              case .array(let procedureValues)? = procedureSchema["enum"] else {
            Issue.record("workshop_submit procedure is not enum-constrained"); return
        }
        #expect(procedureValues == [.string("local_file_copy_v1")])
        #expect(sprops["source"] != nil)
        #expect(sprops["destination"] != nil)

        let status = try #require(schemas.first { $0.name == "workshop_status" })
        let statusParsed = try JSONValue.parse(status.parametersJSON)
        guard case .object(let sto) = statusParsed,
              case .object(let stprops)? = sto["properties"],
              case .array(let streq)? = sto["required"] else {
            Issue.record("workshop_status schema is not a well-formed object"); return
        }
        #expect(streq == [])  // id optional
        #expect(stprops["id"] != nil)

        #expect(status.description.contains("Desk's directed task execution status"))
        #expect(status.description.contains("retained for compatibility"))
    }

    @Test func workshopToolsAreLazyLoadedBuiltIns() {
        // Catalog-visible + dispatchable after a tool_load, but NOT hot core:
        // a user submits/checks an execution occasionally, so they ride the
        // lazy-load lane (same as scheduler_create_job) — they must NOT be in
        // alwaysOnCoreNames (keeps the hot-core budget at 21).
        #expect(SwiftToolDispatcher.builtInToolNames.contains("workshop_submit"))
        #expect(SwiftToolDispatcher.builtInToolNames.contains("workshop_status"))
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("workshop_submit"))
        #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains("workshop_status"))
    }

    // MARK: workshop_submit — empty-text rejection (hermetic; throws before runner)

    @Test func emptyTextRejectedBeforeRunner() async throws {
        let dispatcher = hermeticDispatcher(hermeticRoot())
        await #expect(throws: (any Error).self) {
            _ = try await dispatcher.impl_workshop_submit(input: ["text": .string("   ")])
        }
        await #expect(throws: (any Error).self) {
            _ = try await dispatcher.impl_workshop_submit(input: ["text": .string("")])
        }
    }

    @Test func workshopNamesReachTheDispatchBoundary() async throws {
        let dispatcher = hermeticDispatcher(hermeticRoot())
        await #expect(throws: (any Error).self) {
            _ = try await dispatcher.dispatch(
                tool: "workshop_submit",
                input: ["text": .string("   ")],
                surface: "chat"
            )
        }
        let result = try await dispatcher.dispatch(
            tool: "workshop_status",
            input: [:],
            surface: "chat"
        )
        guard case .object(let object) = result else {
            Issue.record("workshop_status did not return an object"); return
        }
        #expect(object["status"] == .string("ok"))
    }

    @Test func missingTextRejected() async throws {
        let dispatcher = hermeticDispatcher(hermeticRoot())
        await #expect(throws: (any Error).self) {
            _ = try await dispatcher.impl_workshop_submit(input: ["context": .string("title only")])
        }
    }

    // MARK: workshop_submit — happy-path round trip against the tmp queue

    @Test func submitEnqueuesAndStatusReadsItBack() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = hermeticDispatcher(root)

        let submitResult = try await dispatcher.impl_workshop_submit(input: [
            "text": .string("Draft a summary of yesterday's commits"),
            "context": .string("commit-summary"),
        ])
        guard case .object(let sub) = submitResult else {
            Issue.record("workshop_submit did not return an object"); return
        }
        // Honest queued envelope with a real id (NOT a `failed` envelope).
        #expect(sub["status"] == .string("queued"))
        guard case .string(let executionId)? = sub["id"], !executionId.isEmpty else {
            Issue.record("workshop_submit returned no id: \(sub)"); return
        }
        guard case .string(let deskHandle)? = sub["desk_handle"], !deskHandle.isEmpty else {
            Issue.record("workshop_submit returned no Desk identity: \(sub)"); return
        }

        // Shadow cutover: the authoritative User-facing task exists on the Desk
        // before the compatibility executor record is exposed.
        let desk = try await SwiftNativeDeskStore(dataRoot: root).liveState()
        let deskItem = try #require(desk.items.first { $0.handle == deskHandle })
        #expect(deskItem.origin == .owner)
        #expect(deskItem.status == .now)
        #expect(deskItem.refs.contains { ref in
            if case .trace(let id, let kind) = ref.kind {
                return id == executionId && kind == "workshop_execution"
            }
            return false
        })

        // The runner wrote the queue under <dataRoot>/workshop/executions/<id>/.
        let executionRecordJSON = root
            .appendingPathComponent("workshop/executions/\(executionId)/execution.json")
        #expect(FileManager.default.fileExists(atPath: executionRecordJSON.path))

        // workshop_status (no id) lists it as active.
        let listResult = try await dispatcher.impl_workshop_status(input: [:])
        guard case .object(let list) = listResult,
              case .array(let active)? = list["active"] else {
            Issue.record("workshop_status list missing active array: \(listResult)"); return
        }
        let activeIds: [String] = active.compactMap {
            if case .object(let o) = $0, case .string(let id)? = o["id"] { return id }
            return nil
        }
        #expect(activeIds.contains(executionId))

        // workshop_status (with id) returns detail + a receipts summary.
        let detailResult = try await dispatcher.impl_workshop_status(input: [
            "id": .string(executionId)
        ])
        guard case .object(let det) = detailResult,
              det["status"] == .string("ok"),
              case .object(let execution)? = det["execution"] else {
            Issue.record("workshop_status detail malformed: \(detailResult)"); return
        }
        #expect(execution["id"] == .string(executionId))
        #expect(execution["desk_handle"] == .string(deskHandle))
        #expect(execution["receipts_summary"] != nil)
    }

    // MARK: workshop_status — honest unknown-id error

    @Test func statusUnknownIdReturnsHonestNotFound() async throws {
        let dispatcher = hermeticDispatcher(hermeticRoot())
        let result = try await dispatcher.impl_workshop_status(input: [
            "id": .string("does-not-exist-\(UUID().uuidString)")
        ])
        guard case .object(let obj) = result else {
            Issue.record("workshop_status did not return object"); return
        }
        #expect(obj["status"] == .string("not_found"))
        #expect(obj["execution"] == nil)  // no fabricated empty record
    }

    @Test func statusEmptyQueueListsNoWorkshopExecutions() async throws {
        let dispatcher = hermeticDispatcher(hermeticRoot())
        let result = try await dispatcher.impl_workshop_status(input: [:])
        guard case .object(let obj) = result,
              case .array(let active)? = obj["active"],
              case .array(let recent)? = obj["recent"] else {
            Issue.record("workshop_status list malformed: \(result)"); return
        }
        #expect(obj["status"] == .string("ok"))
        #expect(active.isEmpty)
        #expect(recent.isEmpty)
    }

    // MARK: workshop_submit — policy-off refusal surfaces as honest envelope

    @Test func submitWithWorkshopPolicyOffReturnsForbiddenEnvelope() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Seed a trust policy that explicitly disables Workshop executions (and no
        // developerMode) → the runner's workshopExecutionsAllowed() gate refuses.
        let trustDir = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
        let policy: JSONValue = .object([
            "missionPolicy": .object(["enabled": .bool(false)]),
        ])
        try policy.serializedData(pretty: true)
            .write(to: trustDir.appendingPathComponent("policy.json"))

        let dispatcher = hermeticDispatcher(root)
        let result = try await dispatcher.impl_workshop_submit(input: [
            "text": .string("do a thing")
        ])
        guard case .object(let obj) = result else {
            Issue.record("workshop_submit did not return object"); return
        }
        // Honest failed envelope (NOT a thrown crash, NOT a fabricated queued).
        #expect(obj["status"] == .string("failed"))
        #expect(obj["error"] == .string("forbidden"))
        #expect(obj["id"] == nil)
    }

    @Test func redundantExactOperationAndProcedureCanonicalizeWithoutRetryTrap() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trustDir = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)
        try JSONValue.object([
            "missionPolicy": .object(["enabled": .bool(false)]),
        ]).serializedData(pretty: true)
            .write(to: trustDir.appendingPathComponent("policy.json"))

        let result = try await hermeticDispatcher(root).impl_workshop_submit(input: [
            "text": .string("Copy exact bytes"),
            "operation": .string("copy_workspace_file"),
            "procedure": .string("local_file_copy_v1"),
            "source": .string("procedure-lab/source.txt"),
            "destination": .string("procedure-lab/output.txt"),
        ])
        guard case .object(let object) = result else {
            Issue.record("redundant exact pair returned a non-object"); return
        }
        #expect(object["status"] == .string("failed"))
        #expect(object["reason"] != .string("provide operation or procedure, not both"))
        #expect(object["reason"] != .string("operation and procedure identify conflicting routes"))
    }
}
