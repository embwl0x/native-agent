import ChatTurnContracts
import ChatToolRuntime
import Cognition
import BackgroundLoops
import CognitiveSubstrate
import Foundation
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import PersonaEngine
import PersistenceCore
import Studio
import TrustCenter
// Blueprint: | `AppToolExecutor+QuietMind.swift` | Owner previews precede bootstrap and effect callbacks |

public typealias QuietMindOutcome = (ok: Bool, detail: String, fields: [String: JSONValue])

extension AppToolExecutor {
    private static let quietMindRetry = " Read \(AppToolExecutor.doorDoctor) to see what is wrong, then try again."

    @MainActor
    public static func quietMindMisses(dataRoot: URL, turn: Turn) async -> QuietMindOutcome {
        // Surface-hidden corrections count without text; all persona slots share the same store, so no persona recall filter applies.
        let weeks = [MemoryRecoveryReadout.isoWeek(), MemoryRecoveryReadout.isoWeek(ago: 1)]
        let envelope = TurnEnvelope.current(turn: turn, surface: turn.runtime?.surface ?? "chat")
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
        dataRoot: URL, remPolicy: TrustPolicy?, turn: Turn,
        dreamEnabled: () async throws -> Bool,
        runDream: () async -> (succeeded: Bool, status: String, error: String?, busy: [String]),
        previewDream: () async -> QuietMindOutcome,
        runREM: () async -> (succeeded: Bool, message: String)
    ) async -> QuietMindOutcome {
        if input["preview"] == .bool(true) {
            if verb == "dream" { return await previewDream() }
            if let clock = MindClockVerb(rawValue: verb) {
                let result = await runtime.runClockNow(verb: clock, input: input)
                return (result.ok, result.why, result.json)
            }
        }
        switch verb {
        case "dream":
            do {
                guard try await dreamEnabled() else {
                    return (false, "Your dream cycle is off. setting.set with setting personality.dreams, value true turns it on; then run again.", [:])
                }
            } catch {
                return (false, error.localizedDescription,
                    ["status": .string("unavailable"), "error": .string("trust_policy_unavailable")])
            }
            let run = await runDream()
            guard run.succeeded else {
                return (false, (run.error ?? "The dream pass failed.") + Self.quietMindRetry, [:])
            }
            // A held slot is busy, not broken: what it kept owed waits, named with its holder and when to call again.
            if !run.busy.isEmpty {
                return (false, run.status + ". Busy, nothing broken: " + run.busy.joined(separator: "; ")
                    + ". Run mind.dream again once that slot opens to settle it.", ["status": .string("busy"), "busy": .array(run.busy.map(JSONValue.string))])
            }
            return (true, run.status + ". app mind.dream_diary shows the entry.", [:])
        case "rem":
            guard let remPolicy else {
                return (false, "The Trust policy that gates REM hasn't been read yet. Try again in a moment.", [:])
            }
            guard remPolicy.trainingPolicy?.rem_cycle_enabled == true else {
                return (false, """
                    Your weekly REM consolidation is off. setting.set with setting personality.rem_cycle, value true turns it on; then run again.
                    """, [:])
            }
            let feedback = await runREM()
            guard feedback.succeeded else { return (false, feedback.message + Self.quietMindRetry, [:]) }
            return (true, feedback.message + " Its proposals wait in Approvals.", [:])
        case "body":
            return await quietMindBody()
        default: break
        }
        await runtime.bootstrap()
        if let clock = MindClockVerb(rawValue: verb) {
            let result = await runtime.runClockNow(verb: clock, input: input)
            return (result.ok, result.why, result.json)
        }
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
                return (false, (outcome.error ?? "Body signals are off.")
                    + " setting.set with setting settings.organism_kernel, value true turns them on.", [:])
            case .persistenceFailed:
                return (false, (outcome.error ?? "Body state was not saved.") + Self.quietMindRetry, [:])
            }
        }
        switch verb {
        case "why":
            let wantedTurn = input["turn"]?.scalarText
            guard case .object(let fields) = await runtime.why(turn: wantedTurn, callerTurn: turn) else { return (false, "No why record.", [:]) }
            return (fields["status"] == .string("ok"),
                    fields["detail"]?.scalarText ?? "Why it surfaced, from the turn trace.", fields)
        case "reject", "undo":
            // Only the agent's own live local turn may enter this action; bridge, replay and phone turns refuse.
            let seat: StudioCanonTurnProvenance
            switch StudioCanonSeatGate.liveTurnProvenance(turn: turn) {
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
                always: input["always"] == .bool(true), seat: seat, callerTurn: turn)
            return (outcome.ok, outcome.detail, ["source": .string(source)])
        case "think_now":
            return background(await runtime.runMicrocycle(reason: "mind_run think_now"), "Thinking")
        case "workspace":
            guard case .bool(let enabled)? = input["value"] else {
                return (false, "mind.workspace takes value true or false.", [:])
            }
            let detail = await runtime.observatoryDetail()
            if (detail.summary.ablations["workspace"] != false) != enabled {
                await runtime.setAblation("workspace", enabled: enabled)
            }
            return (true, enabled ? "Workspace included." : "Workspace excluded.", [:])
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
            switch StudioCanonSeatGate.liveTurnProvenance(turn: turn) {
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
                recordQuietMindDecision("mind.clear", input: input, dataRoot: dataRoot, turn: turn)
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

    /// The agent's body read: the same projection Doctor's Body view draws. It needs no running mind, so it reads before bootstrap.
    private static func quietMindBody() async -> QuietMindOutcome {
        let read: OrganBody?
        do { read = try await OrganBody.read() }
        catch { return (false, "Your body can't be read: the organ record is unreadable (\(error.localizedDescription))." + Self.quietMindRetry, [:]) }
        guard let body = read else {
            return (false, "Your body can't be read: the organ record is not installed in this process." + Self.quietMindRetry, [:])
        }
        let unreadable: [JSONValue] = body.unreadable.sorted { $0.key < $1.key }.map {
            .object(["organ": .string($0.key), "unreadable": .string($0.value)])
        }
        let gaps = body.unreadable.isEmpty ? "" : " Unreadable beats, so unknown: "
            + body.unreadable.keys.sorted().map(OrganBody.name).joined(separator: ", ") + "."
        guard !body.lines.isEmpty else {
            return (true, "No organ has a readable beat yet, so nothing else is known about your body." + gaps,
                    ["organs": .array([]), "unreadable": .array(unreadable)])
        }
        let iso = ISO8601DateFormatter()
        let organs: [JSONValue] = body.lines.map { line in
            .object([
                "organ": .string(line.organ),
                "line": .string(line.words(now: body.at)),
                "deviation": line.deviation.map { JSONValue.string($0.kind.rawValue) } ?? .null,
                "outcome": .string(line.latest.outcome.rawValue),
                "at": .string(iso.string(from: line.latest.at)),
                "next": line.next.map { JSONValue.string(iso.string(from: $0)) } ?? .null,
            ])
        }
        let felt = body.felt.count
        return (true, (felt == 0 ? "Every organ matches its record. " : "\(felt) of \(body.lines.count) organs broke from their record. ")
                    + body.lines.map { $0.words(now: body.at) }.joined(separator: "; ") + "." + gaps,
                ["organs": .array(organs), "felt": .int(Int64(felt)), "unreadable": .array(unreadable)])
    }

    public static func recordQuietMindDecision(_ tool: String, input: [String: JSONValue], dataRoot: URL, turn: Turn) {
        BodyDecidedRow.post(turn: turn, requester: "Full Mac", tool: tool,
                              sessionID: input["__session_id"]?.scalarText, dataRoot: dataRoot)
    }
}
