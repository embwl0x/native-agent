import Foundation
import Testing
@testable import NativeAgentApp
import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import TrustCenter
import MacIntegration

@Suite("Discovery first call")
struct DiscoveryFirstCallTests {
    @Test(arguments: [false, true], ["__session_id", "session_id", "sessionId"])
    func verifiedSessionOwnsExplicitLoadAndCatalog(mixed: Bool, sessionKey: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
        let store = inner.activeToolsStore
        let dispatcher = AppChatToolDispatcher(
            inner: inner, activeToolsStore: store,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: root),
            macIntegrationPermissionStore: MacIntegrationPermissionStore(dataRoot: root),
            organismPostureProvider: { nil })
        _ = try await store.addLoaded(sessionId: "B", names: ["telegram_status"])
        let before = await store.load(sessionId: "B")
        let names = ["doctor_status"] + (mixed ? ["market_status"] : [])
        let gated = makeGatedToolDispatchClient(tools: dispatcher, dataRoot: root, verifiedSessionId: "A")
        try await LLMCallContext.$sessionId.withValue("B") {
            _ = try await gated.dispatch(tool: "tool_load", input: [
                sessionKey: .string("B"), "names": .array(names.map(JSONValue.string)),
            ], surface: "chat")
            for tool in ["tool_catalog", "list_tools"] {
                let result = try await gated.dispatch(tool: tool, input: [
                    sessionKey: .string("B"), "query": .string("doctor_status"),
                ], surface: "chat")
                guard case .object(let object) = result else { Issue.record("expected catalog"); continue }
                #expect(object["session_id"] == .string("A"))
            }
        }
        let loaded = await store.load(sessionId: "A")
        #expect(loaded.activeTools == Set(names))
        #expect(Set(loaded.loadOrder) == Set(names))
        #expect(Set(loaded.pinnedSchemas.keys) == Set(names))
        let other = await store.load(sessionId: "B")
        #expect(other.activeTools == before.activeTools)
        #expect(other.loadOrder == before.loadOrder)
        #expect(other.pinnedSchemas == before.pinnedSchemas)
    }

    @Test(arguments: [false, true], ["__session_id", "session_id"])
    func verifiedSessionOwnsAppToolLoadout(unloaded: Bool, sessionKey: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
        let store = inner.activeToolsStore
        let dispatcher = AppChatToolDispatcher(
            inner: inner, activeToolsStore: store,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: root),
            macIntegrationPermissionStore: MacIntegrationPermissionStore(dataRoot: root),
            doctorStatusProvider: { .object(["reached": .bool(true)]) },
            organismPostureProvider: { nil })
        if unloaded {
            _ = try await store.addLoaded(sessionId: "A", names: ["doctor_status"])
            _ = try await dispatcher.dispatch(tool: "tool_unload", input: [
                "session_id": .string("A"), "names": .array([.string("doctor_status")]),
            ], surface: "chat")
        }
        let input: [String: JSONValue] = [sessionKey: .string("B")]
        let gated = makeGatedToolDispatchClient(tools: dispatcher, dataRoot: root, verifiedSessionId: "A")
        // A conflicting compatibility context must also lose to the verified session.
        try await LLMCallContext.$sessionId.withValue("B") {
            let result = try await gated.dispatch(tool: "doctor_status", input: input, surface: "chat")
            guard case .object(let object) = result else { Issue.record("expected envelope"); return }
            #expect(object["reason"] == (unloaded ? .string("not_loaded") : nil))
            #expect(object["reached"] == (unloaded ? nil : .bool(true)))
            try await ChatToolSessionContext.$verifiedSessionId.withValue("A") {
                let refusal = await dispatcher.preApprovalRefusal(tool: "doctor_status", input: input, surface: "chat")
                #expect((refusal != nil) == unloaded)
                let direct = try await dispatcher.dispatch(tool: "doctor_status", input: input, surface: "chat")
                guard case .object(let object) = direct else { Issue.record("expected envelope"); return }
                #expect(object["reason"] == (unloaded ? .string("not_loaded") : nil))
                #expect(object["reached"] == (unloaded ? nil : .bool(true)))
            }
        }
        #expect(await store.load(sessionId: "A").activeTools == (unloaded ? [] : ["doctor_status"]))
        #expect(await store.turnUnloadedNames(sessionId: "A").contains("doctor_status") == unloaded)
        let other = await store.load(sessionId: "B")
        #expect(other.activeTools.isEmpty)
        #expect(other.loadOrder.isEmpty)
        #expect(other.pinnedSchemas.isEmpty)
    }

    @Test(arguments: ["mac.notify", "mobile.notify", "mac_notify", "mobile_notify"])
    func notificationApprovalLoadsOnlyTheCoreSchema(tool: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = tool.replacingOccurrences(of: "_", with: ".")
        try await SwiftNativePersistenceCore().writeJSON(.object([
            "toolAutonomy": .object([
                canonical: .string("confirm"),
                canonical.replacingOccurrences(of: ".", with: "_"): .string("confirm"),
            ]),
        ]), to: root.appendingPathComponent("trust/policy.json"))
        let inner = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
        let store = inner.activeToolsStore
        let security = SwiftNativeSecurityCenter(dataRoot: root)
        let dispatcher = AppChatToolDispatcher(
            inner: inner, activeToolsStore: store, securityCenter: security,
            macIntegrationPermissionStore: MacIntegrationPermissionStore(dataRoot: root),
            organismPostureProvider: { nil })
        let prior = Set((0..<23).map { "existing_\($0)" })
        _ = try await store.addLoaded(sessionId: "notify", names: prior)
        let input: [String: JSONValue] = [
            "__session_id": .string("notify"), "title": .string("Hello"), "body": .string("Ready"),
        ]
        let gated = makeGatedToolDispatchClient(
            tools: dispatcher, dataRoot: root, verifiedSessionId: "notify")
        do {
            _ = try await gated.dispatch(tool: tool, input: input, surface: "chat")
            Issue.record("confirm must require an approval filer")
        } catch let error as AutonomyGateError {
            guard case .notRun(.approvalUnavailable) = error else {
                Issue.record("expected unavailable approval, got \(error)")
                return
            }
        }
        // The model is offered the core schema only; the app still owns the route.
        let loadName = canonical.replacingOccurrences(of: ".", with: "_")
        let state = await store.load(sessionId: "notify")
        #expect(state.activeTools == prior.union([loadName]))
        #expect(state.loadOrder.last == loadName)
        #expect(state.pinnedSchemas[loadName] != nil)
        #expect(state.pinnedSchemas[canonical] == nil)
    }

    @Test(arguments: ["doctor_status", "mac.notify", "mobile_notify"])
    func sameTurnUnloadBlocksAppAutoLoad(tool: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
        let store = inner.activeToolsStore
        let dispatcher = AppChatToolDispatcher(
            inner: inner, activeToolsStore: store,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: root),
            macIntegrationPermissionStore: MacIntegrationPermissionStore(dataRoot: root),
            organismPostureProvider: { nil })
        let canonical = tool == "mobile_notify" ? "mobile.notify" : tool
        _ = try await store.addLoaded(sessionId: "unload", names: [canonical])
        try await LLMCallContext.$turnActiveTools.withValue([canonical]) {
            _ = try await dispatcher.dispatch(tool: "tool_unload", input: [
                "session_id": .string("unload"), "names": .array([.string(tool)]),
            ], surface: "chat")
            let input: [String: JSONValue] = ["__session_id": .string("unload")]
            let refusal = await dispatcher.preApprovalRefusal(tool: tool, input: input, surface: "chat")
            guard case .object(let result) = refusal else { Issue.record("expected refusal"); return }
            #expect(result["reason"] == .string("not_loaded"))
            let dispatched = try await dispatcher.dispatch(tool: tool, input: input, surface: "chat")
            guard case .object(let result) = dispatched else { Issue.record("expected refusal"); return }
            #expect(result["reason"] == .string("not_loaded"))
        }
        #expect(await store.load(sessionId: "unload").activeTools.isEmpty)
        #expect(await store.turnUnloadedNames(sessionId: "unload").contains(canonical))
    }

    @Test(arguments: [false, true])
    func unloadedAppToolRunsThroughTheSameSecurityGate(blocked: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await SwiftNativePersistenceCore().writeJSON(.object([
            "securityPolicy": .object(["killSwitchEnabled": .bool(blocked)]),
        ]), to: root.appendingPathComponent("trust/policy.json"))
        let store = ActiveToolsStore(dataRoot: root)
        let inner = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
        let dispatcher = AppChatToolDispatcher(
            inner: inner, activeToolsStore: store,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: root),
            enforceAutonomySecurity: true,
            doctorStatusProvider: { .object(["status": .string("ok"), "reached": .bool(true)]) },
            organismPostureProvider: { nil })
        let input: [String: JSONValue] = ["__session_id": .string("first-call")]
        let first = try await dispatcher.dispatch(tool: "doctor_status", input: input, surface: "chat")
        let second = try await dispatcher.dispatch(tool: "doctor_status", input: input, surface: "chat")
        guard case .object(let result) = first, case .object(let repeated) = second else {
            Issue.record("expected envelopes"); return
        }
        #expect(result["reason"] != .string("not_loaded"))
        if blocked {
            #expect(result["status"] == .string("blocked"))
            #expect(result["reached"] == nil)
        } else {
            #expect(result["reached"] == .bool(true))
            let loaded = await store.load(sessionId: "first-call")
            #expect(loaded.loadOrder == ["doctor_status"])
            #expect(loaded.pinnedSchemas["doctor_status"] != nil)
        }
        #expect(result["status"] == repeated["status"])
        #expect(result["reached"] == repeated["reached"])
    }
}
