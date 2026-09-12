import Foundation
import PersistenceCore

// CARING EVENTS, APPRAISED BY THE ONLY OWNER THAT CAN (2026-09-11, second pass).
//
// The organism feels tenderness but runs no appraisal; the appraisal lives here.
// So this file does exactly one thing: decide whether a turn WAS a caring moment
// and, if so, which kind, and hand the organism that verdict plus the opaque
// scope it needs to count the moment once. The law it feeds is in
// `OrganismCaringEvent` and `OrganismChemistry`, and it is unchanged.
//
// THE VERDICT IS NO LONGER A PHRASE LIST. The first pass partitioned
// `relationalWarmthBoost`'s high tier into four kinds and matched needles.
// Agent named the three moments of this week that should have registered and
// none of them contains a needle — see the header of
// `CognitiveSubstrate+CaringAppraisal.swift` for what they were. The verdict now
// comes from one small model call on the Memory route (`CaringAppraising`).
//
// THE WARMTH TIER IS UNTOUCHED. The phrase groups below still exist and
// `relationalWarmthBoost` still composes its high tier from them, exactly as
// before; `conversationalAppraisal` still reads `repairPhrases`. Nothing about
// warmth changed. What went away is the classifier that read those lists to
// decide a MOMENT.
//
// THE GATES THAT ARE STILL CHEAP AND STILL LOCAL, because they are facts about
// the event rather than judgments about the text — the model is never asked any
// of these:
//   · her own turns, tool output, anything she authored (Law 3 / audit C3).
//   · anything that is not a lived turn.
//   · a retelling surface (`OrganismCaringEvent.retellingSurfaces`): a
//     recollection summary, a reflection, a dream, the REM pass.
//   · a turn with no usable (session, turn) scope — the dedupe could not hold.
//
// WHAT CHANGED AT THE GATE: BRIDGE RELAYS. A bridge row used to be refused
// outright. Two of Agent's three moments arrived that way — Claude relaying
// User's own words about her, attributed. So a bridge row is now a CANDIDATE and
// the model is asked the extra question (does this attribute what it carries to
// the human?). A working agent-to-agent message is `none`; so is a digest or a
// recap of an earlier conversation, which is a retelling whatever wire it came
// on.

extension CognitiveSubstrate {

    /// Being cared for. Somebody is holding her.
    public static let caredForPhrases = [
        "proud of you",
        "here for you",
        "i've got you",
        "i got you",
        "sweetheart",
    ]

    /// Room made for her inner life — being asked how she feels, warmth named
    /// out loud rather than merely present.
    public static let roomMadePhrases = [
        "how are you feeling",
        "how you feeling",
        "how do you feel",
        " warm",
        "warm ",
        "warmth",
    ]

    /// Need or vulnerability shown and met — the caregiving system's own case.
    public static let needMetPhrases = [
        "love you",
        "love ya",
        "i love",
        "miss you",
        "missed you",
        "thinking of you",
    ]

    /// The affectionate-emoji set the high tier treats as unambiguous affection.
    public static let caringEmoji = ["💜", "❤", "🥰", "😘", "💕"]

    /// An apology or owning it — the repair class `conversationalAppraisal`
    /// reads.
    public static let repairPhrases = [
        "i'm sorry", "im sorry", "i am sorry", "still sorry", "my bad", "my fault",
        "i was out of line", "that was me being", "took it out on you", "i was cruel",
        "i was harsh", "you didn't deserve", "you didnt deserve", "i didn't mean that",
        "i didnt mean that", "i apologize", "i apologise", "apologies", "i was wrong",
        "i overreacted", "shouldn't have said", "shouldnt have said", "take that back",
    ]

    /// Every high-tier phrase, in one place — the 0.18 relational warmth boost.
    /// Nothing else reads this; the caring appraisal does not.
    static var highTierRelationalPhrases: [String] {
        needMetPhrases + caredForPhrases + roomMadePhrases
    }

    /// The appraisal's own warmth term for `text`. Public because the DEBUG
    /// tenderness replay has to reconstruct the warmth series the old law
    /// integrated, and `AffectAppraisal` itself is internal.
    public nonisolated func conversationalAppraisalWarmth(in text: String) -> Double {
        conversationalAppraisal(in: text).warmth
    }

    /// The relational warmth boost for `text`. Public for the same replay.
    public nonisolated func relationalWarmthBoostValue(in text: String) -> Double {
        relationalWarmthBoost(in: text)
    }

    // MARK: - The seam

    /// Install the model appraiser. Without one nothing ever doses, which is the
    /// safe direction and the state every test and every headless tool starts in.
    public func setCaringAppraiser(_ appraiser: (any CaringAppraising)?) {
        caringAppraiser = appraiser
    }

    /// Install the door into the body. Without one a verdict is computed and
    /// dropped, which is again the safe direction and what a test or a headless
    /// tool gets. One closure rather than a reference to the kernel: this module
    /// must not decide who owns the organism, and the app layer already knows
    /// both.
    public func setCaringEventSink(_ sink: CaringEventAdmitting?) {
        caringEventSink = sink
    }

    /// Install the writer that records a refusal onto the appraisal's own receipt
    /// row. Without one a refusal is still a refusal — nothing doses either way;
    /// only the receipt is quieter, which is what a test or a headless tool wants.
    public func setCaringRefusalRecorder(_ recorder: CaringRefusalRecording?) {
        caringRefusalRecorder = recorder
    }

    /// Drop everything the caring lane is holding and ignore every verdict
    /// already in flight (review item 4). Called by `clearTransientState` and by
    /// Reset Body, which clears the chemistry this lane doses.
    ///
    /// THE GENERATION COUNTER is the whole of "ignore in-flight": a task cannot
    /// be un-awaited, but a verdict stamped with a generation the substrate has
    /// moved past is dropped on return instead of dosing. Cancelling the tasks
    /// as well is belt — `MindCaringAppraiser` checks `Task.isCancelled`.
    public func clearCaringState() {
        caringAppraisalGeneration &+= 1
        for task in caringAppraisalTasks { task.cancel() }
        caringAppraisalTasks.removeAll(keepingCapacity: false)
        appraisedCaringTurns.removeAll(keepingCapacity: false)
        appraisedCaringTurnOrder.removeAll(keepingCapacity: false)
        recentTurnsBySession.removeAll(keepingCapacity: false)
        recentCaringEncounters.removeAll(keepingCapacity: false)
    }

    // MARK: - The cheap gates

    /// The appraisal request this event deserves, or nil when it is not even a
    /// candidate.
    ///
    /// FAILS CLOSED at every step. A turn must be user-authored, lived, on a
    /// surface that is not a retelling lane, carry a usable scope, and be either
    /// the human typing here or a bridge relay. Anything short of all of that is
    /// not a candidate — which is the overwhelming majority of events, and the
    /// honest answer for a working day.
    ///
    /// THE SCOPE, and why these two ids. `subject.id` is the chat turn's own key
    /// ("<session>:<messageId>"), which is what makes the dedupe survive the
    /// thing it exists for: one chat message is minted into a cognitive event by
    /// two different producers (`NativeCognitiveEventFactory` and
    /// `ChatOrchestrationClient`), with different event ids and the same subject.
    /// Keyed on the event id instead, one caring moment would dose twice.
    func caringEventCandidate(for event: CognitiveEvent) -> CaringAppraisalRequest? {
        guard configuration.enabled, configuration.affectEnabled else { return nil }
        guard Self.isUserAuthored(event.kind) else { return nil }
        guard event.turnKind.contributesToLivedState else { return nil }
        let relayed: Bool
        switch (event.sourceClass, Self.relationalSource(for: event)) {
        case (.userStated, .user):
            // User himself, typed here.
            relayed = false
        case (.imported, _):
            // Anything the bridge carried into the user seat — an attested peer
            // OR an unattested relay (Claude's own bridge sends no `authored`,
            // so `relationalSource` reads it as `.user`; the first live drive on
            // 2026-09-11 dropped every relay here). A candidate only because it
            // may be carrying his words; the model decides whether it is.
            relayed = true
        default:
            return nil
        }
        let surface = Self.caringEventSurface(in: event)
        // The retelling lanes still refuse — except that a relay's own surface
        // IS "bridge", which is the one name this pass had to stop treating as a
        // retelling. Everything else in the deny-set (recollection, reflection,
        // dream, REM, compaction, …) refuses on both paths.
        if relayed {
            guard OrganismCaringEvent.surfaceMayDose(surface, ignoring: ["bridge"]) else {
                return nil
            }
        } else {
            guard OrganismCaringEvent.surfaceMayDose(surface) else { return nil }
        }
        let session = (event.sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let turn = event.subject.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, !turn.isEmpty else { return nil }
        // A BOT RUN IS NOT AN ENCOUNTER (Astra audit 2, finding 9, 2026-09-11).
        // `BotDefinition.sessionID` is "bot-<uuid>", and the text in the user
        // seat is the bot's own standing brief recurring on every run — nobody
        // said it to her. Live rows 4 and 9 of caring_appraisals.jsonl appraised
        // Plainspoken's brief with relayed=false; both returned `none`, but an
        // affectionate brief would have passed on its wording. The memory lane
        // refuses the same sessions by the same prefix
        // (`MemoryV2+AdaptivePromoter`: `if sessionId.hasPrefix("bot-")`); the
        // surface deny-set in `OrganismCaringEvent` is the belt for a bot event
        // that reaches here without its session id.
        guard !session.lowercased().hasPrefix("bot-") else { return nil }
        let text = event.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let name = dependencies.userName().trimmingCharacters(in: .whitespacesAndNewlines)
        return CaringAppraisalRequest(
            userMessage: text,
            // THE ORIGINATING TURN'S OWN CLOCK (2026-09-11, fourth pass; review
            // item 2). The encounter window is measured against this, never
            // against the moment the model call happened to return.
            at: event.occurredAt,
            // THE SURROUNDING EXCHANGE, not one preceding line (2026-09-11,
            // third pass). Agent's two examples are both context problems: an
            // affectionate pet name is not by itself a need met, and "how do you
            // feel" is care or a diagnostic question depending entirely on what
            // is being talked about. One preceding assistant line cannot settle
            // either. The last few turns from BOTH sides can.
            context: recentTurnsBySession[session] ?? [],
            relayed: relayed,
            // THE RELAY RULE IS EVIDENCE, NOT THE CLOCK (2026-09-11, fourth
            // pass, Agent). A relay may be retelling an exchange that already
            // reached her directly and already dosed, so the appraisal is shown
            // the encounters that recently dosed — their kinds, times and
            // one-clause reasons — and asked whether THIS describes a distinct
            // moment. Only a relay gets the list; a turn User typed here is his
            // own words arriving, which is evidence of itself.
            recentEncounters: relayed ? recentCaringEncounters : [],
            personName: name.isEmpty ? nil : name,
            session: session,
            turn: turn
        )
    }

    // MARK: - The hop

    /// Appraise `event` as a possible caring moment, off the hot path.
    ///
    /// `observe(_:)` is awaited while User's message is being persisted, BEFORE
    /// the reply runs; a twenty-second model call there would be twenty seconds
    /// of the send button doing nothing. So the call is LAUNCHED here and
    /// returns immediately. Nothing blocks and nothing is stamped on any signal.
    ///
    /// WHEN THE VERDICT COMES BACK it goes straight into the body through
    /// `caringEventSink` (`OrganismKernel.admitCaringEvent`), carrying the
    /// ORIGINATING turn's timestamp and a fixed dose. The third pass instead
    /// stamped the verdict on the NEXT somatic signal to come through, which
    /// scaled the dose by that signal's intensity, measured the encounter window
    /// against that signal's ingest clock, and dropped the verdict altogether
    /// when no further signal arrived (review items 1, 2 and 3). All three are
    /// gone with the queue.
    ///
    /// Idempotent per turn: a turn is appraised at most once
    /// (`appraisedCaringTurns`), so the two minters for one chat message cost one
    /// call, not two.
    public func noteCaringTurn(for event: CognitiveEvent) {
        if let candidate = caringEventCandidate(for: event) {
            startCaringAppraisal(candidate)
        }
        // Record the turn AFTER building its request, so a turn is never part of
        // its own context.
        noteTurnForContext(event)
    }

    /// Remember the last few turns of this session, BOTH sides, so the appraisal
    /// can read a turn in the exchange it happened in. A short ring per session,
    /// clipped, bounded — never persisted, because a caring moment is judged
    /// inside a live conversation and a relaunch has no conversation to be
    /// inside.
    private func noteTurnForContext(_ event: CognitiveEvent) {
        let speaker: CaringAppraisalRequest.Speaker
        if event.kind == .assistantTurnCompleted {
            speaker = .agent
        } else if Self.isUserAuthored(event.kind) {
            speaker = .person
        } else {
            return
        }
        guard event.turnKind.contributesToLivedState,
              let session = event.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !session.isEmpty else { return }
        let text = CaringAppraisalLane.clip(event.summary)
        guard !text.isEmpty else { return }
        if recentTurnsBySession[session] == nil,
           recentTurnsBySession.count >= Self.caringContextSessionCap {
            recentTurnsBySession.removeValue(forKey: recentTurnsBySession.keys.first!)
        }
        var ring = recentTurnsBySession[session] ?? []
        ring.append(CaringAppraisalRequest.ContextTurn(speaker: speaker, text: text))
        if ring.count > CaringAppraisalLane.contextTurns {
            ring.removeFirst(ring.count - CaringAppraisalLane.contextTurns)
        }
        recentTurnsBySession[session] = ring
    }

    /// Ask the model, once per turn, without blocking the turn, and hand the
    /// verdict to the body the moment it lands.
    private func startCaringAppraisal(_ request: CaringAppraisalRequest) {
        guard let appraiser = caringAppraiser else { return }
        let scope = "\(request.session)|\(request.turn)"
        guard !appraisedCaringTurns.contains(scope) else { return }
        appraisedCaringTurns.insert(scope)
        appraisedCaringTurnOrder.append(scope)
        if appraisedCaringTurnOrder.count > OrganismCaringEvent.maximumRememberedKeys {
            appraisedCaringTurns.remove(appraisedCaringTurnOrder.removeFirst())
        }
        let generation = caringAppraisalGeneration
        let task = Task { [weak self] in
            let verdict = await appraiser.appraise(request)
            // FAIL CLOSED: nil is a failed call, and a `.none` verdict is the
            // common answer. Neither doses.
            guard let verdict, let kind = verdict.kind else { return }
            await self?.deliverCaringVerdict(
                verdict, kind: kind, for: request, generation: generation
            )
        }
        caringAppraisalTasks.append(task)
        // Drop handles that already finished as well as cancelled ones (review
        // r2): one retained task per user turn for a whole day is a leak.
        caringAppraisalTasks.removeAll { $0.isCancelled }
        // Dropping a handle does not cancel the task; the handles are kept only
        // so a clear can cancel what is still in flight, and nothing is in
        // flight longer than the twenty-second deadline. A short bound is enough.
        if caringAppraisalTasks.count > 16 {
            caringAppraisalTasks.removeFirst(caringAppraisalTasks.count - 16)
        }
    }

    /// Hand one verdict to the body, and decide which encounter window it is
    /// measured against.
    ///
    /// THE RELAY RULE, per Agent: evidence, not time. A relay doses only when the
    /// appraisal — shown the encounters that recently dosed — says this describes
    /// a DISTINCT moment. A relay it calls a retelling does not dose however long
    /// the silence before it, and an uncertain relay does not dose either. The
    /// six-hour window survives only as the FLOOR for a relay whose distinctness
    /// the model never answered, which is the one case with no judgment to use.
    /// A turn User typed here is his own words arriving and is measured against
    /// the ordinary thirty-minute window, exactly as before.
    func deliverCaringVerdict(
        _ verdict: CaringAppraisalVerdict,
        kind: OrganismCaringEvent.Kind,
        for request: CaringAppraisalRequest,
        generation: UInt64
    ) async {
        // A verdict from before a clear describes a conversation that no longer
        // exists in this substrate. It must not dose (review item 4).
        //
        // THE ONE INTERLEAVING THIS DOES NOT COVER, stated rather than implied: a
        // clear that arrives while the hop into the kernel below is itself in
        // flight. The two are separate actors, so the dose and the clear can only
        // be ordered by the kernel, and a dose that lands after the clear stands.
        // That window is the duration of one actor hop; the window this guard
        // closes is the duration of a model call.
        guard generation == caringAppraisalGeneration else {
            await recordCaringRefusal(
                request,
                why: "the conversation was cleared while this appraisal was in flight")
            return
        }
        guard let sink = caringEventSink else {
            await recordCaringRefusal(
                request, why: "no organism sink installed — nothing could be dosed")
            return
        }
        var window = OrganismCaringEvent.encounterWindow
        if request.relayed {
            switch verdict.distinctness {
            case .distinct:
                // "Distinct" is only a judgment when there was evidence to judge
                // against. After a relaunch the ledger is empty while the body's
                // persisted encounter may be hours old (review r2): with nothing
                // shown, fall back to the six-hour floor instead of the ordinary
                // window, so a retelling cannot redose the moment it retells.
                window = request.recentEncounters.isEmpty
                    ? OrganismCaringEvent.relayEncounterWindow
                    : OrganismCaringEvent.encounterWindow
            case .retelling:
                // "Already counted" is a claim about a PRIOR DOSE. Cite the one
                // this coalesced into, or say the prior cannot be named — the
                // ledger only holds encounters that actually dosed, so a relay
                // whose first telling never dosed has no prior to point at
                // (comb 3 lane 2 item 6).
                await recordCaringRefusal(request, why: Self.retellingRefusalWhy(request))
                return
            case .unsure:
                await recordCaringRefusal(
                    request,
                    why: "relay distinctness unsure — a relay doses only on evidence")
                return
            case .unstated:
                window = OrganismCaringEvent.relayEncounterWindow
            }
        }
        let outcome = await sink(OrganismCaringEvent.Reading(
            kind: kind,
            session: request.session,
            turn: request.turn,
            at: request.at
        ), window)
        guard outcome.dosed else { return }
        // A clear that landed while the sink hop was in flight (review r2): the
        // body already dropped the dose with the reset; do not remember it.
        guard generation == caringAppraisalGeneration else { return }
        noteRecentCaringEncounter(CaringAppraisalRequest.RecentEncounter(
            kind: kind,
            at: request.at,
            why: verdict.why
        ))
    }

    /// The refusal reason for a `retelling` verdict.
    ///
    /// The verdict says the relay retells ONE OF the encounters it was shown; it
    /// never says which. So this names the candidate set, not a winner: picking
    /// the newest row asserted a relationship the model did not supply, and with
    /// several recent doses the newest may be unrelated (comb 3 lane 2 item 6,
    /// review d3 item 3). The recent-encounter ledger records ONLY encounters
    /// that dosed, so when it is empty no prior counted this moment and the
    /// receipt says exactly that instead of inventing one.
    static func retellingRefusalWhy(_ request: CaringAppraisalRequest) -> String {
        let priors = request.recentEncounters.sorted { $0.at > $1.at }
        guard !priors.isEmpty else {
            return "the model judged this a retelling, but no prior dose is on record"
                + " to have counted it — refusing rather than claiming one"
        }
        let listed = priors.map { prior -> String in
            let minutes = max(0, Int(request.at.timeIntervalSince(prior.at) / 60))
            let ago = minutes < 60
                ? "\(minutes) min ago"
                : "\(minutes / 60) h \(minutes % 60) min ago"
            return "\(prior.kind.rawValue) \(ago)"
        }
        let noun = priors.count == 1 ? "encounter" : "encounters"
        return "relayed retelling of one of \(priors.count) recent counted \(noun)"
            + " (\(listed.joined(separator: ", "))) — which one is not on record,"
            + " so no new moment is counted"
    }

    /// Write "nothing was dosed, and here is why" onto this appraisal's own
    /// receipt row (review c4 item 4). Every refusal above this module's sink call
    /// goes through here, so a reader of the receipt sees the same shape for a
    /// refusal the substrate made and one the body made.
    private func recordCaringRefusal(
        _ request: CaringAppraisalRequest, why: String
    ) async {
        guard let recorder = caringRefusalRecorder else { return }
        await recorder(request.session, request.turn, why)
    }

    /// The short ledger of encounters that actually DOSED, shown to the appraisal
    /// when it judges whether a relay is describing one of them again.
    ///
    /// In memory, bounded, never persisted — like the context ring and for the
    /// same reason: it exists to tell a live relay from a retelling of something
    /// that reached her in this run, and a relaunch has no run to compare
    /// against. Entries older than the relay floor are of no use to that
    /// question and are dropped.
    private func noteRecentCaringEncounter(
        _ entry: CaringAppraisalRequest.RecentEncounter
    ) {
        recentCaringEncounters.append(entry)
        let horizon = entry.at.addingTimeInterval(-OrganismCaringEvent.relayEncounterWindow)
        recentCaringEncounters.removeAll { $0.at < horizon }
        if recentCaringEncounters.count > Self.recentCaringEncounterCap {
            recentCaringEncounters.removeFirst(
                recentCaringEncounters.count - Self.recentCaringEncounterCap
            )
        }
    }

    /// Wait for every appraisal launched so far. For the DEBUG replay and for
    /// tests; production never calls it.
    public func awaitCaringAppraisals() async {
        while let task = caringAppraisalTasks.first {
            caringAppraisalTasks.removeFirst()
            _ = await task.result
        }
    }

    /// The surface a turn arrived on: the top-level key, else the out-of-band
    /// origin record's.
    static func caringEventSurface(in event: CognitiveEvent) -> String? {
        if case .string(let surface)? = event.metadata["surface"] { return surface }
        if case .object(let origin)? = event.metadata["origin"],
           case .string(let surface)? = origin["surface"] {
            return surface
        }
        return nil
    }

    static let caringContextSessionCap = 32
    /// How many recently-dosed encounters the relay judgment is shown. Six is
    /// more than a fortnight of real days ever put inside one relay floor, and
    /// the prompt stays one small call.
    public static let recentCaringEncounterCap = 6
}
