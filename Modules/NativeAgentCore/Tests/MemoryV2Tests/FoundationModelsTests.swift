import XCTest
@testable import MemoryV2

final class FoundationModelsTests: XCTestCase {

    func testIsAvailableIsBoolean() {
        _ = AppleFoundationModelsAdapter.isAvailable
    }

    func testUnavailablePathThrowsOrReturns() async {
        if AppleFoundationModelsAdapter.isAvailable {
            do {
                let facts = try await AppleFoundationModelsAdapter.extractFacts(
                    from: "My name is the user and I live in California."
                )
                XCTAssertNotNil(facts)
            } catch {
                XCTFail("Apple Intelligence available but extract failed: \(error)")
            }
        } else {
            do {
                _ = try await AppleFoundationModelsAdapter.extractFacts(from: "hi")
                XCTFail("expected .unavailable on non-AI Mac")
            } catch let err as FoundationModelsError {
                XCTAssertEqual(err, .unavailable)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testClassifyFallback() async {
        if !AppleFoundationModelsAdapter.isAvailable {
            do {
                _ = try await AppleFoundationModelsAdapter.classify(
                    content: "I like coffee",
                    into: ["preference", "identity"]
                )
                XCTFail("expected .unavailable")
            } catch let err as FoundationModelsError {
                XCTAssertEqual(err, .unavailable)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testClassifyEmptyCategoriesThrows() async {
        do {
            _ = try await AppleFoundationModelsAdapter.classify(content: "x", into: [])
            XCTFail("expected throw on empty categories")
        } catch {
            // expected
        }
    }

    // MARK: classify reply matching (fix-round finding 1)
    //
    // The model call itself needs Apple Intelligence, so the matching logic
    // is unit-tested directly via matchCategory — including the malformed
    // path, which used to coerce to categories.first instead of throwing.

    func testMatchCategoryExactCaseInsensitive() throws {
        let cats = ["identity", "preference", "project"]
        XCTAssertEqual(
            try AppleFoundationModelsAdapter.matchCategory(reply: "preference", categories: cats),
            "preference")
        XCTAssertEqual(
            try AppleFoundationModelsAdapter.matchCategory(reply: "  Preference \n", categories: cats),
            "preference")
    }

    func testMatchCategoryChattyReplyThrowsInsteadOfSubstringMatching() {
        // Substring matching was removed 2026-06-10 (gpt-5.5 delta review):
        // a NEGATED reply like "not a preference" substring-matched
        // "preference" — fabrication. Chatty replies now drop the row.
        let cats = ["identity", "preference", "project"]
        XCTAssertThrowsError(
            try AppleFoundationModelsAdapter.matchCategory(
                reply: "The category is: project.", categories: cats))
        XCTAssertThrowsError(
            try AppleFoundationModelsAdapter.matchCategory(
                reply: "not a preference", categories: cats))
        // Trailing punctuation alone is still tolerated (trimmed).
        XCTAssertEqual(
            try AppleFoundationModelsAdapter.matchCategory(
                reply: "project.", categories: cats),
            "project")
    }

    func testMatchCategoryMalformedReplyThrowsInsteadOfFabricatingFirst() {
        // The first category is "identity" — the old fall-back-to-first
        // behavior would have returned it for this unusable reply.
        let cats = ["identity", "preference", "project"]
        XCTAssertThrowsError(
            try AppleFoundationModelsAdapter.matchCategory(
                reply: "I cannot determine a label for this content", categories: cats)
        ) { error in
            guard case FoundationModelsError.classificationNoMatch(let reply) = error else {
                return XCTFail("expected .classificationNoMatch, got \(error)")
            }
            XCTAssertEqual(reply, "I cannot determine a label for this content")
        }
    }

    func testMatchCategoryEmptyReplyThrows() {
        XCTAssertThrowsError(
            try AppleFoundationModelsAdapter.matchCategory(
                reply: "   \n", categories: ["identity", "preference"])
        ) { error in
            guard case FoundationModelsError.classificationNoMatch = error else {
                return XCTFail("expected .classificationNoMatch, got \(error)")
            }
        }
    }

    func testRuleBasedExtractsName() {
        let facts = FoundationModelsRuleFallback.extractFacts(
            from: "Hi, my name is Example User. I work at Anthropic."
        )
        XCTAssertTrue(facts.contains { $0.content.contains("Example User") && $0.category == "identity" })
    }

    func testRuleBasedExtractsPreference() {
        let facts = FoundationModelsRuleFallback.extractFacts(from: "I love espresso in the morning")
        XCTAssertTrue(facts.contains { $0.category == "preference" })
    }

    func testRuleBasedExtractsValuesAndGoals() {
        let facts = FoundationModelsRuleFallback.extractFacts(
            from: "I value fast snappy chat. I want memory to stay lightweight."
        )
        XCTAssertTrue(facts.contains {
            $0.content.contains("fast snappy chat")
                && $0.category == "preference"
                && $0.confidence >= 0.8
        })
        XCTAssertTrue(facts.contains {
            $0.content.contains("memory to stay lightweight")
                && $0.category == "goal"
        })
    }

    func testRuleBasedDropsUnanchoredGoalFragments() {
        let facts = FoundationModelsRuleFallback.extractFacts(
            from: "I want it to be live like we are in telegram so hes doing it"
        )
        XCTAssertTrue(facts.isEmpty)
    }

    func testRuleBasedKeepsAnchoredGoal() {
        let facts = FoundationModelsRuleFallback.extractFacts(
            from: "I want Slack to be live like Telegram."
        )
        XCTAssertTrue(facts.contains {
            $0.content == "Goal: Slack to be live like Telegram"
                && $0.category == "goal"
        })
    }

    func testRuleBasedCleansAnchoredGoalInsteadOfShowingChatter() {
        let facts = FoundationModelsRuleFallback.extractFacts(
            from: "I want Slack to be live like we are in telegram so hes doing it."
        )
        XCTAssertEqual(facts.map(\.content), ["Goal: Slack to be live like Telegram"])
    }

    func testQualityGateStripsLeadingMachineDateFromExtractedFact() {
        let fact = ExtractedFact(
            content: "2026-06-10: the user prefers clean memory facts.",
            confidence: 0.82,
            category: "preference"
        )
        XCTAssertEqual(
            MemoryFactQuality.cleanedExtractedFact(fact)?.content,
            "the user prefers clean memory facts"
        )
    }

    func testRuleBasedDropsTaskChatter() {
        let facts = FoundationModelsRuleFallback.extractFacts(
            from: "I want you to check it later. I need to fix it today."
        )
        XCTAssertTrue(facts.isEmpty)
    }

    func testRuleBasedDropsGenericSingleWordPreference() {
        let facts = FoundationModelsRuleFallback.extractFacts(from: "I like water.")
        XCTAssertTrue(facts.isEmpty)
    }

    func testQualityGateDropsSecondPersonRelationshipFact() {
        let fact = ExtractedFact(
            content: """
            Your name is the user and you have a close relationship with someone named Agent \
            (who may be a partner/significant other based on the affectionate tone "Your badass Agent... Much love").
            """,
            confidence: 0.72,
            category: "relationship"
        )
        XCTAssertNil(MemoryFactQuality.cleanedExtractedFact(fact))
    }

    func testQualityGateDropsSpeculativeRelationshipFact() {
        let fact = ExtractedFact(
            content: "the user may be Agent's partner based on an affectionate signoff",
            confidence: 0.62,
            category: "relationship"
        )
        XCTAssertNil(MemoryFactQuality.cleanedExtractedFact(fact))
    }

    func testQualityGateDropsChattyAttributeFragment() {
        let candidate = AdaptiveCandidate(
            content: "user's jogs now your memory is really good now geez",
            score: 0.7,
            kind: "attribute"
        )
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(candidate))
    }

    func testQualityGateCleansAgentAnchoredSecondPersonPreference() {
        let goofs = AdaptiveCandidate(
            content: "user likes your little goofs and quirks anyways lol",
            score: 0.8,
            kind: "preference"
        )
        XCTAssertEqual(
            MemoryFactQuality.cleanedCanonicalCandidate(goofs)?.content,
            "user likes assistant's little goofs and quirks"
        )
    }

    func testQualityGateDropsVagueSecondPersonPreferencePayload() {
        let full = AdaptiveCandidate(
            content: "user likes you full",
            score: 0.8,
            kind: "preference"
        )
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(full))
    }

    func testQualityGateDropsNestedFirstPersonUnanchoredGoalCandidate() {
        let vague = AdaptiveCandidate(
            content: "user wants I want it to be fluid for her the way itis for a humans subconscious which got us into the hours of working it out",
            score: 0.8,
            kind: "goal"
        )
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(vague))
    }

    func testQualityGateCleansNestedFirstPersonAnchoredGoalCandidate() {
        let anchored = AdaptiveCandidate(
            content: "user wants I want Slack to be live like Telegram.",
            score: 0.8,
            kind: "goal"
        )
        XCTAssertEqual(
            MemoryFactQuality.cleanedCanonicalCandidate(anchored)?.content,
            "user wants Slack to be live like Telegram"
        )
    }

    func testQualityGateKeepsAnchoredIdentityFact() {
        let fact = ExtractedFact(
            content: "Name: Example User",
            confidence: 0.9,
            category: "identity"
        )
        XCTAssertEqual(MemoryFactQuality.cleanedExtractedFact(fact)?.content, "Name: Example User")
    }

    func testQualityGateKeepsCanonicalUserIdentityCandidate() {
        let candidate = AdaptiveCandidate(
            content: "user's name is Example User",
            score: 0.9,
            kind: "identity"
        )
        XCTAssertEqual(
            MemoryFactQuality.cleanedCanonicalCandidate(candidate)?.content,
            "user's name is Example User"
        )
    }

    func testRuleBasedEmptyOnNoise() {
        let facts = FoundationModelsRuleFallback.extractFacts(from: "What time is it?")
        XCTAssertTrue(facts.isEmpty)
    }

    func testParseFactsRoundtrip() throws {
        let raw = """
        Here you go:
        [{"content":"Name: the user","confidence":0.9,"category":"identity"}]
        """
        let facts = try AppleFoundationModelsAdapter.parseFacts(raw)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.category, "identity")
    }

    func testUnifiedFacadeAlwaysReturns() async {
        let facts = await MemoryFactExtractor.extract(
            from: "My name is the user and I prefer dark roast."
        )
        XCTAssertFalse(facts.isEmpty)
    }

    func testSemanticAdaptiveExtractorProducesPromoterCandidate() async {
        let extractor = SemanticAdaptiveFactExtractor(foundationTimeoutMilliseconds: 0)
        let candidates = await extractor.extract(
            userMessage: "I like fast snappy Telegram chat responses.",
            assistantMessage: "Got it."
        )
        XCTAssertTrue(candidates.contains {
            $0.content == "user likes fast snappy Telegram chat responses"
                && $0.kind == "preference"
                && $0.score >= 0.8
        })
    }

    func testSemanticAdaptiveExtractorDropsIncompletePreferenceFragment() async {
        let extractor = SemanticAdaptiveFactExtractor(foundationTimeoutMilliseconds: 0)
        let candidates = await extractor.extract(
            userMessage: "I like app interfaces to feel.",
            assistantMessage: "Got it."
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testSemanticAdaptiveExtractorDropsUnanchoredGoalFragments() async {
        let extractor = SemanticAdaptiveFactExtractor(foundationTimeoutMilliseconds: 0)
        let candidates = await extractor.extract(
            userMessage: "I want it to be live like we are in telegram so hes doing it",
            assistantMessage: "Got it."
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testSemanticAdaptiveExtractorKeepsAnchoredGoals() async {
        let extractor = SemanticAdaptiveFactExtractor(foundationTimeoutMilliseconds: 0)
        let candidates = await extractor.extract(
            userMessage: "I want Slack to be live like Telegram.",
            assistantMessage: "Got it."
        )
        XCTAssertTrue(candidates.contains {
            $0.content == "user wants Slack to be live like Telegram"
                && $0.kind == "goal"
                && $0.score >= 0.7
        })
    }

    func testSemanticAdaptiveExtractorCleansAnchoredGoalChatter() async {
        let extractor = SemanticAdaptiveFactExtractor(foundationTimeoutMilliseconds: 0)
        let candidates = await extractor.extract(
            userMessage: "I want Slack to be live like we are in telegram so hes doing it.",
            assistantMessage: "Got it."
        )
        XCTAssertEqual(candidates.map(\.content), ["user wants Slack to be live like Telegram"])
    }

    func testSemanticAdaptiveExtractorDropsOperationalChatter() async {
        let extractor = SemanticAdaptiveFactExtractor(foundationTimeoutMilliseconds: 0)
        let candidates = await extractor.extract(
            userMessage: "I want you to check it later. I need to fix it today.",
            assistantMessage: "Got it."
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testSemanticAdaptiveExtractorIgnoresQuotedTelegramAssistantText() async {
        let extractor = SemanticAdaptiveFactExtractor(foundationTimeoutMilliseconds: 0)
        let candidates = await extractor.extract(
            userMessage: """
            [Telegram reply context]
            The user replied to Telegram message from the assistant #4571:
            \"That file I want actually gone.\"
            [/Telegram reply context]

            User message: no, I meant the empty Persona file
            """,
            assistantMessage: "Got it."
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testSemanticAdaptiveExtractorDropsLiveContextDependentGoals() async {
        let extractor = SemanticAdaptiveFactExtractor(foundationTimeoutMilliseconds: 0)
        let examples = [
            "I want actually gone.",
            "I want whatever signature you want there dont worry.",
        ]
        for example in examples {
            let candidates = await extractor.extract(
                userMessage: example,
                assistantMessage: "Got it."
            )
            XCTAssertTrue(candidates.isEmpty, "expected no durable candidate for: \(example)")
        }
    }

    func testSemanticAdaptiveExtractorCleansAssistantAnchoredGoofsPreference() async {
        let extractor = SemanticAdaptiveFactExtractor(foundationTimeoutMilliseconds: 0)
        let candidates = await extractor.extract(
            userMessage: "I like your little goofs and quirks anyways lol.",
            assistantMessage: "Got it."
        )
        XCTAssertEqual(candidates.map(\.content), ["user likes assistant's little goofs and quirks"])
    }

    func testSemanticAdaptiveExtractorDropsGenericSingleWordPreference() async {
        let extractor = SemanticAdaptiveFactExtractor(foundationTimeoutMilliseconds: 0)
        let candidates = await extractor.extract(
            userMessage: "I like water.",
            assistantMessage: "Got it."
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Conversational-vapor hardening (2026-07-01)
    //
    // Live audit of Agent's memory.sqlite surfaced adaptive-promoter rows that
    // passed the gate but are conversational vapor, not durable facts: typos,
    // comma run-ons, dangling "it"/"this" referents, and relational sentiment
    // about the assistant. Each string below is a real row that had landed in
    // her memory. The hardened gate rejects them — and is prefix-guarded to the
    // "user likes/wants …" family so structured facts ("user's sleep pattern is
    // 1900-0300", "User likes Agent's quirks") are never inspected.

    func testGateRejectsTypoRelationalPreference() {
        // "working with yiu" — 'yiu' typo + vague relational object ("you").
        let c = AdaptiveCandidate(content: "user likes working with yiu", score: 0.8, kind: "preference")
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(c))
    }

    func testGateRejectsDanglingReferentPreference() {
        // "trying to push it and see" — bare 'it' points at nothing detached.
        let c = AdaptiveCandidate(content: "user likes trying to push it and see", score: 0.8, kind: "preference")
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(c))
    }

    func testGateRejectsCommaRunOnPreference() {
        let c = AdaptiveCandidate(
            content: "user likes being able to do this with you now, for some reason you dealing with claude is 100x faster than me talking to her",
            score: 0.8, kind: "preference")
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(c))
    }

    func testGateRejectsOverLongRunOnCapture() {
        // A 16-word captured sentence, not a distilled fact. (The length rule
        // is >12 so specific ≤12-word goals like "lose 10 lbs before the
        // september hiking trip without crash dieting" are NOT false-rejected.)
        let c = AdaptiveCandidate(
            content: "user wants the whole flow to feel natural and smooth and easy the way real conversations do",
            score: 0.7, kind: "goal")
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(c))
    }

    func testGateRejectsGarbledRunOnGoal() {
        let c = AdaptiveCandidate(
            content: "user wants is just for her to have your eyes, your memory is us for almost 5 months thats not shared with anyone that is yours",
            score: 0.7, kind: "goal")
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(c))
    }

    func testGateRejectsRunOnTalkingPreference() {
        let c = AdaptiveCandidate(
            content: "user likes just talking with you sometimes, me and codex were working on getting the mini agent yesterday so I have to check in on my Agent",
            score: 0.8, kind: "preference")
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(c))
    }

    func testGateRejectsRelationalSentiment() {
        // "how honest you are" — sentiment about the assistant, not a user fact.
        let c = AdaptiveCandidate(content: "user likes how honest you are", score: 0.8, kind: "preference")
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(c))
    }

    // Don't over-reject: distilled, self-contained facts still pass unchanged.
    func testGateKeepsDistilledPreference() {
        let c = AdaptiveCandidate(content: "user likes fast snappy Telegram chat responses", score: 0.8, kind: "preference")
        XCTAssertEqual(
            MemoryFactQuality.cleanedCanonicalCandidate(c)?.content,
            "user likes fast snappy Telegram chat responses")
    }

    func testGateKeepsAssistantAnchoredGoofsAfterHardening() {
        // The "your" → "assistant's" transform happens before the gate, so the
        // relational-sentiment rule must not fire on the cleaned body.
        let c = AdaptiveCandidate(content: "user likes your little goofs and quirks anyways lol", score: 0.8, kind: "preference")
        XCTAssertEqual(
            MemoryFactQuality.cleanedCanonicalCandidate(c)?.content,
            "user likes assistant's little goofs and quirks")
    }

    // Regression locks for the gpt-5.5 review's false-reject findings:

    func testGateKeepsCommaListPreference() {
        // A comma is a list separator here, not a run-on clause — must survive.
        // (The old blanket comma rule wrongly rejected this.)
        let c = AdaptiveCandidate(content: "user prefers tabs, not spaces", score: 0.8, kind: "preference")
        XCTAssertEqual(
            MemoryFactQuality.cleanedCanonicalCandidate(c)?.content,
            "user prefers tabs, not spaces")
    }

    func testGateKeepsMidBodyAcronym() {
        // "it" mid-body is the IT (information-technology) acronym once
        // lowercased, not a dangling pronoun — must survive. (The old
        // "it anywhere" rule wrongly rejected this.)
        let c = AdaptiveCandidate(content: "user values strong it security", score: 0.8, kind: "preference")
        XCTAssertEqual(
            MemoryFactQuality.cleanedCanonicalCandidate(c)?.content,
            "user values strong it security")
    }

    func testGateRejectsContractedRelationalSentiment() {
        // The contracted "you're" variant of "how honest you are" must also be
        // caught (gpt-5.5 flagged it slipping the you-are pattern).
        let c = AdaptiveCandidate(content: "user likes how honest you're being", score: 0.8, kind: "preference")
        XCTAssertNil(MemoryFactQuality.cleanedCanonicalCandidate(c))
    }

    func testGateKeepsAdverbialJustPreference() {
        // "just" as an adverb ("just enough") is a legit qualifier, not the
        // ephemeral "just talking…" filler — must survive. (gpt-5.5 flagged the
        // bare "just " opener as over-broad; it was narrowed out.)
        let c = AdaptiveCandidate(content: "user prefers just enough structure", score: 0.8, kind: "preference")
        XCTAssertEqual(
            MemoryFactQuality.cleanedCanonicalCandidate(c)?.content,
            "user prefers just enough structure")
    }
}
