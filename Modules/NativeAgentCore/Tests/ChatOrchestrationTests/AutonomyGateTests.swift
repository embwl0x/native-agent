import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import TrustCenter
import ApprovalInbox

// MARK: - Mocks

actor MockAutonomyResolver: AutonomyResolver {
    private var levelByTool: [String: String]
    private(set) var calls: [String] = []
    private let defaultLevel: String

    init(levels: [String: String], defaultLevel: String = "supervised") {
        self.levelByTool = levels
        self.defaultLevel = defaultLevel
    }

    func autonomyLevel(forTool toolName: String, surface: String) async throws -> String {
        calls.append("\(surface):\(toolName)")
        return levelByTool[toolName] ?? defaultLevel
    }

    func callCount() -> Int { calls.count }
    func calledWith() -> [String] { calls }
}

actor MockApprovalFiler: ApprovalFiler {
    enum Outcome: Sendable {
        case approve
        case deny
        case cancel
        case hang  // never resolves — exercises timeout
    }

    private(set) var filed: [(toolName: String, surface: String, reason: String)] = []
    private let outcome: Outcome
    private let resolveDelayMs: Int
    private var nextId = 1

    init(outcome: Outcome, resolveDelayMs: Int = 0) {
        self.outcome = outcome
        self.resolveDelayMs = resolveDelayMs
    }

    func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async throws -> String {
        filed.append((toolName, surface, reason))
        let id = "appr-\(nextId)"
        nextId += 1
        return id
    }

    func awaitResolution(id: String) async throws -> ApprovalDecision {
        if resolveDelayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(resolveDelayMs) * 1_000_000)
        }
        switch outcome {
        case .approve: return .approved
        case .deny:    return .denied
        case .cancel:  return .canceled
        case .hang:
            // Sleep ~forever (until the surrounding TaskGroup cancels).
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .canceled
        }
    }

    func filedCount() -> Int { filed.count }
    func lastReason() -> String? { filed.last?.reason }
}

actor MockNonBlockingApprovalFiler: NonBlockingApprovalFiler {
    private(set) var filed: [(toolName: String, surface: String, payload: JSONValue, reason: String)] = []

    func fileApprovalRequest(
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async throws -> String {
        filed.append((toolName, surface, payload, reason))
        return "telegram-approval-1"
    }

    func awaitResolution(id: String) async throws -> ApprovalDecision {
        Issue.record("non-blocking filer should not await resolution in dispatcher path")
        return .denied
    }

    func pendingApprovalResult(
        id: String,
        toolName: String,
        surface: String,
        payload: JSONValue,
        reason: String
    ) async -> JSONValue {
        .object([
            "status": .string("waiting_approval"),
            "approvalId": .string(id),
            "tool": .string(toolName),
            "reason": .string(reason),
        ])
    }

    func filedCount() -> Int { filed.count }
    func lastFiled() -> (toolName: String, surface: String, payload: JSONValue, reason: String)? {
        filed.last
    }
}

// MARK: - Tests: decide()

@Test
func decide_auto_returns_allow() async throws {
    let trust = MockAutonomyResolver(levels: ["fast.search": "auto"])
    let gate = AutonomyGate(trust: trust)
    let d = try await gate.decide(toolName: "fast.search", surface: "chat")
    #expect(d == .allow)
}

@Test
func decide_supervised_returns_requireApproval() async throws {
    let trust = MockAutonomyResolver(levels: ["risky.tool": "supervised"])
    let gate = AutonomyGate(trust: trust)
    let d = try await gate.decide(toolName: "risky.tool", surface: "chat")
    if case .requireApproval(let reason) = d {
        #expect(reason.contains("supervised"))
    } else {
        Issue.record("expected requireApproval, got \(d)")
    }
}

@Test
func decide_deny_returns_deny() async throws {
    let trust = MockAutonomyResolver(levels: ["dangerous.tool": "blocked"])
    let gate = AutonomyGate(trust: trust)
    let d = try await gate.decide(toolName: "dangerous.tool", surface: "chat")
    if case .deny(let reason) = d {
        #expect(reason.contains("blocked"))
    } else {
        Issue.record("expected deny, got \(d)")
    }
}

@Test
func decide_unknown_level_returns_requireApproval_safe_default() async throws {
    let trust = MockAutonomyResolver(levels: ["weird.tool": "send_approval"])
    let gate = AutonomyGate(trust: trust)
    let d = try await gate.decide(toolName: "weird.tool", surface: "chat")
    if case .requireApproval = d {
        // ok
    } else {
        Issue.record("expected requireApproval for unknown level, got \(d)")
    }
}

@Test
func decide_uses_trust_autonomyForTool() async throws {
    let trust = MockAutonomyResolver(levels: ["x.tool": "auto"])
    let gate = AutonomyGate(trust: trust)
    _ = try await gate.decide(toolName: "x.tool", surface: "chat")
    let calls = await trust.calledWith()
    #expect(calls == ["chat:x.tool"])
}

// MARK: - Tests: resolveWithApproval()

@Test
func resolveWithApproval_filed_request_then_approved_returns_allow() async throws {
    let trust = MockAutonomyResolver(levels: ["risky.tool": "supervised"])
    let filer = MockApprovalFiler(outcome: .approve)
    let gate = AutonomyGate(trust: trust, approvalFiler: filer)
    let d = try await gate.resolveWithApproval(
        toolName: "risky.tool",
        surface: "chat",
        requestPayload: .object(["k": .string("v")]),
        timeoutSeconds: 5
    )
    #expect(d == .allow)
    let count = await filer.filedCount()
    #expect(count == 1)
    let reason = await filer.lastReason()
    #expect(reason == "autonomy=supervised")
}

@Test
func resolveWithApproval_filed_request_then_denied_returns_deny() async throws {
    let trust = MockAutonomyResolver(levels: ["risky.tool": "supervised"])
    let filer = MockApprovalFiler(outcome: .deny)
    let gate = AutonomyGate(trust: trust, approvalFiler: filer)
    let d = try await gate.resolveWithApproval(
        toolName: "risky.tool",
        surface: "chat",
        requestPayload: .object([:]),
        timeoutSeconds: 5
    )
    if case .deny = d {
        // ok
    } else {
        Issue.record("expected deny, got \(d)")
    }
}

@Test
func resolveWithApproval_timeout_returns_deny() async throws {
    let trust = MockAutonomyResolver(levels: ["slow.tool": "supervised"])
    let filer = MockApprovalFiler(outcome: .hang)
    let gate = AutonomyGate(trust: trust, approvalFiler: filer)
    let d = try await gate.resolveWithApproval(
        toolName: "slow.tool",
        surface: "chat",
        requestPayload: .object([:]),
        timeoutSeconds: 0.1
    )
    if case .deny(let reason) = d {
        #expect(reason.contains("timeout"))
    } else {
        Issue.record("expected deny on timeout, got \(d)")
    }
}

@Test
func resolveWithApproval_no_inbox_wired_throws() async throws {
    let trust = MockAutonomyResolver(levels: ["risky.tool": "supervised"])
    let gate = AutonomyGate(trust: trust, approvalFiler: nil)
    do {
        _ = try await gate.resolveWithApproval(
            toolName: "risky.tool",
            surface: "chat",
            requestPayload: .object([:])
        )
        Issue.record("expected throw, got no error")
    } catch AutonomyGateError.noApprovalInboxWired {
        // ok
    } catch {
        Issue.record("expected noApprovalInboxWired, got \(error)")
    }
}

// MARK: - Tests: dispatchToolWithAutonomyGate end-to-end

private func makeEngineForGateTests(
    tools: any ToolDispatchClient
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: MockPersonaEngineForGate(),
        memory: nil,
        router: MockProviderRoutingForGate(),
        trust: hermeticTrust(),
        llm: MockLLMClientForGate(),
        tools: tools
    )
}

@Test
func dispatchToolWithAutonomyGate_allow_path_calls_tools_dispatch() async throws {
    let tools = MockToolDispatchClient(scripted: ["fast.search": .string("OK")])
    let engine = makeEngineForGateTests(tools: tools)
    let trust = MockAutonomyResolver(levels: ["fast.search": "auto"])
    let gate = AutonomyGate(trust: trust)
    let result = try await engine.dispatchToolWithAutonomyGate(
        toolName: "fast.search",
        toolInput: ["q": .string("hi")],
        surface: "chat",
        tools: tools,
        gate: gate
    )
    #expect(result == .string("OK"))
    #expect(tools.dispatches.count == 1)
    #expect(tools.dispatches[0].tool == "fast.search")
}

@Test
func dispatchToolWithAutonomyGate_deny_throws_toolDenied() async throws {
    let tools = MockToolDispatchClient(scripted: ["bad.tool": .string("NO")])
    let engine = makeEngineForGateTests(tools: tools)
    let trust = MockAutonomyResolver(levels: ["bad.tool": "blocked"])
    let gate = AutonomyGate(trust: trust)
    do {
        _ = try await engine.dispatchToolWithAutonomyGate(
            toolName: "bad.tool",
            toolInput: [:],
            surface: "chat",
            tools: tools,
            gate: gate
        )
        Issue.record("expected throw")
    } catch AutonomyGateError.toolDenied {
        // ok
    } catch {
        Issue.record("expected toolDenied, got \(error)")
    }
    #expect(tools.dispatches.isEmpty)
}

@Test
func dispatchToolWithAutonomyGate_approval_flow_end_to_end() async throws {
    let tools = MockToolDispatchClient(scripted: ["risky.tool": .string("APPROVED")])
    let engine = makeEngineForGateTests(tools: tools)
    let trust = MockAutonomyResolver(levels: ["risky.tool": "supervised"])
    let filer = MockApprovalFiler(outcome: .approve)
    let gate = AutonomyGate(trust: trust, approvalFiler: filer)
    let result = try await engine.dispatchToolWithAutonomyGate(
        toolName: "risky.tool",
        toolInput: ["arg": .int(1)],
        surface: "chat",
        tools: tools,
        gate: gate
    )
    #expect(result == .string("APPROVED"))
    #expect(tools.dispatches.count == 1)
    let filed = await filer.filedCount()
    #expect(filed == 1)
}

@Test
func autonomyGatedDispatcher_nonBlockingFiler_returns_pending_without_dispatching_tool() async throws {
    let tools = MockToolDispatchClient(scripted: ["risky.tool": .string("SHOULD_NOT_RUN")])
    let trust = MockAutonomyResolver(levels: ["risky.tool": "confirm"])
    let filer = MockNonBlockingApprovalFiler()
    let gate = AutonomyGate(trust: trust, approvalFiler: filer)
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("autonomy_nonblocking_\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = AutonomyGatedDispatcher(
        inner: tools,
        gate: gate,
        approvalFiler: filer,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: root),
        hasFiler: true,
        verifiedSessionId: "chat-test"
    )

    let result = try await dispatcher.dispatch(
        tool: "risky.tool",
        input: ["arg": .int(1)],
        surface: "chat"
    )

    guard case .object(let obj) = result else {
        Issue.record("expected pending approval object, got \(result)")
        return
    }
    #expect(obj["status"] == .string("waiting_approval"))
    #expect(obj["approvalId"] == .string("telegram-approval-1"))
    #expect(tools.dispatches.isEmpty)
    #expect(await filer.filedCount() == 1)
    let filed = await filer.lastFiled()
    #expect(filed?.toolName == "risky.tool")
    #expect(filed?.surface == "chat")
    #expect(filed?.reason == "autonomy=confirm")
}

@Test
func autonomyGatedDispatcher_trustedTelegramChatHistoryReadBypassesApprovalFiler() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("telegram_chat_history_auto_\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    // Model the VM policy shape that reproduced the bug: a conservative
    // default and no saved search_chat_history override. The shipped default
    // backfill owns the correction for existing installs.
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "toolAutonomy": .object(["default": .string("send_approval")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )

    let tools = MockToolDispatchClient(scripted: [
        "search_chat_history": .object(["count": .int(1)]),
    ])
    let filer = MockNonBlockingApprovalFiler()
    let trust = SwiftNativeTrustCenter(dataRoot: root, persistence: persistence)
    let gate = AutonomyGate(trust: trust, approvalFiler: filer)
    let dispatcher = AutonomyGatedDispatcher(
        inner: tools,
        gate: gate,
        approvalFiler: filer,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence),
        hasFiler: true,
        verifiedSessionId: "telegram:123"
    )

    let result = try await dispatcher.dispatch(
        tool: "search_chat_history",
        input: ["query": .string("earlier Mac chat")],
        surface: "telegram"
    )

    #expect(result == .object(["count": .int(1)]))
    #expect(tools.dispatches.map(\.tool) == ["search_chat_history"])
    #expect(await filer.filedCount() == 0)
}

@Test
func autonomyGatedDispatcher_fullMacYoloTrustedTelegramMemoryWriteBypassesApprovalFiler() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("telegram_full_mac_memory_auto_\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "toolAutonomy": .object(["default": .string("send_approval")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    try await persistence.writeJSON(
        .object([
            "bot_token": .string("redacted"),
            "allowed_chat_ids": .array([.int(123)]),
        ]),
        to: root.appendingPathComponent("telegram", isDirectory: true).appendingPathComponent("config.json")
    )

    let tools = MockToolDispatchClient(scripted: [
        "commit_memory": .object(["status": .string("committed")]),
    ])
    let filer = MockNonBlockingApprovalFiler()
    let trust = SwiftNativeTrustCenter(dataRoot: root, persistence: persistence)
    let dispatcher = AutonomyGatedDispatcher(
        inner: tools,
        gate: AutonomyGate(trust: trust, approvalFiler: filer),
        approvalFiler: filer,
        securityCenter: SwiftNativeSecurityCenter(dataRoot: root, persistence: persistence),
        hasFiler: true,
        verifiedSessionId: "telegram:123"
    )

    let result = try await dispatcher.dispatch(
        tool: "commit_memory",
        input: [
            "kind": .string("fact"),
            "text": .string("A durable user preference"),
        ],
        surface: "telegram"
    )

    #expect(result == .object(["status": .string("committed")]))
    #expect(tools.dispatches.map(\.tool) == ["commit_memory"])
    #expect(await filer.filedCount() == 0)
}

@Test
func trustCenter_fullMacYoloDoesNotTrustRemoteSurfaceLabelAloneOrRemoveHardFloors() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("telegram_full_mac_origin_boundary_\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()
    try await persistence.writeJSON(
        .object([
            "permissionLevel": .string("full_mac_os"),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "toolAutonomy": .object(["default": .string("send_approval")]),
        ]),
        to: root.appendingPathComponent("trust", isDirectory: true).appendingPathComponent("policy.json")
    )
    let trust = SwiftNativeTrustCenter(dataRoot: root, persistence: persistence)

    let untrustedMemory = try await trust.autonomyLevel(
        forTool: "commit_memory",
        surface: "telegram",
        originTrusted: false
    )
    let untrustedFileWrite = try await trust.autonomyLevel(
        forTool: "write_file",
        surface: "telegram",
        originTrusted: false
    )
    let trustedExternalWrite = try await trust.autonomyLevel(
        forTool: "github_set_repo_visibility",
        surface: "telegram",
        originTrusted: true
    )

    #expect(untrustedMemory == "send_approval")
    #expect(untrustedFileWrite != "auto")
    #expect(trustedExternalWrite == "confirm")
}

// MARK: - Throwaway protocol stubs for SwiftNativeTurnEngine construction

import PersonaEngine
import MemoryV2
import ProviderRouting

final class MockPersonaEngineForGate: PersonaEngineProtocol, @unchecked Sendable {
    func listPersonaDocs() async throws -> [PersonaDoc] { [] }
    func getPersonaDoc(id: String) async throws -> PersonaDoc? { nil }
}

final class MockProviderRoutingForGate: ProviderRoutingProtocol, @unchecked Sendable {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { Provider(id: id) }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider { Provider(id: id) }
    func testProvider(id: String) async throws -> ProviderTestResult {
        ProviderTestResult(rawResponse: .object([:]))
    }
    func getModelPreferences() async throws -> ModelPreferences {
        ModelPreferences()
    }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences {
        ModelPreferences()
    }
    func computeModelPreferences() async throws -> [String: SurfacePreference] { [:] }
}

final class MockLLMClientForGate: LLMClient, @unchecked Sendable {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        "mock"
    }
}
