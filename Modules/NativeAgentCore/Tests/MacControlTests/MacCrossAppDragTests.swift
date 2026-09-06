import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - CROSS-APP ACT (fable51 sweep item 32b)
//
// `act(drag, target: "report.pdf", to: "Standup notes", to_app: "Mail")` —
// one drag whose two ends live in two different windows. Four things these
// tests exist to hold, and they are the four ways this can go wrong on User's
// real screen:
//
//   1. RESOLUTION COSTS NO FOCUS. The destination is named in Mail's window
//      through the background sight; nothing is activated while it is being
//      found. Every refusal below therefore happens with his screen untouched.
//   2. THE RAISE IS ON THE RECEIPT. Focus moving is a visible cost. It happens
//      once, only when the drop needs it, and both the sentence and the detail
//      say which app came forward and why.
//   3. REFUSALS ARE SENTENCES. Not running, ambiguous, our own process, no
//      such thing in that window, a raise that would bury the source, a path
//      across a password field — each has words and none sends input.
//   4. THE SINGLE-WINDOW DRAG IS UNTOUCHED. With `to_app` absent nothing in
//      this file's code path runs.
//
// Synthetic AX seams throughout — two apps, two framed trees, no window
// server, no real pointer.

private struct _XElement {
    var attributes: MacAXAttributes?
    var children: [Int]
}

/// Two apps with FRAMED trees, so a drag has real physical points to aim at,
/// and an anchor probe that records how much focus had moved by the time each
/// window was walked.
private final class _XSource: MacAXElementSource, @unchecked Sendable {
    struct App {
        let info: MacAXAppInfo
        let elements: [Int: _XElement]
        let rootID: Int
    }

    private let lock = NSLock()
    private let apps: [App]
    private var frontIndex: Int
    /// (pid walked, focus requests that had ALREADY been made at that moment).
    private var anchorProbes: [(pid: Int32, focusRequestsSoFar: Int)] = []
    /// Set by the harness once the app-control double exists.
    var focusRequestCount: @Sendable () -> Int = { 0 }

    init(apps: [App], frontIndex: Int = 0) {
        self.apps = apps
        self.frontIndex = frontIndex
    }

    private func app(pid: Int32) -> App? { apps.first { $0.info.processIdentifier == pid } }

    private func ref(pid: Int32, local: Int) -> MacAXElementRef {
        MacAXElementRef(id: Int(pid) * 10_000 + local)
    }

    private func decode(_ ref: MacAXElementRef) -> (pid: Int32, local: Int) {
        (Int32(ref.id / 10_000), ref.id % 10_000)
    }

    func isTrusted() -> Bool { true }

    func frontmostApp() -> MacAXAppInfo? {
        lock.lock(); defer { lock.unlock() }
        return apps[frontIndex].info
    }

    func frontmostWindowRoot() -> MacAXElementRef? {
        lock.lock()
        let front = apps[frontIndex]
        lock.unlock()
        return ref(pid: front.info.processIdentifier, local: front.rootID)
    }

    func windowRoot(pid: Int32) -> MacAXElementRef? {
        let moved = focusRequestCount()
        lock.lock(); anchorProbes.append((pid, moved)); lock.unlock()
        guard let hit = app(pid: pid) else { return nil }
        return ref(pid: pid, local: hit.rootID)
    }

    func appInfo(pid: Int32) -> MacAXAppInfo? { app(pid: pid)?.info }

    func runningApps() -> [MacAXAppInfo] { apps.map(\.info) }

    func attributes(of element: MacAXElementRef) -> MacAXAttributes? {
        let (pid, local) = decode(element)
        return app(pid: pid)?.elements[local]?.attributes
    }

    func children(of element: MacAXElementRef) -> [MacAXElementRef] {
        let (pid, local) = decode(element)
        guard let hit = app(pid: pid) else { return [] }
        return (hit.elements[local]?.children ?? []).map { ref(pid: pid, local: $0) }
    }

    func focusedElementPath() -> [Int]? { nil }

    func bringToFront(named name: String) {
        lock.lock(); defer { lock.unlock() }
        if let index = apps.firstIndex(where: { $0.info.name == name }) { frontIndex = index }
    }

    func frontName() -> String {
        lock.lock(); defer { lock.unlock() }
        return apps[frontIndex].info.name
    }

    func probes() -> [(pid: Int32, focusRequestsSoFar: Int)] {
        lock.lock(); defer { lock.unlock() }
        return anchorProbes
    }
}

private final class _XAppControl: AppControlAdapter, AppStateVerificationAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var focusRequests: [String] = []
    /// Flips the AX source's frontmost app, exactly as a real activation does.
    var onFocused: (@Sendable (String) -> Void)?
    var frontName: @Sendable () -> String = { "" }

    func focusApp(named name: String) async throws -> AppControlRunResult {
        lock.withLock { focusRequests.append(name) }
        onFocused?(name)
        return AppControlRunResult(
            requestedName: name, matchedName: name, bundleIdentifier: nil,
            processIdentifier: 1, launched: false, activated: true, terminated: false
        )
    }

    func quitApp(named name: String) async throws -> AppControlRunResult {
        AppControlRunResult(
            requestedName: name, matchedName: name, bundleIdentifier: nil,
            processIdentifier: nil, launched: false, activated: false, terminated: true
        )
    }

    func isFrontmostApplication(matching name: String) async -> Bool { frontName() == name }
    func isApplicationRunning(matching name: String) async -> Bool { true }

    func requests() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return focusRequests
    }
}

private final class _XEventSink: MacEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var mouseEvents: [MacMouseEvent] = []
    var isAvailable: Bool { true }
    func post(key: MacKeyEvent) {}
    func post(mouse: MacMouseEvent) { lock.withLock { mouseEvents.append(mouse) } }
    func post(scroll: MacScrollEvent) {}
    func mice() -> [MacMouseEvent] { lock.withLock { mouseEvents } }
}

private struct _XRow {
    let label: String
    let frame: MacAXFrame
}

private func _xApp(
    name: String,
    bundle: String,
    pid: Int32,
    windowTitle: String,
    rows: [_XRow],
    secureField: (label: String, frame: MacAXFrame)? = nil,
    /// The WINDOW's own rectangle, which `windowRoots(pid:)` publishes as the
    /// window identity's frame and the look then hands to `Sighting`. Absent by
    /// default so every existing case still exercises the union-of-targets
    /// fallback; given, it is what the coverage guard must ask.
    windowFrame: MacAXFrame? = nil
) -> _XSource.App {
    var elements: [Int: _XElement] = [:]
    var rowIDs: [Int] = []
    for (index, row) in rows.enumerated() {
        let id = 100 + index
        rowIDs.append(id)
        elements[id] = _XElement(
            attributes: MacAXAttributes(
                role: "AXRow", title: row.label, frame: row.frame, actions: ["AXPress"]
            ),
            children: []
        )
    }
    elements[1] = _XElement(
        attributes: MacAXAttributes(role: "AXList", title: "items"),
        children: rowIDs
    )
    var windowChildren = [1]
    if let secureField {
        elements[2] = _XElement(
            attributes: MacAXAttributes(
                role: "AXSecureTextField", title: secureField.label,
                frame: secureField.frame, actions: ["AXPress"]
            ),
            children: []
        )
        windowChildren.append(2)
    }
    elements[0] = _XElement(
        attributes: MacAXAttributes(role: "AXWindow", title: windowTitle, frame: windowFrame),
        children: windowChildren
    )
    return _XSource.App(
        info: MacAXAppInfo(name: name, bundleIdentifier: bundle, processIdentifier: pid),
        elements: elements,
        rootID: 0
    )
}

private struct _XHarness {
    let source: _XSource
    let control: _XAppControl
    let sink: _XEventSink
    let verbs: MacFourVerbs
}

/// Finder in front on the left, Mail behind on the right. The two windows do
/// not overlap, which is the ordinary arrangement a person drags between.
private func _xHarness(
    apps: [_XSource.App]? = nil,
    frontIndex: Int = 0
) -> _XHarness {
    let source = _XSource(
        apps: apps ?? [
            _xApp(
                name: "Finder", bundle: "com.apple.finder", pid: 501,
                windowTitle: "Documents",
                rows: [
                    _XRow(label: "report.pdf", frame: MacAXFrame(x: 20, y: 100, w: 200, h: 20)),
                    _XRow(label: "notes.md", frame: MacAXFrame(x: 20, y: 130, w: 200, h: 20)),
                ]
            ),
            _xApp(
                name: "Mail", bundle: "com.apple.mail", pid: 777,
                windowTitle: "New Message",
                rows: [
                    _XRow(label: "Invoice from Acme", frame: MacAXFrame(x: 620, y: 100, w: 200, h: 20)),
                    _XRow(label: "Standup notes", frame: MacAXFrame(x: 620, y: 130, w: 200, h: 20)),
                ]
            ),
        ],
        frontIndex: frontIndex
    )
    let control = _XAppControl()
    let sink = _XEventSink()
    control.onFocused = { [source] name in source.bringToFront(named: name) }
    control.frontName = { [source] in source.frontName() }
    source.focusRequestCount = { [control] in control.requests().count }
    let client = SwiftNativeMacControl(
        appControlAdapter: control,
        accessibilitySource: source,
        eventSink: sink,
        screenCaptureSource: UnavailableMacScreenCaptureSource(),
        screenViewStore: MacScreenViewStore(),
        lookFrameStore: MacLookFrameStore()
    )
    return _XHarness(source: source, control: control, sink: sink, verbs: MacFourVerbs(host: client))
}

// MARK: - 1. The pure decisions

@Test
func crossAppDrag_raiseIsDecidedByTheMeasuredFrontFact() {
    let behind = MacCrossAppDrag.raise(destinationApp: "Mail", destinationIsFront: false)
    #expect(behind.needed)
    #expect(behind.reason == MacCrossAppDrag.raiseReasonDropNeedsWindow)
    // The sentence must carry the app AND the reason. "Focus moved" with no
    // why is the thing this whole receipt exists to prevent.
    #expect(behind.words.contains("Mail"))
    #expect(behind.words.lowercased().contains("front"))

    let alreadyThere = MacCrossAppDrag.raise(destinationApp: "Mail", destinationIsFront: true)
    #expect(!alreadyThere.needed)
    #expect(alreadyThere.reason == MacCrossAppDrag.raiseReasonAlreadyFront)
    #expect(alreadyThere.words.contains("focus did not move"))
}

@Test
func crossAppDrag_boundsAreTheUnionOfWhatWasActuallyRead() {
    #expect(MacCrossAppDrag.bounds(of: []) == nil)
    // Degenerate frames are not evidence of a window and must not widen one.
    #expect(MacCrossAppDrag.bounds(of: [MacAXFrame(x: 0, y: 0, w: 0, h: 10)]) == nil)
    let box = MacCrossAppDrag.bounds(of: [
        MacAXFrame(x: 620, y: 100, w: 200, h: 20),
        MacAXFrame(x: 600, y: 300, w: 100, h: 40),
    ])
    #expect(box == MacAXFrame(x: 600, y: 100, w: 220, h: 240))
}

@Test
func crossAppDrag_anUnknownWindowBoxNeverBecomesARefusal() {
    let point = MacPointerPosition(x: 120, y: 110)!
    #expect(!MacCrossAppDrag.raiseWouldCoverSource(point, destinationBounds: nil))
    #expect(MacCrossAppDrag.raiseWouldCoverSource(
        point, destinationBounds: MacAXFrame(x: 100, y: 100, w: 300, h: 300)
    ))
    #expect(!MacCrossAppDrag.raiseWouldCoverSource(
        point, destinationBounds: MacAXFrame(x: 600, y: 0, w: 300, h: 300)
    ))
}

@Test
func crossAppDrag_secureKindTracksTheRenderer() {
    // Spelling "secure text" here by hand is how these two drift apart.
    #expect(MacCrossAppDrag.secureKind == MacScreenRender.kindName(role: "AXSecureTextField"))
    #expect(MacCrossAppDrag.isSecureKind(MacCrossAppDrag.secureKind))
    #expect(!MacCrossAppDrag.isSecureKind("row"))
    // The receipt reads the same whether typing or the pointer hit it.
    #expect(MacCrossAppDrag.secureCrossingReason == MacActClosedLoop.secureFieldReason)
}

// MARK: - 2. Two anchors, resolved without a focus steal

@Test
func crossAppDrag_resolvesBothEndsWithoutActivatingAnything() async {
    let harness = _xHarness()
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "Standup notes", toApp: "Mail", seconds: 0
    )

    #expect(reply.ok, "\(reply.text)")
    // Mail's window really was walked…
    let probes = harness.source.probes()
    let mailProbe = probes.first { $0.pid == 777 }
    #expect(mailProbe != nil, "Mail's window was never anchored: \(probes)")
    // …and NOTHING had been activated at the moment it was read. This is the
    // whole difference from `go Mail`: a refusal after this point costs User
    // nothing, because his screen has not moved yet.
    #expect(mailProbe?.focusRequestsSoFar == 0,
            "the destination was resolved after a focus steal: \(probes)")

    // One drag, from Finder's row centre to Mail's row centre.
    let mice = harness.sink.mice()
    #expect(mice.first?.phase == .down)
    #expect(mice.last?.phase == .up)
    #expect(mice.first?.x == 120 && mice.first?.y == 110)
    #expect(mice.last?.x == 720 && mice.last?.y == 140)
}

@Test
func crossAppDrag_recordsTheRaiseInTheReceiptAndSaysWhyFocusMoved() async {
    let harness = _xHarness()
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "Standup notes", toApp: "Mail", seconds: 0
    )

    #expect(reply.ok, "\(reply.text)")
    // ONE raise, of the app that had to receive the drop.
    #expect(harness.control.requests() == ["Mail"], "\(harness.control.requests())")

    // The receipt.
    #expect(reply.detail["cross_app_drag"] == .bool(true))
    #expect(reply.detail["destination_app"] == .string("Mail"))
    #expect(reply.detail["destination_app_bundle"] == .string("com.apple.mail"))
    #expect(reply.detail["destination_resolved_without_focus"] == .bool(true))
    #expect(reply.detail["raised"] == .bool(true))
    #expect(reply.detail["raised_app"] == .string("Mail"))
    #expect(reply.detail["raise_reason"] == .string(MacCrossAppDrag.raiseReasonDropNeedsWindow))

    // And the WORDS, because the receipt is not what User reads when his window
    // flips: the first line must name both ends and explain the flip.
    let first = reply.text.split(separator: "\n").first.map(String.init) ?? ""
    #expect(first.contains("report.pdf"), "\(first)")
    #expect(first.contains("Standup notes"), "\(first)")
    #expect(first.contains("into Mail"), "\(first)")
    #expect(first.contains("brought Mail to the front"), "\(first)")
}

@Test
func crossAppDrag_doesNotRaiseWhenTheDestinationIsAlreadyInFront() async {
    // Mail in front; both ends of the drag are in Mail's own window, named
    // through the two-anchor form. A raise here would move focus for nothing.
    let harness = _xHarness(frontIndex: 1)
    let reply = await harness.verbs.act(
        verb: "drag", target: "Invoice from Acme", to: "Standup notes", toApp: "Mail", seconds: 0
    )

    #expect(reply.ok, "\(reply.text)")
    #expect(harness.control.requests().isEmpty,
            "nothing needed raising: \(harness.control.requests())")
    #expect(reply.detail["raised"] == .bool(false))
    #expect(reply.detail["raise_reason"] == .string(MacCrossAppDrag.raiseReasonAlreadyFront))
    #expect(reply.text.contains("focus did not move"), "\(reply.text)")
}

// MARK: - 3. Refusals, in words, with nothing raised and nothing posted

@Test
func crossAppDrag_refusesInWordsWhenTheDestinationAppIsAmbiguous() async {
    let harness = _xHarness(apps: [
        _xApp(name: "Finder", bundle: "com.apple.finder", pid: 501, windowTitle: "Documents",
              rows: [_XRow(label: "report.pdf", frame: MacAXFrame(x: 20, y: 100, w: 200, h: 20))]),
        _xApp(name: "Notes", bundle: "com.apple.Notes", pid: 777, windowTitle: "All Notes",
              rows: [_XRow(label: "Standup notes", frame: MacAXFrame(x: 620, y: 100, w: 200, h: 20))]),
        _xApp(name: "Notion", bundle: "so.notion.desktop", pid: 888, windowTitle: "Workspace",
              rows: [_XRow(label: "Inbox", frame: MacAXFrame(x: 620, y: 300, w: 200, h: 20))]),
    ])
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "Standup notes", toApp: "Not", seconds: 0
    )

    #expect(!reply.ok)
    // Guessing which window she meant is the failure the whole organ avoids.
    #expect(reply.text.contains("Notes"), "\(reply.text)")
    #expect(reply.text.contains("Notion"), "\(reply.text)")
    #expect(reply.text.contains("haven't raised anything"), "\(reply.text)")
    #expect(harness.control.requests().isEmpty)
    #expect(harness.sink.mice().isEmpty, "an ambiguous app must not post input")
}

@Test
func crossAppDrag_refusesInWordsWhenNothingByThatNameIsRunning() async {
    let harness = _xHarness()
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "Standup notes", toApp: "Photoshop", seconds: 0
    )

    #expect(!reply.ok)
    #expect(reply.text.contains("Photoshop"), "\(reply.text)")
    // What IS running, so the model does not retry the same spelling forever.
    #expect(reply.text.contains("Mail") || reply.text.contains("Finder"), "\(reply.text)")
    #expect(harness.control.requests().isEmpty, "a refusal must not have launched anything")
    #expect(harness.sink.mice().isEmpty)
}

@Test
func crossAppDrag_refusesWhenTheDestinationIsNotInThatWindow() async {
    let harness = _xHarness()
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "Trash", toApp: "Mail", seconds: 0
    )

    #expect(!reply.ok)
    #expect(reply.detail["error"] == .string(MacCrossAppDrag.unresolvedDestinationReason))
    // Say WHOSE window was searched, and what it actually shows.
    #expect(reply.text.contains("Mail's front window"), "\(reply.text)")
    #expect(reply.text.contains("Standup notes"), "\(reply.text)")
    #expect(harness.control.requests().isEmpty)
    #expect(harness.sink.mice().isEmpty)
}

@Test
func crossAppDrag_refusesWhenTheSourceIsNotOnTheScreenInFront() async {
    let harness = _xHarness()
    let reply = await harness.verbs.act(
        verb: "drag", target: "nothing like this", to: "Standup notes", toApp: "Mail", seconds: 0
    )

    #expect(!reply.ok)
    #expect(reply.detail["error"] == .string("no_match"))
    // An unresolvable SOURCE must fail before Mail's window is ever walked:
    // the cheapest refusal is the one that reads nothing extra.
    #expect(!harness.source.probes().contains { $0.pid == 777 })
    #expect(harness.control.requests().isEmpty)
    #expect(harness.sink.mice().isEmpty)
}

@Test
func crossAppDrag_refusesWhenTheDragPathCrossesAPasswordField() async {
    let harness = _xHarness(apps: [
        _xApp(
            name: "Finder", bundle: "com.apple.finder", pid: 501, windowTitle: "Documents",
            rows: [_XRow(label: "report.pdf", frame: MacAXFrame(x: 20, y: 100, w: 200, h: 20))],
            // A password box sitting on the line from (120,110) to (720,140).
            secureField: ("Password", MacAXFrame(x: 300, y: 100, w: 80, h: 40))
        ),
        _xApp(
            name: "Mail", bundle: "com.apple.mail", pid: 777, windowTitle: "New Message",
            rows: [_XRow(label: "Standup notes", frame: MacAXFrame(x: 620, y: 130, w: 200, h: 20))]
        ),
    ])
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "Standup notes", toApp: "Mail", seconds: 0
    )

    #expect(!reply.ok)
    #expect(reply.detail["error"] == .string(MacCrossAppDrag.secureCrossingReason))
    #expect(reply.text.contains("password field"), "\(reply.text)")
    // Refused ABOVE the raise, so his screen never moved for it.
    #expect(harness.control.requests().isEmpty)
    #expect(harness.sink.mice().isEmpty)
}

@Test
func crossAppDrag_refusesToDropIntoAPasswordField() async {
    let harness = _xHarness(apps: [
        _xApp(name: "Finder", bundle: "com.apple.finder", pid: 501, windowTitle: "Documents",
              rows: [_XRow(label: "report.pdf", frame: MacAXFrame(x: 20, y: 100, w: 200, h: 20))]),
        _xApp(
            name: "Vault", bundle: "com.example.vault", pid: 777, windowTitle: "Unlock",
            rows: [_XRow(label: "Account", frame: MacAXFrame(x: 620, y: 300, w: 200, h: 20))],
            secureField: ("Master key", MacAXFrame(x: 620, y: 100, w: 200, h: 24))
        ),
    ])
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "Master key", toApp: "Vault", seconds: 0
    )

    #expect(!reply.ok)
    #expect(reply.detail["error"] == .string(MacCrossAppDrag.secureCrossingReason))
    #expect(reply.text.contains("credential box"), "\(reply.text)")
    #expect(harness.control.requests().isEmpty)
    #expect(harness.sink.mice().isEmpty)
}

@Test
func crossAppDrag_refusesWhenRaisingWouldBuryTheThingBeingPickedUp() async {
    let harness = _xHarness(apps: [
        _xApp(name: "Finder", bundle: "com.apple.finder", pid: 501, windowTitle: "Documents",
              rows: [_XRow(label: "report.pdf", frame: MacAXFrame(x: 20, y: 100, w: 200, h: 20))]),
        // Mail's window lies ON TOP of Finder's row. Raising it would put the
        // mouse-down on Mail instead of on the file.
        _xApp(name: "Mail", bundle: "com.apple.mail", pid: 777, windowTitle: "New Message",
              rows: [
                _XRow(label: "Invoice from Acme", frame: MacAXFrame(x: 100, y: 100, w: 300, h: 100)),
                _XRow(label: "Standup notes", frame: MacAXFrame(x: 100, y: 220, w: 300, h: 60)),
              ]),
    ])
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "Standup notes", toApp: "Mail", seconds: 0
    )

    #expect(!reply.ok)
    #expect(reply.detail["error"] == .string(MacCrossAppDrag.coveredSourceReason))
    #expect(reply.detail["raised"] == .bool(false))
    #expect(reply.text.contains("cover"), "\(reply.text)")
    #expect(harness.control.requests().isEmpty, "the refusal must precede the raise")
    #expect(harness.sink.mice().isEmpty)
}

@Test
func toApp_onANonDragVerbIsRefusedRatherThanIgnored() async {
    let harness = _xHarness()
    let reply = await harness.verbs.act(verb: "click", target: "report.pdf", toApp: "Mail")

    #expect(!reply.ok)
    #expect(reply.detail["error"] == .string(MacCrossAppDrag.verbNotDraggableReason))
    // Silently dropping it would let the model believe a cross-app act happened.
    #expect(reply.text.contains("to_app"), "\(reply.text)")
    #expect(harness.control.requests().isEmpty)
    #expect(harness.sink.mice().isEmpty)
}

@Test
func toApp_withoutATargetToDropOntoIsRefused() async {
    let harness = _xHarness()
    let reply = await harness.verbs.act(verb: "drag", target: "report.pdf", toApp: "Mail")

    #expect(!reply.ok)
    #expect(reply.detail["error"] == .string(MacCrossAppDrag.missingDestinationReason))
    #expect(reply.text.contains("Mail"), "\(reply.text)")
    #expect(harness.sink.mice().isEmpty)
}

// MARK: - 4. The single-window drag is untouched

@Test
func singleWindowDrag_isUnchangedWhenToAppIsAbsent() async {
    let harness = _xHarness()
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "notes.md", seconds: 0
    )

    #expect(reply.ok, "\(reply.text)")
    // Same words as before item 32b, and NONE of the cross-app receipt.
    let first = reply.text.split(separator: "\n").first.map(String.init) ?? ""
    #expect(first.hasPrefix("Dragged \"report.pdf\" to \"notes.md\"."), "\(first)")
    #expect(reply.detail["cross_app_drag"] == nil)
    #expect(reply.detail["raised"] == nil)
    #expect(reply.detail["destination_app"] == nil)
    // Nothing was raised and nothing outside the front window was read.
    #expect(harness.control.requests().isEmpty)
    #expect(!harness.source.probes().contains { $0.pid == 777 })

    let mice = harness.sink.mice()
    #expect(mice.first?.x == 120 && mice.first?.y == 110)
    #expect(mice.last?.x == 120 && mice.last?.y == 140)
}

// MARK: - 5. gpt-5.5 review: the window, not the union of what was read

@Test
func crossAppDrag_refusesWhenTheDestinationWINDOWCoversTheSource_evenWithNoTargetThere() async {
    // THE BUG THIS PINS. Mail's window sits over Finder's row, but the part of
    // it that does — its title bar and the blank band under it — publishes no
    // AX element. The union of Mail's TARGET frames therefore misses the source
    // point entirely, the old guard passed, Mail came forward, and the
    // mouse-down landed on Mail's title bar instead of on report.pdf.
    let harness = _xHarness(apps: [
        _xApp(name: "Finder", bundle: "com.apple.finder", pid: 501, windowTitle: "Documents",
              rows: [_XRow(label: "report.pdf", frame: MacAXFrame(x: 20, y: 100, w: 200, h: 20))]),
        _xApp(name: "Mail", bundle: "com.apple.mail", pid: 777, windowTitle: "New Message",
              // Every row is far below the source point…
              rows: [_XRow(label: "Standup notes", frame: MacAXFrame(x: 40, y: 400, w: 300, h: 60))],
              // …but the WINDOW starts above it and covers it.
              windowFrame: MacAXFrame(x: 0, y: 40, w: 500, h: 500)),
    ])
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "Standup notes", toApp: "Mail", seconds: 0
    )

    #expect(!reply.ok, "\(reply.text)")
    #expect(reply.detail["error"] == .string(MacCrossAppDrag.coveredSourceReason))
    #expect(reply.detail["raised"] == .bool(false))
    #expect(harness.control.requests().isEmpty, "the refusal must precede the raise")
    #expect(harness.sink.mice().isEmpty, "nothing may be pressed down")
}

@Test
func crossAppDrag_windowFrameBeatsTheUnionOfTargets_andTheUnionIsOnlyTheFallback() throws {
    let start = try #require(MacPointerPosition(x: 120, y: 110))
    let union = [MacAXFrame(x: 40, y: 400, w: 300, h: 60)]
    let window = MacAXFrame(x: 0, y: 40, w: 500, h: 500)

    // With the window's own frame, the point is covered…
    #expect(MacCrossAppDrag.raiseWouldCoverSource(
        start,
        destinationBounds: MacCrossAppDrag.coverageBounds(windowFrame: window, targetFrames: union)
    ))
    // …and without it the union is all there is, which is exactly why the
    // union alone was not a guard.
    #expect(!MacCrossAppDrag.raiseWouldCoverSource(
        start,
        destinationBounds: MacCrossAppDrag.coverageBounds(windowFrame: nil, targetFrames: union)
    ))
}

@Test
func crossAppDrag_looksAgainAfterTheRaise_beforeItAimsAnything() async {
    let harness = _xHarness()
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "Standup notes", toApp: "Mail", seconds: 0
    )

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.detail["reread_after_raise"] == .bool(true))
    // Mail was walked BEFORE the raise (costing no focus) and AGAIN after it,
    // because raising re-lays a window and a point computed before that is a
    // point about a screen that no longer exists.
    let mailProbes = harness.source.probes().filter { $0.pid == 777 }
    #expect(mailProbes.count >= 2, "Mail was not re-read after the raise: \(harness.source.probes())")
    #expect(mailProbes.first?.focusRequestsSoFar == 0)
    #expect(mailProbes.last.map { $0.focusRequestsSoFar > 0 } == true,
            "the second read was not after the raise: \(harness.source.probes())")
}

// MARK: - 6. gpt-5.5 review: a refusal about a background window says little

@Test
func crossAppDrag_refusalNeverPrintsTheBackgroundWindow() async {
    let harness = _xHarness(apps: [
        _xApp(name: "Finder", bundle: "com.apple.finder", pid: 501, windowTitle: "Documents",
              rows: [_XRow(label: "report.pdf", frame: MacAXFrame(x: 20, y: 100, w: 200, h: 20))]),
        _xApp(name: "Mail", bundle: "com.apple.mail", pid: 777, windowTitle: "New Message",
              rows: (1...12).map { index in
                  _XRow(label: "Private thread \(index)",
                        frame: MacAXFrame(x: 620, y: Double(100 + index * 30), w: 200, h: 20))
              }),
    ])
    let reply = await harness.verbs.act(
        verb: "drag", target: "report.pdf", to: "nothing by this name", toApp: "Mail", seconds: 0
    )

    #expect(!reply.ok)
    #expect(reply.detail["error"] == .string(MacCrossAppDrag.unresolvedDestinationReason))
    // The whole rendered window is gone. `POINTER:` is the last line of every
    // render, so its absence is proof the render was not appended.
    #expect(!reply.text.contains("POINTER:"), "\(reply.text)")
    // What survives is bounded: names only, capped.
    let named = (1...12).filter { reply.text.contains("Private thread \($0)") }
    #expect(named.count <= MacCrossAppDrag.maxDisclosedNames,
            "\(named.count) of that window's rows were read back: \(reply.text)")
    // And it still says whose window was searched, or the model retries forever.
    #expect(reply.text.contains("Mail's front window"), "\(reply.text)")
    #expect(harness.control.requests().isEmpty)
    #expect(harness.sink.mice().isEmpty)
}

@Test
func crossAppDrag_disclosableNamesIsCappedAndDeduplicatedAndCut() {
    let long = String(repeating: "x", count: MacCrossAppDrag.maxDisclosedNameChars + 40)
    let out = MacCrossAppDrag.disclosableNames(
        ["a", "a", "  ", "b", long, "c", "d", "e", "f", "g"]
    )
    #expect(out.count == MacCrossAppDrag.maxDisclosedNames)
    #expect(out.first == "a")
    #expect(!out.contains(""))
    #expect(Set(out).count == out.count)
    #expect(out.allSatisfy { $0.count <= MacCrossAppDrag.maxDisclosedNameChars + 1 })
}
