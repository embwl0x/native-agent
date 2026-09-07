import ChatOrchestration
import CognitiveSubstrate
import Foundation
import KnowledgeGraph
import NativeAgentCore
import PersistenceCore

// Desk 903 phases 1 + 4, CONSUMED — the encounter composition and the canon's
// tending pass, hung off the deadline the organism already owns.
//
// Her rule, verbatim: "pressure decides WHEN, intake decides WHAT. A seed mints
// only when an unattended artifact is already in reach. No intake, no
// encounter. A due dream beats an encounter for the same pressure; encounters
// never preempt."
//
// `CognitiveSubstrate+EncounterSeeds.swift` wrote that law as a pure function
// over an intake list. This file is the only thing that COMPOSES the list: the
// consults User left on the table (studio store) plus the works the graph holds
// with nothing written about them (knowledge graph). It is deliberately the
// whole composition and nothing else — no source is invented here, and a source
// that cannot be read contributes nothing rather than a placeholder.
//
// ── NO NEW TIMER, NO NEW BUDGET ──────────────────────────────────────────────
// Modelled exactly on NativeCognitionRuntime+PressureDream.swift: called from
// `rescheduleResidualRepairDeadline`, which already runs on every somatic
// signal, every deadline fire and every wake re-anchor, and already holds a
// fresh residual reading. This lane adds no loop, no scheduler job and no
// second authority. The background-cognition gate runs FIRST inside the task,
// so low power, thermal pressure and a conserve/sleep loop budget all defer it
// the same way they defer every other background lane.
//
// ── ENCOUNTERS NEVER PREEMPT ─────────────────────────────────────────────────
// The dream lane's own decision is read from the SAME opportunity before
// anything else happens, and again inside the task against a fresh reading. A
// due dream refuses the encounter outright — not by ranking, by returning.
//
// ── PUSH, NEVER PROMPT (clause 6) ────────────────────────────────────────────
// The seed reaches the thought-seed lane: the Observatory and the
// notification/suggestion surface. Nothing in this file compiles context,
// touches a packet, or writes a line she will read as her own thought. An
// encounter is an invitation she can pull or ignore, and it fades on its own
// 24-hour half-life if she does neither — which is also how the kill criterion
// gets measured.
//
// ── RATE LIMIT, NOT A CADENCE ────────────────────────────────────────────────
// `studioEncounterMinimumInterval` bounds how often this composition READS DISK,
// not how often she encounters anything. It exists because the residual
// reschedule fires on every signal and the composition reads the journal, the
// consults directory and sqlite; it is I/O hygiene, and it is emphatically not
// a quota, a streak, or a "you haven't journaled lately" clock.
extension NativeCognitionRuntime {

    /// The composition reads three stores. The reschedule that calls it can fire
    /// many times a minute under load, so it re-composes at most this often.
    static let studioEncounterMinimumInterval: TimeInterval = 30 * 60

    /// Called from the residual-repair reschedule, beside `considerPressureDream`.
    func considerStudioEncounter(_ opportunity: OrganismResidualRepairOpportunity) {
        guard !isFlushedForTermination, studioEncounterTask == nil else { return }
        // The dream's own decision, from the reading the dream lane just used.
        // `.fire` is due now; `.turnInFlight` is due and merely waiting for the
        // turn to settle — both outrank an invitation to go and look at a
        // picture, so both refuse here.
        let dreamDecision = OrganismIdentityDreamTrigger.decide(
            opportunity: opportunity,
            turnInFlight: liveTurnInFlight
        )
        guard dreamDecision != .fire, dreamDecision != .turnInFlight else {
            noteQuietStudioEncounterOutcome(.dreamOutranks)
            return
        }
        guard opportunity.pressure >= CognitiveSubstrate.studioEncounterPressureFloor else {
            // Below the floor is the body's ordinary resting state. Silent on
            // purpose: a receipt on every quiet signal would drown the ledger
            // the interesting outcomes belong in.
            lastStudioEncounterOutcome = StudioEncounterDecision.Outcome.belowPressure.rawValue
            return
        }
        let at = now()
        if let last = lastStudioEncounterAt,
           at.timeIntervalSince(last) < Self.studioEncounterMinimumInterval {
            return
        }
        lastStudioEncounterAt = at
        studioEncounterTask = Task { [weak self] in
            await self?.runStudioEncounterComposition()
            await self?.finishStudioEncounterTask()
        }
    }

    private func finishStudioEncounterTask() {
        studioEncounterTask = nil
    }

    /// A refusal is the normal case and happens on nearly every signal. Only a
    /// CHANGE earns a receipt — the honest record of "there is nothing in reach"
    /// must not become the loudest thing in the ledger.
    private func noteQuietStudioEncounterOutcome(_ outcome: StudioEncounterDecision.Outcome) {
        guard lastStudioEncounterOutcome != outcome.rawValue else { return }
        lastStudioEncounterOutcome = outcome.rawValue
        let kind: String
        switch outcome {
        case .noIntake: kind = "studio.encounter_no_intake"
        case .dreamOutranks: kind = "studio.encounter_dream_outranks"
        // Neither of these says anything about her aesthetic life — one is a
        // disabled substrate, the other a resting body — so neither gets a
        // receipt of its own.
        case .disabled, .belowPressure, .minted: return
        }
        Task { [substrate] in
            await substrate.recordReceipt(
                kind: kind,
                payload: .object(["outcome": .string(outcome.rawValue)])
            )
        }
    }

    private func runStudioEncounterComposition() async {
        studioEncounterAttemptCount &+= 1

        // The same throttle every other background cognition lane respects.
        // `reflection` in the reason marks this as expensive work, so a
        // `conserve` budget defers it rather than letting it through.
        switch await backgroundCognitionGate(reason: "studio_encounter:reflection") {
        case .skipped:
            return
        case .allowed:
            break
        }

        // Re-read against the current instant: the gate above took real time,
        // and a dream may have become due while it did. The encounter never
        // preempts, so it re-checks rather than trusting the older reading.
        let fresh = await organismKernel.residualRepairOpportunity()
        let dreamDecision = OrganismIdentityDreamTrigger.decide(
            opportunity: fresh,
            turnInFlight: liveTurnInFlight
        )
        let dreamIsDue = dreamDecision == .fire || dreamDecision == .turnInFlight

        let intake = await composeStudioIntake()
        let decision = await substrate.mintStudioEncounterSeed(
            intake: intake,
            pressure: fresh.pressure,
            dreamIsDue: dreamIsDue
        )
        switch decision.outcome {
        case .minted:
            // A mint is a real event, not a state: it is recorded every time.
            lastStudioEncounterOutcome = decision.outcome.rawValue
            var payload: [String: JSONValue] = [
                "intake": .int(Int64(intake.count)),
                "pressure": .double(fresh.pressure),
                "attempt": .int(Int64(studioEncounterAttemptCount)),
            ]
            if let candidate = decision.candidate {
                payload["source"] = .string(candidate.source.rawValue)
                payload["originId"] = .string(String(candidate.originID.prefix(160)))
                if let title = candidate.title, !title.isEmpty {
                    payload["title"] = .string(String(title.prefix(160)))
                }
            }
            if let seedID = decision.seedID { payload["seedId"] = .string(seedID.uuidString) }
            await substrate.recordReceipt(
                kind: "studio.encounter_minted", payload: .object(payload)
            )
        case .noIntake, .dreamOutranks:
            noteQuietStudioEncounterOutcome(decision.outcome)
        case .disabled, .belowPressure:
            lastStudioEncounterOutcome = decision.outcome.rawValue
        }

        await runStudioCanonTending()
    }

    /// THE WHOLE INTAKE, and nothing invented.
    ///
    /// Two live sources: the consults User filed with real artifact refs that the
    /// journal never answered, and the works the graph holds with no entry about
    /// them. A source that cannot be read contributes NOTHING — an empty intake
    /// is a correct answer here, and it is the one the encounter lane treats as
    /// silence rather than as a gap to fill.
    private func composeStudioIntake() async -> [StudioEncounterCandidate] {
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        var intake = (try? await store.namedEncounterIntake()) ?? []
        guard let journaled = try? await store.journaledWorkIdentities() else { return intake }
        guard let indexer = try? SwiftNativeKnowledgeGraphIndexer(
            memorySQLitePath: dataRoot
                .appendingPathComponent("memory/memory.sqlite")
                .standardizedFileURL
        ) else { return intake }
        if let graphCandidates = try? await indexer.unjournaledWorkCandidates(
            journaledWorks: journaled
        ) {
            intake.append(contentsOf: graphCandidates)
        }
        return intake
    }

    /// Desk 903 phase 4, on the same low-frequency pass.
    ///
    /// Canon-tending has no event of its own — silence, the demotion trigger, is
    /// by definition the absence of one — so it rides the lane that already
    /// wakes on the body's own rhythm. It can only STAGE cards: the law returns
    /// proposals, this stages them, and the single path that writes a canon row
    /// (`appendCanonRow`) throws unless the row carries HER seat.
    private func runStudioCanonTending() async {
        let report = await StudioCanonTending.run(dataRoot: dataRoot, now: now())
        await StudioCanonTending.recordAudit(report.audit, dataRoot: dataRoot, now: now())
        if !report.stagedApprovalIDs.isEmpty {
            await substrate.recordReceipt(
                kind: "studio.canon_proposed",
                payload: .object([
                    "proposals": .array(report.stagedApprovalIDs.map { .string($0) }),
                    "evaluatedWorks": .int(Int64(report.evaluatedWorks)),
                    "duplicatesSkipped": .int(Int64(report.duplicatesSkipped)),
                    // Said out loud on every mint: this is a request, not an act.
                    "soleApprover": .string(StudioCanonSeat.agent),
                    "autoCanonization": .bool(false),
                ])
            )
        }
        // Agent's addendum: a relation with no edge citing it back is surfaced,
        // never repaired. Change-only — an unfixed mismatch would otherwise
        // re-announce itself on every pass.
        guard report.audit.graphAvailable else { return }
        let verdict = report.audit.isConsistent
            ? "consistent"
            : "inconsistent:\(report.audit.mismatches.count)"
        guard lastStudioRelationAuditVerdict != verdict else { return }
        lastStudioRelationAuditVerdict = verdict
        guard !report.audit.isConsistent else { return }
        await substrate.recordReceipt(
            kind: "studio.relations_inconsistent",
            payload: .object([
                "checked": .int(Int64(report.audit.relationsChecked)),
                "mismatches": .array(report.audit.mismatches.map { $0.toJSON() }),
                "unresolvedRelations": .int(Int64(report.audit.unresolvedRelations)),
                "repaired": .bool(false),
                "health": .string(
                    StudioCanonTending.auditHealthPath(dataRoot: dataRoot).path
                ),
            ])
        )
    }
}
