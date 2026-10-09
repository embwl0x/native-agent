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
            return (true, appModel.statusForAgent + ". app mind.dream_diary shows the entry.", [:])
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
            return (true, feedback.message + " Its proposals wait in Approvals.", [:])
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

    func manageSkill(verb: String, input: [String: JSONValue], steer: [String]) async -> VerbOutcome {
        let outcome = await CapabilityLifecycleCommands(dataRootOverride: appModel.dataRootOverride,
            tools: appModel.engine.tools, formatFailure: { error, action in
                UserFacingError.message(error, action: action)
            }).manageSkill(verb: verb, input: input, steer: steer)
        if outcome.refreshSkills { await appModel.loadSkillManifests() }
        if let status = outcome.toolStatus {
            appModel.recordToolOperationStatus(status.message, outcome: status.succeeded ? .succeeded : .failed)
            appModel.statusCause = status.cause
        }
        if outcome.refreshTools, let reloaded = try? await appModel.engine.tools.listAuthored() {
            appModel.engine.tools.authored = reloaded
        }
        return (outcome.ok, outcome.detail, outcome.fields)
    }

    /// One of User's buttons she pressed under Full Mac: the row he sees it by.
    private func decided(_ tool: String, _ input: [String: JSONValue]) {
        HarnessDecidedRow.post(requester: "Full Mac", tool: tool, sessionID: AppToolExecutor.inputString(input["__session_id"]),
                               dataRoot: appModel.dataRootOverride ?? NativeAgentPaths.dataRoot)
    }
}
