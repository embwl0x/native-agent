import ChatOrchestration
import Cognition
import CognitiveSubstrate
import Foundation
import MemoryV2
import NativeAgentShared
import PersonaEngine
import PersistenceCore
import Studio
import TrustCenter

public typealias QuietMindOutcome = (ok: Bool, detail: String, fields: [String: JSONValue])

extension AppToolExecutor {
    private static let quietMindRetry = " Read \(AppToolExecutor.doorDoctor) to see what is wrong, then try again."

    @MainActor
    public static func quietMindMisses(dataRoot: URL) async -> QuietMindOutcome {
        // The Self-Improvement page's first section, read for her on the
        // surface she is answering, as mind.why reads it: a correction
        // that surface may not see counts, without its text. No persona
        // filter: one store for every persona slot (memoryRecallPersonaFilter).
        let weeks = [MemoryStatusProjection.isoWeek(), MemoryStatusProjection.isoWeek(ago: 1)]
        let envelope = TurnEnvelope.current(surface: ChatTurnRuntimeContext.current?.surface ?? "chat")
        do {
            let lessons = try await MemoryStatusProjection.misses(
                dataRoot: dataRoot, weeks: weeks,
                surface: envelope.agent == nil ? envelope.replyRoute.surface : "bridge")
            return (true, lessons.isEmpty ? "No corrections this week or last."
                        : "Your misses by lesson, this week (\(weeks[0])) / last (\(weeks[1])): "
                            + lessons.map { "\($0.lesson) \($0.count(week: weeks[0]))/\($0.count(week: weeks[1]))" }
                                .joined(separator: ", ") + ".",
                    ["lessons": try JSONValue.fromEncodable(lessons)])
        } catch {
            return (false, "The miss ledger could not be read: \(error.localizedDescription)." + Self.quietMindRetry, [:])
        }
    }

    /// The Observatory's buttons, refused when the same switch that greys the
    /// button out is off.
    @MainActor
    public static func runQuietMind(
        verb: String, input: [String: JSONValue], runtime: NativeCognitionRuntime,
        dataRoot: URL, remPolicy: TrustPolicy?,
        dreamEnabled: () async -> Bool,
        runDream: () async -> (succeeded: Bool, status: String, error: String?),
        runREM: () async -> (succeeded: Bool, message: String),
        runGrowth: () async -> (succeeded: Bool, note: String)
    ) async -> QuietMindOutcome {
        switch verb {
        case "dream":
            guard await dreamEnabled() else {
                return (false, "Your dream cycle is off. setting.set with setting personality.dreams, value true turns it on; then run again.", [:])
            }
            let run = await runDream()
            guard run.succeeded else {
                return (false, (run.error ?? "The dream pass failed.") + Self.quietMindRetry, [:])
            }
            return (true, run.status + ". app mind.dream_diary shows the entry.", [:])
        case "rem":
            guard let remPolicy else {
                return (false, "The Trust policy that gates REM hasn't been read yet. Try again in a moment.", [:])
            }
            guard remPolicy.trainingPolicy?.rem_cycle_enabled == true else {
                return (false, "Your weekly REM consolidation is off. setting.set with setting personality.rem_cycle, value true turns it on; then run again.", [:])
            }
            let feedback = await runREM()
            guard feedback.succeeded else { return (false, feedback.message + Self.quietMindRetry, [:]) }
            return (true, feedback.message + " Its proposals wait in Approvals.", [:])
        case "self_improvement":
            guard UserDefaults.standard.object(forKey: "selfImprovementEnabled") as? Bool ?? true else {
                return (false, "Personal growth is off. setting.set with setting personality.self_improvement, value true turns it on; then run again.", [:])
            }
            let run = await runGrowth()
            if run.succeeded { return (true, run.note, [:]) }
            return (false, run.note + Self.quietMindRetry, [:])
        default: break
        }
        let detail = await runtime.observatoryDetailRead().detail
        let config = detail.configuration
        guard config.enabled else {
            return (false, "Your inner life is off, and the Observatory with it. setting.set with setting settings.inner_life, value true turns it on.", [:])
        }
        func background(_ outcome: CognitiveBackgroundRunOutcome, _ label: String) -> QuietMindOutcome {
            switch outcome {
            case .completed(let note): return (true, "\(label) done: \(note).", [:])
            case .skipped(let reason): return (true, "\(label) skipped: \(reason).", ["changed": .bool(false)])
            case .failed(let reason): return (false, "\(label) failed: \(reason)." + Self.quietMindRetry, [:])
            }
        }
        func body(_ outcome: OrganismContinuityApplyOutcome, _ label: String) -> QuietMindOutcome {
            switch outcome.status {
            case .applied: return (true, "Body state \(label) and saved.", [:])
            case .organismDisabled:
                return (false, (outcome.error ?? "Body signals are off.") + " setting.set with setting settings.organism_kernel, value true turns them on.", [:])
            case .persistenceFailed:
                return (false, (outcome.error ?? "Body state was not saved.") + Self.quietMindRetry, [:])
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
            let outcome = await runtime.runManualReflection()
            _ = await runtime.observatoryDetailRead()
            return background(outcome, "Reflection")
        case "settle_body", "reset_body":
            guard detail.organism.enabled else {
                return (false, "Body signals are off. setting.set with setting settings.organism_kernel, value true turns them on.", [:])
            }
            let outcome = verb == "settle_body"
                ? await runtime.settleOrganismContinuityChecked()
                : await runtime.resetOrganismContinuityChecked()
            _ = await runtime.observatoryDetailRead()
            return body(outcome, verb == "settle_body" ? "settled" : "reset")
        case "pin_concern":
            guard let pinned = await runtime.pinTopConcern() else {
                return (true, "Nothing pressing to pin right now.", ["changed": .bool(false)])
            }
            return (true, "Pinned: \(pinned)", [:])
        case "run_checks":
            let outcome = await runtime.runResearchHarness()
            return (!outcome.isFailed, outcome.presentationText + (outcome.isFailed ? Self.quietMindRetry : ""), [:])
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
            let outcome = await runtime.resolveStandingViewWithOutcome(id: id, approved: approve)
            switch outcome.status {
            case .applied:
                guard approve else { return (true, "Declined \"\(view.title)\"; it is retired.", ["view_id": .string(raw)]) }
                recordQuietMindDecision("mind.approve_view \(view.title)", input: input, dataRoot: dataRoot)
                return (true, "Approved \"\(view.title)\"; it is a standing view now.", ["view_id": .string(raw)])
            case .unavailable(let why): return (false, why + " app mind.inner_state shows its status now.", [:])
            case .notSaved(let why):
                return (false, "\(approve ? "Approved" : "Declined") in memory, but not saved: \(why). "
                    + "It may come back after a restart." + Self.quietMindRetry, [:])
            }
        case "clear":
            // The Observatory's Clear.
            switch await runtime.clearTransientState() {
            case .cleared:
                recordQuietMindDecision("mind.clear", input: input, dataRoot: dataRoot)
                return (true, "Thinking and body state cleared.", [:])
            case .persistenceFailed(let why):
                return (false, "Nothing was cleared; the state was kept: \(why)." + Self.quietMindRetry, [:])
            case .bodyPersistenceFailed:
                return (false, "Thinking state cleared. Body state cleared in memory, but was not saved; its previous state may return after a restart.", [:])
            }
        default:
            return (false, "No mind_run button is called \(verb).", [:])
        }
    }

    public static func recordQuietMindDecision(_ tool: String, input: [String: JSONValue], dataRoot: URL) {
        HarnessDecidedRow.post(requester: "Full Mac", tool: tool,
                              sessionID: inputString(input["__session_id"]), dataRoot: dataRoot)
    }
}
