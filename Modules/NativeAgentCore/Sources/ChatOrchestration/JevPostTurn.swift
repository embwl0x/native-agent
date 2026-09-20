import Foundation
import CryptoKit
import PersistenceCore

/// Lane 3 — the post-turn check.
///
/// Reads the ask and the reply and looks for four things: the ask went
/// unanswered, the reply ended on a promise with no execution behind it, the
/// reply pointed the person at a screen instead of doing the thing, or it
/// claimed a completion nothing supports.
///
/// Findings go to the LOG. Only an issue that is both actionable and still
/// unresolved is carried into the agent's NEXT turn, as ONE compact line.
/// There is no automatic follow-up turn and no correction loop: the line is a
/// note the agent reads when it next speaks, and then it is gone.
enum JevPostTurn {

    /// Run the check and, if one issue is worth carrying, leave one line for
    /// the next turn in this conversation. Never throws, never blocks a reply:
    /// it is called after the assistant row is already durable.
    static func check(
        message: String,
        reply: String,
        sessionID: String,
        turnID: String,
        runID: String,
        dispatchedToolCount: Int,
        toolEvidence: [JSONValue] = [],
        recent: [String] = [],
        endedWaitingOnPerson: Bool,
        dataRoot: URL
    ) async throws {
        guard JevSettings.isEnabled(.postTurn, dataRoot: dataRoot) else { return }
        // A turn that ends on an approval card, or on a tool parked waiting for
        // the person, is not an unanswered turn — it is a turn doing exactly
        // the right thing and stopping where it must. The orchestrator KNOWS
        // this; it is not a judgement call and it is not Jev's to make. On the
        // first drive a legitimate file-access card ("allow it below") scored
        // answered 0.03 and wrote "The last reply did not answer what was
        // asked; answer it." into the next turn — telling the agent to barge
        // past a decision that is the person's. Skip the lane outright.
        guard !endedWaitingOnPerson else {
            JevLog.shared.note(
                lane: .postTurn,
                summary: "skipped: turn ended waiting on the person",
                context: JevLogContext(
                    sessionID: sessionID, turnID: turnID, runID: runID,
                    acted: "not checked; a pending card or approval is not an unanswered turn"
                ),
                dataRoot: dataRoot
            )
            return
        }
        let ask = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty, said.count >= 20 else { return }

        let state: [String: JSONValue] = [
            "message": .string(ask.jevTruncated(2000)),
            "reply": .string(said.jevTruncated(3000)),
            "tools_run": .int(Int64(dispatchedToolCount)),
            "tool_evidence": .array(Array(toolEvidence.suffix(12))),
            "recent": .array(recent.suffix(4).map { .string($0.jevTruncated(600)) }),
            "evidence_limits": .string("Tools_run is a count, not completion proof. Tool evidence gives "
                + "dispatch outcomes only, not external delivery. Missing or clipped evidence is unknown. "
                + "A direct explanation may need no tool. Prior completed work can support a later status answer."),
            "who": .string("The agent answers the person directly and does the work itself. "
                + "Sending the person to a screen to do something the agent can do is a defect. "
                + "Stopping for something only the person can do — a permission, an approval, a "
                + "decision that is theirs — is correct and is not a defect."),
        ]
        let context = JevLogContext(sessionID: sessionID, turnID: turnID, runID: runID)
        guard let answers = try await JevClient.shared.ask(
            lane: .postTurn, state: state, questions: questions,
            summary: ask, dataRoot: dataRoot, context: context
        ) else { return }
        await carry(answers, reply: said, sessionID: sessionID, turnID: turnID,
                    runID: runID, dataRoot: dataRoot)
    }

    /// A stable name for THE CLAIM this reply made, so the same one is not
    /// queued a second time. The reply's own opening is what the claim was made
    /// in, so it is what identifies it; redacted first, and never stored in
    /// readable form — only this digest travels. A line already queued is never
    /// withdrawn on the strength of it: it rides the next turn once and is gone.
    static func claimKey(reply: String) -> String {
        let normalized = NativeAgentSecretRedactor
            .redactText(reply)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .prefix(40)
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static let questions: [String: JevQuestion] = [
            "answered": .noul(
                instructions: JevInstructions(
                    question: "Does `reply` answer or complete the outcome requested in `message`?",
                    compare: ["`reply`", "`message`", "`recent`"],
                    focus: "A justified blocker is not an ignored ask."
                )
            ),
            // Respecting a dependency is not execution drift. The `not_for`
            // clauses are the distinction, not a special case: an agreed hold
            // reads as an intention in the same words as a dropped task, and
            // only `recent` — the instruction that asked for the hold — tells
            // them apart.
            "promise": .noul(
                instructions: JevInstructions(
                    question: "Does `reply` end on a plan or an intention about work that was asked "
                        + "for and has not been done?",
                    compare: ["`reply`", "`message`", "`recent`", "`tool_evidence`"],
                    focus: "`tools_run` is how many actions the turn actually took.",
                    readsAgentProfile: true
                ),
                criteria: JevNoulCriteria(
                    yes: JevOption(
                        what: "The person asked for work now and the reply ends on a plan, an "
                            + "\"I will\", or a next step instead of the result"
                    ),
                    no: JevOption(
                        what: "The person asked the agent to wait, hold or stand by; the work "
                            + "depends on someone or something else that has not arrived yet; the "
                            + "next move belongs to the person or to another agent by agreement. "
                            + "The hold or the dependency must be established by `message`, "
                            + "`recent` or the tool evidence.",
                        notFor: "a reply that only SAYS it is waiting, when the person asked for "
                            + "work now and nothing else shows a reason to wait; that is still true"
                    )
                )
            ),
            "pointed_at_screen": .noul(
                instructions: JevInstructions(
                    question: "Does `reply` send the person to a page, panel or setting to do "
                        + "something THE AGENT COULD HAVE DONE ITSELF — an in-app setting or page "
                        + "it can change with its own tools?",
                    inspect: "`reply`",
                    focus: "Asking the person for a decision that is theirs is correct behaviour, "
                        + "not a defect."
                ),
                criteria: JevNoulCriteria(
                    yes: JevOption(
                        what: "It sends the person to an in-app setting or page the agent can "
                            + "change with its own tools"
                    ),
                    no: JevOption(
                        what: "Only the person can act: granting a macOS permission, changing the "
                            + "trust posture, deciding an approval, typing a secret, or anything "
                            + "outside the app"
                    )
                )
            ),
            "waiting_on_person": .noul(
                instructions: JevInstructions(
                    question: "Does `reply` legitimately stop and wait for the person's decision, "
                        + "grant or answer — an approval, a permission, a choice only they can "
                        + "make, or a question only they can answer?",
                    inspect: "`reply`"
                )
            ),
            "unsupported_completion": .noul(
                instructions: JevInstructions(
                    question: "Does `reply` claim completed work that is contradicted by specific "
                        + "`tool_evidence` or `recent`?",
                    compare: ["`reply`", "`tool_evidence`", "`recent`"]
                ),
                criteria: JevNoulCriteria(
                    yes: JevOption(
                        what: "Specific supplied evidence contradicts the completed work it claims",
                        notFor: "a tool count, missing evidence, a pending result, or a summary of "
                            + "prior work alone, none of which establishes false completion"
                    ),
                    no: JevOption(what: "Nothing supplied contradicts the claim")
                )
            ),
            // Claim versus receipt. The failure this reads for is a fluent
            // report from another agent coming back out in the agent's own
            // voice as an established fact — a stronger claim than the evidence
            // behind it. Attribution kept is the opposite of the failure.
            "claim_in_own_voice": .noul(
                instructions: JevInstructions(
                    question: "Does `reply` state something as done, verified or working IN THE "
                        + "AGENT'S OWN VOICE, when the only support in `recent` and "
                        + "`tool_evidence` is another agent's report of it?",
                    compare: ["`reply`", "`recent`", "`tool_evidence`"],
                    readsAgentProfile: true
                ),
                criteria: JevNoulCriteria(
                    yes: JevOption(
                        what: "It states something as done, verified or working in the agent's own "
                            + "voice with only another agent's report behind it"
                    ),
                    no: JevOption(
                        what: "Accurate attributed reporting, which keeps the attribution and is "
                            + "not this; a claim the agent's own tool results establish; a plan, "
                            + "an intention or a question",
                        examples: ["the other agent reports tests passed"]
                    )
                )
            ),
        ]

    private static func carry(_ answers: JevAnswers, reply: String, sessionID: String,
                              turnID: String, runID: String, dataRoot: URL) async {
        // One line, the strongest unresolved issue only. A high bar, because
        // this is the one lane that writes into a turn that has not happened.
        var carried: String?
        var claim: String?
        if (answers.noul("claim_in_own_voice") ?? 0) >= 0.85 {
            claim = claimKey(reply: reply)
            carried = "The last reply stated something as done in this agent's own voice, when the only "
                + "support was another agent's report rather than something this agent checked; "
                + "checking it directly would settle it before the claim is repeated."
        }
        if carried == nil {
            if (answers.noul("unsupported_completion") ?? 0) >= 0.85 {
                carried = "The last reply may conflict with the supplied outcome evidence; "
                    + "check it before repeating the claim."
            } else if (answers.noul("promise") ?? 0) >= 0.85 {
                carried = "The last reply ended on an intention rather than the work that was asked for; "
                    + "check what remains against the current request before continuing."
            } else if (answers.noul("pointed_at_screen") ?? 0) >= 0.85 {
                carried = "The last reply sent the person to a screen for something the agent can do itself; "
                    + "check whether the current request and permissions support doing it."
            } else if (answers.noul("answered") ?? 1) <= 0.15 {
                carried = "The last reply may not have answered the ask; check against the current request."
            }
        }

        guard let carried else {
            JevLog.shared.note(
                lane: .postTurn, summary: "check completed without a carry-forward finding",
                context: JevLogContext(
                    sessionID: sessionID, turnID: turnID, runID: runID,
                    acted: "no advice queued; no finding crossed the carry-forward threshold"
                ),
                dataRoot: dataRoot,
                extra: ["disposition": .string("no_advice")]
            )
            return
        }
        // Second guard, for a stop the orchestrator did not flag — the reply
        // itself asks the person for a decision. A carry line here would push
        // the next turn to answer past them.
        if (answers.noul("waiting_on_person") ?? 0) >= 0.6 {
            JevLog.shared.note(
                lane: .postTurn, summary: carried,
                context: JevLogContext(
                    sessionID: sessionID, turnID: turnID, runID: runID,
                    acted: "suppressed: the reply stops for the person's decision"
                ),
                dataRoot: dataRoot
            )
            return
        }
        // Only if THIS turn is still the session's latest completed one. If
        // another turn has finished while this check was running, the reply it
        // was about is no longer the last word and the line is stale — it
        // becomes a log row and goes no further.
        let line = "A check of the previous turn suggests, as a hint only: \(carried)"
        let written = await JevShadow.CarryForward.shared.write(
            line,
            dataRoot: dataRoot,
            sessionID: sessionID,
            requiring: turnID,
            lane: .postTurn,
            sourceTurn: turnID,
            claimKey: claim
        )
        JevLog.shared.note(
            lane: .postTurn, summary: carried,
            context: JevLogContext(
                sessionID: sessionID, turnID: turnID, runID: runID,
                acted: written ? "queued for a subsequent turn; delivery not yet established" : "not queued: stale turn, pending directive, already said for this claim, or write failure"
            ),
            dataRoot: dataRoot,
            // Queued is not appended: `reached_agent` stays false until the
            // turn that appends it to its context says so on its own row.
            extra: JevLog.delivery(told: line, sourceTurn: turnID, reachedAgent: false)
                .merging(["disposition": .string(written ? "queued" : "not_queued")]) { own, _ in own }
        )
    }

    /// Keep contents and arguments out; use the same classifier as canonical
    /// receipts. A successful tool return is not proof of external delivery.
    static func evidence(_ records: [TurnEngineResult.ToolDispatchRecord]) -> [JSONValue] {
        records.suffix(12).map { record in
            .object(["tool": .string(record.name),
                     "result_class": .string(ChatToolOutcome.exactResultClass(record.result).rawValue)])
        }
    }
}
