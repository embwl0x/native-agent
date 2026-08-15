import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - mac_ax_tree / mac_ax_find secret redaction (W3.5-FIX-R3)
//
// `mac_view` redacts what is DISPLAYED on the screen it reads. `mac_ax_tree`
// and `mac_ax_find` read the SAME screen through the SAME
// `MacAccessibilityReader.walk` and shipped every node title/value plus the
// window title raw into the identical sinks — turn trace, persisted tool row,
// cognitive-event preview, iOS/Telegram sync. Both are READ tier: no approval
// gate stands between a displayed 2FA code and User's phone.
//
// These are hermetic: a synthetic AX tree pushed through the EXACT production
// handlers (`SwiftNativeMacControl.dispatch`). No window server, no TCC, no
// dataRoot-backed persistence.
//
// The negative half is load-bearing. Over-redaction blinds the tree exactly the
// way it blinds the view, and it fails SILENTLY — she simply cannot read her
// own screen and nothing reports why. Every ordinary-UI assertion below is a
// guard against that, not filler.

private struct _RedElement {
    var attributes: MacAXAttributes?
    var children: [Int]
}

private final class _RedAXSource: MacAXElementSource, @unchecked Sendable {
    private let elements: [Int: _RedElement]
    private let rootID: Int?

    init(elements: [Int: _RedElement], rootID: Int?) {
        self.elements = elements
        self.rootID = rootID
    }

    func isTrusted() -> Bool { true }
    func frontmostApp() -> MacAXAppInfo? {
        MacAXAppInfo(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 909)
    }
    func frontmostWindowRoot() -> MacAXElementRef? { rootID.map { MacAXElementRef(id: $0) } }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? { elements[ref.id]?.attributes }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        (elements[ref.id]?.children ?? []).map { MacAXElementRef(id: $0) }
    }
}

/// One window carrying, side by side, everything that MUST go dark and
/// everything that MUST stay legible.
private func _secretScreenSource(windowTitle: String = "Checkout") -> _RedAXSource {
    func frame(_ x: Double, _ y: Double, _ w: Double = 80, _ h: Double = 20) -> MacAXFrame {
        MacAXFrame(x: x, y: y, w: w, h: h)
    }
    var elements: [Int: _RedElement] = [:]

    // --- must go dark ---
    // The caption and, directly below it, the code itself.
    elements[1] = _RedElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: "2FA code", frame: frame(10, 10)),
        children: []
    )
    elements[2] = _RedElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: "482913", frame: frame(10, 40)),
        children: []
    )
    // A revealed API key sitting in a field's VALUE.
    elements[3] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXTextField", title: "Key",
            value: "sk-live-4f9aB2xQ7mZ1pR8tK3vN", enabled: true,
            frame: frame(10, 70, 260, 22), actions: ["AXPress"]
        ),
        children: []
    )
    // A CVV: three digits are a QUANTITY on their own, so this one is only a
    // secret because of the caption to its left. Nothing about the value's own
    // shape can catch it — it proves the proximity context is wired.
    elements[4] = _RedElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: "CVV", frame: frame(10, 100, 60, 20)),
        children: []
    )
    elements[5] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXTextField", value: "451", enabled: true,
            frame: frame(80, 100, 50, 20), actions: ["AXPress"]
        ),
        children: []
    )

    // --- must stay legible (the load-bearing half) ---
    // Deliberately placed in a far column (x = 600+): the reused proximity rule
    // darkens a token-shaped string within 240pt to the RIGHT of, or BELOW, a
    // secret caption, and the captions above live at x ≤ 70. These are the
    // negative controls, so they must not sit inside a caption's cone — see
    // `axTreeInheritsMacViewProximityConeIncludingItsFalsePositives` for the
    // test that pins that cone's edge on purpose.
    elements[6] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXButton", title: "New Tab", enabled: true,
            frame: frame(600, 10, 70, 22), actions: ["AXPress"]
        ),
        children: []
    )
    elements[7] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXButton", title: "Send", enabled: true,
            frame: frame(600, 40, 60, 22), actions: ["AXPress"]
        ),
        children: []
    )
    elements[8] = _RedElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: "Order 12345678", frame: frame(600, 70)),
        children: []
    )
    elements[9] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXStaticText", title: "Quarterly-Report-2024.pdf", frame: frame(600, 100, 200, 20)
        ),
        children: []
    )
    elements[10] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXStaticText",
            title: "Choose a strong password before you continue to checkout",
            frame: frame(600, 130, 300, 20)
        ),
        children: []
    )
    elements[11] = _RedElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: "NativeAgentCoreBuildNumber42", frame: frame(600, 160, 220, 20)),
        children: []
    )
    elements[12] = _RedElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: "Zip code", frame: frame(600, 190)),
        children: []
    )
    elements[13] = _RedElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: "94103", frame: frame(690, 190, 60, 20)),
        children: []
    )

    elements[0] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXWindow", title: windowTitle, frame: MacAXFrame(x: 0, y: 0, w: 900, h: 600)
        ),
        children: Array(1...13)
    )
    return _RedAXSource(elements: elements, rootID: 0)
}

private func _redClient(_ source: _RedAXSource) -> SwiftNativeMacControl {
    SwiftNativeMacControl(accessibilitySource: source)
}

private func _obj(_ value: JSONValue?) -> [String: JSONValue] {
    guard case .object(let object)? = value else { return [:] }
    return object
}

private func _arr(_ value: JSONValue?) -> [JSONValue] {
    guard case .array(let array)? = value else { return [] }
    return array
}

private func _str(_ value: JSONValue?) -> String? {
    guard case .string(let string)? = value else { return nil }
    return string
}

/// A field that went dark: never the characters, always enough to audit them,
/// and always a REASON — otherwise redaction is indistinguishable from the
/// organ failing to see.
private func _expectRedacted(
    _ value: JSONValue?,
    reason: String? = nil,
    characters: Int? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let object = _obj(value)
    #expect(object["redacted"] == JSONValue.bool(true), sourceLocation: sourceLocation)
    #expect(_str(object["sha256"])?.isEmpty == false, sourceLocation: sourceLocation)
    if let reason {
        #expect(_str(object["reason"]) == reason, sourceLocation: sourceLocation)
    } else {
        #expect(_str(object["reason"])?.isEmpty == false, sourceLocation: sourceLocation)
    }
    if let characters {
        #expect(object["character_count"] == JSONValue.int(Int64(characters)), sourceLocation: sourceLocation)
    }
}

private func _node(_ output: [String: JSONValue], role: String, index: Int = 0) -> [String: JSONValue] {
    let matching = _arr(output["nodes"]).map { _obj($0) }.filter { _str($0["role"]) == role }
    guard index < matching.count else { return [:] }
    return matching[index]
}

/// The node at a known AX path — identity that survives redaction, which is the
/// point: a dark node is still fully addressable.
private func _nodeAtPath(_ output: [String: JSONValue], _ path: [Int]) -> [String: JSONValue] {
    let wanted = JSONValue.array(path.map { .int(Int64($0)) })
    return _arr(output["nodes"]).map { _obj($0) }.first { $0["path"] == wanted } ?? [:]
}

// MARK: - the leak, closed

@Test func axTreeRedactsDisplayedOneTimeCodeNode() async throws {
    let result = try await _redClient(_secretScreenSource()).dispatch(action: "ax_tree", body: [:])
    #expect(result.ok)
    let output = _obj(result.output)
    // The caption itself is not a secret — she needs to know a 2FA field is
    // there. The CODE is.
    #expect(_str(_nodeAtPath(output, [0])["title"]) == "2FA code")
    _expectRedacted(_nodeAtPath(output, [1])["title"], reason: "otp_shape", characters: 6)
    // And it is nowhere in the serialized payload, by any route.
    let encoded = String(describing: result.output)
    #expect(!encoded.contains("482913"))
}

@Test func axTreeRedactsRevealedAPIKeyValue() async throws {
    let result = try await _redClient(_secretScreenSource()).dispatch(action: "ax_tree", body: [:])
    let node = _nodeAtPath(_obj(result.output), [2])
    // The field's NAME stays — she has to be able to say "the Key field".
    #expect(_str(node["title"]) == "Key")
    _expectRedacted(node["value"], reason: "high_entropy_token")
    #expect(!String(describing: result.output).contains("sk-live-4f9a"))
}

@Test func axTreeRedactsCVVByItsNeighbouringCaption() async throws {
    let result = try await _redClient(_secretScreenSource()).dispatch(action: "ax_tree", body: [:])
    let output = _obj(result.output)
    #expect(_str(_nodeAtPath(output, [3])["title"]) == "CVV")
    // Three digits carry no secret shape of their own: this can only be caught
    // by the caption 10pt to its left, i.e. by the proximity context.
    _expectRedacted(_nodeAtPath(output, [4])["value"], reason: "labeled_cvv", characters: 3)
}

@Test func axTreeRedactsSecretShapedWindowTitle() async throws {
    let result = try await _redClient(
        _secretScreenSource(windowTitle: "Verification code: 482913")
    ).dispatch(action: "ax_tree", body: [:])
    let output = _obj(result.output)
    // The root AXWindow is not a text role, so nothing in the node channel
    // covers it — a terminal titled with what it printed, an authenticator
    // window named after the code.
    _expectRedacted(output["window_title"], reason: "labeled_inline_secret")
    #expect(!String(describing: result.output).contains("482913"))
}

@Test func axTreeKeepsOrdinaryWindowTitleLegible() async throws {
    let result = try await _redClient(_secretScreenSource()).dispatch(action: "ax_tree", body: [:])
    #expect(_str(_obj(result.output)["window_title"]) == "Checkout")
}

// MARK: - the false-positive half (over-redaction blinds the organ)

@Test func axTreeKeepsOrdinaryUILabelsFullyLegible() async throws {
    let result = try await _redClient(_secretScreenSource()).dispatch(action: "ax_tree", body: [:])
    let output = _obj(result.output)
    let legible: [[Int]: String] = [
        [5]: "New Tab",
        [6]: "Send",
        [7]: "Order 12345678",
        [8]: "Quarterly-Report-2024.pdf",
        [9]: "Choose a strong password before you continue to checkout",
        [10]: "NativeAgentCoreBuildNumber42",
        [11]: "Zip code",
        [12]: "94103",
    ]
    for (path, expected) in legible {
        #expect(
            _str(_nodeAtPath(output, path)["title"]) == expected,
            "node at \(path) must stay legible; over-redaction blinds the tree"
        )
    }
}

@Test func axTreeInheritsMacViewProximityConeIncludingItsFalsePositives() async throws {
    // HONEST PIN, not an endorsement. `mac_ax_tree` reuses `mac_view`'s
    // detectors verbatim — that reuse is the point, because a second copy of
    // the shape logic would drift — and it therefore inherits the 240pt
    // proximity cone whole, false positives included: a token-shaped string
    // sitting within 240pt to the RIGHT of a secret caption goes dark even when
    // the caption plainly does not name it. Two nodes on one row of a dense
    // window can do that.
    //
    // This test exists so that behaviour is RECORDED rather than discovered by
    // User as "she suddenly can't read a filename". Tightening the cone means
    // changing a detector `mac_view` already ships, which is a separate call.
    var elements: [Int: _RedElement] = [:]
    elements[1] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXStaticText", title: "CVV", frame: MacAXFrame(x: 10, y: 100, w: 60, h: 20)
        ),
        children: []
    )
    // 230pt right of the caption's trailing edge — inside the cone.
    elements[2] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXStaticText", title: "Quarterly-Report-2024.pdf",
            frame: MacAXFrame(x: 300, y: 100, w: 200, h: 20)
        ),
        children: []
    )
    // 530pt away — outside it.
    elements[3] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXStaticText", title: "Quarterly-Report-2024.pdf",
            frame: MacAXFrame(x: 600, y: 100, w: 200, h: 20)
        ),
        children: []
    )
    elements[0] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXWindow", title: "Files", frame: MacAXFrame(x: 0, y: 0, w: 900, h: 600)
        ),
        children: [1, 2, 3]
    )
    let result = try await _redClient(_RedAXSource(elements: elements, rootID: 0))
        .dispatch(action: "ax_tree", body: [:])
    let output = _obj(result.output)
    _expectRedacted(_nodeAtPath(output, [1])["title"], reason: "labeled_secret_nearby")
    #expect(_str(_nodeAtPath(output, [2])["title"]) == "Quarterly-Report-2024.pdf")
}

@Test func axTreeRedactionLeavesEveryAddressingChannelIntact() async throws {
    let result = try await _redClient(_secretScreenSource()).dispatch(action: "ax_tree", body: [:])
    // The API-key field: its value is dark, and it is still a control she can
    // find, reach and press. WHERE it is and THAT it is pressable is not a
    // secret, and redacting those would break acting on the screen.
    let node = _nodeAtPath(_obj(result.output), [2])
    #expect(_str(node["role"]) == "AXTextField")
    #expect(node["enabled"] == JSONValue.bool(true))
    #expect(_arr(node["actions"]) == [JSONValue.string("AXPress")])
    #expect(node["path"] == JSONValue.array([.int(2)]))
    let frame = _obj(node["frame"])
    #expect(frame["x"] == JSONValue.double(10))
    #expect(frame["y"] == JSONValue.double(70))
    #expect(frame["w"] == JSONValue.double(260))
    #expect(frame["h"] == JSONValue.double(22))
    _expectRedacted(node["value"])
}

// MARK: - the other tool that returns nodes

@Test func axFindRedactsMatchOutputTheSameWay() async throws {
    let result = try await _redClient(_secretScreenSource()).dispatch(
        action: "ax_find",
        body: ["role": .string("statictext")]
    )
    #expect(result.ok)
    let matches = _arr(_obj(result.output)["matches"]).map { _obj($0) }
    let secret = try #require(matches.first { $0["path"] == JSONValue.array([.int(1)]) })
    _expectRedacted(secret["title"], reason: "otp_shape")
    // Ranking survives redaction — a match on a dark node is still a handle.
    #expect(secret["score"] != nil)
    #expect(_str(secret["role"]) == "AXStaticText")
    #expect(!String(describing: result.output).contains("482913"))
    // …and the ordinary matches in the SAME response stay readable.
    let order = try #require(matches.first { $0["path"] == JSONValue.array([.int(7)]) })
    #expect(_str(order["title"]) == "Order 12345678")
}

@Test func axFindTakesCaptionContextFromNodesTheQueryDidNotMatch() async throws {
    // Query only text FIELDS. The "CVV" caption is an AXStaticText, so it is
    // NOT in the match set — if the context were built from matches alone, the
    // three digits would ride out in the clear.
    let result = try await _redClient(_secretScreenSource()).dispatch(
        action: "ax_find",
        body: ["role": .string("textfield")]
    )
    let matches = _arr(_obj(result.output)["matches"]).map { _obj($0) }
    #expect(matches.allSatisfy { _str($0["role"]) == "AXTextField" })
    let cvv = try #require(matches.first { $0["path"] == JSONValue.array([.int(4)]) })
    _expectRedacted(cvv["value"], reason: "labeled_cvv", characters: 3)
}

// MARK: - the reader underneath stays byte-identical

@Test func accessibilityReaderWalkItselfIsUnredacted() async throws {
    // Redaction belongs at the TOOL boundary, not in the shared read organ:
    // the walk stays injection-free and byte-identical so `mac_ax_act`'s path
    // resolution, `mac_view`'s own builder and any future consumer see the
    // truth and redact for their own egress.
    let nodes = MacAccessibilityReader.walk(
        source: _secretScreenSource(),
        root: MacAXElementRef(id: 0)
    ).nodes
    #expect(nodes.contains { $0.attributes.title == "482913" })
    #expect(nodes.contains { $0.attributes.value == "sk-live-4f9aB2xQ7mZ1pR8tK3vN" })
    #expect(nodes.first?.attributes.title == "Checkout")
}

// MARK: - W3.5-FIX-R4: the caption that ENCLOSES instead of pointing
//
// Round 3 found the last geometry the caption walk could not see. Every rule
// before this one asks "is there a secret-naming caption to my LEFT or ABOVE
// me". A real card form does neither:
//
//     AXGroup title="CVV"          ← encloses
//       AXTextField value="451"    ← no title of its own
//
// `451` is not a standalone secret (three digits is a quantity), the field has
// no own title to serve as `under`, and the group is neither left-of nor above
// — so the CVV rode out RAW on `ax_tree`, `ax_find` and the `mac_view` legend.
//
// The negative half is, again, the load-bearing half — and more so here than
// anywhere else, because an enclosing caption darkens a whole SUBTREE rather
// than one value. A group titled "Payment", "Shipping" or "Toolbar" must leave
// its children completely legible.

/// Four sibling groups, deliberately far enough apart that NO beside/above
/// caption cone reaches across them. Anything that goes dark here went dark
/// because of the group it is INSIDE, which is the whole point.
private func _enclosingGroupSource() -> _RedAXSource {
    var elements: [Int: _RedElement] = [:]
    func group(_ id: Int, _ title: String, _ frame: MacAXFrame, children: [Int]) {
        elements[id] = _RedElement(
            attributes: MacAXAttributes(role: "AXGroup", title: title, frame: frame),
            children: children
        )
    }
    func field(_ id: Int, _ value: String, _ frame: MacAXFrame) {
        elements[id] = _RedElement(
            attributes: MacAXAttributes(
                role: "AXTextField", value: value, enabled: true,
                frame: frame, actions: ["AXPress"]
            ),
            children: []
        )
    }

    // [0] the leak: a secret-naming group around an untitled field.
    group(1, "CVV", MacAXFrame(x: 10, y: 10, w: 200, h: 60), children: [2])
    field(2, "451", MacAXFrame(x: 20, y: 20, w: 60, h: 20))
    // [1] ordinary grouped UI. "Payment" names a form section, not a secret.
    group(3, "Payment", MacAXFrame(x: 10, y: 400, w: 200, h: 60), children: [4])
    field(4, "4B-1200", MacAXFrame(x: 20, y: 410, w: 120, h: 20))
    // [2] a secret-naming group whose children are NOT all secrets: the shape
    // test still decides. A button label survives; a token-shaped value does not.
    group(5, "Password", MacAXFrame(x: 10, y: 800, w: 200, h: 80), children: [6, 7])
    elements[6] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXButton", title: "New Tab", enabled: true,
            frame: MacAXFrame(x: 20, y: 810, w: 80, h: 22), actions: ["AXPress"]
        ),
        children: []
    )
    field(7, "Zx9-4410", MacAXFrame(x: 20, y: 840, w: 150, h: 20))
    // [3] the WORD-BOUNDARY guard: "Shipping" contains the substring "pin".
    group(8, "Shipping", MacAXFrame(x: 800, y: 10, w: 200, h: 60), children: [9])
    field(9, "4B-1200", MacAXFrame(x: 810, y: 20, w: 120, h: 20))

    elements[0] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXWindow", title: "Checkout",
            frame: MacAXFrame(x: 0, y: 0, w: 1600, h: 1000)
        ),
        children: [1, 3, 5, 8]
    )
    return _RedAXSource(elements: elements, rootID: 0)
}

@Test func axTreeRedactsValueCaptionedByItsEnclosingGroup() async throws {
    let result = try await _redClient(_enclosingGroupSource()).dispatch(action: "ax_tree", body: [:])
    #expect(result.ok)
    let output = _obj(result.output)
    // The group keeps its name — she has to be able to say "the CVV box".
    #expect(_str(_nodeAtPath(output, [0])["title"]) == "CVV")
    // The value inside it does not. Nothing about "451" is secret-shaped and
    // no caption sits left of or above it: containment is the only route.
    _expectRedacted(
        _nodeAtPath(output, [0, 0])["value"],
        reason: "enclosing_cvv",
        characters: 3
    )
    #expect(!String(describing: result.output).contains("451"))
}

@Test func axTreeLeavesOrdinaryEnclosingGroupsCompletelyLegible() async throws {
    let result = try await _redClient(_enclosingGroupSource()).dispatch(action: "ax_tree", body: [:])
    let output = _obj(result.output)
    // "Payment" is a form SECTION. Darkening its children would blind her to
    // an entire checkout page — the exact over-redaction failure this guard
    // exists to prevent.
    #expect(_str(_nodeAtPath(output, [1])["title"]) == "Payment")
    #expect(_str(_nodeAtPath(output, [1, 0])["value"]) == "4B-1200")
    // "Shipping" CONTAINS the substring "pin". A substring match — the rule the
    // beside-geometry uses, where one value is at stake — would darken a whole
    // shipping section here. The enclosing rule matches WORDS.
    #expect(_str(_nodeAtPath(output, [3])["title"]) == "Shipping")
    #expect(_str(_nodeAtPath(output, [3, 0])["value"]) == "4B-1200")
}

@Test func enclosingSecretCaptionStillDefersToTheShapeTest() async throws {
    let result = try await _redClient(_enclosingGroupSource()).dispatch(action: "ax_tree", body: [:])
    let output = _obj(result.output)
    // Inside a group literally titled "Password": the BUTTON keeps its label.
    // A caption says which shapes are in play, it never blanks a subtree.
    #expect(_str(_nodeAtPath(output, [2, 0])["title"]) == "New Tab")
    // …and the token-shaped value in the same group goes dark.
    _expectRedacted(_nodeAtPath(output, [2, 1])["value"], reason: "enclosing_secret_caption")
    #expect(!String(describing: result.output).contains("Zx9-4410"))
}

@Test func axFindRedactsEnclosedValueEvenWhenTheGroupIsNotAMatch() async throws {
    // Query only text FIELDS: the "CVV" GROUP is not in the match set. If the
    // enclosing context were built from matches rather than the whole
    // snapshot, the three digits would ride out in the clear.
    let result = try await _redClient(_enclosingGroupSource()).dispatch(
        action: "ax_find",
        body: ["role": .string("textfield")]
    )
    let matches = _arr(_obj(result.output)["matches"]).map { _obj($0) }
    #expect(matches.allSatisfy { _str($0["role"]) == "AXTextField" })
    let cvv = try #require(matches.first { $0["path"] == JSONValue.array([.int(0), .int(0)]) })
    _expectRedacted(cvv["value"], reason: "enclosing_cvv", characters: 3)
    // The negative rides in the SAME response.
    let shipping = try #require(matches.first { $0["path"] == JSONValue.array([.int(3), .int(0)]) })
    #expect(_str(shipping["value"]) == "4B-1200")
}

@Test func enclosingContextIsWhatCatchesTheCVVNotSomeOtherRule() throws {
    // TEETH, permanently in-tree: the same node, serialized with the enclosing
    // context REMOVED, comes back raw. This is the reverted-fix state — if the
    // ancestor walk is ever dropped, deleted or silently returns `.none`, this
    // is the assertion that fails instead of a secret shipping.
    let nodes = MacAccessibilityReader.walk(
        source: _enclosingGroupSource(),
        root: MacAXElementRef(id: 0)
    ).nodes
    let cvvField = try #require(nodes.first { $0.path == [0, 0] })
    #expect(cvvField.attributes.value == "451", "the reader itself stays byte-identical")

    let withoutContext = MacScreenViewTextRedaction.redactedNodeJSON(cvvField, context: .empty)
    #expect(_str(_obj(withoutContext)["value"]) == "451", "no context ⇒ the leak is back")

    let withContext = MacScreenViewTextRedaction.redactedNodeJSON(
        cvvField,
        context: MacScreenViewTextRedaction.nodeSecretContext(nodes)
    )
    _expectRedacted(_obj(withContext)["value"], reason: "enclosing_cvv", characters: 3)
}

@Test func enclosingCaptionNeedsBothAncestryAndContainment() throws {
    let caption = MacScreenViewTextRedaction.EnclosingCaption(
        frame: MacAXFrame(x: 0, y: 0, w: 500, h: 500),
        path: [1],
        kinds: MacScreenViewTextRedaction.EnclosingCaptionKinds(secret: true)
    )
    let inside = MacAXFrame(x: 10, y: 10, w: 50, h: 20)
    // Descendant AND enclosed → applies.
    #expect(MacScreenViewTextRedaction.enclosingKinds(
        forNodeAt: inside, path: [1, 0], among: [caption]
    ).secret)
    // Same rectangle, unrelated branch → a bigger overlapping box is not a
    // caption. Frame containment alone would have said yes.
    #expect(!MacScreenViewTextRedaction.enclosingKinds(
        forNodeAt: inside, path: [2, 0], among: [caption]
    ).secret)
    // Descendant but drawn outside the group's box → not enclosed.
    #expect(!MacScreenViewTextRedaction.enclosingKinds(
        forNodeAt: MacAXFrame(x: 900, y: 10, w: 50, h: 20), path: [1, 0], among: [caption]
    ).secret)
    // The node itself is never its own ancestor.
    #expect(!MacScreenViewTextRedaction.enclosingKinds(
        forNodeAt: inside, path: [1], among: [caption]
    ).secret)
}

@Test func theRootWindowIsNeverAnEnclosingCaption() async throws {
    // A window titled with a secret encloses EVERYTHING. Treating it as a
    // caption would blank the whole screen — the organ would go blind exactly
    // when she most needs to read it. The title is redacted on its own instead.
    var elements: [Int: _RedElement] = [:]
    elements[1] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXTextField", value: "4B-1200", enabled: true,
            frame: MacAXFrame(x: 20, y: 20, w: 120, h: 20), actions: ["AXPress"]
        ),
        children: []
    )
    elements[0] = _RedElement(
        attributes: MacAXAttributes(
            role: "AXWindow", title: "1Password — Recovery Code",
            frame: MacAXFrame(x: 0, y: 0, w: 900, h: 600)
        ),
        children: [1]
    )
    let result = try await _redClient(_RedAXSource(elements: elements, rootID: 0))
        .dispatch(action: "ax_tree", body: [:])
    let output = _obj(result.output)
    // The whole window stays readable. Without the root exclusion every
    // token-shaped value on this screen would be dark.
    #expect(_str(_nodeAtPath(output, [0])["value"]) == "4B-1200")
    // The title is judged on its own SHAPE, exactly as before — a title that
    // merely names a secret is not itself one, and she needs to know which
    // window she is looking at. (A title that IS a secret is redacted by
    // `axTreeRedactsSecretShapedWindowTitle`.)
    #expect(_str(output["window_title"]) == "1Password — Recovery Code")
}

// MARK: - W3.5-FIX-R4: the caller's own query, echoed back

@Test func axFindRedactsASecretShapedQueryEcho() async throws {
    // The model reads a code off the screen, then calls
    // `mac_ax_find(value: "482913")` to locate the field. The echo put the
    // code back into a traced/persisted/synced result — the redaction on the
    // way OUT undone by the echo on the way IN.
    let result = try await _redClient(_secretScreenSource()).dispatch(
        action: "ax_find",
        body: ["value": .string("482913")]
    )
    #expect(result.ok)
    let query = _obj(_obj(result.output)["query"])
    _expectRedacted(query["value"], reason: "otp_shape", characters: 6)
    #expect(!String(describing: result.output).contains("482913"))
}

@Test func axFindKeepsAnOrdinaryQueryEchoLegible() async throws {
    // The echo has to stay USEFUL: a caller needs to see what it asked for.
    let result = try await _redClient(_secretScreenSource()).dispatch(
        action: "ax_find",
        body: ["role": .string("button"), "title": .string("Send")]
    )
    let query = _obj(_obj(result.output)["query"])
    #expect(_str(query["title"]) == "Send")
    // A role is an AX constant, never user text — nothing to protect.
    #expect(_str(query["role"]) == "button")
    #expect(query["value"] == JSONValue.null)
}
