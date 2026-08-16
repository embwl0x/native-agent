import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MemoryV2
import ProviderRouting

// Best-agent sweep R4 — wave 3: window-aware context budgets.
//
// EVAL GATE, not vibes. Three things must hold, and each has a test that fails
// loudly if it stops holding:
//
//   (a) SMALL WINDOWS ARE BYTE-IDENTICAL. Every budget at/below the floor
//       window — and every unknown model — equals the literal that shipped
//       before ContextBudgetPolicy existed, and the RENDERED prompt block is
//       character-for-character what the pre-policy renderer produced.
//   (b) LARGE WINDOWS ADMIT MORE. A wide window renders strictly more history
//       and strictly more memory content, without exceeding the derived caps.
//   (c) THE DERIVED TOTAL IS BOUNDED. history + memory + capsule never exceeds
//       the utilization fraction of the window's character estimate.

// MARK: - Fixtures

private func msg(
    role: String,
    content: String,
    timestamp: String,
    kind: String? = nil
) -> ChatMessage {
    var metadata: [String: JSONValue] = [:]
    if let kind { metadata["kind"] = .string(kind) }
    return ChatMessage(
        role: role,
        content: content,
        timestamp: timestamp,
        extras: metadata.isEmpty ? nil : .object(["metadata": .object(metadata)])
    )
}

/// A transcript of `turns` user/assistant pairs, each turn ~`charsPerTurn`
/// characters of distinct prose so truncation and row-dropping are both
/// detectable by content, not just by length.
private func transcript(turns: Int, charsPerTurn: Int) -> [ChatMessage] {
    var out: [ChatMessage] = []
    for i in 0..<turns {
        let stamp = String(format: "2026-08-01T%02d:%02d:00Z", i / 60, i % 60)
        let body = "turn\(i) " + String(repeating: "w\(i % 10) ", count: max(1, charsPerTurn / 4))
        out.append(msg(role: "user", content: "Q\(i): " + body, timestamp: stamp))
        out.append(msg(role: "assistant", content: "A\(i): " + body, timestamp: stamp))
    }
    return out
}

private func hit(_ index: Int, chars: Int) -> MemoryRecallHit {
    let preview: String = String(repeating: "p", count: 200)
    let score: Double = 1.0 - Double(index) * 0.01
    let ts: String = "2026-07-1\(index % 10)T00:00:00Z"
    let body: String = String(repeating: "x", count: chars)
    let content: String = "mem\(index) " + body
    return MemoryRecallHit(
        score: score,
        sessionId: nil,
        role: "fact",
        ts: ts,
        preview: preview,
        content: content
    )
}

/// Every window the eval sweeps. Two floor-regime sizes, four derived.
private let sweptWindows = [8_000, 32_768, 65_536, 200_000, 262_144, 1_048_576]
private let sweptSurfaces = ["chat", "mac", "telegram", "ios", "icloud", "workshop"]

// MARK: - (a) Floor regime is byte-identical

@Suite("R4 W3 — floor regime reproduces the pre-policy literals exactly")
struct ContextBudgetFloorRegimeTests {

    /// The pre-policy table, retyped here from HEAD~ so a change to
    /// ContextBudgetPolicy.floors cannot silently redefine "unchanged".
    private struct HeadBudget {
        let historyChars, userCap, assistantCap, systemCap: Int
        let compactionSummaryCap, toolCap, continuityCap: Int
        let relevantChars, relevantItemCap: Int
    }

    private func headBudget(_ surface: String) -> HeadBudget {
        switch surface.lowercased() {
        case "telegram":
            return HeadBudget(historyChars: 9_000, userCap: 900, assistantCap: 1_100,
                              systemCap: 700, compactionSummaryCap: 4_000, toolCap: 220,
                              continuityCap: 2_200, relevantChars: 1_600, relevantItemCap: 420)
        case "ios", "mobile", "iphone", "icloud":
            return HeadBudget(historyChars: 13_000, userCap: 1_100, assistantCap: 1_400,
                              systemCap: 900, compactionSummaryCap: 6_000, toolCap: 260,
                              continuityCap: 2_600, relevantChars: 2_000, relevantItemCap: 520)
        case "chat", "mac", "default":
            return HeadBudget(historyChars: 22_000, userCap: 1_800, assistantCap: 2_200,
                              systemCap: 1_200, compactionSummaryCap: 12_000, toolCap: 320,
                              continuityCap: 3_200, relevantChars: 2_400, relevantItemCap: 650)
        default:
            return HeadBudget(historyChars: 11_000, userCap: 1_000, assistantCap: 1_200,
                              systemCap: 800, compactionSummaryCap: 5_000, toolCap: 240,
                              continuityCap: 2_200, relevantChars: 1_700, relevantItemCap: 460)
        }
    }

    private func expectFloor(_ b: ContextBudgetPolicy.Resolved, _ surface: String) {
        let head = headBudget(surface)
        #expect(b.isDerived == false)
        #expect(b.historyChars == head.historyChars)
        #expect(b.userCap == head.userCap)
        #expect(b.assistantCap == head.assistantCap)
        #expect(b.systemCap == head.systemCap)
        #expect(b.compactionSummaryCap == head.compactionSummaryCap)
        #expect(b.toolCap == head.toolCap)
        #expect(b.continuityCap == head.continuityCap)
        #expect(b.relevantChars == head.relevantChars)
        #expect(b.relevantItemCap == head.relevantItemCap)
        // Surface-independent literals.
        #expect(b.recallRowLimit == 5)
        #expect(b.memoryRowChars == 1_200)
        #expect(b.capsuleChars == 4_000)
        #expect(b.packetChars == 6_000)
        #expect(b.packetExpandedChars == 24_000)
        #expect(b.packetPostMandatoryReserve == 4_000)
    }

    @Test func nilWindowIsFloorOnEverySurface() {
        for surface in sweptSurfaces {
            expectFloor(ContextBudgetPolicy.resolve(windowTokens: nil, surface: surface), surface)
        }
    }

    @Test func smallWindowsAreFloorOnEverySurface() {
        for surface in sweptSurfaces {
            for window in [1, 8_000, 16_000, 32_000, ContextBudgetPolicy.floorWindowTokens] {
                expectFloor(
                    ContextBudgetPolicy.resolve(windowTokens: window, surface: surface),
                    surface
                )
            }
        }
    }

    /// An unknown model id must NOT be scaled. `contextLength(forModel:)`
    /// answers 128,000 for anything unrecognized — a pessimistic gauge default,
    /// not a measurement — and scaling against a guess is exactly the failure
    /// this gate exists to prevent.
    @Test func unknownAndBlankModelsResolveToNilWindow() {
        #expect(ContextBudgetPolicy.windowTokens(forModel: nil) == nil)
        #expect(ContextBudgetPolicy.windowTokens(forModel: "") == nil)
        #expect(ContextBudgetPolicy.windowTokens(forModel: "   ") == nil)
        #expect(ContextBudgetPolicy.windowTokens(forModel: "totally-made-up-model") == nil)
        expectFloor(
            ContextBudgetPolicy.resolve(model: "totally-made-up-model", surface: "chat"),
            "chat"
        )
    }

    @Test func knownModelsResolveTheirRealWindow() {
        #expect(ContextBudgetPolicy.windowTokens(forModel: "kimi-k3") == 1_048_576)
        #expect(ContextBudgetPolicy.windowTokens(forModel: "claude-opus-5") == 1_000_000)
        #expect(ContextBudgetPolicy.windowTokens(forModel: "  Kimi-K3  ") == 1_048_576)
    }

    @Test func exactProviderTupleSelectsVerifiedWindow() throws {
        #expect(ContextBudgetPolicy.windowTokens(
            forModel: "gpt-5.6-sol", providerID: "openai"
        ) == 400_000)
        #expect(ContextBudgetPolicy.windowTokens(
            forModel: "gpt-5.6-sol", providerID: "openai_oauth_direct"
        ) == 372_000)
        #expect(ContextBudgetPolicy.windowTokens(
            forModel: "anthropic/claude-sonnet-5", providerID: "openrouter"
        ) == 1_000_000)
        #expect(ContextBudgetPolicy.windowTokens(
            forModel: "anthropic/claude-sonnet-5", providerID: "anthropic"
        ) == nil)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-window-openrouter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let cached: [String: Any] = [
            "models": [[
                "id": "vendor/live-model",
                "name": "Live Model",
                "context_length": 654_321,
                "supports_streaming": true,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: cached).write(
            to: providers.appendingPathComponent("openrouter-models-cache.json")
        )
        #expect(ContextBudgetPolicy.windowTokens(
            forModel: "vendor/live-model", providerID: "openrouter", dataRoot: root
        ) == 654_321)
    }

    /// The RENDERED block, not just the numbers: a floor-regime render must be
    /// character-identical to the legacy no-window call.
    @Test func floorRenderIsCharacterIdenticalToLegacyCall() throws {
        let messages = transcript(turns: 40, charsPerTurn: 900)
        for surface in sweptSurfaces {
            let legacy = try #require(SessionHistoryPromptRenderer.render(
                messages: messages, userMessage: "what now?",
                surface: surface, historyLimit: 30
            ))
            for window in [nil, 8_000, ContextBudgetPolicy.floorWindowTokens] as [Int?] {
                let scoped = try #require(SessionHistoryPromptRenderer.render(
                    messages: messages, userMessage: "what now?",
                    surface: surface, historyLimit: 30, windowTokens: window
                ))
                #expect(scoped == legacy)
            }
        }
    }

    /// Same for the memory block: floor regime keeps all 5 rows at 1,200 chars
    /// each and never applies the aggregate bound (markers push five full rows
    /// past 5×1,200, and dropping row 5 would be a silent regression).
    @Test func floorMemoryBlockKeepsAllFiveFullRows() throws {
        let hits = (0..<8).map { hit($0, chars: 4_000) }
        let block = try #require(
            SwiftNativeTurnEngine.renderRecalledMemoryBlock(hits)
        )
        let rows = block.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(rows.count == 5)
        for i in 0..<5 { #expect(block.contains("mem\(i) ")) }
        #expect(!block.contains("mem5 "))
        // Each row clipped at the 1,200 literal.
        #expect(block.contains(String(repeating: "x", count: 1_190)))
        #expect(!block.contains(String(repeating: "x", count: 1_205)))
        // And the explicit floor budget renders identically to no budget.
        let floored = try #require(SwiftNativeTurnEngine.renderRecalledMemoryBlock(
            hits, budget: ContextBudgetPolicy.resolve(windowTokens: nil, surface: "chat")
        ))
        #expect(floored == block)
    }
}

// MARK: - The scaling table (pinned)

@Suite("R4 W3 — scaling table")
struct ContextBudgetScalingTableTests {

    /// 32,768 tokens → floor. 200,000 → scale ~4.95. 1,048,576 → caps bind.
    /// These numbers are the deliverable; pin them so a tuning change is a
    /// deliberate test edit, never a silent drift.
    @Test func chatSurfaceScalingTable() {
        let floor = ContextBudgetPolicy.resolve(windowTokens: 32_768, surface: "chat")
        #expect(floor.historyChars == 22_000)
        #expect(floor.memoryBlockChars == 6_000)
        #expect(floor.capsuleChars == 4_000)
        #expect(floor.packetChars == 6_000)
        #expect(floor.recallRowLimit == 5)

        let mid = ContextBudgetPolicy.resolve(windowTokens: 200_000, surface: "chat")
        #expect(mid.isDerived)
        #expect(mid.historyChars == 96_000)
        #expect(mid.memoryRowChars == 4_736)   // 24,000/5 net of row markup
        #expect(mid.memoryBlockChars == 24_000)
        #expect(mid.recallRowLimit == 5)
        #expect(mid.capsuleChars == 8_000)
        #expect(mid.packetChars == 29_702)
        #expect(mid.packetExpandedChars == 48_000)
        #expect(mid.packetPostMandatoryReserve == 19_801)
        #expect(mid.userCap == 7_200)
        #expect(mid.assistantCap == 8_800)
        #expect(mid.compactionSummaryCap == 12_000)
        #expect(mid.relevantChars == 11_881)

        let wide = ContextBudgetPolicy.resolve(windowTokens: 1_048_576, surface: "chat")
        #expect(wide.isDerived)
        #expect(wide.historyChars == 96_000)      // ceiling
        #expect(wide.recallRowLimit == 10)         // doubled above 200k
        #expect(wide.memoryRowChars == 2_336)      // 24,000/10 net of row markup
        #expect(wide.memoryBlockChars == 24_000)   // 10 full rows fit the ceiling
        #expect(wide.capsuleChars == 8_000)        // ceiling
        #expect(wide.packetChars == 32_000)
        #expect(wide.packetExpandedChars == 48_000)
        #expect(wide.packetPostMandatoryReserve == 40_000)
        #expect(wide.relevantChars == 24_000)
        #expect(wide.compactionSummaryCap == ChatCompactionDistiller.maxSummaryChars)
    }

    /// Telegram and iOS scale from THEIR floors — they never inherit chat's.
    @Test func mobileSurfacesScaleFromTheirOwnFloors() {
        let tg = ContextBudgetPolicy.resolve(windowTokens: 200_000, surface: "telegram")
        let ios = ContextBudgetPolicy.resolve(windowTokens: 200_000, surface: "ios")
        let chat = ContextBudgetPolicy.resolve(windowTokens: 200_000, surface: "chat")
        #expect(tg.historyChars == 44_554)   // 9,000 × ~4.95
        #expect(ios.historyChars == 64_356) // 13,000 × ~4.95
        #expect(tg.historyChars < ios.historyChars)
        #expect(ios.historyChars < chat.historyChars)
    }

    /// (c) The derived total never exceeds the utilization fraction, on any
    /// surface, at any swept window.
    @Test func derivedTotalNeverExceedsUtilizationFraction() {
        for surface in sweptSurfaces {
            for window in sweptWindows {
                let b = ContextBudgetPolicy.resolve(windowTokens: window, surface: surface)
                guard b.isDerived else { continue }
                let allowance = ContextBudgetPolicy.derivedCharacterAllowance(
                    windowTokens: window
                )
                #expect(
                    b.governedTotalChars <= allowance,
                    "\(surface)@\(window): \(b.governedTotalChars) > \(allowance)"
                )
            }
        }
    }

    /// Monotonic and never below the floor — the invariant that makes this
    /// change safe to ship on every model at once.
    @Test func budgetsAreMonotonicAndNeverBelowFloor() {
        for surface in sweptSurfaces {
            let floor = ContextBudgetPolicy.resolve(windowTokens: nil, surface: surface)
            var previous = floor
            for window in sweptWindows {
                let b = ContextBudgetPolicy.resolve(windowTokens: window, surface: surface)
                #expect(b.historyChars >= floor.historyChars)
                #expect(b.userCap >= floor.userCap)
                #expect(b.assistantCap >= floor.assistantCap)
                #expect(b.systemCap >= floor.systemCap)
                #expect(b.toolCap >= floor.toolCap)
                #expect(b.continuityCap >= floor.continuityCap)
                #expect(b.relevantChars >= floor.relevantChars)
                #expect(b.relevantItemCap >= floor.relevantItemCap)
                #expect(b.compactionSummaryCap >= floor.compactionSummaryCap)
                #expect(b.memoryBlockChars >= floor.memoryBlockChars)
                #expect(b.capsuleChars >= floor.capsuleChars)
                #expect(b.packetChars >= floor.packetChars)
                #expect(b.packetExpandedChars >= floor.packetExpandedChars)
                #expect(b.recallRowLimit >= floor.recallRowLimit)
                #expect(b.historyChars >= previous.historyChars)
                #expect(b.governedTotalChars >= previous.governedTotalChars)
                previous = b
            }
        }
    }

    /// A per-row cap can never exceed the block it lives in.
    @Test func rowCapsStayInsideTheirBlocks() {
        for surface in sweptSurfaces {
            for window in sweptWindows {
                let b = ContextBudgetPolicy.resolve(windowTokens: window, surface: surface)
                #expect(b.userCap <= b.historyChars)
                #expect(b.assistantCap <= b.historyChars)
                #expect(b.compactionSummaryCap <= b.historyChars)
                #expect(b.relevantItemCap <= b.relevantChars)
                #expect(b.recallRowLimit * b.memoryRowChars <= b.memoryBlockChars)
                #expect(b.packetChars <= b.packetExpandedChars)
            }
        }
    }
}

// MARK: - (b) Large windows admit more, bounded

@Suite("R4 W3 EVAL — wide windows admit more context, within the derived caps")
struct ContextBudgetEvalHarnessTests {

    /// Three fixture transcript sizes: one that fits inside the floor budget
    /// (nothing to win), one that overflows the floor but fits the derived
    /// budget, and one that overflows both.
    private static let fixtures: [(name: String, turns: Int, charsPerTurn: Int)] = [
        ("small", 6, 400),
        ("medium", 60, 900),
        ("large", 400, 1_200),
    ]

    @Test func wideWindowRendersStrictlyMoreHistoryOnOverflowingTranscripts() throws {
        for fixture in Self.fixtures {
            let messages = transcript(turns: fixture.turns, charsPerTurn: fixture.charsPerTurn)
            let floorBlock = try #require(SessionHistoryPromptRenderer.render(
                messages: messages, userMessage: "continue",
                surface: "chat", historyLimit: 200, windowTokens: nil
            ))
            let wideBlock = try #require(SessionHistoryPromptRenderer.render(
                messages: messages, userMessage: "continue",
                surface: "chat", historyLimit: 200, windowTokens: 1_048_576
            ))
            let wide = ContextBudgetPolicy.resolve(windowTokens: 1_048_576, surface: "chat")

            if fixture.name == "small" {
                // Nothing overflowed, so nothing changes — the extra room is
                // only ever spent on content that actually exists.
                #expect(wideBlock == floorBlock)
            } else {
                #expect(
                    wideBlock.count > floorBlock.count,
                    "\(fixture.name): wide \(wideBlock.count) !> floor \(floorBlock.count)"
                )
                // More ROWS, not just longer ones.
                let floorRows = floorBlock.components(separatedBy: "\n[").count
                let wideRows = wideBlock.components(separatedBy: "\n[").count
                #expect(
                    wideRows > floorRows,
                    "\(fixture.name): wide \(wideRows) rows !> floor \(floorRows)"
                )
            }
            // ...and never past the derived cap. The history block carries the
            // continuity + relevant sections alongside the conversation, so the
            // bound is the sum of the three section budgets it can spend.
            #expect(
                wideBlock.count <= wide.historyChars + wide.relevantChars
                    + wide.continuityCap + 4_096,
                "\(fixture.name): \(wideBlock.count) exceeded derived history bound"
            )
        }
    }

    @Test func wideWindowAdmitsMoreMemoryContentWithinTheBlockCap() throws {
        let hits = (0..<14).map { hit($0, chars: 4_000) }
        let floorBlock = try #require(SwiftNativeTurnEngine.renderRecalledMemoryBlock(
            hits, budget: ContextBudgetPolicy.resolve(windowTokens: nil, surface: "chat")
        ))
        let wideBudget = ContextBudgetPolicy.resolve(windowTokens: 1_048_576, surface: "chat")
        let wideBlock = try #require(
            SwiftNativeTurnEngine.renderRecalledMemoryBlock(hits, budget: wideBudget)
        )

        let floorRows = floorBlock.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
        let wideRows = wideBlock.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
        #expect(floorRows == 5)
        #expect(wideRows == 10)                       // doubled recall breadth
        #expect(wideBlock.count > floorBlock.count)   // strictly more content
        // Bounded: the aggregate block cap holds (allowing the header and the
        // one row that is always admitted).
        #expect(wideBlock.count <= wideBudget.memoryBlockChars + wideBudget.memoryRowChars + 512)
        #expect(wideBudget.memoryBlockChars <= ContextBudgetPolicy.maximumMemoryBlockCharacters)
    }

    /// The aggregate bound genuinely bites: pathologically long memories stop
    /// the block instead of multiplying it by the row count.
    @Test func derivedMemoryBlockStopsAtItsAggregateBound() throws {
        let hits = (0..<10).map { hit($0, chars: 100_000) }
        let wideBudget = ContextBudgetPolicy.resolve(windowTokens: 1_048_576, surface: "chat")
        let block = try #require(
            SwiftNativeTurnEngine.renderRecalledMemoryBlock(hits, budget: wideBudget)
        )
        #expect(block.count <= wideBudget.memoryBlockChars + wideBudget.memoryRowChars + 512)
        #expect(block.count < 10 * 100_000)
    }

    /// End-to-end shape of the claim: at 1M tokens the assembled budget still
    /// spends well under the window, and far more than the ~30k of characters
    /// the pre-policy assembler could ever ask for.
    @Test func windowUtilizationRisesButStaysConservative() {
        let floor = ContextBudgetPolicy.resolve(windowTokens: nil, surface: "chat")
        let wide = ContextBudgetPolicy.resolve(windowTokens: 1_048_576, surface: "chat")
        #expect(floor.governedTotalChars == 32_000)
        #expect(wide.governedTotalChars == 128_000)
        let allowance = ContextBudgetPolicy.derivedCharacterAllowance(windowTokens: 1_048_576)
        #expect(wide.governedTotalChars <= allowance)
        // Still a minority of the window even at the ceilings: ~45% of the
        // 25% allowance, i.e. ~11% of the full window in characters.
        #expect(Double(wide.governedTotalChars) < Double(allowance) * 0.5)
    }

    @Test func worstCaseDerivedFitsCatalogMinimum() {
        // gpt-5.5 review 2026-08-06 BLOCKING: there is no post-assembly
        // provider input clamp, so the ceilings themselves must guarantee the
        // worst-case derived ask fits the SMALLEST window the catalog gate can
        // admit (128k tokens) — even when a stale catalog row claims 1M.
        let worstChars = ContextBudgetPolicy.maximumHistoryCharacters
            + ContextBudgetPolicy.maximumMemoryBlockCharacters
            + ContextBudgetPolicy.maximumRelevantCharacters
            + ContextBudgetPolicy.maximumCapsuleCharacters
            + ContextBudgetPolicy.maximumPacketExpandedCharacters
        let worstTokens = Double(worstChars) / 3.2
        // 60% of the 128k catalog minimum leaves room for persona/system
        // blocks, the tool catalog, the current message, and output reserve.
        #expect(worstTokens <= 0.60 * 128_000,
            "derived ceilings sum to \(Int(worstTokens)) tokens — exceeds the safe share of the smallest catalog-gated window; a stale catalog row could produce provider-rejected prompts")
    }

}
