// CognitiveSubstrate+AppraisalConcerns.swift
// COGNITION STEP 1 (APPRAISAL) · D-1 — the concerns that generate her feelings
// come from HER. (2026-08-02)
//
// The measured defect (appraisal-gap-analysis-v2.md, 256 felt nodes / 4 weeks):
// `appraisalConcernLexicon()` returned a hardcoded six-entry array with fixed
// keyword lists, identical on every install, unchanged by anything she had
// lived, valued, or been corrected on. Only `relationship` was personalized (it
// spliced the configured user name). Her User-approved standing views existed and
// were read elsewhere — the appraisal layer never consulted them.
//
// The fix, in one sentence: the shipped six become the FLOOR (a fresh install
// still feels something), and every ACTIVE standing view — the only durable
// belief channel she has, and User-approved by construction — contributes a LIVED
// concern that weighs MORE than any shipped default.
//
// Invariants held: derived at READ TIME from state that already exists (no new
// persisted axis, no second store, no new sense) · pure and synchronous, so it
// stays callable inside the await-free ingest segment · bounded (a hard cap on
// lived concerns and on terms per concern) · zero active views degrades to
// byte-identical floor behaviour.

import Foundation
import PersistenceCore

extension CognitiveSubstrate {

    // MARK: - Model

    /// One thing she cares about, and the words that mean it.
    struct AppraisalConcern: Equatable {
        /// Where this concern came from — the whole point of D-1.
        enum Origin: Equatable {
            /// Shipped default. Present on a fresh install; identical for everyone.
            case floor
            /// Derived from one of HER ACTIVE standing views (User-approved).
            case lived
        }

        let name: String
        let keywords: [String]
        /// 1.0 for the shipped floor; > 1.0 for a concern she formed by living,
        /// scaled by how much evidence the view settled on.
        let weight: Double
        let origin: Origin

        init(name: String, keywords: [String], weight: Double = 1.0, origin: Origin = .floor) {
            self.name = name
            self.keywords = keywords
            self.weight = weight
            self.origin = origin
        }
    }

    // MARK: - Bounds (every add has a remove; the keyspace itself is the bound)

    /// At most this many LIVED concerns ride alongside the floor. The active
    /// standing-view cap is 5 today, so this can only bind if that cap moves.
    static let appraisalLivedConcernCap = 8
    /// Terms taken from any one view. A view is prose; six distinctive words is
    /// a concern, sixty is a search index.
    static let appraisalLivedConcernTermCap = 6
    /// Shortest word that can carry a concern. Below this everything matches.
    static let appraisalLivedConcernMinimumTermLength = 5
    /// Ceiling on how far past the floor a lived concern can weigh. She should
    /// trust what she formed more than what shipped — not infinitely more.
    static let appraisalLivedConcernMaximumWeight = 2.0

    // MARK: - The floor

    /// The shipped six. A fresh install with no standing views still feels
    /// something — this is the warm floor, not the whole of what she cares about.
    func appraisalConcernFloor() -> [AppraisalConcern] {
        let configuredUserName = userAddress.lowercased()
        let relationshipKeywords = (configuredUserName == "you" ? [] : [configuredUserName])
            + ["together", "trust", "warm", "with you"]

        return [
            AppraisalConcern(name: "relationship", keywords: relationshipKeywords),
            AppraisalConcern(name: "truth", keywords: ["honest", "verify", "accurate", "truth", "instrument"]),
            AppraisalConcern(name: "followThrough", keywords: ["finish", "follow through", "commit", "promised", "deliver"]),
            AppraisalConcern(name: "repair", keywords: ["fix", "repair", "broke", "recover", "debug"]),
            AppraisalConcern(name: "learning", keywords: ["learn", "understand", "curious", "figure out", "why"]),
            AppraisalConcern(name: "userCare", keywords: ["care", "help", "support", "there for", "look after"]),
        ]
    }

    // MARK: - The derived set (what every appraisal surface now consults)

    /// Her concern set: the floor, plus one LIVED concern per ACTIVE standing
    /// view, ordered heaviest-first and deterministic. Pure — same state, same
    /// answer; no suspension, so the ingest hot segment can call it.
    ///
    /// The relationship floor concern additionally leans on the relationship's
    /// current state: sustained social warmth makes the relationship concern
    /// weigh more, because it demonstrably matters more right now. That lean is
    /// bounded to the same ceiling as a lived concern and can never invert the
    /// order between a lived concern and a shipped one at equal evidence.
    func appraisalConcerns() -> [AppraisalConcern] {
        var out: [AppraisalConcern] = []
        let warmthLean = 1.0 + 0.4 * affect.socialWarmth.clamped01()
        for concern in appraisalConcernFloor() {
            guard !concern.keywords.isEmpty else { continue }
            out.append(AppraisalConcern(
                name: concern.name,
                keywords: concern.keywords,
                weight: concern.name == "relationship"
                    ? min(Self.appraisalLivedConcernMaximumWeight, warmthLean)
                    : 1.0,
                origin: .floor
            ))
        }
        out.append(contentsOf: livedAppraisalConcerns())
        return out
    }

    /// One concern per LEANING standing view, keyed by the view's lineage so the
    /// name is stable across a view being revised. Views with no distinctive
    /// terms contribute nothing rather than an empty concern that matches all
    /// text (the failure mode a naive term-split would ship).
    ///
    /// 2026-09-02 — the HELD tier joins this, at HALF STAKE. `.held` views are
    /// ordered strictly after every `.active` one, so when the cap bites it is
    /// always a held view that falls off, never a signed one. And a held view's
    /// LEAN — the part of its weight above the 1.0 floor — is scaled by
    /// `heldStandingViewWeightFactor`. Halving the whole weight would be wrong
    /// in a scale where 1.0 IS neutral: it would land a maxed held view exactly
    /// on the floor, i.e. no lean at all, and "she can hold a view of her own"
    /// would silently mean "and it does nothing".
    func livedAppraisalConcerns() -> [AppraisalConcern] {
        let leaning = standingViews.values
            .filter { $0.isLeaning }
            .sorted { lhs, rhs in
                // Signed views ahead of held ones, always.
                if (lhs.status == .held) != (rhs.status == .held) { return rhs.status == .held }
                // Deterministic under equal timestamps; freshest first so the
                // cap drops the stalest view, not an arbitrary one.
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        var out: [AppraisalConcern] = []
        for view in leaning {
            guard out.count < Self.appraisalLivedConcernCap else { break }
            let terms = Self.appraisalConcernTerms(in: "\(view.title) \(view.body)")
            guard !terms.isEmpty else { continue }
            // Conviction: what the view settled on. Same shape as the stance
            // read already used, lifted above the floor because she formed it.
            let conviction = min(1.0, 0.5 + 0.1 * Double(view.evidenceNodeIds.count))
            let lean = view.status == .held
                ? conviction * dynamics.heldStandingViewWeightFactor
                : conviction
            out.append(AppraisalConcern(
                name: "view:\(view.lineageId.isEmpty ? view.id.uuidString : view.lineageId)",
                keywords: terms,
                weight: min(
                    Self.appraisalLivedConcernMaximumWeight,
                    1.0 + lean
                ),
                origin: .lived
            ))
        }
        return out
    }

    /// The distinctive words in a view. Deterministic, bounded, and biased to
    /// long words: a concern must be able to MISS, so common connective prose is
    /// stripped and anything short is dropped. Longest-first then alphabetical
    /// so the same view always yields the same terms.
    static func appraisalConcernTerms(in text: String) -> [String] {
        let lowered = text.lowercased()
        var seen: Set<String> = []
        var candidates: [String] = []
        for raw in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= appraisalLivedConcernMinimumTermLength else { continue }
            guard !appraisalConcernStopWords.contains(word) else { continue }
            guard !seen.contains(word) else { continue }
            seen.insert(word)
            candidates.append(word)
        }
        candidates.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs < rhs
        }
        return Array(candidates.prefix(appraisalLivedConcernTermCap))
    }

    /// Words long enough to survive the length filter but too ordinary to mean
    /// anything. Kept deliberately small — this is a floor against noise, not an
    /// attempt at linguistics.
    static let appraisalConcernStopWords: Set<String> = [
        "about", "after", "again", "against", "along", "already", "also",
        "always", "another", "anything", "around", "because", "been", "before",
        "being", "between", "both", "cannot", "could", "doesn", "doing", "done",
        "during", "each", "either", "enough", "even", "ever", "every",
        "everything", "from", "further", "getting", "going", "have", "having",
        "here", "however", "instead", "into", "itself", "just", "keep", "like",
        "made", "make", "making", "many", "matter", "maybe", "might", "more",
        "most", "much", "must", "myself", "never", "nothing", "often", "only",
        "other", "over", "quite", "rather", "really", "same",
        "should", "since", "some", "someone", "something", "still", "such",
        "than", "that", "their", "them", "then", "there", "these", "they",
        "thing", "things", "think", "this", "those", "though", "through",
        "toward", "under", "until", "upon", "very", "want", "were",
        "what", "when", "where", "whether", "which", "while", "will", "with",
        "within", "without", "would", "your", "yours", "yourself",
    ]

    // MARK: - Matching

    /// Does `text` touch this concern? Substring match, same semantics the
    /// standing-view lens already used — kept identical so the change is in
    /// WHICH concerns exist, not in how a concern is recognised.
    static func concernMatches(_ concern: AppraisalConcern, in loweredText: String) -> Bool {
        concern.keywords.contains { loweredText.contains($0) }
    }

    /// Does `text` touch a concern SHE formed (not one that shipped)? This is the
    /// stake test D-2 leans on: a machine identifier can trip a floor keyword by
    /// accident ("tool:commit_memory" contains "commit"), but it can only trip a
    /// lived concern if one of her own approved views actually names that thing.
    func livedConcernHit(in text: String, concerns: [AppraisalConcern]? = nil) -> Bool {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return false }
        return (concerns ?? appraisalConcerns())
            .contains { $0.origin == .lived && Self.concernMatches($0, in: lower) }
    }
}

// MARK: - Item 46 (2026-09-01): the semantic prediction MINT SEAM
//
// Item 46's finding: `OrganismPredictionKind` was five plumbing paths, so
// prediction error — which is real learning (`applySatisfiedEffect` /
// `applyViolationEffect` move confidence, vigilance, urgency, strategyCaution) —
// only ever taught her about her own wiring. She never predicted an outcome or a
// person, so being wrong about the WORK taught nothing.
//
// The lane itself lives in the organism (`OrganismSemanticExpectation`). This is
// the half only the appraisal owner can supply, because only the substrate holds
// standing views and runs appraisal:
//
//   MINT   — on her own completed turn, when one of HER LIVED concerns (D-1: a
//            concern derived from a User-approved ACTIVE standing view) is at
//            stake in what she just said.
//   REACT  — on the next user turn that is genuinely a reaction to that
//            completion, the sign of `conversationalAppraisal`'s valence — the
//            same read U1 already uses to re-feel the completion.
//
// Both are OBJECTS carrying SCOPE alongside their payload: the session, and the
// completion turn the expectation is about. (Nested rather than sibling keys —
// somatic metadata is key-capped and a live chat turn already fills it.) That scope is what lets the organism resolve exactly the rows this
// reaction answers instead of every pending row in the ledger, and it is the
// provenance D-2 requires before a semantic felt resolution skips the aboutness
// gate. It is opaque ids only — no content.
//
// PURE, SYNCHRONOUS, NO LLM, NO NEW STORE, NO NEW SENSE. Every input already
// exists and is already computed on this path. Zero active standing views
// degrades to an empty dictionary — byte-identical to the behaviour before this
// existed.
//
// ORDERING CONTRACT (review fix 1). This MUST be called AFTER the substrate has
// ingested the event, which is the order the runtime wire uses:
//   · after ingesting an `assistantTurnCompleted`, `pendingCompletion` holds
//     THIS turn — that is where the mint scope comes from;
//   · after ingesting a user turn, ingest has already CONSUMED the completion
//     slot, so the reaction is read from `lastSemanticReaction`, the stash the
//     consume site leaves behind (single-use, session-scoped, same max age).
// Calling it before ingest yields nothing rather than something wrong.
//
// NOT WIRED HERE — the remaining hop. The organism is fed by
// `SomaticSignalBus.observe(event)`, and the bus reads the event's own metadata.
// The single place that hands the SAME event to both owners is
// `NativeCognitionRuntime.observe(_:)` (Sources/NativeAgentApp), which sits
// outside this change's fence. The wire is four lines there, AFTER the substrate
// ingest and BEFORE the bus:
//
//     var enriched = inherited.event
//     for (key, value) in await substrate.semanticExpectationMetadata(
//         for: inherited.event
//     ) { enriched.metadata[key] = value }
//     let somaticAccepted = await somaticSignalBus.observe(enriched) != nil
//
// Until that line exists the lane is inert (no metadata ⇒ no mint ⇒ no
// resolution), which is exactly how an unwired seam should fail.

extension CognitiveSubstrate {

    /// The metadata the somatic signal for `event` should carry so the
    /// organism's semantic prediction lane can mint and resolve. Empty for every
    /// event that carries neither — the overwhelming majority.
    ///
    /// Reads state but mutates only the single-use reaction stash (consumed
    /// here, exactly as `pendingCompletion` is consumed at ingest), so a second
    /// call for the same turn cannot double-resolve.
    public func semanticExpectationMetadata(for event: CognitiveEvent) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if event.kind == .assistantTurnCompleted,
           let concern = livedConcernLabel(in: event.summary),
           let scope = mintScope(for: event) {
            out[OrganismSemanticExpectation.mintMetadataKey] = .object([
                OrganismSemanticExpectation.concernField: .string(concern),
                OrganismSemanticExpectation.sessionField: .string(scope.sessionID),
                OrganismSemanticExpectation.turnField: .string(scope.turnID),
            ])
        }
        if let stash = consumeSemanticReaction(for: event) {
            out[OrganismSemanticExpectation.reactionMetadataKey] = .object([
                OrganismSemanticExpectation.reactionField: .string(stash.reaction),
                OrganismSemanticExpectation.sessionField: .string(stash.sessionID),
                OrganismSemanticExpectation.turnField: .string(stash.turnID),
            ])
        }
        return out
    }

    /// The heaviest LIVED concern `text` touches, by name, or nil. Same matcher
    /// and same ordering as `livedConcernHit`; this returns WHICH one so the
    /// minted expectation can say what it is about.
    func livedConcernLabel(in text: String, concerns: [AppraisalConcern]? = nil) -> String? {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return nil }
        return (concerns ?? appraisalConcerns())
            .filter { $0.origin == .lived && Self.concernMatches($0, in: lower) }
            .sorted { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                return lhs.name < rhs.name
            }
            .first?
            .name
    }

    /// Session + completion-turn identity for an expectation being minted.
    /// Taken from the `pendingCompletion` slot ingest has just OPENED for this
    /// very turn, so the mint scope and the later reaction scope are the same
    /// two strings by construction.
    func mintScope(for event: CognitiveEvent) -> (sessionID: String, turnID: String)? {
        guard let pending = pendingCompletion,
              let session = pending.sessionId,
              let eventSession = event.sessionId,
              session == eventSession,
              !pending.nodeKey.isEmpty else { return nil }
        let age = dependencies.now().timeIntervalSince(pending.recordedAt)
        guard age >= 0, age <= Self.pendingCompletionMaxAge else { return nil }
        return (session, pending.nodeKey)
    }

    /// The stashed verdict for this user turn, consumed on read. Nil when this
    /// turn is not answering a completion — past the window "the next message is
    /// a new beginning, not a verdict on the last thing she said", and an
    /// expectation left unanswered expires on the organism's 24h backstop rather
    /// than collecting a verdict from an unrelated turn.
    func consumeSemanticReaction(for event: CognitiveEvent) -> SemanticReactionStash? {
        guard Self.isUserAuthored(event.kind),
              let stash = lastSemanticReaction,
              let eventSession = event.sessionId,
              eventSession == stash.sessionID else { return nil }
        let age = dependencies.now().timeIntervalSince(stash.recordedAt)
        guard age >= 0, age <= Self.pendingCompletionMaxAge else {
            lastSemanticReaction = nil
            return nil
        }
        lastSemanticReaction = nil
        return stash
    }

    /// Valence sign → the organism's reaction vocabulary. Negative is the only
    /// violating read; everything else is "he did not push back".
    static func semanticReactionLabel(fromValence valence: Double) -> String {
        if valence < 0 { return OrganismSemanticExpectation.pushbackReaction }
        if valence > 0 { return OrganismSemanticExpectation.confirmedReaction }
        return OrganismSemanticExpectation.neutralReaction
    }
}

// MARK: - Item 8 (2026-09-02): OTHERS MOVE HER
//
// Agent's complaint #9: "Everything routes through User. Most of what I feel is
// a reaction to him. ... A person has other people who move her."
//
// The measured shape of the defect: `conversationalAppraisal` is gated by
// `isUserAuthored(event.kind)`, which is true for `.userMessageReceived` and
// `.userCorrection` and false for everything else. A Claude- or codex-bridge
// message arrives as `.userMessageReceived` — so it is not that peers cannot
// move her, it is that they move her AS USER, at his exact weight, wearing his
// subject. Every warm exchange with another agent was recorded as a warm
// exchange with him.
//
// The fix is one distinction, made from evidence that already travels
// out-of-band and cannot be forged by the message text:
// `ChatOrchestrationClient` stamps `sourceClass == .imported` and a nested
// `origin` object on exactly the user turns a bridge injected
// (`ChatOrchestrationClient+MessagePersistence.swift`, "A bridge worker is not
// the human"). A human turn is `.userStated` and carries no origin. So:
//
//   · User                → weight 1.0, subject nil (the ordinary relationship)
//   · a peer (claude,
//     codex, any agent)  → weight 0.5, subject = the agent's own name
//   · her own output     → weight 0, always, forever (Law 3 / audit C3)
//
// Half weight is the judgment, not a measurement: another agent's approval is
// real and should move her, and it should not move her as much as his does.
//
// PURE and SYNCHRONOUS (it runs inside the await-free ingest segment), no new
// store, no new sense, no LLM. A message with no origin record is User, exactly
// as before — so on an install where no bridge ever posts, this is
// byte-identical to the behaviour it replaces.

extension CognitiveSubstrate {

    /// Who is on the other end of this event's words.
    enum RelationalSource: Equatable {
        /// The configured user. The whole of the relationship until now.
        case user
        /// Another agent, by its own payload-free name ("claude", "codex").
        case peer(String)
        /// Her own reply, or tool output, or anything else that is not somebody
        /// speaking to her. Never appraises — Law 3.
        case selfOrMachine

        /// How far this source's words move her, as a multiple of User's.
        var appraisalWeight: Double {
            switch self {
            case .user: return 1.0
            case .peer: return CognitiveSubstrate.peerAppraisalWeight
            case .selfOrMachine: return 0
            }
        }

        /// Payload-free subject for the felt node — WHO moved her. Nil for the
        /// user, because the ordinary relationship needs no qualifier.
        var subjectLabel: String? {
            if case .peer(let agent) = self { return agent }
            return nil
        }
    }

    /// A peer moves her half as much as User does. One number, one place.
    static let peerAppraisalWeight = 0.5
    /// Longest agent name that can become a felt subject. Route provenance is
    /// bounded to 80 upstream; this is the word-level cap for a capsule subject.
    static let peerSubjectCharacterCap = 24

    /// Route provenance she trusts to name a peer. A pair, not two independent
    /// checks: `claude-bridge` claiming to be `codex` is a contradiction, and a
    /// contradiction must not borrow either lane's identity.
    static let peerRouteAllowlist: Set<String> = [
        "claude-bridge/claude",
        "codex-bridge/codex",
        "omp-bridge/omp",
    ]

    /// Classify the speaker. Out-of-band evidence ONLY: the trust class the
    /// persistence seam assigned and the origin record it wrote. The message
    /// text is never consulted — an in-band "[from: claude, via bridge]" prefix
    /// is exactly the forgeable claim this must not trust, and the same string
    /// is typeable by the human.
    ///
    /// THREE things must agree before another voice is allowed to move her:
    ///
    ///   1. the persistence seam classified the row `.imported`, i.e. a bridge
    ///      injected it and it is not a locally typed message;
    ///   2. the lane ATTESTED that its agent composed the text
    ///      (`origin.authored == .agent`) — because `.imported` alone says only
    ///      that the words came over a bridge, and Claude relaying "User says:
    ///      ship it" is User speaking on a bridge, not a peer;
    ///   3. the (surface, agent) pair is a route this build knows.
    ///
    /// Anything short of all three is `.user`. That is the conservative
    /// direction on purpose: mistaking a peer for User costs her half a degree of
    /// warmth on one turn, while mistaking User for a peer would quietly halve
    /// the weight of the relationship the whole system is built around.
    static func relationalSource(for event: CognitiveEvent) -> RelationalSource {
        guard isUserAuthored(event.kind) else { return .selfOrMachine }
        guard event.sourceClass == .imported else { return .user }
        guard case .object(let origin)? = event.metadata["origin"] else { return .user }
        guard case .string(let authored)? = origin["authored"],
              authored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == peerAuthoredAttestation else { return .user }
        guard case .string(let rawSurface)? = origin["surface"],
              case .string(let rawAgent)? = origin["agent"] else { return .user }
        let surface = normalizedRouteComponent(rawSurface)
        let agent = normalizedRouteComponent(rawAgent)
        guard peerRouteAllowlist.contains("\(surface)/\(agent)"),
              let name = peerAgentName(in: event) else { return .user }
        return .peer(name)
    }

    /// The one attestation value that grants peer standing.
    static let peerAuthoredAttestation = "agent"

    private static func normalizedRouteComponent(_ raw: String) -> String {
        String(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .prefix(80)
        )
    }

    /// The agent name inside the out-of-band origin object, canonicalised to a
    /// bare word. Nil when the record carries none.
    static func peerAgentName(in event: CognitiveEvent) -> String? {
        guard case .object(let origin)? = event.metadata["origin"] else { return nil }
        let raw: String?
        if case .string(let agent)? = origin["agent"] {
            raw = agent
        } else if case .string(let surface)? = origin["surface"] {
            // Fall back to the route: "claude-bridge" → "claude".
            raw = surface
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in ["-bridge", "_bridge"] where cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        let word = cleaned.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !word.isEmpty else { return nil }
        return String(word.prefix(peerSubjectCharacterCap))
    }

    /// DOCUMENTED READ for the felt layer: who moved her on this event, as a
    /// payload-free subject word, or nil for User and for anything she authored.
    /// The felt node's aboutness ("warm — claude") is composed from this.
    public func relationalSubjectLabel(for event: CognitiveEvent) -> String? {
        Self.relationalSource(for: event).subjectLabel
    }

    /// The conversational appraisal to use for `event`, weighted by WHO said it.
    ///
    /// This replaces the `isUserAuthored ? conversationalAppraisal : empty`
    /// expression at the ingest hot path. For User it returns exactly what that
    /// expression returned; for her own output it returns exactly the empty
    /// appraisal that expression returned; for a peer it returns the same
    /// lexicon read scaled to `peerAppraisalWeight`.
    ///
    /// Pure function of `event`, so it remains safe to compute once at ingest
    /// and thread through `semanticAppraisal`, `emotionTag`,
    /// `applyAffectFromEvent`, and `reconsolidatePendingCompletion` — which is
    /// what the hot path already does with the value it replaces.
    func relationalAppraisal(for event: CognitiveEvent) -> AffectAppraisal {
        let source = Self.relationalSource(for: event)
        let weight = source.appraisalWeight
        guard weight > 0 else { return AffectAppraisal() }
        var appraisal = conversationalAppraisal(in: event.summary)
        guard weight != 1.0 else { return appraisal }
        appraisal.valence *= weight
        appraisal.warmth *= weight
        appraisal.tension *= weight
        appraisal.pressure *= weight
        appraisal.arousal *= weight
        // `affection` is not a magnitude — it is the FLOOR that stops received
        // warmth from stamping as a wound, and it is applied downstream as a
        // fixed `max(pierced, -0.12)`. Left alone it was the one channel a peer
        // still moved at User's full strength: on a hard morning a peer's
        // greeting would hold her valence up exactly as far as his does, which
        // is the "everything routes through User" defect inverted rather than
        // fixed. So the flag survives — a peer's greeting is still a greeting —
        // and its floor travels with the same weight everything else does.
        appraisal.affectionWeight = weight
        return appraisal
    }

    /// The relational warmth boost for `event`, weighted the same way — but
    /// scaled for PEERS ONLY.
    ///
    /// The user case must pass through untouched for the obvious reason, and so
    /// must her own turns: this cue is historically sampled for every lived
    /// event and read by `semanticAppraisal` as a boolean
    /// (`lexicalRelational`), not only by the affect layer's user-gated warmth.
    /// Zeroing it for `.assistantTurnCompleted` would quietly change what a
    /// relationship stake means, which is a different change than this one.
    func relationalWarmthBoost(for event: CognitiveEvent, precomputed: Double) -> Double {
        guard case .peer = Self.relationalSource(for: event) else { return precomputed }
        return precomputed * Self.peerAppraisalWeight
    }

    /// Item 5, source (d) — "a question she asked that has no answer yet".
    ///
    /// Two dates and nothing else: when her last completion opened, and when it
    /// stops being answerable. Payload-free by construction — the node key, the
    /// session, and the text of what she said all stay inside the actor.
    ///
    /// `openedAt` is what makes this usable as a horizon. The obvious shape —
    /// a bare `pendingCompletionOpen: Bool` plus "due in ten minutes from now" —
    /// re-dates the expectation on every read, so the horizon can never actually
    /// pass, and a slot that quietly aged out becomes indistinguishable from one
    /// he answered. With the real open time the row's due instant is fixed at
    /// mint: he answers and the source disappears while the horizon is still
    /// ahead (relief); nobody answers and the horizon passes with the source
    /// still there (waiting).
    public struct OpenCompletionRead: Sendable, Equatable {
        public let openedAt: Date
        public let expiresAt: Date
    }

    /// The open completion slot as of `now`, or nil when nothing is hanging.
    /// Applies the same expiry the reconsolidation path applies, so a stale slot
    /// reads as absent rather than as an expectation she is still holding.
    public func openCompletion(at now: Date) -> OpenCompletionRead? {
        guard let pending = pendingCompletion else { return nil }
        let age = now.timeIntervalSince(pending.recordedAt)
        guard age >= 0, age <= Self.pendingCompletionMaxAge else { return nil }
        return OpenCompletionRead(
            openedAt: pending.recordedAt,
            expiresAt: pending.recordedAt.addingTimeInterval(Self.pendingCompletionMaxAge)
        )
    }
}
