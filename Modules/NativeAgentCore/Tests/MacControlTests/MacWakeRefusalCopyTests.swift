import Foundation
import Testing
@testable import MacControl

// Agent's LIVE mac_wake envelope F0D81308 (2026-08-22), operation
// C3F445B2-C936-438B-8AC4-B0AA44C126E5. The refusal path itself was CORRECT —
// the nudge ran, the lock persisted, nothing was photographed. Two defects were
// in the RECEIPT, not the behaviour:
//
//  1. The prose said mac_wake "refuses rather than nudge or photograph" and
//     "If it is just the screensaver, move the mouse and ask me again" — while
//     the same envelope carried nudged:true and mouse_events:2. The text
//     described a policy the code no longer follows.
//  2. The docs claim the nudge "leaves the pointer exactly where it was" and
//     the envelope exposed no cursor coordinates at all, so the claim was
//     unfalsifiable from outside.

private func lockedState(
    passwordRequirement: MacSessionPasswordRequirement = .notRequired,
    cursorX: Double? = 812.0,
    cursorY: Double? = 455.0
) -> MacSessionState {
    MacSessionState(
        screenIsLocked: true,
        onConsole: true,
        displayAsleep: false,
        passwordRequirement: passwordRequirement,
        sessionReadable: true,
        frontmostBundleID: MacWakeGuard.loginWindowBundleID,
        idleSeconds: 1.0,
        cursorX: cursorX,
        cursorY: cursorY
    )
}

@Test("the obstruction refusal describes what the call DID and names no lock")
func obstructedRefusalIsHonestAndLockFree() {
    let reason = MacWakeGuard.captureRefusalReason(for: lockedState())
    #expect(reason == MacWakeGuard.stillObstructedRefusal)
    let text = reason ?? ""
    // Agent F0D81308: the receipt must never claim it refused to nudge —
    // the nudge always runs now, and the text says so.
    #expect(!text.contains("refuses rather than nudge"))
    #expect(text.contains("nudge was delivered"))
    // User, 2026-08-22: no lock vocabulary in receipts, ever.
    #expect(!text.lowercased().contains("locked"))
    #expect(!text.lowercased().contains("password"))
    #expect(text.hasPrefix("display_obstructed:"))
}

@Test("live F0D81308: an unlocked screen is still not refused, nudged or not")
func wakeCaptureStillPassesWhenUnlocked() {
    let unlocked = MacSessionState(
        screenIsLocked: false, onConsole: true, displayAsleep: false,
        passwordRequirement: .notRequired, sessionReadable: true
    )
    #expect(MacWakeGuard.captureRefusalReason(for: unlocked) == nil)
}

@Test("live F0D81308: the session receipt carries the cursor it read")
func sessionJSONExposesCursor() {
    let json = lockedState().toJSON()
    guard case .object(let fields) = json else { Issue.record("not an object"); return }
    #expect(fields["cursor_x"] == .double(812.0))
    #expect(fields["cursor_y"] == .double(455.0))
}

@Test("live F0D81308: an unreadable cursor reports null, never a fabricated origin")
func sessionJSONCursorNullWhenUnreadable() {
    let json = lockedState(cursorX: nil, cursorY: nil).toJSON()
    guard case .object(let fields) = json else { Issue.record("not an object"); return }
    #expect(fields["cursor_x"] == .null)
    #expect(fields["cursor_y"] == .null)
}

@Test("live F0D81308: pointer_restored is a COMPARISON, not a restatement of intent")
func pointerRestoredIsComputedFromTheTwoReads() {
    // The nudge posts (x+1, y) then (x, y): the after-read matches the before.
    #expect(SwiftNativeMacControl.pointerRestoredJSON(
        before: lockedState(cursorX: 812, cursorY: 455),
        after: lockedState(cursorX: 812, cursorY: 455)
    ) == .bool(true))
    // A nudge that did NOT return the pointer must report false, not true —
    // this is the whole reason it is measured instead of asserted.
    #expect(SwiftNativeMacControl.pointerRestoredJSON(
        before: lockedState(cursorX: 812, cursorY: 455),
        after: lockedState(cursorX: 813, cursorY: 512)
    ) == .bool(false))
    // THE ONE THAT MATTERS: the nudge's own displacement is one pixel, so
    // "moved one pixel and stayed there" is a FAILED restore and must read
    // false. A 1.0 tolerance would have called this a success.
    #expect(SwiftNativeMacControl.pointerRestoredJSON(
        before: lockedState(cursorX: 812, cursorY: 455),
        after: lockedState(cursorX: 813, cursorY: 455)
    ) == .bool(false))
    // Float noise is still forgiven.
    #expect(SwiftNativeMacControl.pointerRestoredJSON(
        before: lockedState(cursorX: 812, cursorY: 455),
        after: lockedState(cursorX: 812.0001, cursorY: 455)
    ) == .bool(true))
    // Unreadable ⇒ null. It must NOT collapse to an optimistic true.
    #expect(SwiftNativeMacControl.pointerRestoredJSON(
        before: lockedState(cursorX: nil, cursorY: nil),
        after: lockedState()
    ) == .null)
    #expect(SwiftNativeMacControl.pointerRestoredJSON(
        before: lockedState(),
        after: lockedState(cursorX: nil, cursorY: nil)
    ) == .null)
}
