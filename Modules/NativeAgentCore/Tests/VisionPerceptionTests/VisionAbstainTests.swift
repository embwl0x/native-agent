import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import VisionPerception

// MARK: - CALIBRATED REFUSAL
//
// "Confidence labels don't create trust; calibrated refusal and verified
// effects do." — Agent, 2026-08-22.
//
// These are the tests for the first half of that sentence. Abstaining is a
// RESULT here, the abstain rate is a measured quality metric, and a forced
// best guess is a failure — so each of these has a mutation that turns the
// abstain off and must go red.

@Test func abstainsWhenTwoTargetsCannotBeSeparated() throws {
    let scene = Scene.inlineActionScene()
    let percept = try VisionPerceptionCompiler().compile(
        image: scene.image, using: VisionKitTextRecognizer()
    )
    let inline = try #require(percept.rows.first { $0.displayLabel == "Open" })
    let straddled = try #require(
        percept.rows.first { $0.roleGuess == VisionRoleGuess.row && $0.ambiguous != nil }
    )
    // BOTH rows, not one. Marking only one would silently elect a winner,
    // which is the forced best guess this rule exists to refuse.
    #expect(inline.ambiguous != nil)
    #expect(inline.ambiguous?.contains("action points coincide") == true)
    #expect(straddled.ambiguous?.contains("action points coincide") == true)
    // …and the abstain has TEETH: target confidence is capped, so an actuator
    // gating on `target` cannot act on either of them however good the other
    // attributes look.
    #expect(inline.confidence.target <= 0.25)
    #expect(straddled.confidence.target <= 0.25)
    // Bounds and role are NOT punished — they are still well-founded facts,
    // and collapsing them into one score is what the contract forbids.
    #expect(inline.confidence.role >= 0.5)
    #expect(inline.confidence.bounds >= 0.5)
}

@Test func unambiguousRowsInTheSameSceneKeepTheirTargetConfidence() throws {
    let scene = Scene.inlineActionScene()
    let percept = try VisionPerceptionCompiler().compile(
        image: scene.image, using: VisionKitTextRecognizer()
    )
    let quit = try #require(percept.rows.first { $0.displayLabel == "Quit" })
    #expect(quit.ambiguous == nil)
    #expect(quit.confidence.target > 0.5)
    // Over-refusal is its own failure: a lane that abstains on everything is
    // as useless as one that never does.
    #expect(percept.abstain.rate < 1.0)
}

@Test func theAbstainRateIsMeasuredAndSurfaced() throws {
    let scene = Scene.inlineActionScene()
    let percept = try VisionPerceptionCompiler().compile(
        image: scene.image, using: VisionKitTextRecognizer()
    )
    #expect(percept.abstain.considered == percept.rows.count)
    #expect(percept.abstain.abstained == percept.rows.filter { $0.ambiguous != nil }.count)
    #expect(percept.abstain.abstained >= 2)
    #expect(percept.abstain.rate > 0)
    #expect(percept.abstain.reasons["overlapping_targets"] == 2)

    // It is a REPORTED metric, not an internal one. A number nobody can read
    // is not a quality signal.
    guard case .object(let payload) = percept.toJSON(),
          case .object(let abstain)? = payload["abstain"] else {
        Issue.record("percept JSON has no abstain report")
        return
    }
    #expect(abstain["rate"] == .double(percept.abstain.rate))
    #expect(abstain["considered"] != nil)
    #expect(abstain["abstained"] != nil)
    #expect(abstain["reasons"] != nil)
}

@Test func anUnlabeledRegionWithNoRoleGuessAbstainsOnItsOwnAccount() throws {
    let scene = Scene.mainScene()
    let percept = try VisionPerceptionCompiler().compile(
        image: scene.image, using: VisionKitTextRecognizer()
    )
    // The decorative block in the corner: a real region, no caption, no shape
    // we can name. Emitting it as an actionable guess would be the invented
    // affordance the contract forbids; hiding it would be a lie about what is
    // on the screen. It is emitted, and it abstains.
    let unknown = try #require(percept.rows.first { $0.roleGuess == VisionRoleGuess.unknown })
    #expect(unknown.ambiguous?.contains("no role guess") == true)
    #expect(unknown.confidence.target <= 0.25)
    #expect(percept.abstain.reasons["unlabeled_unknown_role"] == 1)
}

@Test func abstainRuleDoesNotFireOnMerePartialOverlap() {
    // A button sitting inside a list row but off to one side is perfectly
    // clickable: its action point is in the row, but the row's action point is
    // NOT in the button. Abstaining here would be over-refusal.
    let compiler = VisionPerceptionCompiler()
    let row = VisionRect(x: 0, y: 100, w: 600, h: 40)
    let button = VisionRect(x: 480, y: 105, w: 100, h: 30)
    let out = compiler.abstain([
        (row, VisionRoleGuess.row, "Report 1"),
        (button, VisionRoleGuess.button, "Open"),
    ])
    #expect(out.isEmpty)
}

@Test func aQueryMatchingTwoRowsEquallyWellAbstainsRatherThanPicking() throws {
    let scene = Scene.inlineActionScene()
    let percept = try VisionPerceptionCompiler().compile(
        image: scene.image, using: VisionKitTextRecognizer()
    )
    // "Alpha" matches all three rows. Picking one would be a coin flip
    // wearing a confidence score.
    let resolved = percept.resolving("Alpha")
    #expect(resolved.count >= 2)
    #expect(resolved.allSatisfy { $0.confidence.target <= 0.25 })
    #expect(resolved.allSatisfy { $0.ambiguous?.contains("matches") == true })

    // A query that names exactly one row resolves, and target RISES — this is
    // the attribute answering "is this THE element you asked for", which is a
    // different question from "is this a button".
    let quit = percept.resolving("Quit")
    #expect(quit.count == 1)
    let row = try #require(quit.first)
    #expect(row.ambiguous == nil)
    let unresolved = try #require(percept.rows.first { $0.displayLabel == "Quit" })
    #expect(row.confidence.target > unresolved.confidence.target)
    #expect(row.confidence.role == unresolved.confidence.role, "role must not move with the query")
}
