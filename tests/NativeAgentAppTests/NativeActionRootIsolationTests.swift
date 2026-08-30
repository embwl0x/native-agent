import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

@Suite("Native action selected-root isolation")
struct NativeActionRootIsolationTests {
    @Test func nativeActionsExecuteAndReloadReceiptsInTheirSelectedRoot() async throws {
        let fixture = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for label in ["first", "second"] {
            let repo = fixture.appendingPathComponent(label)
            let root = try prepareRepo(repo)
            let file = repo.appendingPathComponent("fixture.txt")
            try Data("content-\(label)".utf8).write(to: file)
            let context = try NativeClient.strictDispatchContextForTool(
                "read_file", surface: "native_actions", dataRoot: root
            )
            try #require(context.repoRoot == repo.path)
            try #require(context.extra["_na_data_root"] == .string(root.path))
            let client = NativeClient(baseURL: "", dataRootOverride: root)
            let time = try await client.runNativeAction(id: "time_now", dryRun: false)
            let read = try await client.runNativeAction(
                id: "read_file", dryRun: false, input: ["path": "fixture.txt"]
            )
            #expect(time.status == "ok")
            #expect(read.status == "ok")
            let receipts = try await client.getNativeActionReceipts()
            #expect(Set(receipts.map(\.id)) == Set([time.id, read.id]))
            let rows = try jsonRows(NativeClient.nativeActionReceiptsPath(dataRoot: root))
            let row = try #require(rows.first { $0["id"] as? String == read.id })
            let result = try #require(row["output"] as? [String: Any])
            let output = try #require(result["output"] as? [String: Any])
            #expect(output["content"] as? String == "content-\(label)")
            let dispatchRunID = try #require(result["runId"] as? String)
            let traces = try String(contentsOf: root.appendingPathComponent("traces/events.jsonl"), encoding: .utf8)
            #expect(traces.contains(dispatchRunID))
            #expect(!traces.contains("content-\(label == "first" ? "second" : "first")"))
        }
    }

    @Test func workflowNativeActionOuterReceiptUsesTheSameRootAsItsWorkflow() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("workflows")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        [{"id":"selected-root","name":"Selected root","status":"active","engineVersion":"2","steps":[{"id":"trace","title":"Trace","kind":"trace"}]}]
        """.utf8).write(to: directory.appendingPathComponent("registry.json"))
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let receipt = try await client.runNativeAction(
            id: "workflow.launch", dryRun: true, input: ["workflowId": "selected-root"]
        )
        #expect(receipt.status == "dry_run")
        #expect(try await client.getNativeActionReceipts().map(\.id) == [receipt.id])
        let runs = try jsonRows(directory.appendingPathComponent("runs.jsonl"))
        #expect(runs.count == 1)
        #expect(runs[0]["mode"] as? String == "dry_run")
    }

    @Test func explicitRootOverridesReadContextWithoutChangingOrdinaryDefaults() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let normal = try NativeClient.strictDispatchContextForTool("workspace_list", surface: "native_actions")
        #expect(normal.extra.isEmpty)
        let selected = try NativeClient.strictDispatchContextForTool(
            "workspace_list", surface: "native_actions", dataRoot: root
        )
        #expect(selected.extra["_na_data_root"] == .string(root.path))
        #expect(selected.extra["_na_workspace_root"] == .string(root.appendingPathComponent("workspace").path))
        #expect(throws: (any Error).self) {
            _ = try NativeClient.strictDispatchContextForTool("read_file", surface: "native_actions", dataRoot: root)
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-action-roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func prepareRepo(_ repo: URL) throws -> URL {
        let root = repo.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for marker in ["persona/SOUL.template.md", "script/init_persona.sh", "Package.swift"] {
            let path = repo.appendingPathComponent(marker)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: path)
        }
        return root
    }

    private func jsonRows(_ path: URL) throws -> [[String: Any]] {
        try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}
