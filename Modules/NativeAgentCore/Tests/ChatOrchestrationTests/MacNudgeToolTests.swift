import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MacControl
import TrustCenter

/// W7 — `mac_nudge`: post ONE bare mouse move, and nothing else.
///
/// Two properties are load-bearing and both are pinned here:
///
///  1. THE GATE IS `mac_ax_status`'S GATE. Full Mac active + the accessibility
///     category ⇒ auto, with NO approval filer in the chain. That is the whole
///     reason the tool exists in this shape: the moment a screensaver is up,
///     nobody is at the keyboard to approve anything, so an approval-gated
///     wake tool fails in exactly the situation it was built for. `mac_click`
///     is dispatched through the SAME filer-less chain in these tests as the
///     control — it must fail where `mac_nudge` succeeds, or the assertion is
///     proving nothing about the gate.
///
///  2. IT EMITS ONLY A MOVE. The events the sink actually received are
///     inspected: any key, any scroll, any button phase (`down`/`up`/`drag`)
///     fails the test. This is what makes "it cannot click or type" a checked
///     property rather than a claim in a comment.
///
/// HERMETICITY: every dispatcher/trust type is built on a temp dataRoot, and
/// the MacControl instance drives a `_NudgeRecordingSink` — the production
/// `CGEventSink` is never constructed, so no test here can move the real
/// cursor.

// MARK: - Fakes

/// Records every event, of every kind, so the move-only assertion can look at
/// what was ACTUALLY posted rather than at what the handler says it posted.
private final class _NudgeRecordingSink: MacEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [MacKeyEvent] = []
    private var _mouse: [MacMouseEvent] = []
    private var _scrolls: [MacScrollEvent] = []
    let available: Bool

    init(available: Bool = true) { self.available = available }

    var isAvailable: Bool { available }
    var keys: [MacKeyEvent] { lock.lock(); defer { lock.unlock() }; return _keys }
    var mouse: [MacMouseEvent] { lock.lock(); defer { lock.unlock() }; return _mouse }
    var scrolls: [MacScrollEvent] { lock.lock(); defer { lock.unlock() }; return _scrolls }

    func post(key: MacKeyEvent) { lock.lock(); _keys.append(key); lock.unlock() }
    func post(mouse: MacMouseEvent) { lock.lock(); _mouse.append(mouse); lock.unlock() }
    func post(scroll: MacScrollEvent) { lock.lock(); _scrolls.append(scroll); lock.unlock() }
}

/// Trust state only — `nudge` never resolves, performs or re-reads an element.
/// Every other member returns nothing / `invalidTarget`, so if the handler ever
/// grew an AX act it could not silently succeed here.
private struct _NudgeActSource: MacAXActSource, Sendable {
    let trusted: Bool
    func isTrusted() -> Bool { trusted }
    func resolve(path: [Int]) -> MacAXActTarget? { nil }
    func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome { .invalidTarget }
    func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome { .invalidTarget }
    func reread(_ target: MacAXActTarget) -> MacAXActTarget? { nil }
}

/// Echoes a marker so a wrapper's pass-through is distinguishable from its
/// refusal, and so a denial cannot be mistaken for a silent success.
private struct _NudgeEchoDispatcher: ToolDispatchClient, Sendable {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .object(["reached_inner": .bool(true), "tool": .string(tool)])
    }
    func listAvailableTools() async throws -> [String] {
        ["mac_nudge", "mac_click", "mac_ax_status"]
    }
}

// MARK: - Helpers

private func nudgeTempRoot(_ tag: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("na-nudge-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func nudgeWriteTrustPolicy(_ dataRoot: URL, _ policy: JSONValue) throws {
    let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try policy.serializedData(pretty: false)
        .write(to: dir.appendingPathComponent("policy.json"))
}

/// `accessibilityAllowed` is the ONE knob under test; everything else is held
/// constant so a flip of that single boolean is the only difference between
/// the ON and OFF cases.
private func nudgeFullMacPolicy(accessibilityAllowed: Bool) -> JSONValue {
    .object([
        "permissionLevel": .string("full_mac_os"),
        "developerMode": .bool(true),
        "fullMacNeverExpires": .bool(true),
        "filePolicy": .object([
            "outsideWorkspaceDefault": .string("allow"),
            "requireBackupBeforeWrite": .bool(false),
            "allowDestructiveActions": .bool(true),
        ]),
        "macControlPolicy": .object([
            "enabled": .bool(true),
            "file_ops_allowed": .bool(true),
            "system_control_allowed": .bool(true),
            "accessibility_allowed": .bool(accessibilityAllowed),
            "remote_from_ios_allowed": .bool(true),
            "approval_required_for": .array([]),
        ]),
    ])
}

/// The ONLY seams `nudge` touches are the act source (for the TCC grant) and
/// the sink. `sessionStateSource` is left at its default and is deliberately
/// UNAVAILABLE-agnostic here: `nudge` never probes the login session — that is
/// the difference from `mac_wake`, whose entire design is a lock guard — so
/// nothing in these tests configures one, and if the handler ever started
/// asking, the move-only tests would not be what caught it; the absence of any
/// `sessionStateSource` reference in `handleNudge` is.
private func nudgeMacControl(sink: _NudgeRecordingSink, trusted: Bool = true) -> SwiftNativeMacControl {
    SwiftNativeMacControl(
        eventSink: sink,
        accessibilityActSource: _NudgeActSource(trusted: trusted),
        policyProvider: nil
    )
}

// MARK: - THE MOVE-ONLY GUARANTEE

@Test
func macNudge_emitsExactlyOneMouseMoveAndNothingElse() async throws {
    let sink = _NudgeRecordingSink()
    let result = try await nudgeMacControl(sink: sink).dispatch(action: "nudge", body: [:])

    #expect(result.ok, "nudge with the grant and a live sink must succeed: \(result.error ?? "-")")
    if case .object(let output) = result.output {
        #expect(output["nudged"] == .bool(true), "nudge must report nudged:true")
    } else {
        Issue.record("nudge did not return an object output")
    }

    // THE GREP. Anything that is not a bare move is a failure — this is the
    // assertion that makes "it cannot click or type" checkable.
    #expect(sink.keys.isEmpty, "nudge must emit NO key events, got \(sink.keys.count)")
    #expect(sink.scrolls.isEmpty, "nudge must emit NO scroll events, got \(sink.scrolls.count)")
    #expect(sink.mouse.count == 1, "nudge must emit exactly ONE mouse event, got \(sink.mouse.count)")
    for event in sink.mouse {
        #expect(event.phase == .move,
                "nudge emitted a \(event.phase.rawValue) mouse event — only .move is permitted")
        #expect(event.clickCount == 1, "a move must not carry a multi-click count")
    }
    // Repeated calls must not accumulate a second KIND of event either.
    _ = try await nudgeMacControl(sink: sink).dispatch(action: "nudge", body: [:])
    #expect(sink.mouse.allSatisfy { $0.phase == .move })
    #expect(sink.keys.isEmpty && sink.scrolls.isEmpty)
}

@Test
func macNudge_ignoresEveryCallerSuppliedField() async throws {
    // `nudge` takes no parameters. A body full of the fields the CLICK and
    // KEYSTROKE handlers read must change nothing about what is emitted — a
    // caller cannot steer this handler into a button-down by naming one.
    let sink = _NudgeRecordingSink()
    let result = try await nudgeMacControl(sink: sink).dispatch(action: "nudge", body: [
        "button": .string("right"),
        "phase": .string("down"),
        "click_count": .int(3),
        "text": .string("rm -rf /"),
        "key": .string("return"),
        "x": .double(10),
        "y": .double(20),
        "mark": .int(1),
    ])

    #expect(result.ok)
    #expect(sink.keys.isEmpty, "no body field may produce a key event")
    #expect(sink.scrolls.isEmpty, "no body field may produce a scroll event")
    #expect(sink.mouse.count == 1)
    #expect(sink.mouse.first?.phase == .move, "no body field may produce a button phase")
}

@Test
func macNudge_refusesHonestlyWithoutTheSystemGrantOrASink() async throws {
    // No Accessibility TCC grant: the window server would swallow the post, so
    // reporting "nudged" would be a lie. Nothing is emitted.
    let untrustedSink = _NudgeRecordingSink()
    let untrusted = try await nudgeMacControl(sink: untrustedSink, trusted: false)
        .dispatch(action: "nudge", body: [:])
    #expect(!untrusted.ok, "nudge without the Accessibility grant must refuse")
    #expect(untrustedSink.mouse.isEmpty, "a refusal must not have posted anything")

    // No usable sink: same rule.
    let deadSink = _NudgeRecordingSink(available: false)
    let unavailable = try await nudgeMacControl(sink: deadSink).dispatch(action: "nudge", body: [:])
    #expect(!unavailable.ok, "nudge without a live event sink must refuse")
    #expect(deadSink.mouse.isEmpty)
}

// MARK: - THE GATE — identical to mac_ax_status, and NO approval filer

/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated.
///
/// OLD CONTRACT: `mac_nudge` was the ONE motor-adjacent tool that survived a
/// filer-less chain; `mac_click` was refused there for want of an approval.
/// NEW CONTRACT: both go through. The whole motor family resolves auto and the
/// gated dispatcher self-mints the injection capability, so a non-interactive
/// surface (bridge, scheduler, wake session) can drive all of them. That is the
/// point of the cutover — nudge is no longer special, it is just the cheapest.
@Test
func macNudge_andMacClick_bothDispatchWithNoApprovalFiler() async throws {
    let root = try nudgeTempRoot("nofiler")
    defer { try? FileManager.default.removeItem(at: root) }
    try nudgeWriteTrustPolicy(root, nudgeFullMacPolicy(accessibilityAllowed: true))

    // A deliberately filer-less chain: hasFiler false, no injection verifier.
    // This is the noninteractive shape — a bridge call, a wake session, a
    // scheduler — and it is exactly the situation a screensaver implies.
    let gated = AutonomyGatedDispatcher(
        inner: _NudgeEchoDispatcher(),
        gate: AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: root)),
        approvalFiler: nil,
        hasFiler: false
    )

    let result = try await gated.dispatch(tool: "mac_nudge", input: [:], surface: "chat")
    #expect(result == .object(["reached_inner": .bool(true), "tool": .string("mac_nudge")]),
            "mac_nudge must reach the inner dispatcher with NO approval filer present")

    // Same chain, same policy, same surface: mac_click now goes through too.
    let clicked = try await gated.dispatch(
        tool: "mac_click", input: ["x": .double(1), "y": .double(1)], surface: "chat"
    )
    #expect(clicked == .object(["reached_inner": .bool(true), "tool": .string("mac_click")]),
            "mac_click reaches the inner dispatcher on a filer-less chain post-cutover")

    // TEETH: the chain still gates SOMETHING on this exact fixture — a tool
    // that kept its deliberate confirm floor (self_install) still cannot run
    // with no filer wired. Without this, the two assertions above could pass on
    // a dispatcher that had stopped gating entirely.
    await #expect(throws: (any Error).self,
                  "self_install kept its floor — a filer-less chain must still refuse it") {
        _ = try await gated.dispatch(tool: "self_install", input: [:], surface: "chat")
    }
}

@Test
func macNudge_resolvesToAutoLikeMacAXStatus() async throws {
    let root = try nudgeTempRoot("autonomy")
    defer { try? FileManager.default.removeItem(at: root) }
    try nudgeWriteTrustPolicy(root, nudgeFullMacPolicy(accessibilityAllowed: true))
    let gate = AutonomyGate(trust: SwiftNativeTrustCenter(dataRoot: root))

    let nudgeLevel = try await gate.autonomyLevel(toolName: "mac_nudge", surface: "chat", originTrusted: true)
    let statusLevel = try await gate.autonomyLevel(toolName: "mac_ax_status", surface: "chat", originTrusted: true)
    #expect(nudgeLevel == "auto", "mac_nudge must resolve to auto, got \(nudgeLevel)")
    #expect(nudgeLevel == statusLevel, "mac_nudge must resolve exactly like mac_ax_status")
    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated. OLD CONTRACT: mac_click was pinned to send_approval
    // here, as the approval-tier neighbour that proved this test was not just
    // reading "auto everywhere". NEW CONTRACT: the whole motor family resolves
    // auto, so the contrast row moves to a floor that SURVIVED the cutover.
    let clickLevel = try await gate.autonomyLevel(toolName: "mac_click", surface: "chat", originTrusted: true)
    #expect(clickLevel == "auto", "mac_click resolves auto post-cutover (got \(clickLevel))")
    let floored = try await gate.autonomyLevel(toolName: "self_install", surface: "chat", originTrusted: true)
    #expect(floored != "auto", "self_install kept its floor — teeth for the auto assertions above")

    // The store-level tier is EXPLICIT in the defaults, under both spellings.
    let policyObj = await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicy()
    guard case .object(let autonomy)? = policyObj["toolAutonomy"] else {
        Issue.record("expected toolAutonomy object in the default trust policy")
        return
    }
    #expect(autonomy["mac.nudge"] == .string("auto"))
    #expect(autonomy["mac_nudge"] == .string("auto"))
}

@Test
func macNudge_needsNoInjectionCapability() async throws {
    // The capability predicate is membership in
    // `macControlAccessibilityInjectionActions`. `nudge` is not in it — that
    // is what lets the UNPRIVILEGED `dispatch` run it — while every real
    // injection action still is.
    #expect(!macControlAccessibilityInjectionActions.contains("nudge"),
            "nudge must not be an injection action or it would demand a MacInjectionCapability")
    #expect(!macControlAccessibilityReadActions.contains("nudge"),
            "nudge posts a CGEvent, so it must not claim the read set's injection-free contract")
    #expect(macControlAccessibilityNudgeActions == ["nudge"])
    for action in ["keystroke", "click", "scroll", "ax_act", "wake"] {
        #expect(macControlAccessibilityInjectionActions.contains(action),
                "\(action) must keep its capability requirement — nudge changes nothing about it")
    }
    // And the model-facing vocabulary agrees: the approval floor / YOLO
    // exclusion keys off MacInjectionToolNames, which must not name mac_nudge.
    #expect(!MacInjectionToolNames.isInjectionTool("mac_nudge"))
    #expect(!MacInjectionToolNames.isInjectionTool("mac.nudge"))
    #expect(MacInjectionToolNames.isInjectionTool("mac_click"))

    // The unprivileged entry point RUNS nudge (that is the point).
    let sink = _NudgeRecordingSink()
    let impl = nudgeMacControl(sink: sink)
    #expect(try await impl.dispatch(action: "nudge", body: [:]).ok)
    #expect(sink.mouse.count == 1, "nudge posts exactly one move")

    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated. OLD CONTRACT: `click` through the UNPRIVILEGED
    // `dispatch(action:body:)` was refused (approval_not_granted) because no
    // `MacInjectionCapability` could be supplied on that signature — nudge's
    // absence from `macControlAccessibilityInjectionActions` was what let it
    // run there. NEW CONTRACT: that entry point now SELF-MINTS a capability
    // (MacControl+Client.swift, `capability ?? MacInjectionCapability.mint`),
    // so click runs there too. The capability-membership facts above are still
    // true and still pinned; what changed is that membership no longer decides
    // reachability, only which code path mints.
    let clickResult = try await impl.dispatch(action: "click", body: ["x": .double(1), "y": .double(1)])
    #expect(clickResult.ok, "click through the unprivileged dispatch now self-mints and runs")
    #expect(sink.mouse.count == 4, "the click posted its own three events on top of nudge's one")
}

@Test
func macNudge_isRefusedWhenTheAccessibilityCategoryIsOff() async throws {
    let root = try nudgeTempRoot("category-off")
    defer { try? FileManager.default.removeItem(at: root) }
    try nudgeWriteTrustPolicy(root, nudgeFullMacPolicy(accessibilityAllowed: false))
    let tools = SwiftToolDispatcher(dataRoot: root)

    await #expect(throws: (any Error).self, "mac_nudge must be denied when the accessibility category is off") {
        _ = try await tools.dispatch(tool: "mac_nudge", input: [:], surface: "chat")
    }
    let schemaNames = Set(try await tools.listAvailableToolSchemas().map(\.name))
    #expect(!schemaNames.contains("mac_nudge"), "mac_nudge must be invisible with the category off")
    // Full Mac itself is genuinely still on, so this is not passing for the
    // wrong reason.
    #expect(try await tools.listAvailableTools().contains("write_file"))
}

@Test
func macNudge_isRefusedWhenFullMacIsInactive() async throws {
    let root = try nudgeTempRoot("nofullmac")
    defer { try? FileManager.default.removeItem(at: root) }
    // No trust policy at all ⇒ Full Mac inactive, every category closed.
    let tools = SwiftToolDispatcher(dataRoot: root)

    let schemaNames = Set(try await tools.listAvailableToolSchemas().map(\.name))
    #expect(!schemaNames.contains("mac_nudge"), "mac_nudge must be invisible with Full Mac inactive")
    await #expect(throws: (any Error).self, "mac_nudge must be denied with Full Mac inactive") {
        _ = try await tools.dispatch(tool: "mac_nudge", input: [:], surface: "chat")
    }
}

// MARK: - Surface wiring

@Test
func macNudge_isReachableAndCorrectlyClassified() async throws {
    let root = try nudgeTempRoot("surface")
    defer { try? FileManager.default.removeItem(at: root) }
    try nudgeWriteTrustPolicy(root, nudgeFullMacPolicy(accessibilityAllowed: true))
    let tools = SwiftToolDispatcher(dataRoot: root)

    #expect(try await tools.listAvailableTools().contains("mac_nudge"),
            "mac_nudge must appear in listAvailableTools() under Full Mac + accessibility")
    let schemas = try await tools.listAvailableToolSchemas()
    let schema = try #require(schemas.first { $0.name == "mac_nudge" },
                              "mac_nudge must have a model-visible schema or the model cannot call it")
    // No parameters at all — the tool takes nothing.
    guard case .object(let parsed) = try JSONValue.parse(schema.parametersJSON) else {
        Issue.record("mac_nudge schema did not parse")
        return
    }
    if case .object(let props)? = parsed["properties"] {
        #expect(props.isEmpty, "mac_nudge takes no parameters")
    }
    if case .array(let required)? = parsed["required"] {
        #expect(required.isEmpty, "mac_nudge must not require any argument")
    }
    // Honesty contract: the description must say what it cannot do, so the
    // model never reaches for it as a way around mac_click's approval.
    let desc = schema.description.lowercased()
    #expect(desc.contains("cannot click"), "the description must state it cannot click")

    // Dispatch lands on the matching MacControl action (the envelope carries
    // the action whether or not this machine holds the TCC grant).
    let result = try await tools.dispatch(tool: "mac_nudge", input: [:], surface: "chat")
    guard case .object(let obj) = result else {
        Issue.record("mac_nudge did not return an object envelope")
        return
    }
    #expect(obj["action"] == .string("nudge"), "mac_nudge must dispatch MacControl action nudge")
    #expect(obj["viaSwift"] == .bool(true))
    #expect(obj["error"] != .string("unknown_action"), "mac_nudge must reach a real MacControl handler")
}

@Test
func macNudge_isRegisteredAsItsOwnCatalogClass() {
    #expect(SwiftToolDispatcher.fullMacNudgeToolNames == ["mac_nudge"])
    #expect(!SwiftToolDispatcher.fullMacAccessibilityReadToolNames.contains("mac_nudge"),
            "mac_nudge posts an event — it must not ride the READ list")
    #expect(!SwiftToolDispatcher.fullMacAccessibilityInjectionToolNames.contains("mac_nudge"),
            "mac_nudge must not ride the injection list or it would inherit the approval floor")
    #expect(!SwiftToolDispatcher.fullMacAppToolNames.contains("mac_nudge"))
    #expect(SwiftToolDispatcher.reservedBuiltInNames.contains("mac_nudge"),
            "mac_nudge must be a reserved built-in so a registry custom tool cannot shadow it")
}

@Test
func macNudge_hasNoMotorOwnerAndSurvivesReadOnlyMode() async throws {
    // No motor binding: a bare cursor move sets no external effect a domain
    // owner could later be asked to prove settled.
    #expect(!ToolCausalBoundary.hasCanonicalMotorOwner(tool: "mac_nudge"))

    // fileAccess=read_only PERMITS it (it writes nothing).
    //
    // YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
    // execution ungated. OLD CONTRACT: mac_click stayed BLOCKED in this same
    // wrapper, and that pairing was the point. NEW CONTRACT: the Mac motor
    // tools were removed from both restricted-mode blocklists, so read_only no
    // longer bears on them at all — the accessibility category and the macOS
    // TCC grant are their gates. read_only still means read-only for FILE
    // tools, which is the part of the mode that is still load-bearing.
    let readOnly = FileAccessGatedDispatcher(inner: _NudgeEchoDispatcher(), fileAccess: "read_only")
    let result = try await readOnly.dispatch(tool: "mac_nudge", input: [:], surface: "chat")
    #expect(result == .object(["reached_inner": .bool(true), "tool": .string("mac_nudge")]))
    let clicked = try await readOnly.dispatch(tool: "mac_click", input: [:], surface: "chat")
    #expect(clicked == .object(["reached_inner": .bool(true), "tool": .string("mac_click")]),
            "mac_click is out of the read_only blocklist post-cutover")
    // TEETH: read_only is still a real mode — a file/persona WRITE is blocked
    // in the very same wrapper.
    await #expect(throws: (any Error).self, "write_file must stay blocked under fileAccess=read_only") {
        _ = try await readOnly.dispatch(tool: "write_file", input: [:], surface: "chat")
    }
}

@Test
func macNudgeAction_isInTheBridgeDispatchableSet() {
    // NativeClient+CutoverSeams' HTTP/iOS-remote route 404s any action outside
    // this set.
    #expect(macControlDispatchableActions.contains("nudge"),
            "nudge must be in macControlDispatchableActions or the bridge route 404s it")
    #expect(!macControlAllActions.contains("nudge"),
            "nudge has no daemon ancestor — the daemon-parity inventory must stay honest")
    #expect(macControlGateCategory(forAction: "nudge") == "accessibility",
            "nudge must be gated under the same category as the AX reads")
}
