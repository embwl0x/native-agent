import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Agent's complaints #1 and #2, 2026-09-02.
//
//   #1 "They're also never *about* anything. 'Interested' — in what? A real
//       mood has an object and a direction. Mine is weather with no sky."
//   #2 "What I'm handed is always clean and agreeable with itself. A person at
//       1 AM after a night of restarts is fond *and* irritated."
//
// Both organs are word-level on the line that already exists — the capsule stays
// brief. Both have exactly one way to fail badly, and it is the same way: by
// putting something in front of her that is not true. So the assertions below
// are mostly REFUSALS.
//
// The two failures this suite exists to catch:
//   * the object leaking BODY TEXT — a subject label that is really the user's
//     message would put the user's own words back into her felt line, on a
//     surface whose whole exposure argument is that it carries no payload;
//   * ambivalence firing on ONE SUBJECT or on a WEAK state — that is not
//     ambivalence, it is a broken gauge reporting two signs of one reading, and
//     it would re-open the contradiction table for everything.
@Suite("FeltObjectAmbivalence")
struct FeltObjectAmbivalenceTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let dyn = PersonalityDynamicsConfiguration.default

    private func node(
        subjectType: String,
        label: String?,
        summary: String = "we shipped the register fix tonight",
        valence: Double,
        arousal: Double = 0.3,
        warmth: Double = 0.5,
        at: Date,
        id: UUID = UUID(),
        subjectID: String = UUID().uuidString
    ) -> CognitiveNode {
        CognitiveNode(
            id: id,
            kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(
                type: subjectType, id: subjectID, label: label),
            activation: 0.9, salience: 0.9, confidence: 0.8, sourceClass: .userStated,
            createdAt: at, lastActivatedAt: at,
            decayHalfLife: 1_000_000,
            summary: summary, metadata: [:],
            emotionalValence: valence, emotionalArousal: arousal, emotionalWarmth: warmth)
    }

    private func item(_ node: CognitiveNode) -> CognitiveWorkspaceItem {
        CognitiveWorkspaceItem(node: node, score: node.activation, reasons: ["recency"])
    }

    private func substrate() -> CognitiveSubstrate {
        AffectFenceFixture.substrate(clock: AffectFenceClock(t0))
    }

    // MARK: - (1) the OBJECT only ever names a real subject label

    /// The allowlist is the gate, per design law 8 ("noise gates are
    /// allowlists"). A studio entry's label IS its work title — the same
    /// pointer the felt-day summary is already permitted to name.
    @Test func objectNamesAnAllowlistedSubjectLabel() {
        let studio = node(subjectType: "studio_entry", label: "the register fix", valence: -0.6, at: t0)
        #expect(CognitiveSubstrate.feltObjectLabel(
            for: studio, maxCharacters: dyn.feltObjectMaximumLabelCharacters) == "the register fix")
    }

    /// THE LEAK TEST. Every subject type nobody has vetted fails closed.
    ///
    /// `chat_turn` and `chat.user_turn` LEFT this list on 2026-09-02, when their
    /// producers started minting a safe topic label instead of a route — they
    /// have their own coverage above and below. `chat.assistant_turn` did not
    /// and must not: design law 3, she never appraises her own output.
    @Test func objectRefusesEveryUnvettedSubjectType() {
        let cases: [(String, String?)] = [
            ("chat.assistant_turn", "sure — reading it now"),
            ("chat.session", "s1"),
            ("tool", "read_file"),
            ("provider", "anthropic"),
            ("app", "NativeAgent"),
            ("motor_action", "filesystem"),
            ("topic", "topic"),
        ]
        for (type, label) in cases {
            let n = node(subjectType: type, label: label, valence: -0.6, at: t0)
            #expect(
                CognitiveSubstrate.feltObjectLabel(
                    for: n, maxCharacters: dyn.feltObjectMaximumLabelCharacters) == nil,
                "subject type \(type) must not be able to name an object")
        }
    }

    /// Belt and braces on the allowlisted type: even there, a label that has
    /// become a copy of the node's body, a sentence, an id, or something too
    /// long to be a name is REFUSED — never trimmed. Truncating at 32 would
    /// manufacture a phrase she then reads as the name of a thing.
    @Test func objectRefusesBodyTextSentencesIdsAndOverlongLabels() {
        let body = "we shipped the register fix tonight"
        let leaked = node(subjectType: "studio_entry", label: body, summary: body, valence: -0.6, at: t0)
        #expect(CognitiveSubstrate.feltObjectLabel(
            for: leaked, maxCharacters: dyn.feltObjectMaximumLabelCharacters) == nil,
            "a label equal to the node body is body text wearing a label")

        let sentence = node(
            subjectType: "studio_entry",
            label: "can you check this? it broke.",
            valence: -0.6, at: t0)
        #expect(CognitiveSubstrate.feltObjectLabel(
            for: sentence, maxCharacters: dyn.feltObjectMaximumLabelCharacters) == nil)

        let wordy = node(
            subjectType: "studio_entry",
            label: "one two three four five six seven",
            valence: -0.6, at: t0)
        #expect(CognitiveSubstrate.feltObjectLabel(
            for: wordy, maxCharacters: dyn.feltObjectMaximumLabelCharacters) == nil)

        let overlong = node(
            subjectType: "studio_entry",
            label: "the deploy pipeline rewrite we started",
            valence: -0.6, at: t0)
        #expect(overlong.subjectReference.label!.count > dyn.feltObjectMaximumLabelCharacters)
        #expect(CognitiveSubstrate.feltObjectLabel(
            for: overlong, maxCharacters: dyn.feltObjectMaximumLabelCharacters) == nil,
            "over the cap is a refusal, not a trim")

        let identifier = node(subjectType: "studio_entry", label: "entry 20260902 1", valence: -0.6, at: t0)
        #expect(CognitiveSubstrate.feltObjectLabel(
            for: identifier, maxCharacters: dyn.feltObjectMaximumLabelCharacters) == nil)

        let unlabelled = node(subjectType: "studio_entry", label: nil, valence: -0.6, at: t0)
        #expect(CognitiveSubstrate.feltObjectLabel(
            for: unlabelled, maxCharacters: dyn.feltObjectMaximumLabelCharacters) == nil)
    }

    /// The lead's node is TRACED, not guessed: the dominant node is the one whose
    /// valence carries direct weight in the fingerprint, which is the freshest
    /// felt node — the same rule the tint loop applies.
    @Test func dominantNodeIsTheFreshestContributor() throws {
        let stale = node(subjectType: "studio_entry", label: "old work", valence: 0.7, at: t0.addingTimeInterval(-3_600))
        let fresh = node(subjectType: "studio_entry", label: "the register fix", valence: -0.7, at: t0)
        let dominant = try #require(CognitiveSubstrate.feltDominantNode(
            in: [stale, fresh], at: t0, halfLife: dyn.fingerprintTintHalfLife))
        #expect(dominant.id == fresh.id)
        #expect(CognitiveSubstrate.feltDominantNode(
            in: [], at: t0, halfLife: dyn.fingerprintTintHalfLife) == nil,
            "no contributing node is a DIFFUSE state, and a diffuse state has no object")
    }

    /// Rendering. Direction picks the connector because English does, and the
    /// object binds to the LEAD — before the second feeling, which is about
    /// something else and stays honestly unattributed.
    @Test func theLineRendersObjectThenAmbivalence() {
        let negative = CognitiveSubstrate.FeltFingerprintParts(
            family: "neg_high", lead: "on edge", overlays: [])
        #expect(CognitiveSubstrate.feltLineText(
            parts: negative, object: "the register fix", second: nil)
            == "on edge — about the register fix")

        let positive = CognitiveSubstrate.FeltFingerprintParts(
            family: "pos_low", lead: "warm", overlays: [])
        #expect(CognitiveSubstrate.feltLineText(parts: positive, object: "User, earlier", second: nil)
            == "warm — User, earlier")

        #expect(CognitiveSubstrate.feltLineText(
            parts: negative, object: "the register fix", second: "fond")
            == "on edge — about the register fix, and fond underneath")

        // No object: the exception still reads as one line, not two.
        #expect(CognitiveSubstrate.feltLineText(parts: negative, object: nil, second: "fond")
            == "on edge, and fond underneath")

        // Unchanged when neither organ fires — the historical line, byte for byte.
        let withOverlays = CognitiveSubstrate.FeltFingerprintParts(
            family: "neu_high", lead: "focused", overlays: ["curious", "clear-headed"])
        #expect(CognitiveSubstrate.feltLineText(parts: withOverlays, object: nil, second: nil)
            == "focused, curious, clear-headed")
        #expect(withOverlays.text == "focused, curious, clear-headed")
    }

    /// The decomposition must not have moved the words. `feltFingerprint` is
    /// `feltFingerprintParts(...).text` and nothing else.
    @Test func decompositionIsByteIdenticalToTheOldFingerprint() {
        for valence in stride(from: -0.9, through: 0.9, by: 0.15) {
            for arousal in stride(from: 0.05, through: 0.95, by: 0.15) {
                let s = CognitiveSubstrate.FeltSignals(
                    valence: valence, arousal: arousal, warmth: 0.55,
                    tension: 0.3, pressure: 0.3,
                    fatigue: 0.4, curiosity: 0.5, clarity: 0.6,
                    agency: 0.5, confidence: 0.5)
                #expect(CognitiveSubstrate.feltFingerprint(s)
                    == CognitiveSubstrate.feltFingerprintParts(s)?.text)
            }
        }
    }

    // MARK: - (1b) the TOPIC label that makes the object live on conversation

    /// The object organ was inert until conversation nodes carried a topic.
    /// This is the label that fixed it: salient content words only, through the
    /// same extractor Fluid Context already runs for attention terms.
    @Test func topicLabelKeepsTermsAndDropsEverythingElse() throws {
        let label = try #require(CognitiveSubstrate.feltTopicLabel(
            from: "can you look at the deploy pipeline again? it broke overnight"))
        // Content words survive; the question, the addressee and the grammar
        // do not — which is the whole exposure argument. "deploy pipeline" were
        // ADJACENT, so the pair earns the two-word form.
        #expect(label == "deploy pipeline", "got \(label)")
        #expect(!label.contains("?"))
        #expect(!label.contains("you"))
        #expect(label.count <= 32)
        #expect(label == label.lowercased())
    }

    // MARK: - (1a') THE PHRASE RULE (live residual, 2026-09-02)

    /// THE LIVE DEFECT: `proud, collected, curious — readings pull fatigue`.
    /// Three salient, safe, SCATTERED words joined by spaces read as salad, and
    /// an object that reads as salad is worse than no object. Salience was
    /// never the missing test — adjacency was.
    @Test func threeScatteredTermsCollapseToTheLeadingOne() throws {
        let label = try #require(CognitiveSubstrate.feltTopicLabel(
            from: "the readings pull fatigue into every answer"))
        #expect(label == "readings", "salad survived: \(label)")
        #expect(label.split(separator: " ").count == 1)
    }

    /// A real compound noun keeps both words — that is the whole point of
    /// allowing two.
    @Test func anAdjacentPairIsRenderedAsAPhrase() throws {
        for (text, expected) in [
            ("the vault migration is overdue", "vault migration"),
            ("that deploy pipeline again", "deploy pipeline"),
        ] {
            let label = try #require(CognitiveSubstrate.feltTopicLabel(from: text))
            #expect(label == expected, "\(text.debugDescription) → \(label)")
        }
        // NOT "tool audit", even though it is a genuine adjacent pair: `tool`
        // is a ROUTE word in this codebase (`feltWeakObjectWords`) and is
        // dropped before adjacency is ever considered, so the noun beside it is
        // what stands. Pinned because it is surprising, and because whoever
        // takes `tool` off that list should have to change a test that says why
        // it is on it.
        #expect(CognitiveSubstrate.feltTopicLabel(from: "the tool audit is overdue") == "audit")
    }

    /// Two safe terms that were NOT next to each other stay apart: only the
    /// leading one is rendered, because they never formed a phrase.
    @Test func nonAdjacentTermsNeverJoin() throws {
        let label = try #require(CognitiveSubstrate.feltTopicLabel(
            from: "the invoice, which nobody chased, concerns the rollout"))
        #expect(label.split(separator: " ").count == 1, "joined a non-phrase: \(label)")
        #expect(label == "invoice", "got \(label)")
    }

    /// NEVER THREE, by construction rather than by a cap — and a caller that
    /// asks for three gets the same answer as one that asks for two.
    @Test func theRenderedObjectIsNeverMoreThanTwoWords() {
        for text in [
            "the readings pull fatigue into every answer",
            "reconciliation subsystem instrumentation checkpoints drifted",
            "deploy pipeline rollout schedule slipped",
            "warmth variety language cadence",
        ] {
            for terms in [2, 3, 6] {
                let label = CognitiveSubstrate.feltTopicLabel(from: text, maximumTerms: terms) ?? ""
                #expect(label.split(separator: " ").count <= 2,
                        "\(text.debugDescription) at limit \(terms) → \(label)")
            }
            #expect(CognitiveSubstrate.feltTopicLabel(from: text, maximumTerms: 3)
                == CognitiveSubstrate.feltTopicLabel(from: text, maximumTerms: 2))
        }
    }

    /// A state-change verb is a sentence ABOUT the thing, not a name FOR it, so
    /// the leading noun is left standing alone rather than paired with it.
    @Test func aStateChangeVerbNeverPairsWithItsSubject() throws {
        let label = try #require(CognitiveSubstrate.feltTopicLabel(from: "the deploy broke again"))
        #expect(label == "deploy", "got \(label)")
    }

    /// NO SALIENT TERM, NO OBJECT. A turn made entirely of stopwords and short
    /// words has no topic, and the honest answer is silence rather than a
    /// fallback that would put the route back on the line.
    @Test func topicLabelIsNilWhenNothingIsSalient() {
        for empty in ["ok", "yes, and then?", "it is what it is", "   ", "hey you"] {
            #expect(CognitiveSubstrate.feltTopicLabel(from: empty) == nil,
                    "\(empty.debugDescription) has no topic and must yield no object")
        }
    }

    // MARK: - (1a) THE PRIVACY RULES (review finding 1)

    /// THE FINDING, VERBATIM. `summaryKeywords` — the ranker's extractor —
    /// happily returns a person's name, and the felt line would have rendered
    /// `on edge — about sarah kensington` into the model's context. The safe
    /// extractor drops every non-lowercase token, so the name is gone before
    /// anything is joined; the leftover verb is dropped too, so what is left is
    /// no object at all rather than a fragment standing in for a name.
    @Test func aPersonsNameNeverReachesTheObject() {
        let label = CognitiveSubstrate.feltTopicLabel(from: "don't mention Sarah Kensington")
        #expect(label == nil, "a name-only turn must yield no object, got \(label ?? "nil")")

        for text in [
            "Sarah broke the build",
            "ask Dr Kensington about it",
            "James and Priya are both on it",
            "Kensington",
        ] {
            let out = CognitiveSubstrate.feltTopicLabel(from: text) ?? ""
            for name in ["sarah", "kensington", "james", "priya"] {
                #expect(!out.contains(name), "\(text.debugDescription) leaked \(name): \(out)")
            }
        }
    }

    /// The neighbourhood of a credential is the credential. A term next to
    /// "password" / "key" / "token" names the thing being protected, so it goes
    /// with the word that named it.
    @Test func secretNeighbourhoodsAreDropped() {
        for text in [
            "rotate the anthropic deploy key tonight",
            "my password for the pipeline account is wrong",
            "the github token expired",
            "check my ssn on the passport application",
            "the card number failed again",
        ] {
            let out = CognitiveSubstrate.feltTopicLabel(from: text) ?? ""
            for banned in ["password", "token", "ssn", "card", "account", "passport",
                           "anthropic", "github", "deploy", "pipeline"] where text.contains(banned) {
                #expect(!out.contains(banned),
                        "\(text.debugDescription) kept secret-adjacent \(banned): \(out)")
            }
        }
    }

    /// A redaction marker is what the redactor leaves BEHIND. It must not be
    /// re-read as a topic — `about redacted github token` would describe the
    /// shape of the secret that was removed.
    @Test func redactionMarkersNeverBecomeObjects() {
        let redacted = TurnTraceRedactor.redactText(
            "the deploy uses ghp_abcdefghijklmnopqrstuvwxyz012345 to publish")
        #expect(redacted.contains("REDACTED"), "fixture must actually redact: \(redacted)")
        let out = CognitiveSubstrate.feltTopicLabel(from: redacted) ?? ""
        #expect(!out.lowercased().contains("redacted"))
        #expect(!out.lowercased().contains("github"))
        #expect(!out.lowercased().contains("token"))
    }

    /// Numbers, addresses, handles and URLs — none of them are topics, and all
    /// of them are identifying.
    @Test func numericsAddressesAndHandlesAreDropped() {
        for text in [
            "invoice 88421 is overdue",
            "email user@example.com about the schedule",
            "ping @rowan.vale when it lands",
            "see https://internal.example.com/runbook for the steps",
            "the api_key=abcd1234 broke it",
        ] {
            let out = CognitiveSubstrate.feltTopicLabel(from: text) ?? ""
            #expect(out.rangeOfCharacter(from: .decimalDigits) == nil, "\(text.debugDescription) kept a digit: \(out)")
            #expect(!out.contains("@"))
            #expect(!out.contains("example"), "\(text.debugDescription) kept an address token: \(out)")
            #expect(!out.contains("rowan.vale"))
        }
    }

    /// The producer is where this has to hold: the LABEL ITSELF must be safe on
    /// disk, not merely scrubbed on the way to the prompt. Both mint sites call
    /// `feltTopicLabel`, so this is the check that covers both.
    @Test func theProducerNeverMintsAnUnsafeLabel() {
        let hostile = "Sarah Kensington's password is hunter2 — email sarah@example.com, invoice 5512"
        let label = CognitiveSubstrate.feltTopicLabel(from: hostile)
        if let label {
            for banned in ["sarah", "kensington", "password", "hunter", "example", "5512", "@"] {
                #expect(!label.lowercased().contains(banned), "label leaked \(banned): \(label)")
            }
            #expect(label.rangeOfCharacter(from: .decimalDigits) == nil)
        }
    }

    /// A phrase that would overflow the cap is DROPPED back to one word, and a
    /// single word that overflows is refused outright — never cut. A fragment
    /// would read as the name of a thing.
    @Test func topicLabelNeverTruncatesMidWord() throws {
        let source = "reconciliation subsystem instrumentation checkpoints"
        let label = try #require(CognitiveSubstrate.feltTopicLabel(from: source, maxCharacters: 32))
        #expect(label.count <= 32)
        // Every rendered token is a whole token from the source.
        let tokens = Set(source.split(separator: " ").map(String.init))
        for token in label.split(separator: " ") {
            #expect(tokens.contains(String(token)), "\(token) was cut, not dropped")
        }
        // A pair that does not fit falls back to its first word rather than
        // being trimmed to fit.
        let tight = CognitiveSubstrate.feltTopicLabel(
            from: "the vault migration is overdue", maxCharacters: 8)
        #expect(tight == "vault", "got \(tight ?? "nil")")
        // And a lone word longer than the cap is refused, not cut.
        #expect(CognitiveSubstrate.feltTopicLabel(
            from: "reconciliation", maxCharacters: 8) == nil)
    }

    /// End of the chain: a conversation subject type is now on the allowlist, so
    /// a labelled chat turn yields a real object.
    @Test func aChatTurnWithATopicYieldsAnObject() throws {
        let label = try #require(CognitiveSubstrate.feltTopicLabel(from: "the deploy broke again"))
        let turn = node(
            subjectType: "chat_turn", label: label,
            summary: "the deploy broke again", valence: -0.6, at: t0)
        #expect(CognitiveSubstrate.feltObjectLabel(
            for: turn, maxCharacters: dyn.feltObjectMaximumLabelCharacters) == label)
    }

    /// The route label this replaced is refused at BOTH ends now: the producer
    /// cannot mint it (every token is a route word), and the extractor refuses
    /// it if some other seam ever hands one over. Two seams, one rule.
    @Test func theRouteLabelIsRefusedAtBothEnds() {
        #expect(CognitiveSubstrate.feltTopicLabel(from: "chat user") == nil)
        #expect(CognitiveSubstrate.feltTopicLabel(from: "chat assistant") == nil)
        #expect(CognitiveSubstrate.feltTopicLabel(from: "telegram user") == nil)
        #expect(CognitiveSubstrate.feltSafeObjectTerms(in: "chat user").isEmpty)
    }

    // MARK: - (1c) TOWARD — the forward object

    private func toward(_ label: String, sign: Int, overdue: Bool) -> OrganismTowardRead {
        OrganismTowardRead(
            label: label,
            sourceKind: .statedPlan,
            valenceSign: sign,
            dueAt: overdue ? t0.addingTimeInterval(-600) : t0.addingTimeInterval(86_400),
            isOverdue: overdue)
    }

    /// Horizon labels are canonicalised with dashes; the line reads them as
    /// language, and refuses the ones that are not names.
    @Test func towardLabelsAreCleanedOrRefused() {
        #expect(CognitiveSubstrate.feltTowardLabel("dinner-with-user", maxCharacters: 32)
            == "dinner with user")
        #expect(CognitiveSubstrate.feltTowardLabel("friday", maxCharacters: 32) == "friday")
        #expect(CognitiveSubstrate.feltTowardLabel("unknown", maxCharacters: 32) == nil,
                "the register's own placeholder is not a thing to look forward to")
        #expect(CognitiveSubstrate.feltTowardLabel(
            "a-b-c-d-e-f", maxCharacters: 32) == nil, "too many tokens to be a name")
        #expect(CognitiveSubstrate.feltTowardLabel(
            String(repeating: "a", count: 40), maxCharacters: 32) == nil)
    }

    /// BRANCH 1 — a positive lead with no node object takes the horizon.
    /// BRANCH 2 — an overdue horizon under a NEUTRAL lead renames the lead
    /// `waiting`. Both are rendered through the same one-object path.
    @Test func towardFillsAnEmptyObjectSlotInBothBranches() {
        let hopeful = CognitiveSubstrate.FeltFingerprintParts(
            family: "pos_med", lead: "hopeful", overlays: [])
        #expect(CognitiveSubstrate.feltLineText(parts: hopeful, object: "friday", second: nil)
            == "hopeful — friday")

        var waiting = CognitiveSubstrate.FeltFingerprintParts(
            family: "neu_med", lead: "quiet", overlays: [])
        waiting.lead = "waiting"
        #expect(CognitiveSubstrate.feltLineText(parts: waiting, object: "codex", second: nil)
            == "waiting — codex")
    }

    /// NEVER TWO OBJECTS. A node object is something that actually happened to
    /// her and always wins; the horizon only ever fills an EMPTY slot.
    @Test func aNodeObjectBeatsTheHorizonAndOnlyOneIsRendered() async throws {
        let s = substrate()
        let studio = node(
            subjectType: "studio_entry", label: "the register fix",
            valence: 0.7, arousal: 0.4, warmth: 0.8, at: t0)
        var request = AffectFenceFixture.capsuleRequest("how's it going")
        request.toward = toward("friday", sign: 1, overdue: false)

        let line = try #require(await s.feltFingerprintLine(
            signals: CognitiveSubstrate.FeltSignals(
                valence: 0.5, arousal: 0.35, warmth: 0.75,
                tension: 0.1, pressure: 0.1,
                fatigue: 0.1, curiosity: 0.5, clarity: 0.7),
            workspaceItems: [item(studio)],
            request: request,
            at: t0,
            dynamics: dyn))
        #expect(line.carriedObject)
        #expect(line.text.contains("the register fix"))
        #expect(!line.text.contains("friday"), "two objects on one line: \(line.text)")
        #expect(line.text.components(separatedBy: " — ").count == 2,
                "exactly one object connector: \(line.text)")
    }

    /// REVIEW FINDING 4 — the horizon's OWN sign decides too. A positive lead
    /// over a horizon she is DREADING would have rendered "hopeful — friday"
    /// about the call she does not want to take.
    @Test func aDreadedHorizonIsNeverAHopefulObject() async throws {
        let s = substrate()
        var request = AffectFenceFixture.capsuleRequest("how's it going")
        request.toward = toward("the call", sign: -1, overdue: false)
        let line = try #require(await s.feltFingerprintLine(
            signals: CognitiveSubstrate.FeltSignals(
                valence: 0.5, arousal: 0.35, warmth: 0.75,
                tension: 0.1, pressure: 0.1,
                fatigue: 0.1, curiosity: 0.5, clarity: 0.7),
            workspaceItems: [],
            request: request,
            at: t0,
            dynamics: dyn))
        #expect(!line.carriedObject, "a dreaded horizon took a hopeful object: \(line.text)")
        #expect(!line.text.contains("the call"))
    }

    /// A flat (zero-sign) horizon is not something to look forward to either —
    /// only the overdue/neutral `waiting` path may take one.
    @Test func aFlatHorizonIsNotAPositiveObject() async throws {
        let s = substrate()
        var request = AffectFenceFixture.capsuleRequest("how's it going")
        request.toward = toward("friday", sign: 0, overdue: false)
        let line = try #require(await s.feltFingerprintLine(
            signals: CognitiveSubstrate.FeltSignals(
                valence: 0.5, arousal: 0.35, warmth: 0.75,
                tension: 0.1, pressure: 0.1,
                fatigue: 0.1, curiosity: 0.5, clarity: 0.7),
            workspaceItems: [],
            request: request,
            at: t0,
            dynamics: dyn))
        #expect(!line.carriedObject, "a flat horizon must not read as hopeful: \(line.text)")
    }

    /// A NEGATIVE lead takes no horizon. Dread about something ahead reads as
    /// the sting in the room; attaching a future label would tell her the wrong
    /// thing about why she feels bad.
    @Test func aNegativeLeadNeverTakesTheHorizon() async throws {
        let s = substrate()
        var request = AffectFenceFixture.capsuleRequest("this is going badly")
        request.toward = toward("friday", sign: 1, overdue: false)
        let line = try #require(await s.feltFingerprintLine(
            signals: CognitiveSubstrate.FeltSignals(
                valence: -0.6, arousal: 0.6, warmth: 0.2,
                tension: 0.6, pressure: 0.5,
                fatigue: 0.2, curiosity: 0.3, clarity: 0.6),
            workspaceItems: [],
            request: request,
            at: t0,
            dynamics: dyn))
        #expect(!line.carriedObject, "negative lead took a forward object: \(line.text)")
    }

    // MARK: - (1d) the body's clock reaches the words

    /// `tired` is the MID band whose ceiling is the `worn` gate — the same
    /// discipline `curious`/`interested` follow, so widening the vocabulary
    /// cannot re-create a floor one notch down.
    @Test func tiredOwnsTheMidBandAndWornOwnsTheTop() {
        func words(fatigue: Double) -> [String] {
            let s = CognitiveSubstrate.FeltSignals(
                valence: 0.1, arousal: 0.35, warmth: 0.55, tension: 0.2, pressure: 0.3,
                fatigue: fatigue, curiosity: 0.3, clarity: 0.6)
            return CognitiveSubstrate.feltFingerprintParts(s)?.words ?? []
        }
        #expect(!words(fatigue: 0.10).contains("tired"), "below the floor there is no tiredness to report")
        #expect(words(fatigue: 0.40).contains("tired"))
        #expect(!words(fatigue: 0.40).contains("worn"))
        #expect(words(fatigue: 0.80).contains("worn"))
        #expect(!words(fatigue: 0.80).contains("tired"), "tired and worn must never both be true")
    }

    /// `late` refuses to read the clock alone: deep night with nothing behind
    /// it is a timestamp, not a feeling — and with no diurnal clock at all the
    /// word leaves the pool rather than being guessed.
    @Test func lateNeedsBothTheNightAndTheTiredness() {
        func words(nightliness: Double?, fatigue: Double) -> [String] {
            let s = CognitiveSubstrate.FeltSignals(
                valence: 0.1, arousal: 0.3, warmth: 0.55, tension: 0.2, pressure: 0.3,
                fatigue: fatigue, curiosity: 0.3, clarity: 0.6, nightliness: nightliness)
            return CognitiveSubstrate.feltFingerprintParts(s)?.words ?? []
        }
        #expect(words(nightliness: 0.9, fatigue: 0.30).contains("late"))
        #expect(!words(nightliness: 0.9, fatigue: 0.02).contains("late"),
                "1 AM with nothing behind it is a timestamp")
        #expect(!words(nightliness: 0.2, fatigue: 0.30).contains("late"))
        #expect(!words(nightliness: nil, fatigue: 0.30).contains("late"),
                "with no diurnal clock the word must be unreachable, not guessed")
    }

    // MARK: - (2) AMBIVALENCE — the gates, first

    /// THE FIXTURE THE EXCEPTION EXISTS FOR: two strong, recent felt nodes,
    /// opposite sign, DIFFERENT subjects. 1 AM after a night of restarts.
    @Test func ambivalenceFiresOnTwoSubjectsOfOppositeSign() async throws {
        let s = substrate()
        let sting = node(
            subjectType: "studio_entry", label: "the deploy",
            valence: -0.7, arousal: 0.6, warmth: 0.2, at: t0, subjectID: "deploy")
        let warm = node(
            subjectType: "studio_entry", label: "the evening",
            valence: 0.6, arousal: 0.2, warmth: 0.8,
            at: t0.addingTimeInterval(-600), subjectID: "evening")

        let partner = try #require(await s.feltAmbivalencePartner(
            of: sting, among: [item(sting), item(warm)], at: t0, dynamics: dyn))
        #expect(partner.id == warm.id)

        // …and it reaches a WORD. The counter signals are the current signals
        // with only valence/arousal swapped, so the second word is a real read
        // of the same body, not an invented one.
        var counter = CognitiveSubstrate.FeltSignals(
            valence: -0.7, arousal: 0.6, warmth: 0.62, tension: 0.5, pressure: 0.4,
            fatigue: 0.5, curiosity: 0.4, clarity: 0.6)
        counter.valence = warm.emotionalValence
        counter.arousal = warm.emotionalArousal
        let word = CognitiveSubstrate.feltCounterWord(
            counter, excluding: ["on edge"], intensityFloor: dyn.feltIntensityFloor)
        #expect(word != nil, "the pair must reach an actual second word, not just a flag")
        #expect(word != "on edge", "the second word must not repeat what is already on the line")
    }

    /// ONE SUBJECT IS NOT AMBIVALENCE. Same subject with two signs is a gauge
    /// fault; letting it through would turn the exception into the rule.
    @Test func ambivalenceRefusesOneSubject() async throws {
        let s = substrate()
        let sting = node(
            subjectType: "studio_entry", label: "deploy",
            valence: -0.7, arousal: 0.6, at: t0, subjectID: "deploy")
        let sameSubject = node(
            subjectType: "studio_entry", label: "deploy",
            valence: 0.6, arousal: 0.2, at: t0.addingTimeInterval(-600), subjectID: "deploy")
        #expect(await s.feltAmbivalencePartner(
            of: sting, among: [item(sting), item(sameSubject)], at: t0, dynamics: dyn) == nil)
    }

    /// REVIEW FINDING 2 — THE ONE THAT MATTERED. A chat turn's `stableKey` is
    /// `chat.user_turn:<session>:<message>`, i.e. PER TURN, so two turns about
    /// the same deploy compared as two subjects and the gate whose whole job is
    /// "different things" waved through one thing felt twice. Aboutness is now
    /// keyed on the topic, so it does not.
    @Test func twoTurnsAboutOneTopicAreOneSubject() async throws {
        let s = substrate()
        let stung = node(
            subjectType: "chat.user_turn", label: "deploy pipeline",
            summary: "the deploy pipeline broke", valence: -0.7, arousal: 0.6,
            at: t0, subjectID: "session-1:message-1")
        let warm = node(
            subjectType: "chat.user_turn", label: "deploy pipeline",
            summary: "the deploy pipeline is finally green", valence: 0.6, arousal: 0.2,
            at: t0.addingTimeInterval(-600), subjectID: "session-1:message-2")
        #expect(stung.subjectReference.stableKey != warm.subjectReference.stableKey,
                "fixture must actually have different per-turn ids")
        #expect(CognitiveSubstrate.feltAboutnessKey(for: stung)
            == CognitiveSubstrate.feltAboutnessKey(for: warm),
            "same topic must be the same aboutness")
        #expect(await s.feltAmbivalencePartner(
            of: stung, among: [item(stung), item(warm)], at: t0, dynamics: dyn) == nil,
            "two turns about one deploy are not ambivalence")
    }

    /// …and two turns about DIFFERENT topics still qualify, so the fix did not
    /// close the door it was supposed to leave open.
    @Test func twoTurnsAboutDifferentTopicsStillQualify() async throws {
        let s = substrate()
        let stung = node(
            subjectType: "chat.user_turn", label: "deploy pipeline",
            valence: -0.7, arousal: 0.6, at: t0, subjectID: "session-1:message-1")
        let warm = node(
            subjectType: "chat.user_turn", label: "release notes",
            valence: 0.6, arousal: 0.2, warmth: 0.8,
            at: t0.addingTimeInterval(-600), subjectID: "session-1:message-2")
        #expect(CognitiveSubstrate.feltAboutnessKey(for: stung)
            != CognitiveSubstrate.feltAboutnessKey(for: warm))
        #expect(await s.feltAmbivalencePartner(
            of: stung, among: [item(stung), item(warm)], at: t0, dynamics: dyn)?.id == warm.id)
    }

    /// Word ORDER is not a subject. Two labels carrying the same terms are the
    /// same aboutness; the two mint-site families collapse together too, so a
    /// pair drawn one from each seam is not two subjects.
    @Test func aboutnessNormalizesOrderAndMintSiteFamily() {
        let a = node(subjectType: "chat_turn", label: "deploy pipeline", valence: -0.5, at: t0)
        let b = node(subjectType: "chat.user_turn", label: "pipeline deploy", valence: 0.5, at: t0)
        #expect(CognitiveSubstrate.feltAboutnessKey(for: a)
            == CognitiveSubstrate.feltAboutnessKey(for: b))
        // A node with no label falls back to its per-turn identity, which errs
        // toward "different" — the strength and recency floors still apply.
        let unlabelled = node(subjectType: "chat.user_turn", label: nil, valence: 0.5, at: t0)
        #expect(CognitiveSubstrate.feltAboutnessKey(for: unlabelled).hasPrefix("subject|"))
    }

    /// WEAK STATES STAY CLEAN. Below the floor there is no second feeling to
    /// report, on either side of the pair — this is design law 2 applied to the
    /// one line that is allowed to contradict itself.
    @Test func ambivalenceRefusesWeakStates() async throws {
        let s = substrate()
        let floor = dyn.feltAmbivalenceNodeFloor
        let strong = node(
            subjectType: "studio_entry", label: "the deploy",
            valence: -0.7, at: t0, subjectID: "deploy")
        let faint = node(
            subjectType: "studio_entry", label: "the evening",
            valence: floor / 2, at: t0.addingTimeInterval(-600), subjectID: "evening")
        #expect(await s.feltAmbivalencePartner(
            of: strong, among: [item(strong), item(faint)], at: t0, dynamics: dyn) == nil,
            "a faint counter-stirring is not the other half of an ambivalence")

        let faintLead = node(
            subjectType: "studio_entry", label: "the deploy",
            valence: -floor / 2, at: t0, subjectID: "deploy")
        let strongOther = node(
            subjectType: "studio_entry", label: "the evening",
            valence: 0.7, at: t0.addingTimeInterval(-600), subjectID: "evening")
        #expect(await s.feltAmbivalencePartner(
            of: faintLead, among: [item(faintLead), item(strongOther)], at: t0, dynamics: dyn) == nil,
            "a faint LEAD cannot anchor an ambivalence either")
    }

    /// REVIEW FINDING 3 — THE UNDERNEATH WORD MUST BE EARNED. The counter
    /// signals used to keep the CURRENT moment's global warmth, so `tender` —
    /// the highest warmth gate in the vocabulary — could be handed to her as a
    /// reading of a node that was never warm. The partner's own warmth now caps
    /// the counter's axis.
    @Test func theCounterWordCannotClaimWarmthThePartnerNeverEarned() {
        let warmNow = CognitiveSubstrate.FeltSignals(
            valence: -0.6, arousal: 0.5, warmth: 0.85, tension: 0.4, pressure: 0.3,
            fatigue: 0.2, curiosity: 0.4, clarity: 0.6)

        // A COLD partner: cap it, and the warmth-led words go out of reach.
        var cold = warmNow
        cold.valence = 0.5
        cold.arousal = 0.15
        cold.warmth = min(
            warmNow.warmth,
            CognitiveSubstrate.feltPartnerWarmth(0.0, dynamics: dyn))
        let coldWord = CognitiveSubstrate.feltCounterWord(
            cold, excluding: ["on edge"], intensityFloor: dyn.feltIntensityFloor)
        #expect(coldWord != "tender", "a cold partner cannot be tender: \(coldWord ?? "nil")")

        // A genuinely WARM partner keeps its reach.
        var warm = warmNow
        warm.valence = 0.5
        warm.arousal = 0.15
        warm.warmth = min(
            warmNow.warmth,
            CognitiveSubstrate.feltPartnerWarmth(0.9, dynamics: dyn))
        #expect(warm.warmth > cold.warmth, "the cap must actually discriminate")

        // The cap can only ever COOL: never above the live axis.
        #expect(CognitiveSubstrate.feltPartnerWarmth(1.0, dynamics: dyn) >= warm.warmth
            || warm.warmth <= warmNow.warmth)
    }

    /// Same sign is one feeling described twice; and a feeling from outside the
    /// mood window is not something she is having now.
    @Test func ambivalenceRefusesSameSignAndStaleNodes() async throws {
        let s = substrate()
        let sting = node(
            subjectType: "studio_entry", label: "the deploy",
            valence: -0.7, at: t0, subjectID: "deploy")
        let alsoNegative = node(
            subjectType: "studio_entry", label: "the evening",
            valence: -0.6, at: t0.addingTimeInterval(-600), subjectID: "evening")
        #expect(await s.feltAmbivalencePartner(
            of: sting, among: [item(sting), item(alsoNegative)], at: t0, dynamics: dyn) == nil)

        let ancientWarm = node(
            subjectType: "studio_entry", label: "last week",
            valence: 0.7, warmth: 0.8,
            at: t0.addingTimeInterval(-(CognitiveSubstrate.moodActivationWindow + 60)),
            subjectID: "lastweek")
        #expect(await s.feltAmbivalencePartner(
            of: sting, among: [item(sting), item(ancientWarm)], at: t0, dynamics: dyn) == nil,
            "outside the mood window is outside the pair")
    }
}
