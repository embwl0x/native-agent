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
            if lastStudioEncounterOutcome != StudioEncounterDecision.Outcome.belowPressure.rawValue {
                lastStudioEncounterOutcome = StudioEncounterDecision.Outcome.belowPressure.rawValue
                persistStudioEncounterState()
            }
            return
        }
        let at = now()
        if let last = lastStudioEncounterAt,
           at.timeIntervalSince(last) < Self.studioEncounterMinimumInterval {
            return
        }
        lastStudioEncounterAt = at
        persistStudioEncounterState()
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
    private func noteQuietStudioEncounterOutcome(
        _ outcome: StudioEncounterDecision.Outcome,
        extras: [String: JSONValue] = [:]
    ) {
        guard lastStudioEncounterOutcome != outcome.rawValue else { return }
        lastStudioEncounterOutcome = outcome.rawValue
        persistStudioEncounterState()
        let kind: String
        switch outcome {
        case .noIntake: kind = "studio.encounter_no_intake"
        case .dreamOutranks: kind = "studio.encounter_dream_outranks"
        // Neither of these says anything about her aesthetic life — one is a
        // disabled substrate, the other a resting body — so neither gets a
        // receipt of its own.
        // Neither does a budget deferral: `cognition.organism_loop_deferred`
        // already carries it, with the lane and the starvation floor.
        case .disabled, .belowPressure, .minted, .deferred: return
        }
        var payload: [String: JSONValue] = ["outcome": .string(outcome.rawValue)]
        for (key, value) in extras { payload[key] = value }
        Task { [substrate] in
            await substrate.recordReceipt(kind: kind, payload: .object(payload))
        }
    }

    // MARK: - Durable quiet-outcome ledger
    //
    // `lastStudioEncounterOutcome` / `lastStudioEncounterAt` were in-memory
    // only, so a relaunch forgot both: the change-only suppression re-fired a
    // `studio.encounter_no_intake` receipt on every launch (live: 56 of 58 of
    // them sit on a `lifecycle.restore`) and the 30-minute read throttle started
    // over. One tiny sidecar beside cognition/organism_state.json — the same
    // continuity lane, not a new store — written only when a value changes.
    private var studioEncounterStateURL: URL {
        dataRoot
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("studio_encounter_state.json")
    }

    /// Called from the organism continuity restore, which runs exactly once per
    /// launch. Unreadable or malformed → memory defaults, never a throw: this is
    /// a noise suppressor, and the worst case is the receipt it used to write.
    func restoreStudioEncounterStateIfAvailable() {
        guard let data = try? Data(contentsOf: studioEncounterStateURL),
              case .object(let obj)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return }
        if case .string(let outcome)? = obj["outcome"], !outcome.isEmpty {
            lastStudioEncounterOutcome = outcome
        }
        if case .string(let at)? = obj["at"] {
            lastStudioEncounterAt = ISO8601DateFormatter().date(from: at)
        }
    }

    /// ONE writer, in order. A detached task per state update let an older
    /// write land last, leaving the sidecar holding a superseded outcome
    /// (Astra audit 2026-09-11, finding 11). Each write now waits for the
    /// previous one, so the last value persisted is the last value set.
    private func persistStudioEncounterState() {
        var payload: [String: JSONValue] = [:]
        if let outcome = lastStudioEncounterOutcome { payload["outcome"] = .string(outcome) }
        if let at = lastStudioEncounterAt {
            payload["at"] = .string(ISO8601DateFormatter().string(from: at))
        }
        let url = studioEncounterStateURL
        let value: JSONValue = .object(payload)
        let previous = studioEncounterPersistTask
        studioEncounterPersistTask = Task.detached(priority: .utility) {
            await previous?.value
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(value) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Termination (and the proof seam) waits for the queued sidecar writes so
    /// the last state change is durable before the process exits.
    func flushStudioEncounterStateWrites() async {
        await studioEncounterPersistTask?.value
        studioEncounterPersistTask = nil
    }

    private func runStudioEncounterComposition() async {
        studioEncounterAttemptCount &+= 1

        // The same throttle every other background cognition lane respects.
        // `reflection` in the reason marks this as expensive work, so a
        // `conserve` budget defers it rather than letting it through.
        switch await backgroundCognitionGate(reason: "studio_encounter:reflection") {
        case .skipped:
            // The attempt timestamp was already advanced before this task ran.
            // Say what actually happened, so the sidecar cannot present the
            // PREVIOUS outcome under a fresh attempt time (comb 3 lane 2 item 2).
            noteQuietStudioEncounterOutcome(.deferred)
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

        let composition = await composeStudioIntake()
        let intake = composition.candidates
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
        case .noIntake:
            // An empty intake is a correct answer, but "outcome: noIntake" alone
            // cannot tell an empty studio from an unreadable one. Carry what each
            // source actually produced, the way the mint payload does.
            noteQuietStudioEncounterOutcome(
                decision.outcome,
                extras: composition.receiptFields(pressure: fresh.pressure)
            )
        case .dreamOutranks:
            noteQuietStudioEncounterOutcome(decision.outcome)
        // `.deferred` is decided by the loop-budget gate above, never by the
        // mint; it is listed so a future outcome cannot be silently dropped.
        case .disabled, .belowPressure, .deferred:
            if lastStudioEncounterOutcome != decision.outcome.rawValue {
                lastStudioEncounterOutcome = decision.outcome.rawValue
                persistStudioEncounterState()
            }
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
    private func composeStudioIntake() async -> StudioIntakeComposition {
        var composition = StudioIntakeComposition()
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        let consults = try? await store.namedEncounterIntake()
        composition.consultsReadable = consults != nil
        composition.candidates = consults ?? []
        composition.consultCandidates = composition.candidates.count
        guard let journaled = try? await store.journaledWorkIdentities() else { return composition }
        composition.journalReadable = true
        composition.journaledWorks = journaled.count
        guard let indexer = try? SwiftNativeKnowledgeGraphIndexer(
            memorySQLitePath: dataRoot
                .appendingPathComponent("memory/memory.sqlite")
                .standardizedFileURL
        ) else { return composition }
        if let graphCandidates = try? await indexer.unjournaledWorkCandidates(
            journaledWorks: journaled
        ) {
            composition.graphReadable = true
            composition.graphCandidates = graphCandidates.count
            composition.candidates.append(contentsOf: graphCandidates)
        }
        return composition
    }

    /// What each intake source produced on this pass. Counts, plus whether the
    /// source could be read at all — an unreadable store and an empty one are
    /// the same empty intake and must not read the same in the ledger.
    struct StudioIntakeComposition {
        var candidates: [StudioEncounterCandidate] = []
        var consultCandidates = 0
        var journaledWorks = 0
        var graphCandidates = 0
        var consultsReadable = false
        var journalReadable = false
        var graphReadable = false

        func receiptFields(pressure: Double) -> [String: JSONValue] {
            [
                "intake": .int(Int64(candidates.count)),
                "pressure": .double(pressure),
                "consultsUnanswered": .int(Int64(consultCandidates)),
                "worksJournaled": .int(Int64(journaledWorks)),
                "worksUnjournaled": .int(Int64(graphCandidates)),
                "consultsReadable": .bool(consultsReadable),
                "journalReadable": .bool(journalReadable),
                "graphReadable": .bool(graphReadable),
            ]
        }
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
