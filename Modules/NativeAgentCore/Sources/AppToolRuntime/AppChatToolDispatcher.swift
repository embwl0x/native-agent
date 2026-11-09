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
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
import StandingBots
import ToolRegistry
import Senses
import PersonaEngine
// Blueprint: | `AppChatToolDispatcher.swift` | `withAuthoredProgramHost`; Gated dispatch and settled-result observation |

/// The composed dispatcher shares admission and settled-result observations with the engine's catalog.
public final class AppChatToolDispatcher: ToolDispatchClient, PreApprovalToolValidating {
    private let platform: ChatToolPlatformPort
    private let scopedInner: @Sendable (AppActionExecution) -> any ToolDispatchClient
    private let actionExecution: AppActionExecution
    private let securityCenter: SwiftNativeSecurityCenter
    /// App executors finish self-window handoffs inside the originating act/go/screen call.
    private let appTools: AppToolExecutor?
    private let motorOutcomeObserver: @Sendable (ToolCausalBoundary.MotorReference) async -> Void
    private let enforceAutonomySecurity: Bool
    private let includeAppOwnedTools: Bool

    public init(
        securityCenter: SwiftNativeSecurityCenter = SwiftNativeSecurityCenter(),
        enforceAutonomySecurity: Bool = true,
        includeAppOwnedTools: Bool = true,
        appTools: AppToolExecutor? = nil,
        motorOutcomeObserver: @escaping @Sendable (ToolCausalBoundary.MotorReference) async -> Void = { _ in },
        platform: ChatToolPlatformPort,
        scopedInner: @escaping @Sendable (AppActionExecution) -> any ToolDispatchClient,
        actionExecution: AppActionExecution
    ) {
        self.scopedInner = scopedInner
        self.actionExecution = actionExecution
        self.platform = platform
        self.securityCenter = securityCenter
        self.enforceAutonomySecurity = enforceAutonomySecurity
        self.includeAppOwnedTools = includeAppOwnedTools
        self.appTools = appTools
        self.motorOutcomeObserver = motorOutcomeObserver
    }

    /// Carry Core's complete pre-approval gate to the approval membrane, which sees only this wrapper.
    public func preApprovalRefusal(
        turn: Turn, invocation: ChatToolInvocation,
        tool: String, input: [String: JSONValue], surface: String
    ) async -> JSONValue? {
        let execution = actionExecution.receiving(invocation)
        if let validating = scopedInner(execution) as? any PreApprovalToolValidating {
            return await validating.preApprovalRefusal(turn: turn, invocation: invocation, tool: tool, input: input, surface: surface)
        }
        return await (scopedInner(execution) as? any PureToolArgumentValidating)?.argumentRefusal(tool: tool, input: input, turn: turn)
    }

    public func approvalCardReason(
        tool: String, input: [String: JSONValue], surface: String
    ) async -> String? {
        guard let validating = scopedInner(actionExecution) as? any PreApprovalToolValidating else { return nil }
        return await validating.approvalCardReason(tool: tool, input: input, surface: surface)
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
        invocation: ChatToolInvocation) async throws -> JSONValue {
        let execution = actionExecution.receiving(invocation)
        return try await dispatch(tool: tool, input: input, surface: surface, turn: turn, execution: execution)
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
        execution: AppActionExecution) async throws -> JSONValue {
        let result: JSONValue
        do {
            result = ChatToolOutcome.normalizedFailure(try await withToolArguments(turn: turn, invocation: execution.invocation,
                tool: tool, input: input, surface: surface) { input, invocation in
                var execution = execution
                execution.invocation = invocation
                return try await MacAppActGate.withAdmission(origin: Self.securityOrigin(turn: turn, surface: surface), dataRoot: securityCenter.dataRoot,
                    turn: turn, context: execution.macOperation(dataRoot: securityCenter.dataRoot)) { admittedTurn, context in
                    var execution = execution
                    execution.invocation = execution.invocation.serving(mac: context)
                    return try await dispatchNormalized(tool: tool, input: input, surface: surface, turn: admittedTurn, execution: execution)
                }
            }, tool: tool)
        } catch {
            let filed = await filePermissionRemedy(in: ChatToolOutcome.failure(error: error, tool: tool), input: input, surface: surface, turn: turn,
                execution: execution)
            if filed.objectValue?["permission_card"] != nil { return filed }
            throw error
        }
        let withCards = await fileBatchNeeds(in: result, tool: tool, input: input, surface: surface, turn: turn, execution: execution)
        return await filePermissionRemedy(in: withCards, input: input, surface: surface, turn: turn, execution: execution)
    }

    /// File per-file needs before scripts/lists wrap them; the card owner must not replay exports that may already have files.
    private func fileBatchNeeds(in result: JSONValue, tool: String, input: [String: JSONValue], surface: String, turn: Turn,
        execution: AppActionExecution) async -> JSONValue {
        guard input["preview"] != .bool(true), !Task.isCancelled, !execution.handsBack,
              case .object(var fields) = result, fields["needCards"] == nil,
              fields["status"] == .string("partial"),
              case .array(let envelopes)? = fields[InlineInteractionWire.needsKey] else { return result }
        var filings: [JSONValue] = []
        var retainedEnvelopes = envelopes
        var retainedIDs: [String: String] = [:]
        for (index, envelope) in envelopes.enumerated() {
            guard let need = InlineInteractionNeed.interaction(in: envelope),
                  !InlineInteractionNeed.blocksTurn(need) else { continue }
            guard let session = turn.verifiedSessionID else {
                filings.append(.object(["id": .string(need.id), "status": .string("unavailable"),
                    "detail": .string("No card was filed: this call has no originating conversation.")]))
                continue
            }
            if let filed = await InlineInteractionResolver.raise(need, sessionID: session,
                requestingTool: tool,
                origin: TurnEnvelope.current(turn: turn, surface: surface), turn: turn, dataRoot: securityCenter.dataRoot) {
                retainedEnvelopes[index] = InlineInteractionNeed.envelope(invocation: execution.invocation, filed)
                retainedIDs[need.id] = filed.id
                filings.append(.object(["id": .string(filed.id), "session_id": .string(session),
                    "status": .string("filed")]))
            } else {
                filings.append(.object(["id": .string(need.id), "status": .string("unavailable"),
                    "detail": .string("The card could not be saved; inspect this item's need before asking again.")]))
            }
        }
        guard !filings.isEmpty else { return result }
        // Per-file receipt pointers and need envelopes must use the same filing result.
        if case .object(var saved)? = fields["saved"], case .array(let files)? = saved["files"] {
            saved["files"] = .array(files.map { file in
                guard case .object(var item) = file, case .string(let id)? = item["card_id"],
                      let retainedID = retainedIDs[id] else { return file }
                item["card_id"] = .string(retainedID)
                return .object(item)
            })
            fields["saved"] = .object(saved)
        }
        // The filing receipt prevents outer folded returns from filing twice; filing does not prove the grant was answered.
        fields["needCards"] = .array(filings)
        fields[InlineInteractionWire.needsKey] = .array(retainedEnvelopes)
        return .object(fields)
    }

    private func dispatchNormalized(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
        execution: AppActionExecution) async throws -> JSONValue {
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
        let canonicalInput = ChatToolSessionInjection.apply(toolName: tool, input: input, sessionId: turn.verifiedSessionID)
        let result = try await withAuthoredProgramHost(surface: surface, turn: turn, execution: execution) { callTurn, execution in
            try await self.dispatchWithoutOrganismPosture(tool: tool, input: canonicalInput, surface: surface, turn: callTurn, execution: execution)
        }
        if tool != "app" || input["preview"] != .bool(true) {
            await observeMotorOutcomeIfNeeded(tool: tool, result: result)
        }
        return result
    }

    /// All executed app and underlying tool results leave through dispatch. Read only the owner's remedy, never infer a permission from error prose.
    private func filePermissionRemedy(in result: JSONValue, input: [String: JSONValue], surface: String, turn: Turn,
        execution: AppActionExecution) async -> JSONValue {
        guard input["preview"] != .bool(true), !Task.isCancelled,
              !execution.handsBack, case .object(var fields) = result,
              fields["permission_card"] == nil else { return result }
        let reply = ToolResult(result)
        let detail = fields["detail"]?.objectValue
        let calls = [reply.remedy, detail?["remedy"]].compactMap { remedy -> [String: JSONValue]? in
            guard case .object(let remedy)? = remedy, case .object(let next)? = remedy["next_call"],
                  next["tool"] == .string("app"), case .object(let call)? = next["input"],
                  call["action"] == .string("permissions.request") else { return nil }
            return call
        }
        guard var call = calls.first else { return result }
        guard let session = turn.verifiedSessionID, let perform = execution.perform else {
            fields["permission_card"] = .object(["status": .string("unavailable"),
                "detail": .string("No permission card was filed: this call has no originating conversation and gated app door.")])
            return .object(fields)
        }
        call["__session_id"] = .string(session)
        do {
            // The body's request re-enters all gates without waiting as a part step.
            let request = try await perform("app", call, turn.with(\.partID, nil), execution)
            try Task.checkCancellation()
            if let need = InlineInteractionNeed.interaction(in: request), need.kind == .permission {
                let filed = try await InlineInteractionResolver.filePermissionRequest(need, sessionID: session,
                    origin: TurnEnvelope.current(turn: turn, surface: surface), turn: turn, dataRoot: securityCenter.dataRoot)
                let name = AppleScriptExecution.automationTarget(need.target).map { "Automation for " + $0 }
                    ?? SystemPermissionPreflight.cardSettingsCapability(need.target)?.displayName ?? need.target
                fields["permission_card"] = .object(["status": .string("up"), "id": .string(filed.id),
                    "session_id": .string(filed.sessionID),
                    "detail": .string("A permission card for \(name) is up for \(AgentScreen.names(securityCenter.dataRoot).person).")])
            } else {
                // Already granted or refused by its real owner: keep that evidence.
                fields["permission_card"] = request
            }
        } catch {
            fields["permission_card"] = ChatToolOutcome.failure(error: error, tool: "permissions.request")
        }
        return .object(fields)
    }

    /// Compose the host and watch dependencies for this operation. The factory
    /// installs this value in the same gated chain before any nested call runs.
    public func withAuthoredProgramHost<Value: Sendable>(surface: String, turn: Turn,
        execution: AppActionExecution,
        operation: @Sendable (Turn, AppActionExecution) async throws -> Value) async throws -> Value {
        var scoped = execution
        scoped.openScreenWatch = { request, hands, callTurn in
            guard let dispatcher = self.scopedInner(execution) as? SwiftToolDispatcher else {
                throw SenseFailure(code: "unavailable", message: "The originating tool dispatcher is unavailable.")
            }
            return try await dispatcher.openScreenWatch(turn: callTurn, invocation: execution.invocation, request, hands: hands, surface: surface)
        }
        scoped.waitForInteraction = { need, tool, input, callTurn in
            guard let session = callTurn.verifiedSessionID else {
                return AppToolExecutor.failure("door_unavailable", "A card needs the originating conversation.")
            }
            return await InlineInteractionResolver.waitForAnswer(need, tool: tool, input: input,
                sessionID: session, dataRoot: self.securityCenter.dataRoot, turn: callTurn,
                invocation: execution.invocation, deadlines: execution.deadlines)
        }
        let hostExecution = scoped
        let host = AppToolExecutor.authoredProgramHost(dataRoot: securityCenter.dataRoot, turn: turn, execution: hostExecution,
            reach: { operation, arguments, callTurn in
                guard let dispatcher = self.scopedInner(hostExecution) as? SwiftToolDispatcher else {
                    throw SenseFailure(code: "unavailable", message: "The originating tool dispatcher is unavailable.")
                }
                return try await dispatcher.performReach(turn: callTurn, operation, arguments: arguments, surface: surface)
            }) { id, arguments, program, perform in
                guard let callTurn = program.turn else {
                    return AppToolExecutor.failure("door_unavailable", "An authored action needs its originating turn.")
                }
                let callExecution = hostExecution.serving(program)
                guard let perform, let reentry = callExecution.perform else {
                    return .object(["status": .string("refused"), "effects": .string("none"), "checker": .string("app_door"),
                        "reason": .string("door_unavailable"), "detail": .string("Authored work needs its body and originating turn's gate chain.")])
                }
                // The deferred body belongs to this admission, not the earlier host composition.
                var admittedExecution = callExecution
                admittedExecution.authoredCall = (tool: id, perform: perform)
                let requester = callTurn.partID.map { "\(PersonaCompiler.agentDisplayName(dataRoot: self.securityCenter.dataRoot))'s \($0)" }
                do { return try await reentry(id, arguments, callTurn.with(\.requester, requester), admittedExecution) }
                catch { return ChatToolOutcome.failure(error: error, tool: id) }
            }
        scoped.host = host
        let bound = scoped
        return try await MacAppActGate.withAdmission(origin: Self.securityOrigin(turn: turn, surface: surface),
            dataRoot: securityCenter.dataRoot, turn: turn, context: execution.macOperation(dataRoot: securityCenter.dataRoot)) { admittedTurn, context in
                var bound = bound
                bound.invocation = bound.invocation.serving(mac: context)
                return try await operation(admittedTurn, bound)
            }
    }

    private func observeMotorOutcomeIfNeeded(tool: String, result: JSONValue) async {
        guard let reference = ToolCausalBoundary.motorReference(tool: tool, output: result) else {
            return
        }
        await motorOutcomeObserver(reference)
    }

    private func dispatchWithoutOrganismPosture(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
        execution: AppActionExecution) async throws -> JSONValue {
        if let refusal = await unrecognizedAppActionRefusal(tool: tool, input: input, surface: surface,
            turn: turn, invocation: execution.invocation) { return refusal }
        if execution.admissionOnly {
            return .object(["status": .string("refused"), "effects": .string("none"),
                            "reason": .string("door_unavailable"), "detail": .string("Primitive admission requires the turn's autonomy gate.")])
        }
        let envelope: SecurityToolEnvelope
        if let admission = execution.invocation.securityAdmission {
            envelope = try admission.decision(tool: tool, input: input, surface: surface, turn: turn, sessionID: turn.verifiedSessionID)
        } else {
            // Direct app-dispatch clients enter consent here; composed calls carry the outer membrane's decision.
            envelope = await securityCenter.evaluateTool(tool: tool, input: input,
                origin: Self.securityOrigin(turn: turn, surface: surface), enforceAutonomy: enforceAutonomySecurity, turn: turn)
        }
        if tool != "app" || input["preview"] != .bool(true) { try await securityCenter.record(envelope) }
        guard envelope.decision != .block,
              !enforceAutonomySecurity || !envelope.requiresApproval else {
            return Self.securityGateResponse(envelope)
        }
        try Task.checkCancellation()
        let result = try await scopedInner(execution).dispatch(tool: tool, input: input, surface: surface, turn: turn,
            invocation: execution.toolInvocation)
        // An already-satisfied request returns the owner's answer; a card would leave the turn waiting on nobody.
        if includeAppOwnedTools, tool == InlineInteractionWire.toolName,
           let need = InlineInteractionNeed.interaction(in: result),
           let done = await InlineInteractionResolver.verifiedSetupSummary(need, dataRoot: PersistenceCore.defaultDataRoot()) {
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
            return await platform.grok(plan, PersistenceCore.defaultDataRoot(), scopedInner(execution), surface, turn,
                execution.macOperation(dataRoot: securityCenter.dataRoot))
        }
        if includeAppOwnedTools, tool == "agent_message", case .object(let plan) = result,
           plan["status"] == .string("desktop_chat_send") {
            return await platform.desktopChat(plan, PersistenceCore.defaultDataRoot(), turn,
                execution.macOperation(dataRoot: securityCenter.dataRoot), execution.invocation.conversation)
        }
        if includeAppOwnedTools, let appTools, ["act", "go", "screen"].contains(tool) {
            // Workspace calls must not take the self route, which would read the agent's own pages.
            if execution.workspaceMacCall, case .object(let payload) = result, case .object(let detail)? = payload["detail"],
               detail["status"] == .string("in_process_route") { return WorkspaceMacCall.refusal }
            return await AppToolExecutor.performMacSelfAppRoute(result) { input in
                await appTools.runSelfAppRoute(input: input, surface: surface, turn: turn, execution: execution)
            }
        }
        // Desktop contacts are send-only, so only sends reach the desktop route.
        if includeAppOwnedTools, tool == "agent_message",
           case .object(let plan) = result, plan["transport"] == .string("desktop"),
           plan["status"] == .string("requires_interaction") {
            let sent = await platform.desktop(plan, scopedInner(execution), surface, turn, execution.turnWork,
                execution.macOperation(dataRoot: securityCenter.dataRoot))
            return await GrokDesktopReply.follow(conversation: execution.invocation.conversation, sent,
                dataRoot: PersistenceCore.defaultDataRoot())
        }
        return result
    }

    /// The Tools manifest projects Security Center decisions without dispatching or loading tools; catalog facts remain Core-owned.
    public func toolManifest(detail: String? = nil, surface: String = "chat", turn: Turn) async throws -> JSONValue {
        guard let swift = scopedInner(actionExecution) as? SwiftToolDispatcher else {
            return ChatToolOutcome.refusedBeforeRunning(.object(["status": .string("unavailable"), "tools": .array([])]))
        }
        return await withTrust(catalog: try await swift.toolManifest(turn: turn, detail: detail, surface: surface), surface: surface, turn: turn)
    }

    private func withTrust(catalog: JSONValue, surface: String, turn: Turn) async -> JSONValue {
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
                origin: Self.securityOrigin(turn: turn, surface: surface),
                enforceAutonomy: enforceAutonomySecurity, turn: turn
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

    public func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        try await scopedInner(actionExecution).listAvailableTools(turn: turn, surface: surface).sorted()
    }

    public func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await scopedInner(actionExecution).listAvailableToolSchemas(named: names, turn: turn, surface: surface).sorted { $0.name < $1.name }
    }

    public func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await scopedInner(actionExecution).listAvailableToolSchemas(turn: turn, surface: surface).sorted { $0.name < $1.name }
    }

    public static func securityOrigin(turn: Turn, surface: String) -> SecurityOriginContext {
        var origin = SecurityOriginContext.currentTurn(turn: turn, surface: surface)
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
            "checker": .string("trust"),
            "reasons": .array(envelope.reasons.map { .string($0.persistedValue) }),
            "capabilities": .array(envelope.capabilities.map { .string($0) }),
            "message": .string(envelope.requiresApproval ? "Security Center requires approval before running this tool."
                : "Security Center blocked this tool before execution."),
        ]
        refusal["remedy"] = envelope.remedy
        return ChatToolOutcome.refusedBeforeRunning(.object(refusal))
    }
}
