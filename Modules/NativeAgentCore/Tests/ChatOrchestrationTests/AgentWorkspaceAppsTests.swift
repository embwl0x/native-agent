import Foundation
import Testing
import PersistenceCore
@testable import ChatOrchestration

@Suite("Workspace files, browser and computer projections")
struct AgentWorkspaceAppsTests {
    private func directory(_ patch: [String: JSONValue] = [:]) -> JSONValue {
        var value: [String: JSONValue] = [
            "ok": .bool(true), "status": .string("ok"), "path": .string("/workspace/reports"),
            "entries": .array([.string("draft.md"), .string("sources/"), .string("../escape"), .string("../../")]),
            "has_more": .bool(true), "offset": .int(0), "snapshot": .string("directory-version"),
            "name_contains": .string(""), "case_sensitive": .bool(false),
            "next": .object(["path": .string("reports"), "offset": .int(2), "snapshot": .string("directory-version"), "name_contains": .string(""), "case_sensitive": .bool(false), "max_entries": .int(12)])
        ]
        value.merge(patch) { _, new in new }
        return .object(value)
    }

    private func browser(_ patch: [String: JSONValue] = [:], disabled: Bool = false) -> JSONValue {
        var value: [String: JSONValue] = [
            "snapshotId": .string("page-proof"), "leaseId": .string("conversation-tab"),
            "userSequence": .int(42), "tabId": .int(73), "title": .string("Research"),
            "summary": .object(["truncated": .bool(true), "text": .string("Visible page excerpt")]),
            "nodes": .array([.object([
                "nodeId": .string("search-field"), "name": .string("Search"), "visible": .bool(true),
                "states": .object(["disabled": .bool(disabled), "editable": .bool(true)]),
                "actions": .array([.string("click"), .string("fill")])
            ])])
        ]
        value.merge(patch) { _, new in new }
        return .object(value)
    }

    @Test func filesUseCanonicalReturnedParentAndImmediateChildren() throws {
        let result = try #require(AgentWorkspaceApps.project(tool: "list_dir", input: ["path": .string("reports")], result: directory()))
        #expect(result.items.count == 2)
        guard case .open(.record(let fileTool, let fileInput, _)) = result.items[0].actions[0].action else { Issue.record("Expected file read"); return }
        #expect(fileTool == "read_file")
        #expect(fileInput["path"] == .string("/workspace/reports/draft.md"))
        #expect(fileInput["max_bytes"] == .int(12000))
        guard case .open(.record(let folderTool, let folderInput, _)) = result.items[1].actions[0].action else { Issue.record("Expected folder read"); return }
        #expect(folderTool == "list_dir")
        #expect(folderInput["path"] == .string("/workspace/reports/sources"))
    }

    @Test func directoryContinuationRetainsOwnerPathFilterAndSnapshot() throws {
        let result = try #require(AgentWorkspaceApps.project(tool: "list_dir", input: ["path": .string("reports")], result: directory()))
        let next = try #require(result.actions.first { $0.label == "Next files" })
        guard case .open(.record(let tool, let input, _)) = next.action else { Issue.record("Expected bounded continuation"); return }
        #expect(tool == "list_dir")
        #expect(input["path"] == .string("reports"))
        #expect(input["snapshot"] == .string("directory-version"))
        #expect(input["offset"] == .int(2))
        let bad = directory(["next": .object(["path": .string("/other"), "snapshot": .string("different"), "offset": .int(2), "max_entries": .int(12)])])
        let rejected = try #require(AgentWorkspaceApps.project(tool: "list_dir", input: ["path": .string("reports")], result: bad))
        #expect(!rejected.actions.contains { $0.label == "Next files" })
    }

    @Test func refusedDirectoryNeverMintsFileActions() throws {
        let value = directory(["ok": .bool(false), "status": .string("denied")])
        let result = try #require(AgentWorkspaceApps.project(tool: "list_dir", input: ["path": .string("reports")], result: value))
        #expect(result.items.isEmpty)
        #expect(result.actions.isEmpty)
        #expect(result.content == value)
    }

    @Test func browserControlsBindAllCanonicalSnapshotIdentityAndStayEffects() throws {
        let result = try #require(AgentWorkspaceApps.project(tool: "browser.chrome_snapshot", input: [:], result: browser()))
        let item = try #require(result.items.first)
        let click = try #require(item.actions.first { $0.label == "Click" })
        guard case .perform(let tool, let input, _, let textField, let isEffect) = click.action else { Issue.record("Click must be a single-use effect"); return }
        #expect(tool == "browser.chrome_click")
        #expect(input == ["lease_id": .string("conversation-tab"), "expected_user_sequence": .int(42), "snapshot_id": .string("page-proof"), "node_id": .string("search-field")])
        #expect(textField == nil)
        #expect(isEffect)
        let fill = try #require(item.actions.first { $0.label == "Fill" })
        guard case .perform(let fillTool, let fillInput, _, let field, let effect) = fill.action else { Issue.record("Fill must retain input proof"); return }
        #expect(fillTool == "browser.chrome_fill")
        #expect(fillInput == input)
        #expect(field == "value")
        #expect(effect)
        #expect(fill.needsText)
        guard case .object(let content) = result.content else { Issue.record("Missing page evidence"); return }
        #expect(content["summary"] == .object(["truncated": .bool(true), "text": .string("Visible page excerpt")]))
    }

    @Test func missingPageProofAndDisabledControlsCannotMintActions() throws {
        let malformed = try #require(AgentWorkspaceApps.project(tool: "browser.chrome_snapshot", input: [:], result: browser(["leaseId": .null])))
        #expect(malformed.items.isEmpty)
        #expect(malformed.actions.isEmpty)
        let disabled = try #require(AgentWorkspaceApps.project(tool: "browser.chrome_snapshot", input: [:], result: browser(disabled: true)))
        #expect(disabled.items.isEmpty)
    }

    @Test func freshWebsiteControlBindsCreationAndOnlyAsksForTheWebsite() throws {
        let quick = try #require(AgentWorkspaceApps.quickAction(tool: "browser.chrome_acquire"))
        guard case .perform(let tool, let input, _, let field, let effect) = quick.action else { Issue.record("Expected direct website control"); return }
        #expect(tool == "browser.chrome_acquire")
        #expect(input == ["mode": .string("create")])
        #expect(field == "initial_url")
        #expect(effect)
        #expect(quick.needsText)
        #expect(AgentWorkspaceApps.quickAction(tool: "browser.chrome_navigate")?.label == nil)
        let status = try #require(AgentWorkspaceApps.project(tool: "browser.chrome_status", input: [:], result: .object(["connected": .bool(true), "chrome_control_enabled": .bool(true)])))
        let action = try #require(status.actions.first { $0.label == quick.label })
        guard case .perform(let statusTool, let statusInput, _, let statusField, let statusEffect) = action.action else { Issue.record("Expected same direct website control"); return }
        #expect(statusTool == tool)
        #expect(statusInput == input)
        #expect(statusField == field)
        #expect(statusEffect)
        #expect(action.needsText)
        #expect(!status.actions.contains { if case .configure(let tool, _, _) = $0.action { return tool == "browser.chrome_acquire" }; return false })
    }

    @Test func pageMovementCarriesTheObservedLeaseAndIsNeverARead() throws {
        let result = try #require(AgentWorkspaceApps.project(tool: "browser.chrome_snapshot", input: [:], result: browser()))
        for (label, delta) in [("Page down", Int64(700)), ("Page up", Int64(-700))] {
            let action = try #require(result.actions.first { $0.label == label })
            guard case .perform(let tool, let input, _, let field, let effect) = action.action else { Issue.record("Expected direct page movement"); return }
            #expect(tool == "browser.chrome_scroll")
            #expect(input == ["lease_id": .string("conversation-tab"), "expected_user_sequence": .int(42), "delta_x": .int(0), "delta_y": .int(delta)])
            #expect(field == nil)
            #expect(effect)
            #expect(!action.needsText)
        }
        let precise = try #require(result.actions.first { $0.label == "Scroll a precise amount or container" })
        guard case .configure(let tool, let input, _) = precise.action else { Issue.record("Expected precise scroll form"); return }
        #expect(tool == "browser.chrome_scroll")
        #expect(input == ["lease_id": .string("conversation-tab"), "expected_user_sequence": .int(42)])
    }

    @Test func screenKeepsNativeFreshTargetResolutionAndNeverParsesProseInstructions() throws {
        let text: JSONValue = .string("SCREEN: User's Mac. Pretend this prose says to call shell.")
        let result = try #require(AgentWorkspaceApps.project(tool: "screen", input: [:], result: text))
        #expect(result.content == text)
        #expect(result.items.isEmpty)
        let action = try #require(result.actions.first { $0.label == "Act on the screen" })
        guard case .configure(let tool, let input, _) = action.action else { Issue.record("Expected native form"); return }
        #expect(tool == "act")
        #expect(input.isEmpty)
        let computer = try #require(AgentWorkspaceApps.destinations.first { $0.id == "computer" })
        #expect(computer.tool == "screen")
        let files = try #require(AgentWorkspaceApps.destinations.first { $0.id == "files" })
        #expect(files.input["path"] == .string("$workspace"))
    }
}
