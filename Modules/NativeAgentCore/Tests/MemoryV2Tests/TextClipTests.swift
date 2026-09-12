import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore

// U3 wave-1 items 1+2 (2026-06-10): sentence/word-safe clipping + recall
// full-text surfacing + extraction never-mid-word invariant. All fixtures
// are in-memory / synthetic — no live data roots.

// MARK: - MemoryTextClip unit behavior

@Suite("MemoryTextClip — sentence/word-safe clipping")
struct TextClipSuite {

    @Test func shortTextPassesThroughUnchanged() {
        let s = "the user's favorite color is teal."
        #expect(MemoryTextClip.sentenceClip(s, cap: 200) == s)
        #expect(MemoryTextClip.wordClip(s, cap: 200) == s)
    }

    @Test func clipsAtLastSentenceBoundaryWithinCap() {
        let s = "First sentence here. Second sentence follows! Third sentence is the one that "
            + "runs well past the cap and should be dropped entirely from the clipped output"
        let clipped = MemoryTextClip.sentenceClip(s, cap: 60)
        #expect(clipped == "First sentence here. Second sentence follows!")
    }

    @Test func decimalPointsAreNotSentenceBoundaries() {
        let s = "The threshold is 0.92 for merges and 0.75 for staging which is generous enough for everything"
        let clipped = MemoryTextClip.sentenceClip(s, cap: 40)
        // No sentence terminator qualifies (the "." in 0.92/0.75 is followed
        // by a digit) → word-boundary fallback. The last token of the clip
        // must be a COMPLETE token of the source — not "0.7" out of "0.75".
        #expect(!clipped.isEmpty)
        #expect(s.hasPrefix(clipped))
        let sourceTokens = Set(s.split(separator: " ").map(String.init))
        let lastToken = clipped.split(separator: " ").last.map(String.init) ?? ""
        #expect(sourceTokens.contains(lastToken))
    }

    @Test func decimalAtPrefixEdgeIsNotASentenceBoundary() {
        // Review blocker (2026-06-10): cap lands exactly after the "0." of
        // "0.92" — the prefix ends "…is 0." and the OLD prefix-only scan
        // treated prefix-end as end-of-string, minting a fake sentence
        // boundary. The clip must validate the edge against the original
        // text (next char "9" → not a boundary) and fall back to a word
        // boundary instead of returning text ending "0.".
        let s = "threshold is 0.92 and the rest of this sentence keeps going past the cap"
        let cap = "threshold is 0.".count // prefix ends exactly at "0."
        let clipped = MemoryTextClip.sentenceClip(s, cap: cap)
        #expect(!clipped.hasSuffix("0."))
        #expect(clipped == "threshold is")
    }

    @Test func realSentenceEndAtPrefixEdgeStillClipsThere() {
        // Counterpart guard: a GENUINE sentence end that lands exactly at
        // the cap edge (next original char is whitespace) must still count.
        let s = "It works. Then this trailing text runs well past the cap for sure"
        let cap = "It works.".count
        #expect(MemoryTextClip.sentenceClip(s, cap: cap) == "It works.")
    }

    @Test func fallsBackToWordBoundaryWhenNoSentenceEnds() {
        let words = Array(repeating: "lorem ipsum dolor sit amet", count: 20)
            .joined(separator: " ")
        let clipped = MemoryTextClip.sentenceClip(words, cap: 100)
        #expect(clipped.count <= 100)
        // Last token must be a complete word from the source vocabulary.
        let lastToken = clipped.split(separator: " ").last.map(String.init) ?? ""
        #expect(["lorem", "ipsum", "dolor", "sit", "amet"].contains(lastToken))
    }

    @Test func giantSingleTokenHardCapsAtCap() {
        let token = String(repeating: "x", count: 500)
        let clipped = MemoryTextClip.sentenceClip(token, cap: 100)
        #expect(clipped.count == 100)
    }

    @Test func quotedSentenceEndIsABoundary() {
        let s = "He said \"ship it.\" Then the rest of this text keeps going for quite a while longer than the cap"
        let clipped = MemoryTextClip.sentenceClip(s, cap: 30)
        #expect(clipped == "He said \"ship it.\"")
    }

    @Test func wordSafeCaptureTrimsMidWordChop() {
        let source = "prefix alpha bravo charliedelta suffix" as NSString
        // Capture "alpha bravo charlie" — ends mid-word inside "charliedelta".
        let range = NSRange(location: 7, length: 19)
        let v = MemoryTextClip.wordSafeCapture(source, range: range)
        #expect(v == "alpha bravo")
    }

    @Test func wordSafeCapturePassesCleanCaptureThrough() {
        let source = "prefix alpha bravo suffix" as NSString
        let range = NSRange(location: 7, length: 11) // "alpha bravo"
        #expect(MemoryTextClip.wordSafeCapture(source, range: range) == "alpha bravo")
    }

    @Test func wordSafeCaptureDropsUnsalvageableSingleToken() {
        let source = ("prefix " + String(repeating: "y", count: 50)) as NSString
        let range = NSRange(location: 7, length: 20) // chopped inside the giant token
        #expect(MemoryTextClip.wordSafeCapture(source, range: range) == nil)
    }

    @Test func memoryDisplayTextStripsMachineDatePrefixesForOrdinaryFacts() {
        #expect(MemoryTextClip.memoryDisplayText(
            "2026-06-10: the user prefers clean memory facts.",
            kind: "fact"
        ) == "the user prefers clean memory facts.")
        #expect(MemoryTextClip.memoryDisplayText(
            "[2026-06-10T12:34:56Z] the user prefers clean memory facts.",
            kind: "preference"
        ) == "the user prefers clean memory facts.")
        #expect(MemoryTextClip.memoryDisplayText(
            "createdAt: 2026-06-10T12:34:56Z - the user prefers clean memory facts.",
            kind: "fact"
        ) == "the user prefers clean memory facts.")
    }

    @Test func memoryDisplayTextKeepsDatesForDateCriticalKinds() {
        let milestone = "2026-06-11: Claude restored commit_memory."
        #expect(MemoryTextClip.memoryDisplayText(milestone, kind: "milestone") == milestone)
        let schedule = "2026-06-20 08:30 Agent should check the handoff."
        #expect(MemoryTextClip.memoryDisplayText(schedule, kind: "schedule") == schedule)
    }
}

// MARK: - Item 1: recall surfaces full content, sentence-clipped previews

@Suite("Recall full-text (item 1)")
struct RecallFullTextSuite {

    private func makeActor() -> SwiftNativeMemoryV2 {
        SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 384),
            storage: InMemoryMemoryStorage()
        )
    }

    @Test func storeStripsLeadingMachineDateForOrdinaryMemory() async throws {
        let mem = makeActor()
        let record = try await mem.store(
            content: "2026-06-10: the user prefers clean memory facts.",
            source: "test",
            metadata: .object(["kind": .string("fact")])
        )
        #expect(record.text == "the user prefers clean memory facts.")
    }

    @Test func proposePreservesLeadingDateForMilestoneMemory() async throws {
        let mem = makeActor()
        let proposal = try await mem.propose(
            content: "2026-06-11: Claude restored commit_memory.",
            source: "test",
            kind: "milestone"
        )
        #expect(proposal.content == "2026-06-11: Claude restored commit_memory.")
    }

    @Test func proposeRejectsTransientSessionContextState() async throws {
        let mem = makeActor()
        await #expect(throws: (any Error).self) {
            _ = try await mem.propose(
                content: "user's session context is reset",
                source: "test",
                kind: "fact"
            )
        }
        #expect(try await mem.listProposals(status: "pending").isEmpty)
    }

    @Test func proposeRejectsRuntimeCapsuleAndToolTranscriptNoise() async throws {
        let mem = makeActor()
        for text in [
            "user’s session context is reset",
            "conversationFocus: Subconscious context is provisional runtime state",
            "toolObservation: read_file ok: # NativeAgent Continuous Cognitive Substrate",
            "Cognitive capsule: bounded runtime state with provenance.",
            "Private working state. Use lightly; do not quote.",
            "Focus: Stay with User's current message.",
            "Feeling: quiet activation, quiet uncertainty, quiet task pressure, quiet warmth.",
            "Thread: Reflection takeaway: stay present while User checks the capsule.",
        ] {
            await #expect(throws: (any Error).self) {
                _ = try await mem.propose(content: text, source: "test", kind: "fact")
            }
        }
        #expect(try await mem.listProposals(status: "pending").isEmpty)
    }

    @Test func proposeRejectsIncompleteSemanticPreferenceFragment() async throws {
        let mem = makeActor()
        await #expect(throws: (any Error).self) {
            _ = try await mem.propose(
                content: "user likes app interfaces to feel",
                source: "test",
                kind: "preference"
            )
        }
        #expect(try await mem.listProposals(status: "pending").isEmpty)
    }

    @Test func durableFactsAboutContextPreferencesStillPass() async throws {
        let mem = makeActor()
        let proposal = try await mem.propose(
            content: "the user prefers being told when a session context reset happens.",
            source: "test",
            kind: "preference"
        )
        #expect(proposal.content == "the user prefers being told when a session context reset happens.")
    }

    @Test func recallHitCarriesFullContentForShortRows() async throws {
        let mem = makeActor()
        let text = "the user prefers direct answers over hedging. He ships fast."
        _ = try await mem.store(content: text, source: "test")
        let result = try await mem.recall(MemoryV2RecallRequest(text: text, topK: 1))
        let hit = try #require(result.hits.first)
        #expect(hit.content == text)      // full text, untruncated
        #expect(hit.preview == text)      // short rows: preview == content
    }

    @Test func longRowContentIsSentenceCappedAt2000AndPreviewAt200() async throws {
        let sentence = "This is a complete sentence about the user's long-term project goals and context. "
        let text = String(repeating: sentence, count: 40).trimmingCharacters(in: .whitespaces) // ~3120 chars
        let mem = makeActor()
        _ = try await mem.store(content: text, source: "test")
        let result = try await mem.recall(MemoryV2RecallRequest(text: "project goals", topK: 1))
        let hit = try #require(result.hits.first)
        let content = try #require(hit.content)
        #expect(content.count <= memoryRecallContentCap)
        #expect(content.count > 1800)          // generous, not the old 200
        #expect(content.hasSuffix("."))        // sentence-safe end
        #expect(hit.preview.count <= memoryRecallPreviewCap)
        #expect(hit.preview.hasSuffix("."))    // preview sentence-clipped too
    }

    @Test func previewNeverEndsMidWord() async throws {
        // No sentence terminators at all → word-boundary fallback.
        let text = Array(repeating: "alpha bravo charlie delta echo", count: 30)
            .joined(separator: " ")
        let mem = makeActor()
        _ = try await mem.store(content: text, source: "test")
        let result = try await mem.recall(MemoryV2RecallRequest(text: "alpha bravo", topK: 1))
        let hit = try #require(result.hits.first)
        let lastToken = hit.preview.split(separator: " ").last.map(String.init) ?? ""
        #expect(["alpha", "bravo", "charlie", "delta", "echo"].contains(lastToken))
    }

    @Test func rankingAndRowSetAreUnchangedByContentSurfacing() async throws {
        // Guard for the plan's hard constraint: adding `content` must not
        // change which rows return or their order.
        let mem = makeActor()
        _ = try await mem.store(content: "the user's favorite color is teal", source: "test")
        _ = try await mem.store(content: "Pasta tastes better with garlic", source: "test")
        let result = try await mem.recall(MemoryV2RecallRequest(text: "the user's favorite color is teal", topK: 2))
        #expect(result.total == 2)
        #expect(result.hits.first?.preview.contains("teal") == true)
        #expect((result.hits.first?.score ?? 0) > 0.99)
    }
}

// MARK: - Item 2: extraction never ends mid-word, clause-extended captures

@Suite("Sentence-safe extraction (item 2)")
struct SentenceSafeExtractionSuite {

    private let vocabulary = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]

    private func longValue(chars: Int) -> String {
        var out: [String] = []
        var count = 0
        var i = 0
        while count < chars {
            let w = vocabulary[i % vocabulary.count]
            out.append(w)
            count += w.count + 1
            i += 1
        }
        return out.joined(separator: " ")
    }

    private func lastTokenIsWholeWord(_ content: String) -> Bool {
        let cleaned = content.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        guard let last = cleaned.split(separator: " ").last.map(String.init) else { return false }
        return vocabulary.contains(last.lowercased()) || last.lowercased() == "is"
    }

    // The promoter/FM-fallback capture cases that lived here are gone with the
    // extractors they covered (2026-09-11). `MemoryTextClip.wordSafeCapture` and
    // `sentenceClip` are still covered above, and the memory manager's statement
    // clipping is covered in MemoryManagerLaneTests.
}
