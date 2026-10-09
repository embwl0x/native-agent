import AppToolRuntime
import ApprovalInbox
import ChatOrchestration
import Foundation
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import Skills
import ToolExecution
import ToolRegistry

/// A command receipt; mounted skill/tool lists are projections of its saved state.
public struct CapabilityCommandOutcome: Sendable {
    public let ok: Bool
    public let detail: String
    public let fields: [String: JSONValue]
    public let refreshSkills: Bool
    public let refreshTools: Bool
    public let toolStatus: CapabilityToolStatus?
}

public struct CapabilityToolStatus: Sendable {
    public let message: String
    public let succeeded: Bool
    public var cause: String? = nil
}

/// Lifecycle authority and decision receipts, independent of the Mac UI model.
public struct CapabilityLifecycleCommands: Sendable {
    private struct VerbOutcome {
        let ok: Bool
        let detail: String
        let fields: [String: JSONValue]
        let toolStatus: CapabilityToolStatus?
        init(_ ok: Bool, _ detail: String, _ fields: [String: JSONValue], toolStatus: CapabilityToolStatus? = nil) {
            self.ok = ok
            self.detail = detail
            self.fields = fields
            self.toolStatus = toolStatus
        }
    }
    private let dataRoot: URL
    private let personaRoot: URL
    private let tools: ToolsFacade
    private let formatFailure: @Sendable (Error, String) -> String
    private static let retry = " Read \(AppToolExecutor.doorDoctor) to see what is wrong, then try again."

    public init(dataRootOverride: URL?, tools: ToolsFacade,
                formatFailure: @escaping @Sendable (Error, String) -> String) {
        dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        personaRoot = dataRootOverride.map { $0.appendingPathComponent("persona") } ?? PersonaRootResolver.resolve()
        self.tools = tools
        self.formatFailure = formatFailure
    }

    public func manageSkill(verb: String, input: [String: JSONValue], steer: [String]) async -> CapabilityCommandOutcome {
        let result = await runSkill(verb: verb, input: input, steer: steer)
        let preview = input["preview"] == .bool(true)
        return CapabilityCommandOutcome(ok: result.ok, detail: result.detail, fields: result.fields,
            refreshSkills: !preview && !verb.hasPrefix("tool_"), refreshTools: !preview && verb.hasPrefix("tool_"), toolStatus: result.toolStatus)
    }

    /// Agent's rulings, 2026-10-01: installing her drafts is hers, and User
    /// sees each one as a decided row; she turns back on only what she turned
    /// off; delete is a trash she can restore from; built-in skills are User's.
    private func runSkill(verb: String, input: [String: JSONValue], steer: [String]) async -> VerbOutcome {
        if verb.hasPrefix("tool_") { return await manageAuthoredTool(verb: verb, input: input) }
        let name = AppToolExecutor.inputString(input["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = dataRoot
        let fullMac = await AppToolExecutor.freshQuietPosture(dataRoot: root)?.name == AppToolExecutor.fullMacModeName
        // The door's preview (enable, restore, rollback): the same checks, nothing written, no card.
        let preview = input["preview"] == .bool(true)
        // Only the transport's verified caller can carry User's authority;
        // labels from consumed peer data do not grant it.
        let envelope = ChatToolSessionContext.envelope
        let ownerAuthorized = envelope?.agent == "peer"
            && (envelope?.verifiedUserId.map { PeerDataTaint.ownerTrusts("peer:" + $0) } ?? false)
            && PeerDataTaint.current?.isTainted != true
            && (PeerDataTaint.current?.elevatedSources.isEmpty ?? true)
        let result = await SwiftNativeSkillsClient(root: root).manageSkill(
            verb: verb, name: name, personaRoot: personaRoot, retry: Self.retry, fullMac: fullMac, steer: steer,
            preview: preview, ownerAuthorized: ownerAuthorized
        ) {
            try await NativeSkillRegistryActions.reconcileSkillEvolutionRecall(
                memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: root), dataRoot: root, personaRoot: personaRoot)
        }
        var fields = result.fields
        let script = fields.removeValue(forKey: "script")
        if preview { return VerbOutcome(result.ok, result.text, fields) }
        if fields["needs_user"] == .bool(true) {
            // User's card, answerable on the Mac and his phone (`askUserToInstallScript`).
            let skill = AppToolExecutor.inputString(fields["name"]) ?? name
            let source = if case .object(let body)? = script { AppToolExecutor.inputString(body["source"]) ?? "" } else { "" }
            let card: ApprovalRecord
            do {
                card = try await SwiftNativeApprovalInbox(root: root).askUserToInstallScript(
                    skill: skill, skillID: AppToolExecutor.inputString(fields["skill_id"]) ?? skill,
                    digest: AppToolExecutor.inputString(fields["script_digest"]) ?? "", why: result.text,
                    script: SkillScript.signature(script ?? .null) + "\n\n" + source)
            } catch {
                return VerbOutcome(false, result.text + " The card asking him did not file (\(String(describing: error))): tell him.", fields)
            }
            return VerbOutcome(false, result.text + " A card asks him, on the Mac and his phone.",
                    fields.merging(["approval_id": .string(card.id)]) { $1 })
        }
        // Restoring an archived skill turns it on, as enable does.
        guard verb == "enable" || fields["state_before"] == .string(CapabilityLifecycle.archived), result.ok,
              fields["changed"] != .bool(false) else {
            return VerbOutcome(result.ok, result.text, fields)
        }
        let skill = AppToolExecutor.inputString(fields["name"]) ?? name
        if PeerDataTaint.trustedTurn { return VerbOutcome(result.ok, result.text, fields) }
        let decided = await HarnessDecidedRow.record(
            requester: fields["state_before"] == .string("drafted") ? "install skill" : "re-enable skill",
            tool: skill, sessionID: AppToolExecutor.inputString(input["__session_id"]), dataRoot: root, ran: true)
        guard let decided else {
            return VerbOutcome(true, result.text + " Your decision did not reach User's Inbox: the Inbox did not write.", fields)
        }
        return VerbOutcome(true, result.text + " User sees it in his Inbox"
            + (decided.decisions > 1 ? ", decision \(decided.decisions) on that row." : "."),
            fields.merging(["decided_row": .string(decided.id), "decisions_on_row": .int(Int64(decided.decisions))]) { $1 })
    }

    /// The Tools page's lifecycle actions on a tool she wrote.
    private func manageAuthoredTool(verb: String, input: [String: JSONValue]) async -> VerbOutcome {
        // The door's preview of restore and rollback: the same checks, nothing written.
        let preview = input["preview"] == .bool(true)
        if preview, !["tool_restore", "tool_rollback", "tool_approve"].contains(verb) {
            return VerbOutcome(false, "Only tool restore, rollback and approve preview here; nothing was done.", [:])
        }
        if verb == "tool_propose" { return await proposeAuthoredTool(input) }
        let raw = AppToolExecutor.inputString(input["tool_id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tools: [ToolRecord]
        do { tools = try await self.tools.listAuthored() } catch {
            return VerbOutcome(false, "The tool registry didn't read (\(error.localizedDescription))." + Self.retry, [:])
        }
        guard !raw.isEmpty, let tool = tools.first(where: { [$0.id, $0.name].map { $0.lowercased() }.contains(raw.lowercased()) }) else {
            return VerbOutcome(false, "No tool you wrote has id or name \(raw.isEmpty ? "(none passed)" : raw). Pass tool_id as one of these.",
                    ["tools": .array(tools.map { .object(["id": .string($0.id), "name": .string($0.name), "status": .string($0.status)]) })])
        }
        let fields: [String: JSONValue] = ["tool_id": .string(tool.id), "name": .string(tool.name)]
        if verb == "tool_approve" {
            // The Tools page's Approve. User's below Full Mac; the door refuses it there.
            guard tool.status != "active" else {
                return VerbOutcome(true, "\(tool.name) is already active.", fields.merging(["changed": .bool(false)]) { $1 })
            }
            if let refusal = ToolApprovalEligibility.refusal(for: tool) {
                return VerbOutcome(false, "Tool activation unavailable: \(refusal)" + Self.retry, fields,
                    toolStatus: .init(message: "Tool activation unavailable: \(refusal)", succeeded: false))
            }
            if preview {
                return VerbOutcome(true, "Would activate \(tool.name); execution and promotion validation have not run.",
                    fields.merging(["would_status": .string("active")]) { $1 })
            }
            do {
                let proposal = try await SwiftNativeToolExecution(root: dataRoot).promote(id: tool.id, allowRisky: true).toJSON()
                if let field = ToolRecord.stringFieldProblem(in: proposal) {
                    throw ToolRegistryError.registryUnreadable(reason: "promoted tool \(tool.id) has no valid \(field)")
                }
                guard let updated = ToolRecord(json: proposal) else {
                    throw ToolRegistryError.registryUnreadable(reason: "promoted tool \(tool.id) has no registry record")
                }
                try ToolsFacade.checkAuthored(updated)
                guard try await self.tools.listAuthored().first(where: { $0.id == updated.id })?.status == "active" else {
                    return VerbOutcome(false, "Tool activation could not be confirmed after reloading the registry." + Self.retry, fields,
                        toolStatus: .init(message: "Tool activation could not be confirmed after reloading the registry.", succeeded: false))
                }
            } catch {
                let message = formatFailure(error, "turn that tool on")
                return VerbOutcome(false, Self.forAgent(message, error) + Self.retry, fields,
                    toolStatus: .init(message: message, succeeded: false, cause: error.localizedDescription))
            }
            decided("tool.approve \(tool.name)", input)
            return VerbOutcome(true, "\(tool.name) is active: you can use it now.", fields,
                toolStatus: .init(message: "Tool activated", succeeded: true))
        }
        if verb == "tool_quarantine" {
            guard tool.status != "quarantined" else {
                return VerbOutcome(true, "\(tool.name) is already quarantined.", fields.merging(["changed": .bool(false)]) { $1 })
            }
            do {
                let updated = try await SwiftNativeToolRegistry(root: dataRoot).quarantine(id: tool.id,
                    reason: AppToolExecutor.inputString(input["reason"]).map { "Quarantined by the agent: " + $0 }
                        ?? "Quarantined by the agent.")
                try ToolsFacade.checkAuthored(updated)
                guard try await self.tools.listAuthored().first(where: { $0.id == updated.id })?.status == "quarantined" else {
                    return VerbOutcome(false, "Tool quarantine could not be confirmed after reloading the registry." + Self.retry, fields,
                        toolStatus: .init(message: "Tool quarantine could not be confirmed after reloading the registry.", succeeded: false))
                }
            } catch {
                let message = formatFailure(error, "quarantine that tool")
                return VerbOutcome(false, Self.forAgent(message, error) + Self.retry, fields,
                    toolStatus: .init(message: message, succeeded: false, cause: error.localizedDescription))
            }
            return VerbOutcome(true, "\(tool.name) is quarantined; you won't use it. Approving it again is User's.", fields,
                toolStatus: .init(message: "Tool quarantined", succeeded: true))
        }
        let root = dataRoot
        if verb == "tool_restore" {
            // His below Full Mac, as Approve is; the door refuses it there.
            do {
                guard try await ToolRegistryActions.restore(id: tool.id, dataRoot: root, preview: preview) else {
                    return VerbOutcome(false, "\(tool.name) is not archived (\(tool.status)); nothing changed.", fields)
                }
            } catch { return VerbOutcome(false, "Restore failed: \(error.localizedDescription)." + Self.retry, fields) }
            if preview {
                return VerbOutcome(true, "Would turn \(tool.name) back on, active at once and yours under Full Mac, no approval after it; "
                    + "its 30-day unused clock restarts.",
                    fields.merging(["would_status": .string("active"), "would_admit": .string("hers"),
                                    "would_clock": .string("restarts now"),
                                    "versions": await SwiftNativeToolExecution(root: root).versions(id: tool.id)]) { $1 })
            }
            decided("tool.restore \(tool.name)", input)
            return VerbOutcome(true, "\(tool.name) is active again: you can use it now.", fields)
        }
        if verb == "tool_rollback" {
            let execution = SwiftNativeToolExecution(root: root)
            if preview {
                let target: String
                do { target = String(try await execution.rollbackPreview(id: tool.id).prefix(12)) } catch {
                    return VerbOutcome(false, "\(tool.name) would not roll back: \(error.localizedDescription). Nothing was done.", fields)
                }
                let fullMac = await AppToolExecutor.freshQuietPosture(dataRoot: root)?.name == AppToolExecutor.fullMacModeName
                return VerbOutcome(true, "Would put \(tool.name) back to version \(target), proposed: tool.approve turns it on, "
                    + (fullMac ? "yours under Full Mac" : "User's on the Tools page")
                    + ", once it passes validation; its 30-day unused clock restarts then.",
                    fields.merging(["would_status": .string("proposed"), "would_admit": .string(fullMac ? "hers" : "users"),
                                    "would_clock": .string("restarts when it is turned on"), "would_land_on": .string(target),
                                    "versions": await execution.versions(id: tool.id)]) { $1 })
            }
            let result: ProposalValidationResult
            do {
                result = try await execution.rollback(id: tool.id)
            } catch { return VerbOutcome(false, "\(tool.name) was not rolled back: \(error.localizedDescription).", fields) }
            return VerbOutcome(result.valid, "\(tool.name) is back to the version before, proposed: tool.approve activates it"
                + (result.valid ? "." : ", once it passes validation: \(result.errors.joined(separator: "; ")).")
                + " The version it replaced is kept.", fields)
        }
        return VerbOutcome(false, "Authored-tool auto-run is unavailable; this setting does not control execution. Quarantine the tool to stop it.", fields)
    }

    /// Her authoring surface: the tool filed as a proposal on the Tools page,
    /// validated, waiting for Approve; once active it is `authored.<tool_id>`.
    private func proposeAuthoredTool(_ input: [String: JSONValue]) async -> VerbOutcome {
        let id = AppToolExecutor.inputString(input["tool_id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fields: [String: JSONValue] = ["tool_id": .string(id)]
        guard SwiftToolDispatcher.isAuthorableToolName(id) else {
            return VerbOutcome(false, "\(id) is a built-in tool's name. Pick another tool_id; nothing was filed.", fields)
        }
        let list = { (key: String) -> [JSONValue] in if case .array(let items)? = input[key] { items } else { [] } }
        let result: ProposalValidationResult
        do {
            result = try await SwiftNativeToolExecution(root: dataRoot).propose(
                id: id, description: AppToolExecutor.inputString(input["description"]) ?? "",
                code: AppToolExecutor.inputString(input["code"]) ?? "", tests: list("tests"),
                permissions: list("permissions").compactMap(AppToolExecutor.inputString),
                inputSchema: input["input_schema"].flatMap { if case .object = $0 { $0 } else { nil } })
        } catch {
            return VerbOutcome(false, "\(id) was not filed: \(error.localizedDescription).", fields)
        }
        let filed = fields.merging(["validation_errors": .array(result.errors.map(JSONValue.string))]) { $1 }
        guard result.valid else {
            return VerbOutcome(false, "\(id) is filed on the Tools page but failed validation: \(result.errors.joined(separator: "; ")). "
                + "Fix it and tool.propose again.", filed)
        }
        return VerbOutcome(true, "\(id) is filed on the Tools page and passed validation. tool.approve activates it (User's "
            + "below Full Mac); then it runs as authored.\(id).", filed)
    }


    private static func forAgent(_ line: String, _ error: Error) -> String {
        let cause = error.localizedDescription
        return cause.isEmpty || line.contains(cause) ? line : "\(line) (cause: \(cause))"
    }

    private func decided(_ tool: String, _ input: [String: JSONValue]) {
        HarnessDecidedRow.post(requester: "Full Mac", tool: tool, sessionID: AppToolExecutor.inputString(input["__session_id"]),
                               dataRoot: dataRoot)
    }
}
