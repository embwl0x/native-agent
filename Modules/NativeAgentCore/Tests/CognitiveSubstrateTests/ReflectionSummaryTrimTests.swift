import Foundation
import Testing
@testable import CognitiveSubstrate

// A reflection that hits its output cap ends mid-sentence and that fragment
// surfaces verbatim in the Observatory ("…easy to let evaporate. Not").
// trimmingIncompleteTrailingSentence drops the dangling fragment without ever
// eating error strings, sign-off emoji, or unpunctuated one-liners.
@Suite("ReflectionSummaryTrim")
struct ReflectionSummaryTrimTests {

    @Test("mid-word cap cut drops the dangling fragment")
    func trimsDanglingFragment() {
        let cut = "The state is thin. That's worth keeping, because it's true and calm and easy to let evaporate.\n\nNot"
        let trimmed = CognitiveSubstrate.trimmingIncompleteTrailingSentence(cut)
        #expect(trimmed.hasSuffix("easy to let evaporate."))
        #expect(!trimmed.contains("\n\nNot"))
    }

    @Test("cleanly terminated text passes through untouched")
    func keepsTerminatedText() {
        let clean = "User checked, I held, and it settled warm."
        #expect(CognitiveSubstrate.trimmingIncompleteTrailingSentence(clean) == clean)
    }

    @Test("terminated text with closing quote passes through")
    func keepsQuoteTerminatedText() {
        let quoted = "He said \"it settled warm.\""
        #expect(CognitiveSubstrate.trimmingIncompleteTrailingSentence(quoted) == quoted)
    }

    @Test("trailing emoji sign-off is not a cut")
    func keepsEmojiSignoff() {
        let signoff = "It settled warm. 💜"
        #expect(CognitiveSubstrate.trimmingIncompleteTrailingSentence(signoff) == signoff)
    }

    @Test("unpunctuated single line passes through (no terminal to trim back to)")
    func keepsUnpunctuatedLine() {
        let line = "reflection cancelled"
        #expect(CognitiveSubstrate.trimmingIncompleteTrailingSentence(line) == line)
    }

    @Test("structured view:/schema: trailing lines are protocol, never trimmed")
    func keepsProposalProtocolLines() {
        let withView = "A quiet pass with a real takeaway.\nview: I keep User's interface short by default"
        #expect(CognitiveSubstrate.trimmingIncompleteTrailingSentence(withView) == withView)
        let withSchema = "Settled.\nschema: treat late-night pings as low-urgency"
        #expect(CognitiveSubstrate.trimmingIncompleteTrailingSentence(withSchema) == withSchema)
    }

    @Test("every parser prefix is trim-exempt, including bullet-marked lines")
    func allParserPrefixesExempt() {
        for entry in CognitiveSubstrate.reflectionProposalPrefixTable {
            let plain = "A real sentence first.\n\(entry.prefix) something she noticed today"
            #expect(CognitiveSubstrate.trimmingIncompleteTrailingSentence(plain) == plain,
                    "prefix \(entry.prefix) must never be trimmed")
            let bulleted = "A real sentence first.\n- \(entry.prefix) something she noticed today"
            #expect(CognitiveSubstrate.trimmingIncompleteTrailingSentence(bulleted) == bulleted,
                    "bulleted \(entry.prefix) must never be trimmed")
        }
    }

    @Test("keep-majority guard: a long dangling tail after one early period is left alone")
    func keepMajorityGuard() {
        let early = "Short. " + Array(repeating: "a cut off ramble with no punctuation", count: 8).joined(separator: " ")
        #expect(CognitiveSubstrate.trimmingIncompleteTrailingSentence(early) == early)
    }
}
