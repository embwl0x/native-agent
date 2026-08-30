import CoreGraphics
import Foundation
import Testing
@testable import MacControl

/// THE FULL HAND — pins for `MacHandRepertoire`.
///
/// HERMETICITY: `MacHandRepertoire` is a pure planner that posts nothing, so
/// there is no sink in this file at all. No test here can move the real mouse
/// or press a real key — not because a fake intercepts it, but because the code
/// under test has no route to the host.
///
/// Every gesture is pinned as an EXACT event sequence, not a shape assertion. A
/// test that only checks "the plan is non-empty" would survive dropping the
/// release from a drag, which is the failure this file exists to prevent.

// MARK: - Helpers

private func mice(_ plan: [MacHandStep]) -> [MacMouseEvent] {
    plan.compactMap(\.mouseEvent)
}

private func keys(_ plan: [MacHandStep]) -> [MacKeyEvent] {
    plan.compactMap(\.keyEvent)
}

private func scrolls(_ plan: [MacHandStep]) -> [MacScrollEvent] {
    plan.compactMap(\.scrollEvent)
}

private struct BodyBlewUp: Error, Equatable {}

/// Index safely. A pin that TRAPS on a broken planner aborts the whole test
/// process and hides every other pin's verdict — which is exactly what happened
/// the first time the hold-release mutation was run. A failing pin must fail
/// loudly and let the rest of the suite report.
extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Pointer: move / hover / press / release

@Test func heldKeySetIsSimultaneousDeduplicatedAndKeepsSequentialKeysSeparate() throws {
    let held = try MacKeySyntax.parseHeldKeys("w d shift w ctrl+d")
    #expect(held.keys == [13, 2])
    #expect(held.modifiers == [.shift, .control])
    let plan = try MacHandRepertoire.hold(modifiers: held.modifiers, keys: held.keys) {
        [.wait(milliseconds: 200)]
    }
    let dwell = try #require(plan.firstIndex { if case .wait = $0 { return true }; return false })
    #expect(keys(Array(plan[..<dwell])).allSatisfy { $0.down })
    #expect(keys(Array(plan[(dwell + 1)...])).allSatisfy { !$0.down })
    #expect(MacHandRepertoire.isBalanced(plan))
    let sequence = try MacKeySyntax.parseChords("w d").flatMap(MacHandRepertoire.chord)
    #expect(keys(sequence).map(\.down) == [true, false, true, false])
    #expect(throws: (any Error).self) { try MacKeySyntax.parseHeldKeys("w not-a-key") }
    #expect(throws: (any Error).self) { try MacKeySyntax.parseHeldKeys("") }
    #expect(throws: (any Error).self) {
        try MacKeySyntax.parseHeldKeys(Array(repeating: "w", count: 65).joined(separator: " "))
    }
}

@Test func moveEmitsExactlyOneMoveAtThePoint() {
    let plan = MacHandRepertoire.move(to: CGPoint(x: 120, y: 340))
    #expect(plan == [.mouse(MacMouseEvent(phase: .move, button: .left, x: 120, y: 340, clickCount: 1))])
    #expect(MacHandRepertoire.isBalanced(plan))
}

@Test func hoverIsAMoveFollowedByADwellTheCallerHonours() {
    let plan = MacHandRepertoire.hover(at: CGPoint(x: 10, y: 20), dwellMs: 250)
    #expect(plan == [
        .mouse(MacMouseEvent(phase: .move, button: .left, x: 10, y: 20, clickCount: 1)),
        .wait(milliseconds: 250),
    ])
    #expect(MacHandRepertoire.plannedWaitMilliseconds(in: plan) == 250)
}

@Test func dwellIsClampedRatherThanTrusted() {
    let plan = MacHandRepertoire.hover(at: .zero, dwellMs: 10_000_000)
    #expect(MacHandRepertoire.plannedWaitMilliseconds(in: plan) == MacHandRepertoire.maximumWaitMilliseconds)
    let negative = MacHandRepertoire.hover(at: .zero, dwellMs: -5)
    #expect(MacHandRepertoire.plannedWaitMilliseconds(in: negative) == 0)
}

@Test func pressAloneLeavesTheButtonDownAndSaysSo() throws {
    let plan = try MacHandRepertoire.press(button: .left, at: CGPoint(x: 5, y: 6))
    #expect(plan == [.mouse(MacMouseEvent(phase: .down, button: .left, x: 5, y: 6, clickCount: 1))])
    // The invariant helper must NOTICE this — an unbalanced plan that reports
    // balanced would make every other balance pin here vacuous.
    #expect(MacHandRepertoire.residualHeldButtons(in: plan) == [.left])
    #expect(!MacHandRepertoire.isBalanced(plan))
}

@Test func pressThenReleasePairsToNeutral() throws {
    let point = CGPoint(x: 5, y: 6)
    let plan = try MacHandRepertoire.press(button: .right, at: point)
        + MacHandRepertoire.release(button: .right, at: point)
    #expect(plan == [
        .mouse(MacMouseEvent(phase: .down, button: .right, x: 5, y: 6, clickCount: 1)),
        .mouse(MacMouseEvent(phase: .up, button: .right, x: 5, y: 6, clickCount: 1)),
    ])
    #expect(MacHandRepertoire.isBalanced(plan))
}

@Test func pressAndHoldIsBalancedAndCarriesTheDwellBetween() throws {
    let plan = try MacHandRepertoire.pressAndHold(button: .left, at: CGPoint(x: 1, y: 2), holdMs: 800)
    #expect(plan == [
        .mouse(MacMouseEvent(phase: .down, button: .left, x: 1, y: 2, clickCount: 1)),
        .wait(milliseconds: 800),
        .mouse(MacMouseEvent(phase: .up, button: .left, x: 1, y: 2, clickCount: 1)),
    ])
    #expect(MacHandRepertoire.isBalanced(plan))
}

// MARK: - Click

@Test func singleClickIsMoveThenDownThenUp() throws {
    let plan = try MacHandRepertoire.click(button: .left, at: CGPoint(x: 100, y: 200))
    #expect(plan == [
        .mouse(MacMouseEvent(phase: .move, button: .left, x: 100, y: 200, clickCount: 1)),
        .mouse(MacMouseEvent(phase: .down, button: .left, x: 100, y: 200, clickCount: 1)),
        .mouse(MacMouseEvent(phase: .up, button: .left, x: 100, y: 200, clickCount: 1)),
    ])
    #expect(MacHandRepertoire.isBalanced(plan))
}

@Test func doubleClickCarriesAscendingClickCount() throws {
    let plan = try MacHandRepertoire.click(button: .left, at: CGPoint(x: 3, y: 4), count: 2)
    #expect(mice(plan).map(\.phase) == [.move, .down, .up, .down, .up])
    #expect(mice(plan).map(\.clickCount) == [1, 1, 1, 2, 2])
    #expect(MacHandRepertoire.isBalanced(plan))
}

@Test func tripleClickCarriesAscendingClickCountThroughThree() throws {
    let plan = try MacHandRepertoire.click(button: .left, at: CGPoint(x: 3, y: 4), count: 3)
    #expect(mice(plan).map(\.phase) == [.move, .down, .up, .down, .up, .down, .up])
    #expect(mice(plan).map(\.clickCount) == [1, 1, 1, 2, 2, 3, 3])
}

@Test func clickCountIsClampedToWhatMacOSUnderstands() throws {
    let plan = try MacHandRepertoire.click(button: .left, at: .zero, count: 9)
    #expect(mice(plan).map(\.clickCount) == [1, 1, 1, 2, 2, 3, 3])
    let floored = try MacHandRepertoire.click(button: .left, at: .zero, count: 0)
    #expect(mice(floored).map(\.clickCount) == [1, 1, 1])
}

@Test func rightClickEmitsTheRightButtonOnEveryEvent() throws {
    let plan = try MacHandRepertoire.click(button: .right, at: CGPoint(x: 8, y: 9))
    #expect(mice(plan).allSatisfy { $0.button == .right })
    #expect(mice(plan).map(\.phase) == [.move, .down, .up])
}

@Test func middleClickRefusesInsteadOfSilentlyBecomingALeftClick() {
    // The dangerous failure is substitution: a "middle click" that opens the
    // link in the current tab and reports success. Refusal must be typed and
    // must name what the seam is missing.
    #expect(throws: MacHandUnsupported.self) {
        _ = try MacHandRepertoire.click(button: .middle, at: .zero)
    }
    do {
        _ = try MacHandRepertoire.click(button: .middle, at: .zero)
        Issue.record("middle click should not plan")
    } catch let error as MacHandUnsupported {
        #expect(error.limit == .middleButtonNotAtSeam)
        #expect(error.needed.contains("otherMouseDown"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
    #expect(MacHandButton.middle.seamButton == nil)
    #expect(MacHandButton.left.seamButton == .left)
    #expect(MacHandButton.right.seamButton == .right)
}

@Test func everyPointerGestureRefusesTheMiddleButton() {
    #expect(throws: MacHandUnsupported.self) { _ = try MacHandRepertoire.press(button: .middle, at: .zero) }
    #expect(throws: MacHandUnsupported.self) { _ = try MacHandRepertoire.release(button: .middle, at: .zero) }
    #expect(throws: MacHandUnsupported.self) { _ = try MacHandRepertoire.pressAndHold(button: .middle, at: .zero, holdMs: 1) }
    #expect(throws: MacHandUnsupported.self) {
        _ = try MacHandRepertoire.dragPath(button: .middle, through: [.zero, CGPoint(x: 1, y: 1)])
    }
}

// MARK: - Drag: the gesture that separates a hand from a clicker

@Test func dragEmitsPressPlusNMovesPlusRelease() throws {
    for steps in [2, 3, 7, 20] {
        let plan = try MacHandRepertoire.drag(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 50),
            steps: steps
        )
        let events = mice(plan)
        #expect(events.count == steps + 2, "steps=\(steps)")
        #expect(events.first?.phase == .down)
        #expect(events.last?.phase == .up)
        #expect(events.dropFirst().dropLast().allSatisfy { $0.phase == .drag })
        #expect(MacHandRepertoire.isBalanced(plan))
    }
}

@Test func dragIntermediatePointsAreMonotonicAlongThePath() throws {
    let plan = try MacHandRepertoire.drag(
        from: CGPoint(x: 10, y: 100),
        to: CGPoint(x: 210, y: 0),
        steps: 10
    )
    let events = mice(plan)
    let xs = events.map(\.x)
    let ys = events.map(\.y)
    // x strictly increases toward the destination, y strictly decreases —
    // a teleport (one jump then a hold) fails both.
    #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 >= $1 })
    // No intermediate move may sit on top of the origin: that is the teleport
    // signature (press at A, first move already at B).
    #expect((events[safe: 1]?.x ?? 0) > 10)
    #expect((events[safe: 1]?.x ?? .infinity) < 210)
    // The last interpolated move lands exactly on the destination, so the
    // release introduces no jump the app has not already seen.
    #expect(events[safe: events.count - 2]?.x == 210)
    #expect(events[safe: events.count - 2]?.y == 0)
    #expect(events.last?.x == 210)
    #expect(events.last?.y == 0)
}

@Test func dragPathTravelsThroughEveryWaypointInOrder() throws {
    let waypoints = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 50, y: 0),
        CGPoint(x: 50, y: 50),
        CGPoint(x: 0, y: 50),
    ]
    let plan = try MacHandRepertoire.dragPath(through: waypoints, stepsPerSegment: 1)
    let events = mice(plan)
    // press + 3 segments × 1 move + release
    #expect(events.count == 5)
    #expect(events.map(\.phase) == [.down, .drag, .drag, .drag, .up])
    #expect(events.map { CGPoint(x: $0.x, y: $0.y) } == [
        waypoints[0], waypoints[1], waypoints[2], waypoints[3], waypoints[3],
    ])
    #expect(MacHandRepertoire.isBalanced(plan))
}

@Test func dragPathInterpolatesInsideEverySegment() throws {
    let plan = try MacHandRepertoire.dragPath(
        through: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)],
        stepsPerSegment: 5
    )
    let events = mice(plan)
    #expect(events.count == 1 + (2 * 5) + 1)
    #expect(events.map(\.phase) == [.down] + Array(repeating: .drag, count: 10) + [.up])
    // Corner is hit exactly, and both legs move by even fifths.
    #expect(events[safe: 5]?.x == 10 && events[safe: 5]?.y == 0)
    #expect(events[safe: 1]?.x == 2)
    #expect(events[safe: 10]?.y == 10)
}

@Test func dragPathHoldDwellsAfterPressAndBeforeRelease() throws {
    let plan = try MacHandRepertoire.dragPath(
        through: [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0)],
        stepsPerSegment: 2,
        holdMs: 120
    )
    #expect(plan == [
        .mouse(MacMouseEvent(phase: .down, button: .left, x: 0, y: 0, clickCount: 1)),
        .wait(milliseconds: 120),
        .mouse(MacMouseEvent(phase: .drag, button: .left, x: 2, y: 0, clickCount: 1)),
        .mouse(MacMouseEvent(phase: .drag, button: .left, x: 4, y: 0, clickCount: 1)),
        .wait(milliseconds: 120),
        .mouse(MacMouseEvent(phase: .up, button: .left, x: 4, y: 0, clickCount: 1)),
    ])
    // The dwell steps must not disturb the drag arithmetic.
    #expect(mice(plan).count == 2 + 2)
    #expect(MacHandRepertoire.isBalanced(plan))
}

@Test func pacedDragDistributesExactTravelAcrossMovesWithoutEndpointDwell() throws {
    let plan = try MacHandRepertoire.drag(button: .right, from: .zero,
        to: CGPoint(x: 100, y: 50), steps: 18, travelMs: 301)
    let waits = plan.compactMap { step -> Int? in
        if case .wait(let milliseconds) = step { return milliseconds }; return nil
    }
    #expect(waits.count == 18)
    #expect(waits.reduce(0, +) == 301)
    #expect(waits.allSatisfy { $0 == 16 || $0 == 17 })
    #expect(mice(plan).count == 20)
    #expect(mice(plan).allSatisfy { $0.button == .right })
    #expect(plan.last?.mouseEvent?.phase == .up)
    #expect(plan.dropLast().last?.mouseEvent?.phase == .drag)
    #expect(MacHandRepertoire.isBalanced(plan))
    let legacy = try MacHandRepertoire.drag(from: .zero, to: CGPoint(x: 1, y: 1), steps: 4)
    #expect(legacy.count == mice(legacy).count)
}

@Test func dragStepsAreClampedSoOneGestureCannotFloodTheHost() throws {
    let tiny = try MacHandRepertoire.drag(from: .zero, to: CGPoint(x: 1, y: 1), steps: 0)
    #expect(mice(tiny).count == MacHandRepertoire.minimumDragSteps + 2)
    let huge = try MacHandRepertoire.drag(from: .zero, to: CGPoint(x: 1, y: 1), steps: 100_000)
    #expect(mice(huge).count == MacHandRepertoire.maximumDragSteps + 2)
}

@Test func theTeleportFloorAppliesToTheTwoPointDragButNotToAGivenPath() throws {
    // A→B with steps:1 would be a teleport, so it is floored to 2.
    let straight = try MacHandRepertoire.drag(from: .zero, to: CGPoint(x: 10, y: 0), steps: 1)
    #expect(mice(straight).filter { $0.phase == .drag }.count == MacHandRepertoire.minimumDragSteps)
    // An explicit path already chose its own density; honouring it literally is
    // what lets a caller replay a real hand-drawn path point for point.
    let path = try MacHandRepertoire.dragPath(
        through: [.zero, CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)],
        stepsPerSegment: 1
    )
    #expect(mice(path).filter { $0.phase == .drag }.count == 2)
}

@Test func dragPathRefusesAPathThatIsNotAPath() {
    #expect(throws: MacHandRepertoire.MacHandPathError.needsAtLeastTwoPoints(1)) {
        _ = try MacHandRepertoire.dragPath(through: [.zero])
    }
    #expect(throws: MacHandRepertoire.MacHandPathError.needsAtLeastTwoPoints(0)) {
        _ = try MacHandRepertoire.dragPath(through: [])
    }
}

@Test func aDragIsNeverJustAClick() throws {
    // The whole point of the file, stated as a pin: the drag plan must contain
    // real travel between press and release. A click-shaped "drag" fails here.
    let plan = try MacHandRepertoire.drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 300, y: 300), steps: 12)
    let dragMoves = mice(plan).filter { $0.phase == .drag }
    #expect(dragMoves.count == 12)
    #expect(Set(dragMoves.map { "\($0.x),\($0.y)" }).count == 12)
}

// MARK: - Scroll and swipe

@Test func scrollEmitsOneScrollEventWithTheGivenDeltas() {
    let plan = MacHandRepertoire.scroll(dx: -3, dy: 7, unit: .pixel)
    #expect(plan == [.scroll(MacScrollEvent(deltaX: -3, deltaY: 7, unit: .pixel))])
}

@Test func swipeSplitsTravelIntoStepsThatSumExactly() {
    for (amount, steps) in [(100, 5), (7, 3), (1, 5), (37, 4)] {
        let plan = MacHandRepertoire.swipe(direction: .down, amount: amount, steps: steps)
        let total = scrolls(plan).reduce(0) { $0 + Int(abs($1.deltaY)) }
        #expect(total == amount, "amount=\(amount) steps=\(steps)")
        #expect(scrolls(plan).allSatisfy { $0.deltaY < 0 && $0.deltaX == 0 })
    }
}

@Test func swipeDirectionsCarryTheRightAxisAndSign() {
    #expect(scrolls(MacHandRepertoire.swipe(direction: .up, amount: 10, steps: 1)) == [
        MacScrollEvent(deltaX: 0, deltaY: 10, unit: .pixel)
    ])
    #expect(scrolls(MacHandRepertoire.swipe(direction: .down, amount: 10, steps: 1)) == [
        MacScrollEvent(deltaX: 0, deltaY: -10, unit: .pixel)
    ])
    #expect(scrolls(MacHandRepertoire.swipe(direction: .left, amount: 10, steps: 1)) == [
        MacScrollEvent(deltaX: 10, deltaY: 0, unit: .pixel)
    ])
    #expect(scrolls(MacHandRepertoire.swipe(direction: .right, amount: 10, steps: 1)) == [
        MacScrollEvent(deltaX: -10, deltaY: 0, unit: .pixel)
    ])
}

@Test func swipeOfNothingIsNothing() {
    #expect(MacHandRepertoire.swipe(direction: .up, amount: 0).isEmpty)
}

@Test func pinchAndRotateRefuseHonestlyRatherThanFakingADifferentGesture() {
    do {
        _ = try MacHandRepertoire.pinch(scale: 1.5)
        Issue.record("pinch should not plan")
    } catch let error as MacHandUnsupported {
        #expect(error.limit == .pinchNotAtSeam)
    } catch {
        Issue.record("unexpected error \(error)")
    }
    do {
        _ = try MacHandRepertoire.rotate(degrees: 90)
        Issue.record("rotate should not plan")
    } catch let error as MacHandUnsupported {
        #expect(error.limit == .rotateNotAtSeam)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

// MARK: - Keyboard

@Test func typeEmitsADownUpPairPerCharacterCarryingTheText() {
    let plan = MacHandRepertoire.type(text: "hi")
    #expect(keys(plan).count == 4)
    #expect(keys(plan).map(\.down) == [true, false, true, false])
    #expect(keys(plan).map(\.unicodeText) == ["h", "h", "i", "i"])
    #expect(MacHandRepertoire.isBalanced(plan))
}

@Test func keyCarriesModifierFlagsOnBothTheDownAndTheUp() {
    let plan = MacHandRepertoire.key(code: 36, modifiers: [.command, .shift])
    #expect(plan == [
        .key(MacKeyEvent(keyCode: 36, down: true, modifiers: [.command, .shift])),
        .key(MacKeyEvent(keyCode: 36, down: false, modifiers: [.command, .shift])),
    ])
    // Flags on the UP too: an app tracking modifier state from events would
    // otherwise believe ⌘ is still held after the key returns.
    #expect(keys(plan).allSatisfy { $0.modifiers.contains(.command) })
    #expect(MacHandRepertoire.isBalanced(plan))
}

@Test func chordNeverLeavesAModifierDown() {
    let chord = MacKeyChord(modifiers: [.command, .option], keyCode: 8, source: "cmd+opt+c")
    let plan = MacHandRepertoire.chord(chord)
    #expect(plan == [
        .key(MacKeyEvent(keyCode: 8, down: true, modifiers: [.command, .option])),
        .key(MacKeyEvent(keyCode: 8, down: false, modifiers: [.command, .option])),
    ])
    #expect(MacHandRepertoire.residualHeldKeys(in: plan).isEmpty)
    #expect(MacHandRepertoire.isBalanced(plan))
}

// MARK: - Hold: the release must be unavoidable

@Test func holdPressesTheModifierRunsTheBodyAndReleasesIt() throws {
    let plan = try MacHandRepertoire.hold(modifiers: .option) {
        try MacHandRepertoire.drag(from: .zero, to: CGPoint(x: 10, y: 0), steps: 2)
    }
    let keyEvents = keys(plan)
    #expect(keyEvents.count == 2)
    #expect(keyEvents[safe: 0] == MacKeyEvent(keyCode: MacHandRepertoire.ModifierKeyCode.option, down: true, modifiers: .option))
    #expect(keyEvents[safe: 1] == MacKeyEvent(keyCode: MacHandRepertoire.ModifierKeyCode.option, down: false))
    // Ordering: the modifier is down BEFORE the press and up AFTER the release.
    #expect(plan.first?.keyEvent?.down == true)
    #expect(plan.last?.keyEvent?.down == false)
    #expect(mice(plan).count == 4)
    #expect(MacHandRepertoire.isBalanced(plan))
    #expect(MacHandRepertoire.residualHeldKeys(in: plan).isEmpty)
}

@Test func holdReleasesEveryModifierInReversePressOrder() throws {
    let plan = try MacHandRepertoire.hold(modifiers: [.command, .shift, .control]) {
        MacHandRepertoire.key(code: 0)
    }
    let downs = keys(plan).filter(\.down).map(\.keyCode)
    let ups = keys(plan).filter { !$0.down }.map(\.keyCode)
    let held = MacHandRepertoire.modifierKeyCodes([.command, .shift, .control])
    #expect(downs.prefix(held.count) == ArraySlice(held))
    #expect(ups.suffix(held.count) == ArraySlice(held.reversed()))
    #expect(keys(plan).suffix(held.count).map(\.modifiers) == [[.command, .control], [.command], []])
    #expect(MacHandRepertoire.residualHeldKeys(in: plan).isEmpty)
}

@Test func holdReleasesEvenWhenTheBodyThrows() {
    do {
        _ = try MacHandRepertoire.hold(modifiers: [.command, .shift], keys: [13]) {
            throw BodyBlewUp()
        }
        Issue.record("hold should propagate the body's failure")
    } catch let failure as MacHandHoldFailure {
        #expect(failure.underlying as? BodyBlewUp == BodyBlewUp())
        // THE PIN: the error carries a plan that is safe to post and ends the
        // hand in neutral. A stuck ⌘ or ⇧ silently corrupts every later
        // keystroke system-wide, including User's own typing.
        #expect(MacHandRepertoire.residualHeldKeys(in: failure.recoveryPlan).isEmpty)
        #expect(MacHandRepertoire.isBalanced(failure.recoveryPlan))
        #expect(failure.recoveryPlan.count == 6)
        #expect(keys(failure.recoveryPlan).filter { !$0.down }.map(\.keyCode) == [13, MacHandRepertoire.ModifierKeyCode.shift, MacHandRepertoire.ModifierKeyCode.command])
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func holdReleasesWhenAnInnerGestureThrows() {
    // The realistic error path: the body plans a gesture the seam refuses
    // (middle button) partway through a hold.
    do {
        _ = try MacHandRepertoire.hold(modifiers: .option) {
            try MacHandRepertoire.click(button: .middle, at: .zero)
        }
        Issue.record("hold should propagate the unsupported gesture")
    } catch let failure as MacHandHoldFailure {
        #expect((failure.underlying as? MacHandUnsupported)?.limit == .middleButtonNotAtSeam)
        #expect(MacHandRepertoire.isBalanced(failure.recoveryPlan))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func holdAppliesTheHeldModifierToInnerKeyEvents() throws {
    let plan = try MacHandRepertoire.hold(modifiers: .shift) {
        MacHandRepertoire.key(code: 123, modifiers: .option)
    }
    let inner = keys(plan).filter { $0.keyCode == 123 }
    #expect(inner.count == 2)
    #expect(inner.allSatisfy { $0.modifiers.contains(.shift) && $0.modifiers.contains(.option) })
}

@Test func holdCarriesModifiersOnMouseAndScrollWithoutChangingGeometry() throws {
    let plan = try MacHandRepertoire.hold(modifiers: .command) {
        try MacHandRepertoire.click(button: .left, at: CGPoint(x: 7, y: 7))
            + MacHandRepertoire.scroll(dx: 0, dy: 3)
    }
    #expect(mice(plan).map(\.phase) == [.move, .down, .up])
    #expect(mice(plan).allSatisfy { $0.x == 7 && $0.y == 7 && $0.modifiers == .command })
    #expect(scrolls(plan) == [MacScrollEvent(deltaX: 0, deltaY: 3, unit: .line, modifiers: .command)])
    #expect(keys(plan).last?.modifiers.isEmpty == true)
    #expect(MacHandRepertoire.isBalanced(plan))
}

@Test func holdUnionsExistingPointerFlagsAndReleasesNestedModifiers() throws {
    let plan = try MacHandRepertoire.hold(modifiers: .control) {
        try MacHandRepertoire.hold(modifiers: .shift) {
            [.mouse(MacMouseEvent(phase: .drag, button: .right, x: 8, y: 9,
                                  clickCount: 2, modifiers: .option)),
             .scroll(MacScrollEvent(deltaX: 2, deltaY: 3, unit: .pixel, modifiers: .option))]
        }
    }
    #expect(mice(plan).first?.modifiers == [.control, .shift, .option])
    #expect(mice(plan).first?.button == .right && mice(plan).first?.clickCount == 2)
    #expect(scrolls(plan).first?.modifiers == [.control, .shift, .option])
    #expect(keys(plan).filter { !$0.down }.map(\.modifiers) == [[.control], []])
}

@Test func nestedHoldsUnwindInOrder() throws {
    let plan = try MacHandRepertoire.hold(modifiers: .command) {
        try MacHandRepertoire.hold(modifiers: .shift) {
            MacHandRepertoire.type(text: "a")
        }
    }
    #expect(MacHandRepertoire.residualHeldKeys(in: plan).isEmpty)
    let codes = keys(plan)
    #expect(codes.first?.keyCode == MacHandRepertoire.ModifierKeyCode.command)
    #expect(codes.first?.down == true)
    #expect(codes.last?.keyCode == MacHandRepertoire.ModifierKeyCode.command)
    #expect(codes.last?.down == false)
}

// MARK: - Invariants themselves

@Test func residualHelpersDetectTheFailuresTheyGuardAgainst() {
    let stuckKey: [MacHandStep] = [.key(MacKeyEvent(keyCode: 55, down: true, modifiers: .command))]
    #expect(MacHandRepertoire.residualHeldKeys(in: stuckKey) == [55])
    #expect(!MacHandRepertoire.isBalanced(stuckKey))

    let stuckButton: [MacHandStep] = [
        .mouse(MacMouseEvent(phase: .down, button: .left, x: 0, y: 0)),
        .mouse(MacMouseEvent(phase: .drag, button: .left, x: 5, y: 0)),
    ]
    #expect(MacHandRepertoire.residualHeldButtons(in: stuckButton) == [.left])
    #expect(!MacHandRepertoire.isBalanced(stuckButton))
}

@Test func everyRepertoireGestureLeavesTheHandNeutral() throws {
    var plans: [[MacHandStep]] = [
        MacHandRepertoire.move(to: CGPoint(x: 1, y: 1)),
        MacHandRepertoire.hover(at: CGPoint(x: 1, y: 1), dwellMs: 50),
        MacHandRepertoire.type(text: "abc"),
        MacHandRepertoire.key(code: 36, modifiers: [.command]),
        MacHandRepertoire.chord(MacKeyChord(modifiers: [.shift], keyCode: 1, source: "shift+s")),
        MacHandRepertoire.scroll(dx: 1, dy: 1),
        MacHandRepertoire.swipe(direction: .left, amount: 40),
    ]
    for button in [MacHandButton.left, .right] {
        plans.append(try MacHandRepertoire.click(button: button, at: .zero, count: 2))
        plans.append(try MacHandRepertoire.pressAndHold(button: button, at: .zero, holdMs: 10))
        plans.append(try MacHandRepertoire.dragPath(
            button: button,
            through: [.zero, CGPoint(x: 5, y: 5), CGPoint(x: 9, y: 0)],
            stepsPerSegment: 3,
            holdMs: 20
        ))
    }
    for modifiers in [MacKeyModifiers.command, .shift, .option, .control, .function, [.command, .shift]] {
        plans.append(try MacHandRepertoire.hold(modifiers: modifiers) {
            try MacHandRepertoire.dragPath(through: [.zero, CGPoint(x: 3, y: 3)], stepsPerSegment: 2)
        })
    }
    for plan in plans {
        #expect(MacHandRepertoire.isBalanced(plan))
    }
}

@Test func plansAreDeterministic() throws {
    let first = try MacHandRepertoire.dragPath(
        through: [.zero, CGPoint(x: 33, y: 17), CGPoint(x: 4, y: 99)],
        stepsPerSegment: 6,
        holdMs: 30
    )
    let second = try MacHandRepertoire.dragPath(
        through: [.zero, CGPoint(x: 33, y: 17), CGPoint(x: 4, y: 99)],
        stepsPerSegment: 6,
        holdMs: 30
    )
    #expect(first == second)
}
