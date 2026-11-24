import SenseCore
import MacNerves
import MindCore
import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import ProviderRouting
// Blueprint: | `DoorPipeline.swift` | File ceiling, Trust, exact replay and approval settlement for each call |

public struct DoorPolicy: Sendable {
    let fileAccess: String
    let approvalFiler: (any ApprovalFiler)?
    let approvalTimeoutSeconds: Double
    let verifiedSessionId: String?
    let approvedReplay: ApprovedChatToolReplay?
    let traceOnlyAbilities: Bool
    let work: ChatTurnWork
    enum SurfaceProfile: Sendable {
        case ordinary
        case contact(AgentConversationContext)
    }
    let surfaceProfile: SurfaceProfile
    let includeAppOwnedTools: Bool

    func scoping(_ invocation: ChatToolInvocation) -> ChatToolInvocation {
        switch surfaceProfile {
        case .ordinary: invocation
        case .contact(let conversation): invocation.serving(conversation: conversation)
        }
    }
}

public struct DoorPipeline: ToolDispatchClient {
    let policy: DoorPolicy
    let endpoint: any ToolDispatchClient
    let jobStore: AgentJobStore
    let securityCenter: SwiftNativeSecurityCenter
    let gate: AutonomyGate
    let injectionApprovalVerifier: ApprovalInboxInjectionApprovalVerifier
    let approvedReplayVerifier: ApprovalInboxApprovedReplayVerifier
    public var includeAppOwnedTools: Bool { policy.includeAppOwnedTools }
    var dataRoot: URL { securityCenter.dataRoot }

    public func preApprovalRefusal(turn: Turn, invocation: ChatToolInvocation, tool: String, input: [String: JSONValue], surface: String) async -> JSONValue? {
        let turn = turn.with(\.fileAccess, policy.fileAccess)
        do {
            if let refusal = try PermissionLaw.requestFileAccessRefusal(tool: tool, input: input, turn: turn) {
                return ChatToolOutcome.failure(error: refusal, tool: tool)
            }
        } catch { return ChatToolOutcome.failure(error: error, tool: tool) }
        let scoped = policy.scoping(invocation)
        return await endpoint.preApprovalRefusal(turn: turn, invocation: scoped, tool: tool, input: input, surface: surface)
    }

    public func approvalCardReason(tool: String, input: [String: JSONValue], surface: String) async -> String? {
        await endpoint.approvalCardReason(tool: tool, input: input, surface: surface)
    }

    /// Scalar presentation of the saved posture. The turn intersects this with the original request; the label alone is never its authority.
    static func sharedFileAccess(_ requested: String) -> String {
        let saved = UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto"
        guard let savedMode = ICloudChatFileAccessPolicy.Mode(saved) else { return "invalid saved chatFileAccess: \(saved)" }
        guard let requestedMode = ICloudChatFileAccessPolicy.Mode(requested) else { return "invalid request fileAccess: \(requested)" }
        if savedMode == .none || requestedMode == .none { return "none" }
        if requestedMode == .readOnly { return "read_only" }
        return savedMode == .readOnly ? "auto" : saved
    }

    public func dispatch(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        var invocation = invocation
        invocation[AdmittingDoor.self] = nil
        invocation[BoundDoorAction.self] = nil
        invocation[ActionDescriptor.Bound.self] = nil
        var turn = turn.with(\.fileAccess, policy.fileAccess)
        var input = input
        if tool == "app" {
            if turn.doorPreview != nil { input["preview"] = .bool(true) }
            else if input["preview"] == .bool(true) { turn.doorPreview = .request }
        }
        turn[PermissionLaw.BoundPersonCall.self] = nil
        do {
            if let error = try PermissionLaw.requestFileAccessRefusal(tool: tool, input: input, turn: turn) { throw error }
            return try await canonicalize(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        } catch {
            guard ChatToolDispatchTracer.abilityName(tool: tool, input: input) != nil else { throw error }
            var refusal = ChatToolOutcome.failure(error: error, tool: tool).objectValue ?? [:]
            refusal["checker"] = .string("request_file_access")
            return await ChatToolDispatchTracer.traceUndispatched(turn: turn, tool: tool, input: input, surface: surface,
                result: .object(refusal), dataRoot: dataRoot)
        }
    }

    /// Failed consent records remain owed under the life record; they do not alter the decision.
    func audit(_ envelope: SecurityToolEnvelope, turn: Turn) async {
        guard turn.doorPreview == nil else { return }
        do { try await securityCenter.record(envelope) } catch {
            let file = securityCenter.dataRoot.appendingPathComponent("experiences/experiences.sqlite").path
            RepairOwed.owe(securityCenter.dataRoot, id: "security-audit:" + UUID().uuidString, kind: .run,
                operation: "security.audit", owner: file,
                words: "The consent detail for \(envelope.tool) (\(envelope.decision.rawValue)) was not written: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("files.info"), "args": .object(["path": .string(file)])]))
        }
    }

    func admitEffect(tool: String, input: [String: JSONValue], surface: String, turn: Turn, invocation: ChatToolInvocation) async throws -> JSONValue {
        try Task.checkCancellation()
        if StandingBotContinuity.isHelperTurn(turn: turn), let pending = turn.execution?.pendingApproval { return pending }
        var result = try await dispatchHeld(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
        // What the agent's own create made, by the id its receipt declares, is kept so a later removal of it, in this turn or any other, is
        // known as undoing its own act; a removal that ran takes it away. Recorded once, by the declared create or removal itself: a folded
        // `app` call re-enters here under its tool's own name, and its outer `app` call (no declaration of its own) records nothing.
        if turn.doorPreview == nil, ToolResult(result).outcome == .succeeded, let schema = AppActionBinding.declaredSchema(tool) {
            do {
                if let key = schema.makes, let id = ChatTranscriptEvidenceRendering.receiptField(key, in: result)?.stringValue {
                    try AgentMade.note(id, madeBy: tool, root: securityCenter.dataRoot)
                }
                if let key = schema.removes, let id = input[key]?.stringValue { try AgentMade.forget(id, root: securityCenter.dataRoot) }
            } catch {
                if case .object(var fields) = result {
                    fields["made_record_unavailable"] = .string("trust/made.json was not updated (\(error.localizedDescription)), so removing "
                        + "what this made asks the person as removing the person's things does.")
                    result = .object(fields)
                }
            }
        }
        return result
    }

    func dispatchNormalized(tool: String, input: [String: JSONValue], surface: String, turn: Turn, work: ChatTurnWork) async throws -> JSONValue {
        // The person's act admits its own call once per form in one run; every other call here is judged as the agent's.
        let turn = PermissionLaw.admitting(tool: tool, input: input, turn: turn)
        if let refusal = await endpoint.unrecognizedAppActionRefusal(tool: tool, input: input, surface: surface,
            turn: turn, invocation: work.invocation) { return refusal }
        // SecurityCenter persists evaluated arguments: pass injection count/digest
        // redaction across that boundary, keeping execution characters in memory.
        let namedConnect = AgentHostConnection.isNamedConnect(tool: tool, input: input)
        let input: [String: JSONValue] = {
            var bound = input
            // Preserve the exact disclosed path on replay, even when it was absent.
            if namedConnect, policy.approvedReplay?.matches(turn: turn, tool: tool, surface: surface, input: input,
                verifiedSessionID: policy.verifiedSessionId) != true {
                bound.removeValue(forKey: "executable_path")
                if case .string(let name)? = input["name"], let row = AgentHostDirectory.row(named: name),
                   let line = row.commandLine, let path = row.resolveExecutable(line.executable) {
                    bound["executable_path"] = .string(path)
                }
            }
            return bound
        }()
        var work = work
        if let descriptor = ActionCatalog.current.tools[tool] {
            let verifiedTurn = turn.with(\.verifiedSessionID, policy.verifiedSessionId ?? turn.verifiedSessionID)
            let arguments = ChatToolSessionInjection.apply(turn: verifiedTurn, toolName: tool, input: input)
            work.toolInvocation[ActionDescriptor.Bound.self] = descriptor.bound(arguments, invocation: work.invocation)
        }
        let securityInput = MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn)
        let envelope = await securityCenter.evaluateTool(
            tool: tool,
            input: securityInput,
            origin: .currentTurn(
                turn: turn.with(\.verifiedSessionID, policy.verifiedSessionId ?? turn.verifiedSessionID),
                surface: surface
            ),
            enforceAutonomy: false, turn: turn
        )
        // .block is the person's Trust (Safe's blocked level, Pause everything) or their security policy: a good call it stops is refused
        // before it ran, as the person's call. .ask enters the approval flow and denies if no filer exists.
        if envelope.decision == .block {
            await audit(envelope, turn: turn)
            if let refusal = await argumentRefusal(denied: true, tool: tool, input: input, surface: surface, turn: turn, work: work) { return refusal }
            return ChatToolOutcome.refusedBeforeRunning(code: "owners_call", detail: envelope.primaryReason,
                extra: (envelope.remedy.map { ["remedy": $0] } ?? [:]).merging(["decided_by": .string("trust")]) { $1 })
        }

        // Use SecurityCenter's decision for this exact call, including roots, profile, class, reach and saved user entries.
        let approvedReplayAuthorizes: Bool, injectionReplayApprovalID: String?
        let replayInput = work.invocation[BoundDoorAction.self]?.submitted ?? input
        switch try await verifyReplay(tool: tool, input: replayInput, surface: surface, turn: turn, envelope: envelope) {
        case .refused(let refusal): return refusal
        case .checked(let authorizes, let approvalID):
            approvedReplayAuthorizes = authorizes
            injectionReplayApprovalID = approvalID
        }
        var judged = try decideCall(tool: tool, input: input, surface: surface, turn: turn, work: work, namedConnect: namedConnect,
            envelope: envelope, approvedReplayAuthorizes: approvedReplayAuthorizes, injectionReplayApprovalID: injectionReplayApprovalID)
        if let refusal = try await settleWhoDecides(&judged) { return refusal }
        try Task.checkCancellation()
        // An owner that needs the person's yes for this exact call says so in its reply (`needs_person`, with its words): the call then asks
        // as a gate's ask does, and the person's Approve replays it as their own act. The person's own act, or its replay, never asks again.
        while true {
        switch judged.decision {
        case .allow:
            if let result = try await runAllowed(&judged) { return result }
        case .deny(let reason):
            // A good call the person's Trust denies is refused before it ran, in the gate's words: the person's call, not a failure. Its
            // deny was audited above, with the argument check.
            return ChatToolOutcome.refusedBeforeRunning(code: "owners_call", detail: reason,
                extra: (envelope.remedy.map { ["remedy": $0] } ?? [:]).merging(["decided_by": .string("trust")]) { $1 })
        case .requireApproval(let gateReason):
            if let result = try await requestApproval(&judged, gateReason: gateReason) { return result }
        }
        }
    }

    public func listAvailableTools(turn: Turn?, surface: String) async throws -> [String] {
        try await endpoint.listAvailableTools(turn: turn, surface: surface)
    }

    // Forward the actual inner schemas so wrapping gates cannot change the offered catalog.
    public func listAvailableToolSchemas(named names: Set<String>, turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await endpoint.listAvailableToolSchemas(named: names, turn: turn, surface: surface)
    }

    public func listAvailableToolSchemas(turn: Turn?, surface: String) async throws -> [LLMToolSchema] {
        try await endpoint.listAvailableToolSchemas(turn: turn, surface: surface)
    }

    static func securityEnvelope(
        _ envelope: SecurityToolEnvelope,
        decision: SecurityToolDecision,
        reason: String
    ) -> SecurityToolEnvelope {
        var copy = envelope
        copy.decision = decision
        copy.allowed = decision == .allow
        copy.requiresApproval = decision == .ask
        copy.reasons.append(.init(decision == .allow ? .note : .cause, reason))
        return copy
    }
}
