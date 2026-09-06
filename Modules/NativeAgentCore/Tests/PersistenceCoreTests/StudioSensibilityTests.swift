import Testing
import Foundation
@testable import PersistenceCore
import NativeAgentCore

// SENSIBILITY — personality-depth item 10. Three promises:
//   1. It is STAGED only by a canon change.
//   2. It is WRITTEN only by her seat, in a live turn.
//   3. It RENDERS as one short block, ≤400 chars, byte-stable across turns.

private func sensibilityRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("studio-sens-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let herTurn = StudioCanonTurnProvenance(surface: "chat", turnID: "run-1")

private func canonRow(
    proposalID: String,
    title: String,
    decidedAt: String
) -> StudioCanonRow {
    StudioCanonRow(
        proposalID: proposalID,
        action: .promote,
        standing: .canon,
        workTitle: title,
        workCreator: nil,
        decidedAt: decidedAt,
        decidedBy: StudioCanonSeat.agent,
        decidedOnSurface: herTurn.surface,
        decidedInTurn: herTurn.turnID,
        evidenceKind: .recurrence,
        evidenceEntryIDs: ["e1", "e2", "e3"],
        note: nil
    )
}

// MARK: - Staged only by a canon change

@Test func sensibility_isNotStagedWithoutACanonChange() async throws {
    let root = try sensibilityRoot("unstaged")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeStudioStore(dataRoot: root)

    // An empty museum stages nothing. There is no clock, no cadence, and no
    // "it's been a while" that could stage one.
    #expect(await store.sensibilityStaging() == .notStaged)
    #expect(await store.currentSensibility() == nil)
    #expect(await store.renderedSensibilityBlock() == nil)
}

@Test func sensibility_isStagedByACanonRowAndClearedByWriting() async throws {
    let root = try sensibilityRoot("staged")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeStudioStore(dataRoot: root)

    try await store.appendCanonRow(
        canonRow(proposalID: "p1", title: "Meuser House", decidedAt: "2026-09-02T10:00:00Z")
    )
    guard case .staged(let since) = await store.sensibilityStaging() else {
        Issue.record("a decided canon row must stage a distillation")
        return
    }
    #expect(since == "2026-09-02T10:00:00Z")

    _ = try await store.appendSensibility(
        lines: ["I keep choosing work that admits its own weight."],
        decidedBy: StudioCanonSeat.agent,
        provenance: herTurn,
        // 2026-09-02T12:00:00Z — AFTER the canon row's 10:00 decision. Staging
        // compares the newest `decidedAt` against the last write, so a write
        // stamped before the decision reads as older than the thing it is
        // supposed to answer and stays staged.
        now: Date(timeIntervalSince1970: 1_788_350_400)
    )
    // Written; nothing is staged any more, and nothing had to clear a flag.
    #expect(await store.sensibilityStaging() == .notStaged)
}

@Test func sensibility_refusesWhenNothingHasChangedInTheCanon() async throws {
    let root = try sensibilityRoot("not-staged-write")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeStudioStore(dataRoot: root)

    await #expect(throws: StudioSensibility.Error.notStaged) {
        _ = try await store.appendSensibility(
            lines: ["Something I feel like saying today."],
            decidedBy: StudioCanonSeat.agent,
            provenance: herTurn
        )
    }
    #expect(!FileManager.default.fileExists(atPath: store.sensibilityPath.path))
}

// MARK: - Written only by her seat

@Test func sensibility_refusesEveryOwnerSeat() async throws {
    let root = try sensibilityRoot("owner-seat")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeStudioStore(dataRoot: root)
    try await store.appendCanonRow(
        canonRow(proposalID: "p1", title: "Meuser House", decidedAt: "2026-09-02T10:00:00Z")
    )

    for seat in StudioCanonSeat.ownerSeats.sorted() {
        await #expect(throws: StudioSensibility.Error.notFromAgentSeat(seat)) {
            _ = try await store.appendSensibility(
                lines: ["User's idea of what she cares about."],
                decidedBy: seat,
                provenance: herTurn
            )
        }
    }
    #expect(!FileManager.default.fileExists(atPath: store.sensibilityPath.path))
}

/// A background pass, a bridge run and an approval replay all arrive with no
/// live turn. None of them may author it.
@Test func sensibility_refusesWithoutALiveTurn() async throws {
    let root = try sensibilityRoot("no-turn")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeStudioStore(dataRoot: root)
    try await store.appendCanonRow(
        canonRow(proposalID: "p1", title: "Meuser House", decidedAt: "2026-09-02T10:00:00Z")
    )

    await #expect(throws: StudioSensibility.Error.decisionHasNoLiveTurn) {
        _ = try await store.appendSensibility(
            lines: ["Written by nobody in particular."],
            decidedBy: StudioCanonSeat.agent,
            provenance: StudioCanonTurnProvenance(surface: "", turnID: "")
        )
    }
    #expect(!FileManager.default.fileExists(atPath: store.sensibilityPath.path))
}

// MARK: - Append-only history + current

@Test func sensibility_keepsEveryEarlierDistillationAndReadsTheLastAsCurrent() async throws {
    let root = try sensibilityRoot("history")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeStudioStore(dataRoot: root)

    try await store.appendCanonRow(
        canonRow(proposalID: "p1", title: "Meuser House", decidedAt: "2026-03-01T10:00:00Z")
    )
    _ = try await store.appendSensibility(
        lines: ["In March I cared about restraint."],
        decidedBy: StudioCanonSeat.agent,
        provenance: herTurn,
        now: Date(timeIntervalSince1970: 1_740_825_000)
    )
    try await store.appendCanonRow(
        canonRow(proposalID: "p2", title: "Hollow Knight", decidedAt: "2026-09-01T10:00:00Z")
    )
    _ = try await store.appendSensibility(
        lines: ["By September I wanted work that risks being ugly."],
        decidedBy: StudioCanonSeat.agent,
        provenance: herTurn,
        now: Date(timeIntervalSince1970: 1_756_728_000)
    )

    let history = await store.readSensibilityHistory()
    #expect(history.count == 2)
    // Changing her mind is development; the earlier one is not rewritten.
    #expect(history.first?.lines == ["In March I cared about restraint."])
    #expect(await store.currentSensibility()
        == ["By September I wanted work that risks being ugly."])
}

@Test func sensibility_keepsAtMostThreeLinesOfHers() async throws {
    let root = try sensibilityRoot("three-lines")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeStudioStore(dataRoot: root)
    try await store.appendCanonRow(
        canonRow(proposalID: "p1", title: "Meuser House", decidedAt: "2026-09-02T10:00:00Z")
    )
    let written = try await store.appendSensibility(
        lines: ["one", "", "two", "three", "four"],
        decidedBy: StudioCanonSeat.agent,
        provenance: herTurn
    )
    #expect(written == ["one", "two", "three"])
}

// MARK: - The rendered block

@Test func sensibility_rendersUnderFourHundredCharactersOnALineBoundary() {
    let long = String(repeating: "a", count: 180)
    let block = StudioSensibility.renderStableBlock([long, long, long])
    let rendered = try! #require(block)
    #expect(rendered.count <= StudioSensibility.maximumRenderedCharacters)
    #expect(rendered.hasPrefix(StudioSensibility.stableHeading))
    // Cut between lines, never mid-sentence: every retained line is whole.
    for line in rendered.components(separatedBy: "\n").dropFirst() {
        #expect(line == long)
    }
}

@Test func sensibility_isAbsentWhenEmpty() {
    #expect(StudioSensibility.renderStableBlock([]) == nil)
    #expect(StudioSensibility.renderStableBlock(["", "   "]) == nil)
}

/// BYTE-STABLE ACROSS TURNS. Nothing clock-, turn- or count-derived may enter
/// the block, because it lives in the cached prefix: a byte that moves is a
/// cache miss on every turn for the rest of the session.
@Test func sensibility_rendersIdenticalBytesOnEveryRead() async throws {
    let root = try sensibilityRoot("stable")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeStudioStore(dataRoot: root)
    try await store.appendCanonRow(
        canonRow(proposalID: "p1", title: "Meuser House", decidedAt: "2026-09-02T10:00:00Z")
    )
    _ = try await store.appendSensibility(
        lines: [
            "I keep choosing work that admits its own weight.",
            "Cleverness reads as fear to me now.",
        ],
        decidedBy: StudioCanonSeat.agent,
        provenance: herTurn
    )

    let first = await store.renderedSensibilityBlock()
    let second = await store.renderedSensibilityBlock()
    let third = await SwiftNativeStudioStore(dataRoot: root).renderedSensibilityBlock()
    #expect(first != nil)
    #expect(first == second)
    #expect(second == third)
    #expect(first?.contains("2026") == false, "no stamp may reach the cached prefix")
    #expect(first?.hasPrefix("# Sensibility\n") == true)
    #expect((first?.count ?? .max) <= StudioSensibility.maximumRenderedCharacters)
}
