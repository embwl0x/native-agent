import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Accessibility read gate: Full Mac window is required on the bridge path
// (gpt-5.5 BLOCKING, 2026-08-12). The model-tool path gates AX reads on
// accessibilityReadAllowed = fullMacActive && accessibility_allowed. The
// HTTP/iOS-remote bridge dispatches straight through SwiftNativeMacControl,
// whose gate only checked master/category — so these pin that the SAME Full
// Mac predicate refuses in-process when the trust window is absent or expired.

private func _fullMacActiveTrust() -> MacControlTrustPolicy {
    // outside=="allow" satisfies the permission gate; never-expires satisfies
    // the window — fullMacActive is unconditionally true.
    MacControlTrustPolicy(
        outsideWorkspaceDefault: "allow",
        permissionLevel: "full_mac_os",
        fullMacNeverExpires: true
    )
}

@Test func axReadRefusesWhenFullMacWindowInactive() async throws {
    // accessibility category ON, but NO trust policy → Full Mac not active.
    // The category gate alone would pass; the new predicate must refuse.
    let http = _MockHTTPClient()
    let pol = _permissiveMacPolicy()  // trustPolicy: nil
    let client = SwiftNativeMacControl(http: http, policyProvider: _StubPolicyProvider(policy: pol))
    let r = try await client.dispatch(action: "ax_tree", body: [:])
    #expect(r.ok == false)
    #expect(r.viaSwift == true)
    #expect(r.httpStatus == 403)
    #expect(r.error == "full_mac_inactive: ax_tree requires an active Full Mac trust window")
    let calls = await http.calls
    #expect(calls.isEmpty, "a refused AX read must never round-trip to the daemon")
}

@Test func axReadPassesGateWhenFullMacActive() async throws {
    // Same category ON, but WITH an active Full Mac window → the gate no longer
    // refuses. It reaches the reader (untrusted in CI → ok:true, trusted:false),
    // which is a DIFFERENT outcome than the 403 refusal above — proving the
    // predicate is what changed, not a blanket allow/deny.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    let client = SwiftNativeMacControl(http: http, policyProvider: _StubPolicyProvider(policy: pol))
    let r = try await client.dispatch(action: "ax_status", body: [:])
    #expect(r.ok == true, "gate must pass; ax_status answers trusted:false honestly, not a 403")
    #expect(r.httpStatus != 403)
}

// MARK: - W2/W3 injection: the THREE gates, one test each
//
// Every injection action must clear ALL THREE of:
//   (a) the accessibility CATEGORY (master gate + per-category),
//   (b) an ACTIVE Full Mac trust window,
//   (c) the APPROVAL tier — a live, body-bound, single-use
//       `MacInjectionCapability` presented through `dispatchApprovedInjection`.
// Each gate gets its own test, and each test flips exactly ONE input away from
// a known-passing fixture so a pass cannot come from the wrong reason.

private let _injectionActions = ["keystroke", "click", "scroll", "ax_act"]

private func _injectionBody(_ action: String) -> [String: JSONValue] {
    switch action {
    case "keystroke": return ["text": .string("hi")]
    case "click": return ["x": .int(10), "y": .int(20)]
    case "scroll": return ["dy": .int(-3)]
    default: return ["path": .array([.int(0)])]
    }
}

extension SwiftNativeMacControl {
    /// Test-only stand-in for what `AutonomyGatedDispatcher.runInner` does after
    /// a resolved approval: mint a capability bound to this exact action+body
    /// and present it on the privileged entry point. Handler-behaviour tests
    /// use this so they stay about handler behaviour; the gate tests below call
    /// the raw entry points deliberately.
    func injectApproved(
        action: String,
        body: [String: JSONValue],
        approvalID: String = "test-approval-\(UUID().uuidString)"
    ) async throws -> MacControlResult {
        guard let capability = MacInjectionCapability.mint(
            approvalID: approvalID,
            action: action,
            body: body
        ) else {
            Issue.record("could not mint an injection capability for \(action)")
            return MacControlResult(ok: false, action: action, output: .null, error: "mint_failed", durationMs: 0, viaSwift: true)
        }
        return try await dispatchApprovedInjection(
            action: action,
            body: body,
            capability: capability
        )
    }
}

/// Full Mac ACTIVE + accessibility category ON + attested: the fixture every
/// gate test below flips one field of.
/// Swallows every synthesized event so a test can never move the real cursor or
/// type into the real frontmost app.
///
/// HERMETICITY (2026-08-13): this became load-bearing with the YOLO cutover.
/// While the injection entry points refused without a capability, these tests
/// never reached a sink. They self-mint now, so a test host whose responsible
/// process holds the Accessibility TCC grant WOULD post real events through the
/// default `defaultMacEventSink()`. Every client built here injects this sink.
private func _injectionReadyClient(
    _ http: _MockHTTPClient,
    sink: any MacEventSink = _InertEventSink()
) -> SwiftNativeMacControl {
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    return SwiftNativeMacControl(
        http: http,
        eventSink: sink,
        policyProvider: _StubPolicyProvider(policy: pol)
    )
}

@Test func injectionRefusedWhenFullMacWindowInactive() async throws {
    // GATE (b). Category ON, attestation PRESENT — only the Full Mac window
    // is missing (trustPolicy nil ⇒ never confirmed).
    for action in _injectionActions {
        let http = _MockHTTPClient()
        let client = SwiftNativeMacControl(
            http: http,
            policyProvider: _StubPolicyProvider(policy: _permissiveMacPolicy())
        )
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(r.ok == false, "\(action)")
        #expect(r.httpStatus == 403, "\(action)")
        #expect(r.error == "full_mac_inactive: \(action) requires an active Full Mac trust window", "\(action)")
        #expect(await http.calls.isEmpty, "a refused injection must never round-trip anywhere")
    }
}

@Test func injectionRefusedWhenAccessibilityCategoryOff() async throws {
    // GATE (a). Full Mac ACTIVE, attestation PRESENT — only the category flips.
    for action in _injectionActions {
        var pol = _permissiveMacPolicy()
        pol.trustPolicy = _fullMacActiveTrust()
        pol.categoryAllowed["accessibility_allowed"] = false
        let client = SwiftNativeMacControl(
            http: _MockHTTPClient(),
            policyProvider: _StubPolicyProvider(policy: pol)
        )
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(r.ok == false, "\(action)")
        #expect(r.httpStatus == 403, "\(action)")
        #expect(r.error?.isEmpty == false, "\(action) must carry the category refusal reason")
        #expect(r.error?.contains("full_mac_inactive") == false,
                "\(action) must refuse for the CATEGORY, not fall through to the window check")
    }
}

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT (GATE (c)): with Full Mac ACTIVE and the category ON, the only
/// thing missing was a capability — and the public `dispatch` has no parameter
/// that could carry one, so it 403'd with `approval_not_granted`. That gate
/// closed the HTTP / iOS-remote bridge, the app's direct MacControl callers and
/// any raw SwiftToolDispatcher.
/// NEW CONTRACT: `dispatchCore` self-mints, so gate (c) no longer exists.
/// Gates (a) master-enabled and (b) the Full Mac window remain, and their
/// dedicated rows above/below are what still prove the entry point is gated.
@Test func publicDispatchEntryPointSelfMintsAndClearsTheApprovalTier() async throws {
    for action in _injectionActions {
        let http = _MockHTTPClient()
        let client = _injectionReadyClient(http)
        let r = try await client.dispatch(action: action, body: _injectionBody(action))
        #expect(r.error != "approval_not_granted: \(action) requires an approved injection request",
                "\(action): the approval tier is retired")
        // Past the retired tier it may still stop at the macOS TCC grant, which
        // is a DIFFERENT, non-403 outcome.
        if r.httpStatus == 403 {
            Issue.record("\(action) must no longer 403 on the approval tier: \(r.error ?? "nil")")
        }
    }
}

@Test func injectionRefusedWhenTheMasterGateIsOff() async throws {
    // Defense in depth: master `enabled:false` refuses before the category is
    // even consulted, exactly as it does for every other Mac Control action.
    for action in _injectionActions {
        var pol = _permissiveMacPolicy()
        pol.trustPolicy = _fullMacActiveTrust()
        pol.enabled = false
        let client = SwiftNativeMacControl(
            http: _MockHTTPClient(),
            policyProvider: _StubPolicyProvider(policy: pol)
        )
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(r.ok == false && r.httpStatus == 403, "\(action)")
    }
}

@Test func injectionPassesAllThreeGatesAndReachesTheHandler() async throws {
    // The positive control that gives the three refusals above their teeth: the
    // SAME fixture with nothing flipped must NOT 403 — it must reach the
    // injection preconditions PAST the policy gates, where a pinned-untrusted
    // act source refuses with a DIFFERENT, non-403 outcome. That proves the
    // gate is what changed in the tests above, not a blanket deny.
    //
    // The act source is pinned untrusted rather than left at the process
    // default: AXIsProcessTrusted() is HOST state, and on a runner that holds
    // the Accessibility grant the old fixture sailed past the TCC check into
    // real AX-path resolution (ax_path_not_found) — red on granted hosts,
    // green on CI. Hermetic now; no real AX call on any host.
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        eventSink: _InertEventSink(),
        accessibilityActSource: UnavailableMacAXActSource(),
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    for action in _injectionActions {
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(r.httpStatus != 403, "\(action) must clear the gate when all three inputs are satisfied")
        if r.ok == false {
            #expect(r.error == "accessibility_not_trusted",
                    "\(action) past the gate may only fail on the pinned TCC probe, got: \(r.error ?? "nil")")
        }
    }
}

@Test func theRetiredAttestationKeyIsInertOnEveryEntryPoint() async throws {
    // FORGERY, the whole reason this wave was re-cut. The first design carried
    // approval as `body["__mac_injection_approved"] = true`, so anything that
    // could write a dictionary key held the authority. The key is now just a
    // key: it means nothing, and a body carrying it is refused identically to
    // one that does not.
    let forged: [String: JSONValue] = [
        "x": .int(1), "y": .int(2),
        "__mac_injection_approved": .bool(true),
    ]
    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): OLD CONTRACT — a forged
    // body was refused identically to a plain one (403, approval_not_granted).
    // NEW CONTRACT — there is no approval to forge: both bodies are treated
    // identically because the key is stripped in `dispatchCore` and read
    // nowhere. Identical OUTCOME is still the assertion; the outcome itself
    // moved from "both refused" to "both take the same path".
    let client = _injectionReadyClient(_MockHTTPClient())
    let r = try await client.dispatch(action: "click", body: forged)
    let plainResult = try await client.dispatch(action: "click", body: ["x": .int(1), "y": .int(2)])
    #expect(r.ok == plainResult.ok, "the forged key changes no outcome")
    #expect(r.error == plainResult.error, "the forged key changes no refusal reason")
    #expect(r.error?.hasPrefix("approval_not_granted") != true,
            "the approval tier is retired: \(r.error ?? "nil")")

    // And it cannot help a body that is otherwise identical to an approved one:
    // the marker is excluded from the capability digest, so smuggling it in
    // neither authorizes nor invalidates — it is simply inert.
    let plain: [String: JSONValue] = ["x": .int(1), "y": .int(2)]
    #expect(MacInjectionCapability.bodyDigest(action: "click", body: forged)
            == MacInjectionCapability.bodyDigest(action: "click", body: plain),
            "the retired marker must not participate in the capability binding")
}

@Test func aCapabilityIsBoundToItsExactActionAndBody() async throws {
    // The capability is not a boolean. A capability minted for one keystroke
    // does not authorize a different one — which is what makes it useless to
    // anything that did not already hold the approved request.
    let sink = _RecordingEventSink()
    let client = _actingClient(sink: sink)
    let approved: [String: JSONValue] = ["text": .string("hello")]
    guard let capability = MacInjectionCapability.mint(
        approvalID: "approval-1", action: "keystroke", body: approved
    ) else { Issue.record("mint failed"); return }

    // Same capability, DIFFERENT text.
    let swapped = try await client.dispatchApprovedInjection(
        action: "keystroke",
        body: ["text": .string("rm -rf /")],
        capability: capability
    )
    #expect(swapped.httpStatus == 403)
    #expect(swapped.error?.hasPrefix("capability_body_mismatch") == true, "\(swapped.error ?? "nil")")

    // Same capability, DIFFERENT action.
    let crossAction = try await client.dispatchApprovedInjection(
        action: "click",
        body: ["x": .int(1), "y": .int(2)],
        capability: capability
    )
    #expect(crossAction.httpStatus == 403)
    #expect(crossAction.error?.hasPrefix("capability_action_mismatch") == true, "\(crossAction.error ?? "nil")")
    #expect(sink.keys.isEmpty && sink.mouse.isEmpty, "no refused call may emit an event")

    // The matching call still works — the refusals above are about the BINDING,
    // not a blanket deny.
    let honored = try await client.dispatchApprovedInjection(
        action: "keystroke", body: approved, capability: capability
    )
    #expect(honored.ok, "\(honored.error ?? "")")
    #expect(sink.keys.count == 10, "5 characters × down/up")
}

@Test func aCapabilityIsSingleUseAndExpires() async throws {
    let sink = _RecordingEventSink()
    let client = _actingClient(sink: sink)
    let body: [String: JSONValue] = ["x": .int(3), "y": .int(4)]
    guard let capability = MacInjectionCapability.mint(
        approvalID: "approval-2", action: "click", body: body
    ) else { Issue.record("mint failed"); return }

    let first = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: capability
    )
    #expect(first.ok, "\(first.error ?? "")")

    // REPLAY. One approval buys one injection; a captured capability is spent.
    let second = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: capability
    )
    #expect(second.httpStatus == 403)
    #expect(second.error?.hasPrefix("capability_already_used") == true, "\(second.error ?? "nil")")
    #expect(sink.mouse.count == 3, "only the FIRST call may have emitted events")

    // TTL: a capability minted in the past authorizes nothing even unspent.
    guard let stale = MacInjectionCapability.mint(
        approvalID: "approval-3",
        action: "click",
        body: body,
        now: Date().addingTimeInterval(-(MacInjectionCapability.defaultTTLSeconds + 60))
    ) else { Issue.record("mint failed"); return }
    let expired = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: stale
    )
    #expect(expired.httpStatus == 403)
    #expect(expired.error?.hasPrefix("capability_expired") == true, "\(expired.error ?? "nil")")
}

@Test func aCapabilityCannotBeMintedWithoutAnApproval() {
    // An empty approval id is exactly "nobody said yes". There is no other
    // constructor: `MacInjectionCapability`'s memberwise init is private, so a
    // caller cannot write one as a literal.
    #expect(MacInjectionCapability.mint(approvalID: "", action: "keystroke", body: [:]) == nil)
    #expect(MacInjectionCapability.mint(approvalID: "   ", action: "keystroke", body: [:]) == nil)
    // ...and it cannot be minted for a NON-injection action, so it can never
    // become a general-purpose MacControl override.
    #expect(MacInjectionCapability.mint(approvalID: "a", action: "focus_app", body: [:]) == nil)
    #expect(MacInjectionCapability.mint(approvalID: "a", action: "shell", body: [:]) == nil)
}

@Test func injectionActRequiresTheACTSourceTrustNotTheReadSource() async throws {
    // SHOULD-FIX 5. The precondition used to be
    // `actSource.isTrusted() || accessibilitySource.isTrusted()`, so a trusted
    // READ seam satisfied an ACT precondition. Read trust is not act authority.
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        accessibilitySource: _TrustedReadOnlyAXSource(),   // READ seam IS trusted
        eventSink: sink,
        accessibilityActSource: _FakeAXActSource(root: nil, trusted: false),  // ACT seam NOT trusted
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    for action in _injectionActions {
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(r.ok == false, "\(action) must refuse when the ACT source is untrusted")
        #expect(r.error == "accessibility_not_trusted", "\(action): \(r.error ?? "nil")")
    }
    #expect(sink.keys.isEmpty && sink.mouse.isEmpty && sink.scrolls.isEmpty,
            "an untrusted act source must emit NOTHING")
}

@Test func axActRefusesANonIntegralPathIndex() async throws {
    // SHOULD-FIX 6. `1.9` used to truncate to 1 and act on a DIFFERENT element
    // than the caller named — a silent wrong-target click.
    let target = _FakeAXActNode(role: "AXButton", title: "Send",
                                frame: MacAXFrame(x: 1, y: 1, w: 2, h: 2), actions: ["AXPress"])
    let other = _FakeAXActNode(role: "AXButton", title: "Delete",
                               frame: MacAXFrame(x: 9, y: 9, w: 2, h: 2), actions: ["AXPress"])
    let root = _FakeAXActNode(role: "AXWindow", children: [target, other])
    let sink = _RecordingEventSink()
    for bad in [JSONValue.double(1.9), .double(0.5), .double(-0.0001), .double(1e30)] {
        let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
            action: "ax_act",
            body: ["path": .array([bad])]
        )
        #expect(!r.ok && r.httpStatus == 400, "\(bad) must be refused, not truncated")
        #expect(r.error?.contains("non-negative integers") == true, "\(bad): \(r.error ?? "nil")")
    }
    #expect(target.performed.isEmpty && other.performed.isEmpty,
            "no malformed index may reach an element")
    // Positive control: an INTEGRAL double is still a valid index.
    let ok = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act",
        body: ["path": .array([.double(1.0)])]
    )
    #expect(ok.ok, "\(ok.error ?? "")")
    #expect(other.performed == ["AXPress"], "1.0 must mean index 1, the element the caller named")
}

@Test func accessibilityReadsAreUnaffectedByTheInjectionApprovalTier() async throws {
    // Regression fence: the W1 read tier must NOT have acquired an approval
    // requirement. An unattested read still passes the gate.
    let client = _injectionReadyClient(_MockHTTPClient())
    for action in ["ax_status", "ax_tree", "ax_find"] {
        let body: [String: JSONValue] = action == "ax_find" ? ["role": .string("AXButton")] : [:]
        let r = try await client.dispatch(action: action, body: body)
        #expect(r.httpStatus != 403, "\(action) is read tier — it must not need an approval attestation")
    }
}

// MARK: - W2 handler behaviour through the real dispatch path

private func _actingClient(
    sink: any MacEventSink,
    actRoot: _FakeAXActNode? = nil
) -> SwiftNativeMacControl {
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    return SwiftNativeMacControl(
        http: _MockHTTPClient(),
        eventSink: sink,
        accessibilityActSource: _FakeAXActSource(root: actRoot, trusted: true),
        policyProvider: _StubPolicyProvider(policy: pol)
    )
}

@Test func keystrokeDispatchEmitsTypingAndChordEventsInOrder() async throws {
    let sink = _RecordingEventSink()
    let client = _actingClient(sink: sink)
    let r = try await client.injectApproved(
        action: "keystroke",
        body: ([
            "text": .string("hi"),
            "keys": .string("cmd+s"),
        ])
    )
    #expect(r.ok, "\(r.error ?? "")")
    // 2 characters × down/up, then the chord's down/up.
    #expect(sink.keys.count == 6)
    #expect(sink.keys.prefix(4).compactMap(\.unicodeText) == ["h", "h", "i", "i"])
    #expect(sink.keys[4].keyCode == 1 && sink.keys[4].modifiers == .command)
    #expect(sink.keys[5].down == false && sink.keys[5].modifiers == .command)
    guard case .object(let out) = r.output else { Issue.record("no output object"); return }
    // The typed CHARACTERS are never echoed back — only the count.
    #expect(out["text_characters"] == .int(2))
    #expect(out["verified"] == .bool(false), "emitting events is not observing an effect")
    let serialized = String(data: try r.output.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!serialized.contains("\"hi\""), "keystroke payloads carry secrets — never echo the text")
}

@Test func keystrokeRejectsMalformedSyntaxWithoutEmittingAnything() async throws {
    let sink = _RecordingEventSink()
    let client = _actingClient(sink: sink)
    let r = try await client.injectApproved(
        action: "keystroke",
        body: (["keys": .string("cmd+shift+")])
    )
    #expect(!r.ok)
    #expect(r.httpStatus == 400)
    #expect(r.error?.hasPrefix("invalid_keystroke_syntax") == true, "\(r.error ?? "nil")")
    #expect(sink.keys.isEmpty, "a half-understood chord spec must emit NOTHING")
}

@Test func keystrokeRequiresTextOrKeys() async throws {
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "keystroke",
        body: ([:])
    )
    #expect(!r.ok && r.httpStatus == 400)
    #expect(sink.keys.isEmpty)
}

@Test func clickDispatchEmitsMoveDownUp() async throws {
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "click",
        body: (["x": .int(120), "y": .int(340)])
    )
    #expect(r.ok, "\(r.error ?? "")")
    #expect(sink.mouse.map(\.phase) == [.move, .down, .up])
    #expect(sink.mouse.allSatisfy { $0.x == 120 && $0.y == 340 })
}

@Test func clickDispatchSupportsDoubleRightAndDrag() async throws {
    let double = _RecordingEventSink()
    _ = try await _actingClient(sink: double).injectApproved(
        action: "click",
        body: ([
            "x": .int(1), "y": .int(2), "double": .bool(true),
        ])
    )
    #expect(double.mouse.filter { $0.phase == .down }.map(\.clickCount) == [1, 2])

    let right = _RecordingEventSink()
    _ = try await _actingClient(sink: right).injectApproved(
        action: "click",
        body: ([
            "x": .int(1), "y": .int(2), "button": .string("right"),
        ])
    )
    #expect(right.mouse.filter { $0.phase != .move }.allSatisfy { $0.button == .right })

    let drag = _RecordingEventSink()
    let r = try await _actingClient(sink: drag).injectApproved(
        action: "click",
        body: ([
            "from": .object(["x": .int(5), "y": .int(6)]),
            "to": .object(["x": .int(70), "y": .int(80)]),
            "duration_ms": .int(80),
        ])
    )
    #expect(r.ok)
    #expect(drag.mouse.prefix(2).map(\.phase) == [.move, .down])
    #expect(drag.mouse.dropFirst(2).dropLast().allSatisfy { $0.phase == .drag })
    #expect(drag.mouse.last?.phase == .up)
    #expect(drag.mouse.count == 8) // move + down + five 16ms drag steps + up
    #expect(drag.mouse.last?.x == 70 && drag.mouse.last?.y == 80)
}

@Test func clickRequiresCoordinates() async throws {
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "click",
        body: (["button": .string("left")])
    )
    #expect(!r.ok && r.httpStatus == 400)
    #expect(sink.mouse.isEmpty)
}

@Test func scrollDispatchEmitsAWheelEventAndClampsRunawayDeltas() async throws {
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "scroll",
        body: ([
            "dy": .int(999_999), "x": .int(400), "y": .int(300), "units": .string("pixel"),
        ])
    )
    #expect(r.ok, "\(r.error ?? "")")
    #expect(sink.mouse.map(\.phase) == [.move], "an x/y scroll moves the pointer over the target view first")
    #expect(sink.scrolls.count == 1)
    #expect(sink.scrolls[0].deltaY == 10_000, "runaway deltas are clamped")
    #expect(sink.scrolls[0].unit == .pixel)
}

@Test func scrollRefusesAZeroDelta() async throws {
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "scroll",
        body: (["dx": .int(0), "dy": .int(0)])
    )
    #expect(!r.ok && r.httpStatus == 400)
    #expect(sink.scrolls.isEmpty)
}

@Test func axActDispatchPressesAndReturnsPostState() async throws {
    let button = _FakeAXActNode(
        role: "AXButton", title: "Send",
        frame: MacAXFrame(x: 600, y: 500, w: 100, h: 40),
        actions: ["AXPress"]
    )
    let root = _FakeAXActNode(role: "AXWindow", title: "Compose", children: [button])
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act",
        body: (["path": .array([.int(0)])])
    )
    #expect(r.ok, "\(r.error ?? "")")
    guard case .object(let out) = r.output else { Issue.record("no output"); return }
    #expect(out["method"] == .string("ax_action"))
    #expect(out["requested_action"] == .string("AXPress"))
    #expect(button.performed == ["AXPress"])
    #expect(sink.mouse.isEmpty, "the semantic path must not synthesize a click")
    guard case .object(let post)? = out["post_state"] else { Issue.record("no post_state"); return }
    // a1c0e8c3 redacts unmarked post-state values while preserving action proof.
    #expect(button.value == "pressed")
    guard case .object(let value)? = post["value"] else { Issue.record("no redacted post-state value"); return }
    #expect(value["redacted"] == .bool(true))
    #expect(value["character_count"] == .int(7))
    #expect(value["sha256"] == .string("e15348ae477f16c01edc67a48d82db15e719f3a2f3efcc817e8ce25fe983755e"))
}

@Test func axActDispatchFallsBackToACentreClick() async throws {
    let image = _FakeAXActNode(
        role: "AXImage", title: "Logo",
        frame: MacAXFrame(x: 20, y: 20, w: 60, h: 60), actions: []
    )
    let root = _FakeAXActNode(role: "AXWindow", children: [image])
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act",
        body: (["path": .array([.int(0)])])
    )
    #expect(r.ok)
    guard case .object(let out) = r.output else { Issue.record("no output"); return }
    #expect(out["method"] == .string("cgevent_click_fallback"))
    #expect(out["fallback_reason"] == .string("element_does_not_advertise_AXPress"))
    #expect(sink.mouse.map(\.phase) == [.move, .down, .up])
    #expect(sink.mouse.allSatisfy { $0.x == 50 && $0.y == 50 })
}

@Test func axActRejectsAMalformedPath() async throws {
    let root = _FakeAXActNode(role: "AXWindow", children: [])
    let sink = _RecordingEventSink()
    for bad in [
        JSONValue.array([.string("0")]),
        .array([.int(-1)]),
        .string("0"),
    ] {
        let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
            action: "ax_act",
            body: (["path": bad])
        )
        #expect(!r.ok && r.httpStatus == 400, "\(bad)")
    }
    #expect(sink.mouse.isEmpty)
}

@Test func axActReports404WhenThePathDoesNotResolve() async throws {
    let root = _FakeAXActNode(role: "AXWindow", children: [])
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act",
        body: (["path": .array([.int(7)])])
    )
    #expect(!r.ok)
    #expect(r.httpStatus == 404)
    #expect(r.error == "ax_path_not_found")
    #expect(sink.mouse.isEmpty)
}

@Test func injectionRefusesWithoutTheMacOSAccessibilityGrant() async throws {
    // The policy gate is not the system grant. Without the TCC grant CGEventPost
    // is swallowed by the window server, so reporting "typed" would be a lie.
    var pol = _permissiveMacPolicy()
    pol.trustPolicy = _fullMacActiveTrust()
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        http: _MockHTTPClient(),
        accessibilitySource: _UntrustedAXSource(),
        eventSink: sink,
        accessibilityActSource: _FakeAXActSource(root: nil, trusted: false),
        policyProvider: _StubPolicyProvider(policy: pol)
    )
    for action in _injectionActions {
        let r = try await client.injectApproved(action: action, body: _injectionBody(action))
        #expect(!r.ok, "\(action)")
        #expect(r.error == "accessibility_not_trusted", "\(action): \(r.error ?? "nil")")
    }
    #expect(sink.keys.isEmpty && sink.mouse.isEmpty && sink.scrolls.isEmpty)
}

/// Read source that reports no TCC grant, so the grant precondition can be
/// exercised independently of the host machine's real TCC state.
private struct _UntrustedAXSource: MacAXElementSource {
    func isTrusted() -> Bool { false }
    func frontmostApp() -> MacAXAppInfo? { nil }
    func frontmostWindowRoot() -> MacAXElementRef? { nil }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? { nil }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] { [] }
}

/// READ source that reports a live TCC grant. Its whole job is to prove the act
/// precondition does NOT accept it in place of the act source's own trust
/// (SHOULD-FIX 5).
private struct _TrustedReadOnlyAXSource: MacAXElementSource {
    func isTrusted() -> Bool { true }
    func frontmostApp() -> MacAXAppInfo? { nil }
    func frontmostWindowRoot() -> MacAXElementRef? { nil }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? { nil }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] { [] }
}

// MARK: - W2/W3-FIX-R2 3: a written ax_act value never comes back out

@Test func axActValueIsRedactedOutOfTheResultAndThePostState() async throws {
    // BLOCKING R2-3. `ax_act(value:)` writes a string into a field — which can
    // be a password or a 2FA code — and this handler then RE-READS the field
    // and returns both `element` and `post_state`. That put the secret into the
    // tool result, and from there into the turn trace, the operation store, the
    // chat transcript, and the approval record's resultPreview (which syncs to
    // iOS/Telegram). The argument redaction did nothing about the RETURN trip.
    let secret = "hunter2"
    let field = _FakeAXActNode(
        role: "AXTextField", title: "Password",
        frame: MacAXFrame(x: 10, y: 10, w: 200, h: 24),
        actions: [], settable: true
    )
    let root = _FakeAXActNode(role: "AXWindow", title: "Login", children: [field])
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act",
        body: ["path": .array([.int(0)]), "action": .string("AXSetValue"),
               "value": .string(secret)]
    )
    #expect(r.ok, "\(r.error ?? "")")
    // The WRITE still happened — this is redaction of the echo, not of the act.
    #expect(field.value == secret, "the value must actually be written")

    let serialized = String(
        data: try r.output.serializedData(pretty: false), encoding: .utf8
    ) ?? ""
    #expect(!serialized.contains(secret),
            "no part of an ax_act result may echo the written value: \(serialized)")
    #expect(serialized.contains("\"value_redacted\": true"))

    guard case .object(let out) = r.output else { Issue.record("no output"); return }
    guard case .object(let post)? = out["post_state"] else { Issue.record("no post_state"); return }
    guard case .object(let postValue)? = post["value"] else {
        Issue.record("post_state.value must be the redaction envelope, got \(post["value"] ?? .null)")
        return
    }
    // Auditable, not readable: count + digest, the same shape the redacted
    // ARGUMENT carries, so a reviewer can still confirm what landed is what was
    // approved.
    #expect(postValue["redacted"] == .bool(true))
    #expect(postValue["character_count"] == .int(7))
    #expect(postValue["sha256"] == .string(MacInjectionArgRedaction.sha256(secret) ?? ""))
}

@Test func axActWithoutCaptionContextRedactsThePostState() async throws {
    // Path-only receipts have no ancestor/caption context, even when the call
    // writes no value. Preserve the post-state as a redaction envelope.
    let button = _FakeAXActNode(
        role: "AXButton", title: "Send",
        frame: MacAXFrame(x: 600, y: 500, w: 100, h: 40), actions: ["AXPress"]
    )
    let root = _FakeAXActNode(role: "AXWindow", children: [button])
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink, actRoot: root).injectApproved(
        action: "ax_act", body: ["path": .array([.int(0)])]
    )
    #expect(r.ok)
    guard case .object(let out) = r.output else { Issue.record("no output"); return }
    #expect(out["value_redacted"] == .bool(true))
    guard case .object(let post)? = out["post_state"] else { Issue.record("no post_state"); return }
    #expect(post["value"] == MacInjectionResultRedaction.redactedSecret("pressed"))
}

@Test func injectionResultRedactorCoversEveryValueBearingShape() {
    // The downstream preview boundaries (turn trace, approval resultPreview)
    // apply this independently of the MacControl handler, so a future result
    // shape that reintroduces the field cannot leak through them.
    let raw = JSONValue.object([
        "element": .object(["role": .string("AXTextField"), "value": .string("hunter2")]),
        "post_state": .object(["value": .string("hunter2")]),
        "nested": .array([.object(["text": .string("hunter2")])]),
        "role": .string("AXTextField"),
    ])
    let redacted = MacInjectionResultRedaction.redacted(tool: "mac_ax_act", result: raw)
    let serialized = String(data: (try? redacted.serializedData(pretty: false)) ?? Data(), encoding: .utf8) ?? ""
    #expect(!serialized.contains("hunter2"), "\(serialized)")
    #expect(serialized.contains("\"character_count\": 7"))
    #expect(serialized.contains("AXTextField"), "non-secret fields survive")

    // Idempotent, and a non-injection tool is untouched.
    #expect(MacInjectionResultRedaction.redacted(tool: "mac_ax_act", result: redacted) == redacted)
    #expect(MacInjectionResultRedaction.redacted(tool: "read_file", result: raw) == raw)
}

// MARK: - Sweep item 8: secure keyboard entry preflight

/// Available, and reporting macOS secure input ON. `CGEvent.post` would return
/// nothing to say the keys were dropped, which is exactly why the check has to
/// happen BEFORE the loop rather than being inferred from the aftermath.
private final class _SecureInputRecordingSink: MacEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _keys = 0
    var isAvailable: Bool { true }
    var secureKeyboardEntryActive: Bool { true }
    var keyCount: Int { lock.lock(); defer { lock.unlock() }; return _keys }
    func post(key: MacKeyEvent) { lock.lock(); _keys += 1; lock.unlock() }
    func post(mouse: MacMouseEvent) {}
    func post(scroll: MacScrollEvent) {}
}

@Test func keystrokeRefusesWhileSecureInputIsOnAndEmitsNothing() async throws {
    let sink = _SecureInputRecordingSink()
    let client = _actingClient(sink: sink)
    let r = try await client.injectApproved(
        action: "keystroke",
        body: (["text": .string("sudo password"), "keys": .string("cmd+s")])
    )
    #expect(!r.ok)
    #expect(r.error == MacActClosedLoop.secureInputReason)
    #expect(sink.keyCount == 0, "keys posted under secure input vanish — post none")
    guard case .object(let out) = r.output else { Issue.record("no output object"); return }
    guard case .string(let note)? = out["note"] else { Issue.record("no note"); return }
    #expect(note.contains("secure keyboard entry"), "\(note)")
    let serialized = String(data: try r.output.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!serialized.contains("sudo password"), "a refusal echoes the payload no more than a success does")
}

@Test func keystrokeStillTypesWhenSecureInputIsOff() async throws {
    // The preflight is a measurement, not a mood: the default sink reports
    // secure input off and the ordinary path is untouched.
    let sink = _RecordingEventSink()
    let r = try await _actingClient(sink: sink).injectApproved(
        action: "keystroke",
        body: (["text": .string("hi")])
    )
    #expect(r.ok, "\(r.error ?? "")")
    #expect(sink.keys.count == 4)
}
