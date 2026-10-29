import ChatTurnContracts
import ChatToolRuntime
import Cognition
import BackgroundLoops
import CognitiveSubstrate
import Foundation
import MemoryV2
import NativeAgentShared
import PersonaEngine
import PersistenceCore
import Studio
import TrustCenter
// Blueprint: | `AppToolExecutor+QuietMind.swift` | quiet mind commands and decision receipts |

public typealias QuietMindOutcome = (ok: Bool, detail: String, fields: [String: JSONValue])

extension AppToolExecutor {
    private static let quietMindRetry = " Read \(AppToolExecutor.doorDoctor) to see what is wrong, then try again."

    @MainActor
    public static func quietMindMisses(dataRoot: URL) async -> QuietMindOutcome {
        // The Self-Improvement page's first section, read for her on the
        // surface she is answering, as mind.why reads it: a correction
        // that surface may not see counts, without its text. No persona
        // filter: one store for every persona slot (memoryRecallPersonaFilter).
        let weeks = [MemoryRecoveryReadout.isoWeek(), MemoryRecoveryReadout.isoWeek(ago: 1)]
        let envelope = TurnEnvelope.current(surface: ChatTurnRuntimeContext.current?.surface ?? "chat")
        do {
            let lessons = try await MemoryRecoveryReadout.misses(
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

    /// Mind actions use the live runtime's configuration and effect owners.
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
        await runtime.bootstrap()
        let config = await runtime.substrate.configurationSnapshot()
        guard config.enabled else {
            return (false, "Your inner life is off. setting.set with setting settings.inner_life, value true turns it on.", [:])
        }
        func background(_ outcome: LoopTickOutcome, _ label: String) -> QuietMindOutcome {
            switch outcome {
            case .completed(let note): return (true, note.map { "\(label) done: \($0)." } ?? "\(label) done.", [:])
            case .skipped(let reason, _): return (true, "\(label) skipped: \(reason).", ["changed": .bool(false)])
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
            let turn = input["turn"]?.scalarText
            guard case .object(let fields) = await runtime.why(turn: turn) else { return (false, "No why record.", [:]) }
            return (fields["status"] == .string("ok"),
                    fields["detail"]?.scalarText ?? "Why it surfaced, from the turn trace.", fields)
        case "reject", "undo":
            // Her own live local turn, refused on a bridge, executor, replay or phone lane.
            let seat: StudioCanonTurnProvenance
            switch StudioCanonSeatGate.liveTurnProvenance() {
            case .success(let provenance): seat = provenance
            case .failure(let refusal):
                return (false, "mind.\(verb): \(refusal.spoken). It is done from inside your own conversation, in your own turn.",
                        ["reason": .string(refusal.rawValue)])
            }
            if verb == "undo" {
                let outcome = await runtime.undo(item: input["item"]?.scalarText, seat: seat)
                return (outcome.ok, outcome.detail, outcome.fields)
            }
            let source = input["source"]?.scalarText ?? ""
            let outcome = await runtime.rejectAssociation(
                source: source, turn: input["turn"]?.scalarText,
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
            return background(outcome, "Reflection")
        case "settle_body", "reset_body":
            let outcome = verb == "settle_body"
                ? await runtime.settleOrganismContinuityChecked()
                : await runtime.resetOrganismContinuityChecked()
            return body(outcome, verb == "settle_body" ? "settled" : "reset")
        case "pin_concern":
            let seat: StudioCanonTurnProvenance
            switch StudioCanonSeatGate.liveTurnProvenance() {
            case .success(let provenance): seat = provenance
            case .failure(let refusal):
                return (false, "mind.pin_concern: \(refusal.spoken). It is done from inside your own conversation, in your own turn.",
                        ["reason": .string(refusal.rawValue)])
            }
            do {
                guard let pinned = try await runtime.pinTopConcern(
                    text: input["concern"]?.scalarText,
                    care: input["care"]?.scalarText, seat: seat) else {
                    return (true, "Nothing pressing to pin right now.", ["changed": .bool(false)])
                }
                return (true, "Kept open: \(pinned)", [:])
            } catch {
                return (false, "The concern was not saved: \(error)." + Self.quietMindRetry, [:])
            }
        case "clear":
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
                              sessionID: input["__session_id"]?.scalarText, dataRoot: dataRoot)
    }
}
