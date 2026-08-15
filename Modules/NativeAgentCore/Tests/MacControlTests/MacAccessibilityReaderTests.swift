import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - Synthetic AX source
//
// A live AX read needs a window server, a frontmost app, and a granted TCC
// permission — none of which exist in CI. So the caps, the truncation
// accounting, the string capping and the ranking are pinned against a
// synthetic tree pushed through the EXACT production walker
// (`MacAccessibilityReader.walk`) and the EXACT production handlers
// (`SwiftNativeMacControl.dispatch`). The only thing swapped is the element
// source. See `manualLiveReadNote` at the bottom for the one part of this
// surface a machine cannot assert.

private struct _SyntheticElement {
    var attributes: MacAXAttributes?
    var children: [Int]
}

private final class _SyntheticAXSource: MacAXElementSource, @unchecked Sendable {
    private var elements: [Int: _SyntheticElement] = [:]
    private let rootID: Int?
    private let trusted: Bool
    private let app: MacAXAppInfo?
    /// Every ref the walker asked about — proves the caps stop the WALK, not
    /// just the output array.
    private(set) var attributeReads: [Int] = []

    init(
        elements: [Int: _SyntheticElement],
        rootID: Int?,
        trusted: Bool = true,
        app: MacAXAppInfo? = MacAXAppInfo(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 4242)
    ) {
        self.elements = elements
        self.rootID = rootID
        self.trusted = trusted
        self.app = app
    }

    func isTrusted() -> Bool { trusted }
    func frontmostApp() -> MacAXAppInfo? { app }
    func frontmostWindowRoot() -> MacAXElementRef? { rootID.map { MacAXElementRef(id: $0) } }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? {
        attributeReads.append(ref.id)
        return elements[ref.id]?.attributes
    }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        (elements[ref.id]?.children ?? []).map { MacAXElementRef(id: $0) }
    }
}

/// Root (id 0) with `width` children, each with `width` grandchildren.
private func _wideSource(width: Int) -> _SyntheticAXSource {
    var elements: [Int: _SyntheticElement] = [:]
    var next = 1
    var topLevel: [Int] = []
    for i in 0..<width {
        let childID = next; next += 1
        var grandchildren: [Int] = []
        for j in 0..<width {
            let gcID = next; next += 1
            elements[gcID] = _SyntheticElement(
                attributes: MacAXAttributes(role: "AXStaticText", title: "leaf-\(i)-\(j)"),
                children: []
            )
            grandchildren.append(gcID)
        }
        elements[childID] = _SyntheticElement(
            attributes: MacAXAttributes(role: "AXGroup", title: "group-\(i)"),
            children: grandchildren
        )
        topLevel.append(childID)
    }
    elements[0] = _SyntheticElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Untitled"),
        children: topLevel
    )
    return _SyntheticAXSource(elements: elements, rootID: 0)
}

/// A single chain root→child→child… `depth` elements long.
private func _deepSource(depth: Int) -> _SyntheticAXSource {
    var elements: [Int: _SyntheticElement] = [:]
    for i in 0..<depth {
        elements[i] = _SyntheticElement(
            attributes: MacAXAttributes(role: i == 0 ? "AXWindow" : "AXGroup", title: "level-\(i)"),
            children: i + 1 < depth ? [i + 1] : []
        )
    }
    return _SyntheticAXSource(elements: elements, rootID: 0)
}

/// The "find the Send button" fixture.
private func _buttonSource() -> _SyntheticAXSource {
    var elements: [Int: _SyntheticElement] = [:]
    elements[1] = _SyntheticElement(
        attributes: MacAXAttributes(
            role: "AXButton", title: "Send", enabled: true,
            frame: MacAXFrame(x: 10, y: 20, w: 60, h: 24), actions: ["AXPress"]
        ),
        children: []
    )
    elements[2] = _SyntheticElement(
        attributes: MacAXAttributes(role: "AXButton", title: "Send Later", actions: ["AXPress"]),
        children: []
    )
    elements[3] = _SyntheticElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: "Resend all drafts"),
        children: []
    )
    elements[4] = _SyntheticElement(
        attributes: MacAXAttributes(role: "AXTextField", title: "Body", value: "please send this"),
        children: []
    )
    elements[5] = _SyntheticElement(
        attributes: MacAXAttributes(role: "AXButton", title: "Cancel", actions: ["AXPress"]),
        children: []
    )
    elements[0] = _SyntheticElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Compose"),
        children: [1, 2, 3, 4, 5]
    )
    return _SyntheticAXSource(elements: elements, rootID: 0)
}

private func _client(_ source: _SyntheticAXSource) -> SwiftNativeMacControl {
    // Hermetic: no operationStore, no policyProvider, no auditAppendPath — the
    // AX read path touches no dataRoot-backed persistence at all, so nothing
    // here can reach the live app data root.
    SwiftNativeMacControl(accessibilitySource: source)
}

private func _object(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let object) = value else { return [:] }
    return object
}

private func _array(_ value: JSONValue?) -> [JSONValue] {
    guard case .array(let items)? = value else { return [] }
    return items
}

private func _int(_ value: JSONValue?) -> Int? {
    switch value {
    case .int(let n): return Int(n)
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func _string(_ value: JSONValue?) -> String? {
    if case .string(let s)? = value { return s }
    return nil
}

private func _bool(_ value: JSONValue?) -> Bool? {
    if case .bool(let b)? = value { return b }
    return nil
}

// MARK: - Caps

@Test func axTreeNodeCapTruncatesAndSaysSo() {
    // 21 * 21 + 1 = 463 elements > the 400 hard cap.
    let source = _wideSource(width: 21)
    let snapshot = MacAccessibilityReader.walk(source: source, root: MacAXElementRef(id: 0))
    #expect(snapshot.nodes.count == MacAXLimits.hardMaxNodes)
    #expect(snapshot.truncated)
    #expect(snapshot.truncationReasons.contains("node_cap"))
    #expect(snapshot.skippedAtLeast > 0)
    // The walk itself stopped — it did not read all 463 elements and then trim.
    #expect(source.attributeReads.count <= MacAXLimits.hardMaxNodes)
}

@Test func axTreeNodeCapCannotBeRaisedByCaller() {
    let source = _wideSource(width: 21)
    let limits = MacAXLimits(maxNodes: 100_000, maxDepth: 100_000)
    #expect(limits.maxNodes == MacAXLimits.hardMaxNodes)
    #expect(limits.maxDepth == MacAXLimits.hardMaxDepth)
    let snapshot = MacAccessibilityReader.walk(source: source, root: MacAXElementRef(id: 0), limits: limits)
    #expect(snapshot.nodes.count == MacAXLimits.hardMaxNodes)
}

@Test func axTreeDepthCapTruncatesAndSaysSo() {
    let source = _deepSource(depth: 30)
    let snapshot = MacAccessibilityReader.walk(source: source, root: MacAXElementRef(id: 0))
    #expect(snapshot.nodes.count == MacAXLimits.hardMaxDepth)
    #expect(snapshot.truncated)
    #expect(snapshot.truncationReasons.contains("depth_cap"))
    #expect(snapshot.skippedAtLeast >= 1)
    // Root path is []; the deepest emitted node sits at maxDepth - 1 hops.
    #expect(snapshot.nodes.first?.path == [])
    #expect(snapshot.nodes.map(\.path.count).max() == MacAXLimits.hardMaxDepth - 1)
}

@Test func axTreeUnderCapsIsNotTruncated() {
    let source = _wideSource(width: 3)  // 13 elements, depth 3
    let snapshot = MacAccessibilityReader.walk(source: source, root: MacAXElementRef(id: 0))
    #expect(snapshot.nodes.count == 13)
    #expect(!snapshot.truncated)
    #expect(snapshot.truncationReasons.isEmpty)
    #expect(snapshot.skippedAtLeast == 0)
}

@Test func axTreePathIsChildIndexChainInPreorder() {
    let source = _wideSource(width: 2)
    let snapshot = MacAccessibilityReader.walk(source: source, root: MacAXElementRef(id: 0))
    #expect(snapshot.nodes.map(\.path) == [
        [], [0], [0, 0], [0, 1], [1], [1, 0], [1, 1],
    ])
    #expect(snapshot.nodes[2].attributes.title == "leaf-0-0")
    #expect(snapshot.nodes[6].attributes.title == "leaf-1-1")
}

@Test func axTreeUnreadableElementIsReportedNotCrashed() {
    var elements: [Int: _SyntheticElement] = [:]
    elements[1] = _SyntheticElement(attributes: nil, children: [])  // AX copy failed
    elements[2] = _SyntheticElement(attributes: MacAXAttributes(role: "AXButton", title: "OK"), children: [])
    elements[0] = _SyntheticElement(attributes: MacAXAttributes(role: "AXWindow"), children: [1, 2])
    let source = _SyntheticAXSource(elements: elements, rootID: 0)
    let snapshot = MacAccessibilityReader.walk(source: source, root: MacAXElementRef(id: 0))
    #expect(snapshot.nodes.count == 2)
    #expect(snapshot.truncationReasons == ["unreadable_element"])
    #expect(snapshot.skippedAtLeast == 1)
}

// MARK: - String capping

@Test func axValueIsCharacterCappedAndMarked() {
    let long = String(repeating: "x", count: 5_000)
    let node = MacAXNode(attributes: MacAXAttributes(role: "AXTextArea", value: long), path: [])
    let value = _string(_object(node.toJSON())["value"])
    #expect(value?.count == MacAXLimits.hardValueChars)
    #expect(value?.hasSuffix("…") == true)
}

@Test func axShortValueIsNotMarked() {
    let node = MacAXNode(attributes: MacAXAttributes(role: "AXTextArea", value: "hello"), path: [])
    #expect(_string(_object(node.toJSON())["value"]) == "hello")
}

@Test func axMissingAttributesAreAbsentFieldsNotDefaults() {
    let node = MacAXNode(attributes: MacAXAttributes(role: "AXGroup"), path: [1])
    let object = _object(node.toJSON())
    #expect(object["title"] == nil)
    #expect(object["value"] == nil)
    #expect(object["subrole"] == nil)
    #expect(object["frame"] == nil)
    #expect(_string(object["role"]) == "AXGroup")
}

// MARK: - find

@Test func axFindIsCaseInsensitiveSubstring() {
    let nodes = MacAccessibilityReader.walk(source: _buttonSource(), root: MacAXElementRef(id: 0)).nodes
    let titles = MacAccessibilityReader
        .find(nodes: nodes, query: MacAXQuery(title: "SEND"))
        .map(\.node.attributes.title)
    #expect(titles == ["Send", "Send Later", "Resend all drafts"])
}

@Test func axFindRanksExactAbovePrefixAboveSubstring() {
    let nodes = MacAccessibilityReader.walk(source: _buttonSource(), root: MacAXElementRef(id: 0)).nodes
    let matches = MacAccessibilityReader.find(nodes: nodes, query: MacAXQuery(title: "send"))
    #expect(matches.count == 3)
    #expect(matches[0].node.attributes.title == "Send")        // exact
    #expect(matches[1].node.attributes.title == "Send Later")  // prefix
    #expect(matches[2].node.attributes.title == "Resend all drafts")  // substring
    #expect(matches[0].score > matches[1].score)
    #expect(matches[1].score > matches[2].score)
}

@Test func axFindRoleFilterExcludesOtherRolesAndAcceptsBareRole() {
    let nodes = MacAccessibilityReader.walk(source: _buttonSource(), root: MacAXElementRef(id: 0)).nodes
    let axRole = MacAccessibilityReader.find(nodes: nodes, query: MacAXQuery(role: "AXButton", title: "send"))
    let bareRole = MacAccessibilityReader.find(nodes: nodes, query: MacAXQuery(role: "button", title: "send"))
    #expect(axRole.map(\.node.attributes.title) == ["Send", "Send Later"])
    #expect(bareRole.map(\.node.attributes.title) == ["Send", "Send Later"])
    // "Resend all drafts" is AXStaticText — the role filter must drop it.
    #expect(!axRole.contains { $0.node.attributes.title == "Resend all drafts" })
}

@Test func axFindMatchesOnValue() {
    let nodes = MacAccessibilityReader.walk(source: _buttonSource(), root: MacAXElementRef(id: 0)).nodes
    let matches = MacAccessibilityReader.find(nodes: nodes, query: MacAXQuery(value: "SEND THIS"))
    #expect(matches.map(\.node.attributes.title) == ["Body"])
}

@Test func axFindEmptyQueryMatchesNothing() {
    let nodes = MacAccessibilityReader.walk(source: _buttonSource(), root: MacAXElementRef(id: 0)).nodes
    #expect(MacAccessibilityReader.find(nodes: nodes, query: MacAXQuery()).isEmpty)
    #expect(MacAccessibilityReader.find(nodes: nodes, query: MacAXQuery(title: "   ")).isEmpty)
}

@Test func axFindCapsMatchCount() {
    var elements: [Int: _SyntheticElement] = [:]
    var children: [Int] = []
    for i in 1...120 {
        elements[i] = _SyntheticElement(
            attributes: MacAXAttributes(role: "AXButton", title: "Send \(i)"),
            children: []
        )
        children.append(i)
    }
    elements[0] = _SyntheticElement(attributes: MacAXAttributes(role: "AXWindow"), children: children)
    let source = _SyntheticAXSource(elements: elements, rootID: 0)
    let nodes = MacAccessibilityReader.walk(source: source, root: MacAXElementRef(id: 0)).nodes
    let matches = MacAccessibilityReader.find(nodes: nodes, query: MacAXQuery(title: "send"))
    #expect(matches.count == MacAXLimits.hardMaxMatches)
    // A caller cannot widen the cap either.
    let wide = MacAccessibilityReader.find(
        nodes: nodes, query: MacAXQuery(title: "send"), limits: MacAXLimits(maxMatches: 5_000)
    )
    #expect(wide.count == MacAXLimits.hardMaxMatches)
}

@Test func axFindPrefersActionableElementOnTies() {
    var elements: [Int: _SyntheticElement] = [:]
    elements[1] = _SyntheticElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: "Send"), children: []
    )
    elements[2] = _SyntheticElement(
        attributes: MacAXAttributes(role: "AXButton", title: "Send", actions: ["AXPress"]), children: []
    )
    elements[0] = _SyntheticElement(attributes: MacAXAttributes(role: "AXWindow"), children: [1, 2])
    let source = _SyntheticAXSource(elements: elements, rootID: 0)
    let nodes = MacAccessibilityReader.walk(source: source, root: MacAXElementRef(id: 0)).nodes
    let matches = MacAccessibilityReader.find(nodes: nodes, query: MacAXQuery(title: "Send"))
    #expect(matches.first?.node.attributes.role == "AXButton")
}

// MARK: - Dispatch surface

@Test func axStatusUntrustedReturnsGrantNote() async throws {
    let source = _SyntheticAXSource(elements: [:], rootID: nil, trusted: false)
    let result = try await _client(source).dispatch(action: "ax_status", body: [:])
    let output = _object(result.output)
    #expect(result.ok)  // a status read succeeds even when the answer is "no"
    #expect(_bool(output["trusted"]) == false)
    let note = _string(output["note"]) ?? ""
    #expect(note.contains("System Settings"))
    #expect(note.contains("Privacy & Security"))
    #expect(note.contains("Accessibility"))
    #expect(_string(output["grant_path"]) == "System Settings → Privacy & Security → Accessibility")
}

@Test func axStatusTrustedOmitsNote() async throws {
    let result = try await _client(_buttonSource()).dispatch(action: "ax_status", body: [:])
    let output = _object(result.output)
    #expect(_bool(output["trusted"]) == true)
    #expect(output["note"] == nil)
    #expect(_string(_object(output["frontmost_app"] ?? .null)["name"]) == "TextEdit")
}

@Test func axTreeFailsClosedWhenUntrusted() async throws {
    let source = _SyntheticAXSource(elements: [:], rootID: nil, trusted: false)
    let result = try await _client(source).dispatch(action: "ax_tree", body: [:])
    #expect(!result.ok)
    #expect(result.error == "accessibility_not_trusted")
    #expect(_string(_object(result.output)["note"])?.contains("Accessibility") == true)
}

@Test func axTreeDispatchReportsTruncationHonestly() async throws {
    let result = try await _client(_wideSource(width: 21)).dispatch(action: "ax_tree", body: [:])
    let output = _object(result.output)
    #expect(result.ok)
    #expect(_int(output["count"]) == MacAXLimits.hardMaxNodes)
    #expect(_array(output["nodes"]).count == MacAXLimits.hardMaxNodes)
    #expect(_bool(output["truncated"]) == true)
    #expect(_array(output["truncation_reasons"]).contains(JSONValue.string("node_cap")))
    #expect((_int(output["skipped_at_least"]) ?? 0) > 0)
    #expect(_int(output["max_nodes"]) == MacAXLimits.hardMaxNodes)
    #expect(_int(output["max_depth"]) == MacAXLimits.hardMaxDepth)
}

@Test func axTreeDispatchEmitsFullNodeShape() async throws {
    let result = try await _client(_buttonSource()).dispatch(action: "ax_tree", body: [:])
    let nodes = _array(_object(result.output)["nodes"]).map { _object($0) }
    let send = try #require(nodes.first(where: { _string($0["title"]) == "Send" }))
    #expect(_string(send["role"]) == "AXButton")
    #expect(_bool(send["enabled"]) == true)
    #expect(_array(send["actions"]) == [JSONValue.string("AXPress")])
    #expect(_array(send["path"]) == [JSONValue.int(0)])
    let frame = _object(send["frame"] ?? .null)
    #expect(frame["x"] == JSONValue.double(10))
    #expect(frame["w"] == JSONValue.double(60))
    #expect(_string(_object(result.output)["window_title"]) == "Compose")
}

@Test func axTreeNoFrontmostWindowFailsHonestly() async throws {
    let source = _SyntheticAXSource(elements: [:], rootID: nil, trusted: true)
    let result = try await _client(source).dispatch(action: "ax_tree", body: [:])
    #expect(!result.ok)
    #expect(result.error == "no_frontmost_window")
}

@Test func axFindDispatchRanksAndCarriesTruncationState() async throws {
    let result = try await _client(_buttonSource()).dispatch(
        action: "ax_find",
        body: ["role": .string("button"), "title": .string("send")]
    )
    let output = _object(result.output)
    #expect(result.ok)
    let titles = _array(output["matches"]).map { _string(_object($0)["title"]) }
    #expect(titles == ["Send", "Send Later"])
    #expect(_int(output["count"]) == 2)
    #expect(_int(output["searched"]) == 6)
    // A zero/short result must be distinguishable from a capped tree.
    #expect(_bool(output["truncated"]) == false)
    #expect(_object(output["query"] ?? .null)["role"] == JSONValue.string("button"))
}

@Test func axFindWithNoCriteriaThrowsMissingField() async throws {
    do {
        _ = try await _client(_buttonSource()).dispatch(action: "ax_find", body: [:])
        Issue.record("expected missingField")
    } catch let error as MacControlError {
        #expect(error == .missingField("role|title|value"))
    }
}

@Test func axFindFailsClosedWhenUntrusted() async throws {
    let source = _SyntheticAXSource(elements: [:], rootID: nil, trusted: false)
    let result = try await _client(source).dispatch(
        action: "ax_find", body: ["title": .string("Send")]
    )
    #expect(!result.ok)
    #expect(result.error == "accessibility_not_trusted")
}

// MARK: - Inventory / gating invariants

@Test func axActionsAreDispatchableReadsUnderTheAccessibilityGate() {
    for action in macControlAccessibilityReadActions {
        #expect(macControlDispatchableActions.contains(action))
        #expect(macControlGateCategory(forAction: action) == "accessibility")
        // NOT daemon routes, and NOT unsupported.
        #expect(!macControlAllActions.contains(action))
        #expect(!macControlUnsupportedActions.contains(action))
    }
    // W3.5 added the fused view at the SAME read tier: no CGEvent, no AX
    // mutation, no approval — just structure plus a picture of it.
    #expect(macControlAccessibilityReadActions == ["ax_status", "ax_tree", "ax_find", "view"])
}

@Test func injectionActionsAreImplementedAsOfW2() {
    // W1 was perception only and pinned keystroke/click as 501-unsupported.
    // W2/W3 implemented them, so this now pins the INVERSE: they must be
    // dispatchable and must NOT fall into the fail-closed unsupported bucket.
    // Their fence is the three-gate predicate, not a 501.
    #expect(!macControlUnsupportedActions.contains("keystroke"))
    #expect(!macControlUnsupportedActions.contains("click"))
    #expect(macControlDispatchableActions.contains("keystroke"))
    #expect(macControlDispatchableActions.contains("click"))
    // The reads are still reads: no read action may be classified as injection.
    #expect(macControlAccessibilityReadActions
        .intersection(macControlAccessibilityInjectionActions).isEmpty)
}

// MARK: - Manual (not CI-testable)

/// MANUAL, User-shaped: with Accessibility granted, focus TextEdit with an open
/// document and run `mac.ax_tree`. Expect role AXWindow at path [], a
/// descendant AXTextArea carrying the document text as `value`, and
/// `truncated:false` for a small document. Then `mac.ax_find {role:"button",
/// title:"Close"}` should return the window's close button with a frame inside
/// the window's frame. No unit test can assert this — it needs a real window
/// server and a real TCC grant.
@Test func manualLiveReadNoteIsRecorded() {
    #expect(!MacAccessibilityReader.notTrustedNote.isEmpty)
}
