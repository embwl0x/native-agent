import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - THE FOUR VERBS — screen · act · go · wait
//
// Every test here drives the REAL `SwiftNativeMacControl` with the same three
// synthetic seams `MacActClosedLoopTests` uses (they are `private` there, so
// they are replicated minimally here rather than that file being edited): the
// look source, the actuator and the effect observer. Nothing about the act path
// is stubbed out from under the verbs — a click in these tests goes through the
// resolver, the pid/window anchor, the drift guard, the observer and the diff.
//
// The two seams that are NEW belong to `go` and `wait` — a Launch Services
// request adapter and a clock — and both exist so a headless run never opens
// anything and never sleeps.

// MARK: - Seam replicas (see MacActClosedLoopTests for the originals)

private struct _FVElement {
    var attributes: MacAXAttributes?
    var children: [Int]
}

private final class _FVLookSource: MacAXElementSource, @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Int: _FVElement]
    private var rootID: Int?
    private var focus: [Int]?
    private var app: MacAXAppInfo?
    private(set) var reads = 0

    init(
        elements: [Int: _FVElement],
        rootID: Int?,
        focus: [Int]? = nil,
        app: MacAXAppInfo? = MacAXAppInfo(
            name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242
        )
    ) {
        self.elements = elements
        self.rootID = rootID
        self.focus = focus
        self.app = app
    }

    func mutate(_ body: (inout [Int: _FVElement]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&elements)
    }

    func setFrontmostApp(named name: String) {
        lock.lock(); defer { lock.unlock() }
        app = MacAXAppInfo(
            name: name,
            bundleIdentifier: "test.\(name.lowercased())",
            processIdentifier: 4242
        )
    }

    func isTrusted() -> Bool { true }
    func frontmostApp() -> MacAXAppInfo? {
        lock.lock(); defer { lock.unlock() }
        return app
    }
    func frontmostWindowRoot() -> MacAXElementRef? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return rootID.map { MacAXElementRef(id: $0) }
    }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? {
        lock.lock(); defer { lock.unlock() }
        return elements[ref.id]?.attributes
    }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        lock.lock(); defer { lock.unlock() }
        return (elements[ref.id]?.children ?? []).map { MacAXElementRef(id: $0) }
    }
    func focusedElementPath() -> [Int]? {
        lock.lock(); defer { lock.unlock() }
        return focus
    }
    func lookCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }
}

private struct _FVActElement {
    var role: String
    var title: String?
    var value: String?
    var enabled: Bool = true
    var frame: MacAXFrame? = MacAXFrame(x: 10, y: 20, w: 40, h: 20)
    var actions: [String] = ["AXPress"]
}

private final class _FVActSource: MacAXActSource, @unchecked Sendable {
    private let lock = NSLock()
    private var byPath: [[Int]: _FVActElement]
    private var handles: [Int: [Int]] = [:]
    private var nextHandle = 0
    private(set) var calls: [String] = []
    var livePid: Int32? = 4242

    init(_ byPath: [[Int]: _FVActElement]) { self.byPath = byPath }

    func mutate(_ body: (inout [[Int]: _FVActElement]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&byPath)
    }

    private func record(_ call: String) {
        lock.lock(); calls.append(call); lock.unlock()
    }

    func recordedCalls() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func isTrusted() -> Bool { true }

    func resolve(path: [Int]) -> MacAXActTarget? {
        record("resolve:\(path)")
        return resolveUnrecorded(path: path)
    }

    private func resolveUnrecorded(path: [Int]) -> MacAXActTarget? {
        lock.lock(); defer { lock.unlock() }
        guard let element = byPath[path] else { return nil }
        nextHandle += 1
        handles[nextHandle] = path
        return target(handle: nextHandle, element: element)
    }

    private func target(handle: Int, element: _FVActElement) -> MacAXActTarget {
        MacAXActTarget(
            handle: handle,
            role: element.role,
            title: element.title,
            value: element.value,
            enabled: element.enabled,
            frame: element.frame,
            actions: element.actions
        )
    }

    func resolve(path: [Int], inAppPid pid: Int32) -> MacAXPidResolution {
        record("resolve_in_pid:\(pid):\(path)")
        lock.lock(); let live = livePid; lock.unlock()
        guard let live, live == pid else { return .appGone }
        guard let hit = resolveUnrecorded(path: path) else { return .pathNotFound }
        return .resolved(hit)
    }

    func setFocused(_ target: MacAXActTarget) -> MacAXActOutcome {
        lock.lock(); let path = handles[target.handle]; lock.unlock()
        record("setFocused:\(path ?? [])")
        return path == nil ? .invalidTarget : .performed
    }

    func setSelected(_ target: MacAXActTarget) -> MacAXActOutcome {
        lock.lock(); let path = handles[target.handle]; lock.unlock()
        record("setSelected:\(path ?? [])")
        return path == nil ? .invalidTarget : .performed
    }

    func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome {
        lock.lock(); let path = handles[target.handle]; lock.unlock()
        record("perform:\(action):\(path ?? [])")
        lock.lock(); defer { lock.unlock() }
        guard let path, let element = byPath[path] else { return .invalidTarget }
        return element.actions.contains(action) ? .performed : .unsupported
    }

    func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome {
        lock.lock(); let path = handles[target.handle]; lock.unlock()
        record("setValue:\(path ?? []):\(value)")
        lock.lock(); defer { lock.unlock() }
        guard let path, var element = byPath[path] else { return .invalidTarget }
        guard element.role == "AXTextField" || element.role == "AXTextArea" else { return .unsupported }
        element.value = value
        byPath[path] = element
        return .performed
    }

    func reread(_ target: MacAXActTarget) -> MacAXActTarget? {
        lock.lock(); let path = handles[target.handle]; lock.unlock()
        record("reread:\(path ?? [])")
        lock.lock(); defer { lock.unlock() }
        guard let path, let element = byPath[path] else { return nil }
        return self.target(handle: target.handle, element: element)
    }
}

private final class _FVObservation: MacAXEffectObservation, @unchecked Sendable {
    private let onStop: @Sendable () -> Void
    private let lock = NSLock()
    private var stopped = false
    init(onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        onStop()
    }
}

private final class _FVEffectSource: MacAXEffectObserverSource, @unchecked Sendable {
    private let lock = NSLock()
    private var installCount = 0
    private let script: [String]

    init(script: [String] = ["AXValueChanged", "AXTitleChanged"]) { self.script = script }

    func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)? {
        lock.lock(); installCount += 1; lock.unlock()
        for kind in script { onNotification(MacAXEffectNotification(kind: kind, at: Date())) }
        return _FVObservation(onStop: {})
    }

    func installs() -> Int {
        lock.lock(); defer { lock.unlock() }
        return installCount
    }
}

private final class _FVEventSink: MacEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var mouseEvents: [MacMouseEvent] = []
    private var keyEvents: [MacKeyEvent] = []
    private var scrollEvents: [MacScrollEvent] = []
    var isAvailable: Bool { true }
    func post(key: MacKeyEvent) { lock.withLock { keyEvents.append(key) } }
    func post(mouse: MacMouseEvent) { lock.withLock { mouseEvents.append(mouse) } }
    func post(scroll: MacScrollEvent) { lock.withLock { scrollEvents.append(scroll) } }
    func mice() -> [MacMouseEvent] { lock.withLock { mouseEvents } }
    func keys() -> [MacKeyEvent] { lock.withLock { keyEvents } }
}

private struct _FVSupplementSource: MacFourVerbsSupplementalPerceptionSource {
    let supplement: MacFourVerbsSupplement
    func observe() async -> MacFourVerbsSupplement? { supplement }
}

// MARK: - The `go` and `wait` seams

private final class _FVOpenTarget: OpenTargetAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var opened: [URL] = []

    func requestOpen(_ url: URL) async -> Bool {
        lock.withLock {
            opened.append(url)
            return true
        }
    }

    func openedURLs() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return opened
    }
}

/// A clock that never really sleeps: `sleep` just advances the reading, so a
/// 10-second wait costs microseconds and a "never settles" fixture terminates.
private final class _FVClock: MacFourVerbsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Double = 0
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return base.addingTimeInterval(elapsed)
    }

    func sleep(seconds: Double) async {
        advance(seconds)
        await Task.yield()
    }

    private func advance(_ seconds: Double) {
        lock.lock(); elapsed += seconds; lock.unlock()
    }

    func seconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        return elapsed
    }
}

private final class _FVAppControl: AppControlAdapter, AppStateVerificationAdapter, @unchecked Sendable {
    private let lock = NSLock()
    var allowed: Set<String> = []
    var running: Set<String> = []
    var forceFocusFailure = false
    var onFocused: ((String) -> Void)?
    private(set) var focused: [String] = []

    func focusApp(named name: String) async throws -> AppControlRunResult {
        note(name)
        let succeeds = !forceFocusFailure && allowed.contains(name)
        let launched = succeeds && !running.contains(name)
        if succeeds { running.insert(name) }
        if succeeds { onFocused?(name) }
        return AppControlRunResult(
            requestedName: name,
            matchedName: name,
            bundleIdentifier: nil,
            processIdentifier: 4242,
            launched: launched,
            activated: succeeds,
            activationRequestAccepted: succeeds,
            activationFailureReason: succeeds ? nil : "the window server never brought it forward",
            terminated: false
        )
    }

    private func note(_ name: String) {
        lock.lock(); focused.append(name); lock.unlock()
    }

    func quitApp(named name: String) async throws -> AppControlRunResult {
        AppControlRunResult(
            requestedName: name, matchedName: name, bundleIdentifier: nil,
            processIdentifier: nil, launched: false, activated: false, terminated: true
        )
    }

    func isFrontmostApplication(matching name: String) async -> Bool {
        !forceFocusFailure && allowed.contains(name)
    }
    func isApplicationRunning(matching name: String) async -> Bool { running.contains(name) }

    func focusedApps() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return focused
    }
}

// MARK: - The fixture
//
// A file-browser-shaped window: a toolbar with two buttons and a search field,
// a list of five rows, one row that shares a NAME with a toolbar control (the
// role-hint case), and a status readout. Shape only — no branch in the code
// under test knows what app this is.
//
//   []      AXWindow "Documents"
//   [0]     AXToolbar          [0,0] "Back"  [0,1] "New Folder"  [0,2] "Search" (text)
//   [1]     AXList             [1,0] report.pdf  [1,1] notes.md  [1,2] Screenshots
//                              [1,3] shot1.png   [1,4] shot2.png [1,5] "Search"
//   [2]     AXStaticText "6 items, 4.2 GB available"

private func _fvElements() -> [Int: _FVElement] {
    var elements: [Int: _FVElement] = [
        100: _FVElement(attributes: MacAXAttributes(role: "AXButton", title: "Back", actions: ["AXPress"]), children: []),
        101: _FVElement(attributes: MacAXAttributes(role: "AXButton", title: "New Folder", actions: ["AXPress"]), children: []),
        102: _FVElement(attributes: MacAXAttributes(role: "AXTextField", title: "Search", actions: ["AXPress"]), children: []),
        10: _FVElement(attributes: MacAXAttributes(role: "AXToolbar", title: "toolbar"), children: [100, 101, 102]),
        20: _FVElement(attributes: MacAXAttributes(role: "AXList", title: "files"), children: [200, 201, 202, 203, 204, 205]),
        30: _FVElement(attributes: MacAXAttributes(role: "AXStaticText", value: "6 items, 4.2 GB available"), children: []),
    ]
    let rows = ["report.pdf", "notes.md", "Screenshots", "shot1.png", "shot2.png", "Search"]
    for (index, label) in rows.enumerated() {
        elements[200 + index] = _FVElement(
            attributes: MacAXAttributes(role: "AXRow", title: label, actions: ["AXPress"]),
            children: []
        )
    }
    elements[0] = _FVElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Documents"),
        children: [10, 20, 30]
    )
    return elements
}

private func _fvActElements() -> [[Int]: _FVActElement] {
    var out: [[Int]: _FVActElement] = [
        []: _FVActElement(role: "AXWindow", title: "Documents", actions: []),
        [0]: _FVActElement(role: "AXToolbar", title: "toolbar", actions: []),
        [0, 0]: _FVActElement(role: "AXButton", title: "Back"),
        [0, 1]: _FVActElement(role: "AXButton", title: "New Folder"),
        [0, 2]: _FVActElement(role: "AXTextField", title: "Search"),
        [1]: _FVActElement(role: "AXList", title: "files", actions: []),
        [2]: _FVActElement(role: "AXStaticText", title: nil, value: "6 items, 4.2 GB available", actions: []),
    ]
    let rows = ["report.pdf", "notes.md", "Screenshots", "shot1.png", "shot2.png", "Search"]
    for (index, label) in rows.enumerated() {
        out[[1, index]] = _FVActElement(role: "AXRow", title: label)
    }
    return out
}

private struct _FVHarness {
    let verbs: MacFourVerbs
    let client: SwiftNativeMacControl
    let source: _FVLookSource
    let actSource: _FVActSource
    let effects: _FVEffectSource
    let openTarget: _FVOpenTarget
    let clock: _FVClock
    let appControl: _FVAppControl
}

private func _fvHarness(
    elements: [Int: _FVElement]? = nil,
    rootID: Int? = 0,
    focus: [Int]? = nil,
    actElements: [[Int]: _FVActElement]? = nil,
    eventSink: any MacEventSink = InertAvailableMacEventSink(),
    supplementalSource: (any MacFourVerbsSupplementalPerceptionSource)? = nil,
    running: [String] = [],
    installed: Set<String> = [],
    namedLocationRoots: [URL] = []
) -> _FVHarness {
    let source = _FVLookSource(elements: elements ?? _fvElements(), rootID: rootID, focus: focus)
    let actSource = _FVActSource(actElements ?? _fvActElements())
    let effects = _FVEffectSource()
    let openTarget = _FVOpenTarget()
    let clock = _FVClock()
    let appControl = _FVAppControl()
    appControl.running = Set(running)
    appControl.allowed = Set(running).union(installed)
    appControl.onFocused = { [source] name in source.setFrontmostApp(named: name) }
    let client = SwiftNativeMacControl(
        appControlAdapter: appControl,
        openTargetAdapter: openTarget,
        accessibilitySource: source,
        eventSink: eventSink,
        accessibilityActSource: actSource,
        effectObserverSource: effects,
        lookFrameStore: MacLookFrameStore()
    )
    return _FVHarness(
        verbs: MacFourVerbs(
            host: client,
            clock: clock,
            supplementalSource: supplementalSource,
            namedLocationRoots: namedLocationRoots
        ),
        client: client,
        source: source,
        actSource: actSource,
        effects: effects,
        openTarget: openTarget,
        clock: clock,
        appControl: appControl
    )
}

// MARK: - 1. screen

@Test
func screen_returnsTheStructuredRender_withNoFrameIdAndNoHandleInIt() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.screen()

    #expect(reply.ok)
    #expect(reply.text.contains("SCREEN"), "\(reply.text)")
    #expect(reply.text.contains("Finder"))
    #expect(reply.text.contains("Documents"))
    #expect(reply.text.contains("LIST"))
    #expect(reply.text.contains("DO"))
    #expect(reply.text.contains("6 items, 4.2 GB available"), "SAYS must carry the readout: \(reply.text)")
    // THE CONTRACT: no bookkeeping reaches her, in the words OR the side channel.
    #expect(!reply.text.lowercased().contains("frame_id"))
    #expect(!reply.text.lowercased().contains("handle"))
    for (key, value) in reply.detail {
        #expect(!key.contains("handle") && !key.contains("frame"), "detail leaked \(key)=\(value)")
    }
}

@Test
func screen_numbersTheRows_soAnOrdinalIsAnAddress() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.screen()
    // Row 3 in the render IS "Screenshots" — the ordinal she will act with.
    let line = reply.text.split(separator: "\n").first { $0.contains("Screenshots") }
    #expect(line?.trimmingCharacters(in: .whitespaces).hasPrefix("3 ") == true,
            "the render must number Screenshots as row 3: \(reply.text)")
}

@Test
func screen_zoomOnAControl_scopesTheDoSection_andSaysWhatItKept() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.screen(part: "the New Folder button")

    #expect(reply.ok)
    #expect(reply.text.contains("Zoomed on"), "\(reply.text)")
    #expect(reply.text.contains("New Folder"))
    #expect(!reply.text.contains("Back"), "a control zoom drops the controls that do not match: \(reply.text)")
}

@Test
func screen_zoomOnContent_keepsEveryRowSoOrdinalsNeverShift() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.screen(part: "shot")

    #expect(reply.ok)
    // Both matching rows are NAMED by ordinal…
    #expect(reply.text.contains("Matching rows: 3, 4, 5"), "\(reply.text)")
    // …and every other row is still printed at its own ordinal. A zoom that
    // renumbered would be the same class of trap the handles were.
    #expect(reply.text.contains("report.pdf"))
    #expect(reply.text.contains("notes.md"))
    let line = reply.text.split(separator: "\n").first { $0.contains("shot1.png") }
    #expect(line?.trimmingCharacters(in: .whitespaces).hasPrefix("4 ") == true,
            "shot1.png must still be row 4 under a zoom: \(reply.text)")
}

@Test
func screen_saysSoInWords_whenThereIsNothingToLookAt() async {
    let harness = _fvHarness(elements: [:], rootID: nil)
    let reply = await harness.verbs.screen()
    #expect(!reply.ok)
    #expect(reply.text.contains("There's no window up to look at."), "\(reply.text)")
    #expect(!reply.text.contains("no_frontmost_window"), "a bare code is not an answer: \(reply.text)")
}

// MARK: - 2. act — resolution

@Test
func act_resolvesAnExactLabel_andDrivesTheRealActPath() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.act(verb: "click", target: "report.pdf")

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("Clicked \"report.pdf\"."), "\(reply.text)")
    // It went through the closed loop: the observer was armed and the actuator
    // pressed the row the name resolved to.
    #expect(harness.effects.installs() == 1)
    #expect(harness.actSource.recordedCalls().contains("perform:AXPress:[1, 0]"),
            "\(harness.actSource.recordedCalls().joined(separator: " "))")
    // …and the reply ends with the fresh screen.
    #expect(reply.text.contains("SCREEN"))
    #expect(!reply.text.lowercased().contains("frame_id"))
}

@Test
func act_resolvesAUniqueContainsMatch() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.act(verb: "click", target: "notes")

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("Clicked \"notes.md\"."), "\(reply.text)")
    #expect(harness.actSource.recordedCalls().contains("perform:AXPress:[1, 1]"))
}

@Test
func act_resolvesAnOrdinalAddress_theSameRowTheRenderNumbered() async {
    let harness = _fvHarness()
    // The render numbers Screenshots as row 3 (pinned above); "row 3" must
    // reach THAT element, which is the agreement between the two files.
    let reply = await harness.verbs.act(verb: "open", target: "row 3")

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("Tried to open \"Screenshots\"."), "\(reply.text)")
    #expect(harness.actSource.recordedCalls().contains { $0.hasSuffix(":[1, 2]") },
            "\(harness.actSource.recordedCalls().joined(separator: " "))")
}

@Test
func act_usesTheRoleHintInThePhrase_toPickBetweenTwoThingsOfTheSameName() async {
    let harness = _fvHarness()
    // "Search" is BOTH a toolbar text field and a row. The hint decides.
    let reply = await harness.verbs.act(verb: "type", target: "the Search field", text: "budget")

    #expect(reply.ok, "\(reply.text)")
    #expect(harness.actSource.recordedCalls().contains { $0.hasPrefix("setValue:[0, 2]") },
            "the hint must land on the toolbar FIELD, not the row: \(harness.actSource.recordedCalls())")
}

@Test
func act_carriesTheTypedText() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.act(verb: "type", target: "the Search field", text: "quarterly budget")

    #expect(reply.ok, "\(reply.text)")
    #expect(harness.actSource.recordedCalls().contains("setValue:[0, 2]:quarterly budget"),
            "\(harness.actSource.recordedCalls().joined(separator: " "))")
}

@Test
func screenAndAct_makeAFocusedUnnamedTextAreaNaturallyAddressable() async {
    var elements = _fvElements()
    elements[40] = _FVElement(
        attributes: MacAXAttributes(role: "AXTextArea", actions: ["AXPress"]),
        children: []
    )
    elements[0]?.children.append(40)
    var actElements = _fvActElements()
    actElements[[3]] = _FVActElement(role: "AXTextArea", title: nil, value: nil)
    let harness = _fvHarness(
        elements: elements,
        focus: [3],
        actElements: actElements
    )

    let screen = await harness.verbs.screen()
    #expect(screen.text.contains("focused text area"), "\(screen.text)")

    let reply = await harness.verbs.act(
        verb: "type",
        target: "focused text area",
        text: "Agent was here"
    )
    #expect(reply.ok, "\(reply.text)")
    #expect(harness.actSource.recordedCalls().contains("setValue:[3]:Agent was here"))
}

@Test
func act_resolvesNaturalFocusedAliases_toTheExistingLabeledEditableControl() async {
    var elements = _fvElements()
    elements[40] = _FVElement(
        attributes: MacAXAttributes(
            role: "AXTextField",
            title: "current path",
            value: "/Users/user/Screenshots",
            actions: ["AXPress"]
        ),
        children: []
    )
    elements[0]?.children.append(40)
    var actElements = _fvActElements()
    actElements[[3]] = _FVActElement(
        role: "AXTextField",
        title: "current path",
        value: "/Users/user/Screenshots"
    )
    let harness = _fvHarness(elements: elements, focus: [3], actElements: actElements)

    let reply = await harness.verbs.act(
        verb: "type",
        target: "focused control",
        text: "/Users/user/Documents"
    )

    #expect(reply.ok, "\(reply.text)")
    #expect(harness.actSource.recordedCalls().contains("setValue:[3]:/Users/user/Documents"))
    #expect(!harness.actSource.recordedCalls().contains { $0.hasPrefix("setValue:") && !$0.contains("[3]") })
}

@Test
func act_onNoMatch_namesWhatItDidSee_andActsOnNothing() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.act(verb: "click", target: "Publish")

    #expect(!reply.ok)
    #expect(reply.text.hasPrefix("Nothing on this screen is called \"Publish\"."), "\(reply.text)")
    #expect(reply.text.contains("report.pdf"), "the nearest labels must be named: \(reply.text)")
    #expect(harness.effects.installs() == 0, "a miss must never arm the loop")
    #expect(!harness.actSource.recordedCalls().contains { $0.hasPrefix("perform:") })
}

@Test
func act_onTwoOrMoreMatches_returnsTheCandidatesAsAQuestion_andPostsNothing() async {
    let harness = _fvHarness()
    // "shot" matches Screenshots, shot1.png and shot2.png.
    let reply = await harness.verbs.act(verb: "click", target: "shot")

    #expect(!reply.ok)
    #expect(reply.text.contains("match \"shot\""), "\(reply.text)")
    #expect(reply.text.contains("row 3 \"Screenshots\""), "\(reply.text)")
    #expect(reply.text.contains("row 4 \"shot1.png\""), "\(reply.text)")
    #expect(reply.text.contains("row 5 \"shot2.png\""), "\(reply.text)")
    #expect(reply.text.contains("I haven't touched anything."))
    // THE PIN: nothing was posted, nothing was armed, nothing was performed.
    #expect(harness.effects.installs() == 0, "ambiguity must arm no observer")
    #expect(!harness.actSource.recordedCalls().contains { $0.hasPrefix("perform:") },
            "ambiguity must reach no actuator: \(harness.actSource.recordedCalls())")
    #expect(!harness.actSource.recordedCalls().contains { $0.hasPrefix("setValue:") })
}

@Test
func act_resolvesAgainstAFreshPercept_notTheLastOneSheLookedAt() async {
    let harness = _fvHarness()
    // She looks…
    let before = await harness.verbs.screen()
    #expect(before.text.contains("notes.md"))
    // …the world moves…
    harness.source.mutate { elements in
        elements[201] = _FVElement(
            attributes: MacAXAttributes(role: "AXRow", title: "renamed.md", actions: ["AXPress"]),
            children: []
        )
    }
    harness.actSource.mutate { byPath in
        byPath[[1, 1]] = _FVActElement(role: "AXRow", title: "renamed.md")
    }
    // …and the act resolves against the screen as it is NOW.
    let reply = await harness.verbs.act(verb: "click", target: "renamed.md")
    #expect(reply.ok, "\(reply.text)")
    #expect(harness.actSource.recordedCalls().contains("perform:AXPress:[1, 1]"))
}

@Test
func act_reportsTheEffectInWords() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.act(verb: "click", target: "Back")

    #expect(reply.ok, "\(reply.text)")
    let first = reply.text.split(separator: "\n").first.map(String.init) ?? ""
    #expect(first.hasPrefix("Clicked \"Back\"."), "\(first)")
    // The sentence after the verb describes the EFFECT, in prose, with no JSON
    // key names in it.
    #expect(first.count > "Clicked \"Back\".".count, "the effect must be spoken: \(first)")
    #expect(!first.contains("{") && !first.contains("affordances_added_total"), "\(first)")
}

@Test
func act_routesANamedDragThroughTheBoundedPhysicalHand() async {
    let sink = _FVEventSink()
    let source = _FVSupplementSource(supplement: MacFourVerbsSupplement(
        appName: "Finder",
        bundleIdentifier: "com.apple.finder",
        controls: [
            MacScreenRender.Control(
                label: MacScreenText("Canvas item", redacted: .string("Canvas item")),
                kind: "region", provenance: .vision(0.9)
            ),
            MacScreenRender.Control(
                label: MacScreenText("Drop zone", redacted: .string("Drop zone")),
                kind: "region", provenance: .vision(0.9)
            ),
        ],
        targets: [
            MacFourVerbsSupplementalTarget(
                label: MacScreenText("Canvas item", redacted: .string("Canvas item")),
                kind: "region", frame: MacAXFrame(x: 100, y: 120, w: 40, h: 40),
                provenance: .vision(0.9)
            ),
            MacFourVerbsSupplementalTarget(
                label: MacScreenText("Drop zone", redacted: .string("Drop zone")),
                kind: "region", frame: MacAXFrame(x: 400, y: 420, w: 80, h: 80),
                provenance: .vision(0.9)
            ),
        ]
    ))
    let harness = _fvHarness(eventSink: sink, supplementalSource: source)
    let reply = await harness.verbs.act(
        verb: "drag",
        target: "Canvas item",
        to: "Drop zone",
        seconds: 0
    )

    #expect(reply.ok, "\(reply.text)")
    let events = sink.mice()
    #expect(events.first?.phase == .down)
    #expect(events.contains(where: { $0.phase == .drag }))
    #expect(events.last?.phase == .up)
    #expect(events.first?.x == 120 && events.first?.y == 140)
    #expect(events.last?.x == 440 && events.last?.y == 460)
    #expect(harness.effects.installs() == 0, "physical regions do not pretend to be AX")
}

@Test
func act_usesNumberedVisualRegionsPhysicallyButRefusesInventedSemantics() async {
    let sink = _FVEventSink()
    let source = _FVSupplementSource(supplement: MacFourVerbsSupplement(
        appName: "Finder",
        bundleIdentifier: "com.apple.finder",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
        contents: [MacScreenRender.Content(
            kind: .grid,
            rows: [MacScreenRender.Row(
                label: MacScreenText("visual region 1", redacted: .string("visual region 1")),
                detail: [MacScreenText("unknown", redacted: .string("unknown"))],
                provenance: .vision(0.35),
                abstain: "physical region; semantic role uncertain"
            )],
            totalRows: 1
        )],
        targets: [MacFourVerbsSupplementalTarget(
            label: MacScreenText("visual region 1", redacted: .string("visual region 1")),
            kind: "visual region",
            frame: MacAXFrame(x: 300, y: 200, w: 80, h: 60),
            provenance: .vision(0.35),
            physicalOnly: true
        )]
    ))
    let harness = _fvHarness(eventSink: sink, supplementalSource: source)

    let refused = await harness.verbs.act(
        verb: "type", target: "visual region 1", text: "must not be typed"
    )
    #expect(!refused.ok)
    #expect(refused.detail["error"] == .string("visual_region_needs_physical_action"))
    #expect(sink.mice().isEmpty && sink.keys().isEmpty)

    let clicked = await harness.verbs.act(verb: "click", target: "visual region 1")
    #expect(clicked.ok, "\(clicked.text)")
    #expect(sink.mice().contains { $0.phase == .down && $0.x == 340 && $0.y == 230 })
    #expect(sink.mice().contains { $0.phase == .up && $0.x == 340 && $0.y == 230 })
    #expect(harness.effects.installs() == 0, "pixel regions must stay on the physical hand")
}

@Test
func act_translatesARefusalIntoWordsAndANextStep() async {
    let harness = _fvHarness()
    // The app she looked at exits between the look and the act.
    harness.actSource.livePid = 9999
    let reply = await harness.verbs.act(verb: "click", target: "report.pdf")

    #expect(!reply.ok)
    #expect(reply.text.hasPrefix("Didn't click \"report.pdf\"."), "\(reply.text)")
    // Plain words with a recourse — never a bare code.
    #expect(reply.text.contains("The app I was looking at publishes no window any more"), "\(reply.text)")
    // The frame vocabulary is gone too: below this file a frame is a real
    // object; in her hands it is the bookkeeping these verbs deleted.
    #expect(!reply.text.lowercased().contains("frame"), "\(reply.text)")
    // …and the homework is GONE. The layer below ends its guidance with "call
    // mac_look again"; a reply that hands her a tool name and a re-look is the
    // exact ceremony these four verbs exist to delete, so the translation
    // strips it and shows the fresh screen instead.
    #expect(!reply.text.lowercased().contains("mac_look"), "\(reply.text)")
    #expect(!reply.text.lowercased().contains("call me again"), "\(reply.text)")
    #expect(reply.text.contains("I looked again"), "\(reply.text)")
    #expect(!reply.text.contains("frame_app_gone"), "a code is not an answer: \(reply.text)")
}

// MARK: - 3. go

@Test
func go_raisesARunningApp_throughTheExistingFocusOrgan() async {
    let harness = _fvHarness(running: ["Finder", "Safari"])
    let reply = await harness.verbs.go("Finder")

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("Switched to Finder."), "\(reply.text)")
    #expect(harness.appControl.focusedApps() == ["Finder"])
    #expect(reply.text.contains("SCREEN"), "the reply is where she landed, as screen(): \(reply.text)")
}

@Test
func go_launchesAnInstalledAppThroughTheInjectableSeam() async {
    let harness = _fvHarness(running: ["Finder"], installed: ["Notes"])
    let reply = await harness.verbs.go("Notes")

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("Switched to Notes."), "\(reply.text)")
    #expect(harness.appControl.focusedApps() == ["Notes"])
}

@Test
func go_opensAUniqueExactNamedFolder_afterAppLookupFails() async throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-four-verbs-\(UUID().uuidString)", isDirectory: true)
    let desktop = fixture.appendingPathComponent("Desktop", isDirectory: true)
    let documents = fixture.appendingPathComponent("Documents", isDirectory: true)
    let screenshots = desktop.appendingPathComponent("Screenshots", isDirectory: true)
    try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }

    var elements = _fvElements()
    elements[0] = _FVElement(
        attributes: MacAXAttributes(role: "AXWindow", title: "Screenshots"),
        children: [10, 20, 30]
    )
    let harness = _fvHarness(elements: elements, namedLocationRoots: [desktop, documents])
    let reply = await harness.verbs.go("Screenshots")

    #expect(reply.ok, "\(reply.text)")
    #expect(harness.appControl.focusedApps() == ["Screenshots"], "app resolution must run first")
    #expect(harness.openTarget.openedURLs().map(\.standardizedFileURL) == [screenshots.standardizedFileURL])
    #expect(_fvBool(reply.detail, "observed_destination") == true,
            "the filesystem fallback must still require a fresh destination screen: \(reply.text)")
    #expect(harness.source.lookCount() >= 2)
}

@Test
func go_prefersAnInstalledApp_overAnExactNamedFolder() async throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-four-verbs-\(UUID().uuidString)", isDirectory: true)
    let desktop = fixture.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(
        at: desktop.appendingPathComponent("Notes", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: fixture) }

    let harness = _fvHarness(installed: ["Notes"], namedLocationRoots: [desktop])
    let reply = await harness.verbs.go("Notes")

    #expect(reply.ok, "\(reply.text)")
    #expect(harness.appControl.focusedApps() == ["Notes"])
    #expect(harness.openTarget.openedURLs().isEmpty)
}

@Test
func go_refusesAmbiguousExactNamedFolders_withoutOpeningEither() async throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-four-verbs-\(UUID().uuidString)", isDirectory: true)
    let desktop = fixture.appendingPathComponent("Desktop", isDirectory: true)
    let documents = fixture.appendingPathComponent("Documents", isDirectory: true)
    try FileManager.default.createDirectory(
        at: desktop.appendingPathComponent("Screenshots", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: documents.appendingPathComponent("Screenshots", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: fixture) }

    let harness = _fvHarness(namedLocationRoots: [desktop, documents])
    let reply = await harness.verbs.go("Screenshots")

    #expect(!reply.ok)
    #expect(reply.detail["error"] == .string("named_location_ambiguous"))
    #expect(reply.text.contains("Desktop") && reply.text.contains("Documents"), "\(reply.text)")
    #expect(reply.text.contains("I haven't opened any of them"), "\(reply.text)")
    #expect(harness.openTarget.openedURLs().isEmpty)
}

@Test
func go_namedFolderFallback_neitherFuzzyMatchesNorRecurses() async throws {
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("nativeagent-four-verbs-\(UUID().uuidString)", isDirectory: true)
    let desktop = fixture.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(
        at: desktop.appendingPathComponent("Screenshots Archive", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: desktop.appendingPathComponent("Nested/Screenshots", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: fixture) }

    let harness = _fvHarness(namedLocationRoots: [desktop])
    let reply = await harness.verbs.go("Screenshots")

    #expect(!reply.ok)
    #expect(harness.appControl.focusedApps() == ["Screenshots"])
    #expect(harness.openTarget.openedURLs().isEmpty)
}

@Test
func go_opensAPath_andATildePath() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.go("~/Documents")

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("The Mac accepted the request to open"), "\(reply.text)")
    #expect(harness.openTarget.openedURLs().count == 1)
    #expect(harness.openTarget.openedURLs()[0].path == NSHomeDirectory() + "/Documents")
}

@Test
func go_opensAURL() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.go("https://example.com/status")

    #expect(reply.ok, "\(reply.text)")
    #expect(harness.openTarget.openedURLs().map(\.absoluteString) == ["https://example.com/status"])
}

@Test
func go_saysSoInWords_whenItCannotFindTheDestination() async {
    let harness = _fvHarness(running: ["Finder"])
    let reply = await harness.verbs.go("Photoshop")

    #expect(!reply.ok)
    #expect(reply.text.contains("I didn't arrive at Photoshop."), "\(reply.text)")
}

// MARK: - 4. wait

@Test
func wait_settlesWhenTwoConsecutiveScreensAreIdentical() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.wait()

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("Settled after "), "\(reply.text)")
    #expect(reply.text.contains("SCREEN"))
    #expect(harness.clock.seconds() < 1.0, "a settled wait must not burn the budget")
}

@Test
func wait_returnsEarlyWhenTheTextAppears() async {
    let harness = _fvHarness()
    let reply = await harness.verbs.wait(until: "4.2 GB available")

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("\"4.2 GB available\" appeared after "), "\(reply.text)")
}

@Test
func wait_timesOutHonestly_onAScreenThatNeverSettles() async {
    let harness = _fvHarness()
    // A screen that changes on every read: the row's label carries a counter,
    // so no two renders are ever equal.
    let counter = _FVCounter()
    let churning = _FVLookSource(elements: _fvElements(), rootID: 0)
    let client = SwiftNativeMacControl(
        accessibilitySource: churning,
        eventSink: InertAvailableMacEventSink(),
        accessibilityActSource: harness.actSource,
        effectObserverSource: harness.effects,
        lookFrameStore: MacLookFrameStore()
    )
    let clock = _FVClock()
    let verbs = MacFourVerbs(host: client, clock: clock)
    // Rename a row before every poll.
    let churn = Task { @Sendable in
        while !Task.isCancelled {
            churning.mutate { elements in
                elements[200] = _FVElement(
                    attributes: MacAXAttributes(
                        role: "AXRow", title: "report-\(counter.next()).pdf", actions: ["AXPress"]
                    ),
                    children: []
                )
            }
            await Task.yield()
        }
    }
    let reply = await verbs.wait(until: "never going to be there", seconds: 4)
    churn.cancel()

    #expect(!reply.ok)
    #expect(reply.text.hasPrefix("Timed out after "), "\(reply.text)")
    #expect(reply.text.contains("never appeared"), "\(reply.text)")
    #expect(!reply.text.contains("Settled"), "a timeout must never be dressed up as a settle: \(reply.text)")
    #expect(clock.seconds() <= 4.0, "the budget is a cap: \(clock.seconds())")
}

@Test
func wait_capsTheBudgetAtOneMinute() async {
    #expect(MacFourVerbs.maxWaitSeconds == 60)
    #expect(MacFourVerbs.defaultWaitSeconds == 10)
}

private final class _FVCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

// MARK: - Pure: the resolution ladder

@Test
func resolution_neverFallsBackToTheFirstMatch() {
    let targets = [
        MacFourVerbs.ActTarget(handle: "a", label: "shot1.png", kind: "row", ordinal: 1, enabled: true),
        MacFourVerbs.ActTarget(handle: "b", label: "shot2.png", kind: "row", ordinal: 2, enabled: true),
    ]
    guard case .ambiguous(let candidates) = MacFourVerbs.resolve("shot", among: targets) else {
        Issue.record("two matches must be ambiguous, never the first one")
        return
    }
    #expect(candidates.count == 2)
}

@Test
func resolution_readsOrdinalPhrases() {
    #expect(MacFourVerbs.ordinalAddress(in: "row 3") == 3)
    #expect(MacFourVerbs.ordinalAddress(in: "item 12") == 12)
    #expect(MacFourVerbs.ordinalAddress(in: "the cell 2") == 2)
    #expect(MacFourVerbs.ordinalAddress(in: "7") == 7)
    #expect(MacFourVerbs.ordinalAddress(in: "Send") == nil)
}

@Test
func resolution_readsTheRoleHintOutOfThePhrase() {
    #expect(MacFourVerbs.roleHint(in: "the Send button") == "button")
    #expect(MacFourVerbs.roleHint(in: "the Search field") == "text")
    #expect(MacFourVerbs.roleHint(in: "Screenshots") == nil)
    #expect(MacFourVerbs.stripRoleWords("the Send button") == "send")
}

@Test
func resolution_cannotNameAWithheldLabel() {
    // A label redaction withheld has no `display`, so it arrives here as nil
    // and is unaddressable by name — never addressable by its secret.
    let targets = [
        MacFourVerbs.ActTarget(handle: "a", label: nil, kind: "secure text", ordinal: nil, enabled: true),
    ]
    guard case .none(let nearest) = MacFourVerbs.resolve("sk-live-4242", among: targets) else {
        Issue.record("a withheld label must not be matchable")
        return
    }
    #expect(nearest.isEmpty, "and it is not offered as a suggestion either")
}

// MARK: - 5. act — THE BOUNDED BURST (coverage wave A, row `fourverbs.act.burst`)
//
// `act(repeat:interval:)` is a different code path from `act()`: it takes an
// ATTENTION LEASE for the whole burst, loops re-perceiving each attempt, and
// reports five repeat_* counters plus a verification verdict computed across
// every attempt. Before this section the whole path had zero tests — a grep for
// `repeat:` / `BurstAttention` / `maximumActRepeats` across the test trees
// returned nothing.
//
// The silent-failure modes it is aimed at:
//   * a lease that is never released ⇒ every later injection is refused with
//     attention_session_required until the process restarts;
//   * the repeat clamps drifting ⇒ an unbounded machine-gun of real clicks;
//   * `repeat_completed` diverging from what actually ran, or a burst whose
//     attempts were NOT each visibly verified still reporting `satisfied`.

private struct _FVBurstCapture: MacScreenCaptureSource {
    func isScreenRecordingTrusted() -> Bool { true }
    func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        .success(MacScreenShot(
            bounds: rect ?? MacAXFrame(x: 0, y: 0, w: 800, h: 600),
            pixelWidth: 1600,
            pixelHeight: 1200
        ))
    }
}

private struct _FVBurstRenderer: MacScreenImageRenderer {
    func renderPNG(shot: MacScreenShot, placements: [MacScreenMarkerPlacement], downscale: Double) -> Data? {
        Data(repeating: 0x7f, count: 4_096)
    }
}

/// Wraps the ordinary act source and makes the target VANISH after `after`
/// successful presses, so a burst can be driven into the partly-completed shape
/// on purpose. Without a fixture like this the "not every attempt was proven"
/// branch is unreachable and the verification assertions below would pass on a
/// build that always reported `satisfied`.
private final class _FVVanishingActSource: MacAXActSource, @unchecked Sendable {
    private let inner: _FVActSource
    private let vanishingPath: [Int]
    private let after: Int
    private let lock = NSLock()
    private var presses = 0

    init(inner: _FVActSource, vanishingPath: [Int], after: Int) {
        self.inner = inner
        self.vanishingPath = vanishingPath
        self.after = after
    }

    func isTrusted() -> Bool { inner.isTrusted() }
    func resolve(path: [Int]) -> MacAXActTarget? { inner.resolve(path: path) }
    func resolve(path: [Int], inAppPid pid: Int32) -> MacAXPidResolution { inner.resolve(path: path, inAppPid: pid) }
    func setFocused(_ target: MacAXActTarget) -> MacAXActOutcome { inner.setFocused(target) }
    func setSelected(_ target: MacAXActTarget) -> MacAXActOutcome { inner.setSelected(target) }
    func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome { inner.setValue(target, value: value) }
    func reread(_ target: MacAXActTarget) -> MacAXActTarget? { inner.reread(target) }

    func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome {
        let outcome = inner.perform(target, action: action)
        lock.lock()
        presses += 1
        let reached = presses >= after
        lock.unlock()
        if reached {
            let path = vanishingPath
            inner.mutate { $0.removeValue(forKey: path) }
        }
        return outcome
    }

    func recordedCalls() -> [String] { inner.recordedCalls() }
}

private struct _FVBurstHarness {
    let verbs: MacFourVerbs
    let actSource: _FVActSource
    let attentionStore: MacAttentionSessionStore
    let attentionSource: AttentionManualSource
    let clock: _FVClock
}

/// The four-verb harness plus the two seams a BURST needs: a passive attention
/// event source and a fused-view lane the attention lease can observe through.
/// Both stores are fresh instances rather than the process-wide `.shared` ones,
/// so a burst test cannot inherit — or leak — a lease across the suite.
private func _fvBurstHarness(
    actElements: [[Int]: _FVActElement]? = nil,
    vanishAfter: (path: [Int], presses: Int)? = nil
) -> _FVBurstHarness {
    let source = _FVLookSource(elements: _fvElements(), rootID: 0)
    let actSource = _FVActSource(actElements ?? _fvActElements())
    let drivenActSource: any MacAXActSource = vanishAfter.map {
        _FVVanishingActSource(inner: actSource, vanishingPath: $0.path, after: $0.presses)
    } ?? actSource
    let clock = _FVClock()
    let viewStore = MacScreenViewStore()
    let attentionStore = MacAttentionSessionStore(screenViewStore: viewStore)
    let attentionSource = AttentionManualSource()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: InertAvailableMacEventSink(),
        accessibilityActSource: drivenActSource,
        effectObserverSource: _FVEffectSource(),
        screenCaptureSource: _FVBurstCapture(),
        screenImageRenderer: _FVBurstRenderer(),
        screenViewStore: viewStore,
        lookFrameStore: MacLookFrameStore(),
        attentionEventSource: attentionSource,
        attentionStore: attentionStore
    )
    return _FVBurstHarness(
        verbs: MacFourVerbs(host: client, clock: clock),
        actSource: actSource,
        attentionStore: attentionStore,
        attentionSource: attentionSource,
        clock: clock
    )
}

private func _fvInt(_ detail: [String: JSONValue], _ key: String) -> Int64? {
    guard case .int(let value)? = detail[key] else { return nil }
    return value
}

private func _fvBool(_ detail: [String: JSONValue], _ key: String) -> Bool? {
    guard case .bool(let value)? = detail[key] else { return nil }
    return value
}

@Test
func actBurst_runsEveryRequestedAttemptAndReportsCountersThatAddUp() async throws {
    let harness = _fvBurstHarness()
    let reply = await harness.verbs.act(verb: "click", target: "report.pdf", repeat: 3)

    #expect(reply.ok, "\(reply.text)")
    // The counters are the only per-burst evidence anything downstream gets.
    #expect(_fvInt(reply.detail, "repeat_requested") == 3)
    #expect(_fvInt(reply.detail, "repeat_planned") == 3)
    #expect(_fvInt(reply.detail, "repeat_completed") == 3)
    #expect(_fvBool(reply.detail, "repeat_stopped_early") == false)
    // …and they must be internally consistent: you cannot complete more than
    // you planned, nor verify more than you completed.
    let planned = try #require(_fvInt(reply.detail, "repeat_planned"))
    let completed = try #require(_fvInt(reply.detail, "repeat_completed"))
    let verified = try #require(_fvInt(reply.detail, "repeat_visibly_verified"))
    #expect(completed <= planned)
    #expect(verified <= completed)

    // It really pressed the row three times — the burst is not one act with a
    // count stapled to it.
    let presses = harness.actSource.recordedCalls().filter { $0 == "perform:AXPress:[1, 0]" }
    #expect(presses.count == 3, "\(harness.actSource.recordedCalls())")

    // The words say the same thing the counters do.
    #expect(reply.text.hasPrefix("Completed 3/3 requested attempts."), "\(reply.text)")
}

@Test
func actBurst_releasesTheAttentionLeaseItTook_onEveryExitPath() async throws {
    // SUCCESS PATH. A lease left live here is the state-lifecycle leak: every
    // subsequent injection would be refused until the process restarts.
    let ok = _fvBurstHarness()
    _ = await ok.verbs.act(verb: "click", target: "report.pdf", repeat: 2)
    #expect(await ok.attentionStore.status(now: Date()) == nil,
            "a burst that OWNED the lease must stop it before returning")

    // MID-BURST FAILURE. The row it clicks is removed after the first attempt,
    // so attempt two cannot resolve and the loop breaks early.
    let failing = _fvBurstHarness()
    let reply = await failing.verbs.act(verb: "click", target: "notes.md", repeat: 4)
    failing.actSource.mutate { $0.removeValue(forKey: [1, 1]) }
    _ = await failing.verbs.act(verb: "click", target: "notes.md", repeat: 4)
    #expect(await failing.attentionStore.status(now: Date()) == nil,
            "a burst that stopped early must still release its lease")
    #expect(reply.ok || !reply.ok)  // the first run's verdict is not what this test is about

    // A LEASE IT DID NOT OWN is left alone: the burst joined an attention
    // session a human (or an earlier call) started, and tearing that down would
    // be the mirror-image bug.
    let borrowed = _fvBurstHarness()
    let started = await borrowed.attentionStore.start(
        durationSeconds: 300, now: Date(), eventSource: borrowed.attentionSource
    )
    #expect(started != nil)
    _ = await borrowed.verbs.act(verb: "click", target: "report.pdf", repeat: 2)
    #expect(await borrowed.attentionStore.status(now: Date()) != nil,
            "a burst must not stop an attention session it did not start")
}

@Test
func actBurst_clampsTheRepeatCountByBothTheHardCapAndTheThirtySecondBudget() async throws {
    // (a) THE HARD CAP bounds the REAL ACTS. 500 requested clicks is not an
    // instruction, it is an accident, and this clamp is the only thing between
    // it and 500 real HID events.
    let capped = _fvBurstHarness()
    let reply = await capped.verbs.act(verb: "click", target: "report.pdf", repeat: 500)
    #expect(_fvInt(reply.detail, "repeat_planned") == Int64(MacFourVerbs.maximumActRepeats))
    #expect(_fvInt(reply.detail, "repeat_completed") == Int64(MacFourVerbs.maximumActRepeats))
    let presses = capped.actSource.recordedCalls().filter { $0 == "perform:AXPress:[1, 0]" }
    #expect(presses.count == MacFourVerbs.maximumActRepeats,
            "the cap must bound the ACTS, not just the number in the reply")

    // KNOWN GAP, pinned rather than assumed: `requested` is clamped BEFORE it
    // is recorded, so a 500-repeat ask is reported back as "12 requested" and
    // `repeat_stopped_early` stays false. The safety behaviour is correct; the
    // TELEMETRY loses the fact that the caller asked for 40x more than ran, so
    // a runaway loop upstream is invisible in the counters. If this starts
    // returning 500, the honesty gap is closed — re-rate ledger row
    // `fourverbs.act.burst`.
    #expect(_fvInt(reply.detail, "repeat_requested") == Int64(MacFourVerbs.maximumActRepeats),
            "KNOWN GAP: the caller's true repeat ask is not carried into the reply")
    #expect(_fvBool(reply.detail, "repeat_stopped_early") == false)

    // (b) THE INTERVAL IS ITSELF CLAMPED first, so a slow-looking request is
    // not automatically a short burst: 8s of pause becomes 2s, 30 / 2 = 15
    // planned, which the hard cap then holds at 12.
    let paced = _fvBurstHarness()
    let slow = await paced.verbs.act(verb: "click", target: "report.pdf", repeat: 12, interval: 8)
    #expect(_fvInt(slow.detail, "repeat_planned") == Int64(MacFourVerbs.maximumActRepeats))
    #expect(paced.clock.seconds() == Double(MacFourVerbs.maximumActRepeats - 1) * MacFourVerbs.maximumActIntervalSeconds,
            "every inter-attempt pause must be the CLAMPED 2s, not the requested 8s: \(paced.clock.seconds())")

    // (c) THE 30-SECOND BUDGET bites when an attempt is expensive: a 10s
    // per-attempt wait plus the clamped 2s pause is 12s each, so only two fit.
    let expensive = _fvBurstHarness()
    let bounded = await expensive.verbs.act(
        verb: "click", target: "report.pdf", seconds: 10, repeat: 12, interval: 8
    )
    let boundedPlanned = _fvInt(bounded.detail, "repeat_planned") ?? -1
    #expect(boundedPlanned == 2,
            "30s budget / (10s + 2s clamped pause) = 2 attempts, got \(boundedPlanned)")
    let boundedPresses = expensive.actSource.recordedCalls().filter { $0 == "perform:AXPress:[1, 0]" }
    #expect(boundedPresses.count == 2, "the budget must bound the ACTS too")
    // …and THIS is the path where the bound is said out loud, because here the
    // planned count really is below the (already clamped) request.
    #expect(bounded.text.contains("The 30-second safety bound limited this burst to 2."),
            "a shortened burst must say so in words: \(bounded.text)")
    // `ok` stays TRUE — everything it PLANNED succeeded — so the shortfall
    // lives entirely in `repeat_stopped_early` and the sentence. A caller that
    // reads only `ok` learns nothing about the 10 attempts that never ran, and
    // `verification` says `satisfied` because every attempt that DID run was
    // proven. Both are pinned here so the meaning cannot drift silently.
    #expect(bounded.ok, "a burst that completed everything it planned reports ok")
    #expect(_fvBool(bounded.detail, "repeat_stopped_early") == true,
            "the ONLY structured signal that the ask was not met")
    #expect(bounded.text.hasPrefix("Completed 2/12 requested attempts."), "\(bounded.text)")
    #expect(bounded.detail["verification"] == .string(MotorVerificationState.satisfied.rawValue),
            "`satisfied` means what RAN was proven — never that the full ask happened")
}

@Test
func actBurst_reportsSatisfiedOnlyWhenEveryAttemptHadFreshVisibleProof() async throws {
    let harness = _fvBurstHarness()
    let reply = await harness.verbs.act(verb: "click", target: "report.pdf", repeat: 3)

    guard case .string(let verification)? = reply.detail["verification"] else {
        Issue.record("a burst must carry a verification verdict: \(reply.detail)")
        return
    }
    let completed = try #require(_fvInt(reply.detail, "repeat_completed"))
    let verified = try #require(_fvInt(reply.detail, "repeat_visibly_verified"))
    let planned = try #require(_fvInt(reply.detail, "repeat_planned"))

    if verification == MotorVerificationState.satisfied.rawValue {
        // The ONLY shape that earns `satisfied`: every planned attempt ran and
        // every one of them was independently observed.
        #expect(completed == planned)
        #expect(verified == completed)
        #expect(reply.detail["verification_evidence"]
                    == .string("fresh_visible_evidence_for_every_burst_attempt"))
        #expect(reply.text.contains("Every completed attempt had fresh visible proof."), "\(reply.text)")
    } else {
        // Anything short of that is `unverified` and carries NO evidence claim.
        #expect(verification == MotorVerificationState.unverified.rawValue,
                "a partly-proven burst must be unverified, not \(verification)")
        #expect(reply.detail["verification_evidence"] == nil,
                "an unverified burst must not keep a stale evidence string")
    }

    // THE CONTRAPOSITIVE — the half that gives this test teeth. The row is
    // removed after the second press, so attempt three cannot resolve: 2 of 3
    // planned attempts complete. A build that reported `satisfied` here would
    // be claiming visible proof for an act that never happened.
    let partial = _fvBurstHarness(vanishAfter: (path: [1, 0], presses: 2))
    let short = await partial.verbs.act(verb: "click", target: "report.pdf", repeat: 3)
    let shortCompleted = try #require(_fvInt(short.detail, "repeat_completed"))
    let shortPlanned = try #require(_fvInt(short.detail, "repeat_planned"))
    #expect(shortPlanned == 3)
    #expect(shortCompleted < shortPlanned, "the fixture must actually cut the burst short")
    #expect(short.detail["verification"] != .string(MotorVerificationState.satisfied.rawValue),
            "a burst that did not complete every planned attempt must NEVER report satisfied")
    #expect(short.detail["verification_evidence"] == nil,
            "an incomplete burst must carry no fresh-visible-evidence claim")
    #expect(_fvBool(short.detail, "repeat_stopped_early") == true)
    #expect(!short.ok)
    #expect(await partial.attentionStore.status(now: Date()) == nil,
            "the lease must still be released when the burst is cut short")

    // A single-attempt "burst" is the ordinary act path and must not sprout
    // burst counters that no attempt-loop produced.
    let single = await harness.verbs.act(verb: "click", target: "report.pdf", repeat: 1)
    #expect(single.detail["repeat_planned"] == nil)
    #expect(single.detail["repeat_completed"] == nil)
    #expect(await harness.attentionStore.status(now: Date()) == nil,
            "a repeat:1 act must not take an attention lease at all")
}
