import Testing
import Foundation
@testable import ChatOrchestration

// ─────────────────────────────────────────────────────────────────────────────
// EVAL FENCE: core.chat.tools
// Ledger row: chat.tools.markets.secretRedaction  (credential exfiltration, silent)
//
// `impl_market_status` advertises that "configured secrets stay in data/secrets
// and are never returned", and the ONLY thing enforcing that promise is
// `isSensitiveMarketKey` — a substring blocklist. Nothing in Modules/**/Tests or
// tests/ dispatches market_status / market_watchlists / market_quote /
// tradingview_watchlist at all, and per the live trace none has ever run, so
// there is no production signal either.
//
// WHAT THIS EVAL CAN AND CANNOT DO. `sanitizeMarketPayload` and
// `isSensitiveMarketKey` are BOTH file-private, so a behavioural test of the
// redaction needs a production visibility change (see productionSeamNeeded).
// What is testable today, and worth having, is the blocklist itself: parsed out
// of source and pinned as a FLOOR. Narrowing it — the regression that turns a
// redacted field back into a plaintext credential in the chat transcript — goes
// red. Widening it stays green, because widening is always safe.
//
// The blocklist is a DENY-list, which is the wrong shape for a credential
// guard: a provider that names its secret `bearer`, `pat`, `credential`,
// `password`, or `x-api-key` matches none of the substrings below and is copied
// verbatim into a tool result that lands in the transcript and the trace feed.
// That gap is named here so it is a reviewed decision rather than an invisible
// one; closing it properly is the allow-list rewrite described in the seam.
// ─────────────────────────────────────────────────────────────────────────────

/// Substrings/exact keys the redaction MUST keep matching. A floor, not an
/// equality: adding a term is a safety improvement and must not need a test edit.
private let marketSecretBlocklistFloor: Set<String> = [
    "contains:token",
    "contains:secret",
    "contains:cookie",
    "contains:session",
    "contains:auth",
    "equals:key",
    "equals:api_key",
]

@Test func marketSecretRedaction_blocklistNeverNarrows() throws {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Modules/NativeAgentCore/Sources/ChatOrchestration/SwiftToolDispatcher+Markets.swift")
    let text = try String(contentsOf: source, encoding: .utf8)

    guard let start = text.range(of: "private func isSensitiveMarketKey(") else {
        Issue.record("isSensitiveMarketKey moved or was renamed — it is the only thing standing between a provider credential and the chat transcript, so this eval must move with it")
        return
    }
    guard let end = text.range(of: "\n    }", range: start.upperBound..<text.endIndex) else {
        Issue.record("could not find the end of isSensitiveMarketKey")
        return
    }
    let body = String(text[start.upperBound..<end.lowerBound])

    var terms: Set<String> = []
    var cursor = body.startIndex
    while let match = body.range(of: "lower.contains(\"", range: cursor..<body.endIndex) {
        guard let close = body.range(of: "\"", range: match.upperBound..<body.endIndex) else { break }
        terms.insert("contains:" + String(body[match.upperBound..<close.lowerBound]))
        cursor = close.upperBound
    }
    cursor = body.startIndex
    while let match = body.range(of: "lower == \"", range: cursor..<body.endIndex) {
        guard let close = body.range(of: "\"", range: match.upperBound..<body.endIndex) else { break }
        terms.insert("equals:" + String(body[match.upperBound..<close.lowerBound]))
        cursor = close.upperBound
    }

    #expect(
        terms.count >= marketSecretBlocklistFloor.count,
        "parsed only \(terms.count) blocklist terms — the parser drifted, and a parser that finds nothing would pass anything"
    )
    let lost = marketSecretBlocklistFloor.subtracting(terms)
    #expect(
        lost.isEmpty,
        """
        the market secret blocklist LOST \(lost.sorted()). Every term here is the only thing \
        redacting a class of credential key out of a tool result that lands in the chat \
        transcript and the trace feed. Removing one is a plaintext-credential regression \
        with no other signal anywhere.
        """
    )

    // The promise the tool description makes to the user is part of the
    // contract; if the sentence goes away the guarantee did too.
    #expect(
        text.contains("data/secrets") && text.contains("never returned"),
        "impl_market_status no longer promises that configured secrets are never returned — either the promise or the redaction changed"
    )
}
