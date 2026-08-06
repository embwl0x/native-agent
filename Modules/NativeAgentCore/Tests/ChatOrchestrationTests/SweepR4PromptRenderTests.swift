import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MemoryV2

// Best-agent sweep R4 — wave 1 render fixes.
//   A3 (#2): the compaction recollection was rendered through the generic
//            1,200-char systemCap while the distiller writes up to 12,000.
//   A4 (#3): the chat prompt showed 200-char memory previews under a header
//            that claimed recency for relevance-ranked rows.
//   #6      : prior-turn tool rows were head-clipped at 180 chars with a bare
//            "...", dropping exactly the trailing lines that carry failures.

private func msg(
    role: String,
    content: String,
    timestamp: String,
    kind: String? = nil,
    metadata extra: [String: JSONValue] = [:]
) -> ChatMessage {
    var metadata = extra
    if let kind { metadata["kind"] = .string(kind) }
    return ChatMessage(
        role: role,
        content: content,
        timestamp: timestamp,
        extras: metadata.isEmpty ? nil : .object(["metadata": .object(metadata)])
    )
}

// MARK: - A3: compaction recollection render cap

@Suite("Sweep R4 A3 — compaction recollection render cap")
struct CompactionRecollectionRenderCapTests {

    /// The distiller's own maximum is the size the renderer must now honor.
    @Test func twelveKCompactionRowSurvivesRenderingUntruncated() throws {
        let recollection = String(repeating: "recollection sentence. ", count: 600)
        #expect(recollection.count >= 12_000)
        let summary = String(recollection.prefix(ChatCompactionDistiller.maxSummaryChars))

        let rendered = try #require(SessionHistoryPromptRenderer.render(
            messages: [
                msg(role: "system", content: summary,
                    timestamp: "2026-08-01T00:00:00Z", kind: "compaction_summary"),
                msg(role: "user", content: "what were we doing?",
                    timestamp: "2026-08-01T00:01:00Z"),
                msg(role: "assistant", content: "picking the thread back up",
                    timestamp: "2026-08-01T00:02:00Z"),
            ],
            surface: "chat",
            historyLimit: 20
        ))
        // The whole recollection is present — head AND tail.
        #expect(rendered.contains(String(summary.prefix(200))))
        #expect(rendered.contains(String(summary.suffix(200))))
        // ...and it was not silently clipped.
        #expect(!rendered.contains("recollection sentence. ..."))
    }

    /// The generic system cap is untouched — only `compaction_summary` routes
    /// to the new cap.
    @Test func ordinarySystemRowStillCapsAt1200() throws {
        let long = String(repeating: "s", count: 5_000)
        let rendered = try #require(SessionHistoryPromptRenderer.render(
            messages: [
                msg(role: "system", content: long, timestamp: "2026-08-01T00:00:00Z"),
                msg(role: "user", content: "hello", timestamp: "2026-08-01T00:01:00Z"),
            ],
            surface: "chat",
            historyLimit: 20
        ))
        #expect(rendered.contains(String(repeating: "s", count: 1_200) + "..."))
        #expect(!rendered.contains(String(repeating: "s", count: 1_201)))
    }

    /// TOTAL-BUDGET BOUND: `capForRole` bounds one row; `budget.historyChars`
    /// bounds the aggregate. Raising a row cap must not grow the block past it.
    @Test func historyBlockStillRespectsTheAggregateBudget() throws {
        var messages: [ChatMessage] = [
            msg(role: "system", content: String(repeating: "c", count: 12_000),
                timestamp: "2026-08-01T00:00:00Z", kind: "compaction_summary")
        ]
        for i in 1...40 {
            messages.append(msg(
                role: i.isMultiple(of: 2) ? "user" : "assistant",
                content: String(repeating: "x", count: 1_500),
                timestamp: String(format: "2026-08-01T01:%02d:00Z", i % 60)
            ))
        }
        let rendered = try #require(SessionHistoryPromptRenderer.render(
            messages: messages, surface: "chat", historyLimit: 60
        ))
        // The aggregate this cap interacts with is `budget.historyChars`
        // (22,000 on chat), which bounds the CONVERSATION HISTORY section — not
        // the whole block, which also carries continuity/snippet sections with
        // their own separate budgets. Measure the thing the bound applies to.
        let marker = "Conversation history:\n"
        let historySection = try #require(rendered.range(of: marker)).upperBound
        let historyChars = rendered[historySection...].count
        // 22,000 budget + the notice line + the always-admitted newest row's
        // permitted overshoot (one row, ≤ 2,200 chars + role tag).
        #expect(historyChars < 25_000, "history section grew past its budget: \(historyChars)")
        // The recollection still made it in despite 40 newer rows competing —
        // newest-first filling would otherwise have spent the whole budget
        // before reaching the oldest row.
        #expect(rendered.contains(String(repeating: "c", count: 1_000)))
    }
}

// MARK: - A4: recalled-memory rows

@Suite("Sweep R4 A4 — recalled memory renders full text + provenance")
struct RecalledMemoryRenderTests {

    private func hit(
        content: String?,
        preview: String,
        ts: String? = "2026-07-14T09:30:00Z",
        kind: String? = "preference"
    ) -> MemoryRecallHit {
        var extras: [String: JSONValue] = ["id": .string(UUID().uuidString)]
        if let kind { extras["kind"] = .string(kind) }
        return MemoryRecallHit(
            score: 0.8,
            sessionId: nil,
            role: nil,
            ts: ts,
            preview: preview,
            content: content,
            source: "swift-native",
            rankingSignals: nil,
            extras: .object(extras)
        )
    }

    @Test func rendersFullContentNotThePreview() throws {
        let full = String(repeating: "the user prefers direct answers. ", count: 20)
        let block = try #require(SwiftNativeTurnEngine.renderRecalledMemoryBlock([
            hit(content: full, preview: String(full.prefix(200)))
        ]))
        #expect(block.contains(full))
        #expect(block.count > 400, "still rendering the 200-char preview")
    }

    @Test func headerNamesRelevanceNotRecency() throws {
        let block = try #require(SwiftNativeTurnEngine.renderRecalledMemoryBlock([
            hit(content: "a fact", preview: "a fact")
        ]))
        #expect(block.hasPrefix("Relevant memory:\n"))
        #expect(!block.contains("Recent memory:"))
    }

    @Test func eachRowCarriesACompactTimestampAndKindMarker() throws {
        let block = try #require(SwiftNativeTurnEngine.renderRecalledMemoryBlock([
            hit(content: "User uses zsh", preview: "User uses zsh")
        ]))
        #expect(block.contains("[2026-07-14, preference]"))
    }

    @Test func perRowBoundIsTwelveHundredWithTailEllipsis() throws {
        let huge = String(repeating: "z", count: 5_000)
        let block = try #require(SwiftNativeTurnEngine.renderRecalledMemoryBlock([
            hit(content: huge, preview: "zzz")
        ]))
        #expect(block.contains(String(repeating: "z", count: 1_200) + "…"))
        #expect(!block.contains(String(repeating: "z", count: 1_201)))
    }

    @Test func fallsBackToPreviewWhenContentIsAbsent() throws {
        let block = try #require(SwiftNativeTurnEngine.renderRecalledMemoryBlock([
            hit(content: nil, preview: "kg fallback row", ts: nil, kind: nil)
        ]))
        #expect(block.contains("- kg fallback row"))
        // No timestamp, no kind → no empty "[]" marker.
        #expect(!block.contains("[]"))
    }

    @Test func bothPromptLanesUseTheNewBlock() {
        let hits = [hit(content: "a durable fact about User", preview: "a durable")]
        let legacy = SwiftNativeTurnEngine.renderSystemPromptSegments(
            personaDocs: ["SOUL.md": "you are Agent"], recalled: hits, remPins: []
        )
        let compiled = SwiftNativeTurnEngine.renderSystemPromptSegments(
            compiledPersonaPrompt: "you are Agent", recalled: hits, remPins: []
        )
        for segments in [legacy, compiled] {
            #expect(segments.dynamic.contains("Relevant memory:"))
            #expect(segments.dynamic.contains("a durable fact about User"))
            #expect(segments.dynamic.contains("[2026-07-14, preference]"))
            #expect(!segments.dynamic.contains("Recent memory:"))
        }
    }
}

// MARK: - #6: cross-turn tool-result truncation

@Suite("Sweep R4 #6 — prior-turn tool results keep head AND tail")
struct CrossTurnToolResultProjectionTests {

    private func toolMetadata(_ result: String, name: String = "run_tests") -> [String: JSONValue] {
        [
            "kind": .string("tool_use"),
            "toolName": .string(name),
            "resultSummary": .string(result),
            "ok": .bool(false),
        ]
    }

    @Test func longResultKeepsHeadAndTailWithAnExplicitMarker() {
        let head = "starting test run for NativeAgentCore with a long preamble that fills the head budget"
        let tail = "FAILED: 3 tests failed, exit status 1"
        let body = head + String(repeating: " middle noise", count: 400) + " " + tail

        let rendered = SessionHistoryPromptRenderer.toolSummary(
            content: "", metadata: toolMetadata(body)
        )
        #expect(rendered.hasPrefix("run_tests failed:"))
        // Head survives.
        #expect(rendered.contains(String(head.prefix(80))))
        // Tail survives — this is the whole point; head-only clipping dropped it.
        #expect(rendered.contains("exit status 1"))
        // Elision is stated, not implied by a bare "...".
        #expect(rendered.contains("chars elided"))
        #expect(rendered.contains("[…"))
    }

    @Test func shortResultsAreUntouched() {
        let rendered = SessionHistoryPromptRenderer.toolSummary(
            content: "", metadata: toolMetadata("all green", name: "run_tests")
        )
        #expect(rendered == "run_tests failed: all green")
        #expect(!rendered.contains("elided"))
    }

    @Test func projectionIsIdentityForTextInsideTheBudget() {
        let short = String(repeating: "a", count: 120)
        #expect(SessionHistoryPromptRenderer.toolResultProjection(short) == short)
    }

    @Test func projectionMarkerCountsWhatItDropped() {
        let raw = String(repeating: "b", count: 300)
        let projected = SessionHistoryPromptRenderer.toolResultProjection(raw)
        let kept = SessionHistoryPromptRenderer.toolResultHeadChars
            + SessionHistoryPromptRenderer.toolResultTailChars
        #expect(projected.contains("[… \(raw.count - kept) chars elided …]"))
        #expect(projected.hasPrefix(String(repeating: "b", count: 10)))
        #expect(projected.hasSuffix(String(repeating: "b", count: 10)))
    }

    /// The row cap must not head-truncate the projection and throw the tail
    /// away again — the two layers have to agree, on every surface.
    @Test func renderedToolRowKeepsItsTailOnEverySurface() throws {
        let body = "HEADMARK" + String(repeating: " x", count: 2_000) + " TAILMARK"
        for surface in ["chat", "telegram", "ios", "bridge"] {
            let rendered = try #require(SessionHistoryPromptRenderer.render(
                messages: [
                    msg(role: "tool", content: "", timestamp: "2026-08-01T00:00:00Z",
                        kind: "tool_use",
                        metadata: [
                            "toolName": .string("mcp__sonnet_swarm__sonnet_dispatch"),
                            "resultSummary": .string(body),
                            "ok": .bool(false),
                        ]),
                    msg(role: "user", content: "what happened?",
                        timestamp: "2026-08-01T00:01:00Z"),
                ],
                surface: surface,
                historyLimit: 20
            ), "no render for \(surface)")
            #expect(rendered.contains("HEADMARK"), "head lost on \(surface)")
            #expect(rendered.contains("TAILMARK"), "tail lost on \(surface)")
            #expect(rendered.contains("chars elided"), "marker lost on \(surface)")
        }
    }
}
