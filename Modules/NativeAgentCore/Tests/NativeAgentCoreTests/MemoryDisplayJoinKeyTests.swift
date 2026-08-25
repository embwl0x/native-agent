import Foundation
import Testing
@testable import NativeAgentCore

// Ledger rows: core.memoryDisplayText, core.memoryDisplayText.keyCoverage
//
// Silent-failure class: WRONG VALUE, all-or-nothing. `projectionJoinKey` is the
// join between a USER.md projection bullet (which went through the kind-AWARE
// `display(_:kind:)`) and the raw memory-atom body. Consumers:
// ContextMarkdownCompiler, ContextFlowCoordinator (x3), MemoryV2+TextClip.
//
// The join has TWO failure directions and both are silent:
//   * too STRICT — one row fails to converge and USER.md precoverage collapses
//     for the whole document, so USER.md is injected in full alongside the
//     identical atoms, every turn, with no log line;
//   * too LENIENT — two genuinely different dated facts collapse to one key, one
//     admitted atom "covers" both, and the unadmitted fact is silently deleted
//     from the turn.
// Every test below pins one direction or the other.

/// The real shape of the join as ContextFlowCoordinator runs it: one stored row
/// yields a USER.md bullet (kind-aware display) and an atom body (raw text), and
/// the bullet's key must be covered by the body's key.
private func joins(body: String, kind: String?) -> Bool {
    let bullet = MemoryDisplayText.display(body, kind: kind)
    return MemoryDisplayText.projectionJoinKey(bullet)
        .isCovered(by: MemoryDisplayText.projectionJoinKey(body))
}

@Test("the two renderers converge: a stamped body carries its stamp-stripped USER.md bullet")
func joinKeyConvergesTheTwoRenderers() {
    let stampedBodies = [
        "[2026-07-30] User likes the dry register.",
        "[2026-07-30T09:15:00Z] User likes the dry register.",
        "[2026-07-30 09:15] User likes the dry register.",
        "2026-07-30 User likes the dry register.",
        "2026-07-30T09:15:22Z User likes the dry register.",
        "2026-07-30 — User likes the dry register.",
        "createdAt: User likes the dry register.",
        "recorded on: User likes the dry register.",
        "User likes the dry register.",
    ]
    for body in stampedBodies {
        #expect(joins(body: body, kind: "fact"), "join broke for body: \(body.debugDescription)")
        #expect(
            MemoryDisplayText.projectionJoinKey(body).core == "User likes the dry register.",
            "core drifted for body: \(body.debugDescription)"
        )
    }
}

@Test("a date-critical row keeps its stamp on BOTH sides and still joins")
func joinKeyDateCriticalRowsStillJoin() {
    for kind in ["schedule", "deadline", "appointment", "birthday", "  Milestone  "] {
        let body = "2026-08-01 09:00 Dentist appointment downtown."
        #expect(MemoryDisplayText.display(body, kind: kind) == body)
        #expect(joins(body: body, kind: kind), "date-critical join broke for kind \(kind)")
    }
}

@Test("two dated facts differing only by their date do NOT collide")
func joinKeyDatedFactsDoNotCollide() {
    let august = "2026-08-01 09:00 Dentist appointment downtown."
    let september = "2026-09-01 09:00 Dentist appointment downtown."

    let augustKey = MemoryDisplayText.projectionJoinKey(
        MemoryDisplayText.display(august, kind: "schedule")
    )
    let septemberBody = MemoryDisplayText.projectionJoinKey(september)

    #expect(augustKey.core == septemberBody.core)     // same prose
    #expect(augustKey.stamp != septemberBody.stamp)   // different fact
    #expect(!augustKey.isCovered(by: septemberBody),
            "a September atom must not cover the August fact")
    #expect(augustKey != septemberBody)
}

@Test("Key.isCovered is asymmetric exactly where it must be")
func joinKeyCoverageAsymmetry() {
    let stampless = MemoryDisplayText.Key(core: "User likes X", stamp: nil)
    let stamped = MemoryDisplayText.Key(core: "User likes X", stamp: "[2026-07-30]")
    let otherStamp = MemoryDisplayText.Key(core: "User likes X", stamp: "[2026-08-30]")
    let otherCore = MemoryDisplayText.Key(core: "User likes Y", stamp: nil)

    // Renderer convergence (the safe direction): a stampless fact is carried by
    // any body with the same core.
    #expect(stampless.isCovered(by: stamped))
    #expect(stampless.isCovered(by: stampless))
    #expect(stampless.isCovered(by: otherStamp))
    // Fact-distinctness (the dangerous direction): a fact that KEPT its stamp
    // demands the identical stamp.
    #expect(stamped.isCovered(by: stamped))
    #expect(!stamped.isCovered(by: otherStamp))
    #expect(!stamped.isCovered(by: stampless))
    // A different core never joins.
    #expect(!stampless.isCovered(by: otherCore))
    #expect(!otherCore.isCovered(by: stamped))
    // Empty-stamp is treated as no stamp, not as a distinct stamp.
    #expect(MemoryDisplayText.Key(core: "User likes X", stamp: "").isCovered(by: stamped))
}

@Test("the stripper runs to a fixpoint and everything removed becomes the stamp")
func joinKeyStripsStackedStampsToFixpoint() {
    let key = MemoryDisplayText.projectionJoinKey("2026-01-01 2026-01-02 stacked stamps here")
    #expect(key.core == "stacked stamps here")
    #expect(key.stamp == "2026-01-01 2026-01-02")
    #expect(key.description == "2026-01-01 2026-01-02 stacked stamps here")
}

@Test("a STACKED-stamp row fails the join in the SAFE direction, never the lenient one")
func joinKeyStackedStampRowFailsSafely() {
    // CHARACTERIZATION of a real asymmetry: `display(_:kind:)` applies the three
    // strippers ONCE, while `projectionJoinKey` runs them to a fixpoint. So a
    // body carrying two stacked stamps yields a bullet that still holds the
    // second stamp, and the two keys agree on `core` but not on `stamp`.
    //
    // That is the SAFE failure — the fact is not covered, so USER.md stays
    // injected in full — and it must stay that way. If this ever starts
    // "passing" by making `isCovered` ignore a stamp mismatch, the September /
    // August dentist collapse comes back with it.
    let body = "2026-01-01 2026-01-02 User likes the dry register."
    let bullet = MemoryDisplayText.display(body, kind: "fact")
    #expect(bullet == "2026-01-02 User likes the dry register.")

    let bulletKey = MemoryDisplayText.projectionJoinKey(bullet)
    let bodyKey = MemoryDisplayText.projectionJoinKey(body)
    #expect(bulletKey.core == bodyKey.core)
    #expect(bulletKey.stamp == "2026-01-02")
    #expect(bodyKey.stamp == "2026-01-01 2026-01-02")
    #expect(!bulletKey.isCovered(by: bodyKey),
            "a stamp mismatch must fail the join, not be waved through")
}

@Test("whitespace and CRLF fold identically on both sides of the join")
func joinKeyFoldsWhitespace() {
    let body = "[2026-07-30]\r\n  User   likes\tthe\r\ndry  register."
    let key = MemoryDisplayText.projectionJoinKey(body)
    #expect(key.core == "User likes the dry register.")
    #expect(joins(body: body, kind: "fact"))
    #expect(MemoryDisplayText.display(body, kind: "fact") == "User likes the dry register.")
}

@Test("a row that is nothing but a stamp still joins with itself")
func joinKeyStampOnlyRowJoinsWithItself() {
    // `display` falls back to the original when stripping empties the string;
    // `projectionJoinKey` falls back to the whole string as the core. The two
    // fallbacks must agree, or one such row disables precoverage document-wide.
    let body = "[2026-07-30]"
    #expect(MemoryDisplayText.display(body, kind: nil) == body)
    let key = MemoryDisplayText.projectionJoinKey(body)
    #expect(key.core == body)
    #expect(key.stamp == nil)
    #expect(joins(body: body, kind: nil))
    #expect(joins(body: "2026-07-30", kind: nil))
}

@Test("empty and whitespace-only text produce an empty key, not a phantom match")
func joinKeyEmptyText() {
    #expect(MemoryDisplayText.display("", kind: nil) == "")
    #expect(MemoryDisplayText.display("   \n\t ", kind: nil) == "")
    let key = MemoryDisplayText.projectionJoinKey("   \n\t ")
    #expect(key.isEmpty)
    #expect(key.core.isEmpty)
    #expect(key.stamp == nil)
}

@Test("the key is Hashable on the PAIR, so a set does not merge two dated facts")
func joinKeyHashesOnThePair() {
    let keys: Set<MemoryDisplayText.Key> = [
        MemoryDisplayText.projectionJoinKey("2026-08-01 09:00 Dentist appointment downtown."),
        MemoryDisplayText.projectionJoinKey("2026-09-01 09:00 Dentist appointment downtown."),
        MemoryDisplayText.projectionJoinKey("Dentist appointment downtown."),
    ]
    #expect(keys.count == 3)
}
