import Foundation
import Testing
@testable import MacControl
import NativeAgentCore
import PersistenceCore

/// W3.5 — THE FUSED VIEW.
///
/// HERMETICITY / SAFETY: nothing here touches a window server, a display, a
/// TCC grant, the real mouse or the real keyboard. The AX tree is synthetic,
/// the screen capture is a stub, the renderer is a stub that reports SIZES
/// instead of pixels, and the injection paths run against the recording sink
/// and fake act source from `MacAccessibilityActuatorTests`. The production
/// `SystemMacScreenCaptureSource` and `CoreGraphicsMacScreenImageRenderer` are
/// never constructed — which is exactly why both are behind protocols.
///
/// WHAT A MACHINE CANNOT ASSERT HERE: that the marker lands on the button as
/// seen by a human eye. The geometry is pinned exactly (below), but the last
/// millimetre — that macOS handed us the pixels for the rect we asked for —
/// needs User's Screen Recording grant and one look. See `manualLiveViewNote`.

// MARK: - Fakes

private struct _StubCaptureSource: MacScreenCaptureSource {
    var trusted: Bool = true
    var shot: MacScreenShot?
    var failure: MacScreenCaptureFailure = .captureFailed
    /// The rect the client ASKED for — proves the capture is aimed at the
    /// window AX reported, not at a guess.
    final class Box: @unchecked Sendable { var requested: MacAXFrame??; init() {} }
    var box = Box()

    func isScreenRecordingTrusted() -> Bool { trusted }

    func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        box.requested = .some(rect)
        guard let shot else { return .failure(failure) }
        return .success(shot)
    }
}

/// Reports byte counts as a deterministic function of the downscale, so the
/// byte-budget ladder is testable with no image codec involved:
/// `bytes(rung) = baseBytes * rung²` (area scales with the square).
private struct _StubRenderer: MacScreenImageRenderer {
    var baseBytes: Int = 1_000_000
    final class Box: @unchecked Sendable {
        var calls: [(downscale: Double, placements: [MacScreenMarkerPlacement])] = []
        init() {}
    }
    var box = Box()

    func renderPNG(
        shot: MacScreenShot,
        placements: [MacScreenMarkerPlacement],
        downscale: Double
    ) -> Data? {
        box.calls.append((downscale, placements))
        let count = max(1, Int(Double(baseBytes) * downscale * downscale))
        return Data(repeating: 0x7f, count: count)
    }
}

private struct _NeverRenderer: MacScreenImageRenderer {
    func renderPNG(shot: MacScreenShot, placements: [MacScreenMarkerPlacement], downscale: Double) -> Data? {
        nil
    }
}

private final class _InterruptingDragSink: MacEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MacMouseEvent] = []
    private var interrupted = false
    let source: AttentionManualSource

    init(source: AttentionManualSource) { self.source = source }
    var isAvailable: Bool { true }
    var mouse: [MacMouseEvent] { lock.lock(); defer { lock.unlock() }; return events }
    func post(key: MacKeyEvent) {}
    func post(scroll: MacScrollEvent) {}
    func post(mouse event: MacMouseEvent) {
        lock.lock()
        events.append(event)
        let shouldInterrupt = event.phase == .drag && !interrupted
        if shouldInterrupt { interrupted = true }
        lock.unlock()
        if shouldInterrupt {
            source.emit(MacAttentionActivity(kind: .pointerPressed))
        }
    }
}

private struct _ViewElement {
    var attributes: MacAXAttributes?
    var children: [Int]
}

private final class _ViewAXSource: MacAXElementSource, @unchecked Sendable {
    private let elements: [Int: _ViewElement]
    private let rootID: Int?
    private let trusted: Bool
    private let app: MacAXAppInfo?

    init(
        elements: [Int: _ViewElement],
        rootID: Int? = 0,
        trusted: Bool = true,
        app: MacAXAppInfo? = MacAXAppInfo(
            name: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 4242
        )
    ) {
        self.elements = elements
        self.rootID = rootID
        self.trusted = trusted
        self.app = app
    }

    func isTrusted() -> Bool { trusted }
    func frontmostApp() -> MacAXAppInfo? { app }
    func frontmostWindowRoot() -> MacAXElementRef? { rootID.map { MacAXElementRef(id: $0) } }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? { elements[ref.id]?.attributes }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        (elements[ref.id]?.children ?? []).map { MacAXElementRef(id: $0) }
    }
}

/// A window at (100,200) 800x600 points containing, in this DOCUMENT order:
///   1 — a Send button, low-right           (frame 700,700 100x40)
///   2 — a static label, top-left           (unmarkable: no actions, not clickable)
///   3 — a password field, mid              (frame 200,400 300x30, secure)
///   4 — a Cancel button, low-LEFT          (frame 200,700 100x40)
/// Reading order therefore numbers the password field first, then Cancel
/// (left) before Send (right) — the two buttons share an 8-point row band.
private func _composeWindowSource() -> _ViewAXSource {
    _ViewAXSource(elements: [
        0: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXWindow",
                title: "Compose",
                frame: MacAXFrame(x: 100, y: 200, w: 800, h: 600),
                actions: []
            ),
            children: [1, 2, 3, 4]
        ),
        1: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                title: "Send",
                frame: MacAXFrame(x: 700, y: 700, w: 100, h: 40),
                actions: ["AXPress"]
            ),
            children: []
        ),
        2: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXStaticText",
                title: "To:",
                frame: MacAXFrame(x: 120, y: 220, w: 40, h: 20),
                actions: []
            ),
            children: []
        ),
        3: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                title: "Password",
                value: "hunter2-the-real-one",
                frame: MacAXFrame(x: 200, y: 400, w: 300, h: 30),
                actions: ["AXConfirm"]
            ),
            children: []
        ),
        4: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                title: "Cancel",
                frame: MacAXFrame(x: 200, y: 700, w: 100, h: 40),
                actions: ["AXPress"]
            ),
            children: []
        ),
    ])
}

private func _shot(
    x: Double = 100, y: Double = 200, w: Double = 800, h: Double = 600,
    pixelW: Int = 1600, pixelH: Int = 1200
) -> MacScreenShot {
    MacScreenShot(
        bounds: MacAXFrame(x: x, y: y, w: w, h: h),
        pixelWidth: pixelW,
        pixelHeight: pixelH
    )
}

private func _object(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let object) = value else { return [:] }
    return object
}

private func _string(_ output: JSONValue, _ key: String) -> String? {
    guard case .string(let s)? = _object(output)[key] else { return nil }
    return s
}

private func _int(_ output: JSONValue, _ key: String) -> Int? {
    guard case .int(let n)? = _object(output)[key] else { return nil }
    return Int(n)
}

private func _bool(_ output: JSONValue, _ key: String) -> Bool? {
    guard case .bool(let b)? = _object(output)[key] else { return nil }
    return b
}

private func _marks(_ output: JSONValue) -> [[String: JSONValue]] {
    guard case .array(let rows)? = _object(output)["marks"] else { return [] }
    return rows.map { _object($0) }
}

// MARK: - Geometry: AX points → image pixels, EXACTLY

@Test func geometryDerivesTheScaleFromTheImageThatCameBack() {
    // 800x600 points arrived as 1600x1200 pixels ⇒ 2.0, derived, not assumed.
    let geometry = MacScreenViewGeometry(shot: _shot())
    #expect(geometry.scaleX == 2.0)
    #expect(geometry.scaleY == 2.0)
    #expect(geometry.reportedScale == 2.0)

    // A 1x display: same rect, half the pixels.
    let oneX = MacScreenViewGeometry(shot: _shot(pixelW: 800, pixelH: 600))
    #expect(oneX.scaleX == 1.0)
    #expect(oneX.scaleY == 1.0)

    // Non-square effective scale is carried per-axis, not averaged away.
    let squashed = MacScreenViewGeometry(shot: _shot(pixelW: 1600, pixelH: 600))
    #expect(squashed.scaleX == 2.0)
    #expect(squashed.scaleY == 1.0)
    #expect(squashed.reportedScale == 1.0)
}

@Test func geometryTranslatesAnAXFrameToExactImagePixels() throws {
    let geometry = MacScreenViewGeometry(shot: _shot())   // origin (100,200), scale 2
    // The Send button at AX (700,700) 100x40 →
    //   x: (700-100)*2 = 1200, y: (700-200)*2 = 1000, w: 200, h: 80.
    let placement = try #require(
        geometry.placement(mark: 7, frame: MacAXFrame(x: 700, y: 700, w: 100, h: 40))
    )
    #expect(placement.mark == 7)
    #expect(placement.x == 1200)
    #expect(placement.y == 1000)
    #expect(placement.w == 200)
    #expect(placement.h == 80)

    // The window's own top-left corner maps to the image origin. This is the
    // assertion that fails first if the capture-origin subtraction is dropped.
    let corner = try #require(
        geometry.placement(mark: 1, frame: MacAXFrame(x: 100, y: 200, w: 10, h: 10))
    )
    #expect(corner.x == 0)
    #expect(corner.y == 0)
}

@Test func geometryClipsAPartlyOffscreenElementAndDropsAFullyOffscreenOne() throws {
    let geometry = MacScreenViewGeometry(shot: _shot())
    // Straddles the right edge (window spans x 100…900): half in, half out.
    let clipped = try #require(
        geometry.placement(mark: 1, frame: MacAXFrame(x: 850, y: 300, w: 100, h: 20))
    )
    #expect(clipped.x == 1500)
    #expect(clipped.w == 100, "only the 50 points inside the capture survive, at scale 2")
    // Entirely past the bottom edge (window spans y 200…800).
    #expect(geometry.placement(mark: 2, frame: MacAXFrame(x: 200, y: 900, w: 50, h: 50)) == nil)
    // A degenerate frame is not a location.
    #expect(geometry.placement(mark: 3, frame: MacAXFrame(x: 200, y: 300, w: 0, h: 10)) == nil)
}

@Test func geometryScale1ImageIsNotSecretlyScale2() {
    // Teeth for the "scale is derived, not assumed" claim: with the SAME AX
    // frame and the SAME window, a 1x capture must place the marker at half
    // the pixel offset of a 2x capture. A hardcoded 2.0 fails here.
    let retina = MacScreenViewGeometry(shot: _shot())
    let standard = MacScreenViewGeometry(shot: _shot(pixelW: 800, pixelH: 600))
    let frame = MacAXFrame(x: 500, y: 400, w: 100, h: 40)
    #expect(retina.placement(mark: 1, frame: frame)?.x == 800)
    #expect(standard.placement(mark: 1, frame: frame)?.x == 400)
}

// MARK: - Mark selection: what gets a number, in what order

@Test func onlyActionableOrScrollableElementsAreMarked() {
    #expect(MacScreenViewBuilder.isMarkable(MacAXAttributes(role: "AXButton")))
    #expect(MacScreenViewBuilder.isMarkable(MacAXAttributes(role: "AXScrollArea")))
    // No actions and no clickable role: decoration, no number.
    #expect(!MacScreenViewBuilder.isMarkable(MacAXAttributes(role: "AXStaticText")))
    #expect(!MacScreenViewBuilder.isMarkable(MacAXAttributes(role: "AXGroup")))
    // An odd role that nonetheless advertises a real AX action IS actionable.
    #expect(MacScreenViewBuilder.isMarkable(
        MacAXAttributes(role: "AXUnknown", actions: ["AXPress"])
    ))
}

@Test func marksAreNumberedInReadingOrderNotDocumentOrder() {
    let source = _composeWindowSource()
    let root = MacAXElementRef(id: 0)
    let snapshot = MacAccessibilityReader.walk(source: source, root: root)
    let selection = MacScreenViewBuilder.select(
        nodes: snapshot.nodes,
        geometry: MacScreenViewGeometry(shot: _shot())
    )
    let labels = selection.marks.map { $0.label ?? "?" }
    // Password (y=400) is above the button row (y=700); within that row Cancel
    // (x=200) precedes Send (x=700). Document order would have said Send first.
    #expect(labels == ["Password", "Cancel", "Send"])
    #expect(selection.marks.map(\.mark) == [1, 2, 3])
    #expect(!selection.truncated)
}

@Test func markCapTruncatesHonestly() {
    var elements: [Int: _ViewElement] = [:]
    var children: [Int] = []
    for i in 1...80 {
        elements[i] = _ViewElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                title: "b\(i)",
                frame: MacAXFrame(x: 100, y: Double(200 + i), w: 20, h: 8),
                actions: ["AXPress"]
            ),
            children: []
        )
        children.append(i)
    }
    elements[0] = _ViewElement(
        attributes: MacAXAttributes(
            role: "AXWindow",
            title: "Many",
            frame: MacAXFrame(x: 100, y: 200, w: 800, h: 600)
        ),
        children: children
    )
    let snapshot = MacAccessibilityReader.walk(
        source: _ViewAXSource(elements: elements),
        root: MacAXElementRef(id: 0)
    )
    let selection = MacScreenViewBuilder.select(
        nodes: snapshot.nodes,
        geometry: MacScreenViewGeometry(shot: _shot())
    )
    #expect(selection.marks.count == MacScreenViewBuilder.hardMaxMarks)
    #expect(selection.omitted == 20, "80 markable buttons − a 60 cap = 20 reported, not dropped")
    #expect(selection.truncated)

    // A caller may lower the cap but never raise it.
    let lowered = MacScreenViewBuilder.select(
        nodes: snapshot.nodes,
        geometry: MacScreenViewGeometry(shot: _shot()),
        maxMarks: 5
    )
    #expect(lowered.marks.count == 5)
    #expect(lowered.omitted == 75)
    let raised = MacScreenViewBuilder.select(
        nodes: snapshot.nodes,
        geometry: MacScreenViewGeometry(shot: _shot()),
        maxMarks: 5_000
    )
    #expect(raised.marks.count == MacScreenViewBuilder.hardMaxMarks)
}

@Test func offscreenElementsAreCountedNotSilentlyDropped() {
    let elements: [Int: _ViewElement] = [
        0: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXWindow", title: "W",
                frame: MacAXFrame(x: 100, y: 200, w: 800, h: 600)
            ),
            children: [1, 2]
        ),
        // Scrolled far below the window: markable, but not HERE.
        1: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXButton", title: "Below",
                frame: MacAXFrame(x: 200, y: 5_000, w: 60, h: 20),
                actions: ["AXPress"]
            ),
            children: []
        ),
        // Markable but frameless: nowhere to draw, nowhere to click.
        2: _ViewElement(
            attributes: MacAXAttributes(role: "AXButton", title: "Ghost", actions: ["AXPress"]),
            children: []
        ),
    ]
    let snapshot = MacAccessibilityReader.walk(
        source: _ViewAXSource(elements: elements),
        root: MacAXElementRef(id: 0)
    )
    let selection = MacScreenViewBuilder.select(
        nodes: snapshot.nodes,
        geometry: MacScreenViewGeometry(shot: _shot())
    )
    #expect(selection.marks.isEmpty)
    #expect(selection.offscreen == 2)
}

// MARK: - The effortless-vision bar: the legend has to stand alone

/// User's acceptance bar (2026-08-12): she must be able to act correctly from
/// the LEGEND ALONE, because structured text is the channel an LLM reads
/// losslessly. An unlabeled control fails that bar — so a control the app never
/// titled takes its name from the text a human would read it by.
@Test func anUnlabelledControlTakesItsNameFromTheTextBesideIt() {
    let elements: [Int: _ViewElement] = [
        0: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXWindow", title: "Settings",
                frame: MacAXFrame(x: 0, y: 0, w: 600, h: 400)
            ),
            children: [1, 2, 3, 4, 5]
        ),
        // A caption and the untitled field it names, same row.
        1: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXStaticText", title: "Server address",
                frame: MacAXFrame(x: 20, y: 100, w: 120, h: 20)
            ),
            children: []
        ),
        2: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXTextField",
                frame: MacAXFrame(x: 160, y: 100, w: 200, h: 20),
                actions: ["AXConfirm"]
            ),
            children: []
        ),
        // A heading directly above an untitled button.
        3: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXStaticText", title: "Danger zone",
                frame: MacAXFrame(x: 20, y: 200, w: 120, h: 20)
            ),
            children: []
        ),
        4: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                frame: MacAXFrame(x: 20, y: 230, w: 80, h: 24),
                actions: ["AXPress"]
            ),
            children: []
        ),
        // A popup button whose meaning is its own value.
        5: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXPopUpButton", value: "Every hour",
                frame: MacAXFrame(x: 400, y: 300, w: 120, h: 24),
                actions: ["AXPress"]
            ),
            children: []
        ),
    ]
    let snapshot = MacAccessibilityReader.walk(
        source: _ViewAXSource(elements: elements), root: MacAXElementRef(id: 0)
    )
    let selection = MacScreenViewBuilder.select(
        nodes: snapshot.nodes,
        geometry: MacScreenViewGeometry(
            bounds: MacAXFrame(x: 0, y: 0, w: 600, h: 400), pixelWidth: 600, pixelHeight: 400
        )
    )
    let byRole = Dictionary(grouping: selection.marks, by: \.role)
    let field = try? #require(byRole["AXTextField"]?.first)
    #expect(field?.label == "Server address")
    #expect(field?.labelSource == "nearby_text")
    let button = try? #require(byRole["AXButton"]?.first)
    #expect(button?.label == "Danger zone", "the heading directly above names the button")
    #expect(button?.labelSource == "nearby_text")
    let popup = try? #require(byRole["AXPopUpButton"]?.first)
    #expect(popup?.label == "Every hour")
    #expect(popup?.labelSource == "value")
    // And an inference is always DECLARED as one, never presented as a title.
    let encoded = try? String(
        data: (field?.toJSON() ?? .null).serializedData(pretty: false), encoding: .utf8
    )
    #expect(encoded?.contains("label_source") == true && encoded?.contains("nearby_text") == true)
}

@Test func labelInferenceRefusesToReachAcrossTheScreen() {
    // Text 400 points away is not this control's label. Guessing one would be
    // worse than admitting there is none: a confident wrong name is how the
    // wrong button gets pressed.
    let elements: [Int: _ViewElement] = [
        0: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXWindow", title: "W", frame: MacAXFrame(x: 0, y: 0, w: 900, h: 400)
            ),
            children: [1, 2]
        ),
        1: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXStaticText", title: "Far away",
                frame: MacAXFrame(x: 0, y: 100, w: 60, h: 20)
            ),
            children: []
        ),
        2: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                frame: MacAXFrame(x: 800, y: 100, w: 60, h: 20),
                actions: ["AXPress"]
            ),
            children: []
        ),
    ]
    let snapshot = MacAccessibilityReader.walk(
        source: _ViewAXSource(elements: elements), root: MacAXElementRef(id: 0)
    )
    let selection = MacScreenViewBuilder.select(
        nodes: snapshot.nodes,
        geometry: MacScreenViewGeometry(
            bounds: MacAXFrame(x: 0, y: 0, w: 900, h: 400), pixelWidth: 900, pixelHeight: 400
        )
    )
    let button = selection.marks.first { $0.role == "AXButton" }
    #expect(button?.label == nil)
    #expect(button?.labelSource == "none")
    guard case .object(let row)? = button?.toJSON() else { Issue.record("no row"); return }
    #expect(row["label_source"] == .string("none"), "an unnamed control says so out loud")
}

@Test func theViewCarriesWhatTheWindowSaysNotJustWhatItOffers() async throws {
    let elements: [Int: _ViewElement] = [
        0: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXWindow", title: "Alert", frame: MacAXFrame(x: 0, y: 0, w: 400, h: 300)
            ),
            children: [1, 2, 3]
        ),
        1: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXStaticText", title: "Delete 3 items?",
                frame: MacAXFrame(x: 20, y: 40, w: 300, h: 24)
            ),
            children: []
        ),
        2: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXStaticText", title: "This cannot be undone.",
                frame: MacAXFrame(x: 20, y: 80, w: 300, h: 20)
            ),
            children: []
        ),
        3: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXButton", title: "Delete",
                frame: MacAXFrame(x: 300, y: 240, w: 80, h: 24),
                actions: ["AXPress"]
            ),
            children: []
        ),
    ]
    // No image at all — the legend must still answer "what is on screen".
    let result = try await _client(
        ax: _ViewAXSource(elements: elements),
        capture: _StubCaptureSource(trusted: false, shot: nil, failure: .screenRecordingNotTrusted),
        renderer: _NeverRenderer(),
        store: MacScreenViewStore()
    ).dispatch(action: "view", body: [:])

    guard case .array(let rows)? = _object(result.output)["text"] else {
        Issue.record("no text channel"); return
    }
    let lines = rows.compactMap { row -> String? in
        guard case .object(let obj) = row, case .string(let t)? = obj["text"] else { return nil }
        return t
    }
    // In reading order, and complete enough to decide WITHOUT the picture.
    #expect(lines == ["Delete 3 items?", "This cannot be undone."])
    #expect(_marks(result.output).count == 1, "the button is a mark, the prose is text")
    #expect(_string(result.output, "how_to_read")?.contains("backdrop") == true)
}

@Test func theTextChannelIsCappedAndSaysSo() {
    var elements: [Int: _ViewElement] = [:]
    var children: [Int] = []
    for i in 1...100 {
        elements[i] = _ViewElement(
            attributes: MacAXAttributes(
                role: "AXStaticText", title: "line \(i)",
                frame: MacAXFrame(x: 10, y: Double(i * 9), w: 100, h: 8)
            ),
            children: []
        )
        children.append(i)
    }
    elements[0] = _ViewElement(
        attributes: MacAXAttributes(
            role: "AXWindow", title: "Doc", frame: MacAXFrame(x: 0, y: 0, w: 400, h: 1000)
        ),
        children: children
    )
    let snapshot = MacAccessibilityReader.walk(
        source: _ViewAXSource(elements: elements), root: MacAXElementRef(id: 0)
    )
    let text = MacScreenViewBuilder.visibleText(
        nodes: snapshot.nodes,
        geometry: MacScreenViewGeometry(
            bounds: MacAXFrame(x: 0, y: 0, w: 400, h: 1000), pixelWidth: 400, pixelHeight: 1000
        )
    )
    #expect(text.items.count == MacScreenViewBuilder.hardMaxTextItems)
    #expect(text.omitted == 20)
    let lowered = MacScreenViewBuilder.visibleText(
        nodes: snapshot.nodes,
        geometry: MacScreenViewGeometry(
            bounds: MacAXFrame(x: 0, y: 0, w: 400, h: 1000), pixelWidth: 400, pixelHeight: 1000
        ),
        limit: 5
    )
    #expect(lowered.items.count == 5)
    #expect(lowered.omitted == 95)
    #expect(lowered.items.first?.text == "line 1", "reading order, not arbitrary order")
}

// MARK: - Byte budget

@Test func imageBudgetTakesTheFirstRungThatFits() throws {
    // bytes(rung) = 1_000_000 · rung². Cap 300_000 ⇒ 1.0 (1M) and 0.75 (562k)
    // are too big, 0.5 (250k) fits.
    var seen: [Double] = []
    let fitted = try #require(MacScreenViewBuilder.fitImage(maxBytes: 300_000) { rung in
        seen.append(rung)
        return Data(repeating: 0, count: Int(1_000_000 * rung * rung))
    })
    #expect(fitted.downscale == 0.5)
    #expect(fitted.data.count == 250_000)
    #expect(seen == [1.0, 0.75, 0.5], "the ladder is walked in order and stops at the first fit")
}

@Test func imageBudgetGivesUpHonestlyWhenNoRungFits() {
    // Nothing on the ladder fits a 10-byte cap: nil, so the caller reports
    // image_exceeds_byte_cap instead of shipping something oversized.
    let fitted = MacScreenViewBuilder.fitImage(maxBytes: 10) { rung in
        Data(repeating: 0, count: Int(1_000_000 * rung * rung))
    }
    #expect(fitted == nil)
}

// MARK: - Secret fields

@Test func secureFieldsAreDetectedByMarkerAndByLabel() {
    #expect(MacScreenViewBuilder.isSecretField(role: "AXSecureTextField", subrole: nil, label: nil))
    #expect(MacScreenViewBuilder.isSecretField(role: "AXTextField", subrole: "AXSecureTextField", label: "x"))
    #expect(MacScreenViewBuilder.isSecretField(role: "AXTextField", subrole: nil, label: "Master Password"))
    #expect(MacScreenViewBuilder.isSecretField(role: "AXTextField", subrole: nil, label: "API key"))
    #expect(!MacScreenViewBuilder.isSecretField(role: "AXTextField", subrole: nil, label: "Subject"))
}

@Test func aSecretFieldValueNeverRidesOutInTheLegend() throws {
    let secret = "hunter2-the-real-one"
    let mark = MacScreenViewMark(
        mark: 1,
        role: "AXTextField",
        subrole: "AXSecureTextField",
        label: "Password",
        value: secret,
        secret: true,
        frame: MacAXFrame(x: 0, y: 0, w: 10, h: 10),
        path: [3]
    )
    let json = mark.toJSON()
    let encoded = try String(data: json.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!encoded.contains(secret), "a password must never appear in a legend row")
    #expect(encoded.contains("\"redacted\""))
    #expect(encoded.contains("\"character_count\""))
    // A NON-secret value is still readable — teeth: the redaction is targeted,
    // not a blanket that would make the legend useless.
    let plain = MacScreenViewMark(
        mark: 2, role: "AXTextField", label: "Subject", value: "Dinner at 8",
        secret: false, frame: MacAXFrame(x: 0, y: 0, w: 10, h: 10), path: [1]
    )
    let plainEncoded = try String(data: plain.toJSON().serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(plainEncoded.contains("Dinner at 8"))
}

// MARK: - The view store: staleness

@Test func viewStoreResolvesOnlyTheLatestViewWithinItsTTL() async {
    let store = MacScreenViewStore()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let mark = MacScreenViewMark(
        mark: 2, role: "AXButton", label: "Send",
        frame: MacAXFrame(x: 700, y: 700, w: 100, h: 40), path: [1]
    )
    func snapshot(_ id: String, at when: Date) -> MacScreenViewSnapshot {
        MacScreenViewSnapshot(
            viewId: id, capturedAt: when, scope: .focusedWindow,
            bounds: MacAXFrame(x: 100, y: 200, w: 800, h: 600),
            appName: "TextEdit", windowTitle: "Compose", marks: [mark]
        )
    }
    // Nothing recorded yet.
    #expect(await store.resolve(viewId: "v1", mark: 2, now: t0).failure == .noView)

    await store.record(snapshot("v1", at: t0))
    #expect(await store.resolve(viewId: "v1", mark: 2, now: t0).value?.label == "Send")
    #expect(await store.resolve(viewId: "v1", mark: 99, now: t0).failure == .unknownMark)
    // Past the TTL the numbers no longer describe the screen.
    #expect(await store.resolve(
        viewId: "v1", mark: 2,
        now: t0.addingTimeInterval(MacScreenViewStore.ttlSeconds + 1)
    ).failure == .viewExpired)
    #expect(await store.resolve(
        viewId: "v1", mark: 2,
        now: t0.addingTimeInterval(MacScreenViewStore.ttlSeconds - 1)
    ).value?.label == "Send")

    // A SECOND view retires the first: the old token is stale, not merely old.
    await store.record(snapshot("v2", at: t0))
    #expect(await store.resolve(viewId: "v1", mark: 2, now: t0).failure == .staleView)
    #expect(await store.resolve(viewId: "v2", mark: 2, now: t0).value?.label == "Send")
    // A token that was never issued is stale too — never a silent match.
    #expect(await store.resolve(viewId: "never-issued", mark: 2, now: t0).failure == .staleView)
}

private extension Result where Success == MacScreenViewMark, Failure == MacScreenViewStore.ResolveFailure {
    var value: MacScreenViewMark? { try? get() }
    var failure: MacScreenViewStore.ResolveFailure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}

// MARK: - The tool end to end (through the real dispatch)

private func _client(
    ax: _ViewAXSource,
    capture: _StubCaptureSource,
    renderer: any MacScreenImageRenderer,
    store: MacScreenViewStore,
    sink: _RecordingEventSink = _RecordingEventSink(),
    act: _FakeAXActSource = _FakeAXActSource(root: nil)
) -> SwiftNativeMacControl {
    SwiftNativeMacControl(
        accessibilitySource: ax,
        eventSink: sink,
        accessibilityActSource: act,
        screenCaptureSource: capture,
        screenImageRenderer: renderer,
        screenViewStore: store
    )
}

@Test func viewFusesThePictureAndTheStructureIntoOneObject() async throws {
    let capture = _StubCaptureSource(shot: _shot())
    let renderer = _StubRenderer(baseBytes: 100_000)
    let store = MacScreenViewStore()
    let client = _client(ax: _composeWindowSource(), capture: capture, renderer: renderer, store: store)

    let result = try await client.dispatch(action: "view", body: [:])
    #expect(result.ok)
    #expect(_bool(result.output, "accessibility_trusted") == true)
    #expect(_bool(result.output, "screen_recording_trusted") == true)
    #expect(_string(result.output, "window_title") == "Compose")

    // The capture was aimed at the AX window rect, not at a guess or the display.
    #expect(capture.box.requested??.x == 100)
    #expect(capture.box.requested??.w == 800)

    // Legend + picture in ONE result.
    let marks = _marks(result.output)
    #expect(marks.count == 3)
    #expect(_int(result.output, "mark_count") == 3)
    #expect(_string(result.output, "image") != nil)
    #expect(_int(result.output, "image_bytes") == 100_000)
    #expect(_string(result.output, "view")?.isEmpty == false)
    #expect(_bool(result.output, "truncated") == false)
    guard case .double(let scale)? = _object(result.output)["scale"] else {
        Issue.record("scale missing"); return
    }
    #expect(scale == 2.0)

    // The markers the renderer was handed are in IMAGE pixels, and mark 3
    // (Send) sits where the geometry says it does.
    let placements = try #require(renderer.box.calls.first?.placements)
    #expect(placements.count == 3)
    let send = try #require(placements.first { $0.mark == 3 })
    #expect(send.x == 1200 && send.y == 1000 && send.w == 200 && send.h == 80)
}

@Test func attentionRunsTheIntegratedObserveYieldReobserveActCycle() async throws {
    let capture = _StubCaptureSource(shot: _shot())
    let renderer = _StubRenderer(baseBytes: 100_000)
    let viewStore = MacScreenViewStore()
    let attentionStore = MacAttentionSessionStore(screenViewStore: viewStore)
    let attentionSource = AttentionManualSource()
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: _composeWindowSource(),
        eventSink: sink,
        screenCaptureSource: capture,
        screenImageRenderer: renderer,
        screenViewStore: viewStore,
        attentionEventSource: attentionSource,
        attentionStore: attentionStore
    )

    let started = try await client.dispatch(action: "attention", body: [
        "mode": .string("start"),
        "duration_seconds": .int(60),
    ])
    #expect(started.ok)
    #expect(started.action == "attention")
    let startedObject = _object(started.output)
    guard case .object(let attention)? = startedObject["attention"],
          case .string(let session)? = attention["session"],
          case .int(let initialUserSequence)? = attention["user_sequence"],
          case .string(let staleView)? = startedObject["view"] else {
        Issue.record("start did not return one fused view plus attention token")
        return
    }
    #expect(initialUserSequence == 0)

    // A real physical-input pulse retires the exact view the model just saw.
    attentionSource.emit(MacAttentionActivity(kind: .pointerPressed))
    _ = try #require(await waitForUserSequence(1, store: attentionStore))
    let yielded = try await client.dispatch(action: "click", body: [
        "mark": .int(1),
        "view": .string(staleView),
        "attention_session": .string(session),
        "attention_user_sequence": .int(initialUserSequence),
    ])
    #expect(!yielded.ok)
    #expect(yielded.httpStatus == 409)
    #expect(_string(yielded.output, "status") == "yielded_to_user")
    #expect(sink.mouse.isEmpty)

    // Re-observation produces a new scene token and acknowledges only the
    // user activity that happened before that capture.
    let refreshed = try await client.dispatch(action: "attention", body: [
        "mode": .string("next"),
        "session": .string(session),
        "after_sequence": .int(0),
        "wait_ms": .int(0),
    ])
    #expect(refreshed.ok)
    let refreshedObject = _object(refreshed.output)
    guard case .object(let refreshedAttention)? = refreshedObject["attention"],
          case .int(let refreshedUserSequence)? = refreshedAttention["user_sequence"],
          case .string(let freshView)? = refreshedObject["view"] else {
        Issue.record("next did not return a fresh fused view plus attention token")
        return
    }
    #expect(refreshedUserSequence == 1)
    #expect(freshView != staleView)

    let acted = try await client.dispatch(action: "click", body: [
        "mark": .int(1),
        "view": .string(freshView),
        "attention_session": .string(session),
        "attention_user_sequence": .int(refreshedUserSequence),
    ])
    #expect(acted.ok)
    #expect(sink.mouse.map(\.phase) == [MacMousePhase.move, .down, .up])
    // Motor completion retires the acted-on scene even without human input.
    #expect(await viewStore.latestViewId() == nil)

    let stopped = try await client.dispatch(action: "attention", body: ["mode": .string("stop")])
    #expect(stopped.ok)
    #expect(_string(stopped.output, "status") == "stopped")
    #expect(attentionSource.observation.isStopped)
}

@Test func humanTakeoverMidDragReleasesTheButtonAndStopsTheGesture() async throws {
    let capture = _StubCaptureSource(shot: _shot())
    let renderer = _StubRenderer(baseBytes: 100_000)
    let viewStore = MacScreenViewStore()
    let attentionStore = MacAttentionSessionStore(screenViewStore: viewStore)
    let attentionSource = AttentionManualSource()
    let sink = _InterruptingDragSink(source: attentionSource)
    let client = SwiftNativeMacControl(
        accessibilitySource: _composeWindowSource(),
        eventSink: sink,
        screenCaptureSource: capture,
        screenImageRenderer: renderer,
        screenViewStore: viewStore,
        attentionEventSource: attentionSource,
        attentionStore: attentionStore
    )
    let started = try await client.dispatch(action: "attention", body: [
        "mode": .string("start"),
        "duration_seconds": .int(60),
    ])
    let startedObject = _object(started.output)
    guard case .object(let attention)? = startedObject["attention"],
          case .string(let session)? = attention["session"],
          case .int(let userSequence)? = attention["user_sequence"] else {
        Issue.record("missing attention token")
        return
    }

    let result = try await client.dispatch(action: "click", body: [
        "from": .object(["x": .int(10), "y": .int(20)]),
        "to": .object(["x": .int(500), "y": .int(300)]),
        "duration_ms": .int(500),
        "attention_session": .string(session),
        "attention_user_sequence": .int(userSequence),
    ])
    #expect(!result.ok)
    #expect(_string(result.output, "status") == "yielded_to_user")
    let events = sink.mouse
    #expect(events.prefix(2).map(\.phase) == [.move, .down])
    #expect(events.contains { $0.phase == .drag })
    #expect(events.last?.phase == .up, "takeover must never strand a synthesized button-down")
    #expect(events.count < 34, "the local drag path must stop rather than finishing after takeover")
}

@Test func appChangeRefusalAsksForARefreshWithoutClaimingHumanTakeover() async throws {
    let viewStore = MacScreenViewStore()
    let attentionStore = MacAttentionSessionStore(screenViewStore: viewStore)
    let attentionSource = AttentionManualSource()
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: _composeWindowSource(),
        eventSink: sink,
        screenCaptureSource: _StubCaptureSource(shot: _shot()),
        screenImageRenderer: _StubRenderer(baseBytes: 100_000),
        screenViewStore: viewStore,
        attentionEventSource: attentionSource,
        attentionStore: attentionStore
    )
    let started = try await client.dispatch(action: "attention", body: [
        "mode": .string("start"),
        "duration_seconds": .int(60),
    ])
    let startedObject = _object(started.output)
    guard case .object(let attention)? = startedObject["attention"],
          case .string(let session)? = attention["session"],
          case .int(let userSequence)? = attention["user_sequence"],
          case .string(let view)? = startedObject["view"] else {
        Issue.record("missing attention token")
        return
    }

    attentionSource.emit(MacAttentionActivity(kind: .appChanged))
    _ = try #require(await attentionStore.waitForActivity(
        sessionId: session,
        after: 0,
        timeoutMilliseconds: 2_000,
        now: Date()
    ))
    let refused = try await client.dispatch(action: "click", body: [
        "mark": .int(1),
        "view": .string(view),
        "attention_session": .string(session),
        "attention_user_sequence": .int(userSequence),
    ])
    #expect(!refused.ok)
    #expect(_string(refused.output, "status") == "refresh_required")
    #expect(refused.error?.contains("scene_changed") == true)
    #expect(refused.error?.contains("human_takeover") == false)
    #expect(sink.mouse.isEmpty)

    _ = try await client.dispatch(action: "attention", body: ["mode": .string("stop")])
}

@Test func cancellingAnAttentionWaitReturnsPromptlyWithoutCapturingAnotherView() async throws {
    let capture = _StubCaptureSource(shot: _shot())
    let renderer = _StubRenderer(baseBytes: 100_000)
    let viewStore = MacScreenViewStore()
    let attentionStore = MacAttentionSessionStore(screenViewStore: viewStore)
    let attentionSource = AttentionManualSource()
    let client = SwiftNativeMacControl(
        accessibilitySource: _composeWindowSource(),
        eventSink: _RecordingEventSink(),
        screenCaptureSource: capture,
        screenImageRenderer: renderer,
        screenViewStore: viewStore,
        attentionEventSource: attentionSource,
        attentionStore: attentionStore
    )
    let started = try await client.dispatch(action: "attention", body: [
        "mode": .string("start"),
        "duration_seconds": .int(60),
    ])
    guard case .object(let attention)? = _object(started.output)["attention"],
          case .string(let session)? = attention["session"],
          case .int(let sequence)? = attention["sequence"] else {
        Issue.record("missing attention token")
        return
    }
    let initialRenderCount = renderer.box.calls.count
    #expect(initialRenderCount == 1)

    let waiting = Task {
        try await client.dispatch(action: "attention", body: [
            "mode": .string("next"),
            "session": .string(session),
            "after_sequence": .int(sequence),
            "wait_ms": .int(15_000),
        ])
    }
    try await Task.sleep(for: .milliseconds(10))
    waiting.cancel()
    let cancelled = try await waiting.value
    #expect(!cancelled.ok)
    #expect(cancelled.httpStatus == 499)
    #expect(cancelled.error == "attention_wait_cancelled")
    #expect(
        renderer.box.calls.count == initialRenderCount,
        "a cancelled wait must not take another screenshot"
    )

    _ = try await client.dispatch(action: "attention", body: ["mode": .string("stop")])
}

@Test func viewLegendTiesEachMarkToTheRealElementPath() async throws {
    let store = MacScreenViewStore()
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: store
    )
    let result = try await client.dispatch(action: "view", body: [:])
    let marks = _marks(result.output)
    // Mark 3 is Send, whose child-index path in the synthetic tree is [0] —
    // Send is the FIRST child of the window even though it is numbered last.
    // That divergence is the point: the number is a reading-order label, the
    // path is the real address, and the legend must carry both correctly.
    guard case .array(let path)? = marks[2]["path"] else { Issue.record("no path"); return }
    #expect(path == [.int(0)])
    #expect(marks[2]["label"] == .string("Send"))
    // Mark 2 is Cancel, path [3].
    guard case .array(let cancelPath)? = marks[1]["path"] else { Issue.record("no path"); return }
    #expect(cancelPath == [.int(3)])
    #expect(marks[1]["label"] == .string("Cancel"))
}

@Test func viewRedactsASecureFieldValueInTheLegend() async throws {
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: MacScreenViewStore()
    )
    let result = try await client.dispatch(action: "view", body: [:])
    let encoded = try String(data: result.output.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!encoded.contains("hunter2-the-real-one"),
            "the password field's value must never ride out in the fused view")
    #expect(_marks(result.output)[0]["secret_field"] == .bool(true))
}

@Test func viewReportsMissingScreenRecordingWithoutLosingTheLegend() async throws {
    let capture = _StubCaptureSource(trusted: false, shot: nil, failure: .screenRecordingNotTrusted)
    let result = try await _client(
        ax: _composeWindowSource(),
        capture: capture,
        renderer: _StubRenderer(),
        store: MacScreenViewStore()
    ).dispatch(action: "view", body: [:])

    // Honest, not opaque, and NOT a crash or a hard failure.
    #expect(result.ok, "the AX legend is still real perception")
    #expect(_bool(result.output, "screen_recording_trusted") == false)
    #expect(_bool(result.output, "accessibility_trusted") == true)
    #expect(_string(result.output, "image_unavailable_reason") == "screen_recording_not_trusted")
    #expect(_object(result.output)["image"] == JSONValue.null)
    #expect(_string(result.output, "screen_recording_note")?.contains("Screen Recording") == true)
    // The numbers still work — she can still act by name with no picture.
    #expect(_int(result.output, "mark_count") == 3)
    #expect(_bool(result.output, "truncated") == true, "a missing picture is reported as truncation")
}

@Test func viewReportsMissingAccessibilityWithoutLosingThePicture() async throws {
    let untrusted = _ViewAXSource(elements: [:], rootID: nil, trusted: false)
    let result = try await _client(
        ax: untrusted,
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: MacScreenViewStore()
    ).dispatch(action: "view", body: [:])
    #expect(result.ok, "pixels with no marks is the canvas/game/video fallback")
    #expect(_bool(result.output, "accessibility_trusted") == false)
    #expect(_int(result.output, "mark_count") == 0)
    #expect(_string(result.output, "image") != nil)
    #expect(_string(result.output, "accessibility_note")?.contains("Accessibility") == true)
}

@Test func viewReportsTheImageByteCapRatherThanShippingAnOversizedTurn() async throws {
    let result = try await _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        // Every rung of the ladder is over a 1000-byte cap.
        renderer: _StubRenderer(baseBytes: 10_000_000),
        store: MacScreenViewStore()
    ).dispatch(action: "view", body: ["max_image_bytes": .int(1_000)])
    #expect(_object(result.output)["image"] == JSONValue.null)
    #expect(_string(result.output, "image_unavailable_reason") == "image_exceeds_byte_cap")
    #expect(_int(result.output, "max_image_bytes") == 1_000)
    #expect(_int(result.output, "mark_count") == 3, "the legend survives a picture that will not fit")
}

@Test func viewImageByteCapCannotBeRaisedAboveTheHardCeiling() async throws {
    let result = try await _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: MacScreenViewStore()
    ).dispatch(action: "view", body: ["max_image_bytes": .int(99_000_000)])
    #expect(_int(result.output, "max_image_bytes") == MacScreenViewBuilder.hardMaxImageBytes)
}

@Test func viewFullScreenScopeCapturesTheWholeDisplay() async throws {
    let capture = _StubCaptureSource(shot: _shot(x: 0, y: 0, w: 1440, h: 900, pixelW: 2880, pixelH: 1800))
    let result = try await _client(
        ax: _composeWindowSource(),
        capture: capture,
        renderer: _StubRenderer(baseBytes: 1_000),
        store: MacScreenViewStore()
    ).dispatch(action: "view", body: ["full_screen": .bool(true)])
    #expect(_string(result.output, "scope") == "full_screen")
    // nil rect ⇒ "the whole display", decided by the capture source.
    #expect(capture.box.requested == .some(nil))
}

@Test func viewIsReadOnlyAndEmitsNothing() async throws {
    let sink = _RecordingEventSink()
    let act = _FakeAXActSource(root: nil)
    _ = try await _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: MacScreenViewStore(),
        sink: sink,
        act: act
    ).dispatch(action: "view", body: [:])
    #expect(sink.keys.isEmpty && sink.mouse.isEmpty && sink.scrolls.isEmpty,
            "looking is not acting")
    #expect(act.attempted.isEmpty)
}

@Test func viewIsDispatchableAtReadTierUnderTheAccessibilityCategory() {
    #expect(macControlAccessibilityReadActions.contains("view"))
    #expect(macControlDispatchableActions.contains("view"))
    #expect(macControlGateCategory(forAction: "view") == "accessibility")
    // The line that matters: a view is NOT injection. If it ever lands in that
    // set it would demand an approval capability — and, worse, would mean the
    // organ had grown a way to act.
    #expect(!macControlAccessibilityInjectionActions.contains("view"))
    // It has no retired-daemon ancestor, so it stays out of the parity inventory.
    #expect(!macControlAllActions.contains("view"))
}

// MARK: - mark → act: the reference resolves, the gates do not move

/// The W3.5 claim in one test: `mac_click{mark:…}` is still an INJECTION call
/// and a mark buys exactly no extra authority — it resolves to the element's
/// real centre and takes the same path a coordinate click takes.
///
/// YOLO cutover 2026-08-12 (9023d24d, 84fb8201): perimeter gates entry,
/// execution ungated. OLD CONTRACT: the unprivileged public `dispatch` refused
/// a mark click by SIGNATURE (403 / `approval_not_granted`) and emitted no
/// event. NEW CONTRACT: that entry point self-mints a capability, so the mark
/// click executes — with the SAME event sequence a coordinate click produces,
/// which is the "a mark buys no extra authority" half that still holds.
@Test func clickByMarkExecutesOnASelfMintedCapability() async throws {
    let store = MacScreenViewStore()
    let sink = _RecordingEventSink()
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: store,
        sink: sink
    )
    let view = try await client.dispatch(action: "view", body: [:])
    let viewId = try #require(_string(view.output, "view"))

    let clicked = try await client.dispatch(
        action: "click",
        body: ["mark": .int(3), "view": .string(viewId)]
    )
    #expect(clicked.ok)
    #expect(clicked.error?.contains("approval_not_granted") != true,
            "the approval tier is retired: \(clicked.error ?? "nil")")
    #expect(_string(clicked.output, "targeted_by") == "mark")
    #expect(sink.mouse.map(\.phase) == [.move, .down, .up],
            "a mark click emits exactly the coordinate-click sequence")

    // Same for the semantic form.
    let acted = try await client.dispatch(
        action: "ax_act",
        body: ["mark": .int(3), "view": .string(viewId)]
    )
    #expect(acted.error?.contains("approval_not_granted") != true)
}

@Test func clickByMarkResolvesToTheElementsRealCentreOnceApproved() async throws {
    let store = MacScreenViewStore()
    let sink = _RecordingEventSink()
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: store,
        sink: sink,
        act: _FakeAXActSource(root: _FakeAXActNode(role: "AXWindow"))
    )
    let view = try await client.dispatch(action: "view", body: [:])
    let viewId = try #require(_string(view.output, "view"))
    let body: [String: JSONValue] = ["mark": .int(3), "view": .string(viewId)]

    let capability = try #require(MacInjectionCapability.mint(approvalID: "approval-body", action: "click", body: body))
    let result = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: capability
    )
    #expect(result.ok)
    #expect(_string(result.output, "targeted_by") == "mark")
    // Mark 3 is Send: AX frame (700,700) 100x40 ⇒ centre (750, 720). The model
    // supplied NO coordinate; this number came from the captured AX frame.
    guard case .double(let x)? = _object(result.output)["x"],
          case .double(let y)? = _object(result.output)["y"] else {
        Issue.record("no resolved point"); return
    }
    #expect(x == 750 && y == 720)
    let down = try #require(sink.mouse.first { $0.phase == .down })
    #expect(down.x == 750 && down.y == 720)
}

@Test func axActByMarkTargetsThePathTheLegendNamed() async throws {
    // The act tree mirrors the perception tree: child 0 is Send.
    let sendNode = _FakeAXActNode(
        role: "AXButton", title: "Send",
        frame: MacAXFrame(x: 700, y: 700, w: 100, h: 40), actions: ["AXPress"]
    )
    let cancelNode = _FakeAXActNode(
        role: "AXButton", title: "Cancel",
        frame: MacAXFrame(x: 200, y: 700, w: 100, h: 40), actions: ["AXPress"]
    )
    let act = _FakeAXActSource(root: _FakeAXActNode(
        role: "AXWindow", title: "Compose",
        children: [
            sendNode,
            _FakeAXActNode(role: "AXStaticText", title: "To:"),
            _FakeAXActNode(role: "AXTextField", title: "Password", settable: true),
            cancelNode,
        ]
    ))
    let store = MacScreenViewStore()
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: store,
        act: act
    )
    let view = try await client.dispatch(action: "view", body: [:])
    let viewId = try #require(_string(view.output, "view"))
    // Mark 2 is CANCEL in reading order, whose real path is [3]. If mark→path
    // resolution were off by one (or used the reading index as the path) this
    // would press Send instead — the exact wrong-target failure the whole
    // design exists to prevent.
    let body: [String: JSONValue] = ["mark": .int(2), "view": .string(viewId)]
    let capability = try #require(MacInjectionCapability.mint(approvalID: "approval-body", action: "ax_act", body: body))
    let result = try await client.dispatchApprovedInjection(
        action: "ax_act", body: body, capability: capability
    )
    #expect(result.ok)
    #expect(cancelNode.performed == ["AXPress"])
    #expect(sendNode.performed.isEmpty, "mark 2 must NOT press the Send button")
    #expect(_int(result.output, "mark") == 2)
}

@Test func aMarkFromAStaleViewIsRefusedAndNothingIsEmitted() async throws {
    let store = MacScreenViewStore()
    let sink = _RecordingEventSink()
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: store,
        sink: sink,
        act: _FakeAXActSource(root: _FakeAXActNode(role: "AXWindow"))
    )
    let first = try await client.dispatch(action: "view", body: [:])
    let staleId = try #require(_string(first.output, "view"))
    // The screen changed and she looked again: the old numbers are dead.
    _ = try await client.dispatch(action: "view", body: [:])

    let body: [String: JSONValue] = ["mark": .int(3), "view": .string(staleId)]
    let capability = try #require(MacInjectionCapability.mint(approvalID: "approval-body", action: "click", body: body))
    let result = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: capability
    )
    #expect(!result.ok)
    #expect(result.httpStatus == 409)
    #expect(_string(result.output, "mark_resolution") == "stale_view")
    #expect(sink.mouse.isEmpty, "a stale mark must never click ANYWHERE — least of all at (0,0)")

    // A fabricated token is refused the same way.
    let forged: [String: JSONValue] = ["mark": .int(1), "view": .string("not-a-real-view")]
    let forgedCapability = try #require(MacInjectionCapability.mint(approvalID: "approval-forged", action: "click", body: forged))
    let forgedResult = try await client.dispatchApprovedInjection(
        action: "click", body: forged, capability: forgedCapability
    )
    #expect(!forgedResult.ok)
    #expect(_string(forgedResult.output, "mark_resolution") == "stale_view")
    #expect(sink.mouse.isEmpty)
}

@Test func aMarkWithoutItsViewIdIsRefused() async throws {
    let store = MacScreenViewStore()
    let sink = _RecordingEventSink()
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: store,
        sink: sink
    )
    _ = try await client.dispatch(action: "view", body: [:])
    let body: [String: JSONValue] = ["mark": .int(1)]
    let capability = try #require(MacInjectionCapability.mint(approvalID: "approval-body", action: "click", body: body))
    let result = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: capability
    )
    #expect(!result.ok)
    #expect(result.error?.contains("missing required field: view") == true)
    #expect(sink.mouse.isEmpty)
}

@Test func anUnknownMarkNumberIsRefusedRatherThanApproximated() async throws {
    let store = MacScreenViewStore()
    let sink = _RecordingEventSink()
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: store,
        sink: sink
    )
    let view = try await client.dispatch(action: "view", body: [:])
    let viewId = try #require(_string(view.output, "view"))
    let body: [String: JSONValue] = ["mark": .int(42), "view": .string(viewId)]
    let capability = try #require(MacInjectionCapability.mint(approvalID: "approval-body", action: "click", body: body))
    let result = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: capability
    )
    #expect(!result.ok)
    #expect(_string(result.output, "mark_resolution") == "unknown_mark")
    #expect(sink.mouse.isEmpty)
}

@Test func axActRefusesAMarkAndAConflictingPathInTheSameCall() async throws {
    let store = MacScreenViewStore()
    let act = _FakeAXActSource(root: _FakeAXActNode(
        role: "AXWindow",
        children: [_FakeAXActNode(role: "AXButton", title: "Send", actions: ["AXPress"])]
    ))
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: store,
        act: act
    )
    let view = try await client.dispatch(action: "view", body: [:])
    let viewId = try #require(_string(view.output, "view"))
    // mark 2 is path [3]; the call also names path [0]. Two targets, one call.
    let body: [String: JSONValue] = [
        "mark": .int(2),
        "view": .string(viewId),
        "path": .array([.int(0)]),
    ]
    let capability = try #require(MacInjectionCapability.mint(approvalID: "approval-body", action: "ax_act", body: body))
    let result = try await client.dispatchApprovedInjection(
        action: "ax_act", body: body, capability: capability
    )
    #expect(!result.ok)
    #expect(result.error?.contains("ambiguous_target") == true)
    #expect(act.attempted.isEmpty, "nothing may be attempted when the target is ambiguous")
}

/// Regression pin (caught by `axActRejectsAMalformedPath` while W3.5 was being
/// wired): a `path` that is present but not an array must be REFUSED, never
/// silently read as the empty path. The empty path is the WINDOW ITSELF, so
/// "malformed" collapsing to "act on the whole window" would be a silent
/// wrong-target injection — the exact class this design exists to eliminate.
@Test func axActRefusesAMalformedPathRatherThanActingOnTheWindow() async throws {
    let window = _FakeAXActNode(role: "AXWindow", title: "Compose", actions: ["AXPress"])
    let act = _FakeAXActSource(root: window)
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: MacScreenViewStore(),
        act: act
    )
    for bad: JSONValue in [.string("0"), .int(0), .object(["0": .int(0)]), .null] {
        let body: [String: JSONValue] = ["path": bad]
        let capability = try #require(
            MacInjectionCapability.mint(approvalID: "approval-bad", action: "ax_act", body: body)
        )
        let result = try await client.dispatchApprovedInjection(
            action: "ax_act", body: body, capability: capability
        )
        #expect(!result.ok, "\(bad)")
        #expect(result.httpStatus == 400, "\(bad)")
    }
    #expect(window.performed.isEmpty, "a malformed path must never press the window itself")
    #expect(act.attempted.isEmpty)
}

@Test func theCoordinateFormStillWorksForTheUnmarkedParts() async throws {
    // The pixel-only fallback: a canvas/game/video has no AX marks, and she
    // must still be able to point into the raw picture.
    let sink = _RecordingEventSink()
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: MacScreenViewStore(),
        sink: sink
    )
    let body: [String: JSONValue] = ["x": .double(321), "y": .double(654)]
    let capability = try #require(MacInjectionCapability.mint(approvalID: "approval-body", action: "click", body: body))
    let result = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: capability
    )
    #expect(result.ok)
    #expect(_object(result.output)["targeted_by"] == nil)
    let down = try #require(sink.mouse.first { $0.phase == .down })
    #expect(down.x == 321 && down.y == 654)
}

// MARK: - Structural: the view organ is perception, not action

@Test func fusedViewOrganContainsNoInjectionAPIs() throws {
    func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[line.startIndex..<range.lowerBound]
            }
            .joined(separator: "\n")
    }
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MacControl")
    let raw = try String(
        contentsOf: sources.appendingPathComponent("MacScreenView.swift"),
        encoding: .utf8
    )
    #expect(!raw.isEmpty)
    let source = codeOnly(raw)
    for symbol in [
        "AXUIElementPerformAction",
        "AXUIElementSetAttributeValue",
        "CGEvent(",
        "CGEventPost",
        ".post(tap:",
        "keyboardSetUnicodeString",
        // It must not walk AX itself either — the read organ stays the one
        // perception walker.
        "AXUIElementCopyAttributeValue",
        // And it must never REQUEST a TCC grant; the grant is User's click.
        "CGRequestScreenCaptureAccess",
    ] {
        #expect(!source.contains(symbol),
                "MacScreenView.swift must never call \(symbol) — the fused view looks, it does not act")
    }
    // POSITIVE CONTROL: the audit's greps do match real code elsewhere in the
    // module, so a pass cannot come from a misspelling.
    let actSource = codeOnly(try String(
        contentsOf: sources.appendingPathComponent("MacAccessibilityActuator.swift"),
        encoding: .utf8
    ))
    for symbol in ["AXUIElementPerformAction", "CGEvent(", ".post(tap:"] {
        #expect(actSource.contains(symbol), "positive control missing: \(symbol)")
    }
}

/// The one claim a machine cannot make here: that a marker lands ON the button
/// as a human eye sees it. Everything above pins the arithmetic; only User's
/// Screen Recording grant plus one look can confirm that macOS handed us the
/// pixels for the rect we asked for, at the density we derived.
let manualLiveViewNote = """
LIVE PROOF (needs User): grant Screen Recording, open TextEdit, call mac_view,
and confirm the numbered outlines sit on the real controls in both light and
dark appearance. Then mac_ax_act{mark, view} on a numbered button and confirm
it presses THAT control.
"""

// MARK: - W3.5-FIX 1 — secrets in the PROSE channel

/// A window whose SECRETS ARE TEXT, not field values — the shape the legend's
/// secure-field redaction does not cover and the one that actually happens:
/// the 2FA code is displayed, the API key was revealed, the recovery code sits
/// under its caption, the password field was drawn as bullets by the app. The
/// last line is the FALSE-POSITIVE CONTROL: prose that talks about passwords
/// and must stay perfectly readable, or the perception organ has been blinded.
private func _secretsOnScreenSource() -> _ViewAXSource {
    func text(_ id: Int, _ s: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double)
        -> (Int, _ViewElement) {
        (id, _ViewElement(
            attributes: MacAXAttributes(
                role: "AXStaticText",
                title: s,
                frame: MacAXFrame(x: x, y: y, w: w, h: h),
                actions: []
            ),
            children: []
        ))
    }
    var elements: [Int: _ViewElement] = [
        0: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXWindow",
                title: "Security",
                frame: MacAXFrame(x: 100, y: 200, w: 800, h: 600),
                actions: []
            ),
            children: [1, 2, 3, 4, 5, 6, 7]
        ),
    ]
    // 1/2: caption on the left, the code to its right — the OTP shape AND the
    // proximity path both point at it.
    for (id, element) in [
        text(1, "2FA code", 120, 220, 90, 20),
        text(2, "123456", 260, 220, 80, 20),
        // 3/4: a caption and a value that is NOT a standalone secret shape —
        // only the proximity heuristic can catch this one.
        text(3, "Recovery code", 120, 260, 120, 20),
        text(4, "8F2K-91QT", 280, 260, 100, 20),
        // 5: label and value on ONE line.
        text(5, "API key: sk-live-9f2b7c1d4e5a6b", 120, 300, 400, 20),
        // 6: the app drew its own masked field.
        text(6, "••••••••••", 120, 340, 120, 20),
        // 7: THE FALSE-POSITIVE CONTROL.
        text(7, "Your password must be at least 12 characters long and is never shared.",
             120, 380, 600, 20),
    ] { elements[id] = element }
    return _ViewAXSource(elements: elements)
}

private func _textRows(_ output: JSONValue) -> [[String: JSONValue]] {
    guard case .array(let rows)? = _object(output)["text"] else { return [] }
    return rows.map { _object($0) }
}

/// A row's `text` as it actually ships: either the literal string, or the
/// redaction object's reason.
private func _textCell(_ row: [String: JSONValue]) -> (literal: String?, reason: String?) {
    switch row["text"] {
    case .string(let s): return (s, nil)
    case .object(let o):
        guard case .string(let reason)? = o["reason"] else { return (nil, "redacted") }
        return (nil, reason)
    default: return (nil, nil)
    }
}

@Test func visibleTextRedactsDisplayedSecretsAndLeavesProseAlone() async throws {
    let client = _client(
        ax: _secretsOnScreenSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: MacScreenViewStore()
    )
    let result = try await client.dispatch(action: "view", body: [:])
    #expect(result.ok)
    let rows = _textRows(result.output)
    #expect(rows.count == 7)

    var byReason: [String: String] = [:]   // reason -> nothing; presence check
    var literals: [String] = []
    for row in rows {
        let cell = _textCell(row)
        if let literal = cell.literal { literals.append(literal) }
        if let reason = cell.reason { byReason[reason] = reason }
    }

    // The whole serialized view must not contain any of the secrets ANYWHERE —
    // not in `text`, not in a legend label inferred from that text.
    let serialized = String(data: try result.output.serializedData(pretty: false), encoding: .utf8) ?? ""
    for secret in ["123456", "8F2K-91QT", "sk-live-9f2b7c1d4e5a6b"] {
        #expect(!serialized.contains(secret), "secret \(secret) rode out of mac_view in the clear")
    }

    // Each mechanism fired, and is NAMED — a dark line must be explicable.
    #expect(byReason["otp_shape"] != nil, "the lone 6-digit code must be redacted")
    #expect(byReason["labeled_secret_nearby"] != nil, "a code-shaped value under a secret caption must be redacted")
    #expect(byReason["labeled_inline_secret"] != nil, "`API key: …` on one line must be redacted")
    #expect(byReason["masked_secret"] != nil, "a run of bullets must be redacted")

    // FALSE-POSITIVE GUARD: the sentence, the captions, and nothing else, are
    // still legible. If this fails the organ has been blinded, which is a
    // different bug of the same size.
    #expect(literals.contains("Your password must be at least 12 characters long and is never shared."))
    #expect(literals.contains("2FA code"))
    #expect(literals.contains("Recovery code"))

    // The redaction carries an audit trail, same shape the injection path uses.
    let otpRow = try #require(rows.first { _textCell($0).reason == "otp_shape" })
    guard case .object(let redaction)? = otpRow["text"] else {
        Issue.record("otp row is not a redaction object"); return
    }
    #expect(redaction["redacted"] == .bool(true))
    #expect(redaction["character_count"] == .int(6))
    #expect(redaction["sha256"] == .string(MacInjectionArgRedaction.sha256("123456") ?? ""))
    // The frame stays — WHERE a secret is, is not itself a secret, and she
    // still needs to be able to click the field it belongs to.
    #expect(otpRow["frame"] != nil)
}

/// The shape tests, directly — cheaper to read than the end-to-end above and
/// the place a future contributor will add a case.
@Test func textRedactionJudgesShapeNotSubjectMatter() {
    // REDACTED — the five shapes.
    for (text, reason) in [
        ("123456", "otp_shape"),
        ("12 345 678", "otp_shape"),
        ("••••••••", "masked_secret"),
        ("********", "masked_secret"),
        ("API key: sk-live-9f2b7c1d4e5a6b", "labeled_inline_secret"),
        ("Password: hunter2-the-real-one", "labeled_inline_secret"),
        ("sk-live-9f2b7c1d4e5a6b", "high_entropy_token"),
        ("ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7", "high_entropy_token"),
        ("Xk7Qm2Pv9Zr4Tb8Nw1Ly6Hs3", "high_entropy_token"),
    ] {
        #expect(MacScreenViewTextRedaction.standaloneSecretReason(text) == reason,
                "expected \(text) to redact as \(reason)")
    }

    // NOT REDACTED — prose, captions, and ordinary screen furniture. This half
    // is the one that keeps the organ useful; every entry here is a line a real
    // window shows and she must be able to read.
    for text in [
        "Your password must be at least 12 characters long.",
        "Two-factor authentication is on for this account.",
        "Enter the code we sent to your phone",
        "Password",
        "2FA code",
        "Forgot your password?",
        "Sign in with your API key to continue using the service",
        "Choose a strong password: it should be long and hard to guess",
        "https://example.com/settings/security/two-factor",
        "Last updated 2026-08-12 at 14:32",
        "Order 12345678 shipped",
        "$1,234.56",
        "Documents/keys/readme-about-passwords.txt",
    ] {
        #expect(MacScreenViewTextRedaction.standaloneSecretReason(text) == nil,
                "\(text) is prose and must stay readable")
    }

    // A qualified "code" caption does not make its neighbour a secret.
    #expect(MacScreenViewTextRedaction.looksLikeSecretLabel("2FA code"))
    #expect(MacScreenViewTextRedaction.looksLikeSecretLabel("One-time passcode"))
    #expect(!MacScreenViewTextRedaction.looksLikeSecretLabel("Zip code"))
    #expect(!MacScreenViewTextRedaction.looksLikeSecretLabel("Area code"))
    #expect(!MacScreenViewTextRedaction.looksLikeSecretLabel("Promo code"))
    #expect(!MacScreenViewTextRedaction.looksLikeSecretLabel(
        "Enter the verification code that we just sent to the phone number on file"),
        "a sentence is not a caption, however many secret words it contains")
}

/// Proximity has REACH, and the reach is bounded — a secret caption on the far
/// side of the window does not darken an unrelated token.
@Test func proximityRedactionIsBoundedByTheLegendsOwnHeuristic() {
    let label = MacScreenViewBuilder.VisibleText(
        text: "One-time code", frame: MacAXFrame(x: 100, y: 100, w: 100, h: 20)
    )
    let near = MacScreenViewBuilder.VisibleText(
        text: "AB12CD", frame: MacAXFrame(x: 260, y: 100, w: 80, h: 20)
    )
    let far = MacScreenViewBuilder.VisibleText(
        text: "XY98ZW", frame: MacAXFrame(x: 900, y: 100, w: 80, h: 20)
    )
    let applied = MacScreenViewTextRedaction.applied(to: [label, near, far])
    #expect(applied[0].redactionReason == nil)
    #expect(applied[1].redactionReason == "labeled_secret_nearby")
    #expect(applied[2].redactionReason == nil, "640 points away is not 'beside'")
}

/// The legend is the other channel, and it must not be the weak one: a control
/// NAMED by nearby text inherits that text, so an unlabeled field beside a
/// displayed code would have carried the code out as its `label`.
@Test func legendLabelsAndValuesGetTheSameShapeTest() throws {
    let inferred = MacScreenViewMark(
        mark: 1, role: "AXTextField", label: "482913", labelSource: "nearby_text",
        value: "sk-live-9f2b7c1d4e5a6b",
        frame: MacAXFrame(x: 0, y: 0, w: 10, h: 10), path: [0]
    )
    let row = _object(inferred.toJSON())
    guard case .object(let label)? = row["label"] else {
        Issue.record("an OTP-shaped inferred label must not ship as a string"); return
    }
    #expect(label["redacted"] == .bool(true))
    #expect(label["reason"] == .string("otp_shape"))
    guard case .object(let value)? = row["value"] else {
        Issue.record("a revealed key must not ship as a string"); return
    }
    #expect(value["reason"] == .string("high_entropy_token"))

    // An ordinary control is untouched — the legend still reads like a legend.
    let ordinary = MacScreenViewMark(
        mark: 2, role: "AXButton", label: "Send", value: "Send",
        frame: MacAXFrame(x: 0, y: 0, w: 10, h: 10), path: [1]
    )
    let ordinaryRow = _object(ordinary.toJSON())
    #expect(ordinaryRow["label"] == .string("Send"))
    #expect(ordinaryRow["value"] == .string("Send"))
}

// MARK: - W3.5-FIX 2 — one target, named once

/// `mac_click` took `mark` AND coordinates and silently preferred the mark.
/// The approval digest binds the whole body, so this was never an approval
/// bypass — but the human approved a call naming two different points, and
/// only one of them happened. `ax_act` already refuses the analogous
/// mark+path conflict; both act tools now hold the same line.
@Test func clickRefusesABodyThatNamesBothAMarkAndCoordinates() async throws {
    let sink = _RecordingEventSink()
    let store = MacScreenViewStore()
    let client = _client(
        ax: _composeWindowSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: store,
        sink: sink,
        act: _FakeAXActSource(root: _FakeAXActNode(role: "AXWindow"))
    )
    let view = try await client.dispatch(action: "view", body: [:])
    let viewId = try #require(_string(view.output, "view"))

    for body: [String: JSONValue] in [
        ["mark": .int(3), "view": .string(viewId), "x": .double(10), "y": .double(20)],
        [
            "mark": .int(3), "view": .string(viewId),
            "from": .object(["x": .double(10), "y": .double(20)]),
            "to": .object(["x": .double(30), "y": .double(40)]),
        ],
        ["mark": .int(3), "view": .string(viewId), "from_x": .double(1), "from_y": .double(2),
         "to_x": .double(3), "to_y": .double(4)],
    ] {
        let capability = try #require(
            MacInjectionCapability.mint(approvalID: "approval-conflict", action: "click", body: body)
        )
        let result = try await client.dispatchApprovedInjection(
            action: "click", body: body, capability: capability
        )
        #expect(!result.ok)
        #expect(result.httpStatus == 400)
        #expect(result.error?.contains("ambiguous_target") == true)
        #expect(sink.mouse.isEmpty, "an ambiguous target must click NOWHERE")
    }

    // The unambiguous forms still work: mark alone, and coordinates alone.
    let markOnly: [String: JSONValue] = ["mark": .int(3), "view": .string(viewId)]
    let markCapability = try #require(
        MacInjectionCapability.mint(approvalID: "approval-mark", action: "click", body: markOnly)
    )
    #expect(try await client.dispatchApprovedInjection(
        action: "click", body: markOnly, capability: markCapability
    ).ok)

    let pointOnly: [String: JSONValue] = ["x": .double(750), "y": .double(720)]
    let pointCapability = try #require(
        MacInjectionCapability.mint(approvalID: "approval-point", action: "click", body: pointOnly)
    )
    #expect(try await client.dispatchApprovedInjection(
        action: "click", body: pointOnly, capability: pointCapability
    ).ok)
}

// MARK: - W3.5-FIX-R2 3 — the shapes round one could not see
//
// Round 1's heuristic was built around a single opaque token, and three
// structural assumptions inside it let common secrets through:
//   * a length floor of 4 characters  → a 3-digit CVV
//   * "a token contains no whitespace" → a card number written `4111 1111 …`
//   * an allowed charset of [A-Za-z0-9-_.] → base64's own `+ / =`
// and a fourth shape it never modelled at all: a MULTI-WORD secret, i.e. a
// wallet recovery phrase.
//
// Each new detector below ships with the guard that keeps it from eating
// ordinary text — Luhn for cards, an entropy + case-run + marker-character
// gate for base64, a function-word/word-length gate for phrases, and an
// explicit caption for the CVV, which is far too short to darken on its own.

@Test func textRedactionCatchesTheRoundTwoShapes() {
    for (text, reason) in [
        // (a) CVV — three digits, only ever dark under a caption that names it.
        ("CVV: 123", "labeled_cvv"),
        ("CVC: 4821", "labeled_cvv"),
        ("Security code: 908", "labeled_cvv"),
        // (b) card numbers, in the separated forms a human actually reads.
        ("4111 1111 1111 1111", "card_number_shape"),
        ("4111-1111-1111-1111", "card_number_shape"),
        ("4111111111111111", "card_number_shape"),
        ("Card number: 5500 0000 0000 0004", "labeled_inline_secret"),
        // (c) recovery / seed phrases.
        ("ripple carbon melody puzzle orbit fabric tunnel shrimp velvet ginger marble oyster",
         "recovery_phrase_shape"),
        ("Recovery phrase: ripple carbon melody puzzle orbit fabric",
         "labeled_recovery_phrase"),
        // (d) base64 / base64url tokens carrying the characters round 1 banned.
        ("aGVsbG8+d29ybGQvZm9vPQ==", "high_entropy_token"),
        ("U2FsdGVkX1+9xQ2mKp7vRt4LcNw8YbZa", "high_entropy_token"),
    ] {
        #expect(MacScreenViewTextRedaction.standaloneSecretReason(text) == reason,
                "expected \(text) to redact as \(reason)")
    }
}

/// THE LOAD-BEARING HALF. Over-redaction blinds the perception organ this whole
/// feature exists to build, and it fails silently — she simply stops being able
/// to read the screen. Every line here is one a real window shows.
@Test func theRoundTwoDetectorsDoNotEatOrdinaryScreenText() {
    for text in [
        // Prose that NAMES the secrets, which is not the same as being one.
        "Your CVV is the three digit code on the back of your card",
        "Never share your recovery phrase with anyone, not even support",
        "We could not verify the card number you entered. Please try again.",
        "Paste your API key below to finish connecting the account",
        // Numbers that are 13-19 digits' cousins but are not cards.
        "Order number: 12345678",
        "Order 12345678 shipped",
        "Invoice 2024-000123456789",
        "4111 1111 1111 1112",           // one digit off — Luhn says no
        "1234 5678 9012 3456",           // sequential filler — Luhn says no
        "9400111899223197428490",        // USPS tracking: 22 digits, too long
        "1Z999AA10123456784",            // UPS tracking: letters, and short
        "(555) 123-4567",                // phone
        "+1 555 123 4567",
        "94103",                         // zip
        "Building 4, Floor 12, Room 305",
        // Twelve+ words of ordinary English — the seed-phrase false positive.
        "the quick brown fox jumps over the lazy dog while we all watch",
        "please review the attached invoice before the end of the month today",
        "meeting notes from monday about budget planning and hiring for next quarter",
        // Paths and URLs, including one with a base64-shaped segment.
        "https://example.com/assets/aGVsbG8+d29ybGQvZm9vPQ==",
        "Reports/2024/Summary",
        "Documents/Screenshots/2024",
        "NativeAgentCoreBuildNumber42",
        "width=1200&height=800",
        // Ordinary UI furniture.
        "Send", "Cancel", "Card number", "CVV", "Security code", "Recovery phrase",
        "Expires 09/29",
        "$1,234.56",
    ] {
        #expect(MacScreenViewTextRedaction.standaloneSecretReason(text) == nil,
                "\(text) is ordinary screen text and must stay readable")
    }
}

/// Luhn is the card detector's whole false-positive story, so it gets pinned
/// directly: same length, same shape, one digit different.
@Test func theCardDetectorLeansOnLuhnNotOnLength() {
    #expect(MacScreenViewTextRedaction.luhnValid("4111111111111111"))
    #expect(!MacScreenViewTextRedaction.luhnValid("4111111111111112"))
    #expect(MacScreenViewTextRedaction.isPaymentCardNumber("5500 0000 0000 0004"))
    #expect(!MacScreenViewTextRedaction.isPaymentCardNumber("5500 0000 0000 0005"))
    // 12 digits is under the shortest card; 20 is over the longest.
    #expect(!MacScreenViewTextRedaction.isPaymentCardNumber("400000000009"))
    #expect(!MacScreenViewTextRedaction.isPaymentCardNumber("41111111111111111110"))
}

/// The base64 gate: a marker character AND mixed case AND a digit AND a short
/// same-case run AND entropy. Drop any one of them and a file path qualifies.
@Test func theBase64DetectorIsGatedSoPathsAndWordsDoNotQualify() {
    #expect(MacScreenViewTextRedaction.isBase64Token("aGVsbG8+d29ybGQvZm9vPQ=="))
    #expect(!MacScreenViewTextRedaction.isBase64Token("Reports/2024/Summary"),
            "'eports' is a 6-long same-case run; encoded bytes do not do that")
    #expect(!MacScreenViewTextRedaction.isBase64Token("thisisalllowercase+andlong"))
    #expect(!MacScreenViewTextRedaction.isBase64Token("Docs/2024/Q3/Notes.txt"),
            "a dot means a filename")
    #expect(!MacScreenViewTextRedaction.isBase64Token("aGVsbG8+d29"), "too short")
    // The CamelCase guard on the UNPREFIXED token detector: a long identifier
    // clears every entropy bar and is still just a name.
    #expect(MacScreenViewTextRedaction.looksLikeCamelCaseIdentifier("NativeAgentCoreBuildNumber42"))
    #expect(!MacScreenViewTextRedaction.looksLikeCamelCaseIdentifier("Xk7Qm2Pv9Zr4Tb8Nw1Ly6Hs3"),
            "a random token's segments are two characters long, not words")
    #expect(MacScreenViewTextRedaction.longestSameCaseRun("Reports/2024/Summary") == 6)
    #expect(MacScreenViewTextRedaction.shannonEntropyBitsPerCharacter("aaaaaaaa") == 0)
}

/// The phrase detector's guards, one at a time.
@Test func theRecoveryPhraseDetectorRequiresWordlistShapeNotJustLowercase() {
    let real = "ripple carbon melody puzzle orbit fabric tunnel shrimp velvet ginger marble oyster"
    #expect(MacScreenViewTextRedaction.isRecoveryPhrase(real))
    // Eleven words is under the unlabeled bar — the bar exists because a short
    // run of lowercase words is just a phrase.
    #expect(!MacScreenViewTextRedaction.isRecoveryPhrase(
        "ripple carbon melody puzzle orbit fabric tunnel shrimp velvet ginger marble"))
    // …but under an explicit caption, six is enough.
    #expect(MacScreenViewTextRedaction.isRecoveryPhrase(
        "ripple carbon melody puzzle orbit fabric",
        minWords: MacScreenViewTextRedaction.labeledSeedMinWords))
    // A capital, a punctuation mark, or a function word all mean prose.
    #expect(!MacScreenViewTextRedaction.isRecoveryPhrase(
        "Ripple carbon melody puzzle orbit fabric tunnel shrimp velvet ginger marble oyster"))
    #expect(!MacScreenViewTextRedaction.isRecoveryPhrase(
        "ripple carbon melody puzzle orbit fabric tunnel shrimp velvet ginger marble oyster."))
    #expect(!MacScreenViewTextRedaction.isRecoveryPhrase(
        "ripple carbon melody puzzle orbit fabric tunnel shrimp velvet ginger marble that"))
    #expect(MacScreenViewTextRedaction.isSeedPhraseLabel("Secret Recovery Phrase"))
    #expect(MacScreenViewTextRedaction.isCardVerificationLabel("CVV"))
    #expect(MacScreenViewTextRedaction.isCardVerificationLabel("Card verification value"))
    #expect(!MacScreenViewTextRedaction.isCardVerificationLabel("Discount code"))
}

/// By POSITION, the way a checkout form actually lays out: the caption on the
/// left, the three digits in the box beside it. Neither half is a secret on
/// its own — three digits is a quantity — so only the pairing can catch it.
@Test func cvvAndSeedWordsRedactUnderTheirCaptionsByPosition() {
    let cvvLabel = MacScreenViewBuilder.VisibleText(
        text: "CVV", frame: MacAXFrame(x: 100, y: 100, w: 40, h: 20)
    )
    let cvvValue = MacScreenViewBuilder.VisibleText(
        text: "123", frame: MacAXFrame(x: 160, y: 100, w: 40, h: 20)
    )
    let seedLabel = MacScreenViewBuilder.VisibleText(
        text: "Recovery phrase", frame: MacAXFrame(x: 100, y: 200, w: 140, h: 20)
    )
    let seedValue = MacScreenViewBuilder.VisibleText(
        text: "ripple carbon melody puzzle orbit fabric",
        frame: MacAXFrame(x: 100, y: 240, w: 400, h: 20)
    )
    // The control: the same three digits, nowhere near a CVV caption.
    let quantity = MacScreenViewBuilder.VisibleText(
        text: "123", frame: MacAXFrame(x: 900, y: 500, w: 40, h: 20)
    )
    let applied = MacScreenViewTextRedaction.applied(
        to: [cvvLabel, cvvValue, seedLabel, seedValue, quantity]
    )
    #expect(applied[0].redactionReason == nil, "the caption itself is not the secret")
    #expect(applied[1].redactionReason == "labeled_cvv")
    #expect(applied[2].redactionReason == nil)
    #expect(applied[3].redactionReason == "labeled_recovery_phrase")
    #expect(applied[4].redactionReason == nil, "three digits alone is a quantity")
}

/// The legend is the channel she actually acts from, so it carries the same
/// caption pairing: a field NAMED "CVV" showing three digits is the same
/// secret whether it arrives as prose or as a legend row.
@Test func theLegendRedactsAValueUnderItsOwnSecretCaption() {
    let cvvField = MacScreenViewMark(
        mark: 1, role: "AXTextField", label: "CVV", value: "123",
        frame: MacAXFrame(x: 0, y: 0, w: 10, h: 10), path: [0]
    )
    guard case .object(let value)? = _object(cvvField.toJSON())["value"] else {
        Issue.record("a CVV under its own caption must not ship as a string"); return
    }
    #expect(value["reason"] == .string("labeled_cvv"))

    // The false-positive twin: a quantity stepper labeled "Quantity" showing
    // the same three digits stays completely legible.
    let quantity = MacScreenViewMark(
        mark: 2, role: "AXTextField", label: "Quantity", value: "123",
        frame: MacAXFrame(x: 0, y: 0, w: 10, h: 10), path: [1]
    )
    #expect(_object(quantity.toJSON())["value"] == .string("123"))
}

// MARK: - W3.5-FIX-R2 2 — the window title is screen text too

/// The root AXWindow is not a TEXT role, so its title never enters
/// `visibleText` and the source redaction never sees it. A title is routinely
/// the secret itself — a password manager window named after the item, a
/// terminal titled with what it just printed — and it rode out raw into every
/// mac_view sink.
@Test func aSecretShapedWindowTitleIsRedactedInTheFusedView() async throws {
    for (title, reason) in [
        ("sk-live-9f2b7c1d4e5a6b", "high_entropy_token"),
        ("482913", "otp_shape"),
        ("4111 1111 1111 1111", "card_number_shape"),
        ("aGVsbG8+d29ybGQvZm9vPQ==", "high_entropy_token"),
    ] {
        let client = _client(
            ax: _titledWindowSource(title),
            capture: _StubCaptureSource(shot: _shot()),
            renderer: _StubRenderer(baseBytes: 1_000),
            store: MacScreenViewStore()
        )
        let result = try await client.dispatch(action: "view", body: [:])
        #expect(result.ok)
        guard case .object(let redaction)? = _object(result.output)["window_title"] else {
            Issue.record("window title \(title) shipped as a raw string"); return
        }
        #expect(redaction["reason"] == .string(reason))
        let serialized = String(data: try result.output.serializedData(pretty: false), encoding: .utf8) ?? ""
        #expect(!serialized.contains(title), "the title rode out of mac_view in the clear")
    }

    // FALSE-POSITIVE GUARD: an ordinary window title is still a plain string —
    // she needs to know which window she is looking at.
    let ordinary = _client(
        ax: _titledWindowSource("Inbox — Mail"),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: MacScreenViewStore()
    )
    let plain = try await ordinary.dispatch(action: "view", body: [:])
    #expect(_string(plain.output, "window_title") == "Inbox — Mail")
}

/// A window whose only interesting property is its TITLE, plus one button so
/// the legend is non-empty.
private func _titledWindowSource(_ title: String) -> _ViewAXSource {
    _ViewAXSource(elements: [
        0: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXWindow",
                title: title,
                frame: MacAXFrame(x: 100, y: 200, w: 800, h: 600),
                actions: []
            ),
            children: [1]
        ),
        1: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                title: "Close",
                frame: MacAXFrame(x: 700, y: 700, w: 100, h: 40),
                actions: ["AXPress"]
            ),
            children: []
        ),
    ])
}

// MARK: - W3.5-FIX-R2 1 — the later echo, from a mark and from a live re-read

/// A window holding one clickable control whose NAME is the secret — the
/// "Copy 482913" button pattern, where the code IS the control's title.
private func _secretNamedControlSource() -> _ViewAXSource {
    _ViewAXSource(elements: [
        0: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXWindow",
                title: "Authenticator",
                frame: MacAXFrame(x: 100, y: 200, w: 800, h: 600),
                actions: []
            ),
            children: [1]
        ),
        1: _ViewElement(
            attributes: MacAXAttributes(
                role: "AXButton",
                title: "482913",
                frame: MacAXFrame(x: 200, y: 300, w: 120, h: 40),
                actions: ["AXPress"]
            ),
            children: []
        ),
    ])
}

/// `mac_view` serialized this control's label REDACTED. Then `mac_click{mark}`
/// resolved the same mark and echoed `element.label` straight from the stored
/// mark — raw — into a result that rides the trace, the persisted tool row and
/// the sync path. The read tool's redaction was undone by the act tool.
@Test func clickByMarkDoesNotEchoTheRawSecretLabelItResolved() async throws {
    let store = MacScreenViewStore()
    let sink = _RecordingEventSink()
    let client = _client(
        ax: _secretNamedControlSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: store,
        sink: sink
    )
    let view = try await client.dispatch(action: "view", body: [:])
    let viewId = try #require(_string(view.output, "view"))
    #expect(!(String(data: try view.output.serializedData(pretty: false), encoding: .utf8) ?? "")
        .contains("482913"), "precondition: the READ tool already redacts it")

    let body: [String: JSONValue] = ["mark": .int(1), "view": .string(viewId)]
    let capability = try #require(
        MacInjectionCapability.mint(approvalID: "approval-echo", action: "click", body: body)
    )
    let result = try await client.dispatchApprovedInjection(
        action: "click", body: body, capability: capability
    )
    #expect(result.ok)
    #expect(!sink.mouse.isEmpty, "the click itself still happens — this is a redaction, not a refusal")

    let serialized = String(data: try result.output.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!serialized.contains("482913"),
            "the secret-shaped label rode back out through the CLICK result")
    // The row is still useful: she knows WHICH element she hit and where.
    #expect(serialized.contains("AXButton"))
    #expect(serialized.contains("otp_shape"))
}

/// The same echo on the semantic-action tool, from a LIVE re-read rather than
/// from the stored mark: `ax_act` returns `element` and `post_state` built from
/// the AX tree it just touched, and `redactingValue` only ever covered a value
/// this call WROTE.
@Test func axActDoesNotEchoARawSecretElementNameOrReadValue() async throws {
    let node = _FakeAXActNode(
        role: "AXStaticText",
        title: "482913",
        value: "sk-live-9f2b7c1d4e5a6b",
        frame: MacAXFrame(x: 200, y: 300, w: 120, h: 40),
        actions: ["AXPress"]
    )
    let client = _client(
        ax: _secretNamedControlSource(),
        capture: _StubCaptureSource(shot: _shot()),
        renderer: _StubRenderer(baseBytes: 1_000),
        store: MacScreenViewStore(),
        act: _FakeAXActSource(root: _FakeAXActNode(role: "AXWindow", children: [node]))
    )
    let body: [String: JSONValue] = ["path": .array([.int(0)]), "action": .string("AXPress")]
    let capability = try #require(
        MacInjectionCapability.mint(approvalID: "approval-act-echo", action: "ax_act", body: body)
    )
    let result = try await client.dispatchApprovedInjection(
        action: "ax_act", body: body, capability: capability
    )
    let serialized = String(data: try result.output.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!serialized.contains("482913"), "an OTP-shaped element title rode out of ax_act")
    #expect(!serialized.contains("sk-live-9f2b7c1d4e5a6b"), "a read-back key rode out of ax_act")
    #expect(serialized.contains("AXStaticText"), "the row is redacted, not deleted")
}

/// The echo redactor, directly — and its false-positive twin, because an
/// ordinary element must survive the trip completely intact.
@Test func theElementEchoRedactorLeavesOrdinaryElementsWhole() {
    let ordinary = JSONValue.object([
        "role": .string("AXButton"),
        "title": .string("Send"),
        "value": .string("Send"),
    ])
    #expect(MacScreenViewTextRedaction.redactedElementJSON(ordinary) == ordinary)

    let cvvBox = JSONValue.object([
        "role": .string("AXTextField"),
        "title": .string("CVV"),
        "value": .string("123"),
    ])
    guard case .object(let redacted) = MacScreenViewTextRedaction.redactedElementJSON(cvvBox),
          case .object(let value)? = redacted["value"] else {
        Issue.record("a CVV value under its own title must not ship as a string"); return
    }
    #expect(value["reason"] == .string("labeled_cvv"))
    #expect(redacted["title"] == .string("CVV"), "the caption itself stays readable")
}

// MARK: - W3.5-FIX-R4: the ENCLOSING group caption, in the legend
private func _r4String(_ value: JSONValue?) -> String? {
    guard case .string(let s)? = value else { return nil }
    return s
}

private func _r4Array(_ value: JSONValue?) -> [JSONValue] {
    guard case .array(let a)? = value else { return [] }
    return a
}


/// The `mac_view` half of the round-3 leak. The legend redacts a value under
/// the control's OWN caption (`under:`) and a name/value that is secret-shaped
/// on its own — neither of which can see the geometry a real card form uses:
/// the caption is the GROUP the field sits inside.
///
/// Nodes are built with explicit paths rather than walked, so the ancestor
/// relationship under test is stated in the fixture and not inferred.
private func _enclosingLegendNodes() -> [MacAXNode] {
    func node(_ path: [Int], _ attributes: MacAXAttributes) -> MacAXNode {
        MacAXNode(attributes: attributes, path: path)
    }
    func group(_ title: String, _ frame: MacAXFrame) -> MacAXAttributes {
        MacAXAttributes(role: "AXGroup", title: title, frame: frame)
    }
    func field(_ value: String, _ frame: MacAXFrame) -> MacAXAttributes {
        MacAXAttributes(
            role: "AXTextField", value: value, enabled: true,
            frame: frame, actions: ["AXPress"]
        )
    }
    // Inside the `_shot()` window (x 100…900, y 200…800).
    return [
        node([], MacAXAttributes(role: "AXWindow", title: "Checkout",
                                 frame: MacAXFrame(x: 100, y: 200, w: 800, h: 600))),
        node([0], group("CVV", MacAXFrame(x: 150, y: 250, w: 200, h: 60))),
        node([0, 0], field("451", MacAXFrame(x: 160, y: 260, w: 60, h: 20))),
        node([1], group("Payment", MacAXFrame(x: 150, y: 500, w: 200, h: 60))),
        node([1, 0], field("4B-1200", MacAXFrame(x: 160, y: 510, w: 120, h: 20))),
        node([2], group("Toolbar", MacAXFrame(x: 600, y: 250, w: 200, h: 60))),
        node([2, 0], MacAXAttributes(
            role: "AXButton", title: "New Tab", enabled: true,
            frame: MacAXFrame(x: 610, y: 260, w: 80, h: 22), actions: ["AXPress"]
        )),
    ]
}

private func _legendRow(_ selection: MacScreenViewBuilder.Selection, path: [Int]) -> [String: JSONValue] {
    guard let mark = selection.marks.first(where: { $0.path == path }) else { return [:] }
    return _object(mark.toJSON())
}

@Test func legendRedactsAValueCaptionedByItsEnclosingGroup() throws {
    let selection = MacScreenViewBuilder.select(
        nodes: _enclosingLegendNodes(),
        geometry: MacScreenViewGeometry(shot: _shot())
    )
    let row = _legendRow(selection, path: [0, 0])
    // The untitled field's inferred NAME is its own value ("451"), so BOTH
    // legend channels have to be covered or the CVV leaks as a label.
    guard case .object(let value)? = row["value"] else {
        Issue.record("legend value rode out in the clear: \(row)")
        return
    }
    #expect(value["redacted"] == JSONValue.bool(true))
    #expect(_r4String(value["reason"]) == "enclosing_cvv")
    #expect(value["character_count"] == JSONValue.int(3))
    guard case .object(let label)? = row["label"] else {
        Issue.record("legend label rode out in the clear: \(row)")
        return
    }
    #expect(label["redacted"] == JSONValue.bool(true))
    // Addressing survives: a dark row is still a mark she can click.
    #expect(row["path"] == JSONValue.array([.int(0), .int(0)]))
    #expect(_r4Array(row["actions"]) == [JSONValue.string("AXPress")])
    #expect(!String(describing: selection.marks.map { $0.toJSON() }).contains("\"451\""))
}

@Test func legendLeavesOrdinaryEnclosingGroupsAlone() throws {
    let selection = MacScreenViewBuilder.select(
        nodes: _enclosingLegendNodes(),
        geometry: MacScreenViewGeometry(shot: _shot())
    )
    // "Payment" and "Toolbar" are ordinary structure. Their children stay
    // fully readable — an over-redacted legend blinds her silently.
    #expect(_r4String(_legendRow(selection, path: [1, 0])["value"]) == "4B-1200")
    #expect(_r4String(_legendRow(selection, path: [2, 0])["label"]) == "New Tab")
}

@Test func legendEnclosingCaptionIsWhatCatchesIt() throws {
    // TEETH: the same mark, serialized with the enclosing caption removed,
    // hands back the raw CVV. This is the pre-fix state, pinned in-tree.
    let selection = MacScreenViewBuilder.select(
        nodes: _enclosingLegendNodes(),
        geometry: MacScreenViewGeometry(shot: _shot())
    )
    let live = try #require(selection.marks.first { $0.path == [0, 0] })
    #expect(live.enclosingCaption.cvv, "the ancestor walk found the CVV group")
    let stripped = MacScreenViewMark(
        mark: live.mark,
        role: live.role,
        label: live.label,
        labelSource: live.labelSource,
        value: live.value,
        enabled: live.enabled,
        frame: live.frame,
        path: live.path,
        actions: live.actions
    )
    #expect(_r4String(_object(stripped.toJSON())["value"]) == "451", "no caption ⇒ the leak is back")
}

@Test func proseChannelHonoursTheEnclosingCaptionToo() throws {
    // Static text sits inside a captioned group as often as a field does — the
    // recovery words a wallet prints under its heading are prose, not values.
    let nodes: [MacAXNode] = [
        MacAXNode(attributes: MacAXAttributes(
            role: "AXWindow", title: "Wallet",
            frame: MacAXFrame(x: 100, y: 200, w: 800, h: 600)
        ), path: []),
        MacAXNode(attributes: MacAXAttributes(
            role: "AXGroup", title: "Security code",
            frame: MacAXFrame(x: 150, y: 250, w: 300, h: 80)
        ), path: [0]),
        MacAXNode(attributes: MacAXAttributes(
            role: "AXStaticText", title: "8842",
            frame: MacAXFrame(x: 160, y: 300, w: 60, h: 20)
        ), path: [0, 0]),
        MacAXNode(attributes: MacAXAttributes(
            role: "AXGroup", title: "Recent activity",
            frame: MacAXFrame(x: 500, y: 250, w: 300, h: 80)
        ), path: [1]),
        MacAXNode(attributes: MacAXAttributes(
            role: "AXStaticText", title: "8842",
            frame: MacAXFrame(x: 510, y: 300, w: 60, h: 20)
        ), path: [1, 0]),
    ]
    let text = MacScreenViewBuilder.visibleText(
        nodes: nodes,
        geometry: MacScreenViewGeometry(shot: _shot())
    )
    let dark = try #require(text.items.first { $0.frame.x == 160 })
    #expect(dark.redactionReason == "enclosing_cvv")
    // Same four digits, ordinary group: a quantity, and it stays a quantity.
    let legible = try #require(text.items.first { $0.frame.x == 510 })
    #expect(legible.redactionReason == nil)
}
