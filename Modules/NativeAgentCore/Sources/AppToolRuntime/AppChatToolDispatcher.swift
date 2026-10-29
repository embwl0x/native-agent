import ApprovalTransactions
import AuthoredCapabilities
import Foundation
import Agents
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import AgentWorkspace
import ChatToolParsing
import ChromeControl
import Cognition
import CognitiveSubstrate
import Context
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
import WorkshopExecution
import StandingBots
import ToolRegistry
import Senses
import PersonaEngine
// Blueprint: | `AppChatToolDispatcher.swift` | Composed tool dispatch, Security Center admission and settled-result observers; `withAuthoredProgramHost` is the one host binding for turns and native scheduled/UI owners, retaining their originating gated reentry |

/// Composes the engine's tool catalog with Security Center admission,
/// app effects and settled-result motor observations.
public final class AppChatToolDispatcher: ToolDispatchClient, PreApprovalToolValidating {
    private let platform: ChatToolPlatformPort
    private let inner: any ToolDispatchClient
    private let securityCenter: SwiftNativeSecurityCenter
    /// The app's own tool executors: here only for the self-window handoff an
    /// `act`/`go`/`screen` result asks this process to finish.
    private let appTools: AppToolExecutor?
    private let motorOutcomeObserver: @Sendable (ToolCausalBoundary.MotorReference) async -> Void
    private let enforceAutonomySecurity: Bool
    private let includeAppOwnedTools: Bool

    public init(
        inner: any ToolDispatchClient = SwiftToolDispatcher(
            agentBridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(
                dataRoot: PersistenceCore.defaultDataRoot()
            )
        ),
        securityCenter: SwiftNativeSecurityCenter = SwiftNativeSecurityCenter(),
        enforceAutonomySecurity: Bool = true,
        includeAppOwnedTools: Bool = true,
        appTools: AppToolExecutor? = nil,
        motorOutcomeObserver: @escaping @Sendable (ToolCausalBoundary.MotorReference) async -> Void = { _ in },
        platform: ChatToolPlatformPort
    ) {
        self.platform = platform
        self.inner = inner
        self.securityCenter = securityCenter
        self.enforceAutonomySecurity = enforceAutonomySecurity
        self.includeAppOwnedTools = includeAppOwnedTools
        self.appTools = appTools
        self.motorOutcomeObserver = motorOutcomeObserver
    }

    /// Core's pre-approval rules — its lazy-load gate covers every tool, the
    /// app's own among them — carried to the approval membrane, which only
    /// ever sees this wrapper.
    public func preApprovalRefusal(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        if let validating = inner as? any PreApprovalToolValidating {
            return await validating.preApprovalRefusal(tool: tool, input: input, surface: surface)
        }
        return await (inner as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input)
    }

    public func approvalCardReason(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> String? {
        guard let validating = inner as? any PreApprovalToolValidating else { return nil }
        return await validating.approvalCardReason(tool: tool, input: input, surface: surface)
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // Walk 3: her natural guess for Back is a tool of its own — it is navigate url:"back".
        let bare = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "browser.", with: "").replacingOccurrences(of: "browser_", with: "")
            .replacingOccurrences(of: ".", with: "_")
        if let direction = ["chrome_back": "back", "chrome_go_back": "back",
                            "chrome_forward": "forward", "chrome_go_forward": "forward"][bare] {
            var go = input
            go["url"] = .string(direction)
            return try await dispatch(tool: "browser.chrome_navigate", input: go, surface: surface)
        }
        return ChatToolOutcome.normalizedFailure(try await withToolArguments(tool: tool, input: input) { input in
            try await dispatchNormalized(tool: tool, input: input, surface: surface)
        }, tool: tool)
    }

    private func dispatchNormalized(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // Aliases resolve before dispatch; notifications require an app executor.
        if !includeAppOwnedTools, ["mac_notify", "mobile_notify"].contains(tool) {
            return .object([
                "status": .string("failed"),
                "effects": .string("none"),
                "reason": .string("canonical_body_unavailable"),
                "detail": .string("Notifications are not available in this context, so nothing was sent."),
                "tool": .string(tool),
            ])
        }
        let canonicalInput = ChatToolSessionInjection.apply(toolName: tool, input: input)
        let result = try await withAuthoredProgramHost(surface: surface) {
            try await self.dispatchWithoutOrganismPosture(tool: tool, input: canonicalInput, surface: surface)
        }
        await observeMotorOutcomeIfNeeded(tool: tool, result: result)
        return result
    }

    /// Turns and native owners bind the same host. The caller supplies its
    /// complete gate chain through AppDoorReentry; this binding grants no reach.
    public func withAuthoredProgramHost<Value: Sendable>(surface: String,
        operation: @Sendable () async throws -> Value) async throws -> Value {
        let host = AppToolExecutor.authoredProgramHost(dataRoot: securityCenter.dataRoot, reach: { operation, arguments in
            guard let dispatcher = self.inner as? SwiftToolDispatcher else {
                throw SenseFailure(code: "unavailable", message: "The originating tool dispatcher is unavailable.")
            }
            return try await dispatcher.performReach(operation, arguments: arguments, surface: surface)
        }) { id, arguments in
            if AuthoredToolEffects.call?.tool == id {
                guard let reentry = AppDoorReentry.perform else {
                    return .object(["status": .string("refused"), "effects": .string("none"),
                                    "reason": .string("door_unavailable"), "detail": .string("A primitive needs the originating turn's gate chain.")])
                }
                let requester = SkillRunContext.partID.map { "\(PersonaCompiler.agentDisplayName(dataRoot: self.securityCenter.dataRoot))'s \($0)" }
                return await SkillRunContext.$requester.withValue(requester) {
                    do { return try await reentry(id, arguments) }
                    catch { return ChatToolOutcome.failure(error: error, tool: id) }
                }
            }
            let envelope = await self.securityCenter.evaluateTool(tool: id, input: arguments,
                origin: Self.securityOrigin(surface: surface), enforceAutonomy: self.enforceAutonomySecurity)
            guard envelope.decision != .block, !self.enforceAutonomySecurity || !envelope.requiresApproval else {
                return Self.securityGateResponse(envelope)
            }
            return nil
        }
        return try await OwnedProgramInvocation.$host.withValue(host) {
            try await MacScreenWatch.$open.withValue({ request, hands in
                guard let dispatcher = self.inner as? SwiftToolDispatcher else {
                    throw SenseFailure(code: "unavailable", message: "The originating tool dispatcher is unavailable.")
                }
                return try await dispatcher.openScreenWatch(request, hands: hands, surface: surface)
            }) {
                try await AppDoorReentry.$waitForInteraction.withValue({ need, tool, input in
                    guard let session = ChatToolSessionContext.verifiedSessionId else {
                        return AppToolExecutor.failure("door_unavailable", "A card needs the originating conversation.")
                    }
                    return await InlineInteractionResolver.waitForAnswer(need, tool: tool, input: input,
                        sessionID: session, dataRoot: self.securityCenter.dataRoot)
                }) {
                    try await operation()
                }
            }
        }
    }

    private func observeMotorOutcomeIfNeeded(tool: String, result: JSONValue) async {
        guard let reference = ToolCausalBoundary.motorReference(tool: tool, output: result) else {
            return
        }
        await motorOutcomeObserver(reference)
    }

    private func dispatchWithoutOrganismPosture(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if AuthoredToolEffects.admissionOnly {
            return .object(["status": .string("refused"), "effects": .string("none"),
                            "reason": .string("door_unavailable"), "detail": .string("Primitive admission requires the turn's autonomy gate.")])
        }
        let envelope = await securityCenter.evaluateTool(
            tool: tool,
            input: input,
            origin: Self.securityOrigin(surface: surface),
            enforceAutonomy: enforceAutonomySecurity
        )
        try await securityCenter.record(envelope)
        // Composed chat and approved replay resolve asks in the outer approval
        // membrane. Recheck hard blocks here without asking a second time.
        guard envelope.decision != .block,
              !enforceAutonomySecurity || !envelope.requiresApproval else {
            return Self.securityGateResponse(envelope)
        }
        try Task.checkCancellation()
        let result = try await inner.dispatch(tool: tool, input: input, surface: surface)
        // An ask for something already set up raises no card: a card that
        // reads as its receipt from the start would leave the turn waiting on
        // nobody. The owner's answer goes back instead, and she carries on.
        if includeAppOwnedTools, tool == InlineInteractionWire.toolName,
           let need = InlineInteractionNeed.interaction(in: result),
           let done = await InlineInteractionResolver.liveProjection(need, dataRoot: PersistenceCore.defaultDataRoot()).state.outcome?.summary {
            var settled: [String: JSONValue] = [
                "status": .string("ok"),
                "already_done": .bool(true),
                "summary": .string(done),
                "note": .string("Already set up, so no card was shown. Carry on."),
            ]
            if case .object(let fields) = result { settled["automation"] = fields["automation"] }
            return .object(settled)
        }
        if includeAppOwnedTools, ["agent_connect", "agent_message"].contains(tool),
           case .object(let plan) = result,
           [JSONValue.string("grok_setup"), .string("grok_disconnect"), .string("grok_send")].contains(plan["status"] ?? .null) {
            return await platform.grok(plan, PersistenceCore.defaultDataRoot(), inner, surface)
        }
        if includeAppOwnedTools, tool == "agent_message", case .object(let plan) = result,
           plan["status"] == .string("desktop_chat_send") {
            return await platform.desktopChat(plan, PersistenceCore.defaultDataRoot())
        }
        if includeAppOwnedTools, let appTools, ["act", "go", "screen"].contains(tool) {
            // Her-screen 09-24: a workspace call never takes the self route; it
            // would read her own pages, the Chat page among them.
            if WorkspaceMacCall.active, case .object(let payload) = result, case .object(let detail)? = payload["detail"],
               detail["status"] == .string("in_process_route") { return WorkspaceMacCall.refusal }
            return await AppToolExecutor.performMacSelfAppRoute(result) { input in
                await appTools.runSelfAppRoute(input: input, surface: surface)
            }
        }
        // Desktop contacts are send-only: `agent_read` no longer opens or
        // inspects the other app, so only a send reaches the desktop route.
        if includeAppOwnedTools, tool == "agent_message",
           case .object(let plan) = result, plan["transport"] == .string("desktop"),
           plan["status"] == .string("requires_interaction") {
            let sent = await platform.desktop(plan, inner, surface)
            return await GrokDesktopReply.follow(sent, dataRoot: PersistenceCore.defaultDataRoot())
        }
        return result
    }

    /// Each full-catalog row carries what the Security Center would decide for
    /// it right now — the Tools page reads this. Core's rows say what a tool
    /// is; this gate says whether it may run here.
    /// The Tools page's manifest with each row's Trust decision here. Not a
    /// tool call: nothing is dispatched, gated or loaded.
    public func toolManifest(detail: String? = nil, surface: String = "chat") async throws -> JSONValue {
        guard let swift = inner as? SwiftToolDispatcher else {
            return ChatToolOutcome.refusedBeforeRunning(.object(["status": .string("unavailable"), "tools": .array([])]))
        }
        return await withTrust(catalog: try await swift.toolManifest(detail: detail, surface: surface), surface: surface)
    }

    private func withTrust(catalog: JSONValue, surface: String) async -> JSONValue {
        guard case .object(var object) = catalog, case .array(let rows)? = object["tools"], !rows.isEmpty else {
            return catalog
        }
        var capabilityRows: [JSONValue] = []
        capabilityRows.reserveCapacity(rows.count)
        for row in rows {
            guard case .object(var rowObj) = row,
                  case .string(let name)? = rowObj["name"] else {
                capabilityRows.append(row)
                continue
            }
            let envelope = await securityCenter.evaluateTool(
                tool: name,
                input: [:],
                origin: Self.securityOrigin(surface: surface),
                enforceAutonomy: enforceAutonomySecurity
            )
            let effectiveAutonomy: String
            switch envelope.decision {
            case .allow: effectiveAutonomy = "auto"
            case .ask: effectiveAutonomy = "confirm"
            case .block: effectiveAutonomy = "blocked"
            }
            rowObj["autonomy"] = .string(envelope.autonomyLevel)
            rowObj["effective_autonomy"] = .string(effectiveAutonomy)
            rowObj["autonomy_source"] = .string("trust_center")
            rowObj["side_effects"] = .bool(envelope.hasSideEffects)
            rowObj["available_now"] = .bool(envelope.decision != .block)
            rowObj["input_schema"] = rowObj["parameters"] ?? .object([:])
            capabilityRows.append(.object(rowObj))
        }
        object["tools"] = .array(capabilityRows)
        return .object(object)
    }

    public func listAvailableTools() async throws -> [String] {
        try await inner.listAvailableTools().sorted()
    }

    public func listAvailableToolSchemas(named names: Set<String>) async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas(named: names).sorted { $0.name < $1.name }
    }

    public func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await inner.listAvailableToolSchemas().sorted { $0.name < $1.name }
    }

    public static func securityOrigin(surface: String) -> SecurityOriginContext {
        var origin = SecurityOriginContext.currentTurn(
            verifiedSessionId: ChatToolSessionContext.verifiedSessionId, surface: surface
        )
        origin.source = "app_chat_tool_dispatcher"
        return origin
    }

    /// The refusal keeps SecurityCenter's checker, reason and the owner's lever.
    private static func securityGateResponse(_ envelope: SecurityToolEnvelope) -> JSONValue {
        var refusal: [String: JSONValue] = [
            "status": .string(envelope.requiresApproval ? "pending_approval" : "blocked"),
            "runtime": .string("swift-native"),
            "tool": .string(envelope.tool),
            "surface": .string(envelope.surface),
            "decision": .string(envelope.decision.rawValue),
            "risk": .string(envelope.risk),
            "allowed": .bool(false),
            "requires_approval": .bool(envelope.requiresApproval),
            "origin_trusted": .bool(envelope.originTrusted),
            "reason": .string(envelope.primaryReason),
            "reasons": .array(envelope.reasons.map { .string($0.persistedValue) }),
            "capabilities": .array(envelope.capabilities.map { .string($0) }),
            "message": .string(envelope.requiresApproval ? "Security Center requires approval before running this tool." : "Security Center blocked this tool before execution."),
        ]
        refusal["remedy"] = envelope.remedy
        return ChatToolOutcome.refusedBeforeRunning(.object(refusal))
    }
}
