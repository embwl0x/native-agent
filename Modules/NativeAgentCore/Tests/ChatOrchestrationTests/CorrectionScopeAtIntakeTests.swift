import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore

@Suite("Correction scope at intake")
struct CorrectionScopeAtIntakeTests {
    @Test("a correction about the people or about authority stays global")
    func interpersonalAndAuthorityStayGlobal() {
        // Live atoms, verbatim subjects (data/context/context.sqlite, 2026-09-11).
        let global = [
            "Greet User's early-morning messages as the start of his day, never with bedtime nagging or late-night teasing.",
            "User wants my full emotional range: work-neutral can be neutral, tenderness is earned, and endearments land when the moment does.",
            "There is no blanket rule forbidding browsers for GitHub links; background work still must respect User's quiet-desktop boundary.",
        ]
        for text in global {
            #expect(CorrectionScopeAtIntake.isGloballyBinding(text))
            #expect(CorrectionScopeAtIntake.derivedTopics(correctionText: text).isEmpty)
        }
    }

    @Test("a boundary stays global even when its words name a tool family")
    func prohibitionLanguageNeverScopes() {
        // GPT-5.6 review 2026-09-11: `contact` activates the contacts route
        // group, so this scoped to contacts and went missing on the "email
        // Alice" turn it exists for.
        let boundary = "Never contact people unless explicitly asked."
        #expect(CorrectionScopeAtIntake.isGloballyBinding(boundary))
        #expect(CorrectionScopeAtIntake.derivedTopics(correctionText: boundary).isEmpty)
        // Not even with a contacts dispatch record behind it.
        #expect(
            CorrectionScopeAtIntake.derivedTopics(
                correctionText: boundary,
                turnToolNames: ["read_contacts", "send_email"]
            ).isEmpty
        )
    }

    @Test("no tool dispatch record means the correction stays global")
    func unknownDispatchStaysGlobal() {
        #expect(
            CorrectionScopeAtIntake.derivedTopics(
                correctionText: "When shared-tree changes disappear, inspect git stashes and"
                    + " reflogs before inventing an active-writer story."
            ).isEmpty
        )
    }

    @Test("the offered tool set is not dispatch evidence")
    func offeredToolsAreNotEvidence() async {
        // GPT-5.6 review 2026-09-11: the fallback was
        // `LLMCallContext.turnActiveTools` — everything the session had
        // offered or preloaded. Any mail tool ever offered then satisfied the
        // "this turn did mail work" check, and a send boundary could be scoped
        // to mail and vanish on the next differently worded request.
        let text = "Mail drafts go in plain text, not html."
        #expect(!CorrectionScopeAtIntake.isGloballyBinding(text))
        let offered = ToolPreloadHeuristics.predict(userMessage: text, surface: "chat")?
            .candidateTools ?? []
        #expect(!offered.isEmpty)
        let derived = await LLMCallContext.$turnActiveTools.withValue(offered) {
            CorrectionScopeAtIntake.derivedTopics(correctionText: text)
        }
        #expect(derived.isEmpty)
    }

    @Test("a correction about a tool or topic carries that topic")
    func taskSpecificGetsScoped() {
        // The turn that produced it actually dispatched the coding family.
        let prediction = ToolPreloadHeuristics.predict(
            userMessage: "When shared-tree changes disappear, inspect git stashes and"
                + " reflogs before inventing an active-writer story.",
            surface: "chat"
        )
        let topics = CorrectionScopeAtIntake.derivedTopics(
            correctionText: "When shared-tree changes disappear, inspect git stashes and"
                + " reflogs before inventing an active-writer story.",
            turnToolNames: prediction?.candidateTools ?? []
        )
        #expect(!topics.isEmpty)
        // The scope gate matches WORDS, so at least one derived phrase has to be
        // a word a later turn on the same subject would actually use.
        #expect(topics.contains { $0.contains("git") })
        #expect(topics.count <= CorrectionScopeAtIntake.maximumTopics)
    }

    @Test("nothing derivable leaves the correction global, exactly as today")
    func failsOpen() {
        #expect(CorrectionScopeAtIntake.derivedTopics(correctionText: "   ").isEmpty)
        #expect(
            CorrectionScopeAtIntake.derivedTopics(
                correctionText: "A fluent report cannot substitute for evidence.",
                turnToolNames: ["read_file"]
            ).isEmpty
        )
    }
}
