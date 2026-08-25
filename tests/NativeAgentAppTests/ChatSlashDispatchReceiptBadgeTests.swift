import Foundation
import Testing
@testable import NativeAgentApp

// Coverage ledger app.chat / ui.chat.composer.slashToolDispatchReceipt
// (UNCOVERED → COVERED).
//
// Silent-failure mode being pinned: the receipt's status→badge switch has a
// `default: "•"` arm. Every terminal status the dispatcher can produce must map
// to a real badge; a NEW status (a new refusal kind) falls into the default and
// renders as an ambiguous bullet that reads like success — the user believes a
// blocked or failed tool ran.
//
// The envelope asserted: the producer's status vocabulary (mined from the
// Dispatcher, which owns it, plus the app's own local dispatch envelope) is a
// SUBSET of the badge-mapped statuses, and the default arm stays reachable only
// for genuinely unknown values.

private enum DispatchStatusVocabulary {
    /// Statuses the dispatch layer actually writes into a receipt envelope,
    /// mined from executable lines (comments stripped) of the owning sources.
    static func produced() throws -> Set<String> {
        let root = try AppSourceScraping.repositoryRoot()
        let sources = [
            root.appendingPathComponent(
                "Modules/NativeAgentCore/Sources/Dispatcher/Dispatcher.swift"),
            root.appendingPathComponent(
                "Sources/NativeAgentApp/NativeClient+ToolDispatch.swift"),
        ]
        let regex = try NSRegularExpression(pattern: #"status\s*[:=]\s*"([a-z_]+)""#)
        var statuses: Set<String> = []
        for url in sources {
            let source = try String(contentsOf: url, encoding: .utf8)
            for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                // Drop trailing comments so prose about statuses can't inflate
                // the vocabulary.
                let code = line.components(separatedBy: "//").first ?? line
                let range = NSRange(code.startIndex..<code.endIndex, in: code)
                for match in regex.matches(in: code, range: range) {
                    if let r = Range(match.range(at: 1), in: code) {
                        statuses.insert(String(code[r]))
                    }
                }
            }
        }
        return statuses
    }
}

private func dispatchResult(status: String, ok: Bool) -> DispatchResult {
    DispatchResult(
        ok: ok,
        tool: "read_file",
        status: status,
        output: nil,
        error: nil,
        executed: ok,
        verifyPassed: nil,
        durationUs: 1_000,
        durationMs: 1,
        effectiveAutonomy: "assist",
        autonomySource: "policy",
        providerMatch: true,
        traceEventId: nil,
        runId: "run-1",
        startedAt: "2026-08-23T00:00:00Z"
    )
}

@MainActor
@Suite("Chat slash dispatch receipt badge")
struct ChatSlashDispatchReceiptBadgeTests {

    private let ambiguousBadge = "•"

    /// Every status the dispatch layer produces must carry a distinguishing
    /// badge — the default bullet must be unreachable for real statuses.
    @Test func everyProducedStatusRendersANonDefaultBadge() throws {
        let view = ChatView()
        let produced = try DispatchStatusVocabulary.produced()
        #expect(produced.count >= 4, "status vocabulary looks under-mined: \(produced.sorted())")
        // Anchor: these are the statuses the receipt was written for. Mining
        // catches the ones added later.
        for anchor in ["ok", "failed", "blocked", "pending_approval", "dry_run"] {
            #expect(produced.contains(anchor),
                    "the dispatch layer no longer produces \(anchor) — receipt mapping is stale")
        }
        for status in produced.sorted() {
            let receipt = view.buildReceiptMessage(
                result: dispatchResult(status: status, ok: status == "ok"),
                tool: "read_file",
                input: [:]
            )
            #expect(!receipt.content.hasPrefix(ambiguousBadge),
                    "status '\(status)' renders the ambiguous default badge")
            #expect(receipt.role == "system", "the receipt must stay a system row")
            #expect(receipt.content.contains("read_file"),
                    "the receipt dropped the tool name for status \(status)")
        }
    }

    /// The default arm must still exist for a status nobody has mapped — the
    /// test above is only meaningful if the bullet is genuinely reachable.
    @Test func anUnmappedStatusStillFallsThroughToTheDefaultBadge() {
        let view = ChatView()
        let receipt = view.buildReceiptMessage(
            result: dispatchResult(status: "totally_new_terminal_status", ok: false),
            tool: "read_file",
            input: [:]
        )
        #expect(receipt.content.hasPrefix(ambiguousBadge),
                "the default badge arm is unreachable — the mapping test above would be vacuous")
    }

    /// The receipt is a bounded summary: args capped, output capped, and the
    /// duration/autonomy trace always present. An uncapped tool output pastes a
    /// wall of text into the transcript.
    @Test func receiptBodyStaysBoundedAndAlwaysCarriesItsTrace() {
        let view = ChatView()
        let hugeArgs: [String: Any] = ["path": String(repeating: "p", count: 500)]
        let receipt = view.buildReceiptMessage(
            result: dispatchResult(status: "ok", ok: true),
            tool: "read_file",
            input: hugeArgs
        )
        #expect(receipt.content.contains("autonomy: assist"),
                "the receipt lost its duration/autonomy trace")
        #expect(receipt.content.contains("ms ·"))
        // The arg summary is capped well under the raw input length.
        #expect(receipt.content.count < 300,
                "the arg summary is no longer capped: \(receipt.content.count) chars")
    }
}
