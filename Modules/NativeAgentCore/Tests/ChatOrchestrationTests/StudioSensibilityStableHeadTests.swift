import Testing
import Foundation
@testable import ChatOrchestration
import DreamREMCycle
import NativeAgentCore
import PersistenceCore

// SENSIBILITY IN THE CACHED HEAD — personality-depth item 10.
//
// Her lines belong in the STABLE segment, after the REM pins, and nowhere else.
// The three properties that make that safe: it lands in `stable` (not
// `dynamic`), it is bounded at 400 characters, and it is byte-identical across
// turns and surfaces so it costs nothing after the first turn of a session.

private let sensibilityLines = [
    "I keep choosing work that admits its own weight.",
    "Cleverness reads as fear to me now.",
]

private func sensibilitySegments(
    sensibility: String?,
    remPins: [REMPin] = []
) -> SystemPromptSegments {
    SwiftNativeTurnEngine.renderSystemPromptSegments(
        compiledPersonaPrompt: "# SOUL\nYou are Agent.",
        recalled: [],
        remPins: remPins,
        includeNaturalExpressionGuidance: false,
        sensibilityBlock: sensibility
    )
}

@Test func sensibility_landsInTheCachedStableSegmentNotTheDynamicOne() {
    let block = try! #require(StudioSensibility.renderStableBlock(sensibilityLines))
    let segments = sensibilitySegments(sensibility: block)

    #expect(segments.stable.contains("# Sensibility"))
    #expect(segments.stable.contains(sensibilityLines[0]))
    // Zero per-turn cost is the whole claim: nothing of it may ride the
    // per-message dynamic block.
    #expect(!segments.dynamic.contains("# Sensibility"))
}

@Test func sensibility_rendersAfterTheREMPins() {
    let block = try! #require(StudioSensibility.renderStableBlock(sensibilityLines))
    let pins = [REMPin(id: "p1", text: "User prefers answer-first.", createdAt: "2026-08-01T00:00:00Z")]
    let stable = sensibilitySegments(sensibility: block, remPins: pins).stable

    let pinIndex = try! #require(stable.range(of: "# Pinned facts"))
    let sensibilityIndex = try! #require(stable.range(of: "# Sensibility"))
    #expect(pinIndex.lowerBound < sensibilityIndex.lowerBound)
}

@Test func sensibility_isAbsentWhenSheHasNeverWrittenOne() {
    let empty = sensibilitySegments(sensibility: String?.none)
    #expect(!empty.stable.contains("# Sensibility"))
    // An empty string is the same absence, not an empty heading.
    #expect(!sensibilitySegments(sensibility: "   ").stable.contains("# Sensibility"))
}

@Test func sensibility_neverExceedsFourHundredCharactersInTheStableHead() {
    let long = Array(repeating: String(repeating: "weight ", count: 40), count: 5)
    let block = try! #require(StudioSensibility.renderStableBlock(long))
    #expect(block.count <= StudioSensibility.maximumRenderedCharacters)

    let stable = sensibilitySegments(sensibility: block).stable
    let rendered = try! #require(
        stable.components(separatedBy: "\n\n").first { $0.hasPrefix("# Sensibility") }
    )
    #expect(rendered.count <= StudioSensibility.maximumRenderedCharacters)
}

/// BYTE-STABLE ACROSS TURNS. A byte that moves here is a prompt-cache miss on
/// every subsequent turn of the session — the exact cost this feature claims not
/// to have.
@Test func sensibility_rendersByteIdenticalAcrossTurns() {
    let block = try! #require(StudioSensibility.renderStableBlock(sensibilityLines))
    let renders = (0..<3).map { _ in sensibilitySegments(sensibility: block).stable }
    #expect(renders[0] == renders[1])
    #expect(renders[1] == renders[2])
    // And the combined prompt still equals the segments, which is the caching
    // contract the Anthropic adapters verify before splitting system blocks.
    let segments = sensibilitySegments(sensibility: block)
    #expect(segments.combined.contains(segments.stable))
}
