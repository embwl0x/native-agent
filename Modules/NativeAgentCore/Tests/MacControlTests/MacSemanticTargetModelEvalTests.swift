import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// These are deliberately fixtures at the public four-verb boundary.  They do
// not grow an eval-only target model: `MacFourVerbs` parses the ordinary `look`
// payload, renders it with `MacScreenRender`, resolves a natural target from
// that same production sighting, and issues the normal `act`/`hand` request.

private final class _SemanticTargetHost: MacFourVerbsHost, @unchecked Sendable {
    private let lock = NSLock()
    private var looks: [MacControlResult]
    private let actionResult: MacControlResult
    private let handResult: MacControlResult
    private var calls: [(String, [String: JSONValue])] = []

    init(
        looks: [MacControlResult],
        actionResult: MacControlResult = _semanticResult(action: "act", output: [
            "status": .string("acted"), "effect": .object([:]),
        ]),
        handResult: MacControlResult = _semanticResult(action: "hand", output: [
            "hand_neutral": .bool(true),
        ])
    ) {
        self.looks = looks
        self.actionResult = actionResult
        self.handResult = handResult
    }

    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        lock.withLock {
            calls.append((action, body))
            if action == "look" {
                guard !looks.isEmpty else {
                    return _semanticResult(action: "look", ok: false, output: ["message": .string("fixture exhausted")])
                }
                return looks.removeFirst()
            }
            return action == "hand" ? handResult : actionResult
        }
    }

    func recordedCalls() -> [(String, [String: JSONValue])] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

private struct _SemanticTargetSupplement: MacFourVerbsSupplementalPerceptionSource {
    let value: MacFourVerbsSupplement
    func observe() async -> MacFourVerbsSupplement? { value }
}

private func _semanticResult(
    action: String,
    ok: Bool = true,
    output: [String: JSONValue]
) -> MacControlResult {
    MacControlResult(
        ok: ok,
        action: action,
        output: .object(output),
        error: ok ? nil : "fixture_failed",
        durationMs: 1,
        viaSwift: true
    )
}

private func _semanticLook(
    window: String = "Before",
    affordances: [[String: JSONValue]] = [],
    landmarks: [[String: JSONValue]] = [],
    focus: [String: JSONValue] = [:]
) -> MacControlResult {
    _semanticResult(action: "look", output: [
        "frame_id": .string("fixture-frame"),
        "app": .object([
            "name": .string("Fixture App"),
            "bundle_id": .string("test.fixture.app"),
            "pid": .int(42),
        ]),
        "window": .string(window),
        "affordances": .array(affordances.map(JSONValue.object)),
        "landmarks": .array(landmarks.map(JSONValue.object)),
        "focus": .object(focus),
    ])
}

private func _semanticFrame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> JSONValue {
    .object(["x": .double(x), "y": .double(y), "w": .double(w), "h": .double(h)])
}

private func _semanticAffordance(
    handle: String,
    role: String,
    label: String? = nil,
    path: [Int],
    frame: JSONValue? = nil
) -> [String: JSONValue] {
    var value: [String: JSONValue] = [
        "handle": .string(handle),
        "role": .string(role),
        "path": .array(path.map { .int(Int64($0)) }),
        "enabled": .bool(true),
    ]
    if let label { value["label"] = .string(label) }
    if let frame { value["frame"] = frame }
    return value
}

private func _semanticLandmark(
    kind: String,
    role: String,
    label: String,
    path: [Int],
    frame: JSONValue
) -> [String: JSONValue] {
    [
        "kind": .string(kind),
        "role": .string(role),
        "label": .string(label),
        "path": .array(path.map { .int(Int64($0)) }),
        "frame": frame,
    ]
}

@Test("one fused target model renders an AX name and physically aims it from vision")
func fusedSemanticTargetUsesVisionPointAndFreshReceipt() async throws {
    let before = _semanticLook(affordances: [
        _semanticAffordance(handle: "publish", role: "AXButton", label: "Publish", path: [0]),
    ])
    let after = _semanticLook(window: "Published", affordances: [
        _semanticAffordance(handle: "publish", role: "AXButton", label: "Publish", path: [0]),
    ])
    let supplement = _SemanticTargetSupplement(value: MacFourVerbsSupplement(
        appName: "Fixture App",
        bundleIdentifier: "test.fixture.app",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 1_000, h: 800),
        targets: [
            MacFourVerbsSupplementalTarget(
                label: MacScreenText("Publish", redacted: .string("Publish")),
                kind: "button",
                frame: MacAXFrame(x: 100, y: 200, w: 80, h: 40),
                provenance: .vision(0.93)
            ),
        ]
    ))
    let host = _SemanticTargetHost(looks: [before, before, after])
    let verbs = MacFourVerbs(host: host, supplementalSource: supplement)

    let screen = await verbs.screen()
    #expect(screen.ok)
    #expect(screen.text.components(separatedBy: "Publish").count == 2,
            "AX and vision must make one visible target, not parallel screen vocabularies: \(screen.text)")

    let reply = await verbs.act(verb: "move", target: "Publish")
    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.contains("fresh screen changed"), "\(reply.text)")
    #expect(reply.detail["observed_after"] == .bool(true))
    #expect(reply.detail["screen_changed"] == .bool(true))
    #expect(reply.detail["verification"] == .string(MotorVerificationState.satisfied.rawValue))
    #expect(reply.detail["verification_evidence"] == .string("fresh_visible_screen_change"))

    let calls = host.recordedCalls()
    #expect(calls.map(\.0) == ["look", "look", "hand", "look"])
    let hand = try #require(calls.first(where: { $0.0 == "hand" })?.1)
    #expect(hand["gesture"] == .string("move"))
    #expect(hand["x"] == .double(140))
    #expect(hand["y"] == .double(220))
}

@Test("unlabeled control remains addressable through the production role vocabulary")
func uniqueUnlabeledControlResolvesByRoleWithoutInventingAnEvalLabel() async throws {
    let look = _semanticLook(affordances: [
        _semanticAffordance(handle: "unnamed-button", role: "AXButton", path: [0]),
    ])
    let host = _SemanticTargetHost(looks: [look, look, look])
    let verbs = MacFourVerbs(host: host)

    let screen = await verbs.screen()
    #expect(screen.text.contains(MacScreenRender.unlabeledMarker), "\(screen.text)")
    let reply = await verbs.act(verb: "click", target: "button")

    #expect(reply.ok, "\(reply.text)")
    let act = try #require(host.recordedCalls().first(where: { $0.0 == "act" })?.1)
    #expect(act["handle"] == .string("unnamed-button"))
    #expect(act["frame_id"] == .string("fixture-frame"))
}

@Test("an unnamed text area resolves through its visible role and row ordinal")
func unnamedTextAreaResolvesThroughTheProductionTargetModel() async throws {
    let before = _semanticLook(affordances: [
        _semanticAffordance(handle: "draft", role: "AXTextArea", path: [0]),
    ])
    let after = _semanticLook(window: "Draft changed", affordances: [
        _semanticAffordance(handle: "draft", role: "AXTextArea", path: [0]),
    ])
    let host = _SemanticTargetHost(looks: [before, before, after])
    let verbs = MacFourVerbs(host: host)

    let screen = await verbs.screen()
    #expect(screen.text.contains("text area"), "the visible role is the natural target vocabulary: \(screen.text)")
    let reply = await verbs.act(verb: "type", target: "text area 1", text: "one line")

    #expect(reply.ok, "\(reply.text)")
    let act = try #require(host.recordedCalls().first(where: { $0.0 == "act" })?.1)
    #expect(act["handle"] == .string("draft"))
}

@Test("sidebar regions and numbered rows share the screen target resolver")
func sidebarRegionAndOrdinalRowResolveFromOneSighting() async throws {
    let listFrame = _semanticFrame(20, 50, 400, 500)
    let sidebarFrame = _semanticFrame(0, 0, 200, 600)
    let look = _semanticLook(
        affordances: [
            _semanticAffordance(handle: "first", role: "AXRow", label: "Inbox", path: [1, 0]),
            _semanticAffordance(handle: "second", role: "AXRow", label: "Receipts", path: [1, 1]),
        ],
        landmarks: [
            _semanticLandmark(kind: "sidebar", role: "AXGroup", label: "Mailboxes", path: [0], frame: sidebarFrame),
            _semanticLandmark(kind: "list", role: "AXList", label: "Messages", path: [1], frame: listFrame),
        ]
    )
    let after = _semanticLook(
        window: "Receipts",
        affordances: [
            _semanticAffordance(handle: "first", role: "AXRow", label: "Inbox", path: [1, 0]),
            _semanticAffordance(handle: "second", role: "AXRow", label: "Receipts", path: [1, 1]),
        ],
        landmarks: [
            _semanticLandmark(kind: "sidebar", role: "AXGroup", label: "Mailboxes", path: [0], frame: sidebarFrame),
            _semanticLandmark(kind: "list", role: "AXList", label: "Messages", path: [1], frame: listFrame),
        ]
    )

    let sidebarHost = _SemanticTargetHost(looks: [look, after])
    let sidebarReply = await MacFourVerbs(host: sidebarHost).act(verb: "hover", target: "Mailboxes")
    #expect(sidebarReply.ok, "\(sidebarReply.text)")
    let hand = try #require(sidebarHost.recordedCalls().first(where: { $0.0 == "hand" })?.1)
    #expect(hand["gesture"] == .string("hover"))
    #expect(hand["x"] == .double(100))
    #expect(hand["y"] == .double(300))

    let rowHost = _SemanticTargetHost(looks: [look, after])
    let rowReply = await MacFourVerbs(host: rowHost).act(verb: "open", target: "row 2")
    #expect(rowReply.ok, "\(rowReply.text)")
    let rowAct = try #require(rowHost.recordedCalls().first(where: { $0.0 == "act" })?.1)
    #expect(rowAct["handle"] == .string("second"))
}

@Test("identical unlabeled controls render and resolve through stable role ordinals")
func identicalUnlabeledControlsResolveThroughTheProductionScreenModel() async throws {
    func compiledLook(window: String) -> (result: MacControlResult, handles: [String]) {
        let percept = MacPerceptionCompiler.compile(
            snapshot: MacAXTreeSnapshot(nodes: [
                MacAXNode(attributes: MacAXAttributes(
                    role: "AXWindow", title: window
                ), path: []),
                MacAXNode(attributes: MacAXAttributes(
                    role: "AXButton", actions: ["AXPress"]
                ), path: [0]),
                MacAXNode(attributes: MacAXAttributes(
                    role: "AXButton", actions: ["AXPress"]
                ), path: [1]),
            ], truncated: false, truncationReasons: [], skippedAtLeast: 0),
            app: MacAXAppInfo(name: "Fixture App", bundleIdentifier: "test.fixture.app", processIdentifier: 42),
            windowTitle: window
        )
        guard case .object(var output) = percept.lookJSON().json else {
            fatalError("the production look percept must encode as an object")
        }
        output["frame_id"] = .string("fixture-frame")
        return (
            _semanticResult(action: "look", output: output),
            percept.affordances.map(\.handle)
        )
    }

    let before = compiledLook(window: "Before")
    let after = compiledLook(window: "Second pressed")
    let host = _SemanticTargetHost(looks: [before.result, before.result, after.result])
    let verbs = MacFourVerbs(host: host)

    let screen = await verbs.screen()
    #expect(screen.text.contains("button 1"), "the first unnamed control needs a visible address: \(screen.text)")
    #expect(screen.text.contains("button 2"), "the second unnamed control needs a visible address: \(screen.text)")

    let reply = await verbs.act(verb: "click", target: "button 2")
    #expect(reply.ok, "\(reply.text)")
    let act = try #require(host.recordedCalls().first(where: { $0.0 == "act" })?.1)
    let secondHandle = try #require(before.handles.dropFirst().first)
    #expect(act["handle"] == .string(secondHandle))
}

@Test("an unambiguous landmark kind resolves without requiring its incidental label")
func genericSidebarKindUsesTheProductionTargetResolver() async throws {
    let sidebarFrame = _semanticFrame(0, 0, 200, 600)
    let before = _semanticLook(landmarks: [
        _semanticLandmark(kind: "sidebar", role: "AXGroup", label: "Mailboxes", path: [0], frame: sidebarFrame),
    ])
    let after = _semanticLook(window: "After hover", landmarks: [
        _semanticLandmark(kind: "sidebar", role: "AXGroup", label: "Mailboxes", path: [0], frame: sidebarFrame),
    ])
    let host = _SemanticTargetHost(looks: [before, after])
    let reply = await MacFourVerbs(host: host).act(verb: "hover", target: "sidebar")

    #expect(reply.ok, "\(reply.text)")
    let hand = try #require(host.recordedCalls().first(where: { $0.0 == "hand" })?.1)
    #expect(hand["x"] == .double(100))
    #expect(hand["y"] == .double(300))
}
