import Testing
import Foundation
@testable import TelegramBot
import NativeAgentCore
import NativeAgentTestSupport
import PersistenceCore

// Audit 2026-06-09: Telegram hard-rejects >4096-char messages; before
// chunking, long Agent replies died silently (typing, then nothing).
@Suite("Telegram message chunking")
struct TelegramChunkingTests {
    @Test func shortMessagePassesThroughUnchanged() {
        let chunks = TelegramPollLoop._tgChunkMessage("hello the user", limit: 4000)
        #expect(chunks == ["hello the user"])
    }

    @Test func longMessageSplitsUnderLimitPreservingContent() {
        let line = String(repeating: "x", count: 80)
        let text = Array(repeating: line, count: 200).joined(separator: "\n") // ~16k chars
        let chunks = TelegramPollLoop._tgChunkMessage(text, limit: 4000)
        #expect(chunks.count >= 4)
        for c in chunks { #expect(c.count <= 4000) }
        // Content preserved modulo the newline/space separators we split on.
        let rejoined = chunks.joined(separator: "\n")
        #expect(rejoined.replacingOccurrences(of: "\n", with: "")
            == text.replacingOccurrences(of: "\n", with: ""))
    }

    @Test func unbrokenBlobStillSplitsHard() {
        let text = String(repeating: "a", count: 9000)
        let chunks = TelegramPollLoop._tgChunkMessage(text, limit: 4000)
        #expect(chunks.count == 3)
        #expect(chunks.joined() == text)
    }

    @Test func budgetsByUTF16NotGraphemes() {
        // Telegram counts UTF-16 code units: 3000 emoji = 3000 graphemes
        // but 6000 units — one grapheme-budgeted chunk would 400.
        let text = String(repeating: "\u{1F600}", count: 3000)
        let chunks = TelegramPollLoop._tgChunkMessage(text, limit: 4000)
        #expect(chunks.count == 2)
        for c in chunks { #expect(c.utf16.count <= 4000) }
        #expect(chunks.joined() == text)
    }

}
