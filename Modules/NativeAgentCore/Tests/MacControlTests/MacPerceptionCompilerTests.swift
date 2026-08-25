import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - Synthetic AX source (same seam MacAccessibilityReaderTests uses)
//
// A live look needs a window server, a frontmost app and a granted TCC
// permission — none of which exist in CI. So the compiler, the handles, the
// redaction, the byte budget and the frame store are pinned against a synthetic
// tree pushed through the EXACT production walker and the EXACT production
// handler. Only the element source is swapped.

private struct _LookElement {
    var attributes: MacAXAttributes?
    var children: [Int]
}

private final class _LookSource: MacAXElementSource, @unchecked Sendable {
    private let elements: [Int: _LookElement]
    private let rootID: Int?
    private let trusted: Bool
    private let app: MacAXAppInfo?
    private let focus: [Int]?

    init(
        elements: [Int: _LookElement],
        rootID: Int?,
        trusted: Bool = true,
        app: MacAXAppInfo? = MacAXAppInfo(
            name: "Mail", bundleIdentifier: "com.apple.mail", processIdentifier: 4242
        ),
        focus: [Int]? = nil
    ) {
        self.elements = elements
        self.rootID = rootID
        self.trusted = trusted
        self.app = app
        self.focus = focus
    }

    func isTrusted() -> Bool { trusted }
    func frontmostApp() -> MacAXAppInfo? { app }
    func frontmostWindowRoot() -> MacAXElementRef? { rootID.map { MacAXElementRef(id: $0) } }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? { elements[ref.id]?.attributes }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        (elements[ref.id]?.children ?? []).map { MacAXElementRef(id: $0) }
    }
    func focusedElementPath() -> [Int]? { focus }
}

private func _walk(_ source: _LookSource) -> MacAXTreeSnapshot {
    guard let root = source.frontmostWindowRoot() else {
        return MacAXTreeSnapshot(nodes: [], truncated: false, truncationReasons: [], skippedAtLeast: 0)
    }
    return MacAccessibilityReader.walk(source: source, root: root)
}

private func _compile(_ source: _LookSource, maxAffordances: Int = MacPerceptionCompiler.maxAffordances) -> MacLookPercept {
    let snapshot = _walk(source)
    return MacPerceptionCompiler.compile(
        snapshot: snapshot,
        app: source.frontmostApp(),
        windowTitle: snapshot.nodes.first?.attributes.title,
        focusPath: source.focusedElementPath(),
        maxAffordances: maxAffordances
    )
}

private func _object(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let object) = value else { return [:] }
    return object
}

private func _array(_ value: JSONValue?) -> [JSONValue] {
    guard case .array(let array)? = value else { return [] }
    return array
}

// MARK: - Fixtures

/// A compose window: a toolbar of labeled buttons, a labeled text field, a
/// secure field, three UNLABELED toolbar buttons (Finder's real shape), and one
/// static text that must never be mistaken for an affordance.
private func _composeSource(withSheet: Bool = false, focus: [Int]? = nil) -> _LookSource {
    var elements: [Int: _LookElement] = [:]
    var toolbarChildren: [Int] = []
    var next = 100

    func add(_ attributes: MacAXAttributes, into bucket: inout [Int]) {
        elements[next] = _LookElement(attributes: attributes, children: [])
        bucket.append(next)
        next += 1
    }

    add(MacAXAttributes(role: "AXButton", title: "Send", actions: ["AXPress"]), into: &toolbarChildren)
    add(MacAXAttributes(role: "AXButton", title: "Cancel", actions: ["AXPress"]), into: &toolbarChildren)
    add(MacAXAttributes(role: "AXButton", title: "Attach", actions: ["AXPress"]), into: &toolbarChildren)
    // Three glyph-only toolbar buttons — real, unnamed, and counted.
    add(MacAXAttributes(role: "AXButton", actions: ["AXPress"]), into: &toolbarChildren)
    add(MacAXAttributes(role: "AXButton", actions: ["AXPress"]), into: &toolbarChildren)
    add(MacAXAttributes(role: "AXCheckBox", actions: ["AXPress"]), into: &toolbarChildren)

    elements[10] = _LookElement(
        attributes: MacAXAttributes(role: "AXToolbar", title: "Compose toolbar"),
        children: toolbarChildren
    )

    var bodyChildren: [Int] = []
    add(MacAXAttributes(role: "AXStaticText", title: "To:"), into: &bodyChildren)
    add(MacAXAttributes(role: "AXTextField", title: "Subject", value: "Lunch"), into: &bodyChildren)
    add(
        MacAXAttributes(role: "AXSecureTextField", title: "Password", value: "hunter2-correct-horse"),
        into: &bodyChildren
    )
    elements[11] = _LookElement(
        attributes: MacAXAttributes(role: "AXScrollArea", title: "Message body"),
        children: bodyChildren
    )

    var rootChildren = [10, 11]
    if withSheet {
        elements[30] = _LookElement(
            attributes: MacAXAttributes(role: "AXStaticText", title: "Save this message as a draft?"),
            children: []
        )
        elements[31] = _LookElement(
            attributes: MacAXAttributes(role: "AXButton", title: "Save Draft", actions: ["AXPress"]),
            children: []
        )
        elements[20] = _LookElement(
            attributes: MacAXAttributes(role: "AXSheet"),
            children: [30, 31]
        )
        rootChildren.append(20)
    }

    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Lunch tomorrow"),
        children: rootChildren
    )
    return _LookSource(elements: elements, rootID: 0, focus: focus)
}

/// Five identically-fingerprinted siblings: same role, same (absent) title,
/// same parent chain. Exactly the Chrome/System Settings shape the spike
/// measured, and the reason the handle carries an ordinal.
private func _duplicateSource(count: Int = 5) -> _LookSource {
    var elements: [Int: _LookElement] = [:]
    var children: [Int] = []
    for index in 0..<count {
        let id = 200 + index
        elements[id] = _LookElement(
            attributes: MacAXAttributes(role: "AXButton", title: "Add", actions: ["AXPress"]),
            children: []
        )
        children.append(id)
    }
    elements[10] = _LookElement(
        attributes: MacAXAttributes(role: "AXGroup", title: "Rows"),
        children: children
    )
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Rows"),
        children: [10]
    )
    return _LookSource(elements: elements, rootID: 0)
}

// MARK: - Glance

@Test
func glance_isOneLine_namingApp_windowTitle_countsAndExampleButtons() {
    let percept = _compile(_composeSource(focus: [1, 1]))
    let line = percept.glanceLine()

    #expect(line.count <= MacPerceptionCompiler.glanceMaxChars, "a glance is ONE line: \(line.count) chars")
    #expect(!line.contains("\n"), "a glance must never contain a newline")
    #expect(line.hasPrefix("Mail — \"Lunch tomorrow\""), "glance starts with app — \"window\": \(line)")
    // 8 interactive (6 toolbar + subject + password), 5 of them labeled.
    #expect(line.contains("8 controls (5 labeled)"), "glance must carry the labeled/total census: \(line)")
    #expect(line.contains("focus: AXTextField \"Subject\""), "glance names the focused element: \(line)")
    #expect(line.contains("e.g. Send, Cancel, Attach"), "glance offers the first labeled buttons: \(line)")
}

@Test
func glance_reportsMODAL_onlyWhenASheetIsPresent() {
    let withSheet = _compile(_composeSource(withSheet: true)).glanceLine()
    #expect(withSheet.contains("MODAL: Save this message as a draft?"),
            "a sheet must surface in the glance — it changes what every other control means: \(withSheet)")

    let without = _compile(_composeSource(withSheet: false)).glanceLine()
    #expect(!without.contains("MODAL"),
            "no sheet ⇒ no MODAL segment (the negative control): \(without)")
}

@Test
func glance_omitsFocus_whenTheSourceCannotTell() {
    // focus: nil — the source has no notion of focus. Absence is reported as
    // absence rather than guessed at from "the first text field".
    let line = _compile(_composeSource(focus: nil)).glanceLine()
    #expect(!line.contains("focus:"), "an unknown focus must not be invented: \(line)")
}

// MARK: - Look

@Test
func look_keepsUnnamedInteractiveElementsWithTheirStableHandles() {
    let percept = _compile(_composeSource())
    let object = _object(percept.lookJSON().json)

    let affordances = _array(object["affordances"]).map { _object($0) }
    #expect(affordances.count == 8, "every interactive control stays addressable, got \(affordances.count)")
    let unnamed = affordances.filter { $0["label_source"] == .string("unlabeled") }
    #expect(unnamed.count == 3, "unnamed controls must retain their handles: \(affordances)")
    #expect(unnamed.allSatisfy { $0["handle"] != nil })
    // Static text is not an affordance, however visible it is.
    #expect(!affordances.contains { $0["role"] == .string("AXStaticText") },
            "AXStaticText is prose, not an affordance")

    // The unlabeled remainder is COUNTED, never hidden.
    let unlabeled = _object(object["unlabeled"] ?? .null)
    #expect(unlabeled["AXButton"] == .int(2), "two unnamed toolbar buttons must be counted: \(unlabeled)")
    #expect(unlabeled["AXCheckBox"] == .int(1), "the unnamed checkbox must be counted: \(unlabeled)")
    #expect(object["interactive_count"] == .int(8))
    #expect(object["labeled_count"] == .int(5))
}

@Test
func look_carriesLandmarks_andTheWalkTruncationState() {
    let percept = _compile(_composeSource(withSheet: true))
    let object = _object(percept.lookJSON().json)

    let kinds = Set(_array(object["landmarks"]).compactMap { row -> String? in
        guard case .string(let kind)? = _object(row)["kind"] else { return nil }
        return kind
    })
    #expect(kinds.contains("toolbar"))
    #expect(kinds.contains("scrollarea"))
    #expect(kinds.contains("sheet"))
    #expect(_array(object["landmarks"]).count <= MacPerceptionCompiler.maxLandmarks)

    // Truncation accounting rides through untouched from the walk.
    #expect(object["truncated"] == .bool(false))
    #expect(object["skipped_at_least"] == .int(0))
    #expect(object["truncation_reasons"] == .array([]))
}

@Test
func look_reportsTheModalAsAStructuredField_notJustInTheGlance() {
    let object = _object(_compile(_composeSource(withSheet: true)).lookJSON().json)
    let modal = _object(object["modal"] ?? .null)
    #expect(modal["role"] == .string("AXSheet"))
    #expect(modal["label"] == .string("Save this message as a draft?"))

    let none = _object(_compile(_composeSource(withSheet: false)).lookJSON().json)
    #expect(none["modal"] == .null, "no sheet ⇒ modal is null, not a fabricated object")
}

// MARK: - Handles

@Test
func handles_areDeterministic_acrossTwoCompilesOfTheSameTree() {
    let first = _compile(_composeSource()).affordances.map(\.handle)
    let second = _compile(_composeSource()).affordances.map(\.handle)
    #expect(first == second, "the same tree must yield the same handles: \(first) vs \(second)")
    #expect(!first.contains(""), "every affordance gets a real handle")
    // Process-stable, not Hasher-seeded: pin the primitive itself.
    #expect(MacLookHandle.fnv1a64("AXWindow:Inbox>AXButton//Send") == MacLookHandle.fnv1a64("AXWindow:Inbox>AXButton//Send"))
}

@Test
func handles_areUnique_andCarryAnOrdinalWhenTheFingerprintRepeats() {
    let percept = _compile(_duplicateSource(count: 5))
    let handles = percept.affordances.map(\.handle)

    #expect(handles.count == 5)
    #expect(Set(handles).count == 5, "five identically-fingerprinted buttons must get five DISTINCT handles: \(handles)")
    // First bare, rest suffixed in document order.
    #expect(!handles[0].contains("."), "the first of a repeated fingerprint is bare: \(handles[0])")
    #expect(handles[1].hasSuffix(".2"), "the second carries ordinal 2: \(handles[1])")
    #expect(handles[4].hasSuffix(".5"), "the fifth carries ordinal 5: \(handles[4])")
    // They all share one token — the ordinal is the ONLY thing separating them.
    let tokens = Set(handles.map { $0.split(separator: ".").first.map(String.init) ?? $0 })
    #expect(tokens.count == 1, "same fingerprint ⇒ same token: \(tokens)")
}

@Test
func handles_excludeValues_soAChangingFieldKeepsItsIdentity() {
    // Same tree, different text-field CONTENTS. A field whose contents change
    // is still the same field, so the handle must not move.
    func source(_ value: String) -> _LookSource {
        var elements: [Int: _LookElement] = [:]
        elements[1] = _LookElement(
            attributes: MacAXAttributes(role: "AXTextField", title: "Subject", value: value),
            children: []
        )
        elements[0] = _LookElement(
            attributes: MacAXAttributes(role: "AXWindow", title: "Compose"),
            children: [1]
        )
        return _LookSource(elements: elements, rootID: 0)
    }
    let before = _compile(source("Lunch")).affordances.first?.handle
    let after = _compile(source("Dinner, actually")).affordances.first?.handle
    #expect(before != nil)
    #expect(before == after, "a value change must not mint a new handle: \(String(describing: before)) vs \(String(describing: after))")
}

@Test
func everyAffordanceCarriesItsChildIndexPath_theResolveFallback() {
    let percept = _compile(_composeSource())
    for affordance in percept.affordances {
        #expect(!affordance.path.isEmpty, "\(affordance.label) must carry its path")
    }
    // And the path survives serialization — item 3's verbs and mac_ax_act both
    // need it when a fingerprint has changed under them.
    let rows = _array(_object(percept.lookJSON().json)["affordances"]).map { _object($0) }
    for row in rows {
        #expect(row["path"] != nil, "path must ride out on the wire: \(row)")
    }
    // The toolbar's first button is child 0 of child 0 of the window.
    #expect(percept.affordances.first?.path == [0, 0])
}

// MARK: - Redaction

@Test
func secureFieldValue_isRedacted_neverInTheClear() {
    let percept = _compile(_composeSource())
    let rows = _array(_object(percept.lookJSON().json)["affordances"]).map { _object($0) }
    let password = try? #require(rows.first { $0["role"] == .string("AXSecureTextField") })
    let row = password ?? [:]

    #expect(row["secret_field"] == .bool(true))
    let value = _object(row["value"] ?? .null)
    #expect(value["redacted"] == .bool(true), "a secure field's value must ride out redacted: \(row)")
    #expect(value["character_count"] == .int(21))
    #expect(value["sha256"] != nil, "the digest is what makes redaction auditable")

    // The literal characters appear NOWHERE in the serialized percept.
    let bytes = try? _object(percept.lookJSON().json)["affordances"].map { try $0.serializedData(pretty: false) } ?? Data()
    let text = String(data: bytes ?? Data(), encoding: .utf8) ?? ""
    #expect(!text.contains("hunter2"), "the password must not appear anywhere in the look payload")
}

@Test
func aSecretShapedLabelOrWindowTitle_isRedactedInBothGrades() {
    // The window title is routinely the secret itself (a terminal titled with
    // the token it just printed). Same standalone shape test as the legend.
    var elements: [Int: _LookElement] = [:]
    elements[1] = _LookElement(
        attributes: MacAXAttributes(role: "AXButton", title: "OK", actions: ["AXPress"]),
        children: []
    )
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "sk-live-9f2ab7c41de8905632aa77bd"),
        children: [1]
    )
    let percept = _compile(_LookSource(elements: elements, rootID: 0))

    let window = _object(_object(percept.lookJSON().json)["window"] ?? .null)
    #expect(window["redacted"] == .bool(true), "a key-shaped window title must be redacted in look")
    #expect(!percept.glanceLine().contains("sk-live"), "…and must not leak through the glance either")
}

// MARK: - Byte budget

@Test
func lookJSON_respectsTheByteBudget_andSAYSSoWhenItTrims() {
    // 60 affordances with long labels — comfortably over 6 KB.
    var elements: [Int: _LookElement] = [:]
    var children: [Int] = []
    for index in 0..<MacPerceptionCompiler.maxAffordances {
        let id = 300 + index
        elements[id] = _LookElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                title: "Command number \(index) with a deliberately long descriptive label",
                actions: ["AXPress"]
            ),
            children: []
        )
        children.append(id)
    }
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Dense"),
        children: children
    )
    let percept = _compile(_LookSource(elements: elements, rootID: 0))
    let rendering = percept.lookJSON()
    let object = _object(rendering.json)

    #expect(rendering.bytes <= MacPerceptionCompiler.lookByteBudget,
            "the look JSON is hard-capped at 6 KB, got \(rendering.bytes)")
    #expect(object["affordances_truncated"] == .bool(true),
            "trimming for bytes must be REPORTED, never silent")
    #expect(rendering.affordancesDroppedForBytes > 0)
    #expect(object["affordances_dropped_for_bytes"] == .int(Int64(rendering.affordancesDroppedForBytes)))
    // The census still tells the truth about what exists.
    #expect(object["interactive_count"] == .int(Int64(MacPerceptionCompiler.maxAffordances)))

    // Negative control: a small window is NOT reported as truncated.
    let small = _compile(_composeSource()).lookJSON()
    #expect(small.bytes <= MacPerceptionCompiler.lookByteBudget)
    #expect(_object(small.json)["affordances_truncated"] == .bool(false))
}

@Test
func affordanceCap_isReportedTooAndNeverRaisedAboveTheCompilerCeiling() {
    let percept = _compile(_duplicateSource(count: 5), maxAffordances: 2)
    #expect(percept.affordances.count == 2)
    #expect(percept.affordancesOmitted == 3)
    #expect(_object(percept.lookJSON().json)["affordances_truncated"] == .bool(true))

    // A caller cannot raise the ceiling.
    let raised = _compile(_duplicateSource(count: 5), maxAffordances: 10_000)
    #expect(raised.affordances.count == 5)
}

// MARK: - Frame store

@Test
func frameStore_resolvesAHandleToItsPath_andRefusesEveryOtherCase() async {
    let store = MacLookFrameStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let percept = _compile(_composeSource())
    let handle = percept.affordances.first!.handle

    // 1. no frame at all
    switch await store.resolve(handle: handle, frameId: "whatever", now: now) {
    case .failure(let failure):
        #expect(failure == .noFrame)
        #expect(failure.guidance.contains("mac_look"))
    case .success: Issue.record("an empty store must refuse, not answer")
    }

    await store.record(MacLookFrame(
        frameId: "frame-1",
        capturedAt: now,
        appName: "Mail",
        bundleId: "com.apple.mail",
        windowTitle: "Lunch tomorrow",
        entries: MacLookFrame.entries(from: percept)
    ))

    // 2. success — a handle resolves to a real path + rect-bearing entry
    switch await store.resolve(handle: handle, frameId: "frame-1", now: now.addingTimeInterval(5)) {
    case .success(let entry):
        #expect(entry.path == [0, 0])
        #expect(entry.role == "AXButton")
        #expect(entry.label == "Send")
    case .failure(let failure): Issue.record("expected a resolve, got \(failure.rawValue)")
    }

    // 3. unknown handle inside the live frame
    switch await store.resolve(handle: "nope99", frameId: "frame-1", now: now) {
    case .failure(let failure): #expect(failure == .unknownHandle)
    case .success: Issue.record("an unminted handle must be refused")
    }

    // 4. an older frame id — single slot, so the previous frame is gone
    await store.record(MacLookFrame(
        frameId: "frame-2", capturedAt: now, appName: nil, bundleId: nil,
        windowTitle: nil, entries: MacLookFrame.entries(from: percept)
    ))
    switch await store.resolve(handle: handle, frameId: "frame-1", now: now) {
    case .failure(let failure): #expect(failure == .staleFrame)
    case .success: Issue.record("a superseded frame id must be refused, not reinterpreted")
    }

    // 5. TTL — injected clock, one second past the boundary
    let expired = now.addingTimeInterval(MacLookFrameStore.ttlSeconds + 1)
    switch await store.resolve(handle: handle, frameId: "frame-2", now: expired) {
    case .failure(let failure):
        #expect(failure == .frameExpired)
        #expect(failure.guidance.contains("180"))
    case .success: Issue.record("a frame past its TTL must be refused")
    }
    // …and exactly ON the boundary it still resolves.
    let boundary = now.addingTimeInterval(MacLookFrameStore.ttlSeconds)
    if case .failure(let failure) = await store.resolve(handle: handle, frameId: "frame-2", now: boundary) {
        Issue.record("the TTL boundary itself must still resolve, got \(failure.rawValue)")
    }
    #expect(await store.isExpired(now: expired))
    #expect(!(await store.isExpired(now: boundary)))
}

// MARK: - The tool surface

@Test
func macLook_glanceAndLook_returnAFrameIdAndTheGradeTheyRan() async throws {
    let store = MacLookFrameStore()
    let client = SwiftNativeMacControl(
        accessibilitySource: _composeSource(focus: [1, 1]),
        lookFrameStore: store
    )

    let glance = try await client.dispatch(action: "look", body: ["grade": .string("glance")])
    #expect(glance.ok)
    #expect(glance.action == "look")
    let glanceOut = _object(glance.output)
    #expect(glanceOut["grade"] == .string("glance"))
    #expect(glanceOut["glance"] != nil)
    #expect(glanceOut["affordances"] == nil, "a glance is ONE line — it must not ship the structured list")
    guard case .string(let glanceFrame)? = glanceOut["frame_id"] else {
        Issue.record("glance must carry a frame_id so a later verb can reference it")
        return
    }
    #expect(await store.latestFrameId() == glanceFrame)

    let look = try await client.dispatch(action: "look", body: [:])
    let lookOut = _object(look.output)
    #expect(lookOut["grade"] == .string("look"), "look is the DEFAULT grade")
    // Unlabeled controls remain in the look payload with stable handles; the
    // compact tool surface must not silently revert to the old labeled-only count.
    #expect(_array(lookOut["affordances"]).count == 8)
    #expect(lookOut["frame_id"] != nil)
    #expect(lookOut["frame_ttl_seconds"] == .int(180))
}

@Test
func macLook_stare_delegatesToTheSameTreeSnapshotMacAxTreeReturns() async throws {
    let source = _composeSource()
    let client = SwiftNativeMacControl(accessibilitySource: source, lookFrameStore: MacLookFrameStore())

    let stare = _object(try await client.dispatch(action: "look", body: ["grade": .string("stare")]).output)
    let tree = _object(try await client.dispatch(action: "ax_tree", body: [:]).output)

    #expect(stare["grade"] == .string("stare"))
    // Byte-identical payload apart from the grade tag: stare DELEGATES, it does
    // not reimplement, so mac_ax_tree and stare can never drift.
    for key in tree.keys {
        #expect(stare[key] == tree[key], "stare must return mac_ax_tree's \(key) unchanged")
    }
    #expect(_array(stare["nodes"]).count == _array(tree["nodes"]).count)
    #expect(_array(stare["nodes"]).count > 0)
}

@Test
func macLook_refusesAnUnknownGrade_ratherThanSilentlyPickingOne() async throws {
    let client = SwiftNativeMacControl(accessibilitySource: _composeSource(), lookFrameStore: MacLookFrameStore())
    let result = try await client.dispatch(action: "look", body: ["grade": .string("squint")])
    #expect(!result.ok)
    #expect(result.error == "unknown_grade")
}

// MARK: - S5: the FINAL byte cap is exact, measured on the whole payload

/// A window with `count` long-labeled buttons — far more than the byte budget
/// can carry, so the trimmer has to bite.
private func _fatSource(count: Int) -> _LookSource {
    var elements: [Int: _LookElement] = [:]
    var children: [Int] = []
    for index in 0..<count {
        let id = 100 + index
        elements[id] = _LookElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                title: "Command number \(index) — a deliberately long control label",
                frame: MacAXFrame(x: 0, y: Double(index) * 20, w: 300, h: 18),
                actions: ["AXPress"]
            ),
            children: []
        )
        children.append(id)
    }
    elements[10] = _LookElement(attributes: MacAXAttributes(role: "AXToolbar", title: "Everything"), children: children)
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "A window with a fairly long title of its own"),
        children: [10]
    )
    return _LookSource(elements: elements, rootID: 0)
}

@Test
func macLook_serializedOutputNeverExceedsTheByteBudget_andSaysWhenItTrimmed() async throws {
    // gpt-5.5 round-2 S5. The old code reserved a FIXED 768 bytes for the
    // envelope and then measured; a long window title plus the `seam`, the
    // `limits` block and `how_to_read` walked straight past 6144 and the
    // payload reported the overshoot as if it were the budget.
    let client = SwiftNativeMacControl(accessibilitySource: _fatSource(count: 60), lookFrameStore: MacLookFrameStore())
    let result = try await client.dispatch(action: "look", body: [:])
    #expect(result.ok)
    let output = _object(result.output)
    let serialized = (try? result.output.serializedData(pretty: false).count) ?? 0
    #expect(serialized <= MacPerceptionCompiler.lookByteBudget,
            "the WHOLE mac_look payload must fit \(MacPerceptionCompiler.lookByteBudget) bytes, got \(serialized)")
    #expect(output["bytes"] == .int(Int64(serialized)),
            "`bytes` must be the real, final size of this object — not an estimate: \(output["bytes"] ?? .null) vs \(serialized)")
    #expect(output["affordances_truncated"] == .bool(true), "trimming must be declared, never silent")
    #expect(output["byte_budget_exceeded"] == nil)
    let dropped = _object(result.output)["affordances_dropped_for_bytes"] ?? .int(0)
    #expect(dropped != .int(0), "this fixture cannot fit — some rows must be reported as dropped")
}

@Test
func macLook_smallWindowIsNotTrimmed_andStillReportsItsExactSize() async throws {
    // The negative control: an ordinary window is under budget, reports no
    // truncation, and still measures itself exactly.
    let client = SwiftNativeMacControl(accessibilitySource: _composeSource(), lookFrameStore: MacLookFrameStore())
    let result = try await client.dispatch(action: "look", body: [:])
    let output = _object(result.output)
    let serialized = (try? result.output.serializedData(pretty: false).count) ?? 0
    #expect(serialized <= MacPerceptionCompiler.lookByteBudget)
    #expect(output["bytes"] == .int(Int64(serialized)))
    #expect(output["affordances_dropped_for_bytes"] == .int(0))
}

@Test
func macLook_honorsMaxNodes_andSaysWhatTheLimitsResolvedTo() async throws {
    // Agent round 2 — she read `max_nodes`/`max_depth` as silently ignored.
    // They are honored and clamped; the walk really does get smaller, and the
    // payload now names the resolved values so "ignored" is falsifiable.
    let client = SwiftNativeMacControl(accessibilitySource: _fatSource(count: 60), lookFrameStore: MacLookFrameStore())
    let wide = _object(try await client.dispatch(action: "look", body: [:]).output)
    let narrow = _object(try await client.dispatch(action: "look", body: ["max_nodes": .int(6)]).output)

    #expect(_array(narrow["affordances"]).count < _array(wide["affordances"]).count,
            "a smaller node budget must produce a smaller walk: \(_array(narrow["affordances"]).count) vs \(_array(wide["affordances"]).count)")
    #expect(narrow["truncated"] == .bool(true))
    #expect(_object(narrow["limits"] ?? .null)["max_nodes"] == .int(6))
    #expect(_object(wide["limits"] ?? .null)["max_nodes"] == .int(Int64(MacAXLimits.hardMaxNodes)))
    // …and a caller cannot RAISE them.
    let greedy = _object(try await client.dispatch(action: "look", body: ["max_nodes": .int(10_000)]).output)
    #expect(_object(greedy["limits"] ?? .null)["max_nodes"] == .int(Int64(MacAXLimits.hardMaxNodes)))
}

// MARK: - A2: page-first perception for a Chromium window

/// A Chrome-shaped tree: a shell whose toolbar and bookmarks bar carry dozens
/// of controls, with the `AXWebArea` buried underneath them — the exact shape
/// that spent Agent's whole node budget on bookmarks and never reached the page.
private func _chromiumSource(bookmarks: Int = 40, webDepth: Int = 5) -> _LookSource {
    var elements: [Int: _LookElement] = [:]
    var bookmarkIDs: [Int] = []
    for index in 0..<bookmarks {
        let id = 500 + index
        elements[id] = _LookElement(
            attributes: MacAXAttributes(role: "AXButton", title: "Bookmark \(index)", actions: ["AXPress"]),
            children: []
        )
        bookmarkIDs.append(id)
    }
    elements[20] = _LookElement(attributes: MacAXAttributes(role: "AXGroup", title: "Bookmarks Bar"), children: bookmarkIDs)
    elements[11] = _LookElement(
        attributes: MacAXAttributes(role: "AXTextField", title: "Address and search bar", value: "example.com", actions: ["AXPress"]),
        children: []
    )
    elements[10] = _LookElement(attributes: MacAXAttributes(role: "AXToolbar", title: "Chrome toolbar"), children: [11, 20])

    // The page: a chain of wrapper groups (Chrome's real shape) with the web
    // area at the bottom, then the page's own controls.
    elements[900] = _LookElement(
        attributes: MacAXAttributes(role: "AXButton", title: "Buy now", actions: ["AXPress"]),
        children: []
    )
    elements[901] = _LookElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: nil, value: "Order total: $42"),
        children: []
    )
    elements[800] = _LookElement(attributes: MacAXAttributes(role: "AXWebArea", title: "Example Store"), children: [900, 901])
    var childID = 800
    for level in 0..<webDepth {
        let id = 700 + level
        elements[id] = _LookElement(attributes: MacAXAttributes(role: "AXGroup", title: nil), children: [childID])
        childID = id
    }
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Example Store — Google Chrome"),
        children: [10, childID]
    )
    return _LookSource(
        elements: elements,
        rootID: 0,
        app: MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 777)
    )
}

@Test
func macLook_walksThePageFirst_inAChromiumWindow_andCollapsesTheChrome() async throws {
    let client = SwiftNativeMacControl(accessibilitySource: _chromiumSource(), lookFrameStore: MacLookFrameStore())
    let page = _object(try await client.dispatch(action: "look", body: [:]).output)
    let seam = _object(page["seam"] ?? .null)

    #expect(seam["scope"] == .string("page"), "a chromium window defaults to the PAGE: \(seam)")
    let labels = _array(page["affordances"]).compactMap { row -> String? in
        guard case .string(let label)? = _object(row)["label"] else { return nil }
        return label
    }
    #expect(labels.contains("Buy now"), "the page's controls are the point of the look: \(labels)")
    #expect(!labels.contains { $0.hasPrefix("Bookmark ") },
            "bookmarks must not eat the budget once the page is the scope: \(labels)")
    guard case .string(let chrome)? = seam["chrome"] else {
        Issue.record("the browser chrome must still be reported — as ONE line: \(seam)")
        return
    }
    #expect(chrome.contains("control(s)"))
    #expect(seam["chrome_controls"] == .int(41), "40 bookmarks + the address bar, counted and not listed: \(seam)")

    // The page's readout came along too, so "what does it say" needs no stare.
    let readouts = _array(page["readouts"]).compactMap { row -> String? in
        guard case .string(let text)? = _object(row)["text"] else { return nil }
        return text
    }
    #expect(readouts.contains { $0.contains("Order total") }, "\(readouts)")
}

@Test
func macLook_pagePathsStayWindowRelative_soAnActCanStillResolveThem() async throws {
    // The trap this design has to avoid: a page walk numbered from the web area
    // would hand back child-index paths that resolve to a DIFFERENT element when
    // mac_act walks them from the window root.
    let client = SwiftNativeMacControl(accessibilitySource: _chromiumSource(), lookFrameStore: MacLookFrameStore())
    let page = _object(try await client.dispatch(action: "look", body: [:]).output)
    let seam = _object(page["seam"] ?? .null)
    let webPath = _array(seam["web_area_path"]).compactMap { value -> Int? in
        guard case .int(let index) = value else { return nil }
        return Int(index)
    }
    #expect(!webPath.isEmpty, "the descent must say where it found the page: \(seam)")
    for row in _array(page["affordances"]) {
        let path = _array(_object(row)["path"]).compactMap { value -> Int? in
            guard case .int(let index) = value else { return nil }
            return Int(index)
        }
        #expect(path.starts(with: webPath),
                "every page affordance's path must be rooted at the WINDOW, through the web area: \(path) vs \(webPath)")
    }
}

@Test
func macLook_scopeChrome_looksAtTheBrowsersOwnControls_andScopeIsAlwaysStated() async throws {
    let client = SwiftNativeMacControl(accessibilitySource: _chromiumSource(), lookFrameStore: MacLookFrameStore())
    let chrome = _object(try await client.dispatch(
        action: "look",
        body: ["scope": .string("chrome")]
    ).output)
    let labels = _array(chrome["affordances"]).compactMap { row -> String? in
        guard case .string(let label)? = _object(row)["label"] else { return nil }
        return label
    }
    #expect(_object(chrome["seam"] ?? .null)["scope"] == .string("chrome"))
    #expect(labels.contains { $0.hasPrefix("Bookmark ") }, "scope:chrome addresses the browser itself: \(labels.prefix(5))")

    let both = _object(try await client.dispatch(action: "look", body: ["scope": .string("both")]).output)
    #expect(_object(both["seam"] ?? .null)["scope"] == .string("both"))

    let bad = try await client.dispatch(action: "look", body: ["scope": .string("sideways")])
    #expect(!bad.ok)
    #expect(bad.error == "unknown_scope", "an unknown scope is refused, never silently defaulted")
}

@Test
func macLook_nonChromiumWindow_isUnaffectedByTheDefaultPageScope() async throws {
    // The negative control: a native window has no web area, so the default
    // scope must resolve to `chrome` and the payload must say WHY.
    let client = SwiftNativeMacControl(accessibilitySource: _composeSource(), lookFrameStore: MacLookFrameStore())
    let seam = _object(_object(try await client.dispatch(action: "look", body: [:]).output)["seam"] ?? .null)
    #expect(seam["scope"] == .string("chrome"))
    #expect(seam["scope_reason"] == .string("not_a_chromium_window"))
}

@Test
func findFirst_stopsAtTheFirstMatch_andRefusesToRunAwayOnABudget() {
    let source = _chromiumSource()
    guard let root = source.frontmostWindowRoot() else {
        Issue.record("fixture has no root")
        return
    }
    guard let hit = MacAccessibilityReader.findFirst(role: "AXWebArea", source: source, root: root).hit else {
        Issue.record("the descent must find the web area the ordinary walk misses")
        return
    }
    #expect(source.attributes(of: hit.ref)?.role == "AXWebArea")
    // gpt-5.5 round-3 S5 — a budget too small answers NOT A WRONG NODE, and it
    // says WHICH budget ended the search. "nil" collapsed "it ran out" into
    // "it is not there", and the look then reported `no_web_area_found` on the
    // authority of a search that never reached the page.
    let starved = MacAccessibilityReader.findFirst(
        role: "AXWebArea",
        source: source,
        root: root,
        nodeBudget: 3
    )
    #expect(starved.hit == nil)
    #expect(starved == .nodeCap, "a node-budget stop is a nodeCap, never notFound: \(starved)")
    #expect(starved.truncationReason == "node_cap")
    // …and so does a depth too shallow.
    let shallow = MacAccessibilityReader.findFirst(
        role: "AXWebArea",
        source: source,
        root: root,
        maxDepth: 2
    )
    #expect(shallow.hit == nil)
    #expect(shallow.truncationReason != nil, "a depth-limited stop is truncation, not absence: \(shallow)")
    // The NEGATIVE CONTROL: a tree with no web area at all, searched under
    // budgets big enough to cover it, is the one case that really is `notFound`
    // — otherwise "truncated" would just be the new always-answer.
    guard let nativeRoot = _composeSource().frontmostWindowRoot() else {
        Issue.record("fixture has no native root")
        return
    }
    let absent = MacAccessibilityReader.findFirst(
        role: "AXWebArea",
        source: _composeSource(),
        root: nativeRoot
    )
    #expect(absent == .notFound, "an exhaustive search of a page-less window is notFound: \(absent)")
    #expect(absent.truncationReason == nil)
}

/// The invariant the `visited > nodeBudget` backstop rests on: the fetch clamp
/// never queues more nodes than the budget can pay for, so the search reads at
/// most `nodeBudget` elements no matter how wide the tree is. Remove the clamp
/// and this count runs past the budget — which is exactly what the budget
/// exists to stop, on a Chrome shell that can publish thousands of nodes.
private final class _CountingLookSource: MacAXElementSource, @unchecked Sendable {
    private let inner: _LookSource
    private let lock = NSLock()
    private var reads = 0
    /// Every child fetch, as the LIMIT it asked for — nil meaning "the whole
    /// array, however big it is". On a live AX bridge that unbounded fetch is
    /// the cost the clamp exists to avoid.
    private var fetches: [Int?] = []

    init(_ inner: _LookSource) { self.inner = inner }
    func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
    func childFetches() -> [Int?] { lock.lock(); defer { lock.unlock() }; return fetches }

    func isTrusted() -> Bool { inner.isTrusted() }
    func frontmostApp() -> MacAXAppInfo? { inner.frontmostApp() }
    func frontmostWindowRoot() -> MacAXElementRef? { inner.frontmostWindowRoot() }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? {
        lock.lock(); reads += 1; lock.unlock()
        return inner.attributes(of: ref)
    }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        lock.lock(); fetches.append(nil); lock.unlock()
        return inner.children(of: ref)
    }
    func children(of ref: MacAXElementRef, limit: Int) -> [MacAXElementRef] {
        lock.lock(); fetches.append(limit); lock.unlock()
        return limit <= 0 ? [] : Array(inner.children(of: ref).prefix(limit))
    }
    func childCount(of ref: MacAXElementRef) -> Int { inner.children(of: ref).count }
}

@Test
func findFirst_neverVisitsMoreNodesThanItsBudget() {
    // A window with a very wide shell and no web area anywhere: the search has
    // to give up, and it must give up INSIDE its budget.
    var elements: [Int: _LookElement] = [:]
    let fanout = 500
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Wide"),
        children: Array(1...fanout)
    )
    for index in 1...fanout {
        elements[index] = _LookElement(
            attributes: MacAXAttributes(role: "AXGroup", title: "g\(index)"),
            children: []
        )
    }
    let source = _CountingLookSource(_LookSource(elements: elements, rootID: 0))
    guard let root = source.frontmostWindowRoot() else {
        Issue.record("fixture has no root")
        return
    }
    let budget = 25
    let outcome = MacAccessibilityReader.findFirst(
        role: "AXWebArea",
        source: source,
        root: root,
        nodeBudget: budget
    )
    #expect(outcome == .nodeCap, "a 500-wide shell under a 25-node budget is truncation: \(outcome)")
    #expect(source.readCount() <= budget,
            "the search read \(source.readCount()) nodes on a \(budget)-node budget")
    // …and it never bridged a whole 500-element child array to do it. An
    // unbounded fetch is the pathological cost the clamp exists to avoid, and
    // it is invisible in the node count because the walk stops reading anyway.
    let fetches = source.childFetches()
    #expect(!fetches.isEmpty, "the search must actually descend")
    #expect(fetches.allSatisfy { $0 != nil },
            "every child fetch must be bounded: \(fetches)")
    #expect(fetches.compactMap { $0 }.allSatisfy { $0 <= budget },
            "no fetch may ask for more children than the whole budget: \(fetches)")
}

/// S5 — and the LOOK says so. A Chromium window whose shell is wider than the
/// search budget falls back to chrome scope (correct), but must report
/// `web_area_search_truncated` with the budget that bit, not the flat claim
/// that the window has no page.
@Test
func macLook_reportsWebAreaSearchTruncation_ratherThanClaimingNoPage() async throws {
    // The shell is a fan of 200 empty groups; the web area sits behind them, so
    // a 160-node breadth-first search cannot reach it.
    var elements: [Int: _LookElement] = [:]
    let fanout = 200
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Chrome"),
        children: Array(1...(fanout + 1))
    )
    for index in 1...fanout {
        elements[index] = _LookElement(
            attributes: MacAXAttributes(role: "AXGroup", title: "shelf \(index)"),
            children: []
        )
    }
    elements[fanout + 1] = _LookElement(
        attributes: MacAXAttributes(role: "AXGroup", title: "content"),
        children: [fanout + 2]
    )
    elements[fanout + 2] = _LookElement(
        attributes: MacAXAttributes(role: "AXWebArea", title: "Example"),
        children: []
    )
    let source = _LookSource(
        elements: elements,
        rootID: 0,
        app: MacAXAppInfo(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            processIdentifier: 909
        )
    )
    let client = SwiftNativeMacControl(accessibilitySource: source, lookFrameStore: MacLookFrameStore())
    let seam = _object(_object(try await client.dispatch(action: "look", body: [:]).output)["seam"] ?? .null)
    #expect(seam["scope"] == .string("chrome"), "the fallback to chrome is right — the reason was not")
    #expect(seam["scope_reason"] == .string("web_area_search_truncated"),
            "a budget-exhausted search must not report no_web_area_found: \(seam)")
    #expect(seam["web_area_search_limit"] == .string("node_cap"))
    #expect(seam["scope_reason"] != .string("no_web_area_found"))
}

// MARK: - N7: the focus epoch

/// A source whose focus path is only valid under ITS OWN root: asked about any
/// other root it answers nil, exactly like the live source when focus moved to
/// another window between the walk and the focus read.
private final class _EpochFocusSource: MacAXElementSource, @unchecked Sendable {
    private let inner: _LookSource
    private let ownRoot: MacAXElementRef?
    private let path: [Int]
    private(set) var rootsAskedAbout: [Int?] = []

    init(inner: _LookSource, ownRoot: MacAXElementRef?, path: [Int]) {
        self.inner = inner
        self.ownRoot = ownRoot
        self.path = path
    }

    func isTrusted() -> Bool { inner.isTrusted() }
    func frontmostApp() -> MacAXAppInfo? { inner.frontmostApp() }
    func frontmostWindowRoot() -> MacAXElementRef? { inner.frontmostWindowRoot() }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? { inner.attributes(of: ref) }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] { inner.children(of: ref) }
    func focusedElementPath() -> [Int]? { path }
    func focusedElementPath(relativeTo root: MacAXElementRef?) -> [Int]? {
        rootsAskedAbout.append(root?.id)
        guard let root, root == ownRoot else { return nil }
        return path
    }
}

@Test
func macLook_focusIsReadAgainstTheWALKEDRoot_notWhateverIsFocusedNow() async throws {
    // gpt-5.5 round-2 N7 — the direct regression for the focus epoch. A focus
    // path fetched against a DIFFERENT tree that happens to index into the old
    // snapshot makes a look lie about where the cursor is.
    let base = _composeSource()
    let realRoot = base.frontmostWindowRoot()

    let matching = _EpochFocusSource(inner: base, ownRoot: realRoot, path: [1])
    let matched = _object(try await SwiftNativeMacControl(
        accessibilitySource: matching,
        lookFrameStore: MacLookFrameStore()
    ).dispatch(action: "look", body: [:]).output)
    #expect(matched["focus"] != .null, "focus under the walked root must be reported")
    #expect(matching.rootsAskedAbout == [realRoot?.id],
            "the handler must ASK about the root it walked, not call the rootless overload")

    // Same tree, same focus path — but the source only vouches for it under a
    // root that is not the one the walk used.
    let foreign = _EpochFocusSource(inner: base, ownRoot: MacAXElementRef(id: 987_654), path: [1])
    let unknown = _object(try await SwiftNativeMacControl(
        accessibilitySource: foreign,
        lookFrameStore: MacLookFrameStore()
    ).dispatch(action: "look", body: [:]).output)
    #expect(unknown["focus"] == .null,
            "a focus the source cannot place under THIS root must read as unknown, never as a path: \(unknown["focus"] ?? .null)")
}

@Test
func macLook_isReadTier_andReachableThroughTheDispatcher() {
    #expect(macControlAccessibilityReadActions.contains("look"))
    #expect(macControlDispatchableActions.contains("look"))
    #expect(!macControlAccessibilityInjectionActions.contains("look"),
            "look synthesizes no input and mutates no UI state — it must never join the injection set")
    #expect(!macControlAccessibilityActActions.contains("look"))
    #expect(!macControlAllActions.contains("look"),
            "look has no retired-daemon ancestor, so the daemon-parity inventory must not claim it")
}

// MARK: - The Chromium seam's pure half

@Test
func chromiumSeam_recognisesTheFamilyByBundleId_andByShellShape() {
    let empty = MacAXTreeSnapshot(
        nodes: [MacAXNode(attributes: MacAXAttributes(role: "AXWindow"), path: [])],
        truncated: false, truncationReasons: [], skippedAtLeast: 0
    )
    #expect(MacChromiumAccessibility.looksChromium(bundleId: "com.google.Chrome", snapshot: nil))
    #expect(MacChromiumAccessibility.looksChromium(bundleId: "md.obsidian", snapshot: nil))
    // Unknown Electron app: no web area + a shell-sized window.
    #expect(MacChromiumAccessibility.looksChromium(bundleId: "com.example.unknown", snapshot: empty))
    // The lock screen: one window, zero controls — shell-shaped, but Apple's.
    #expect(!MacChromiumAccessibility.looksChromium(bundleId: "com.apple.loginwindow", snapshot: empty),
            "Apple processes are never Chromium shells (live false positive 2026-08-22)")

    // A native app with a real tree is NOT flagged — the negative control that
    // keeps the flag off Mail and Finder.
    let native = _walk(_composeSource())
    #expect(!MacChromiumAccessibility.looksChromium(bundleId: "com.apple.mail", snapshot: native))

    // And an app that ALREADY exposes a web area needs no settle.
    let web = MacAXTreeSnapshot(
        nodes: [MacAXNode(attributes: MacAXAttributes(role: "AXWebArea"), path: [])],
        truncated: false, truncationReasons: [], skippedAtLeast: 0
    )
    #expect(MacChromiumAccessibility.hasWebArea(web))
    #expect(!MacChromiumAccessibility.hasWebArea(native))
}

// MARK: - gpt-5.5 review round 1 (2026-08-22) — the pins it asked for

/// An unlabeled, NON-secure field showing `123` inside a group titled "CVV".
/// `mac_view`'s legend redacts it through the enclosing-caption geometry; a
/// look that only knew `AXSecureTextField` shipped it in the clear.
private func _cvvFormSource() -> _LookSource {
    _LookSource(elements: _cvvFormElements(), rootID: 0, focus: [0, 1])
}

private func _cvvFormElements() -> [Int: _LookElement] {
    var elements: [Int: _LookElement] = [:]
    elements[40] = _LookElement(
        attributes: MacAXAttributes(role: "AXStaticText", title: "Card details",
                                    frame: MacAXFrame(x: 10, y: 10, w: 200, h: 20)),
        children: []
    )
    // The CVV box: no title of its own, value-labeled, sitting INSIDE the group.
    elements[41] = _LookElement(
        attributes: MacAXAttributes(role: "AXTextField", value: "123",
                                    frame: MacAXFrame(x: 20, y: 40, w: 60, h: 24)),
        children: []
    )
    elements[42] = _LookElement(
        attributes: MacAXAttributes(role: "AXButton", title: "Pay now",
                                    frame: MacAXFrame(x: 20, y: 80, w: 90, h: 24), actions: ["AXPress"]),
        children: []
    )
    elements[30] = _LookElement(
        attributes: MacAXAttributes(role: "AXGroup", title: "CVV",
                                    frame: MacAXFrame(x: 0, y: 0, w: 300, h: 200)),
        children: [40, 41, 42]
    )
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Checkout",
                                    frame: MacAXFrame(x: 0, y: 0, w: 400, h: 400)),
        children: [30]
    )
    return elements
}

@Test
func enclosingCVVGroup_redactsAnUnlabeledFieldsValue_inLookGlanceAndFocus() {
    let percept = _compile(_cvvFormSource())
    let look = percept.lookJSON()
    let serialized = (try? look.json.serializedData(pretty: false)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    #expect(!serialized.contains("\"123\""), "the CVV value rode out in the clear: \(serialized)")
    // The field is value-labeled, so its LABEL channel is the value too — both
    // channels must be redacted, and the affordance itself still listed.
    let rows = _array(_object(look.json)["affordances"]).map(_object)
    let cvvRow = rows.first { _array($0["path"]).map { "\($0)" } == ["int(0)", "int(1)"] }
        ?? rows.first { ($0["role"]) == .string("AXTextField") }
    #expect(cvvRow != nil, "the CVV field must still be an affordance (redacted, not hidden)")
    if let cvvRow {
        #expect(cvvRow["label"] != .string("123"))
        if case .string(let clear)? = cvvRow["label"] { Issue.record("label leaked: \(clear)") }
    }
    // Glance: the focus sits in the CVV box; the glance names the role, never the digits.
    let glance = percept.glanceLine()
    #expect(!glance.contains("123"), Comment(rawValue: glance))
    #expect(glance.contains("Pay now"), "a harmless button label still prints: \(glance)")
}

@Test
func frameEntries_mintOnlyTheRowsActuallyRendered() {
    let percept = _compile(_composeSource())
    #expect(percept.affordances.count >= 3)
    let entries = MacLookFrame.entries(from: percept, rendered: 1)
    // One rendered row ⇒ one addressable handle (plus the focus handle, absent here).
    #expect(entries.count == 1, "\(entries.keys.sorted())")
    #expect(entries[percept.affordances[0].handle] != nil)
    let all = MacLookFrame.entries(from: percept)
    #expect(all.count == percept.affordances.count)
}

@Test
func lookJSON_leavesRoomForTheToolEnvelope() {
    let percept = _compile(_duplicateSource(count: 60))
    let rendering = percept.lookJSON()
    #expect(rendering.bytes <= MacPerceptionCompiler.lookByteBudget - MacPerceptionCompiler.lookEnvelopeReserve)
    // The reserve is what keeps the FINAL payload under the budget once the
    // handler adds frame_id / seam / glance / how_to_read (~600 bytes).
    #expect(MacPerceptionCompiler.lookEnvelopeReserve >= 600)
}

// MARK: - Agent acceptance round 1 (2026-08-22), finding A — READOUTS
//
// She pressed Calculator's Equals and NOTHING in glance, look or the act's
// effect could tell her the answer was 42: the display is an AXStaticText
// inside an AXScrollArea, neither interactive, so the compiler dropped both.
// She had to fall back to a 51 KB stare to read one number — "any read-back
// task forces a stare and the token win evaporates exactly when it matters".

/// Calculator's real shape: a display landmark ("Edit field") whose only child
/// is the AXStaticText showing the number, over a row of AXButtons.
private func _calculatorSource(
    display: String = "7x6",
    containerValue: String? = nil,
    clearLabel: String = "All Clear"
) -> _LookSource {
    var elements: [Int: _LookElement] = [:]
    elements[20] = _LookElement(
        attributes: MacAXAttributes(
            role: "AXStaticText", value: display,
            frame: MacAXFrame(x: 10, y: 10, w: 200, h: 40)
        ),
        children: []
    )
    elements[10] = _LookElement(
        attributes: MacAXAttributes(
            role: "AXScrollArea", title: "Edit field", value: containerValue,
            frame: MacAXFrame(x: 0, y: 0, w: 220, h: 60)
        ),
        children: [20]
    )
    var children = [10]
    for (index, title) in ["7", "×", "6", "=", clearLabel].enumerated() {
        let id = 30 + index
        elements[id] = _LookElement(
            attributes: MacAXAttributes(
                role: "AXButton", title: title,
                frame: MacAXFrame(x: Double(index) * 40, y: 80, w: 36, h: 36),
                actions: ["AXPress"]
            ),
            children: []
        )
        children.append(id)
    }
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Calculator",
                                    frame: MacAXFrame(x: 0, y: 0, w: 240, h: 200)),
        children: children
    )
    return _LookSource(
        elements: elements, rootID: 0,
        app: MacAXAppInfo(name: "Calculator", bundleIdentifier: "com.apple.calculator", processIdentifier: 77)
    )
}

@Test
func readouts_carryTheValueTheDisplayShows_andTheGlanceSaysIt() {
    let percept = _compile(_calculatorSource(display: "42"))

    #expect(percept.readouts.count == 1, "the display is ONE readout: \(percept.readouts)")
    let readout = percept.readouts[0]
    #expect(readout.text == "42")
    #expect(readout.role == "AXStaticText")
    #expect(readout.source == "value")
    #expect(readout.path == [0, 0], "a readout carries its path, like every other row")
    #expect(readout.handle?.isEmpty == false, "a readout is addressable: it carries the handle pass's handle")

    // The GLANCE — the whole point. Calculator's one line must say the answer.
    let glance = percept.glanceLine()
    #expect(glance.contains("reads: \"42\""), "the glance must be able to say the answer: \(glance)")
    #expect(glance.count <= MacPerceptionCompiler.glanceMaxChars)

    // The LOOK — a named channel with honest accounting.
    let object = _object(percept.lookJSON().json)
    #expect(object["readout_count"] == .int(1))
    #expect(object["readouts_omitted"] == .int(0))
    #expect(object["readouts_dropped_for_bytes"] == .int(0))
    let rows = _array(object["readouts"]).map(_object)
    #expect(rows.first?["text"] == .string("42"))
    #expect(rows.first?["source"] == .string("value"))

    // Negative control: with no display value there is no readouts channel to
    // print, and the glance says nothing about what it reads.
    let blank = _compile(_calculatorSource(display: "   "))
    #expect(blank.readouts.isEmpty)
    #expect(!blank.glanceLine().contains("reads:"))
}

@Test
func readouts_includeAContainerThatPublishesItsOwnValue_andDedupeAgainstIt() {
    // Calculator's AXScrollArea publishes the same number its AXStaticText
    // child does. Both are readout-shaped; ONE readout comes out, or this
    // channel becomes a second tree.
    let percept = _compile(_calculatorSource(display: "42", containerValue: "42"))
    #expect(percept.readouts.count == 1, "\(percept.readouts.map(\.text))")
    #expect(percept.readouts[0].role == "AXScrollArea", "document order decides which survives the dedupe")
    #expect(percept.readouts[0].text == "42")
}

@Test
func readouts_dedupeAgainstAffordanceLabels_theWindowTitle_andEachOther() {
    // A button's own AXStaticText child says exactly what the button says.
    var elements: [Int: _LookElement] = [:]
    elements[2] = _LookElement(attributes: MacAXAttributes(role: "AXStaticText", value: "Send"), children: [])
    elements[1] = _LookElement(
        attributes: MacAXAttributes(role: "AXButton", title: "Send", actions: ["AXPress"]),
        children: [2]
    )
    // …and a static text repeating the window title.
    elements[3] = _LookElement(attributes: MacAXAttributes(role: "AXStaticText", value: "Compose"), children: [])
    // …and the same status line twice.
    elements[4] = _LookElement(attributes: MacAXAttributes(role: "AXStaticText", value: "3 unread"), children: [])
    elements[5] = _LookElement(attributes: MacAXAttributes(role: "AXStaticText", value: "3 unread"), children: [])
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Compose"),
        children: [1, 3, 4, 5]
    )
    let percept = _compile(_LookSource(elements: elements, rootID: 0))
    #expect(percept.readouts.map(\.text) == ["3 unread"],
            Comment(rawValue: "a button's static-text child, the window title echo and the duplicate "
                    + "must all drop: \(percept.readouts.map(\.text))"))
}

@Test
func readouts_areCappedAndTheOmittedCountIsReported() {
    var elements: [Int: _LookElement] = [:]
    var children: [Int] = []
    for index in 0..<20 {
        let id = 400 + index
        elements[id] = _LookElement(
            attributes: MacAXAttributes(role: "AXStaticText", value: "line \(index)"),
            children: []
        )
        children.append(id)
    }
    elements[0] = _LookElement(attributes: MacAXAttributes(role: "AXWindow", title: "Dense"), children: children)
    let percept = _compile(_LookSource(elements: elements, rootID: 0))

    #expect(percept.readouts.count == MacPerceptionCompiler.maxReadouts)
    #expect(percept.readoutsOmitted == 20 - MacPerceptionCompiler.maxReadouts)
    #expect(_object(percept.lookJSON().json)["readouts_omitted"] == .int(8),
            "the cap must never short the caller silently")
}

@Test
func readouts_rankTheModalAndTheFocusedSubtreeFirst() {
    var elements: [Int: _LookElement] = [:]
    // A line in a DIFFERENT part of the window — neither in the sheet nor
    // anywhere near the cursor. Document order puts it first, and it must
    // still come last.
    elements[10] = _LookElement(attributes: MacAXAttributes(role: "AXStaticText", value: "background line"), children: [])
    elements[1] = _LookElement(attributes: MacAXAttributes(role: "AXGroup", title: "Elsewhere"), children: [10])
    // The focused field, with its own status text beside it (a real sibling —
    // same parent group, which is what "beside the cursor" means structurally).
    elements[20] = _LookElement(
        attributes: MacAXAttributes(role: "AXTextField", title: "Amount", value: "10", actions: ["AXPress"]),
        children: []
    )
    elements[21] = _LookElement(attributes: MacAXAttributes(role: "AXStaticText", value: "near focus line"), children: [])
    elements[2] = _LookElement(attributes: MacAXAttributes(role: "AXGroup", title: "Payment"), children: [20, 21])
    elements[40] = _LookElement(attributes: MacAXAttributes(role: "AXStaticText", value: "sheet line"), children: [])
    elements[4] = _LookElement(attributes: MacAXAttributes(role: "AXSheet", title: "Confirm"), children: [40])
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Ranked"),
        children: [1, 2, 4]
    )
    let percept = _compile(_LookSource(elements: elements, rootID: 0, focus: [1, 0]))
    #expect(percept.readouts.map(\.text) == ["sheet line", "near focus line", "background line"],
            "modal first, then focus-adjacent, then document order: \(percept.readouts.map(\.text))")
    #expect(percept.readouts[0].inModal)
    #expect(percept.readouts[1].nearFocus)
    // …and the glance prints the modal's readout, which is the one that matters.
    #expect(percept.glanceLine().contains("reads: \"sheet line\""))
}

@Test
func aSecretShapedReadout_isRedactedInLookAndGlance_neverInTheClear() {
    // A login sheet DISPLAYING the key it just minted: a caption naming a
    // secret with the value on the row below it — the exact geometry the prose
    // channel already darkens. A readout channel that bypassed redaction would
    // ship it on the read tool that needs no approval.
    var elements: [Int: _LookElement] = [:]
    elements[1] = _LookElement(
        attributes: MacAXAttributes(role: "AXStaticText", value: "Password",
                                    frame: MacAXFrame(x: 100, y: 100, w: 120, h: 20)),
        children: []
    )
    elements[2] = _LookElement(
        attributes: MacAXAttributes(role: "AXStaticText", value: "hunter2correcthorse",
                                    frame: MacAXFrame(x: 100, y: 130, w: 200, h: 20)),
        children: []
    )
    elements[3] = _LookElement(
        attributes: MacAXAttributes(role: "AXButton", title: "Continue",
                                    frame: MacAXFrame(x: 100, y: 170, w: 90, h: 24),
                                    actions: ["AXPress"]),
        children: []
    )
    elements[0] = _LookElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Sign in",
                                    frame: MacAXFrame(x: 0, y: 0, w: 400, h: 400)),
        children: [1, 2, 3]
    )
    let percept = _compile(_LookSource(elements: elements, rootID: 0))

    let secret = percept.readouts.first { $0.text == "hunter2correcthorse" }
    #expect(secret != nil, "the readout must still EXIST — redacted, not hidden")
    #expect(secret?.displayText == nil, "a redacted readout has no printable text")

    // WHOLE-PAYLOAD assertion: the cleartext appears nowhere.
    let look = percept.lookJSON()
    let serialized = (try? look.json.serializedData(pretty: false))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    #expect(!serialized.contains("hunter2"), "the readout rode out in the clear: \(serialized)")
    #expect(!percept.glanceLine().contains("hunter2"), "…and it must not leak through the glance either")
    // The redaction is auditable, not a silent drop.
    let row = _array(_object(look.json)["readouts"]).map(_object)
        .first { _object($0["text"] ?? .null)["redacted"] == .bool(true) }
    #expect(row != nil, "a darkened readout must carry the count+digest audit shape")
    // The harmless caption still reads, or the organ has been blinded instead.
    #expect(percept.readouts.contains { $0.text == "Password" })
}

@Test
func byteBudget_trimsTheLONGERList_andReportsBothDropCounts() {
    // 60 long-labeled buttons + 12 readouts: the affordance list is the longer
    // one, so it is what gives way — a readout is worth more than the 47th
    // bookmark. The POLICY is pinned here, not left to be inferred.
    var elements: [Int: _LookElement] = [:]
    var children: [Int] = []
    for index in 0..<MacPerceptionCompiler.maxAffordances {
        let id = 300 + index
        elements[id] = _LookElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                title: "Command number \(index) with a deliberately long descriptive label",
                actions: ["AXPress"]
            ),
            children: []
        )
        children.append(id)
    }
    for index in 0..<MacPerceptionCompiler.maxReadouts {
        let id = 600 + index
        elements[id] = _LookElement(
            attributes: MacAXAttributes(role: "AXStaticText", value: "readout \(index)"),
            children: []
        )
        children.append(id)
    }
    elements[0] = _LookElement(attributes: MacAXAttributes(role: "AXWindow", title: "Dense"), children: children)
    let rendering = _compile(_LookSource(elements: elements, rootID: 0)).lookJSON()
    let object = _object(rendering.json)

    #expect(rendering.bytes <= MacPerceptionCompiler.lookByteBudget - MacPerceptionCompiler.lookEnvelopeReserve)
    #expect(rendering.affordancesDroppedForBytes > 0, "the affordance tail is what pays for the bytes")
    #expect(rendering.affordancesDroppedForBytes > rendering.readoutsDroppedForBytes,
            Comment(rawValue: "the LONGER list gives way: 60 affordances vs 12 readouts, so the "
                    + "affordance tail pays \(rendering.affordancesDroppedForBytes) of the drops "
                    + "against \(rendering.readoutsDroppedForBytes)"))
    // …and neither channel can starve the other: trimming stops alternating
    // once the two lists are the same length.
    let keptAffordances = _array(object["affordances"]).count
    let keptReadouts = _array(object["readouts"]).count
    #expect(keptAffordances > 0 && keptReadouts > 0, Comment(rawValue: "\(keptAffordances) / \(keptReadouts)"))
    #expect(abs(keptAffordances - keptReadouts) <= 1,
            Comment(rawValue: "the longer-list rule converges: \(keptAffordances) vs \(keptReadouts)"))
    // BOTH drop counts ride out — a trimmed list that does not say so is how a
    // caller concludes a control does not exist.
    #expect(object["affordances_dropped_for_bytes"] == .int(Int64(rendering.affordancesDroppedForBytes)))
    #expect(object["readouts_dropped_for_bytes"] == .int(Int64(rendering.readoutsDroppedForBytes)))
    #expect(object["readouts_omitted"] == .int(Int64(rendering.readoutsDroppedForBytes)))
}

// MARK: - Agent acceptance round 1, finding B — HONEST HANDLES

/// Finder's list: rows with no title of their own, each containing a cell whose
/// text is the filename. Before `contentName` every row fingerprinted
/// identically and came back as `csmai7`, `csmai7.2`, `csmai7.3` — a
/// DOCUMENT-ORDER ordinal addressing whatever now sits in that position.
private func _fileListSource(names: [String], frames: Bool = false) -> _LookSource {
    var elements: [Int: _LookElement] = [:]
    var rows: [Int] = []
    for (index, name) in names.enumerated() {
        let field = 700 + index * 3
        let cell = field + 1
        let row = field + 2
        let frame = frames
            ? MacAXFrame(x: 0, y: Double(100 + index * 30), w: 200, h: 20)
            : nil
        elements[field] = _LookElement(
            attributes: MacAXAttributes(role: "AXTextField", value: name, frame: frame, actions: ["AXPress"]),
            children: []
        )
        elements[cell] = _LookElement(
            attributes: MacAXAttributes(role: "AXCell", frame: frame), children: [field]
        )
        elements[row] = _LookElement(
            attributes: MacAXAttributes(role: "AXRow", frame: frame), children: [cell]
        )
        rows.append(row)
    }
    elements[10] = _LookElement(attributes: MacAXAttributes(role: "AXTable", title: "Files"), children: rows)
    elements[11] = _LookElement(
        attributes: MacAXAttributes(role: "AXButton", title: "Share", actions: ["AXPress"]),
        children: []
    )
    elements[12] = _LookElement(attributes: MacAXAttributes(role: "AXToolbar", title: "Finder toolbar"), children: [11])
    elements[0] = _LookElement(attributes: MacAXAttributes(role: "AXWindow", title: "Home"), children: [10, 12])
    return _LookSource(elements: elements, rootID: 0)
}

@Test
func titlelessRowsWithDistinctContent_getDistinctNonOrdinalHandles() {
    let percept = _compile(_fileListSource(names: ["Documents", "Downloads", "Pictures", "Projects"]))
    let rows = percept.affordances.filter { $0.role == "AXTextField" }
    #expect(rows.count == 4)
    let handles = rows.map(\.handle)
    #expect(Set(handles).count == 4, "four different files must be four different handles: \(handles)")
    for handle in handles {
        #expect(!handle.contains("."), "a row with content of its own must NOT be position-derived: \(handle)")
    }
    for row in rows { #expect(!row.handleAmbiguous, "\(row.label) is not ambiguous") }
    #expect(percept.ambiguousHandles == 0)
    #expect(_object(percept.lookJSON().json)["ambiguous_handles"] == nil,
            "no ambiguity ⇒ no note; the payload must not carry a field that says nothing")

    // AND the identity is CONTENT, not position: inserting a row at the top
    // must not move the handle of the rows below it.
    let inserted = _compile(_fileListSource(names: ["Applications", "Documents", "Downloads", "Pictures", "Projects"]))
    let byLabel = Dictionary(
        uniqueKeysWithValues: inserted.affordances.filter { $0.role == "AXTextField" }.map { ($0.label, $0.handle) }
    )
    for row in rows {
        #expect(byLabel[row.label] == row.handle,
                "\(row.label) changed handle because a row was inserted above it — that is the bug")
    }
}

@Test
func genuinelyIdenticalSiblings_keepTheirOrdinalBUTSayItIsPositional() {
    let percept = _compile(_duplicateSource(count: 5))
    let object = _object(percept.lookJSON().json)

    #expect(percept.affordances.allSatisfy { $0.handleAmbiguous },
            "five identical unlabeled buttons ARE ambiguous — the ordinal is all there is")
    #expect(percept.ambiguousHandles == 5)
    let note = percept.affordances[1].handleAmbiguity ?? ""
    #expect(note.hasPrefix("ordinal:2 of 5 identical elements"), Comment(rawValue: note))
    #expect(note.contains("re-look before acting on it"))

    let rows = _array(object["affordances"]).map(_object)
    #expect(rows.allSatisfy { $0["handle_ambiguous"] == .bool(true) })
    #expect(object["ambiguous_handles"] == .int(5))
    guard case .string(let handlesNote)? = object["handles_note"] else {
        Issue.record("an ambiguous payload must say so ONCE, in prose")
        return
    }
    #expect(handlesNote.contains("position-derived"))

    // The frame carries it, so the act can echo it.
    let entries = MacLookFrame.entries(from: percept)
    #expect(entries.values.allSatisfy { $0.ambiguous })
}

@Test
func contentIdentity_neverAppliesToAControlWhoseValueIsItsLabel() {
    // Rule 2 stands: a popup button reading "Medium" then "Large" is ONE
    // control and must keep ONE handle. This is the case `contentName` must
    // never touch.
    func source(_ value: String) -> _LookSource {
        var elements: [Int: _LookElement] = [:]
        elements[2] = _LookElement(attributes: MacAXAttributes(role: "AXStaticText", value: value), children: [])
        elements[1] = _LookElement(
            attributes: MacAXAttributes(role: "AXPopUpButton", value: value, actions: ["AXPress"]),
            children: [2]
        )
        // …and a GROUP whose only content is that same changing value: it is
        // interactive and value-labeled, so it is excluded too.
        elements[3] = _LookElement(
            attributes: MacAXAttributes(role: "AXGroup", value: value, actions: ["AXPress"]),
            children: []
        )
        elements[0] = _LookElement(attributes: MacAXAttributes(role: "AXWindow", title: "Prefs"), children: [1, 3])
        return _LookSource(elements: elements, rootID: 0)
    }
    let before = _compile(source("Medium")).affordances.map(\.handle)
    let after = _compile(source("Large")).affordances.map(\.handle)
    #expect(!before.isEmpty)
    #expect(before == after, "a value change must not mint a new handle: \(before) vs \(after)")
}

@Test
func affordanceRanking_putsControlsAheadOfRowContent_withoutMovingAHandle() {
    // 8 file rows (each an enabled AXTextField — Finder's rename-in-place) and
    // ONE toolbar button, the button LAST in document order. With a cap of 2
    // the button must survive: burying the toolbar under filenames is exactly
    // what she reported.
    let source = _fileListSource(names: (0..<8).map { "file-\($0).txt" })
    let full = _compile(source)
    let capped = _compile(source, maxAffordances: 2)

    #expect(full.affordances.first?.label == "Share", "controls rank first: \(full.affordances.map(\.label))")
    #expect(capped.affordances.map(\.label).contains("Share"),
            "the cap must not eat the toolbar: \(capped.affordances.map(\.label))")
    #expect(capped.affordancesOmitted == 7)
    #expect(_object(full.lookJSON().json)["affordance_ranking"] == .string("controls_first"))

    // Within a tier document order is preserved.
    let rows = full.affordances.filter { $0.role == "AXTextField" }.map(\.label)
    #expect(rows == (0..<8).map { "file-\($0).txt" }, "\(rows)")

    // HANDLES ARE NOT RANKED. The handle pass runs over document order before
    // any of this, so ranking and capping can never move an identity.
    let byLabel = Dictionary(uniqueKeysWithValues: full.affordances.map { ($0.label, $0.handle) })
    for affordance in capped.affordances {
        #expect(byLabel[affordance.label] == affordance.handle,
                "\(affordance.label)'s handle moved when the list was ranked/capped")
    }
}

@Test
func aDotfileNameIsNotASecretValue_butARealTokenBesideItStillIs() {
    // She saw `labeled_secret_nearby` fire on ~4 dotfile names in her home
    // directory, and INCONSISTENTLY: `.claude.json.backup` visible, a sibling
    // redacted. The mechanism is a row named `.vscode` reading as a "code"
    // caption, which makes its neighbours "the value beside a secret label".
    #expect(MacScreenViewTextRedaction.looksLikeSecretLabel(".vscode"),
            "the caption test is unchanged — this is the input that starts it")
    #expect(MacScreenViewTextRedaction.isFilenameShapedToken(".claude.json.backup"))
    #expect(!MacScreenViewTextRedaction.isFilenameShapedToken("sk-live-9f2ab7c41de8905632aa77bd"))

    let percept = _compile(_fileListSource(
        names: [".vscode", ".claude.json.backup", "AKIA5ZQ7T2XKLM4NBVC"],
        frames: true
    ))
    let labels = percept.affordances.filter { $0.role == "AXTextField" }
    let dotfile = labels.first { $0.label == ".claude.json.backup" }
    #expect(dotfile?.displayLabel == ".claude.json.backup",
            "a filename is not a secret VALUE: \(String(describing: dotfile?.labelJSON))")

    // NEGATIVE CONTROL — the narrowing must not blind the redactor. A genuine
    // key-shaped token in the same list, beside the same caption, still goes
    // dark (here by its own shape, which is the point: nothing was loosened
    // for anything that is actually secret-shaped).
    let key = labels.first { $0.label.hasPrefix("AKIA") }
    #expect(key != nil)
    #expect(key?.displayLabel == nil, "a key-shaped filename-less token must still be redacted")
    let serialized = (try? percept.lookJSON().json.serializedData(pretty: false))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    #expect(!serialized.contains("AKIA5ZQ7T2XKLM4NBVC"), Comment(rawValue: serialized))
}

// MARK: - gpt-5.5 round-2 B4: the effect diff is a text channel too

/// The CVV form, one step later: the hidden field's value moved and the button
/// it sat beside is gone. `look` redacted that value at compile time; the ACT's
/// diff must not hand it back. Before this, `changed` / `affordances_removed` /
/// `acted_element` re-redacted the STORED string with no enclosing-caption
/// context, so the group titled "CVV" was invisible and `456` shipped clear.
@Test
func effectDiff_carriesTheCompilesRedaction_soAChangedSecretNeverShipsClear() {
    let before = _compile(_cvvFormSource())
    let frame = MacLookFrame.from(
        percept: before,
        frameId: "f1",
        capturedAt: Date(),
        windowTitle: "Checkout"
    )
    // The entry itself must be the carrier — a raw label/value stored with no
    // redaction beside it is exactly how the leak reopened.
    let cvvEntry = frame.entries.values.first { $0.role == "AXTextField" }
    #expect(cvvEntry != nil)
    #expect(cvvEntry?.secret == true, "the compile judged this value secret; the frame must remember that")
    #expect(cvvEntry?.valueJSON != nil || cvvEntry?.labelJSON != nil,
            "the entry must carry the compile's redacted text, not only the raw string")

    var elements = _cvvFormElements()
    elements[41] = _LookElement(
        attributes: MacAXAttributes(role: "AXTextField", value: "456",
                                    frame: MacAXFrame(x: 20, y: 40, w: 60, h: 24)),
        children: []
    )
    elements[30] = _LookElement(
        attributes: MacAXAttributes(role: "AXGroup", title: "CVV",
                                    frame: MacAXFrame(x: 0, y: 0, w: 300, h: 200)),
        children: [40, 41]           // "Pay now" is gone ⇒ a REMOVED row
    )
    let after = _compile(_LookSource(elements: elements, rootID: 0, focus: [0, 1]))
    let diff = MacActClosedLoop.diff(before: frame, after: after, afterWindowTitle: "Checkout")

    let rows = (diff.changed.map { $0.toJSON() } + diff.removed.map { entry in
        JSONValue.object([
            "handle": .string(entry.handle),
            "label": entry.labelJSON ?? entry.label.map { .string($0) } ?? .null,
        ])
    })
    let serialized = rows.compactMap { row -> String? in
        (try? row.serializedData(pretty: false)).flatMap { String(data: $0, encoding: .utf8) }
    }.joined(separator: " ")
    #expect(!serialized.contains("456"), "the NEW secret value rode out through the diff: \(serialized)")
    #expect(!serialized.contains("123"), "the OLD secret value rode out through the diff: \(serialized)")
    #expect(!diff.changed.isEmpty || !diff.removed.isEmpty,
            "negative control: if nothing diffed, this test proves nothing")
}
