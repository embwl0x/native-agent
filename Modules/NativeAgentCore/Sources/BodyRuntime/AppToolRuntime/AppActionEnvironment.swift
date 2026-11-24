import SenseCore
import Foundation
import MindCore
import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
// Blueprint: | `AppActionEnvironment.swift` | App effects and program-host binding for an admitted call |

enum AdmittingDoor: ToolInvocationPart { static let unset: DoorPipeline? = nil }

struct AppActionEnvironment: Sendable {
    let interactions: InlineInteractionCoordinator
    let securityCenter: SwiftNativeSecurityCenter
    let enforceAutonomySecurity: Bool
    let includeAppOwnedTools: Bool
    let motorOutcomeObserver: @Sendable (ToolCausalBoundary.MotorReference) async -> Void
    let platform: ChatToolPlatformPort

    func executeAdmitted(_ admission: consuming SecurityToolAdmission, client: SwiftToolDispatcher, invocation: ChatToolInvocation) async throws -> JSONValue {
        let (tool, input, surface, turn) = (admission.tool, admission.input, admission.surface, admission.turn)
        guard let pipeline = invocation[AdmittingDoor.self] else {
            throw ToolFailureError("This call needs its originating door’s admission.", effects: .none)
        }
        var scoped = invocation.callExecution
        if scoped.perform == nil {
            scoped.perform = { tool, input, turn, execution in
                try await AppDoorReentry.call(tool, input: input, surface: surface, turn: turn, invocation: execution.toolInvocation, tools: pipeline)
            }
        }
        let execution = scoped
        let result: JSONValue
        do {
            result = ChatToolOutcome.normalizedFailure(try await client.withToolArguments(turn: turn, invocation: invocation, tool: tool,
                input: input, surface: surface) { input, invocation in
                let envelope = try admission.decision(for: input)
                var execution = execution
                execution.invocation = invocation
                return try await dispatchNormalized(client: client, tool: tool, input: input, surface: surface, turn: turn,
                    envelope: envelope, execution: execution)
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
        guard turn.doorPreview == nil, input["preview"] != .bool(true), !Task.isCancelled, !execution.handsBack,
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
            if let filed = await self.interactions.raise(need, sessionID: session,
                requestingTool: tool,
                origin: TurnEnvelope.current(turn: turn, surface: surface), turn: turn) {
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

    private func dispatchNormalized(client: SwiftToolDispatcher, tool: String, input: [String: JSONValue], surface: String, turn: Turn, envelope: SecurityToolEnvelope,
        execution: AppActionExecution) async throws -> JSONValue {
        let result = try await withAuthoredProgramHost(client: client, surface: surface, turn: turn, execution: execution) { callTurn, execution in
            try await self.dispatchWithoutOrganismPosture(client: client, tool: tool, input: input, surface: surface, turn: callTurn, envelope: envelope, execution: execution)
        }
        if turn.doorPreview == nil {
            await observeMotorOutcomeIfNeeded(tool: tool, result: result)
        }
        return result
    }

    /// All executed app and underlying tool results leave through dispatch. Read only the owner's remedy, never infer a permission from error prose.
    private func filePermissionRemedy(in result: JSONValue, input: [String: JSONValue], surface: String, turn: Turn,
        execution: AppActionExecution) async -> JSONValue {
        guard turn.doorPreview == nil, input["preview"] != .bool(true), !Task.isCancelled,
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
                let filed = try await self.interactions.filePermissionRequest(need, sessionID: session,
                    origin: TurnEnvelope.current(turn: turn, surface: surface), turn: turn)
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
    func withAuthoredProgramHost<Value: Sendable>(client: SwiftToolDispatcher, surface: String, turn: Turn,
        execution: AppActionExecution,
        operation: @Sendable (Turn, AppActionExecution) async throws -> Value) async throws -> Value {
        try await MacAppActGate.withAdmission(origin: Self.securityOrigin(turn: turn, surface: surface),
            dataRoot: securityCenter.dataRoot, turn: turn, context: execution.macOperation(dataRoot: securityCenter.dataRoot)) { turn, context in
            var execution = execution
            execution.invocation = execution.invocation.serving(mac: context)
            let scoped = bindProgramHost(client: client, surface: surface, turn: turn, execution: execution)
            return try await operation(turn, scoped)
        }
    }

    private func bindProgramHost(client: SwiftToolDispatcher, surface: String, turn: Turn, execution: AppActionExecution) -> AppActionExecution {
        var scoped = execution
        scoped.invocation.bodyField = client.bodyField
        scoped.openScreenWatch = { request, hands, callTurn in
            return try await client.openScreenWatch(turn: callTurn, invocation: execution.invocation, request, hands: hands, surface: surface)
        }
        scoped.waitForInteraction = { need, tool, input, callTurn in
            guard let session = callTurn.verifiedSessionID else {
                return AppToolExecutor.failure("door_unavailable", "A card needs the originating conversation.")
            }
            return await self.interactions.waitForAnswer(need, tool: tool, input: input,
                sessionID: session, turn: callTurn,
                invocation: execution.invocation, deadlines: execution.deadlines)
        }
        let hostExecution = scoped
        let host = AppToolExecutor.authoredProgramHost(dataRoot: securityCenter.dataRoot, jobStore: client.jobStore, turn: turn, execution: hostExecution,
            reach: { operation, arguments, callTurn in
                try await client.performReach(turn: callTurn, operation, arguments: arguments, surface: surface)
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
        return scoped
    }

    private func observeMotorOutcomeIfNeeded(tool: String, result: JSONValue) async {
        guard let reference = ToolCausalBoundary.motorReference(tool: tool, output: result) else {
            return
        }
        await motorOutcomeObserver(reference)
    }

    private func dispatchWithoutOrganismPosture(client: SwiftToolDispatcher, tool: String, input: [String: JSONValue], surface: String, turn: Turn, envelope: SecurityToolEnvelope,
        execution: AppActionExecution) async throws -> JSONValue {
        if let refusal = await client.unrecognizedAppActionRefusal(tool: tool, input: input, surface: surface,
            turn: turn, invocation: execution.invocation) { return refusal }
        if execution.admissionOnly {
            return .object(["status": .string("refused"), "effects": .string("none"),
                            "reason": .string("door_unavailable"), "detail": .string("Primitive admission requires the turn's autonomy gate.")])
        }
        guard envelope.decision != .block,
              !enforceAutonomySecurity || !envelope.requiresApproval else {
            return Self.securityGateResponse(envelope)
        }
        try Task.checkCancellation()
        let result = ChatToolOutcome.normalizedFailure(try await client.dispatchAdmitted(turn: turn,
            invocation: execution.toolInvocation, tool: tool, input: input, surface: surface), tool: tool,
            throughAppDoor: execution.invocation.appDoor != nil)
        // An already-satisfied request returns the owner's answer; a card would leave the turn waiting on nobody.
        if includeAppOwnedTools, tool == InlineInteractionWire.toolName,
           let need = InlineInteractionNeed.interaction(in: result),
           let done = await self.interactions.verifiedSetupSummary(need) {
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
            return await platform.grok(plan, PersistenceCore.defaultDataRoot(), surface, turn, execution.partInvocation(turn: turn, surface: surface))
        }
        if includeAppOwnedTools, ["agent_message", "agent_read"].contains(tool), case .object(let plan) = result,
           [JSONValue.string("desktop_chat_send"), .string("desktop_chat_read")].contains(plan["status"] ?? .null) {
            return await platform.desktopChat(plan, PersistenceCore.defaultDataRoot(), turn,
                execution.macOperation(dataRoot: securityCenter.dataRoot), execution.invocation.conversation)
        }
        if includeAppOwnedTools, let appTools = client.appTools, ["act", "go", "screen"].contains(tool) {
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
            return await platform.desktop(plan, client, surface, turn, execution.turnWork.with(\.toolInvocation, execution.toolInvocation),
                execution.macOperation(dataRoot: securityCenter.dataRoot), execution.invocation.conversation,
                execution.partInvocation(turn: turn, surface: surface))
        }
        return result
    }

    func withTrust(catalog: JSONValue, surface: String, turn: Turn) async -> JSONValue {
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

    static func securityOrigin(turn: Turn, surface: String) -> SecurityOriginContext {
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
            "capabilities": .array(envelope.capabilities.wireNames.map { .string($0) }),
            "message": .string(envelope.requiresApproval ? "Security Center requires approval before running this action."
                : "Security Center blocked this action before it ran."),
        ]
        refusal["remedy"] = envelope.remedy
        return ChatToolOutcome.refusedBeforeRunning(.object(refusal))
    }
}

extension SwiftToolDispatcher {
    public func withAuthoredProgramHost<Value: Sendable>(surface: String, turn: Turn, execution: AppActionExecution,
        operation: @Sendable (Turn, AppActionExecution) async throws -> Value) async throws -> Value {
        guard let appEnvironment else { throw ToolFailureError("The originating app door is unavailable.", effects: .none) }
        return try await appEnvironment.withAuthoredProgramHost(client: self, surface: surface, turn: turn, execution: execution, operation: operation)
    }

    public func toolManifest(detail: String?, surface: String = "chat", turn: Turn) async throws -> JSONValue {
        let catalog = try await toolManifest(turn: turn, detail: detail, surface: surface)
        guard let appEnvironment else { return catalog }
        return await appEnvironment.withTrust(catalog: catalog, surface: surface, turn: turn)
    }
}
