import AppToolRuntime
import ApprovalInbox
import BackgroundLoops
import ChatToolRuntime
import Cognition
import Foundation
import NativeAgentCore
import NativeAgentShared
import NotificationInbox
import PersonaEngine
import PersistenceCore
import ToolExecution
import ToolRegistry
import Skills
import Studio
import MemoryV2

/// `mind_run` and `skill_manage`: each verb is the call its button makes on
/// the Dreams, Self-Improvement, Observatory, Skills or Tools page, gated by
/// what disables that button. Core has already admitted the call (posture
/// gate) and refused User's floor (Clear, Approve, auto-run on) below Full Mac;
/// under it each of those posts the decided row he sees it by. Nothing here
/// moves User's screen.
extension AppQuietToolHost {
    typealias VerbOutcome = (ok: Bool, detail: String, fields: [String: JSONValue])

    private static let retry = " Read \(AppToolExecutor.doorDoctor) to see what is wrong, then try again."

    // MARK: - mind_run

    func runMind(verb: String, input: [String: JSONValue]) async -> VerbOutcome {
        switch verb {
        case "dream":
            guard await dreamEnabled() else {
                return (false, "Your dream cycle is off. setting.set with setting personality.dreams, value true turns it on; then run again.", [:])
            }
            guard await appModel.runDreamPassForDreams() else {
                return (false, (appModel.dreamError ?? "The dream pass failed.") + Self.retry, [:])
            }
            return (true, appModel.statusText + ". app mind.dream_diary shows the entry.", [:])
        case "rem":
            switch DreamsREMRunAvailability.resolve(policy: trustPolicy, policyLoadFailed: false) {
            case .enabled: break
            case .disabled:
                return (false, "Your weekly REM consolidation is off. setting.set with setting personality.rem_cycle, value true turns it on; then run again.", [:])
            case .checking, .unavailable:
                return (false, "The Trust policy that gates REM hasn't been read yet. Try again in a moment.", [:])
            }
            let feedback = await appModel.runRemPass()
            guard feedback.isSuccess else { return (false, feedback.message + Self.retry, [:]) }
            return (true, feedback.message + " Its proposals wait in User's Approvals.", [:])
        case "self_improvement":
            guard UserDefaults.standard.object(forKey: "selfImprovementEnabled") as? Bool ?? true else {
                return (false, "Personal growth is off. setting.set with setting personality.self_improvement, value true turns it on; then run again.", [:])
            }
            let run = await SelfImprovementView.runManually(appModel: appModel)
            if case .completed? = run.outcome { return (true, run.note, [:]) }
            if run.outcome?.isCoalescedSkip == true { return (true, run.note, [:]) }
            return (false, run.note + Self.retry, [:])
        default:
            return await runObservatory(verb: verb, input: input)
        }
    }

    /// The Observatory's buttons, refused when the same switch that greys the
    /// button out is off.
    private func runObservatory(verb: String, input: [String: JSONValue]) async -> VerbOutcome {
        let runtime = NativeAgentEngine.liveCognition
        let detail = await CognitionObservatoryActions.refresh(runtime: runtime)
        let config = detail.configuration
        guard config.enabled else {
            return (false, "Your inner life is off, and the Observatory with it. setting.set with setting settings.inner_life, value true turns it on.", [:])
        }
        func background(_ outcome: CognitiveBackgroundRunOutcome, _ label: String) -> VerbOutcome {
            switch outcome {
            case .completed(let note): return (true, "\(label) done: \(note).", [:])
            case .skipped(let reason): return (true, "\(label) skipped: \(reason).", ["changed": .bool(false)])
            case .failed(let reason): return (false, "\(label) failed: \(reason)." + Self.retry, [:])
            }
        }
        func body(_ outcome: OrganismContinuityApplyOutcome, _ label: String) -> VerbOutcome {
            switch outcome.status {
            case .applied: return (true, "Body state \(label) and saved.", [:])
            case .organismDisabled:
                return (false, (outcome.error ?? "Body signals are off.") + " setting.set with setting settings.organism_kernel, value true turns them on.", [:])
            case .persistenceFailed:
                return (false, (outcome.error ?? "Body state was not saved.") + Self.retry, [:])
            }
        }
        switch verb {
        case "why":
            let turn = AppToolExecutor.inputString(input["turn"])
            guard case .object(let fields) = await runtime.why(turn: turn) else { return (false, "No why record.", [:]) }
            return (fields["status"] == .string("ok"),
                    AppToolExecutor.inputString(fields["detail"]) ?? "Why it surfaced, from the turn trace.", fields)
        case "reject", "undo", "revise":
            // Phase 5 B0: the seat hold_view/release_view use — her own live
            // local turn, refused on a bridge, executor, replay or phone lane.
            let seat: StudioCanonTurnProvenance
            switch StudioCanonSeatGate.liveTurnProvenance() {
            case .success(let provenance): seat = provenance
            case .failure(let refusal):
                return (false, "mind.\(verb): \(refusal.spoken). It is done from inside your own conversation, in your own turn.",
                        ["reason": .string(refusal.rawValue)])
            }
            if verb == "revise" {
                let raw = AppToolExecutor.inputString(input["view_id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let id = UUID(uuidString: raw) else {
                    return (false, "mind.revise: name the opinion by its view_id, from app mind.inner_state.", [:])
                }
                let refusal = await runtime.reviseOpinion(
                    id: id, stance: AppToolExecutor.inputString(input["view"]) ?? "",
                    evidence: AppToolExecutor.inputString(input["evidence"]) ?? "",
                    wouldChangeMind: AppToolExecutor.inputString(input["unless"]) ?? "", seat: seat)
                return refusal == nil
                    ? (true, "Revised. The earlier view and what changed it are kept; mind.undo reverses it.", ["view_id": .string(raw)])
                    : (false, "Not revised: \(refusal!).", ["view_id": .string(raw)])
            }
            if verb == "undo" {
                let outcome = await runtime.undo(item: AppToolExecutor.inputString(input["item"]), seat: seat)
                return (outcome.ok, outcome.detail, outcome.fields)
            }
            let source = AppToolExecutor.inputString(input["source"]) ?? ""
            let outcome = await runtime.rejectAssociation(
                source: source, turn: AppToolExecutor.inputString(input["turn"]),
                always: input["always"] == .bool(true), seat: seat)
            return (outcome.ok, outcome.detail, ["source": .string(source)])
        case "think_now":
            return background(await runtime.runMicrocycle(reason: "mind_run think_now"), "Thinking")
        case "reflect":
            guard config.reflectiveCallsEnabled else {
                return (false, "Reflection is off. setting.set with setting settings.reflection, value true turns it on.", [:])
            }
            guard config.dailyReflectionCallBudget > 0 else {
                return (false, "Your daily reflection budget is 0. setting.set with setting settings.daily_reflection_budget, value 1 to 8 allows one.", [:])
            }
            return background(await CognitionObservatoryActions.reflectWithOutcome(runtime: runtime).status, "Reflection")
        case "settle_body", "reset_body":
            guard detail.organism.enabled else {
                return (false, "Body signals are off. setting.set with setting settings.organism_kernel, value true turns them on.", [:])
            }
            return verb == "settle_body"
                ? body(await CognitionObservatoryActions.settleBodyChecked(runtime: runtime).outcome, "settled")
                : body(await CognitionObservatoryActions.resetBodyChecked(runtime: runtime).outcome, "reset")
        case "pin_concern":
            guard let pinned = await runtime.pinTopConcern() else {
                return (true, "Nothing pressing to pin right now.", ["changed": .bool(false)])
            }
            return (true, "Pinned: \(pinned)", [:])
        case "run_checks":
            let outcome = await runtime.runResearchHarness()
            return (!outcome.isFailed, outcome.presentationText + (outcome.isFailed ? Self.retry : ""), [:])
        case "export_trace":
            guard let path = await runtime.exportResearchTrace() else {
                return (false, "The trace could not be written. Check free disk space, then try again.", [:])
            }
            return (true, "Trace exported to \(path).", ["path": .string(path)])
        case "ablate_workspace", "include_workspace":
            let include = verb == "include_workspace"
            guard (detail.summary.ablations["workspace"] == false) == include else {
                return (true, include ? "The workspace is already included." : "The workspace is already left out.",
                        ["changed": .bool(false)])
            }
            await runtime.setAblation("workspace", enabled: include)
            return (true, include
                ? "The workspace is included again."
                : "The workspace is left out: the thought summary and background thinking ignore it until include_workspace.", [:])
        case "decline_view", "approve_view":
            let approve = verb == "approve_view"
            let raw = AppToolExecutor.inputString(input["view_id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let id = UUID(uuidString: raw), let view = detail.standingViews.first(where: { $0.id == id }) else {
                return (false, "No standing view has id \(raw.isEmpty ? "(none passed)" : raw). app mind.inner_state lists your proposed views with their ids.", [:])
            }
            let outcome = await CognitionProposalActions.resolveWithOutcome(runtime: runtime, id: id, approved: approve)
            switch outcome.status {
            case .applied:
                guard approve else { return (true, "Declined \"\(view.title)\"; it is retired.", ["view_id": .string(raw)]) }
                decided("mind.approve_view \(view.title)", input)
                return (true, "Approved \"\(view.title)\"; it is a standing view now.", ["view_id": .string(raw)])
            case .unavailable(let why): return (false, why + " app mind.inner_state shows its status now.", [:])
            case .notSaved(let why):
                return (false, "\(approve ? "Approved" : "Declined") in memory, but not saved: \(why). "
                    + "It may come back after a restart." + Self.retry, [:])
            }
        case "clear":
            // The Observatory's Clear.
            switch await runtime.clearTransientState() {
            case .cleared:
                decided("mind.clear", input)
                return (true, "Thinking and body state cleared.", [:])
            case .persistenceFailed(let why):
                return (false, "Nothing was cleared; the state was kept: \(why)." + Self.retry, [:])
            case .bodyPersistenceFailed:
                return (false, "Thinking state cleared. Body state cleared in memory, but was not saved; its previous state may return after a restart.", [:])
            }
        default:
            return (false, "No mind_run button is called \(verb).", [:])
        }
    }

    // MARK: - skill_manage

    /// Agent's rulings, 2026-10-01: installing her drafts is hers, and User
    /// sees each one as a decided row; she turns back on only what she turned
    /// off; delete is a trash she can restore from; built-in skills are User's.
    func manageSkill(verb: String, input: [String: JSONValue], steer: [String]) async -> VerbOutcome {
        if verb.hasPrefix("tool_") { return await manageAuthoredTool(verb: verb, input: input) }
        let name = AppToolExecutor.inputString(input["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = appModel.dataRootOverride ?? NativeAgentPaths.dataRoot
        let personaRoot = appModel.dataRootOverride.map { $0.appendingPathComponent("persona") } ?? PersonaRootResolver.resolve()
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
        if preview { return (result.ok, result.text, fields) }
        await appModel.loadSkillManifests()
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
                return (false, result.text + " The card asking him did not file (\(String(describing: error))): tell him.", fields)
            }
            return (false, result.text + " A card asks him, on the Mac and his phone.",
                    fields.merging(["approval_id": .string(card.id)]) { $1 })
        }
        // Restoring an archived skill turns it on, as enable does.
        guard verb == "enable" || fields["state_before"] == .string(CapabilityLifecycle.archived), result.ok,
              fields["changed"] != .bool(false) else {
            return (result.ok, result.text, fields)
        }
        let skill = AppToolExecutor.inputString(fields["name"]) ?? name
        let decided = await HarnessDecidedRow.record(
            requester: fields["state_before"] == .string("drafted") ? "install skill" : "re-enable skill",
            tool: skill, sessionID: AppToolExecutor.inputString(input["__session_id"]), dataRoot: root)
        guard let decided else {
            return (true, result.text + " Your decision did not reach User's Inbox: the Inbox did not write.", fields)
        }
        return (true, result.text + " User sees it in his Inbox"
            + (decided.decisions > 1 ? ", decision \(decided.decisions) on that row." : "."),
            fields.merging(["decided_row": .string(decided.id), "decisions_on_row": .int(Int64(decided.decisions))]) { $1 })
    }

    /// The Tools page's lifecycle actions on a tool she wrote.
    private func manageAuthoredTool(verb: String, input: [String: JSONValue]) async -> VerbOutcome {
        // The door's preview of restore and rollback: the same checks, nothing written.
        let preview = input["preview"] == .bool(true)
        if preview, !["tool_restore", "tool_rollback"].contains(verb) {
            return (false, "Only tool restore and rollback preview here; nothing was done.", [:])
        }
        if verb == "tool_propose" { return await proposeAuthoredTool(input) }
        let raw = AppToolExecutor.inputString(input["tool_id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tools: [ToolRecord]
        do { tools = try await appModel.engine.tools.listAuthored() } catch {
            return (false, "The tool registry didn't read (\(error.localizedDescription))." + Self.retry, [:])
        }
        guard !raw.isEmpty, let tool = tools.first(where: { [$0.id, $0.name].map { $0.lowercased() }.contains(raw.lowercased()) }) else {
            return (false, "No tool you wrote has id or name \(raw.isEmpty ? "(none passed)" : raw). Pass tool_id as one of these.",
                    ["tools": .array(tools.map { .object(["id": .string($0.id), "name": .string($0.name), "status": .string($0.status)]) })])
        }
        let fields: [String: JSONValue] = ["tool_id": .string(tool.id), "name": .string(tool.name)]
        let confirmed = { [appModel] in appModel.engine.tools.authored.first { $0.id == tool.id } }
        if verb == "tool_approve" {
            // The Tools page's Approve. User's below Full Mac; the door refuses it there.
            guard tool.status != "active" else {
                return (true, "\(tool.name) is already active.", fields.merging(["changed": .bool(false)]) { $1 })
            }
            await appModel.promoteTool(tool, userRequested: true)
            guard confirmed()?.status == "active" else { return (false, appModel.statusText + Self.retry, fields) }
            decided("tool.approve \(tool.name)", input)
            return (true, "\(tool.name) is active: you can use it now.", fields)
        }
        if verb == "tool_quarantine" {
            guard AuthoredToolPresentation.canQuarantine(tool) else {
                return (true, "\(tool.name) is already quarantined.", fields.merging(["changed": .bool(false)]) { $1 })
            }
            await appModel.quarantineTool(tool, reason: AppToolExecutor.inputString(input["reason"]).map { "Quarantined by the agent: " + $0 }
                ?? "Quarantined by the agent.")
            guard confirmed()?.status == "quarantined" else { return (false, appModel.statusText + Self.retry, fields) }
            return (true, "\(tool.name) is quarantined; you won't use it. Approving it again is User's.", fields)
        }
        let root = appModel.dataRootOverride ?? NativeAgentPaths.dataRoot
        if verb == "tool_restore" {
            // His below Full Mac, as Approve is; the door refuses it there.
            do {
                guard try await ToolRegistryActions.restore(id: tool.id, dataRoot: root, preview: preview) else {
                    return (false, "\(tool.name) is not archived (\(tool.status)); nothing changed.", fields)
                }
            } catch { return (false, "Restore failed: \(error.localizedDescription)." + Self.retry, fields) }
            if preview {
                return (true, "Would turn \(tool.name) back on, active at once and yours under Full Mac, no approval after it; "
                    + "its 30-day unused clock restarts.",
                    fields.merging(["would_status": .string("active"), "would_admit": .string("hers"),
                                    "would_clock": .string("restarts now"),
                                    "versions": await SwiftNativeToolExecution(root: root).versions(id: tool.id)]) { $1 })
            }
            if let reloaded = try? await appModel.engine.tools.listAuthored() { appModel.engine.tools.authored = reloaded }
            decided("tool.restore \(tool.name)", input)
            return (true, "\(tool.name) is active again: you can use it now.", fields)
        }
        if verb == "tool_rollback" {
            let execution = SwiftNativeToolExecution(root: root)
            if preview {
                let target: String
                do { target = String(try await execution.rollbackPreview(id: tool.id).prefix(12)) } catch {
                    return (false, "\(tool.name) would not roll back: \(error.localizedDescription). Nothing was done.", fields)
                }
                let fullMac = await AppToolExecutor.freshQuietPosture(dataRoot: root)?.name == AppToolExecutor.fullMacModeName
                return (true, "Would put \(tool.name) back to version \(target), proposed: tool.approve turns it on, "
                    + (fullMac ? "yours under Full Mac" : "User's on the Tools page")
                    + ", once it passes validation; its 30-day unused clock restarts then.",
                    fields.merging(["would_status": .string("proposed"), "would_admit": .string(fullMac ? "hers" : "users"),
                                    "would_clock": .string("restarts when it is turned on"), "would_land_on": .string(target),
                                    "versions": await execution.versions(id: tool.id)]) { $1 })
            }
            let result: ProposalValidationResult
            do {
                result = try await execution.rollback(id: tool.id)
            } catch { return (false, "\(tool.name) was not rolled back: \(error.localizedDescription).", fields) }
            if let reloaded = try? await appModel.engine.tools.listAuthored() { appModel.engine.tools.authored = reloaded }
            return (result.valid, "\(tool.name) is back to the version before, proposed: tool.approve activates it"
                + (result.valid ? "." : ", once it passes validation: \(result.errors.joined(separator: "; ")).")
                + " The version it replaced is kept.", fields)
        }
        return (false, "Authored-tool auto-run is unavailable; this setting does not control execution. Quarantine the tool to stop it.", fields)
    }

    /// Her authoring surface: the tool filed as a proposal on the Tools page,
    /// validated, waiting for Approve; once active it is `authored.<tool_id>`.
    private func proposeAuthoredTool(_ input: [String: JSONValue]) async -> VerbOutcome {
        let id = AppToolExecutor.inputString(input["tool_id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fields: [String: JSONValue] = ["tool_id": .string(id)]
        guard SwiftToolDispatcher.isAuthorableToolName(id) else {
            return (false, "\(id) is a built-in tool's name. Pick another tool_id; nothing was filed.", fields)
        }
        let list = { (key: String) -> [JSONValue] in if case .array(let items)? = input[key] { items } else { [] } }
        let result: ProposalValidationResult
        do {
            result = try await SwiftNativeToolExecution(root: appModel.dataRootOverride ?? NativeAgentPaths.dataRoot).propose(
                id: id, description: AppToolExecutor.inputString(input["description"]) ?? "",
                code: AppToolExecutor.inputString(input["code"]) ?? "", tests: list("tests"),
                permissions: list("permissions").compactMap(AppToolExecutor.inputString),
                inputSchema: input["input_schema"].flatMap { if case .object = $0 { $0 } else { nil } })
        } catch {
            return (false, "\(id) was not filed: \(error.localizedDescription).", fields)
        }
        if let reloaded = try? await appModel.engine.tools.listAuthored() { appModel.engine.tools.authored = reloaded }
        let filed = fields.merging(["validation_errors": .array(result.errors.map(JSONValue.string))]) { $1 }
        guard result.valid else {
            return (false, "\(id) is filed on the Tools page but failed validation: \(result.errors.joined(separator: "; ")). "
                + "Fix it and tool.propose again.", filed)
        }
        return (true, "\(id) is filed on the Tools page and passed validation. tool.approve activates it (User's "
            + "below Full Mac); then it runs as authored.\(id).", filed)
    }

    /// One of User's buttons she pressed under Full Mac: the row he sees it by.
    private func decided(_ tool: String, _ input: [String: JSONValue]) {
        HarnessDecidedRow.post(requester: "Full Mac", tool: tool, sessionID: AppToolExecutor.inputString(input["__session_id"]),
                               dataRoot: appModel.dataRootOverride ?? NativeAgentPaths.dataRoot)
    }
}
