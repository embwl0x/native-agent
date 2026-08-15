import Foundation
import Testing
@testable import MacControl
import NativeAgentCore
import PersistenceCore

/// W6 — `mac_wake`: dismiss a NON-LOCKED screensaver, then hand back the fresh
/// fused view.
///
/// HERMETICITY / SAFETY: every test drives a `_RecordingEventSink`, a fake
/// session probe and a stub capture/render pair. Nothing here can move the real
/// mouse, read the real login session, or take a real screenshot — the
/// production `CGEventSink` and `SystemMacSessionStateSource` are never
/// constructed.
///
/// THE RULE THIS FILE PINS (round 2, after an adversarial review found the lock
/// detection could nudge and photograph a real password lock): a set
/// `CGSSessionScreenIsLocked` is REFUSED, unconditionally. It is 1 for a
/// dismissable screensaver AND for a manual Ctrl-Cmd-Q lock, the idle
/// `screenLock` policy governs only the former, and macOS publishes no
/// point-in-time signal separating them — so the flag is an ambiguous reading and
/// ambiguity fails closed. The cost is deliberate and documented in
/// `MacWakeGuard`: refusing a saver costs one mouse movement, proceeding on a
/// lock photographs a screen the OS is holding shut. `mac_wake`'s remaining
/// reach is a sleeping display and an unlocked-but-obstructed screen.

// MARK: - Fakes

/// Hands back a scripted sequence of states: index 0 is the pre-nudge probe,
/// index 1 the post-nudge one. Exhausting the script repeats the last entry.
final class _FakeSessionStateSource: MacSessionStateSource, @unchecked Sendable {
    private let lock = NSLock()
    private let states: [MacSessionState]
    private var index = 0
    private(set) var reads = 0
    let available: Bool

    init(_ states: [MacSessionState], available: Bool = true) {
        self.states = states
        self.available = available
    }

    var isAvailable: Bool { available }

    func currentState() -> MacSessionState {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        let state = states[min(index, states.count - 1)]
        index += 1
        return state
    }
}

private func _state(
    locked: Bool = false,
    onConsole: Bool = true,
    asleep: Bool = false,
    password: MacSessionPasswordRequirement = .notRequired,
    readable: Bool = true,
    frontmost: String? = "com.apple.TextEdit",
    idle: Double? = 10,
    cursor: (Double, Double)? = (400, 300)
) -> MacSessionState {
    MacSessionState(
        screenIsLocked: locked,
        onConsole: onConsole,
        displayAsleep: asleep,
        passwordRequirement: password,
        sessionReadable: readable,
        frontmostBundleID: frontmost,
        idleSeconds: idle,
        cursorX: cursor?.0,
        cursorY: cursor?.1
    )
}

/// THE PROCEED POSTURE, and now the only kind there is: the lock flag is CLEAR.
/// A sleeping display with `loginwindow` frontmost is obstructed — a nudge is
/// exactly the right answer — and nothing about it is holding a password.
private func _displayAsleep(idle: Double = 4500) -> MacSessionState {
    _state(
        locked: false,
        asleep: true,
        password: .notRequired,
        frontmost: "com.apple.loginwindow",
        idle: idle
    )
}

/// THE POSTURE THAT MUST REFUSE, and the one the first build got wrong: the lock
/// flag is SET while the IDLE password policy reads off. That is a manual
/// Ctrl-Cmd-Q lock's exact fingerprint — password required, idle policy
/// irrelevant — and it is indistinguishable from a no-password screensaver from
/// inside the process. It fails closed.
private func _lockedIdlePolicyOff() -> MacSessionState {
    _state(
        locked: true,
        password: .notRequired,
        frontmost: "com.apple.loginwindow",
        idle: 4500
    )
}

/// The saver is gone: the real desktop is back and the idle timer has reset,
/// which is what a landed HID post looks like from outside.
private func _desktopBack() -> MacSessionState {
    _state(locked: false, frontmost: "com.apple.TextEdit", idle: 0.2)
}

private struct _WakeCapture: MacScreenCaptureSource {
    var trusted: Bool = true
    var shot: MacScreenShot? = MacScreenShot(
        bounds: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
        pixelWidth: 1600,
        pixelHeight: 1200
    )
    func isScreenRecordingTrusted() -> Bool { trusted }
    func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        guard let shot else { return .failure(.captureFailed) }
        return .success(shot)
    }
}

private struct _WakeRenderer: MacScreenImageRenderer {
    func renderPNG(
        shot: MacScreenShot,
        placements: [MacScreenMarkerPlacement],
        downscale: Double
    ) -> Data? {
        Data(repeating: 0x11, count: 4096)
    }
}

private struct _WakeElement {
    var attributes: MacAXAttributes?
    var children: [Int]
}

private final class _WakeAXSource: MacAXElementSource, @unchecked Sendable {
    private let elements: [Int: _WakeElement]
    private let trusted: Bool
    init(elements: [Int: _WakeElement], trusted: Bool = true) {
        self.elements = elements
        self.trusted = trusted
    }
    func isTrusted() -> Bool { trusted }
    func frontmostApp() -> MacAXAppInfo? {
        MacAXAppInfo(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 99)
    }
    func frontmostWindowRoot() -> MacAXElementRef? { MacAXElementRef(id: 0) }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? { elements[ref.id]?.attributes }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        (elements[ref.id]?.children ?? []).map { MacAXElementRef(id: $0) }
    }
}

/// The real desktop under the saver: one button, and one banner that happens to
/// be showing a 2FA code.
private func _deskAfterWake() -> _WakeAXSource {
    _WakeAXSource(elements: [
        0: _WakeElement(
            attributes: MacAXAttributes(
                role: "AXWindow",
                title: "Untitled",
                frame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
                actions: []
            ),
            children: [1, 2]
        ),
        1: _WakeElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                title: "Send",
                frame: MacAXFrame(x: 600, y: 500, w: 100, h: 40),
                actions: ["AXPress"]
            ),
            children: []
        ),
        2: _WakeElement(
            attributes: MacAXAttributes(
                role: "AXStaticText",
                title: nil,
                value: "482913",
                frame: MacAXFrame(x: 50, y: 60, w: 200, h: 20),
                actions: []
            ),
            children: []
        ),
    ])
}

private func _wakeClient(
    session: _FakeSessionStateSource,
    sink: _RecordingEventSink = _RecordingEventSink(),
    ax: _WakeAXSource = _deskAfterWake(),
    act: _FakeAXActSource = _FakeAXActSource(root: nil, trusted: true),
    capture: _WakeCapture = _WakeCapture()
) -> SwiftNativeMacControl {
    SwiftNativeMacControl(
        accessibilitySource: ax,
        eventSink: sink,
        accessibilityActSource: act,
        screenCaptureSource: capture,
        screenImageRenderer: _WakeRenderer(),
        screenViewStore: MacScreenViewStore(),
        sessionStateSource: session
    )
}

private func _obj(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let object) = value else { return [:] }
    return object
}

private func _wakeBlock(_ output: JSONValue) -> [String: JSONValue] {
    _obj(_obj(output)["wake"] ?? .null)
}

// MARK: - The happy path

@Test func wakePostsAMouseNudgeAndReturnsTheFreshView() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([_displayAsleep(), _desktopBack()])
    let client = _wakeClient(session: session, sink: sink)

    let result = try await client.injectApproved(action: "wake", body: [:])
    #expect(result.ok)
    #expect(result.action == "wake")

    // A nudge, and nothing but a nudge: two mouse MOVES, one point apart, and
    // the pointer put back exactly where it was. No clicks, no keys.
    #expect(sink.mouse.count == 2)
    #expect(sink.mouse.allSatisfy { $0.phase == .move })
    #expect(sink.mouse[0].x == 401 && sink.mouse[0].y == 300)
    #expect(sink.mouse[1].x == 400 && sink.mouse[1].y == 300)
    #expect(sink.keys.isEmpty)
    #expect(sink.scrolls.isEmpty)

    // The FRESH VIEW came back in the same call, flattened — she lands on the
    // real screen without a second round trip.
    let output = _obj(result.output)
    #expect(output["marks"] != nil, "wake must return the mac_view legend")
    #expect(output["text"] != nil)
    #expect(output["view"] != nil, "wake must return a view id she can act on")
    if case .array(let marks)? = output["marks"] {
        #expect(!marks.isEmpty, "the desktop under the saver has a markable button")
    }

    // The verdict is OBSERVED, not asserted: the session was re-read after the
    // nudge, and both reads happened.
    let wake = _wakeBlock(result.output)
    #expect(session.reads == 2)
    #expect(wake["was_obstructed"] == .bool(true))
    #expect(wake["dismissed"] == .bool(true))
    #expect(output["verified"] == .bool(true))
    // The idle timer fell across the nudge — the orthogonal evidence that the
    // events reached the HID tap rather than being swallowed.
    #expect(wake["idle_reset"] == .bool(true))
}

@Test func wakeReportsHonestlyWhenTheScreenDidNotComeBack() async throws {
    let sink = _RecordingEventSink()
    // Nudged, but the saver is still up and the idle timer never moved: the
    // signature of a missing Accessibility grant.
    let session = _FakeSessionStateSource([_displayAsleep(idle: 4500), _displayAsleep(idle: 4501)])
    let client = _wakeClient(session: session, sink: sink)

    let result = try await client.injectApproved(action: "wake", body: [:])
    #expect(sink.mouse.count == 2, "it still tried")
    let wake = _wakeBlock(result.output)
    #expect(wake["dismissed"] == .bool(false))
    #expect(_obj(result.output)["verified"] == .bool(false))
    #expect(wake["idle_reset"] == .bool(false))
}

// MARK: - THE SAFETY LINE

@Test func wakeRefusesAPasswordLockAndPostsNothing() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([
        _state(locked: true, password: .required, frontmost: "com.apple.loginwindow"),
    ])
    let client = _wakeClient(session: session, sink: sink)

    let result = try await client.injectApproved(action: "wake", body: [:])
    #expect(!result.ok)
    #expect(result.httpStatus == 403)
    #expect(result.error?.contains("screen_locked: cannot bypass a password lock") == true)

    // THE PROPERTY THAT MATTERS: not one event was emitted. Refusing after
    // nudging would already have defeated half of what a lock is for.
    #expect(sink.mouse.isEmpty)
    #expect(sink.keys.isEmpty)
    #expect(sink.scrolls.isEmpty)

    // And it refused BEFORE the re-capture, so a locked screen is not
    // photographed on the way out either.
    #expect(_obj(result.output)["marks"] == nil)
    #expect(_obj(result.output)["image"] == nil)
}

@Test func wakeRefusesWhenItCannotTellWhetherAPasswordIsRequired() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([_state(locked: true, password: .unknown)])
    let client = _wakeClient(session: session, sink: sink)

    let result = try await client.injectApproved(action: "wake", body: [:])
    #expect(!result.ok)
    #expect(result.error?.contains("screen_locked") == true)
    #expect(sink.mouse.isEmpty, "an unreadable lock posture fails CLOSED")
}

/// BLOCKING #1 — THE MANUAL LOCK. `sysadminctl -screenLock status` == off is the
/// IDLE policy, not the state of the lock UI in front of you: Ctrl-Cmd-Q demands
/// the password regardless and reads `CGSSessionScreenIsLocked == 1` exactly like
/// a screensaver does. The first build read that pair as "no password needed" and
/// nudged. It must refuse — and must not photograph it on the way out.
@Test func wakeRefusesAManualLockEvenWhenTheIdlePasswordPolicyIsOff() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([_lockedIdlePolicyOff(), _desktopBack()])
    let client = _wakeClient(session: session, sink: sink)

    let result = try await client.injectApproved(action: "wake", body: [:])
    #expect(!result.ok)
    #expect(result.httpStatus == 403)
    #expect(result.error?.contains("screen_locked") == true)
    #expect(result.error?.contains("Ctrl-Cmd-Q") == true,
            "the refusal must name WHY the policy reading does not clear the lock")

    // Not one event, and not one pixel.
    #expect(sink.mouse.isEmpty)
    #expect(sink.keys.isEmpty)
    #expect(_obj(result.output)["image"] == nil)
    #expect(_obj(result.output)["marks"] == nil)
    #expect(_obj(result.output)["text"] == nil)
    #expect(_obj(result.output)["view"] == nil, "a refusal hands back no actable view id")

    // TEETH: the same client, same fixtures, with the flag CLEAR does proceed —
    // so the assertions above are not passing because everything is refused.
    let openSink = _RecordingEventSink()
    let open = try await _wakeClient(
        session: _FakeSessionStateSource([_displayAsleep(), _desktopBack()]),
        sink: openSink
    ).injectApproved(action: "wake", body: [:])
    #expect(open.ok)
    #expect(openSink.mouse.count == 2)
}

/// THE FEATURE IS NOT BROKEN: an obstructed screen whose lock flag is CLEAR — a
/// sleeping display, `loginwindow` frontmost — is still nudged and still hands
/// back the fresh view. This is what `mac_wake` reaches after the safety line
/// narrowed, and it is narrower than the wave hoped.
@Test func wakeStillProceedsOnAnObstructedScreenThatIsNotLocked() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([_displayAsleep(), _desktopBack()])
    let client = _wakeClient(session: session, sink: sink)

    let result = try await client.injectApproved(action: "wake", body: [:])
    #expect(result.ok)
    #expect(sink.mouse.count == 2, "an unlocked obstructed screen is what wake is for")
    #expect(_wakeBlock(result.output)["was_obstructed"] == .bool(true))
    #expect(_wakeBlock(result.output)["dismissed"] == .bool(true))
    #expect(_obj(result.output)["marks"] != nil)
}

/// BLOCKING #3 — THE RE-GUARD. The first guard's "not locked" is only true at the
/// instant it was read; the settle wait is a window in which User can hit
/// Ctrl-Cmd-Q. The seam returns unlocked on the first read and locked on the
/// second, which is that exact race, and the result must carry NO picture.
@Test func wakeRefusesWhenTheScreenLocksBetweenTheNudgeAndTheCapture() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([
        _displayAsleep(),
        _state(locked: true, password: .required, frontmost: "com.apple.loginwindow"),
    ])
    let client = _wakeClient(session: session, sink: sink)

    let result = try await client.injectApproved(action: "wake", body: ["settle_ms": .int(0)])
    #expect(!result.ok)
    #expect(result.httpStatus == 403)
    #expect(result.error?.contains("screen_locked") == true)

    // The nudge DID go out — the first guard passed and that is honest — but the
    // capture did not happen: no image, no marks, no text, no view id.
    #expect(sink.mouse.count == 2)
    let output = _obj(result.output)
    #expect(output["image"] == nil, "a screen that locked mid-call is never photographed")
    #expect(output["marks"] == nil, "…nor described")
    #expect(output["text"] == nil)
    #expect(output["view"] == nil)
    #expect(_wakeBlock(result.output)["locked_after_nudge"] == .bool(true))
    #expect(_wakeBlock(result.output)["dismissed"] == .bool(false))
    #expect(session.reads == 2, "the re-guard reuses the post-nudge read, it does not add one")
}

/// BLOCKING #2 — A SESSION READ THAT FAILED MID-CALL. `isAvailable` said yes,
/// then the dictionary came back unreadable. That is not an unlocked screen.
@Test func wakeRefusesWhenTheSessionReadIsUnreadableEvenThoughTheSourceIsAvailable() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([_state(locked: false, readable: false)])
    let client = _wakeClient(session: session, sink: sink)

    let result = try await client.injectApproved(action: "wake", body: [:])
    #expect(!result.ok)
    #expect(result.error?.contains("session_unreadable") == true)
    #expect(sink.mouse.isEmpty, "an unreadable session read fails CLOSED")
    #expect(_obj(result.output)["image"] == nil)
}

/// And the same failure arriving on the SECOND read, after the nudge.
@Test func wakeRefusesWhenTheSessionBecomesUnreadableBeforeTheCapture() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([
        _displayAsleep(),
        _state(locked: false, readable: false),
    ])
    let result = try await _wakeClient(session: session, sink: sink)
        .injectApproved(action: "wake", body: ["settle_ms": .int(0)])
    #expect(!result.ok)
    #expect(result.error?.contains("session_unreadable") == true)
    #expect(_obj(result.output)["image"] == nil)
    #expect(_obj(result.output)["marks"] == nil)
}

/// The platform fallback source reports itself unreadable rather than inventing
/// an unlocked screen, and the guard refuses the state it hands back.
@Test func theUnavailableSessionSourceIsUnreadableAndRefused() {
    let state = UnavailableMacSessionStateSource().currentState()
    #expect(!UnavailableMacSessionStateSource().isAvailable)
    #expect(!state.sessionReadable)
    #expect(MacWakeGuard.refusalReason(for: state) == MacWakeGuard.sessionUnreadableRefusal)
}

@Test func wakeRefusesWhenAnotherLoginSessionOwnsTheDisplay() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([_state(onConsole: false)])
    let client = _wakeClient(session: session, sink: sink)

    let result = try await client.injectApproved(action: "wake", body: [:])
    #expect(!result.ok)
    #expect(result.error?.contains("session_not_on_console") == true)
    #expect(sink.mouse.isEmpty)
}

@Test func wakeRefusesWhenTheSessionCannotBeReadAtAll() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([_state()], available: false)
    let client = _wakeClient(session: session, sink: sink)

    let result = try await client.injectApproved(action: "wake", body: [:])
    #expect(!result.ok)
    #expect(result.error?.contains("session_state_unavailable") == true)
    #expect(sink.mouse.isEmpty, "an unreadable session is not an unlocked one")
}

/// The guard as a decision table, so the rule is readable in one place and a
/// future edit to it fails here first.
@Test func wakeGuardRefusesEveryLockedPostureAndEveryUnreadableOne() {
    // PROCEED — and only these: the lock flag is clear.
    #expect(MacWakeGuard.refusalReason(for: _state()) == nil)
    #expect(MacWakeGuard.refusalReason(for: _state(asleep: true)) == nil)
    #expect(MacWakeGuard.refusalReason(for: _displayAsleep()) == nil)
    #expect(MacWakeGuard.refusalReason(
        for: _state(locked: false, frontmost: "com.apple.loginwindow")
    ) == nil)

    // REFUSE — every locked posture, whatever the idle policy says. The policy
    // only chooses which true sentence comes back; it never buys a proceed.
    #expect(MacWakeGuard.refusalReason(
        for: _state(locked: true, password: .required)
    ) == MacWakeGuard.lockedRefusal)
    #expect(MacWakeGuard.refusalReason(
        for: _state(locked: true, password: .unknown)
    ) == MacWakeGuard.unknownLockRefusal)
    // THE ONE THAT USED TO PROCEED.
    #expect(MacWakeGuard.refusalReason(
        for: _state(locked: true, password: .notRequired)
    ) == MacWakeGuard.lockedIndeterminateRefusal)
    #expect(MacWakeGuard.refusalReason(for: _lockedIdlePolicyOff())
            == MacWakeGuard.lockedIndeterminateRefusal)
    // Every refusal is a `screen_locked`/session refusal a caller can branch on.
    for password in [MacSessionPasswordRequirement.required, .unknown, .notRequired] {
        #expect(MacWakeGuard.refusalReason(for: _state(locked: true, password: password))?
            .hasPrefix("screen_locked:") == true)
    }

    // REFUSE — unreadable, checked before anything else, even when every other
    // field looks permissive.
    #expect(MacWakeGuard.refusalReason(
        for: _state(locked: false, onConsole: true, readable: false)
    ) == MacWakeGuard.sessionUnreadableRefusal)

    #expect(MacWakeGuard.refusalReason(
        for: _state(onConsole: false)
    ) == MacWakeGuard.notOnConsoleRefusal)
    // An unlocked screen owned by another console still refuses: the console
    // check is not conditional on the lock.
    #expect(MacWakeGuard.refusalReason(
        for: _state(locked: false, onConsole: false)
    ) == MacWakeGuard.notOnConsoleRefusal)
}

// MARK: - The approval gate is retired; the SESSION guard is not

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: the UNPRIVILEGED entry point — the one the HTTP/iOS bridge and
/// every raw dispatcher use — refused `wake` with `approval_not_granted` and
/// nudged nothing, because no authorization could be carried on that signature.
/// NEW CONTRACT: it SELF-MINTS a capability, so wake runs there. The retired
/// in-band marker is still inert (it is stripped and read nowhere) — it neither
/// authorizes nor changes the outcome, which is the half of this row that
/// survives. `MacWakeGuard`'s lock/console refusals are untouched and are what
/// still stops a wake (see the guard rows above).
@Test func wakeRunsOnTheUnprivilegedEntryPoint_selfMinted() async throws {
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([_displayAsleep(), _desktopBack()])
    let client = _wakeClient(session: session, sink: sink)

    let raw = try await client.dispatch(action: "wake", body: [:])
    #expect(raw.ok)
    #expect(raw.error?.contains("approval_not_granted") != true,
            "the approval tier is retired: \(raw.error ?? "nil")")
    #expect(!sink.mouse.isEmpty, "wake nudges post-cutover")

    // A body key that LOOKS like an attestation still buys nothing — the
    // outcome is identical with and without it.
    let eventsAfterFirst = sink.mouse.count
    let forged = try await client.dispatch(
        action: "wake",
        body: ["__mac_injection_approved": .bool(true)]
    )
    #expect(forged.ok == raw.ok, "the forged key changes no outcome")
    #expect(sink.mouse.count == eventsAfterFirst * 2, "the same nudge, no more, no less")

    // Same treatment as mac_click: it too runs on a self-minted capability.
    let click = try await client.dispatch(action: "click", body: ["x": .int(1), "y": .int(2)])
    #expect(click.error?.contains("approval_not_granted") != true)
}

@Test func wakeIsInTheInjectionSetAndItsCapabilityIsBoundToTheBody() async throws {
    #expect(macControlAccessibilityInjectionActions.contains("wake"))
    #expect(!macControlAccessibilityReadActions.contains("wake"),
            "wake posts input — read tier would be a bypass with a view stapled to it")
    #expect(macControlGateCategory(forAction: "wake") == "accessibility")
    #expect(MacInjectionToolNames.action(forTool: "mac_wake") == "wake")
    #expect(MacInjectionToolNames.isInjectionTool("mac_wake"))
    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): the post-resolution clamp
    // is RETIRED — it is now the identity function, so injection-set membership
    // no longer forces `mac_wake` up to `minimumAutonomyLevel`. Membership
    // itself (asserted above) is unchanged, and still decides which path mints
    // the capability and which body the capability is bound to — which is what
    // the rest of this row proves.
    #expect(MacInjectionToolNames.clampedAutonomyLevel(toolName: "mac_wake", resolved: "auto") == "auto")

    // A capability minted for a DIFFERENT body does not authorize this call.
    let sink = _RecordingEventSink()
    let session = _FakeSessionStateSource([_displayAsleep(), _desktopBack()])
    let client = _wakeClient(session: session, sink: sink)
    let capability = try #require(MacInjectionCapability.mint(
        approvalID: "wake-approval",
        action: "wake",
        body: ["settle_ms": .int(0)]
    ))
    let mismatched = try await client.dispatchApprovedInjection(
        action: "wake",
        body: ["settle_ms": .int(3000)],
        capability: capability
    )
    #expect(!mismatched.ok)
    #expect(sink.mouse.isEmpty)
}

// MARK: - The re-capture inherits mac_view's redaction

@Test func wakeResultIsSecretRedactedExactlyLikeTheView() async throws {
    let session = _FakeSessionStateSource([_displayAsleep(), _desktopBack()])
    let client = _wakeClient(session: session)

    let result = try await client.injectApproved(action: "wake", body: [:])
    let encoded = try String(
        data: result.output.serializedData(pretty: false),
        encoding: .utf8
    ) ?? ""
    // The desktop under the saver is showing a 2FA code. The wake result rides
    // the same trace / persist / sync sinks the view does, so it must arrive
    // covered — by REUSING mac_view's redaction, not a second copy.
    #expect(!encoded.contains("482913"), "a displayed code must not ride out on the wake result")
    #expect(encoded.contains("\"redacted\""))

    // TEETH: the legend is not blanket-darkened — an ordinary control label is
    // still readable, or the organ would be blind.
    #expect(encoded.contains("Send"))

    // And the image sink knows this tool carries a picture, so the base64 is
    // stripped downstream instead of being persisted whole.
    #expect(MacScreenViewResultRedaction.carriesImage(tool: "mac_wake"))
    #expect(MacScreenViewResultRedaction.carriesImage(tool: "wake"))
    let stripped = _obj(MacScreenViewResultRedaction.redacted(tool: "mac_wake", result: result.output))
    #expect(stripped["image"] == nil)
    #expect(stripped["image_redacted"] == .bool(true))
    #expect(stripped["marks"] != nil, "stripping the picture must not strip the legend")
}

// MARK: - The optional key tap

@Test func wakeTapsAKeyOnlyWhenAskedAndOnlyAModifier() async throws {
    let plainSink = _RecordingEventSink()
    _ = try await _wakeClient(
        session: _FakeSessionStateSource([_displayAsleep(), _desktopBack()]),
        sink: plainSink
    ).injectApproved(action: "wake", body: [:])
    #expect(plainSink.keys.isEmpty, "the default nudge presses no key at all")

    let tapSink = _RecordingEventSink()
    _ = try await _wakeClient(
        session: _FakeSessionStateSource([_displayAsleep(), _desktopBack()]),
        sink: tapSink
    ).injectApproved(action: "wake", body: ["key_tap": .bool(true)])
    #expect(tapSink.keys.count == 2)
    #expect(tapSink.keys.allSatisfy { $0.keyCode == SwiftNativeMacControl.wakeShiftKeyCode })
    #expect(tapSink.keys[0].down && !tapSink.keys[1].down)
    // A modifier alone inserts no character anywhere: nothing carries text.
    #expect(tapSink.keys.allSatisfy { $0.unicodeText == nil })
}

@Test func wakeClampsTheSettleWaitItWillAccept() async throws {
    let session = _FakeSessionStateSource([_displayAsleep(), _desktopBack()])
    let result = try await _wakeClient(session: session)
        .injectApproved(action: "wake", body: ["settle_ms": .int(999_999)])
    #expect(_wakeBlock(result.output)["settle_ms"]
            == .int(Int64(SwiftNativeMacControl.wakeMaxSettleMs)),
            "a model-supplied wait must never be able to hold the turn open")

    let floored = try await _wakeClient(
        session: _FakeSessionStateSource([_displayAsleep(), _desktopBack()])
    ).injectApproved(action: "wake", body: ["settle_ms": .int(-5)])
    #expect(_wakeBlock(floored.output)["settle_ms"] == .int(0))
}
