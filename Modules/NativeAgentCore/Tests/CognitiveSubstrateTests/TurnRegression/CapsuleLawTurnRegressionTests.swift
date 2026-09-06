import Foundation
import PersistenceCore
import Testing
@testable import CognitiveSubstrate

// MARK: - INVARIANT (2b) — WHAT THE CAPSULE MAY SAY, DRIVEN THROUGH A REAL TURN
//
// `FeltObjectAmbivalenceTests` and `InnerLineFloorLawTests` pin the individual
// gates. This file drives the ASSEMBLED capsule — real substrate, real events,
// real frozen read, the production `compileFrozenCapsule` path — and asserts
// the laws that only hold across the whole render:
//
//   * the felt line may name an object, and ONLY from a safe label;
//   * exactly one contradiction, and only under the two-node rule;
//   * `- Inner:` is SILENT without a relevant view or a never-surfaced takeaway
//     (measured: it rode 100% of 1,487 live capsules — a line on every turn is
//     a standing instruction, not a signal);
//   * `- Thread:` is COMPOSED from kind + safe object + a worded age, never the
//     seed's own sentence;
//   * the capsule stays inside its measured byte envelope;
//   * `How you feel:` never sits above a labelled line, because read
//     positionally a standing view then IS her stated feeling (measured on 184
//     of 1,487 capsules).
//
// Silent-failure class throughout: a wrong value with no error. Every one of
// these renders a perfectly plausible capsule when it is broken.

private let capsuleT0 = Date(timeIntervalSince1970: 1_756_000_000)

private func lawSubstrate(
    now: @escaping @Sendable () -> Date,
    capsuleInjection: Bool = true
) -> CognitiveSubstrate {
    CognitiveSubstrate(
        configuration: CognitiveConfiguration(
            enabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: capsuleInjection,
            affectEnabled: true,
            maximumActiveNodes: 64
        ),
        dependencies: CognitiveSubstrateDependencies(
            now: now, makeUUID: { UUID() }, userName: { "User" }
        )
    )
}

private func lawEvent(
    _ id: String,
    at instant: Date,
    summary: String,
    label: String? = nil,
    importance: Double = 0.9
) -> CognitiveEvent {
    CognitiveEvent(
        id: id,
        kind: .userMessageReceived,
        subject: CognitiveSubjectReference(
            type: "chat.user_turn", id: "session-1:\(id)", label: label
        ),
        sourceClass: .userStated,
        occurredAt: instant,
        summary: summary,
        importance: importance
    )
}

private func lawCapsule(
    _ mind: CognitiveSubstrate,
    at instant: Date,
    userMessage: String = "where did the rollout land",
    maximumCharacters: Int? = nil
) async -> CognitiveCapsule {
    let read = await mind.frozenRead(at: instant, currentSessionId: "session-1")
    return await mind.compileFrozenCapsule(
        CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: userMessage,
            sessionId: "session-1",
            mode: .inject,
            maximumCharacters: maximumCharacters,
            turnKind: .live
        ),
        from: read
    )
}

private func lines(_ capsule: CognitiveCapsule) -> [String] {
    capsule.dynamicContext
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
}

private func labelled(_ capsule: CognitiveCapsule, _ prefix: String) -> [String] {
    lines(capsule).filter { $0.hasPrefix(prefix) }
}

// MARK: - The felt line's object

@Suite("TurnRegression.CapsuleLaw.Object")
struct CapsuleFeltObjectTurnRegressionTests {

    private let dyn = PersonalityDynamicsConfiguration.default

    /// THE LEAK TEST, at the render. A user turn whose text carries a person's
    /// name, an email, a credential word and a redaction marker must produce an
    /// object that names NONE of them — the safe extractor runs at the MINT
    /// site, so the label is safe on disk and in every later read.
    @Test("no user private word can ever become the felt line's object")
    func noUserPrivateWordCanBecomeTheObject() {
        let unsafe = [
            "Sarah broke the deploy again",
            "email user@example.com about the outage",
            "rotate the anthropic deploy key before friday",
            "the ticket is at https://example.com/issues/4412",
            "[REDACTED_SECRET] is in the config",
            "don't mention Sarah Kensington",
            "my password is hunter2 and the account id is 99182",
        ]
        for text in unsafe {
            let label = CognitiveSubstrate.feltTopicLabel(from: text)
            if let label {
                let lowered = label.lowercased()
                for banned in [
                    "sarah", "kensington", "user@example.com", "example.com",
                    "anthropic", "deploy key", "redacted", "hunter2", "99182",
                    "password",
                ] {
                    #expect(
                        !lowered.contains(banned),
                        "the felt object leaked \"\(banned)\" from \"\(text)\" as \"\(label)\""
                    )
                }
                #expect(label == label.lowercased(),
                        "a label with capitals came from a name-shaped token")
                #expect(label.count <= 32, "over-length is a refusal, never a trim")
            }
        }
    }

    /// The allowlist is the gate (design law 8). Every subject type nobody
    /// vetted fails closed, so a new producer cannot quietly start naming
    /// objects nobody reviewed.
    @Test("only allowlisted subject types may name an object")
    func onlyAllowlistedSubjectTypesMayNameAnObject() {
        func node(_ type: String, label: String?) -> CognitiveNode {
            CognitiveNode(
                id: UUID(), kind: .conversationFocus,
                subjectReference: CognitiveSubjectReference(
                    type: type, id: UUID().uuidString, label: label
                ),
                activation: 0.9, salience: 0.9, confidence: 0.8, sourceClass: .userStated,
                createdAt: capsuleT0, lastActivatedAt: capsuleT0, decayHalfLife: 1_000_000,
                summary: "we shipped the register fix tonight", metadata: [:],
                emotionalValence: -0.6, emotionalArousal: 0.3, emotionalWarmth: 0.5
            )
        }
        // Vetted: a studio entry's label IS its work title.
        #expect(CognitiveSubstrate.feltObjectLabel(
            for: node("studio_entry", label: "the register fix"),
            maxCharacters: dyn.feltObjectMaximumLabelCharacters
        ) == "the register fix")

        // Never vetted, and — design law 3 — never her own output.
        for type in [
            "chat.assistant_turn", "chat.session", "tool", "provider",
            "app", "motor_action", "topic", "body", "dream",
        ] {
            #expect(
                CognitiveSubstrate.feltObjectLabel(
                    for: node(type, label: "the register fix"),
                    maxCharacters: dyn.feltObjectMaximumLabelCharacters
                ) == nil,
                "subject type \(type) was allowed to name an object"
            )
        }
    }

    /// The rendered capsule never contains the user's message body. The object
    /// is a LABEL; the summary is what the label is derived from and must never
    /// itself reach the prompt.
    @Test("the rendered capsule never contains the user's own sentence")
    func theRenderedCapsuleNeverContainsTheUsersSentence() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        let sentence = "Sarah broke the deploy and the key rotation is still pending"
        for index in 0..<4 {
            await mind.ingest(lawEvent(
                "turn-\(index)",
                at: capsuleT0.addingTimeInterval(Double(index)),
                summary: sentence
            ))
        }
        let capsule = await lawCapsule(mind, at: capsuleT0)
        #expect(!capsule.combined.contains(sentence))
        #expect(!capsule.combined.contains("Sarah"))
    }
}

// MARK: - One honest contradiction

@Suite("TurnRegression.CapsuleLaw.Ambivalence")
struct CapsuleAmbivalenceTurnRegressionTests {

    private let dyn = PersonalityDynamicsConfiguration.default

    private func node(
        subject: String,
        valence: Double,
        arousal: Double = 0.4,
        warmth: Double = 0.5
    ) -> CognitiveNode {
        CognitiveNode(
            id: UUID(), kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(
                type: "chat.user_turn", id: subject, label: nil
            ),
            activation: 0.9, salience: 0.9, confidence: 0.8, sourceClass: .userStated,
            createdAt: capsuleT0, lastActivatedAt: capsuleT0, decayHalfLife: 1_000_000,
            summary: "a moment", metadata: [:],
            emotionalValence: valence, emotionalArousal: arousal, emotionalWarmth: warmth
        )
    }

    private func item(_ node: CognitiveNode) -> CognitiveWorkspaceItem {
        CognitiveWorkspaceItem(node: node, score: node.activation, reasons: ["recency"])
    }

    /// ALL FOUR conditions, together, or there is no contradiction. This is the
    /// one place the capsule is allowed to disagree with itself, and what makes
    /// it honest rather than a broken gauge is that the two words are readings
    /// of DIFFERENT subjects.
    @Test("a contradiction needs opposite signs, two subjects, and both over the floor")
    func aContradictionNeedsAllFourConditions() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        let dominant = node(subject: "session-1:a", valence: -0.6)

        // Same subject, opposite sign: a gauge fault, not ambivalence.
        let sameSubject = node(subject: "session-1:a", valence: 0.6)
        #expect(await mind.feltAmbivalencePartner(
            of: dominant, among: [item(dominant), item(sameSubject)],
            at: capsuleT0, dynamics: dyn
        ) == nil)

        // Different subject, but below the floor: two faint stirrings are not
        // a contradiction.
        let faint = node(subject: "session-1:b", valence: dyn.feltAmbivalenceNodeFloor / 2)
        #expect(await mind.feltAmbivalencePartner(
            of: dominant, among: [item(dominant), item(faint)],
            at: capsuleT0, dynamics: dyn
        ) == nil)

        // Different subject, SAME sign: agreement, not conflict.
        let agreeing = node(subject: "session-1:c", valence: -0.5)
        #expect(await mind.feltAmbivalencePartner(
            of: dominant, among: [item(dominant), item(agreeing)],
            at: capsuleT0, dynamics: dyn
        ) == nil)

        // All four hold: 1 AM after a night of restarts is fond AND irritated.
        let honest = node(subject: "session-1:d", valence: 0.55, warmth: 0.8)
        let partner = await mind.feltAmbivalencePartner(
            of: dominant, among: [item(dominant), item(honest)],
            at: capsuleT0, dynamics: dyn
        )
        #expect(partner?.id == honest.id, "the one honest contradiction did not fire")
    }

    /// ONE contradiction, never two. Two counter-words on one line stop being a
    /// reading and start being a sentence.
    @Test("at most one contradiction is ever chosen, however many candidates exist")
    func atMostOneContradictionIsEverChosen() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        let dominant = node(subject: "session-1:a", valence: -0.7)
        let candidates = (0..<5).map { node(subject: "session-1:c\($0)", valence: 0.5) }
        let partner = await mind.feltAmbivalencePartner(
            of: dominant, among: ([dominant] + candidates).map(item),
            at: capsuleT0, dynamics: dyn
        )
        // A single node, or none — never a list.
        #expect(candidates.map(\.id).contains(where: { $0 == partner?.id }) || partner == nil)
    }

    /// The rendered capsule can carry at most one `underneath`, because the
    /// contradiction is a word on the felt line, not a second line.
    @Test("a rendered capsule never carries two contradictions")
    func aRenderedCapsuleNeverCarriesTwoContradictions() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        for index in 0..<6 {
            await mind.ingest(lawEvent(
                "turn-\(index)",
                at: capsuleT0.addingTimeInterval(Double(index) * 30),
                summary: index % 2 == 0
                    ? "this is genuinely great work, thank you"
                    : "that is wrong and you keep getting it wrong"
            ))
        }
        let capsule = await lawCapsule(mind, at: capsuleT0.addingTimeInterval(200))
        let occurrences = capsule.combined.components(separatedBy: "underneath").count - 1
        #expect(occurrences <= 1, "the capsule contradicted itself twice")
    }
}

// MARK: - The Inner / Thread line

@Suite("TurnRegression.CapsuleLaw.InnerAndThread")
struct CapsuleInnerAndThreadTurnRegressionTests {

    /// THE FLOOR LAW (design law 2). A mind with no relevant standing view and
    /// no fresh takeaway says nothing on that line — and the rest of the
    /// capsule still speaks. Measured before the fix: `- Inner:` rode 100% of
    /// 1,487 live capsules with 23 distinct texts.
    @Test("Inner is silent without a relevant view or a never-surfaced takeaway")
    func innerIsSilentWithoutARelevantViewOrAFreshTakeaway() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        for index in 0..<4 {
            await mind.ingest(lawEvent(
                "turn-\(index)",
                at: capsuleT0.addingTimeInterval(Double(index)),
                summary: "the rollout keeps slipping and it is wearing on me"
            ))
        }
        let capsule = await lawCapsule(mind, at: capsuleT0)
        #expect(
            labelled(capsule, "- Inner:").isEmpty,
            "a fresh mind with no signed views spoke an Inner line anyway"
        )
    }

    /// At most ONE of the two, ever — they share one rotation ledger, so a nag
    /// can never outrank a worldview and the capsule never carries both.
    @Test("a capsule carries at most one Inner-or-Thread line")
    func aCapsuleCarriesAtMostOneInnerOrThreadLine() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        for index in 0..<8 {
            await mind.ingest(lawEvent(
                "turn-\(index)",
                at: capsuleT0.addingTimeInterval(Double(index) * 120),
                summary: "the deploy pipeline is still unexplained and it bothers me"
            ))
        }
        let capsule = await lawCapsule(mind, at: capsuleT0.addingTimeInterval(9 * 3_600))
        let count = labelled(capsule, "- Inner:").count + labelled(capsule, "- Thread:").count
        #expect(count <= 1, "the capsule carried both an Inner and a Thread line")
    }

    /// THE LEAK TEST for the nag. `- Thread:` is COMPOSED from three things —
    /// the kind of unfinished thing, a safe object label, and a WORDED age. The
    /// seed's own sentence is read only to derive the label and is never
    /// rendered; no safe label means no line, because the alternatives were
    /// bare noise or a leak.
    @Test("Thread renders a composed abstract and never the seed's own text")
    func threadRendersAnAbstractNeverTheSeedText() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        let seedText = "why did Sarah's rollout of the deploy pipeline stall on friday"
        let seed = CognitiveThoughtSeed(
            id: UUID(),
            kind: .openQuestion,
            text: seedText,
            priority: 0.8,
            createdAt: capsuleT0.addingTimeInterval(-30 * 3_600),
            lastUpdatedAt: capsuleT0.addingTimeInterval(-30 * 3_600)
        )
        let line = await mind.threadLine(for: seed, at: capsuleT0)
        if let line {
            #expect(line.hasPrefix("- Thread: "))
            #expect(!line.contains(seedText), "the Thread line quoted the seed")
            #expect(!line.contains("Sarah"), "the Thread line leaked a name")
            #expect(line.contains("unanswered "), "the age has to be worded")
            // Digits are a machine's way of saying it; the Body line already
            // refuses them and the Thread line reads the same way.
            let hasDigit = line.contains { $0.isNumber }
            #expect(!hasDigit, "the Thread line spelled a number")
            #expect(line.count <= 180)
        }
    }

    /// A reflection takeaway can never become a Thread line: it is a conclusion
    /// she already reached, not something unfinished that is carrying weight.
    @Test("a reflection takeaway can never be a Thread line")
    func aReflectionTakeawayCanNeverBeAThreadLine() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        let seed = CognitiveThoughtSeed(
            id: UUID(),
            kind: .reflectionTakeaway,
            text: "the rollout pipeline needs a receipt before a claim",
            priority: 0.9,
            createdAt: capsuleT0.addingTimeInterval(-48 * 3_600),
            lastUpdatedAt: capsuleT0.addingTimeInterval(-48 * 3_600)
        )
        #expect(await mind.threadLine(for: seed, at: capsuleT0) == nil)
    }

    /// A seed whose text yields no safe object gets NO line — silence, never a
    /// bare "something is unresolved" and never the sentence itself.
    @Test("a seed with no safe object label produces no Thread line at all")
    func aSeedWithoutASafeLabelProducesNoLine() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        let seed = CognitiveThoughtSeed(
            id: UUID(),
            kind: .anomaly,
            text: "AWS_KEY=abcd1234 j@x.io",
            priority: 0.9,
            createdAt: capsuleT0.addingTimeInterval(-40 * 3_600),
            lastUpdatedAt: capsuleT0.addingTimeInterval(-40 * 3_600)
        )
        #expect(await mind.threadLine(for: seed, at: capsuleT0) == nil)
    }
}

// MARK: - The header, and the byte envelope

@Suite("TurnRegression.CapsuleLaw.HeaderAndBytes")
struct CapsuleHeaderAndBytesTurnRegressionTests {

    /// `How you feel:` is a promise that the next thing is her FEELING WORDS.
    /// Measured: the capsule shipped that header with an `- Inner:` reflection
    /// directly under it on 184 of 1,487 capsules (12.4%) — read positionally,
    /// a standing view then IS her stated feeling.
    @Test("the header never sits above a labelled line")
    func theHeaderNeverSitsAboveALabelledLine() {
        let header = "How you feel:"
        #expect(
            CognitiveSubstrate.capsuleStableKernel(header, dynamicLines: ["- Inner: a view"])
                .isEmpty,
            "the header labelled a standing view as a feeling"
        )
        #expect(
            CognitiveSubstrate.capsuleStableKernel(header, dynamicLines: ["- Body: worn"])
                .isEmpty
        )
        #expect(
            CognitiveSubstrate.capsuleStableKernel(header, dynamicLines: ["- Thread: a loose end"])
                .isEmpty
        )
        // Feeling words first → the header means exactly what it says.
        #expect(
            CognitiveSubstrate.capsuleStableKernel(
                header, dynamicLines: ["focused, curious", "- Inner: a view"]
            ) == header
        )
        // No lines at all → nothing to promise, and the kernel is returned
        // unchanged rather than silently emptied.
        #expect(CognitiveSubstrate.capsuleStableKernel(header, dynamicLines: []) == header)
    }

    /// The same law through the real render: whenever the capsule opens on a
    /// labelled line, there is no header above it.
    @Test("a rendered capsule that opens on a labelled line carries no header")
    func aRenderedCapsuleOpeningOnALabelledLineCarriesNoHeader() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        for index in 0..<4 {
            await mind.ingest(lawEvent(
                "turn-\(index)",
                at: capsuleT0.addingTimeInterval(Double(index)),
                summary: "the rollout keeps slipping"
            ))
        }
        let capsule = await lawCapsule(mind, at: capsuleT0)
        if capsule.dynamicContext.hasPrefix("- ") {
            #expect(
                capsule.stableKernel.isEmpty,
                "the header promised feeling words and then labelled something else"
            )
        }
    }

    /// THE BYTE ENVELOPE. Measured across 1,487 live capsules: median 507 B,
    /// p95 672 B, max 769 B for the `[CognitiveSubstrate]` block. A render that
    /// blew past that envelope would be pushing the user's own message toward
    /// the window edge every turn — silently.
    @Test("the compiled capsule stays inside its measured p95 envelope")
    func theCompiledCapsuleStaysInsideItsMeasuredEnvelope() async {
        // The measured p95 (672 B), rounded up to the next 64-byte step so an
        // ordinary render has room without the bound becoming decorative.
        let p95Cap = 768
        let mind = lawSubstrate(now: { capsuleT0 })
        for index in 0..<24 {
            await mind.ingest(lawEvent(
                "turn-\(index)",
                at: capsuleT0.addingTimeInterval(Double(index) * 45),
                summary: "the rollout keeps slipping and the pipeline is unexplained"
            ))
        }
        let capsule = await lawCapsule(mind, at: capsuleT0.addingTimeInterval(1_200))
        #expect(
            capsule.combined.utf8.count <= p95Cap,
            "the capsule grew past its measured envelope: \(capsule.combined.utf8.count) B"
        )
    }

    /// The configured cap is a HARD bound, and overrunning it is reported as a
    /// truncation rather than silently swallowed.
    @Test("a tight budget truncates from the end and says that it did")
    func aTightBudgetTruncatesFromTheEndAndReportsIt() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        for index in 0..<12 {
            await mind.ingest(lawEvent(
                "turn-\(index)",
                at: capsuleT0.addingTimeInterval(Double(index) * 60),
                summary: "the rollout keeps slipping and the pipeline is unexplained"
            ))
        }
        let tight = await lawCapsule(
            mind, at: capsuleT0.addingTimeInterval(900), maximumCharacters: 40
        )
        #expect(tight.combined.count <= 40)
        let full = await lawCapsule(mind, at: capsuleT0.addingTimeInterval(900))
        if full.combined.count > 40 {
            #expect(tight.truncated, "a capsule that lost lines to the budget said nothing about it")
        }
    }

    /// A zero budget is an honest empty, not a fragment. A half-rendered felt
    /// line would read as a whole one.
    @Test("a zero budget renders nothing at all")
    func aZeroBudgetRendersNothingAtAll() async {
        let mind = lawSubstrate(now: { capsuleT0 })
        await mind.ingest(lawEvent("turn-0", at: capsuleT0, summary: "the rollout slipped"))
        let capsule = await lawCapsule(mind, at: capsuleT0, maximumCharacters: 0)
        #expect(capsule.stableKernel.isEmpty)
        #expect(capsule.dynamicContext.isEmpty)
        #expect(capsule.truncated)
    }
}
