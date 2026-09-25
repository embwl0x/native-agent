import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import MacIntegration
@testable import ChatOrchestration

@Suite struct CatalogSpinReplayTests {
    @Test func catalogExplainsDisabledPermissionsAndRefreshesAfterTheyChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        for enabled in [false, true] {
            try await SwiftNativePersistenceCore().writeJSON(.object([
                "permissionLevel": .string("full_mac_os"), "fullMacNeverExpires": .bool(true),
                "developerMode": .bool(true), "macControlPolicy": .object([
                    "enabled": .bool(true), "accessibility_allowed": .bool(enabled),
                ]),
            ]), to: root.appendingPathComponent("trust/policy.json"))
            let result = try await dispatcher.dispatch(tool: "tool_catalog", input: [
                "query": .string("desktop mouse keyboard click"), "__session_id": .string("permissions")
            ], surface: "chat")
            guard case .object(let fields) = result,
                  case .string(let availability)? = fields["availability"] else { Issue.record("Missing availability"); return }
            #expect(availability.contains("Mac control is off") == !enabled)
            let names = try await dispatcher.listAvailableTools()
            #expect(names.contains("act") == enabled)
        }
        let mail = try await dispatcher.dispatch(tool: "tool_catalog", input: [
            "query": .string("mail_send"), "__session_id": .string("permissions")
        ], surface: "chat")
        guard case .object(let fields) = mail,
              case .string(let availability)? = fields["availability"] else { Issue.record("Missing mail availability"); return }
        #expect(availability.contains("Mac Integration permissions"))
        #expect(availability.contains("Mail sending is off"))
        #expect(!availability.contains("enable"))
        #expect(!availability.contains("mail_send"))
        for query in ["find an email", "read mail", "find mail_send", "read shell commands", "inspect Mac control", "write a workspace file", "email"] {
            let result = try await dispatcher.dispatch(tool: "tool_catalog", input: ["query": .string(query)], surface: "chat")
            guard case .object(let fields) = result else { Issue.record("Missing result"); return }
            #expect(fields["unavailable_matches"] == .array([]), "Unexpected notice for \(query)")
        }
        try await MacIntegrationPermissionStore(dataRoot: root).set(integrationId: "mail", read: true, write: true)
        let enabledMail = try await dispatcher.dispatch(tool: "tool_catalog", input: ["query": .string("send an email")], surface: "chat")
        guard case .object(let enabledFields) = enabledMail else { Issue.record("Missing result"); return }
        #expect(enabledFields["unavailable_matches"] == .array([]))
    }

    @Test func unavailableMacControlAndRepeatedSearchesStayInformative() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await SwiftNativePersistenceCore().writeJSON(.object([
            "permissionLevel": .string("balanced"), "developerMode": .bool(false),
            "outsideWorkspaceDefault": .string("deny"),
            "macControlPolicy": .object(["enabled": .bool(false)]),
        ]), to: root.appendingPathComponent("trust/policy.json"))
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let session = "catalog-replay"
        _ = await dispatcher.activeToolsStore.beginTurn(sessionId: session)
        let queries = ["frontmost window select settings tab", "open NativeAgent settings page visibly with Mac UI control",
                       "Desktop permission control mouse keyboard click app window"]
        for index in 0..<15 {
            let result = try await dispatcher.dispatch(tool: "tool_catalog", input: [
                "query": .string(queries[index % queries.count]), "__session_id": .string(session), "limit": .int(1), "load": .bool(false)
            ], surface: "chat")
            guard case .object(let fields) = result else { Issue.record("Expected catalog result"); return }
            #expect(fields["status"] == .string("ok"))
            #expect(fields["searches_this_turn"] == .int(Int64(index + 1)))
            #expect(fields["no_tools_loaded_since_previous_search"] == .bool(index > 0))
            guard case .string(let summary)? = fields["availability"] else { Issue.record("Missing summary"); return }
            #expect(summary.contains("Mac control is off in Work mode."))
            #expect(!summary.contains("enable"))
            #expect(!summary.contains("Tools:"))
            if case .array(let matches)? = fields["matches"] { #expect(matches.count <= 1) }
            else { Issue.record("Missing matches") }
            if index > 0 { #expect(summary.contains("capped by limit")) }
        }
        for (query, note) in [("run shell commands", "Shell commands"), ("write files outside the workspace", "File writes outside the workspace"), ("send a message", "Messages sending")] {
            let result = try await dispatcher.dispatch(tool: "tool_catalog", input: ["query": .string(query)], surface: "chat")
            guard case .object(let fields) = result, case .array(let notes)? = fields["unavailable_matches"] else { Issue.record("Missing notes"); return }
            #expect(notes.count == 1)
            if case .string(let text)? = notes.first { #expect(text.hasPrefix(note)) }
            else { Issue.record("Missing note") }
        }
        try await dispatcher.activeToolsStore.addLoaded(sessionId: session, names: ["market_quote"])
        let progress = await dispatcher.activeToolsStore.recordCatalogSearch(sessionId: session, active: ["market_quote"])
        #expect(!progress.noNewTools)
        _ = await dispatcher.activeToolsStore.beginTurn(sessionId: session)
        let nextTurn = await dispatcher.activeToolsStore.recordCatalogSearch(sessionId: session, active: ["market_quote"])
        #expect(nextTurn.count == 1)
        #expect(!nextTurn.noNewTools)
    }
}
