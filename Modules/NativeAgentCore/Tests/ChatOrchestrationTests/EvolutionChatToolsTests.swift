import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Evolution chat tools dispatcher-surface tests (U2b, 2026-06-11)
//
// The three privileged self-evolution chat tools — evolution_propose,
// evolution_status, self_install — wired through the privileged-chat-tool
// safety stack. These tools do NOT spawn a Process; they manipulate the
// EvolutionProposalStore (propose/status) and stage a self_evolution.apply
// approval card (self_install). All three are Full-Mac-gated at the catalog +
// dispatch layers, default autonomy `confirm`, FileAccess-blocked in
// none/read_only, and reach their app-side backend through an injected
// EvolutionToolBridge (nil → bridge_not_wired envelope, never a throw).

@Suite("EvolutionChatTools")
struct EvolutionChatToolsTests {

    // MARK: - Fakes

    /// In-memory EvolutionToolBridge. Records call counts and asserts the
    /// install trigger is NEVER fired (self_install only STAGES a card).
    final class FakeEvolutionBridge: EvolutionToolBridge, @unchecked Sendable {
        // Tests call these methods sequentially (no concurrency), so plain
        // counters are safe; @unchecked Sendable carries the contract.
        private(set) var proposeCalls = 0
        private(set) var statusCalls = 0
        private(set) var stageInstallCalls = 0
        /// MUST stay false — the bridge stages a card; it never installs.
        private(set) var installEverTriggered = false
        var seededStatus = "proposed"  // non-green → not_installable

        func evolutionPropose(input: [String: JSONValue]) async throws -> JSONValue {
            proposeCalls += 1
            return .object([
                "status": .string("ok"),
                "id": .string("evo_fake_1"),
                "proposal_status": .string("proposed"),
                "echo_title": input["title"] ?? .null,
            ])
        }

        func evolutionStatus(input: [String: JSONValue]) async throws -> JSONValue {
            statusCalls += 1
            return .object([
                "status": .string("ok"),
                "count": .int(1),
                "proposals": .array([.object(["id": .string("evo_fake_1")])]),
            ])
        }

        func evolutionStageInstall(input: [String: JSONValue]) async throws -> JSONValue {
            stageInstallCalls += 1
            // Non-green → honest not_installable. NEVER set installEverTriggered.
            return .object([
                "status": .string("not_installable"),
                "id": input["proposal_id"] ?? .null,
                "proposal_status": .string(seededStatus),
                "reason": .string("not installable yet: status=\(seededStatus)"),
            ])
        }
    }

    /// Permissive inner used only to prove FileAccessGatedDispatcher blocks
    /// BEFORE reaching the real tools.
    final class PermissiveInner: ToolDispatchClient, @unchecked Sendable {
        func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
            .object(["status": .string("ok"), "tool": .string(tool)])
        }
        func listAvailableTools() async throws -> [String] { [] }
        func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
    }

    // MARK: - Helpers

    private func tempRoot(_ tag: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvolutionChatTools-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Seed a Full-Mac trust policy under <dataRoot>/trust/policy.json so the
    /// dispatch-time file_ops gate opens (mirrors ChatOrchestrationClientTests).
    private func seedFullMac(_ dataRoot: URL) throws {
        let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let policy: JSONValue = .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(true),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object([
                "outsideWorkspaceDefault": .string("allow"),
                "requireBackupBeforeWrite": .bool(false),
                "allowDestructiveActions": .bool(true),
            ]),
            "macControlPolicy": .object([
                "enabled": .bool(true),
                "file_ops_allowed": .bool(true),
                "system_control_allowed": .bool(true),
                "accessibility_allowed": .bool(true),
                "shell_allowed": .bool(true),
                "remote_from_ios_allowed": .bool(true),
                "approval_required_for": .array([]),
            ]),
        ])
        try policy.serializedData(pretty: true)
            .write(to: dir.appendingPathComponent("policy.json"))
    }

    // MARK: - L1 catalog gating

    @Test func catalogHidesEvolutionToolsWhenFullMacOff() {
        let dispatcher = SwiftToolDispatcher(dataRoot: tempRoot("catalog-off"))
        let schemas = dispatcher.builtInToolSchemas(includeFullMacFileTools: false)
        let names = Set(schemas.map { $0.name })
        #expect(!names.contains("evolution_propose"))
        #expect(!names.contains("evolution_status"))
        #expect(!names.contains("self_install"))
    }

    @Test func catalogExposesEvolutionToolsWhenFullMacOn() throws {
        let dispatcher = SwiftToolDispatcher(dataRoot: tempRoot("catalog-on"))
        let schemas = dispatcher.builtInToolSchemas(includeFullMacFileTools: true)
        let names = Set(schemas.map { $0.name })
        #expect(names.contains("evolution_propose"))
        #expect(names.contains("evolution_status"))
        #expect(names.contains("self_install"))

        // evolution_propose: title + evidence required, diff_text/expected_head optional.
        let propose = try #require(schemas.first { $0.name == "evolution_propose" })
        let pParsed = try JSONValue.parse(propose.parametersJSON)
        guard case .object(let po) = pParsed,
              case .object(let pprops)? = po["properties"],
              case .array(let preq)? = po["required"] else {
            Issue.record("evolution_propose schema malformed"); return
        }
        #expect(preq == [.string("title"), .string("evidence")])
        #expect(pprops["diff_text"] != nil)
        #expect(pprops["expected_head"] != nil)

        // self_install: proposal_id required.
        let install = try #require(schemas.first { $0.name == "self_install" })
        let iParsed = try JSONValue.parse(install.parametersJSON)
        guard case .object(let io) = iParsed, case .array(let ireq)? = io["required"] else {
            Issue.record("self_install schema malformed"); return
        }
        #expect(ireq == [.string("proposal_id")])

        // evolution_status: proposal_id optional.
        let status = try #require(schemas.first { $0.name == "evolution_status" })
        let sParsed = try JSONValue.parse(status.parametersJSON)
        guard case .object(let so) = sParsed, case .array(let sreq)? = so["required"] else {
            Issue.record("evolution_status schema malformed"); return
        }
        #expect(sreq == [])
    }

    @Test func evolutionToolsAreFullMacGatedNames() {
        #expect(SwiftToolDispatcher.fullMacEvolutionToolNames
            == ["evolution_propose", "evolution_status", "self_install"])
        // Not always-on core (privileged, lazy-loaded under Full Mac).
        for name in SwiftToolDispatcher.fullMacEvolutionToolNames {
            #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains(name))
        }
    }

    // MARK: - L3 SecurityCenter profile risk

    @Test func securityProfile_evolutionPropose_isCriticalWrite() async throws {
        let center = SwiftNativeSecurityCenter(dataRoot: tempRoot("sec-propose"))
        let env = await center.evaluateTool(
            tool: "evolution_propose",
            input: ["title": .string("x"), "evidence": .string("y")],
            origin: SecurityOriginContext(surface: "chat"))
        #expect(env.risk == "critical")
        #expect(env.capabilities.contains("evolution_write"))
        #expect(env.signedToolKnown)
        #expect(!env.capabilities.contains("shell"))
        #expect(!env.capabilities.contains("process_spawn"))
    }

    @Test func securityProfile_selfInstall_isCriticalApplyTrigger() async throws {
        let center = SwiftNativeSecurityCenter(dataRoot: tempRoot("sec-install"))
        let env = await center.evaluateTool(
            tool: "self_install",
            input: ["proposal_id": .string("evo_1")],
            origin: SecurityOriginContext(surface: "chat"))
        #expect(env.risk == "critical")
        #expect(env.capabilities.contains("evolution_apply_trigger"))
        #expect(env.signedToolKnown)
        // The `install` keyword must NOT mis-tag it medium filesystem_write.
        #expect(!env.capabilities.contains("filesystem_write"))
        #expect(!env.capabilities.contains("process_spawn"))
    }

    @Test func securityProfile_evolutionStatus_isLowRead() async throws {
        let center = SwiftNativeSecurityCenter(dataRoot: tempRoot("sec-status"))
        let env = await center.evaluateTool(
            tool: "evolution_status",
            input: [:],
            origin: SecurityOriginContext(surface: "chat"))
        #expect(env.risk == "low")
        #expect(env.capabilities.contains("safe_read"))
        #expect(env.signedToolKnown)
        #expect(!env.capabilities.contains("evolution_write"))
    }

    // MARK: - L4 FileAccess gating (none + read_only block all three)

    @Test func fileAccessNoneBlocksAllThree() async throws {
        let gated = FileAccessGatedDispatcher(inner: PermissiveInner(), fileAccess: "none")
        for tool in ["evolution_propose", "evolution_status", "self_install"] {
            await #expect(throws: (any Error).self) {
                _ = try await gated.dispatch(tool: tool, input: [:], surface: "chat")
            }
        }
    }

    @Test func fileAccessReadOnlyBlocksAllThree() async throws {
        let gated = FileAccessGatedDispatcher(inner: PermissiveInner(), fileAccess: "read_only")
        for tool in ["evolution_propose", "evolution_status", "self_install"] {
            await #expect(throws: (any Error).self) {
                _ = try await gated.dispatch(tool: tool, input: [:], surface: "chat")
            }
        }
    }

    // MARK: - L2 dispatch routes to the injected bridge (Full Mac on)

    @Test func dispatchRoutesProposeAndStatusToBridge() async throws {
        let root = tempRoot("dispatch-bridge")
        defer { try? FileManager.default.removeItem(at: root) }
        try seedFullMac(root)
        let fake = FakeEvolutionBridge()
        let dispatcher = SwiftToolDispatcher(dataRoot: root, evolutionBridge: fake)

        let proposeResult = try await dispatcher.dispatch(
            tool: "evolution_propose",
            input: ["title": .string("Improve X"), "evidence": .string("usage shows Y")],
            surface: "chat")
        guard case .object(let pobj) = proposeResult else {
            Issue.record("propose did not return object"); return
        }
        #expect(pobj["status"] == .string("ok"))
        #expect(pobj["id"] == .string("evo_fake_1"))
        #expect(fake.proposeCalls == 1)

        let statusResult = try await dispatcher.dispatch(
            tool: "evolution_status", input: [:], surface: "chat")
        guard case .object(let sobj) = statusResult else {
            Issue.record("status did not return object"); return
        }
        #expect(sobj["status"] == .string("ok"))
        #expect(fake.statusCalls == 1)
    }

    @Test func dispatchSelfInstallNonGreenReturnsHonestEnvelopeNeverInstalls() async throws {
        let root = tempRoot("dispatch-install")
        defer { try? FileManager.default.removeItem(at: root) }
        try seedFullMac(root)
        let fake = FakeEvolutionBridge()
        fake.seededStatus = "proposed"  // not candidate_green
        let dispatcher = SwiftToolDispatcher(dataRoot: root, evolutionBridge: fake)

        let result = try await dispatcher.dispatch(
            tool: "self_install",
            input: ["proposal_id": .string("evo_fake_1")],
            surface: "chat")
        guard case .object(let obj) = result else {
            Issue.record("self_install did not return object"); return
        }
        #expect(obj["status"] == .string("not_installable"))
        if case .string(let reason)? = obj["reason"] {
            #expect(reason.contains("status=proposed"))
        } else {
            Issue.record("missing reason on not_installable envelope")
        }
        #expect(fake.stageInstallCalls == 1)
        // The hard invariant: the bridge NEVER triggers an install.
        #expect(fake.installEverTriggered == false)
    }

    // MARK: - nil bridge → bridge_not_wired (Full Mac on, but no bridge)

    @Test func nilBridgeReturnsBridgeNotWired() async throws {
        let root = tempRoot("nil-bridge")
        defer { try? FileManager.default.removeItem(at: root) }
        try seedFullMac(root)
        // No evolutionBridge injected.
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        for tool in ["evolution_propose", "evolution_status", "self_install"] {
            let result = try await dispatcher.dispatch(
                tool: tool, input: ["proposal_id": .string("evo_x")], surface: "chat")
            guard case .object(let obj) = result else {
                Issue.record("\(tool) did not return object"); return
            }
            #expect(obj["status"] == .string("failed"))
            #expect(obj["reason"] == .string("bridge_not_wired"))
            #expect(obj["tool"] == .string(tool))
        }
    }
}
