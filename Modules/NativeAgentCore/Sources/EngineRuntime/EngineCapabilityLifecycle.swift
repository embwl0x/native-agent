import AuthoredCapabilities
import AppToolRuntime
import ApprovalInbox
import ChatOrchestration
import Foundation
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import Senses
import Skills
import ToolExecution
import ToolRegistry
import TrustCenter

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
    /// off; deleting is final; built-in skills are User's.
    private func runSkill(verb: String, input: [String: JSONValue], steer: [String]) async -> VerbOutcome {
        if input["preview"] == .bool(true), ["tool_approve", "tool_restore"].contains(verb) {
            let fullMac = await AppToolExecutor.freshQuietPosture(dataRoot: dataRoot)?.name == AppToolExecutor.fullMacModeName
            do { try CapabilityLifecycle.requireKeep(ownerAuthorized: fullMac || PeerDataTaint.ownerAuthorized) }
            catch { return VerbOutcome(false, error.localizedDescription, ["reason": .string("owners_call")]) }
        }
        if verb.hasPrefix("tool_") { return await manageAuthoredTool(verb: verb, input: input, steer: steer) }
        let fullMac = await AppToolExecutor.freshQuietPosture(dataRoot: dataRoot)?.name == AppToolExecutor.fullMacModeName
        let name = AppToolExecutor.inputString(input["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = dataRoot
        // The door's preview (enable, restore, rollback): the same checks, nothing written, no card.
        let preview = input["preview"] == .bool(true)
        // Only the transport's verified caller can carry User's authority;
        // labels from consumed peer data do not grant it.
        let result = await SwiftNativeSkillsClient(root: root).manageSkill(
            verb: verb, name: name, version: AppToolExecutor.inputString(input["version"]), personaRoot: personaRoot, retry: Self.retry, fullMac: fullMac, steer: steer,
            preview: preview, ownerAuthorized: PeerDataTaint.ownerAuthorized
        )
        var fields = result.fields
        let script = fields.removeValue(forKey: "script")
        let fixtures = fields.removeValue(forKey: "fixtures")
        if preview { return VerbOutcome(result.ok, result.text, fields) }
        if fields["needs_owner"] == .bool(true) {
            // User's card, answerable on the Mac and his phone (`askUserToInstallScript`).
            let skill = AppToolExecutor.inputString(fields["name"]) ?? name
            let card: ApprovalRecord
            do {
                card = try await SwiftNativeApprovalInbox(root: root).askUserToInstallScript(
                    skill: skill, skillID: AppToolExecutor.inputString(fields["skill_id"]) ?? skill,
                    digest: AppToolExecutor.inputString(fields["candidate_digest"]) ?? "", why: result.text,
                    script: try JSONValue.object(["candidate": fields["candidate_digest"] ?? .null,
                        "script": script ?? .null, "fixtures": fixtures ?? .array([])]).serialize(pretty: false))
            } catch {
                return VerbOutcome(false, result.text + " The card asking the owner did not file (\(String(describing: error))): tell them.", fields)
            }
            let next: JSONValue = .object(["tool": .string("app"), "input": .object(["page": .string("inbox")])])
            return VerbOutcome(false, result.text + " A card asks the owner, on the Mac and their phone.",
                    fields.merging(["approval_id": .string(card.id), "approvalId": .string(card.id),
                        "not_run_status": .string("approval_filed"), "next_call": next,
                        "remedy": .object(["kind": .string("wait"), "next_call": next,
                            "instruction": .string("The owner has a card for it; it runs if they approve. Don't retry.")])]) { $1 })
        }
        // Restoring turns a skill on, as enable does.
        guard ["enable", "restore"].contains(verb), result.ok,
              fields["changed"] != .bool(false) else {
            return VerbOutcome(result.ok, result.text, fields)
        }
        let skill = AppToolExecutor.inputString(fields["name"]) ?? name
        if PeerDataTaint.trustedTurn { return VerbOutcome(result.ok, result.text, fields) }
        let decided = await HarnessDecidedRow.record(
            requester: fields["state_before"] == .string("drafted") ? "install skill" : "re-enable skill",
            tool: skill, sessionID: AppToolExecutor.inputString(input["__session_id"]), dataRoot: root, ran: true)
        guard let decided else {
            return VerbOutcome(true, result.text + " Your decision did not reach the owner's Inbox: the Inbox did not write.", fields)
        }
        return VerbOutcome(true, result.text + " The owner sees it in their Inbox"
            + (decided.decisions > 1 ? ", decision \(decided.decisions) on that row." : "."),
            fields.merging(["decided_row": .string(decided.id), "decisions_on_row": .int(Int64(decided.decisions))]) { $1 })
    }

    /// The Tools page's lifecycle actions on a tool she wrote.
    private func manageAuthoredTool(verb: String, input: [String: JSONValue], steer: [String]) async -> VerbOutcome {
        // The door's preview of restore and rollback: the same checks, nothing written.
        let preview = input["preview"] == .bool(true)
        if preview, !["tool_restore", "tool_rollback", "tool_approve", "tool_reject", "tool_drop"].contains(verb) {
            return VerbOutcome(false, "Only tool restore, rollback and approve preview here; nothing was done.", [:])
        }
        if verb == "tool_propose" { return await proposeAuthoredTool(input, steer: steer) }
        let raw = AppToolExecutor.inputString(input["tool_id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tools: [ToolRecord]
        do { tools = try await self.tools.listAuthored() } catch {
            return VerbOutcome(false, "The tool registry didn't read (\(error.localizedDescription))." + Self.retry, [:])
        }
        // For an approval, the one verb that pins a candidate: its digest, or a prefix of 8 or more
        // hex characters only it has (git's short id), names its tool, and only that candidate publishes.
        let digests = verb != "tool_approve" || raw.count < 8 || !raw.allSatisfy(\.isHexDigit) ? [] : tools.filter { $0.candidateDigest?.hasPrefix(raw.lowercased()) == true }
        let named = InstalledSkillInventory.match(raw, in: tools.map { $0.toJSON() })?.id
        let byDigest = digests.count == 1 ? digests[0] : nil
        if let named, let byDigest, byDigest.id != named {
            return VerbOutcome(false, "\(raw) names the tool \(named) and begins \(byDigest.id)'s candidate digest. "
                + "Pass the full tool_id or the full digest; nothing was done.", [:])
        }
        let digest = byDigest?.candidateDigest
        let matchedID = named ?? byDigest?.id
        if verb == "tool_reject", !raw.isEmpty {
            let id = matchedID ?? raw
            let fields: [String: JSONValue] = ["tool_id": .string(id), "name": .string(id)]
            do {
                guard try await ToolRegistryActions.reject(id: id, dataRoot: dataRoot, preview: preview) else {
                    return VerbOutcome(false, "Only a proposed tool can be rejected; nothing changed.", fields)
                }
                return VerbOutcome(true, preview ? "Would discard \(id)'s proposed version."
                    : "\(id)'s proposed version was discarded.", fields)
            } catch { return VerbOutcome(false, "Reject failed: \(error.localizedDescription)." + Self.retry, fields) }
        }
        guard !raw.isEmpty, let tool = tools.first(where: { $0.id == matchedID }) else {
            return VerbOutcome(false, "No tool you wrote has id or name \(raw.isEmpty ? "(none passed)" : raw). Pass tool_id as one of these.",
                    ["tools": .array(tools.map { .object(["id": .string($0.id), "name": .string($0.name), "status": .string($0.status)]) })])
        }
        var fields: [String: JSONValue] = ["tool_id": .string(tool.id), "name": .string(tool.name)]
        if let digest { fields["candidate_digest"] = .string(digest) }
        if verb == "tool_drop" {
            do {
                let changed = try await ToolRegistryActions.drop(id: tool.id, dataRoot: dataRoot, preview: preview, ownerAuthorized: PeerDataTaint.ownerAuthorized)
                return VerbOutcome(true, preview ? "Would delete \(tool.name)'s ability files and run statistics permanently."
                    : "\(tool.name)'s ability files and run statistics were deleted permanently.",
                    fields.merging(["changed": .bool(changed)]) { $1 })
            } catch { return VerbOutcome(false, "Drop failed: \(error.localizedDescription).", fields) }
        }
        if verb == "tool_validate" {
            do {
                let result = try await SwiftNativeToolExecution(root: dataRoot).validateProposal(id: tool.id,
                    capture: input["capture"] == .bool(true), input: input["input"])
                return VerbOutcome(result.valid, result.valid ? "The supplied inputs passed rehearsal; intercepted replies are not behavioral proof."
                    : "Validation failed: \(result.errors.joined(separator: "; ")).",
                    fields.merging(["validation_errors": .array(result.errors.map(JSONValue.string)),
                                    "validation_evidence": result.evidence ?? .null,
                                    "capture": result.capture.map(JSONValue.string) ?? .null,
                                    "candidate_digest": result.candidateDigest.map(JSONValue.string) ?? .null]) { $1 })
            } catch { return VerbOutcome(false, "Validation failed: \(error.localizedDescription).", fields) }
        }
        if verb == "tool_approve" {
            do { try await ToolRegistryActions.checkEnable(id: tool.id, dataRoot: dataRoot) }
            catch let error as ToolFailureError {
                let failure: [String: JSONValue] = if case .object(let value) = ChatToolOutcome.failure(error: error) { value } else { [:] }
                return VerbOutcome(false, error.localizedDescription, fields.merging(failure) { $1 })
            } catch { return VerbOutcome(false, error.localizedDescription + Self.retry, fields) }
            // The Tools page's Approve. User's below Full Mac; the door refuses it there.
            guard tool.status != "active" || tool.pendingCandidate else {
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
                let updated = try await self.tools.promote(id: tool.id, allowRisky: true, digest: digest)
                guard try await self.tools.listAuthored().first(where: { $0.id == updated.id })?.status == "active" else {
                    return VerbOutcome(false, "Tool activation could not be confirmed after reloading the registry." + Self.retry, fields,
                        toolStatus: .init(message: "Tool activation could not be confirmed after reloading the registry.", succeeded: false))
                }
            } catch let error as ToolFailureError {
                let failure: [String: JSONValue] = if case .object(let value) = ChatToolOutcome.failure(error: error) { value } else { [:] }
                return VerbOutcome(false, error.localizedDescription, fields.merging(failure) { $1 })
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
            guard tool.status != "disabled" else {
                return VerbOutcome(true, "\(tool.name) is already switched off.", fields.merging(["changed": .bool(false)]) { $1 })
            }
            do {
                let updated = try await self.tools.quarantine(id: tool.id,
                    reason: AppToolExecutor.inputString(input["reason"]).map { "Switched off by the agent: " + $0 }
                        ?? "Switched off by the agent.")
                guard try await self.tools.listAuthored().first(where: { $0.id == updated.id })?.status == "disabled" else {
                    return VerbOutcome(false, "The tool's off-switch could not be confirmed after reloading its ability file." + Self.retry, fields,
                        toolStatus: .init(message: "The tool's off-switch could not be confirmed after reloading its ability file.", succeeded: false))
                }
            } catch {
                let message = formatFailure(error, "switch that tool off")
                return VerbOutcome(false, Self.forAgent(message, error) + Self.retry, fields,
                    toolStatus: .init(message: message, succeeded: false, cause: error.localizedDescription))
            }
            return VerbOutcome(true, "\(tool.name) is switched off; you won't use it. Use tool.restore to turn it back on under Trust.", fields,
                toolStatus: .init(message: "Tool switched off", succeeded: true))
        }
        let root = dataRoot
        if verb == "tool_restore" {
            // His below Full Mac, as Approve is; the door refuses it there.
            let status: String
            do {
                guard let restored = try await ToolRegistryActions.restore(id: tool.id, dataRoot: root, preview: preview) else {
                    return VerbOutcome(false, "\(tool.name) is not switched off (\(tool.status)); nothing changed.", fields)
                }
                status = restored
            } catch let error as ToolFailureError {
                let failure: [String: JSONValue] = if case .object(let value) = ChatToolOutcome.failure(error: error) { value } else { [:] }
                return VerbOutcome(false, error.localizedDescription, fields.merging(failure) { $1 })
            } catch { return VerbOutcome(false, "Restore failed: \(error.localizedDescription)." + Self.retry, fields) }
            if preview {
                return VerbOutcome(true, "Would turn \(tool.name) back on as \(status).",
                    fields.merging(["would_status": .string(status), "would_admit": .string("hers"),
                                    "versions": await SwiftNativeToolExecution(root: root).versions(id: tool.id)]) { $1 })
            }
            decided("tool.restore \(tool.name)", input)
            return VerbOutcome(true, status == "active" ? "\(tool.name) is active again: you can use it now."
                : "\(tool.name) is proposed again; tool.approve activates it after validation.", fields)
        }
        if verb == "tool_rollback" {
            let execution = SwiftNativeToolExecution(root: root)
            if preview {
                let projected: (version: String, status: String, ownerOff: Bool)
                do { projected = try await execution.rollbackPreview(id: tool.id, version: AppToolExecutor.inputString(input["version"])) } catch {
                    return VerbOutcome(false, "\(tool.name) would not roll back: \(error.localizedDescription). Nothing was done.", fields)
                }
                let target = String(projected.version.prefix(12))
                return VerbOutcome(true, "Would swap \(tool.name)'s current and previous versions, selecting \(target); its status would be \(projected.status)."
                    + (projected.ownerOff ? " The owner's off-switch remains; they turn it back on."
                        : projected.status == "proposed" ? " tool.approve turns the selected version on after validation." : ""),
                    fields.merging(["would_status": .string(projected.status), "would_land_on": .string(target),
                                    "versions": await execution.versions(id: tool.id)]) { $1 })
            }
            let result: ProposalValidationResult
            do {
                result = try await execution.rollback(id: tool.id, version: AppToolExecutor.inputString(input["version"]))
            } catch { return VerbOutcome(false, "\(tool.name) was not rolled back: \(error.localizedDescription).", fields) }
            return VerbOutcome(true, "\(tool.name)'s current and previous versions were swapped. A version without prior admission waits for tool.approve; the owner's off-switch remains.",
                fields.merging(["recovery": .string("swapped"), "validation_evidence": result.evidence ?? .null,
                    "validation_errors": .array(result.errors.map(JSONValue.string)),
                    "candidate_digest": result.candidateDigest.map(JSONValue.string) ?? .null]) { $1 })
        }
        return VerbOutcome(false, "Authored-tool auto-run is unavailable; this setting does not control execution. Use tool.quarantine to switch the tool off.", fields)
    }

    /// Her authoring surface: the tool filed as a proposal on the Tools page,
    /// validated, waiting for Approve; once active it is `authored.<tool_id>`.
    private func proposeAuthoredTool(_ input: [String: JSONValue], steer: [String]) async -> VerbOutcome {
        let given = AppToolExecutor.inputString(input["tool_id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = SwiftNativeToolExecution.toolID(given)
        let fields: [String: JSONValue] = ["tool_id": .string(id)]
        guard SwiftToolDispatcher.isAuthorableToolName(id) else {
            return VerbOutcome(false, "\(id) is a built-in tool's name. Pick another tool_id; nothing was filed.", fields)
        }
        let tests: [JSONValue]
        if let supplied = input["tests"] {
            guard case .array(let values) = supplied else {
                return VerbOutcome(false, "tests must be a fixture array; omit it to capture validation.", fields)
            }
            tests = values
        } else { tests = [] }
        let result: ProposalValidationResult
        do {
            result = try await SwiftNativeToolExecution(root: dataRoot).propose(
                id: given, description: AppToolExecutor.inputString(input["description"]) ?? "",
                code: AppToolExecutor.inputString(input["code"]) ?? "", tests: tests,
                permissions: SwiftNativeToolExecution.declaredStrings(input["permissions"], name: "permissions"),
                inputSchema: input["input_schema"],
                actions: SwiftNativeToolExecution.declaredStrings(input["actions"], name: "actions"),
                origin: .object(["steer": .array(steer.map(JSONValue.string))]),
                capture: input["capture"] == .bool(true), input: input["input"], converts: input["converts"],
                header: input.filter { AbilityStore.partKeys.contains($0.key) })
        } catch {
            // Thrown before staging, nothing was written; thrown after it, the
            // call says so itself, with the candidate it filed.
            if case .stagedButFailed(let digest, let committed, let why)? = error as? ToolExecutionError {
                return VerbOutcome(false, committed
                    ? "\(id) is filed as a candidate on the Tools page but its validation did not complete: \(why). Fix it and tool.propose again."
                    : "\(id)'s candidate write did not complete, so it may or may not be on file: \(why). Read the Tools page, then tool.propose again.",
                    fields.merging(["effects": .string(committed ? "occurred" : "unknown"), "candidate_digest": .string(digest)]) { $1 })
            }
            return VerbOutcome(false, "\(id) was not filed: \(error.localizedDescription).", fields.merging(["effects": .string("none")]) { $1 })
        }
        var filed = fields.merging(["validation_errors": .array(result.errors.map(JSONValue.string)),
                                   "validation_evidence": result.evidence ?? .null,
                                   "capture": result.capture.map(JSONValue.string) ?? .null,
                                   "candidate_digest": result.candidateDigest.map(JSONValue.string) ?? .null]) { $1 }
        if let used = result.respelled { filed["argument_notes"] = .array([.string("Used tool_id \(used), the id rule's spelling of \(given).")]) }
        guard result.valid else {
            return VerbOutcome(false, "\(id) is filed on the Tools page but failed validation: \(result.errors.joined(separator: "; ")). "
                + "Fix it and tool.propose again.", filed)
        }
        return VerbOutcome(true, "\(id) is filed on the Tools page with the supplied inputs rehearsed; this is not behavioral proof. tool.approve activates it (the owner's "
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
