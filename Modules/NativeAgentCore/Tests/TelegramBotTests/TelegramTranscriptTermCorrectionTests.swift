import Testing
import Foundation
@testable import TelegramBot

/// W5 L1#11: voice transcripts mangle this install's domain nouns. The pass is
/// TRANSCRIPT-ONLY, word-boundary, and case-insensitive — these tests pin all
/// three properties, plus the no-substring-overreach guard.
@Suite("Telegram transcript term correction")
struct TelegramTranscriptTermCorrectionTests {
    /// "get help" is ordinary English ("get help from codex") — correcting it
    /// corrupts meaning, so it stays OUT of the table on purpose (Claude,
    /// W5 fix-round). This pin keeps a future sweep from re-adding it.
    @Test func ordinaryEnglishGetHelpIsNeverCorrected() {
        let result = TelegramTranscriptTermCorrection.correct("can you get help from codex on this")
        #expect(!result.text.contains("GitHub"))
        #expect(result.text.contains("get help"))
        // "codex" case-normalizes independently — that part still fires.
        #expect(result.text.contains("Codex"))
    }

    @Test func eachManglingCorrectsToCanonicalSpelling() {
        let cases: [(String, String)] = [
            ("tell kodex to look at it", "tell Codex to look at it"),
            ("kodak already has the branch", "Codex already has the branch"),
            ("ayla pinged me twice", "Agent pinged me twice"),
            ("check gate hub for the PR", "check GitHub for the PR"),
            ("its on git hub already", "its on GitHub already"),
            ("open native agent and look", "open NativeAgent and look"),
            ("cortina can handle that", "Claude can handle that"),
            ("ask cor tana to verify", "Ask Claude to verify"),
            ("kimmy is the default model", "Kimi is the default model"),
            ("did sparkle ship the update", "did Sparkle ship the update"),
        ]
        for (heard, expected) in cases {
            let result = TelegramTranscriptTermCorrection.correct(heard)
            #expect(result.text.lowercased() == expected.lowercased(),
                    "\(heard) -> \(result.text)")
            #expect(result.correctedCount >= 1, "no correction counted for: \(heard)")
            #expect(result.original == heard)
        }
    }

    @Test func caseInsensitiveAndCanonicalCasingIsFree() {
        #expect(TelegramTranscriptTermCorrection.correct("KODEX broke").text == "Codex broke")
        #expect(TelegramTranscriptTermCorrection.correct("Ayla and Kodex").text == "Agent and Codex")
        // Already-canonical text corrects nothing and counts nothing.
        let clean = TelegramTranscriptTermCorrection.correct("Codex opened a GitHub PR for NativeAgent")
        #expect(clean.text == "Codex opened a GitHub PR for NativeAgent")
        #expect(clean.correctedCount == 0)
        #expect(clean.marker == nil)
        #expect(!clean.didCorrect)
    }

    @Test func noSubstringOverreach() {
        // The canonical guard: word boundaries only.
        let samples = [
            "decode the payload",
            "the codebase is fine",
            "we need better codecs for this audio",
            "islands and aylanders are not names here",
            "kimono",
            "sparkles everywhere",
            "cortinas are cars",
        ]
        for sample in samples {
            let result = TelegramTranscriptTermCorrection.correct(sample)
            #expect(result.text == sample, "overreach on: \(sample) -> \(result.text)")
            #expect(result.correctedCount == 0)
        }
    }

    @Test func markerCountsOccurrencesAndStaysOutOfVisibleText() {
        let result = TelegramTranscriptTermCorrection.correct("kodex and kodak and ayla")
        #expect(result.correctedCount == 3)
        #expect(result.marker == "[transcript corrected: 3 terms]")
        #expect(!result.text.contains("[transcript corrected"))
        #expect(result.text == "Codex and Codex and Agent")
    }

    @Test func emptyAndWhitespaceTranscriptsAreLeftAlone() {
        #expect(TelegramTranscriptTermCorrection.correct("").correctedCount == 0)
        let blank = TelegramTranscriptTermCorrection.correct("   \n ")
        #expect(blank.text == "   \n ")
        #expect(blank.correctedCount == 0)
    }
}

/// The typed-text lane must never route through the correction pass. The poll
/// loop applies it at exactly one call site (the voice branch), so this pins
/// the SOURCE-level fact that no typed-text path calls it.
@Suite("Transcript correction stays on the voice lane")
struct TelegramTranscriptCorrectionScopeTests {
    @Test func correctionIsAppliedOnlyInTheVoiceBranch() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TelegramBotTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NativeAgentCore
            .appendingPathComponent("Sources/TelegramBot", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceRoot, includingPropertiesForKeys: nil)
        var callSites: [String] = []
        for file in files where file.pathExtension == "swift" {
            guard file.lastPathComponent != "TelegramTranscriptTermCorrection.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("TelegramTranscriptTermCorrection.correct(") {
                callSites.append(file.lastPathComponent)
            }
        }
        #expect(callSites == ["TelegramPollLoop.swift"],
                "unexpected correction call sites: \(callSites)")

        // And in that file it sits inside the voice-transcription branch,
        // adjacent to the transcriber call — not on the msg.text path.
        let pollLoop = try String(
            contentsOf: sourceRoot.appendingPathComponent("TelegramPollLoop.swift"),
            encoding: .utf8
        )
        let transcribeIndex = try #require(pollLoop.range(of: "voiceTranscriber.transcribe("))
        let correctIndex = try #require(pollLoop.range(of: "TelegramTranscriptTermCorrection.correct("))
        #expect(transcribeIndex.lowerBound < correctIndex.lowerBound)
    }
}
