import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

#if canImport(AppKit) && os(macOS)
import AppKit
import CoreText
#endif

// MARK: - THE READ ORGAN (fable51 sweep item 33)
//
// Hermetic. A synthetic AX tree whose contents CHANGE when a scroll event
// arrives — that is the whole seam the accumulate route lives on — plus a
// recording event sink, plus a real PDF generated at test time for the extract
// route. No window server, no real scroll wheel, no file of User's is opened.
//
// What these tests hold:
//
//   1. The accumulate route reconstructs the WHOLE document, in order, with the
//      seams merged: no duplicated overlap lines, no dropped ones.
//   2. It stops because the content stopped changing, not because a cap bit,
//      and it puts the scroll position back where it found it.
//   3. THE TIER. It emits exactly one class of event — vertical scrolls, plus
//      the one cursor move that aims them. That emission set is why this organ
//      is graded a read rather than injection, so it is greped, not asserted in
//      a comment. Anything that could press or type fails this file.
//   4. The extract route reads a real PDF's real characters.
//   5. Refusals are WORDS: no document, unreadable, secure content.
//   6. The shape redactor runs on the accumulated text before it returns.
//   7. `look`'s budgets are untouched — the caps item 33 was NOT allowed to
//      raise are pinned here, in the file that would have been tempted.

// MARK: - The seam: a document behind a moving viewport

/// The scrolled document. The AX source reads its CURRENT window; the event
/// sink moves it. Two seams, one shared truth, exactly like the real thing.
private final class _Viewport: @unchecked Sendable {
    private let lock = NSLock()
    let document: [String]
    let windowLines: Int
    let stepLines: Int
    private var offset = 0

    init(document: [String], windowLines: Int, stepLines: Int) {
        self.document = document
        self.windowLines = windowLines
        self.stepLines = stepLines
    }

    var maxOffset: Int { max(0, document.count - windowLines) }

    func visible() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let start = min(offset, maxOffset)
        return Array(document[start..<min(start + windowLines, document.count)])
    }

    func scroll(lines: Int) {
        lock.lock(); defer { lock.unlock() }
        offset = max(0, min(maxOffset, offset + lines))
    }

    func currentOffset() -> Int {
        lock.lock(); defer { lock.unlock() }
        return min(offset, maxOffset)
    }

    func restoreOffset(_ saved: Int) {
        lock.lock(); defer { lock.unlock() }
        offset = max(0, min(maxOffset, saved))
    }
}

private struct _ViewportRestoration: MacDocumentScrollRestoring {
    let viewport: _Viewport
    let savedOffset: Int
    func restore() -> Bool {
        viewport.restoreOffset(savedOffset)
        return isRestored
    }
    var isRestored: Bool { viewport.currentOffset() == savedOffset }
}

/// Window (1) → AXScrollArea (2) → one AXStaticText per VISIBLE line.
/// Line elements are minted at `100 + index`, so the tree genuinely re-renders
/// between frames rather than the test handing the organ a pre-merged answer.
private final class _DocSource: MacAXElementSource, MacDocumentScrollRestorationSource, @unchecked Sendable {
    let viewport: _Viewport
    private let containerRole: String
    private let containerFrame: MacAXFrame
    private let extraRoles: [String]
    private let documentPath: String?
    var targetIsCurrent: @Sendable () -> Bool = { true }
    var switchWindowDuringDocumentQuery = false
    private var changedWindow = false
    private let app = MacAXAppInfo(name: "Preview", bundleIdentifier: "com.apple.Preview", processIdentifier: 4242)

    init(
        viewport: _Viewport,
        containerRole: String = "AXScrollArea",
        containerFrame: MacAXFrame = MacAXFrame(x: 0, y: 0, w: 800, h: 600),
        extraRoles: [String] = [],
        documentPath: String? = nil
    ) {
        self.viewport = viewport
        self.containerRole = containerRole
        self.containerFrame = containerFrame
        self.extraRoles = extraRoles
        self.documentPath = documentPath
    }

    func isTrusted() -> Bool { true }
    func frontmostApp() -> MacAXAppInfo? { app }
    func frontmostWindowRoot() -> MacAXElementRef? { MacAXElementRef(id: changedWindow ? 9 : 1) }
    func frontmostDocumentPath(pid: Int32) -> String? {
        if switchWindowDuringDocumentQuery { changedWindow = true }
        return documentPath
    }
    func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32) -> Bool {
        targetIsCurrent()
    }

    // 66ecad9d restores observed position, not the sum of requested wheel deltas.
    func captureScrollRestoration(container: MacAXElementRef) -> (any MacDocumentScrollRestoring)? {
        guard container.id == 2 else { return nil }
        return _ViewportRestoration(viewport: viewport, savedOffset: viewport.currentOffset())
    }

    func attributes(of element: MacAXElementRef) -> MacAXAttributes? {
        switch element.id {
        case 1:
            return MacAXAttributes(role: "AXWindow", title: "Contract", frame: containerFrame)
        case 2:
            return MacAXAttributes(role: containerRole, frame: containerFrame)
        case 50..<100:
            let index = element.id - 50
            guard index < extraRoles.count else { return nil }
            return MacAXAttributes(role: extraRoles[index], value: "should never be read")
        default:
            let index = element.id - 100
            let lines = viewport.visible()
            guard index >= 0, index < lines.count else { return nil }
            return MacAXAttributes(role: "AXStaticText", value: lines[index])
        }
    }

    func children(of element: MacAXElementRef) -> [MacAXElementRef] {
        switch element.id {
        case 1:
            return [MacAXElementRef(id: 2)]
        case 2:
            let lines = (0..<viewport.visible().count).map { MacAXElementRef(id: 100 + $0) }
            let extras = (0..<extraRoles.count).map { MacAXElementRef(id: 50 + $0) }
            return extras + lines
        default:
            return []
        }
    }

    func focusedElementPath() -> [Int]? { nil }
}

/// Every event the organ emitted, in order. The tier assertion greps this.
private final class _ScrollSink: MacEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private let viewport: _Viewport?
    /// Points per line, so a pixel-unit scroll maps onto the line model.
    private let pointsPerLine: Double
    let available: Bool
    private(set) var keys: [MacKeyEvent] = []
    private(set) var mice: [MacMouseEvent] = []
    private(set) var scrolls: [MacScrollEvent] = []
    var onScroll: @Sendable () -> Void = {}

    init(viewport: _Viewport?, pointsPerLine: Double = 20, available: Bool = true) {
        self.viewport = viewport
        self.pointsPerLine = pointsPerLine
        self.available = available
    }

    var isAvailable: Bool { available }
    var secureKeyboardEntryActive: Bool { false }

    func post(key: MacKeyEvent) { lock.withLock { keys.append(key) } }
    func post(mouse: MacMouseEvent) { lock.withLock { mice.append(mouse) } }
    func post(scroll: MacScrollEvent) {
        lock.withLock { scrolls.append(scroll) }
        // A negative deltaY moves the CONTENT up, i.e. further down the
        // document — the same sign convention the actuator uses.
        let lines = Int((Double(-scroll.deltaY) / pointsPerLine).rounded())
        viewport?.scroll(lines: lines)
        onScroll()
    }

    func recorded() -> (keys: [MacKeyEvent], mice: [MacMouseEvent], scrolls: [MacScrollEvent]) {
        lock.lock(); defer { lock.unlock() }
        return (keys, mice, scrolls)
    }
}

private func _readClient(
    source: any MacAXElementSource,
    sink: any MacEventSink,
    policyProvider: (any MacControlPolicyProvider)? = nil
) -> SwiftNativeMacControl {
    // A FRESH attention store, never `.shared`: `read` is (deliberately)
    // subject to the human-input priority check, and a session another test in
    // this target left open would refuse these reads for the wrong reason.
    SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        attentionEventSource: UnavailableMacAttentionEventSource(),
        attentionStore: MacAttentionSessionStore(screenViewStore: MacScreenViewStore()),
        policyProvider: policyProvider
    )
}

/// A live policy, for the two checks that only exist when one is wired.
private struct _FixedPolicy: MacControlPolicyProvider {
    let policy: MacControlPolicy
    func currentPolicy() async -> MacControlPolicy? { policy }
}

/// Full Mac ON (so `read` clears its own pre-flight) with the `file_ops`
/// category explicitly OFF — the exact shape in which the AX-inferred path used
/// to open a file the tool layer would have refused.
private func _accessibilityButNoFilesPolicy() -> MacControlPolicy {
    MacControlPolicy(
        enabled: true,
        categoryAllowed: ["accessibility_allowed": true, "file_ops_allowed": false],
        trustPolicy: MacControlTrustPolicy(
            outsideWorkspaceDefault: "allow",
            permissionLevel: "full_mac_os"
        )
    )
}

private func _object(_ value: JSONValue) -> [String: JSONValue] {
    if case .object(let o) = value { return o }
    return [:]
}

private func _string(_ value: JSONValue?) -> String? {
    if case .string(let s)? = value { return s }
    return nil
}

private func _bool(_ value: JSONValue?) -> Bool? {
    if case .bool(let b)? = value { return b }
    return nil
}

private func _int(_ value: JSONValue?) -> Int? {
    if case .int(let n)? = value { return Int(n) }
    return nil
}

/// A 24-line document behind a 5-line window that steps 4 lines: every scroll
/// leaves exactly one shared line, which is the seam the merge identifies on.
private func _longDocument(lines: Int = 24) -> [String] {
    (1...lines).map { "Clause \($0): the party of the \($0)th part agrees to the terms herein." }
}

@Test func readStopsWithoutRestorationWhenWindowOwnershipChanges() async throws {
    let viewport = _Viewport(document: _longDocument(), windowLines: 5, stepLines: 3)
    let source = _DocSource(viewport: viewport)
    let lostTarget = MacDocumentReadTakeover()
    source.targetIsCurrent = { !lostTarget.occurred }
    let sink = _ScrollSink(viewport: viewport)
    sink.onScroll = { lostTarget.mark() }
    let result = try await _readClient(source: source, sink: sink).dispatch(action: "read", body: [:])
    #expect(sink.recorded().scrolls.count == 1)
    #expect(_bool(_object(result.output)["scroll_restored"]) == false)
    #expect(_string(_object(result.output)["truncation_reason"]) == "scroll_target_changed")
}

@Test func readDoesNotAimOrScrollAnObscuredBackgroundTarget() async throws {
    let viewport = _Viewport(document: _longDocument(), windowLines: 5, stepLines: 3)
    let source = _DocSource(viewport: viewport)
    source.targetIsCurrent = { false }
    let sink = _ScrollSink(viewport: viewport)
    _ = try await _readClient(source: source, sink: sink).dispatch(action: "read", body: [:])
    #expect(sink.recorded().mice.isEmpty && sink.recorded().scrolls.isEmpty)
}

@Test func readCancellationStopsWheelAndRestoration() async {
    let viewport = _Viewport(document: _longDocument(), windowLines: 5, stepLines: 3)
    let source = _DocSource(viewport: viewport)
    let sink = _ScrollSink(viewport: viewport)
    sink.onScroll = { withUnsafeCurrentTask { $0?.cancel() } }
    let task = Task { try await _readClient(source: source, sink: sink).dispatch(action: "read", body: [:]) }
    _ = await task.result
    #expect(sink.recorded().scrolls.count == 1)
}

// MARK: - 1. It reconstructs the whole document

@Test
func read_accumulatesEveryLineAcrossScrollSeams_inOrder_withNoDuplicates() async throws {
    let document = _longDocument()
    // window 5 lines, step 4 lines → 20 points/line * 4 = the sink's mapping.
    let viewport = _Viewport(document: document, windowLines: 5, stepLines: 4)
    // Container height 100pt → step = 100 - max(40, 15) = 60pt = 3 lines at
    // 20pt/line. Two shared lines per seam; the merge must still be exact.
    let source = _DocSource(
        viewport: viewport,
        containerFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 100)
    )
    let sink = _ScrollSink(viewport: viewport)

    let result = try await _readClient(source: source, sink: sink).dispatch(action: "read", body: [:])
    let out = _object(result.output)

    #expect(result.ok, "\(out)")
    #expect(_string(out["source"]) == "screen")
    let text = try #require(_string(out["text"]))
    let got = text.components(separatedBy: "\n")

    #expect(got == document, "the document did not survive the merge:\n\(text)")
    #expect(_bool(out["gaps"]) == false, "a seam was missed: \(out)")
}

@Test
func read_stopsBecauseTheContentStopped_notBecauseACapBit() async throws {
    let viewport = _Viewport(document: _longDocument(), windowLines: 5, stepLines: 4)
    let source = _DocSource(viewport: viewport, containerFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 100))
    let sink = _ScrollSink(viewport: viewport)

    let out = _object(try await _readClient(source: source, sink: sink).dispatch(action: "read", body: [:]).output)

    #expect(_bool(out["reached_end"]) == true, "\(out)")
    #expect(_bool(out["truncated"]) == false, "\(out)")
    #expect(out["truncation_reason"] == nil, "nothing should have been cut: \(out)")
    let frames = try #require(_int(out["frames"]))
    #expect(frames > 1 && frames < MacDocumentRead.maxFrames, "frames=\(frames)")
}

// MARK: - 2. It puts the scroll position back

@Test
func read_scrollsBackToWhereItStarted_andSaysSoOnlyAfterChecking() async throws {
    let viewport = _Viewport(document: _longDocument(), windowLines: 5, stepLines: 4)
    let source = _DocSource(viewport: viewport, containerFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 100))
    let sink = _ScrollSink(viewport: viewport)

    let out = _object(try await _readClient(source: source, sink: sink).dispatch(action: "read", body: [:]).output)

    #expect(viewport.currentOffset() == 0, "the user's document was left scrolled: \(viewport.currentOffset())")
    #expect(_bool(out["scroll_restored"]) == true, "\(out)")
}

// MARK: - 3. THE TIER — what it is allowed to emit

@Test
func read_emitsOnlyVerticalScrollsAndTheCursorMoveThatAimsThem() async throws {
    let viewport = _Viewport(document: _longDocument(), windowLines: 5, stepLines: 4)
    let source = _DocSource(viewport: viewport, containerFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 100))
    let sink = _ScrollSink(viewport: viewport)

    _ = try await _readClient(source: source, sink: sink).dispatch(action: "read", body: [:])
    let events = sink.recorded()

    // NOT ONE keystroke. This organ is graded a read; a key event here would
    // make that grade a lie.
    #expect(events.keys.isEmpty, "read posted keyboard events: \(events.keys)")
    // Mouse: MOVES only. No down, no up, no drag — nothing that can click.
    #expect(
        events.mice.allSatisfy { $0.phase == .move },
        "read posted a non-move mouse event: \(events.mice.map(\.phase))"
    )
    #expect(events.mice.count <= 1, "one aim is enough: \(events.mice.count) moves")
    // Scrolls: VERTICAL only. A horizontal scroll over a slider changes its
    // value, which would be a mutation wearing a read's clothes.
    #expect(!events.scrolls.isEmpty)
    #expect(
        events.scrolls.allSatisfy { $0.deltaX == 0 && $0.modifiers.isEmpty },
        "read posted a horizontal or modified scroll: \(events.scrolls)"
    )
}

@Test
func read_isNeitherAReadActionNorAnInjectionAction_andIsGatedOnAccessibility() {
    #expect(macControlDispatchableActions.contains("read"))
    #expect(macControlDocumentReadActions == ["read"])
    #expect(macControlGateCategory(forAction: "read") == "accessibility")
    // If this ever fails, the organ grew a press or a keystroke and the tier
    // must move WITH it — see the comment on `macControlDocumentReadActions`.
    #expect(!macControlAccessibilityInjectionActions.contains("read"))
    // And it must not claim the read set's "no CGEvent" contract either.
    #expect(!macControlAccessibilityReadActions.contains("read"))
}

// MARK: - 4. The extract route: a real PDF

#if canImport(PDFKit) && canImport(AppKit) && os(macOS)
/// A genuine one-page PDF with a known sentence drawn into it.
private func _writeFixturePDF(_ sentence: String) throws -> URL {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    let attributed = NSAttributedString(
        string: sentence,
        attributes: [.font: NSFont.systemFont(ofSize: 14)]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 48, y: 700)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-read-fixture-\(UUID().uuidString).pdf")
    try (data as Data).write(to: url)
    return url
}

@Test
func read_extractsARealPDFsOwnCharacters_notAScrapeOfItsPixels() async throws {
    let sentence = "The tenant shall not sublet the premises without written consent."
    let url = try _writeFixturePDF(sentence)
    defer { try? FileManager.default.removeItem(at: url) }

    let viewport = _Viewport(document: ["irrelevant on-screen chrome"], windowLines: 1, stepLines: 1)
    let source = _DocSource(viewport: viewport)
    let sink = _ScrollSink(viewport: nil)
    let result = try await _readClient(source: source, sink: sink)
        .dispatch(action: "read", body: ["path": .string(url.path)])
    let out = _object(result.output)

    #expect(result.ok, "\(out)")
    #expect(_string(out["source"]) == "file")
    #expect(_int(out["document_pages"]) == 1, "\(out)")
    let text = try #require(_string(out["text"]))
    #expect(text.contains("sublet the premises"), "PDFKit did not yield the text: \(text)")
    // The extract route never touches the screen.
    #expect(sink.recorded().scrolls.isEmpty)
}

@Test
func read_findsTheDocumentTheFrontWindowNames_withNoPathGiven() async throws {
    let sentence = "Exhibit A lists every asset transferred at closing."
    let url = try _writeFixturePDF(sentence)
    defer { try? FileManager.default.removeItem(at: url) }

    let viewport = _Viewport(document: ["Preview toolbar"], windowLines: 1, stepLines: 1)
    let source = _DocSource(viewport: viewport, documentPath: url.path)
    let sink = _ScrollSink(viewport: nil)
    let out = _object(try await _readClient(source: source, sink: sink)
        .dispatch(action: "read", body: [:]).output)

    #expect(_string(out["source"]) == "file", "\(out)")
    #expect(_string(out["named_by"]) == "front_window", "\(out)")
    #expect(try #require(_string(out["text"])).contains("Exhibit A"))
}

@Test
func read_fallsBackToTheScreenWhenTheNamedDocumentCannotBeParsed() async throws {
    // The front window names a file this organ cannot read as text. The window
    // is still right there, so it reads THAT and says which file it gave up on.
    let viewport = _Viewport(document: ["Slide 1: revenue", "Slide 2: costs"], windowLines: 2, stepLines: 1)
    let source = _DocSource(viewport: viewport, documentPath: "/tmp/deck.key")
    let sink = _ScrollSink(viewport: viewport)
    let out = _object(try await _readClient(source: source, sink: sink)
        .dispatch(action: "read", body: [:]).output)

    #expect(_string(out["source"]) == "screen", "\(out)")
    let fallback = _object(out["fell_back_from"] ?? .null)
    #expect(_string(fallback["path"]) == "/tmp/deck.key", "\(out)")
    #expect(_string(fallback["reason"]) == "unsupported_document_type", "\(out)")
    #expect(try #require(_string(out["text"])).contains("revenue"))
}

@Test func readKeepsSelectedWindowWhenDocumentQueryChangesFocus() async throws {
    let viewport = _Viewport(document: ["Original document A"], windowLines: 1, stepLines: 1)
    let source = _DocSource(viewport: viewport, documentPath: "/tmp/unsupported.key")
    source.switchWindowDuringDocumentQuery = true
    let result = try await _readClient(source: source, sink: _ScrollSink(viewport: viewport))
        .dispatch(action: "read", body: [:])
    let output = _object(result.output)
    #expect(_string(output["text"])?.contains("Original document A") == true)
    #expect(output["fell_back_from"] == nil, "The racy legacy document-path query is not attributed to window A")
}
#endif

@Test
func read_extractsAPlainTextFileWhole() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-read-fixture-\(UUID().uuidString).md")
    let body = (1...400).map { "Line \($0) of a long note." }.joined(separator: "\n")
    try body.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let viewport = _Viewport(document: ["chrome"], windowLines: 1, stepLines: 1)
    let out = _object(try await _readClient(
        source: _DocSource(viewport: viewport),
        sink: _ScrollSink(viewport: nil)
    ).dispatch(action: "read", body: ["path": .string(url.path)]).output)

    #expect(_string(out["text"]) == body, "the file did not come back whole")
    #expect(_bool(out["truncated"]) == false)
}

// MARK: - 5. Refusals in words

@Test
func read_refusesAnUnreadableNamedFile_inWords() async throws {
    let viewport = _Viewport(document: ["chrome"], windowLines: 1, stepLines: 1)
    let result = try await _readClient(
        source: _DocSource(viewport: viewport),
        sink: _ScrollSink(viewport: nil)
    ).dispatch(action: "read", body: ["path": .string("/tmp/does-not-exist-\(UUID().uuidString).pdf")])
    let out = _object(result.output)

    #expect(!result.ok)
    #expect(result.error == "unreadable_document", "\(out)")
    let words = try #require(_string(out["message"]))
    #expect(words.contains("cannot make text out of it"), "\(words)")
}

@Test
func read_refusesAnUnsupportedNamedFile_inWords_andNamesWhatItCanRead() async throws {
    let viewport = _Viewport(document: ["chrome"], windowLines: 1, stepLines: 1)
    let result = try await _readClient(
        source: _DocSource(viewport: viewport),
        sink: _ScrollSink(viewport: nil)
    ).dispatch(action: "read", body: ["path": .string("/tmp/photo.heic")])
    let out = _object(result.output)

    #expect(result.error == "unsupported_document_type", "\(out)")
    let words = try #require(_string(out["message"]))
    #expect(words.contains("PDFs and plain-text files"), "\(words)")
}

@Test
func read_refusesASecureFieldInWords_andReadsNoCharacterOfIt() async throws {
    // A window whose only content is a password box.
    let viewport = _Viewport(document: [], windowLines: 0, stepLines: 1)
    let source = _DocSource(viewport: viewport, extraRoles: ["AXSecureTextField"])
    let sink = _ScrollSink(viewport: viewport)
    let result = try await _readClient(source: source, sink: sink).dispatch(action: "read", body: [:])
    let out = _object(result.output)

    #expect(!result.ok)
    #expect(result.error == "secure_content", "\(out)")
    let words = try #require(_string(out["message"]))
    #expect(words.contains("password box"), "\(words)")
    #expect(!words.contains("should never be read"))
    // And it did not start scrolling a password field around.
    #expect(sink.recorded().scrolls.isEmpty)
}

@Test
func read_refusesAWindowWithNoText_inWords_andPointsAtScreen() async throws {
    let viewport = _Viewport(document: [], windowLines: 0, stepLines: 1)
    let result = try await _readClient(
        source: _DocSource(viewport: viewport),
        sink: _ScrollSink(viewport: viewport)
    ).dispatch(action: "read", body: [:])
    let out = _object(result.output)

    #expect(result.error == "no_readable_text", "\(out)")
    #expect(try #require(_string(out["message"])).contains("look at the screen"))
}

@Test
func read_refusesWithoutTheAccessibilityGrant_inWords() async throws {
    final class Untrusted: MacAXElementSource, @unchecked Sendable {
        func isTrusted() -> Bool { false }
        func frontmostApp() -> MacAXAppInfo? { nil }
        func frontmostWindowRoot() -> MacAXElementRef? { nil }
        func attributes(of element: MacAXElementRef) -> MacAXAttributes? { nil }
        func children(of element: MacAXElementRef) -> [MacAXElementRef] { [] }
    }
    let result = try await _readClient(
        source: Untrusted(),
        sink: _ScrollSink(viewport: nil)
    ).dispatch(action: "read", body: [:])

    #expect(result.error == "accessibility_not_trusted")
    #expect(try #require(_string(_object(result.output)["note"])).contains("System Settings"))
}

@Test
func read_saysSoWhenItCannotScroll_ratherThanPassingOneScreenfulOffAsTheDocument() async throws {
    let viewport = _Viewport(document: _longDocument(), windowLines: 5, stepLines: 4)
    let source = _DocSource(viewport: viewport, containerFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 100))
    let sink = _ScrollSink(viewport: viewport, available: false)
    let out = _object(try await _readClient(source: source, sink: sink).dispatch(action: "read", body: [:]).output)

    #expect(_bool(out["scrollable"]) == false, "\(out)")
    #expect(try #require(_string(out["message"])).contains("cannot scroll it"))
    #expect(_bool(out["reached_end"]) == false, "an unscrolled read must not claim the end: \(out)")
}

// MARK: - 6. The redaction boundary, on accumulated text

@Test
func read_redactsASecretLineInTheAccumulatedText_andLeavesTheProseAlone() async throws {
    var document = _longDocument(lines: 10)
    document.insert("sk-live-9f2ab7c41de85630bb14aa02cf7e91d4", at: 5)
    let viewport = _Viewport(document: document, windowLines: 5, stepLines: 3)
    let source = _DocSource(viewport: viewport, containerFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 100))
    let out = _object(try await _readClient(
        source: source,
        sink: _ScrollSink(viewport: viewport)
    ).dispatch(action: "read", body: [:]).output)

    let text = try #require(_string(out["text"]))
    #expect(_bool(out["redacted"]) == true, "\(out)")
    #expect(!text.contains("sk-live-9f2ab7c41de85630bb14aa02cf7e91d4"), "a live key crossed the boundary: \(text)")
    #expect(text.contains("[redacted:"), "redaction must be visible, not a silent gap: \(text)")
    // THE OTHER HALF: over-redaction blinds this organ silently.
    #expect(text.contains("Clause 1:"), "\(text)")
    #expect(text.contains("Clause 10:"), "\(text)")
}

// MARK: - 7. The merge itself (pure)

@Test
func accumulator_mergesOnTheLongestSharedRun_notOnASeenSet() {
    var accumulator = MacDocumentRead.Accumulator()
    _ = accumulator.absorb(["a", "b", "c"])
    _ = accumulator.absorb(["b", "c", "d"])
    #expect(accumulator.lines == ["a", "b", "c", "d"])
}

@Test
func accumulator_keepsARepeatedLineThatIsGenuinelyRepeatedLater() {
    // A set-based dedupe eats the second "Signed:" and guts the document.
    var accumulator = MacDocumentRead.Accumulator()
    _ = accumulator.absorb(["Signed:", "Alice", "Bob"])
    _ = accumulator.absorb(["Bob", "Charlie", "Signed:"])
    #expect(accumulator.lines == ["Signed:", "Alice", "Bob", "Charlie", "Signed:"])
}

@Test
func accumulator_seesThroughAStickyHeaderThatIsRedrawnEveryFrame() {
    var accumulator = MacDocumentRead.Accumulator()
    _ = accumulator.absorb(["HEADER", "one", "two"])
    let absorbed = accumulator.absorb(["HEADER", "two", "three"])
    #expect(accumulator.lines == ["HEADER", "one", "two", "three"], "\(accumulator.lines)")
    #expect(absorbed == .added(1))
    #expect(accumulator.sawGap == false)
}

@Test
func accumulator_reportsAGapRatherThanPretendingTwoFramesWereContiguous() {
    var accumulator = MacDocumentRead.Accumulator()
    _ = accumulator.absorb(["one", "two"])
    let absorbed = accumulator.absorb(["nine", "ten"])
    #expect(absorbed == .addedWithGap(2))
    #expect(accumulator.sawGap)
}

@Test
func accumulator_callsAnUnchangedFrameTheEnd() {
    var accumulator = MacDocumentRead.Accumulator()
    _ = accumulator.absorb(["one", "two"])
    #expect(accumulator.absorb(["one", "two"]) == .nothingNew)
}

@Test
func scrollStep_alwaysLeavesAnOverlapBandSoTheMergeHasASeam() {
    for height in [60.0, 200.0, 600.0, 1_400.0, 4_000.0] {
        let step = Double(MacDocumentRead.scrollStepPoints(viewportHeight: height))
        #expect(step < height || height <= 80, "a full-viewport step leaves no seam at h=\(height)")
        #expect(step > 0)
    }
}

// MARK: - 8. `look`'s budgets are UNTOUCHED

@Test
func read_didNotRaiseASingleOneOfLooksBudgets() {
    // Item 33 exists BECAUSE these caps make a document unreadable. The fix was
    // a separate organ with its own caps — not a wider glance. If a future edit
    // is tempted to raise one of these to make `read` easier, this is the line
    // that says no.
    #expect(MacPerceptionCompiler.lookByteBudget == 6144)
    #expect(MacPerceptionCompiler.maxReadouts == 12)
    #expect(MacPerceptionCompiler.affordanceValueChars == 40)
    #expect(MacPerceptionCompiler.glanceMaxChars == 220)
    #expect(MacAXLimits.hardMaxNodes == 400)
    #expect(MacAXLimits.hardMaxDepth == 12)
    #expect(MacAXLimits.hardValueChars == 200)
    // And the read organ's own caps are its own — strictly larger, and living
    // in its own file.
    #expect(MacDocumentRead.maxNodesPerFrame > MacAXLimits.hardMaxNodes)
    #expect(MacDocumentRead.maxCharsPerNode > MacAXLimits.hardValueChars)
}

// MARK: - 9. The sensitive-path fence is not exempted by the word "document"

@Test
func read_refusesASensitivePath_inWords_evenThoughItIsATextFile() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let viewport = _Viewport(document: ["chrome"], windowLines: 1, stepLines: 1)
    for path in ["\(home)/.ssh/known_hosts", "\(home)/Library/Keychains/notes.txt"] {
        let result = try await _readClient(
            source: _DocSource(viewport: viewport),
            sink: _ScrollSink(viewport: nil)
        ).dispatch(action: "read", body: ["path": .string(path)])
        #expect(result.error == "sensitive_path_denied", "\(path): \(result.output)")
        let words = try #require(_string(_object(result.output)["message"]))
        #expect(words.contains("keys, credentials"), "\(words)")
    }
    // And the workspace file policy sees this organ's path at all — without
    // this key a document read would be the one door the policy never covered.
    #expect(macControlFilePolicyPathKeys(forAction: "read") == ["path"])
}

// MARK: - 10. gpt-5.5 review: an AX-inferred path is still a file read

@Test
func read_doesNotOpenAnAXInferredFileWithoutTheFileGate_andSaysItReadTheWindowInstead() async throws {
    // THE BUG THIS PINS. With no `path`, the tool layer clears only the
    // accessibility category — and the window then handed a FILESYSTEM PATH to
    // the extractor, which opened it. A call with no path got a file read a
    // call WITH one could not have got.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-inferred-\(UUID().uuidString).md")
    try "SECRET FROM THE FILE ON DISK".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let viewport = _Viewport(document: ["what the window itself shows"], windowLines: 1, stepLines: 1)
    let source = _DocSource(viewport: viewport, documentPath: url.path)
    let result = try await _readClient(
        source: source,
        sink: _ScrollSink(viewport: viewport),
        policyProvider: _FixedPolicy(policy: _accessibilityButNoFilesPolicy())
    ).dispatch(action: "read", body: [:])
    let out = _object(result.output)

    // It fell back to AX accumulation — and the file's bytes never appeared.
    #expect(_string(out["source"]) == "screen", "\(out)")
    #expect(try #require(_string(out["text"])).contains("what the window itself shows"))
    #expect(!(try #require(_string(out["text"])).contains("SECRET FROM THE FILE ON DISK")), "\(out)")
    // And it said so, rather than silently returning less than it was asked for.
    let declined = _object(out["file_route_declined"] ?? .null)
    #expect(_string(declined["path"]) == url.path, "\(out)")
    #expect(try #require(_string(declined["reason"])).hasPrefix("category_disabled"), "\(out)")
    #expect(try #require(_string(declined["words"])).contains("file access"), "\(out)")
}

@Test
func read_stillTakesTheFileRouteWhenTheFileGateIsOpen() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-inferred-ok-\(UUID().uuidString).md")
    try "THE DOCUMENT'S OWN CHARACTERS".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    var policy = _accessibilityButNoFilesPolicy()
    policy.categoryAllowed["file_ops_allowed"] = true

    let viewport = _Viewport(document: ["chrome"], windowLines: 1, stepLines: 1)
    let out = _object(try await _readClient(
        source: _DocSource(viewport: viewport, documentPath: url.path),
        sink: _ScrollSink(viewport: nil),
        policyProvider: _FixedPolicy(policy: policy)
    ).dispatch(action: "read", body: [:]).output)

    #expect(_string(out["source"]) == "file", "\(out)")
    #expect(_string(out["named_by"]) == "front_window", "\(out)")
    #expect(try #require(_string(out["text"])).contains("THE DOCUMENT'S OWN CHARACTERS"))
    #expect(out["file_route_declined"] == nil, "\(out)")
}

// MARK: - 11. gpt-5.5 review: `app` names whose window, and activates nothing

@Test
func read_readsANamedAppsWindow_withoutActivatingAnything() async throws {
    let viewport = _Viewport(document: _longDocument(lines: 8), windowLines: 4, stepLines: 3)
    let sink = _ScrollSink(viewport: viewport)
    let out = _object(try await _readClient(source: _DocSource(viewport: viewport), sink: sink)
        .dispatch(action: "read", body: ["app": .string("Preview")]).output)

    #expect(_string(out["source"]) == "screen", "\(out)")
    #expect(try #require(_string(out["text"])).contains("Clause 1"))
    // The emission set is unchanged by naming an app: still only the wheel and
    // the one move that aims it. Nothing focuses, raises or launches.
    let recorded = sink.recorded()
    #expect(recorded.keys.isEmpty, "read pressed a key")
    #expect(recorded.mice.allSatisfy { $0.phase == .move }, "read clicked something")
}

@Test
func read_refusesAnAppThatIsNotRunning_inWords_andReadsNothing() async throws {
    let viewport = _Viewport(document: ["a document"], windowLines: 1, stepLines: 1)
    let sink = _ScrollSink(viewport: viewport)
    let result = try await _readClient(source: _DocSource(viewport: viewport), sink: sink)
        .dispatch(action: "read", body: ["app": .string("Sketchbook")])

    #expect(!result.ok)
    #expect(result.error == "app_not_running", "\(result.output)")
    let words = try #require(_string(_object(result.output)["message"]))
    #expect(words.contains("Sketchbook"), "\(words)")
    // A refusal that read nothing also SCROLLED nothing.
    #expect(sink.recorded().scrolls.isEmpty)
}

// MARK: - 12. gpt-5.5 review: the read organ carries its own clock

@Test
func read_isBoundedInTimeEvenThoughItSkipsTheOperationStoresDeadline() {
    // `read` is deliberately a LIVE read (a replayable operation record would
    // answer with a document that has since changed), which left it with no
    // bound at all. Both bounds are pinned here because neither is visible at
    // runtime until an app stops answering.
    #expect(macControlDocumentReadActions.contains("read"))
    #expect(MacDocumentRead.deadlineSeconds > 0 && MacDocumentRead.deadlineSeconds <= 60)
    #expect(MacDocumentRead.axMessagingTimeoutSeconds > 0
            && MacDocumentRead.axMessagingTimeoutSeconds <= 5)
    // The per-call timeout is set on ONE APP's element, never process-wide:
    // exactly one organ in this app may retune the global, and it is not this
    // one (ActivityWatchArchitectureTests pins the other side of that).
    let compiler = try? String(
        contentsOfFile: "Modules/NativeAgentCore/Sources/MacControl/MacPerceptionCompiler.swift",
        encoding: .utf8
    )
    if let compiler {
        #expect(compiler.contains("AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(pid)"))
        #expect(!compiler.contains("AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide"))
    }
    // And the two words the clock can produce exist, so a caller is never left
    // guessing whether a short answer was the document or the deadline.
    #expect(MacDocumentRead.timedOutWords(app: "Preview").contains("Preview"))
    #expect(MacDocumentRead.deadlineWords(app: "Preview").contains("not the whole thing"))
}
