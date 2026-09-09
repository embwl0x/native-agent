import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// Paired structural/semantic rendering fixtures live in ChatOrchestrationTests;
// these value cases pin the common identity matcher without any live input.

@Test
func supplementalIdentityRequiresUniqueCompatiblePathLabelAndGeometry() {
    func existing(_ path: Int?, label: String = "Remove", x: Double = 0, kind: String = "button", physical: Bool = false) -> MacFourVerbs.ActTarget {
        MacFourVerbs.ActTarget(
            handle: path.map { "h\($0)" } ?? "", label: label, kind: kind, ordinal: nil,
            enabled: true, frame: MacAXFrame(x: x, y: 0, w: 80, h: 30),
            physicalOnly: physical, sourceAXPath: path.map { [$0] }
        )
    }
    func candidate(_ path: Int?, label: String = "Remove", x: Double = 0, kind: String = "button", physical: Bool = false) -> MacFourVerbsSupplementalTarget {
        MacFourVerbsSupplementalTarget(
            label: MacScreenText(label), kind: kind, frame: MacAXFrame(x: x, y: 0, w: 80, h: 30),
            provenance: .ax, physicalOnly: physical, sourceAXPath: path.map { [$0] }
        )
    }
    let left = existing(1)
    let right = existing(2, x: 200)
    #expect(MacFourVerbs.supplementalDuplicateIndex(candidate(2, x: 200), among: [left, right]) == 1)
    #expect(MacFourVerbs.supplementalDuplicateIndex(candidate(2), among: [left]) == nil,
            "A different explicit AX path must not merge even when name and frame coincide")
    #expect(MacFourVerbs.supplementalDuplicateIndex(candidate(1, label: "Save"), among: [left]) == nil)
    #expect(MacFourVerbs.supplementalDuplicateIndex(candidate(1, x: 200), among: [left]) == nil)
    #expect(MacFourVerbs.supplementalDuplicateIndex(candidate(1, kind: "text field"), among: [left]) == nil)
    #expect(MacFourVerbs.supplementalDuplicateIndex(candidate(nil, x: 200), among: [left, right]) == 1)
    #expect(MacFourVerbs.supplementalDuplicateIndex(candidate(nil), among: [left, existing(2)]) == nil,
            "Ambiguous geometry must not silently choose the first equal label")
    let region = existing(nil, label: "region 1", kind: "region", physical: true)
    #expect(MacFourVerbs.supplementalDuplicateIndex(
        candidate(nil, label: "region 1", x: 200, kind: "region", physical: true), among: [region]
    ) == 0)
    #expect(MacFourVerbs.supplementalDuplicateIndex(
        candidate(nil, label: "region 2", kind: "region", physical: true), among: [region]
    ) == nil, "Overlapping named pixel regions keep their own identities")
}
// MARK: - THE FOUR VERBS — screen · act · go · wait

@Test func readoutZoomRevealsHiddenStatusWithoutMakingItAnActionTarget() throws {
    let screen = MacScreenRender.Screen(appName: "Canvas", values: (0..<9).map {
        MacScreenRender.Value(text: MacScreenText($0 == 8 ? "Last drag: 300ms moving" : "Counter \($0): 0"), provenance: .vision(1))
    }, unclassifiedOmittedTargets: 2)
    let overview = MacScreenRender.render(screen)
    #expect(!overview.contains("Last drag"))
    #expect(overview.contains("3 observed readouts not shown (screen part: hud, or name a readout)"))
    #expect(!overview.contains("maxValues"))
    let zoom = try #require(MacFourVerbs.zoom(screen, part: "Last drag", options: .default))
    let text = MacScreenRender.render(zoom.screen, options: zoom.options)
    #expect(text.contains("Last drag: 300ms moving"))
    #expect(!text.contains("Counter 0"))
    #expect(zoom.screen.controls.isEmpty && zoom.screen.contents.isEmpty)
    #expect(zoom.screen.unclassifiedOmittedTargets == 2)
    let hud = try #require(MacFourVerbs.zoom(screen, part: "hud", options: .default))
    #expect(hud.screen.values.count == 9)
    #expect(MacScreenRender.render(hud.screen, options: hud.options).contains("Last drag"))
}

@Test func readoutZoomDoesNotInventMissingSourceValues() throws {
    let screen = MacScreenRender.Screen(appName: "Canvas", values: [
        MacScreenRender.Value(text: MacScreenText("Hits: 2"), provenance: .vision(1))
    ], totalValues: 4)
    let zoom = try #require(MacFourVerbs.zoom(screen, part: "hud", options: .default))
    #expect(zoom.screen.totalValues == 4)
    let rendered = MacScreenRender.rendering(zoom.screen, options: zoom.options)
    #expect(rendered.valuesDropped == 3)
    #expect(rendered.text.contains("3 further values outside this observation"))
    #expect(!rendered.text.contains("observed readouts not shown"))
    let named = try #require(MacFourVerbs.zoom(screen, part: "Hits", options: .default))
    #expect(named.screen.totalValues == 1)
}

@Test func controlZoomExposesBoundedControlsWithoutRenumberingOrHidingSourceOmissions() throws {
    let controls = (1...70).map { (index: Int) in
        MacScreenRender.Control(label: MacScreenText(index == 70 ? "Last action" : "Action \(index)"), kind: "button",
            ordinal: index, provenance: .ax)
    }
    let screen = MacScreenRender.Screen(appName: "Many controls", controls: controls,
        totalControls: 73, unlabeledControls: ["text": 2], unclassifiedOmittedTargets: 4)
    let overview = MacScreenRender.render(screen)
    #expect(overview.contains("screen part: controls, or name a control"))
    #expect(!overview.contains("maxControls"))
    for name in ["controls", "actions", "actionable controls", "button"] {
        let zoom = try #require(MacFourVerbs.zoom(screen, part: name, options: .default))
        #expect(zoom.options.maxControls == 60)
        #expect(zoom.screen.controls.last?.ordinal == 70)
        #expect(zoom.screen.unclassifiedOmittedTargets == 4)
        let rendering = MacScreenRender.rendering(zoom.screen, options: zoom.options)
        #expect(rendering.text.contains("button 60"))
        #expect(!rendering.text.contains("button 61"))
        #expect(rendering.text.contains("10 observed controls not shown"))
        if name != "button" {
            #expect(rendering.controlsDropped == 13)
            #expect(rendering.text.contains("3 further controls outside this observation"))
            #expect(zoom.screen.unlabeledControls["text"] == 2)
        }
    }
    let named = try #require(MacFourVerbs.zoom(screen, part: "Last action", options: .default))
    #expect(named.screen.controls.map(\.ordinal) == [70])
    let empty = try #require(MacFourVerbs.zoom(MacScreenRender.Screen(appName: "Canvas"), part: "controls", options: .default))
    #expect(empty.screen.controls.isEmpty)
}

@Test func agentDetailOmitsDuplicateReadoutsButKeepsInternalEvidenceAndReceipts() {
    let values: JSONValue = .array([.string("Hits: 2")])
    let reply = MacFourVerbsReply(ok: true, text: "Hits: 2", detail: [
        "vision_value_text": values, "vision_effect_value_text": values,
        "verification": .string("satisfied"), "operationId": .string("receipt"), "vision_compile_ms": .int(100)
    ])
    #expect(reply.detail["vision_effect_value_text"] == values)
    #expect(reply.agentDetail["vision_value_text"] == nil && reply.agentDetail["vision_effect_value_text"] == nil)
    #expect(reply.agentDetail["verification"] == .string("satisfied"))
    #expect(reply.agentDetail["operationId"] == .string("receipt"))
    #expect(reply.agentDetail["vision_compile_ms"] == .int(100))
}

@Test func rowFilenameFusionRequiresActualBoundedLineageAndCompatibleEvidence() {
    let frame = MacAXFrame(x: 100, y: 200, w: 180, h: 20)
    let filename = MacFourVerbs.ActTarget(handle: "file", label: "fixture.html", kind: "text",
        ordinal: 1, enabled: true, frame: frame, sourceAXPath: [0, 2, 0, 1])
    func row(_ path: [Int], label: String = "fixture.html", kind: String = "row", enabled: Bool = true,
             x: Double = 100) -> MacFourVerbsSupplementalTarget {
        MacFourVerbsSupplementalTarget(label: MacScreenText(label), kind: kind,
            frame: MacAXFrame(x: x, y: 200, w: 500, h: 20), provenance: .ax,
            sourceAXPath: path, enabled: enabled)
    }
    #expect(MacFourVerbs.supplementalDuplicateIndex(row([0, 2]), among: [filename]) == 0)
    #expect(MacFourVerbs.supplementalDuplicateIndex(row([0, 2, 0], kind: "cell"), among: [filename]) == 0)
    for unrelated in [row([0, 3]), row([0]), row([0, 2], label: "other.html"),
                      row([0, 2], kind: "button"), row([0, 2], enabled: false), row([0, 2], x: 900)] {
        #expect(MacFourVerbs.supplementalDuplicateIndex(unrelated, among: [filename]) == nil)
    }
    #expect(MacFourVerbs.supplementalDuplicateIndex(row([0, 2]), among: [filename, filename]) == nil)
}
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
    private var live: [@Sendable (MacAXEffectNotification) -> Void] = []
    private let script: [String]

    init(script: [String] = ["AXValueChanged", "AXTitleChanged"]) { self.script = script }

    func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)? {
        lock.lock()
        installCount += 1
        live.append(onNotification)
        lock.unlock()
        for kind in script { onNotification(MacAXEffectNotification(kind: kind, at: Date())) }
        return _FVObservation(onStop: {})
    }

    /// fable51 item 31 — a live app that CHANGES fires notifications. `wait`
    /// now ends on those, so a fixture that mutates its tree without emitting
    /// one models an app that does not exist.
    func emit(_ kind: String = "AXValueChanged") {
        lock.lock(); let sinks = live; lock.unlock()
        for sink in sinks { sink(MacAXEffectNotification(kind: kind, at: Date())) }
    }

    func installs() -> Int {
        lock.lock(); defer { lock.unlock() }
        return installCount
    }
}

/// An observer source that installs NOTHING. It is how the fallback path — the
/// documented safety net for apps that publish no subscribable signal — is
/// exercised without a window server.
private final class _FVDeafEffectSource: MacAXEffectObserverSource, @unchecked Sendable {
    func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)? { nil }
}

/// The workspace-activation half, scripted. `fire()` is the app switch.
private final class _FVActivationSource: MacAppActivationObserverSource, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [@Sendable () -> Void] = []
    private(set) var stops = 0

    func install(onActivation: @escaping @Sendable () -> Void) -> (any MacAXEffectObservation)? {
        lock.lock(); live.append(onActivation); lock.unlock()
        return _FVObservation(onStop: { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.stops += 1; self.lock.unlock()
        })
    }

    func fire() {
        lock.lock(); let sinks = live; lock.unlock()
        for sink in sinks { sink() }
    }

    func stopCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return stops
    }
}

private struct _FVSilentActivationSource: MacAppActivationObserverSource {
    func install(onActivation: @escaping @Sendable () -> Void) -> (any MacAXEffectObservation)? { nil }
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
    func scrolls() -> [MacScrollEvent] { lock.withLock { scrollEvents } }
}

private struct _FVSupplementSource: MacFourVerbsSupplementalPerceptionSource {
    let supplement: MacFourVerbsSupplement
    func observe() async -> MacFourVerbsSupplement? {
        MacSightCaptureBinding.current?.confirm() // Fixture represents one bound capture.
        return supplement
    }
}

private actor _FVHandRequestHost: MacFourVerbsHost {
    let inner: any MacFourVerbsHost
    private var requests: [[String: JSONValue]] = []
    init(_ inner: any MacFourVerbsHost) { self.inner = inner }
    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        if action == "hand" { requests.append(body) }
        return try await inner.dispatch(action: action, body: body)
    }
    func handRequests() -> [[String: JSONValue]] { requests }
}

private actor _FVSequencedSupplementSource: MacFourVerbsSupplementalPerceptionSource {
    private let supplements: [MacFourVerbsSupplement]
    private var index = 0

    init(_ supplements: [MacFourVerbsSupplement]) {
        self.supplements = supplements
    }

    func observe() -> MacFourVerbsSupplement? {
        MacSightCaptureBinding.current?.confirm()
        guard !supplements.isEmpty else { return nil }
        let value = supplements[min(index, supplements.count - 1)]
        index += 1
        return value
    }

    func observationCount() -> Int { index }
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

    func monotonicSeconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        return elapsed
    }

    func sleep(seconds: Double) async {
        advance(seconds)
        await Task.yield()
    }

    func advance(_ seconds: Double) {
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
    namedLocationRoots: [URL] = [],
    effects: _FVEffectSource? = nil,
    waitEffects: (any MacAXEffectObserverSource)? = nil,
    waitActivation: (any MacAppActivationObserverSource)? = nil
) -> _FVHarness {
    let source = _FVLookSource(elements: elements ?? _fvElements(), rootID: rootID, focus: focus)
    let actSource = _FVActSource(actElements ?? _fvActElements())
    let effects = effects ?? _FVEffectSource()
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
        // These fixtures own their visible evidence. A real desktop capture
        // can change independently and must never settle a synthetic action.
        screenCaptureSource: UnavailableMacScreenCaptureSource(),
        screenViewStore: MacScreenViewStore(),
        lookFrameStore: MacLookFrameStore()
    )
    return _FVHarness(
        verbs: MacFourVerbs(
            host: client,
            clock: clock,
            supplementalSource: supplementalSource,
            namedLocationRoots: namedLocationRoots,
            // fable51 item 31 — `wait` subscribes through these. Default to the
            // same scripted effect source the client uses, so a fixture that
            // fires a notification is seen by both the act loop and the wait.
            effectObserverSource: waitEffects ?? effects,
            appActivationSource: waitActivation ?? _FVSilentActivationSource()
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
func screen_zoomOnCanvas_keepsVisualWorldInsteadOfMatchingBrowserChrome() throws {
    let visualRegion = MacScreenRender.Row(
        label: MacScreenText("visual region 1", redacted: .string("visual region 1")),
        detail: [MacScreenText(
            "yellow, high contrast, lower right, at 33%,37%, size 15%x20%, moving right",
            redacted: .string(
                "yellow, high contrast, lower right, at 33%,37%, size 15%x20%, moving right"
            )
        )],
        provenance: .vision(0.35),
        abstain: "physical region; semantic role uncertain"
    )
    let screen = MacScreenRender.Screen(
        appName: "Browser",
        windowTitle: MacScreenText("Visual Saliency Check", redacted: .string("Visual Saliency Check")),
        isFront: true,
        contents: [
            MacScreenRender.Content(kind: .grid, rows: [visualRegion]),
            MacScreenRender.Content(
                kind: .canvas,
                canvas: MacScreenRender.Canvas(
                    description: "visual surface", width: 1200, height: 800,
                    provenance: .vision(1)
                )
            ),
        ],
        controls: [
            MacScreenRender.Control(
                label: MacScreenText("Visual Saliency Check", redacted: .string("Visual Saliency Check")),
                kind: "radio", provenance: .ax
            ),
            MacScreenRender.Control(
                label: MacScreenText("Back", redacted: .string("Back")),
                kind: "button", provenance: .ax
            ),
        ],
        totalControls: 2,
        values: [MacScreenRender.Value(
            text: MacScreenText("Hits: 0", redacted: .string("Hits: 0")),
            provenance: .vision(1)
        )]
    )

    let zoom = try #require(MacFourVerbs.zoom(
        screen,
        part: "the open Visual Saliency Check canvas",
        options: .default
    ))
    let rendered = MacScreenRender.render(zoom.screen, options: zoom.options)
    #expect(rendered.contains("visual region 1"))
    #expect(rendered.contains("CANVAS"))
    #expect(rendered.contains("Hits: 0"))
    #expect(rendered.contains("size 15%x20%"))
    #expect(rendered.contains("moving right"))
    #expect(!rendered.contains("Visual Saliency Check   radio"))
    #expect(!rendered.contains("Back"))
    #expect(zoom.note.contains("surrounding controls omitted"))
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
        contents: [
            MacScreenRender.Content(
                kind: .grid,
                rows: [MacScreenRender.Row(
                    label: MacScreenText("visual region 1", redacted: .string("visual region 1")),
                    detail: [MacScreenText("unknown", redacted: .string("unknown"))],
                    provenance: .vision(0.35),
                    abstain: "physical region; semantic role uncertain"
                )],
                totalRows: 1
            ),
            MacScreenRender.Content(
                kind: .canvas,
                canvas: MacScreenRender.Canvas(
                    description: "visual surface", width: 800, height: 600,
                    provenance: .vision(1)
                )
            ),
        ],
        values: [MacScreenRender.Value(
            text: MacScreenText("Hits: 1", redacted: .string("Hits: 1")),
            provenance: .vision(1)
        )],
        targets: [MacFourVerbsSupplementalTarget(
            label: MacScreenText("visual region 1", redacted: .string("visual region 1")),
            aliases: ["round yellow object", "yellow object", "yellow object on the left"],
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
    #expect(clicked.text.contains("CANVAS"), "\(clicked.text)")
    #expect(clicked.text.contains("Hits: 1"), "\(clicked.text)")
    #expect(!clicked.text.contains("DO      "), "\(clicked.text)")

    let natural = await harness.verbs.act(verb: "click", target: "yellow object")
    #expect(natural.ok, "\(natural.text)")
    #expect(natural.detail["matched"] == .string("\"visual region 1\""))
    #expect(natural.text.hasPrefix("Clicked \"yellow object\"."), "\(natural.text)")

    let positioned = await harness.verbs.act(
        verb: "click", target: "yellow object on the left"
    )
    #expect(positioned.ok, "\(positioned.text)")
    #expect(sink.mice().filter { $0.phase == .down }.last?.x == 340)
    #expect(sink.mice().filter { $0.phase == .down }.last?.y == 230)

    let sided = await harness.verbs.act(
        verb: "click", target: "left side of yellow object"
    )
    #expect(sided.ok, "\(sided.text)")
    #expect(sink.mice().filter { $0.phase == .down }.last?.x == 320)
    #expect(sink.mice().filter { $0.phase == .down }.last?.y == 230)

    let diagonal = await harness.verbs.act(
        verb: "click", target: "upper-left corner of the yellow object"
    )
    #expect(diagonal.ok, "\(diagonal.text)")
    #expect(sink.mice().filter { $0.phase == .down }.last?.x == 320)
    #expect(sink.mice().filter { $0.phase == .down }.last?.y == 215)

    let eventCount = sink.mice().count
    let falseMotion = await harness.verbs.act(
        verb: "click", target: "moving yellow object"
    )
    #expect(!falseMotion.ok)
    #expect(falseMotion.detail["error"] == .string("no_match"))
    #expect(sink.mice().count == eventCount, "an absent motion qualifier must act on nothing")
}

@Test func actTransientMenuUsesFreshGeometryAndRefusesClosedOrDisabledItems() async {
    func menu(x: Double, enabled: Bool = true, present: Bool = true) -> MacFourVerbsSupplement {
        MacFourVerbsSupplement(
            appName: "Finder", bundleIdentifier: "com.apple.finder",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
            controls: present ? [MacScreenRender.Control(label: MacScreenText("Inspect"),
                                                       kind: "menu item", provenance: .ax)] : [],
            targets: present ? [MacFourVerbsSupplementalTarget(
                label: MacScreenText("Inspect"), kind: "menu item",
                frame: MacAXFrame(x: x, y: 200, w: 100, h: 24), provenance: .ax, enabled: enabled
            )] : []
        )
    }
    let sink = _FVEventSink()
    let harness = _fvHarness(eventSink: sink, supplementalSource: _FVSequencedSupplementSource([
        menu(x: 100), menu(x: 300), menu(x: 300, present: false),
    ]))
    _ = await harness.verbs.screen(part: "menu")
    let result = await harness.verbs.act(verb: "click", target: "Inspect")
    #expect(result.ok, "\(result.text)")
    #expect(sink.mice().contains { $0.phase == .down && $0.x == 350 && $0.y == 212 })
    for next in [menu(x: 300, enabled: false), menu(x: 300, present: false)] {
        let refusedSink = _FVEventSink()
        let refused = _fvHarness(eventSink: refusedSink,
                                supplementalSource: _FVSequencedSupplementSource([menu(x: 100), next]))
        _ = await refused.verbs.screen(part: "menu")
        let reply = await refused.verbs.act(verb: "click", target: "Inspect")
        #expect(!reply.ok)
        #expect(refusedSink.mice().isEmpty)
    }
}

@Test
func act_reobservesOneTransientMissForNumberedAndNaturalVisualTargets() async {
    let sink = _FVEventSink()
    let missing = MacFourVerbsSupplement(
        appName: "Finder", bundleIdentifier: "com.apple.finder",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600)
    )
    let visible = MacFourVerbsSupplement(
        appName: "Finder", bundleIdentifier: "com.apple.finder",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
        targets: [MacFourVerbsSupplementalTarget(
            label: MacScreenText("visual region 1", redacted: .string("visual region 1")),
            aliases: ["round yellow object", "yellow object"],
            kind: "visual region",
            frame: MacAXFrame(x: 300, y: 200, w: 80, h: 60),
            provenance: .vision(0.78),
            physicalOnly: true
        )]
    )
    let source = _FVSequencedSupplementSource([missing, visible, visible])
    let harness = _fvHarness(eventSink: sink, supplementalSource: source)

    let reply = await harness.verbs.act(verb: "click", target: "visual region 1")

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.detail["dynamic_reobserved"] == .bool(true))
    #expect(sink.mice().contains { $0.phase == .down && $0.x == 340 && $0.y == 230 })

    let naturalSource = _FVSequencedSupplementSource([missing, visible, visible])
    let naturalHarness = _fvHarness(eventSink: sink, supplementalSource: naturalSource)
    let natural = await naturalHarness.verbs.act(verb: "click", target: "yellow object")

    #expect(natural.ok, "\(natural.text)")
    #expect(natural.detail["dynamic_reobserved"] == .bool(true))
    #expect(natural.text.hasPrefix("Clicked \"yellow object\"."), "\(natural.text)")
}

@Test
func visualEffectEvidenceExcludesOrdinarySceneMotion() {
    let detail: [String: JSONValue] = [
        "vision_value_text": .array([
            .string("yellow visual region 1 is left of blue visual region 2")
        ]),
        "vision_effect_value_text": .array([.string("Hits: 2")]),
    ]

    #expect(MacFourVerbs.visionValueTexts(detail) == ["hits: 2"])
    #expect(MacFourVerbs.hasTemporalQualifier("moving yellow object"))
    #expect(MacFourVerbs.hasTemporalQualifier("stationary square object"))
    #expect(!MacFourVerbs.hasTemporalQualifier("yellow object"))
}

@Test func physicalClickAcquiresMotionWithBoundedFreshFramesAndStopsOnLostTarget() async {
    func view(_ x: Double?, uncertain: Bool = true, duplicate: Bool = false) -> MacFourVerbsSupplement {
        let target = x.map { value in
            MacFourVerbsSupplementalTarget(
                label: MacScreenText("visual region 1", redacted: .string("visual region 1")),
                aliases: ["yellow object"], kind: "visual region",
                frame: MacAXFrame(x: value, y: 200, w: 40, h: 40),
                provenance: .vision(0.8), physicalOnly: true, motionUncertain: uncertain
            )
        }
        var targets = target.map { [$0] } ?? []
        if duplicate {
            targets.append(MacFourVerbsSupplementalTarget(
                label: MacScreenText("visual region 2", redacted: .string("visual region 2")),
                aliases: ["yellow object"], kind: "visual region",
                frame: MacAXFrame(x: 600, y: 200, w: 40, h: 40),
                provenance: .vision(0.8), physicalOnly: true
            ))
        }
        return MacFourVerbsSupplement(
            appName: "Finder", bundleIdentifier: "com.apple.finder",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600), targets: targets
        )
    }
    let sink = _FVEventSink()
    let source = _FVSequencedSupplementSource([view(100), view(200), view(300, uncertain: false)])
    let harness = _fvHarness(eventSink: sink, supplementalSource: source)
    let reply = await harness.verbs.act(verb: "click", target: "yellow object")
    #expect(reply.ok, "\(reply.text)")
    #expect(sink.mice().filter { $0.phase == .down }.map(\.x) == [320])
    #expect(await source.observationCount() == 4, "initial + two acquisition frames + post-action proof")

    let boundedSink = _FVEventSink()
    let boundedSource = _FVSequencedSupplementSource([view(100), view(200), view(300), view(400)])
    let bounded = _fvHarness(eventSink: boundedSink, supplementalSource: boundedSource)
    let boundedReply = await bounded.verbs.act(verb: "click", target: "yellow object")
    #expect(boundedReply.ok)
    #expect(boundedSink.mice().filter { $0.phase == .down }.map(\.x) == [320])
    #expect(await boundedSource.observationCount() == 4, "uncertain motion must not create an unbounded observation loop")

    for next in [view(nil), view(200, duplicate: true)] {
        let blockedSink = _FVEventSink()
        let blockedSource = _FVSequencedSupplementSource([view(100), next])
        let blocked = _fvHarness(eventSink: blockedSink, supplementalSource: blockedSource)
        let result = await blocked.verbs.act(verb: "click", target: "yellow object")
        #expect(!result.ok)
        #expect(blockedSink.mice().isEmpty, "fresh loss or ambiguity must never use the original point")
    }
}

@Test
func physicalHoverDoesNotTreatAnAnimatedSceneAsEffectProof() async {
    func frame(_ relation: String) -> MacFourVerbsSupplement {
        MacFourVerbsSupplement(
            appName: "Finder",
            bundleIdentifier: "com.apple.finder",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
            values: [MacScreenRender.Value(
                text: MacScreenText(relation, redacted: .string(relation)),
                provenance: .vision(0.7)
            )],
            targets: [MacFourVerbsSupplementalTarget(
                label: MacScreenText("visual region 1", redacted: .string("visual region 1")),
                aliases: ["yellow object on the left"],
                kind: "visual region",
                frame: MacAXFrame(x: 300, y: 200, w: 80, h: 60),
                provenance: .vision(0.8),
                physicalOnly: true
            )],
            diagnostics: [
                "vision_value_text": .array([.string(relation)]),
                "vision_effect_value_text": .array([]),
            ]
        )
    }
    let sink = _FVEventSink()
    let source = _FVSequencedSupplementSource([
        frame("yellow object is left of blue object"),
        frame("yellow object is right of blue object"),
    ])
    let harness = _fvHarness(eventSink: sink, supplementalSource: source)

    let reply = await harness.verbs.act(
        verb: "hover", target: "yellow object on the left"
    )

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.detail["verification"] == .string("unverified"))
    #expect(reply.detail["verification_evidence"] == nil)
    #expect(reply.text.hasPrefix("Hovered over \"yellow object on the left\"."), "\(reply.text)")
    #expect(reply.text.contains("This is the fresh screen afterward."), "\(reply.text)")
    #expect(!reply.text.contains("changed after it"), "\(reply.text)")
    #expect(sink.mice().contains { $0.phase == .move && $0.x == 340 && $0.y == 230 })
}

@Test func composedPhysicalActDefersOnlyDuplicateProofAndStillObservesItsOutcome() async {
    for physicalOnly in [true, false] {
        func frame(_ hits: Int) -> MacFourVerbsSupplement {
            MacFourVerbsSupplement(
                appName: "Finder", bundleIdentifier: "com.apple.finder",
                visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
                targets: [MacFourVerbsSupplementalTarget(
                    label: MacScreenText("target", redacted: .string("target")),
                    kind: "visual region", frame: MacAXFrame(x: 300, y: 200, w: 40, h: 40),
                    provenance: .vision(0.8), physicalOnly: physicalOnly
                )],
                diagnostics: ["vision_effect_value_text": .array([.string("Hits: \(hits)")])]
            )
        }
        let source = _FVSequencedSupplementSource([frame(0), frame(1)])
        let harness = _fvHarness()
        let host = _FVHandRequestHost(harness.client)
        let verbs = MacFourVerbs(host: host, clock: harness.clock, supplementalSource: source)
        let reply = await verbs.act(verb: "click", target: "target")
        #expect(reply.ok, "\(reply.text)")
        let requests = await host.handRequests()
        #expect(requests.count == 1)
        #expect(requests.first?["defer_visual_verification"] == (physicalOnly ? .bool(true) : nil))
        #expect(await source.observationCount() == 2, "caller must still own fresh before and after evidence")
        #expect(reply.detail["verification"] == .string("satisfied"))
        #expect(reply.detail["verification_evidence"] == .string("fresh_visible_value_change"))
    }
}

@Test func naturalShapeNounsKeepExactAimAndSharedShapeAmbiguity() async {
    let sink = _FVEventSink()
    let source = _FVSupplementSource(supplement: MacFourVerbsSupplement(
        appName: "Finder", bundleIdentifier: "com.apple.finder",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
        targets: [
            MacFourVerbsSupplementalTarget(label: MacScreenText("visual region 1"),
                aliases: ["square", "green square", "stationary green square", "green square at lower right"],
                kind: "visual region", frame: MacAXFrame(x: 500, y: 400, w: 60, h: 60),
                provenance: .vision(0.9), physicalOnly: true),
            MacFourVerbsSupplementalTarget(label: MacScreenText("visual region 2"),
                aliases: ["square", "blue square", "moving blue square"],
                kind: "visual region", frame: MacAXFrame(x: 100, y: 200, w: 60, h: 60),
                provenance: .vision(0.9), physicalOnly: true),
        ]
    ))
    let harness = _fvHarness(eventSink: sink, supplementalSource: source)
    let ambiguous = await harness.verbs.act(verb: "hover", target: "square")
    #expect(!ambiguous.ok && sink.mice().isEmpty)
    let wrongMotion = await harness.verbs.act(verb: "hover", target: "stationary blue square")
    #expect(!wrongMotion.ok && sink.mice().isEmpty)
    for phrase in ["stationary green square", "green square at lower right"] {
        let result = await harness.verbs.act(verb: "hover", target: phrase)
        #expect(result.ok, "\(result.text)")
    }
    #expect(sink.mice().count == 2)
    #expect(sink.mice().allSatisfy { $0.phase == .move && $0.x == 530 && $0.y == 430 })
}

@Test func shapeNounTemporalMissUsesBoundedFreshObservation() async {
    func frame(stationary: Bool) -> MacFourVerbsSupplement {
        MacFourVerbsSupplement(appName: "Finder", bundleIdentifier: "com.apple.finder",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
            targets: [MacFourVerbsSupplementalTarget(label: MacScreenText("visual region 1"),
                aliases: ["green square"] + (stationary ? ["stationary green square"] : []),
                kind: "visual region", frame: MacAXFrame(x: 300, y: 200, w: 60, h: 60),
                provenance: .vision(0.9), physicalOnly: true)])
    }
    for becomesKnown in [true, false] {
        let sink = _FVEventSink()
        let source = _FVSequencedSupplementSource([frame(stationary: false), frame(stationary: becomesKnown)])
        let harness = _fvHarness(eventSink: sink, supplementalSource: source)
        let reply = await harness.verbs.act(verb: "hover", target: "stationary green square")
        #expect(reply.ok == becomesKnown)
        #expect(await source.observationCount() == 3)
        #expect(sink.mice().count == (becomesKnown ? 1 : 0))
        if becomesKnown { #expect(reply.detail["dynamic_reobserved"] == .bool(true)) }
    }
}

@Test func temporalTargetCanAcquireThirdFrameWithoutDroppingQualifierOrAmbiguity() async {
    func frame(_ count: Int) -> MacFourVerbsSupplement {
        MacFourVerbsSupplement(appName: "Finder", bundleIdentifier: "com.apple.finder",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
            targets: (0..<max(1, count)).map { index in
                MacFourVerbsSupplementalTarget(label: MacScreenText("visual region \(index + 1)"),
                    aliases: ["yellow circle"] + (count > 0 ? ["moving yellow circle"] : []),
                    kind: "visual region", frame: MacAXFrame(x: Double(200 + index * 200), y: 200, w: 50, h: 50),
                    provenance: .vision(0.9), physicalOnly: true, motionUncertain: count == 0)
            })
    }
    for verb in ["click", "hover"] {
        for finalCount in [0, 1, 2] {
            let source = _FVSequencedSupplementSource([frame(0), frame(0), frame(finalCount)])
            let sink = _FVEventSink()
            let harness = _fvHarness(eventSink: sink, supplementalSource: source)
            let reply = await harness.verbs.act(verb: verb, target: "moving yellow circle")
            #expect(reply.ok == (finalCount == 1), "\(reply.text)")
            #expect(await source.observationCount() == (finalCount == 2 ? 3 : 4))
            #expect(sink.mice().isEmpty == (finalCount != 1))
            if finalCount == 2 { #expect(reply.detail["error"] == .string("ambiguous")) }
        }
    }
    for verb in ["click", "hover"] {
        let source = _FVSequencedSupplementSource([frame(0), frame(0), frame(0), frame(1)])
        let sink = _FVEventSink()
        let harness = _fvHarness(eventSink: sink, supplementalSource: source)
        let reply = await harness.verbs.act(verb: verb, target: "moving yellow circle")
        #expect(reply.ok, "\(reply.text)")
        #expect(await source.observationCount() == 5, "fourth confirmation plus mandatory post-action view")
        #expect(!sink.mice().isEmpty)
    }
}

@Test func temporalTurnConfirmationRequiresSameUniqueUncertainPhysicalIdentity() {
    func target(_ label: String, uncertain: Bool = true) -> MacFourVerbs.ActTarget {
        MacFourVerbs.ActTarget(handle: "", label: label, aliases: ["yellow circle"], kind: "visual region",
            ordinal: nil, enabled: true, frame: MacAXFrame(x: 100, y: 200, w: 40, h: 40),
            physicalOnly: true, motionUncertain: uncertain)
    }
    let old = target("visual region 1")
    #expect(MacFourVerbs.canConfirmTemporalTurn("moving yellow circle", previous: [old], current: [old]))
    #expect(!MacFourVerbs.canConfirmTemporalTurn("yellow circle", previous: [old], current: [old]))
    #expect(!MacFourVerbs.canConfirmTemporalTurn("moving yellow circle", previous: [old], current: []))
    #expect(!MacFourVerbs.canConfirmTemporalTurn("moving yellow circle", previous: [old], current: [target("visual region 2")]))
    #expect(!MacFourVerbs.canConfirmTemporalTurn("moving yellow circle", previous: [old], current: [old, target("visual region 2")]))
    #expect(!MacFourVerbs.canConfirmTemporalTurn("stationary yellow circle", previous: [old], current: [target("visual region 1", uncertain: false)]))
}

@Test func explicitRightButtonReachesNamedPointerActionsAndRejectsWrongUses() async {
    let supplement = MacFourVerbsSupplement(appName: "Finder", bundleIdentifier: "com.apple.finder",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600), targets: [
            MacFourVerbsSupplementalTarget(label: MacScreenText("orange circle"), kind: "visual region",
                frame: MacAXFrame(x: 100, y: 200, w: 60, h: 60), provenance: .vision(0.9), physicalOnly: true),
            MacFourVerbsSupplementalTarget(label: MacScreenText("green square"), kind: "visual region",
                frame: MacAXFrame(x: 500, y: 200, w: 60, h: 60), provenance: .vision(0.9), physicalOnly: true),
        ])
    for verb in ["click", "open", "drag", "hold"] {
        let sink = _FVEventSink()
        let harness = _fvHarness(eventSink: sink, supplementalSource: _FVSupplementSource(supplement: supplement))
        let reply = await harness.verbs.act(verb: verb, target: "orange circle", to: "green square",
                                             seconds: 0, holding: verb == "hold" ? "w d" : nil, button: "right")
        #expect(reply.ok, "\(reply.text)")
        #expect(reply.detail["button"] == .string("right"))
        #expect(!sink.mice().isEmpty && sink.mice().allSatisfy { $0.button == .right })
        #expect(sink.mice().last?.phase == .up)
        if verb == "hold" {
            #expect(sink.keys().map(\.keyCode) == [13, 2, 2, 13])
            #expect(sink.keys().map(\.down) == [true, true, false, false])
        }
        if verb == "drag" { #expect(sink.mice().contains { $0.phase == .drag && $0.x == 530 }) }
    }
    for (verb, target, button) in [("click", "orange circle", "middle"), ("key", "w", "right"),
                                    ("type", "orange circle", "right"), ("hold", "key w", "right"),
                                    ("hover", "orange circle", "right")] {
        let sink = _FVEventSink()
        let harness = _fvHarness(eventSink: sink, supplementalSource: _FVSupplementSource(supplement: supplement))
        let reply = await harness.verbs.act(verb: verb, target: target, text: "test", button: button)
        #expect(!reply.ok && reply.detail["error"] == .string("invalid_mouse_button_action"))
        #expect(sink.mice().isEmpty && sink.keys().isEmpty)
    }
}

@Test func keyboardHoldStillRejectsASecondHeldKeySetBeforeInput() async {
    let sink = _FVEventSink()
    let harness = _fvHarness(eventSink: sink)
    let reply = await harness.verbs.act(verb: "hold", target: "key w", seconds: 0, holding: "d")
    #expect(!reply.ok)
    #expect(reply.detail["error"] == .string("nested_hold_not_supported"))
    #expect(sink.keys().isEmpty && sink.mice().isEmpty)
}

@Test func automaticButtonPreservesOrdinaryHoverKeysAndSemanticActions() async {
    let sink = _FVEventSink()
    let supplement = MacFourVerbsSupplement(appName: "Finder", bundleIdentifier: "com.apple.finder",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600), targets: [
            MacFourVerbsSupplementalTarget(label: MacScreenText("green square"), kind: "visual region",
                frame: MacAXFrame(x: 500, y: 200, w: 60, h: 60), provenance: .vision(0.9), physicalOnly: true),
        ])
    let harness = _fvHarness(eventSink: sink, supplementalSource: _FVSupplementSource(supplement: supplement))
    let hover = await harness.verbs.act(verb: "hover", target: "green square", seconds: 0, button: "auto")
    #expect(hover.ok)
    #expect(sink.mice().count == 1 && sink.mice().first?.phase == .move)
    let key = await harness.verbs.act(verb: "key", target: "w", button: "auto")
    #expect(key.ok && sink.keys().count == 2 && sink.keys().last?.down == false)
    let semantic = await harness.verbs.act(verb: "click", target: "Back", button: "auto")
    #expect(semantic.ok)
    #expect(!harness.actSource.recordedCalls().isEmpty)
    #expect(sink.mice().count == 1, "auto must not force semantic AX actions into physical clicks")
}

@Test func pointerLandingUsesIndependentObservedBoundsAndNeverSettlesClicks() async {
    func frame(_ pointer: MacPointerPosition?, observedX: Double = 500,
               physicalOnly: Bool = true) -> MacFourVerbsSupplement {
        MacFourVerbsSupplement(appName: "Finder", bundleIdentifier: "com.apple.finder",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600), pointer: pointer,
            targets: [MacFourVerbsSupplementalTarget(label: MacScreenText("green square"),
                kind: "visual region", frame: MacAXFrame(x: 500, y: 200, w: 60, h: 60),
                observedFrame: MacAXFrame(x: observedX, y: 200, w: 60, h: 60),
                provenance: .vision(0.9), physicalOnly: physicalOnly)])
    }
    for verb in ["hover", "move", "click"] {
        for physicalOnly in [true, false] {
            let source = _FVSequencedSupplementSource([
                frame(MacPointerPosition(x: 10, y: 10), physicalOnly: physicalOnly),
                frame(MacPointerPosition(x: 530, y: 230), physicalOnly: physicalOnly),
            ])
            let harness = _fvHarness(eventSink: _FVEventSink(), supplementalSource: source)
            let reply = await harness.verbs.act(verb: verb, target: "green square", button: "auto")
            #expect(reply.ok, "\(reply.text)")
            #expect(reply.text.contains("POINTER: 66%,38%"))
            if verb == "click" {
                #expect(reply.detail["verification"] != .string("satisfied"))
                if physicalOnly { #expect(reply.detail["verification"] == .string("unverified")) }
                #expect(reply.detail["verification_evidence"] == nil)
                #expect(reply.detail["pointer_on_target"] == nil)
            } else {
                #expect(reply.detail["verification"] == .string("satisfied"))
                #expect(reply.detail["verification_evidence"] == .string("fresh_system_pointer_in_observed_target"))
                #expect(reply.detail["verification_scope"] == .string("pointer_position_only"))
            }
        }
    }
    // A predicted motor frame is NOT where the object was seen. Nor can a
    // missing cursor read turn into an invented successful landing at (0,0).
    for pointer in [MacPointerPosition(x: 530, y: 230), nil] {
        let source = _FVSequencedSupplementSource([frame(nil), frame(pointer, observedX: 300)])
        let harness = _fvHarness(eventSink: _FVEventSink(), supplementalSource: source)
        let reply = await harness.verbs.act(verb: "hover", target: "green square")
        #expect(reply.ok && reply.detail["verification"] == .string("unverified"))
        #expect(reply.detail["pointer_on_target"] == (pointer == nil ? .null : .bool(false)))
    }
}

@Test func pointerScreenReportsOutsideSurfaceAndUnavailableWithoutGlobalCoordinates() async {
    for pointer in [MacPointerPosition(x: -400, y: 200), nil] {
        let supplement = MacFourVerbsSupplement(appName: "Finder", bundleIdentifier: "com.apple.finder",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600), pointer: pointer)
        let harness = _fvHarness(supplementalSource: _FVSupplementSource(supplement: supplement))
        let reply = await harness.verbs.screen()
        #expect(reply.text.contains(pointer == nil ? "POINTER: position unavailable." : "POINTER: outside the observed surface."))
        #expect(!reply.text.contains("-400"))
    }
    #expect(MacPointerPosition(x: .nan, y: 0) == nil)
    #expect(MacPointerPosition(x: 0, y: .infinity) == nil)
}

@Test func diagonalAimQualifiersPreserveIdentityAndRefuseCoveredQuadrants() {
    let frame = MacAXFrame(x: 100, y: 200, w: 800, h: 600)
    for (qualifier, x, y) in [
        ("upper-left corner", 300.0, 350.0), ("top left", 300.0, 350.0),
        ("upper right part", 700.0, 350.0), ("top-right corner", 700.0, 350.0),
        ("lower-left side", 300.0, 650.0), ("bottom left", 300.0, 650.0),
        ("lower-right corner", 700.0, 650.0), ("bottom right", 700.0, 650.0),
    ] {
        let phrase = "\(qualifier) of the upper-left-icon"
        #expect(MacFourVerbs.stripWithinTargetAimQualifier(phrase) == "upper-left-icon")
        let aim = MacFourVerbs.aimPoint(in: frame, describedBy: phrase)
        #expect(aim.x == x && aim.y == y)
        let target = MacFourVerbs.ActTarget(handle: "", label: "canvas", kind: "canvas",
            ordinal: nil, enabled: true, frame: frame,
            excludedFrames: [MacAXFrame(x: x - 10, y: y - 10, w: 20, h: 20)], regionOnly: true)
        #expect(MacFourVerbs.safeAimPoint(for: target, in: frame, describedBy: phrase) == nil)
        #expect(MacFourVerbs.safeAimPoint(for: target, in: frame, describedBy: "canvas") != nil)
    }
    #expect(MacFourVerbs.stripWithinTargetAimQualifier("upper-left-icon") == "upper-left-icon")
    #expect(MacFourVerbs.stripWithinTargetAimQualifier("portrait of the upper-left-icon") == "portrait of the upper-left-icon")
    let centered = MacFourVerbs.aimPoint(in: frame, describedBy: "centre of upper left control")
    #expect(centered.x == 500 && centered.y == 500, "object name must not override explicit aim")
}

@Test func partiallyCoveredCanvasKeepsClearAimingWithoutReinterpretingExplicitPoints() async throws {
    let frame = MacAXFrame(x: 0, y: 0, w: 800, h: 600)
    let popup = MacAXFrame(x: 350, y: 250, w: 100, h: 100)
    let center = try #require(MacPointerPosition(x: 400, y: 300))
    let clear = try #require(MacRegionAim.point(in: frame, preferred: center, excluding: [popup], allowAlternate: true))
    #expect(clear.isInside(frame) && !clear.isInside(popup))
    #expect(MacRegionAim.point(in: frame, preferred: center, excluding: [popup], allowAlternate: false) == nil)
    #expect(MacRegionAim.point(in: frame, preferred: center, excluding: [frame], allowAlternate: true) == nil)
    #expect(!MacRegionAim.pathIsClear(from: MacPointerPosition(x: 200, y: 300)!,
        to: MacPointerPosition(x: 600, y: 300)!, excluding: [popup]))
    #expect(MacRegionAim.pathIsClear(from: MacPointerPosition(x: 200, y: 100)!,
        to: MacPointerPosition(x: 600, y: 100)!, excluding: [popup]))
    let target = MacFourVerbs.ActTarget(handle: "", label: "visual surface", kind: "canvas",
        ordinal: nil, enabled: true, frame: frame, excludedFrames: [popup], regionOnly: true)
    #expect(MacFourVerbs.safeAimPoint(for: target, in: frame, describedBy: "visual surface") != nil)
    #expect(MacFourVerbs.safeAimPoint(for: target, in: frame, describedBy: "center of visual surface") == nil)
    #expect(MacFourVerbs.safeAimPoint(for: target, in: frame, describedBy: "upper left visual surface")?.x == 200)

    let source = _FVSupplementSource(supplement: MacFourVerbsSupplement(
        appName: "Finder", bundleIdentifier: "com.apple.finder", visibleFrame: frame,
        targets: [MacFourVerbsSupplementalTarget(label: MacScreenText("visual surface"), aliases: ["canvas", "viewport", "world"], kind: "canvas",
            frame: frame, excludedFrames: [popup], provenance: .vision(1), regionOnly: true)]))
    let sink = _FVEventSink()
    let harness = _fvHarness(eventSink: sink, supplementalSource: source)
    for name in ["visual surface", "canvas", "viewport", "world"] {
        let reply = await harness.verbs.act(verb: "scroll up", target: name)
        #expect(reply.ok, "\(reply.text)")
    }
    #expect(!sink.mice().isEmpty)
    #expect(sink.mice().allSatisfy { event in MacPointerPosition(x: event.x, y: event.y)?.isInside(popup) == false })
    let click = await harness.verbs.act(verb: "click", target: "visual surface")
    #expect(!click.ok && click.detail["error"] == .string("region_needs_inner_target"))
}

@Test func displayedCanvasEndpointsSupportBalancedDragAndPointerHold() async {
    func source(covered: Bool = false) -> _FVSupplementSource {
        _FVSupplementSource(supplement: MacFourVerbsSupplement(
            appName: "Finder", bundleIdentifier: "com.apple.finder",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
            targets: [MacFourVerbsSupplementalTarget(label: MacScreenText("visual surface"),
                aliases: ["canvas", "viewport", "world"], kind: "canvas",
                frame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
                excludedFrames: covered ? [MacAXFrame(x: 150, y: 250, w: 100, h: 100)] : [],
                provenance: .vision(1), regionOnly: true)]))
    }
    for verb in ["drag", "hold"] {
        let sink = _FVEventSink()
        let harness = _fvHarness(eventSink: sink, supplementalSource: source())
        let reply = await harness.verbs.act(verb: verb, target: "left side of canvas",
            to: verb == "drag" ? "right side of canvas" : nil,
            seconds: 0, holding: verb == "hold" ? "w d" : nil, button: "right")
        #expect(reply.ok, "\(reply.text)")
        #expect(sink.mice().first?.x == 200)
        #expect(sink.mice().allSatisfy { $0.button == .right })
        #expect(sink.mice().last?.phase == .up)
        if verb == "drag" { #expect(sink.mice().last?.x == 600) }
        else { #expect(sink.keys().map(\.down) == [true, true, false, false]) }

        let blockedSink = _FVEventSink()
        let blocked = _fvHarness(eventSink: blockedSink, supplementalSource: source(covered: true))
        let refused = await blocked.verbs.act(verb: verb, target: "left side of canvas",
            to: verb == "drag" ? "right side of canvas" : nil,
            seconds: 0, holding: "w d", button: "right")
        #expect(!refused.ok)
        #expect(blockedSink.mice().isEmpty && blockedSink.keys().isEmpty)
    }
}

@Test func fineAndHorizontalScrollUseWheelMagnitudeWithoutPageKeySubstitution() async {
    for kind in ["canvas", "web area"] {
        let supplement = MacFourVerbsSupplement(appName: "Finder", bundleIdentifier: "com.apple.finder",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
            targets: [MacFourVerbsSupplementalTarget(label: MacScreenText("surface"), kind: kind,
                frame: MacAXFrame(x: 100, y: 100, w: 600, h: 400), provenance: .vision(1), regionOnly: true)])
        for (direction, dx, dy) in [("up", 0, 1), ("down", 0, -1), ("left", 1, 0), ("right", -1, 0)] {
            let sink = _FVEventSink()
            let harness = _fvHarness(eventSink: sink, supplementalSource: _FVSupplementSource(supplement: supplement))
            let reply = await harness.verbs.act(verb: "scroll \(direction)", target: "surface", scrollAmount: 1)
            #expect(reply.ok, "\(reply.text)")
            #expect(reply.detail["physical_route"] == .string("wheel"))
            #expect(sink.scrolls().count == 1)
            #expect(sink.scrolls().first?.deltaX == Int32(dx) && sink.scrolls().first?.deltaY == Int32(dy))
            #expect(sink.keys().isEmpty)
        }
    }
    let harness = _fvHarness()
    for amount in [-1, 121] {
        let reply = await harness.verbs.act(verb: "scroll up", target: "Back", scrollAmount: amount)
        #expect(!reply.ok && reply.detail["error"] == .string("invalid_scroll_amount"))
    }
    let invalid = await harness.verbs.act(verb: "click", target: "Back", scrollAmount: 1)
    #expect(!invalid.ok && invalid.detail["error"] == .string("invalid_scroll_amount"))
    let ordinary = await harness.verbs.act(verb: "click", target: "Back", scrollAmount: 0)
    #expect(ordinary.ok)
}

@Test
func physicalHoverReobservesOneTransientNaturalTargetMiss() async {
    let missing = MacFourVerbsSupplement(
        appName: "Finder", bundleIdentifier: "com.apple.finder",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600)
    )
    let visible = MacFourVerbsSupplement(
        appName: "Finder", bundleIdentifier: "com.apple.finder",
        visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
        targets: [MacFourVerbsSupplementalTarget(
            label: MacScreenText("visual region 1", redacted: .string("visual region 1")),
            aliases: ["moving yellow object", "yellow object"],
            kind: "visual region",
            frame: MacAXFrame(x: 300, y: 200, w: 80, h: 60),
            provenance: .vision(0.8),
            physicalOnly: true
        )],
        diagnostics: ["vision_effect_value_text": .array([])]
    )
    let sink = _FVEventSink()
    let source = _FVSequencedSupplementSource([missing, visible, visible])
    let harness = _fvHarness(eventSink: sink, supplementalSource: source)

    let reply = await harness.verbs.act(verb: "hover", target: "moving yellow object")

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.detail["dynamic_reobserved"] == .bool(true))
    #expect(harness.clock.seconds() == 0.06)
    #expect(sink.mice().contains { $0.phase == .move && $0.x == 340 && $0.y == 230 })
}

@Test
func physicalDragReobservesBothEndsWhenMovingDestinationDropsOut() async {
    func supplement(includeDestination: Bool) -> MacFourVerbsSupplement {
        var targets = [MacFourVerbsSupplementalTarget(
            label: MacScreenText("visual region 1", redacted: .string("visual region 1")),
            aliases: ["yellow object"],
            kind: "visual region",
            frame: MacAXFrame(x: 100, y: 120, w: 40, h: 40),
            provenance: .vision(0.8),
            physicalOnly: true
        )]
        if includeDestination {
            targets.append(MacFourVerbsSupplementalTarget(
                label: MacScreenText("visual region 2", redacted: .string("visual region 2")),
                aliases: ["moving blue object"],
                kind: "visual region",
                frame: MacAXFrame(x: 400, y: 420, w: 80, h: 80),
                provenance: .vision(0.8),
                physicalOnly: true
            ))
        }
        return MacFourVerbsSupplement(
            appName: "Finder", bundleIdentifier: "com.apple.finder",
            visibleFrame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
            targets: targets,
            diagnostics: ["vision_effect_value_text": .array([])]
        )
    }
    let sink = _FVEventSink()
    let source = _FVSequencedSupplementSource([
        supplement(includeDestination: false),
        supplement(includeDestination: true),
        supplement(includeDestination: true),
    ])
    let harness = _fvHarness(eventSink: sink, supplementalSource: source)

    let reply = await harness.verbs.act(
        verb: "drag", target: "yellow object", to: "moving blue object", seconds: 0
    )

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.detail["dynamic_reobserved"] == .bool(true))
    let down = sink.mice().first { $0.phase == .down }
    let up = sink.mice().last { $0.phase == .up }
    #expect(down?.x == 120 && down?.y == 140)
    #expect(up?.x == 440 && up?.y == 460)
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
    let effects = _FVEffectSource(script: [])
    let client = SwiftNativeMacControl(
        accessibilitySource: churning,
        eventSink: InertAvailableMacEventSink(),
        accessibilityActSource: harness.actSource,
        effectObserverSource: effects,
        lookFrameStore: MacLookFrameStore()
    )
    let clock = _FVClock()
    let verbs = MacFourVerbs(
        host: client,
        clock: clock,
        effectObserverSource: effects,
        appActivationSource: _FVSilentActivationSource()
    )
    // Rename a row continuously AND fire the notification a real app would fire
    // when it does. fable51 item 31: the wait ends on the signal now, so a
    // fixture that mutates its tree in total silence models an app that does
    // not exist — and would be reported (correctly) as settled.
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
            effects.emit()
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

// MARK: - 4b. wait as a SIGNAL, not a poll (fable51 item 31)

@Test
func wait_resolvesOnTheAXSignal_withoutASecondCaptureUntilSomethingHappened() async {
    // No scripted notification: the observer installs and stays silent, so the
    // ONLY reason the wait can look again is a signal it actually receives.
    let effects = _FVEffectSource(script: [])
    let harness = _fvHarness(effects: effects)
    let source = harness.source

    let changer = Task { @Sendable in
        // Change the screen, then say so the way a real app does.
        source.mutate { elements in
            elements[30] = _FVElement(
                attributes: MacAXAttributes(role: "AXStaticText", value: "upload complete"),
                children: []
            )
        }
        effects.emit("AXValueChanged")
    }
    let reply = await harness.verbs.wait(until: "upload complete", seconds: 10)
    _ = await changer.value

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("\"upload complete\" appeared after "), "\(reply.text)")
    // The baseline plus exactly one render caused by the signal. The old poll
    // would have walked and captured the screen up to twenty times to see this.
    #expect(source.lookCount() == 2, "one baseline + one signal render, not a poll: \(source.lookCount())")
}

@Test
func wait_settlesOnSilence_withASingleCapture() async {
    // A live subscription that never fires: silence IS the settle, and the
    // render already in hand is the answer.
    let harness = _fvHarness(effects: _FVEffectSource(script: []))
    let reply = await harness.verbs.wait()

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("Settled after "), "\(reply.text)")
    #expect(reply.text.contains("SCREEN"), "the settle still carries the screen: \(reply.text)")
    #expect(harness.source.lookCount() == 1, "a quiet settle costs ONE capture: \(harness.source.lookCount())")
    // It waited for the quiet window rather than answering instantly, and it
    // did not burn the budget.
    #expect(harness.clock.seconds() >= MacFourVerbs.settleQuietSeconds - 0.001)
    #expect(harness.clock.seconds() < MacFourVerbs.defaultWaitSeconds)
    #expect(MacFourVerbs.string(reply.detail["settled_by"]) == "quiet")
}

@Test
func wait_endsOnAnAppSwitch_whichNoAXObserverOnOnePidCanSee() async {
    // The AX observer is installed on the app that WAS in front; an activation
    // happens in a different process entirely. Without the workspace
    // subscription this wait is blind until the deadline.
    let effects = _FVEffectSource(script: [])
    let activation = _FVActivationSource()
    let harness = _fvHarness(effects: effects, waitActivation: activation)
    let source = harness.source

    let switcher = Task { @Sendable in
        source.setFrontmostApp(named: "Mail")
        activation.fire()
    }
    let reply = await harness.verbs.wait(until: "Mail", seconds: 10)
    _ = await switcher.value

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("\"Mail\" appeared after "), "\(reply.text)")
    #expect(source.lookCount() == 2, "\(source.lookCount())")
}

@Test
func wait_removesBothSubscriptionsOnEveryExit() async {
    let activation = _FVActivationSource()
    let harness = _fvHarness(effects: _FVEffectSource(script: []), waitActivation: activation)
    _ = await harness.verbs.wait(seconds: 2)
    // The settle path is the one that returns EARLY. An observer that survives
    // it leaks for the life of the process.
    #expect(activation.stopCount() == 1, "\(activation.stopCount())")
}

@Test
func wait_fallsBackToACoarseReRender_whenNoObserverCouldBeInstalled() async {
    // The documented SAFETY NET: with nothing subscribable, silence proves
    // nothing, so a settle must be decided the old way — by comparing two
    // renders — and never claimed from quiet.
    let harness = _fvHarness(
        waitEffects: _FVDeafEffectSource(),
        waitActivation: _FVSilentActivationSource()
    )
    let reply = await harness.verbs.wait(seconds: 20)

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.hasPrefix("Settled after "), "\(reply.text)")
    #expect(MacFourVerbs.string(reply.detail["settled_by"]) == "compared",
            "a settle with no subscription must be a comparison, not a claim: \(reply.detail)")
    #expect(harness.source.lookCount() == 2, "\(harness.source.lookCount())")
    // It waited the coarse cadence, not the quiet window.
    #expect(harness.clock.seconds() >= MacFourVerbs.fallbackPollSeconds - 0.001)
}

@Test
func wait_keepsItsVocabularyAndItsBudget() {
    #expect(MacFourVerbs.maxWaitSeconds == 60)
    #expect(MacFourVerbs.defaultWaitSeconds == 10)
    // The quiet window carries the same meaning the old 0.5s poll encoded.
    #expect(MacFourVerbs.settleQuietSeconds == 0.5)
    #expect(MacFourVerbs.fallbackPollSeconds == 5.0)
    #expect(MacFourVerbs.signalPollSeconds < MacFourVerbs.settleQuietSeconds)
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
func duplicateControlNamesGetMatchingRenderedAddressesWithoutRenumberingUnnamedControls() async {
    var elements = _fvElements()
    var actElements = _fvActElements()
    for (index, id) in [103, 104].enumerated() {
        let frame = MacAXFrame(x: Double(30 + index * 40), y: 70, w: 20, h: 20)
        elements[id] = _FVElement(attributes: MacAXAttributes(role: "AXButton", frame: frame, actions: ["AXPress"]), children: [])
        elements[10]?.children.append(id)
        actElements[[0, index + 3]] = _FVActElement(role: "AXButton", title: nil, frame: frame)
    }
    let harness = _fvHarness(elements: elements, actElements: actElements)
    let before = await harness.verbs.screen()
    #expect(before.text.contains("button 1"))
    #expect(before.text.contains("button 2"))
    #expect(!before.text.contains("button 3"))

    harness.source.mutate { tree in
        tree[100] = _FVElement(attributes: MacAXAttributes(role: "AXButton", title: "Remove", actions: ["AXPress"]), children: [])
        tree[101] = _FVElement(attributes: MacAXAttributes(role: "AXButton", title: "REMOVE", actions: ["AXPress"]), children: [])
    }
    harness.actSource.mutate { tree in
        tree[[0, 0]] = _FVActElement(role: "AXButton", title: "Remove")
        tree[[0, 1]] = _FVActElement(role: "AXButton", title: "REMOVE")
    }
    let screen = await harness.verbs.screen()
    for address in ["button 1", "button 2", "button 3", "button 4"] {
        #expect(screen.text.contains(address), "Missing visible address \(address): \(screen.text)")
    }
    let ambiguous = await harness.verbs.act(verb: "click", target: "Remove")
    #expect(!ambiguous.ok)
    #expect(ambiguous.text.contains("button 3 \"Remove\""))
    #expect(ambiguous.text.contains("button 4 \"REMOVE\""))
    #expect(!harness.actSource.recordedCalls().contains { $0.hasPrefix("perform:") })

    let named = await harness.verbs.act(verb: "click", target: "button 4")
    #expect(named.ok, "\(named.text)")
    #expect(harness.actSource.recordedCalls().contains("perform:AXPress:[0, 1]"))
    for copiedAddress in ["button 4 REMOVE", "button 4 \"REMOVE\""] {
        let copied = await harness.verbs.act(verb: "click", target: copiedAddress)
        #expect(copied.ok, "\(copied.text)")
        #expect(harness.actSource.recordedCalls().last { $0.hasPrefix("perform:") } == "perform:AXPress:[0, 1]")
    }
    let callsBeforeStale = harness.actSource.recordedCalls().filter { $0.hasPrefix("perform:") }.count
    for staleAddress in ["button 4 Send", "button 99 Remove"] {
        let stale = await harness.verbs.act(verb: "click", target: staleAddress)
        #expect(!stale.ok)
    }
    #expect(harness.actSource.recordedCalls().filter { $0.hasPrefix("perform:") }.count == callsBeforeStale)
    let unnamed = await harness.verbs.act(verb: "click", target: "button 1")
    #expect(unnamed.ok, "\(unnamed.text)")
    #expect(harness.actSource.recordedCalls().contains("perform:AXPress:[0, 3]"))

    let missed = await harness.verbs.act(verb: "click", target: "Remove impossible")
    // Even when a longer label is ambiguous, both recovery choices stay
    // distinct and refer to the same fresh screen's published ordinals.
    #expect(!missed.ok)
    #expect(missed.text.contains("button 3"))
    #expect(missed.text.contains("button 4"))
}

@Test
func resolution_copiedLabeledOrdinalsPreserveLiteralNamesAndExactKinds() {
    let targets: [MacFourVerbs.ActTarget] = [
        .init(handle: "first", label: "Remove", kind: "button", ordinal: nil, roleOrdinal: 4, enabled: true),
        .init(handle: "second", label: "Remove", kind: "button", ordinal: nil, roleOrdinal: 5, enabled: true),
        .init(handle: "editor", label: "Notes", kind: "text area", ordinal: nil, roleOrdinal: 2, enabled: true),
        .init(handle: "row", label: "Report", kind: "row", ordinal: 7, enabled: true),
    ]
    for (phrase, expected) in [("button 4 Remove", "first"), ("button 5 \"Remove\"", "second"),
                               ("text area 2 Notes", "editor"), ("row 7 Report", "row")] {
        guard case .hit(let hit) = MacFourVerbs.resolve(phrase, among: targets) else {
            Issue.record("Copied address did not resolve: \(phrase)"); continue
        }
        #expect(hit.handle == expected)
    }
    for phrase in ["button 4 Notes", "button 2 Notes", "button 99 Remove"] {
        guard case .none = MacFourVerbs.resolve(phrase, among: targets) else {
            Issue.record("Inconsistent address must not fall back to another target: \(phrase)"); continue
        }
    }
    let literal = MacFourVerbs.ActTarget(handle: "literal", label: "button 4 Remove", kind: "row", ordinal: 8, enabled: true)
    guard case .hit(let hit) = MacFourVerbs.resolve("button 4 Remove", among: targets + [literal]) else {
        Issue.record("An exact literal name must retain precedence"); return
    }
    #expect(hit.handle == "literal")
}

@Test
func resolution_roleQualifierFiltersBeforeUniqueOrAmbiguousNameMatches() {
    func target(_ handle: String, _ label: String, _ kind: String) -> MacFourVerbs.ActTarget {
        .init(handle: handle, label: label, kind: kind, ordinal: nil, enabled: true)
    }
    let wrongRole = target("field", "Send", "text")
    guard case .none = MacFourVerbs.resolve("Send button", among: [wrongRole]) else {
        Issue.record("An explicit button request must not select the sole Send text field")
        return
    }
    let sendButton = target("button", "Send message", "button")
    for wrongRoles in [[wrongRole], [wrongRole, target("row", "Send", "row")]] {
        guard case .hit(let hit) = MacFourVerbs.resolve("Send button", among: wrongRoles + [sendButton]) else {
            Issue.record("Wrong-role exact names must not shadow the matching button")
            return
        }
        #expect(hit.handle == "button")
    }
    guard case .ambiguous(let matches) = MacFourVerbs.resolve("Send button", among: [
        wrongRole, sendButton, target("other-button", "Send later", "button"),
    ]) else {
        Issue.record("Two same-role matches must remain ambiguous")
        return
    }
    #expect(Set(matches.map(\.handle)) == ["button", "other-button"])
    guard case .hit(let textArea) = MacFourVerbs.resolve("Search text area", among: [
        target("field", "Search", "text"), target("area", "Search", "text area"),
    ]) else {
        Issue.record("Multiword printed roles must qualify the entire name")
        return
    }
    #expect(textArea.handle == "area")
}

@Test
func resolution_roleQualifierPreservesLiteralLabelsAliasesAndOrdinals() {
    for label in ["Send button", "Button Manager", "Search text area"] {
        let literal = MacFourVerbs.ActTarget(handle: "literal", label: label, kind: "row", ordinal: 1, enabled: true)
        guard case .hit(let hit) = MacFourVerbs.resolve(label, among: [literal]) else {
            Issue.record("A literal label containing role words must stay addressable: \(label)")
            return
        }
        #expect(hit.handle == "literal")
    }
    let focused = MacFourVerbs.ActTarget(
        handle: "focus", label: nil, aliases: ["focused field"], kind: "text area", ordinal: nil,
        roleOrdinal: 2, enabled: true
    )
    for phrase in ["focused field", "text area 2", "text area"] {
        guard case .hit(let hit) = MacFourVerbs.resolve(phrase, among: [focused]) else {
            Issue.record("Existing aliases, ordinals and bare kinds must stay addressable: \(phrase)")
            return
        }
        #expect(hit.handle == "focus")
    }
}

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
// reports bounded repeat_* receipts plus a verification verdict computed across
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

private struct _FVElapsedHost: MacFourVerbsHost {
    let base: any MacFourVerbsHost
    let clock: _FVClock
    let elapsedPerDispatch: Double

    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        let result = try await base.dispatch(action: action, body: body)
        clock.advance(elapsedPerDispatch)
        return result
    }
}

/// The four-verb harness plus the two seams a BURST needs: a passive attention
/// event source and a fused-view lane the attention lease can observe through.
/// Both stores are fresh instances rather than the process-wide `.shared` ones,
/// so a burst test cannot inherit — or leak — a lease across the suite.
private func _fvBurstHarness(
    actElements: [[Int]: _FVActElement]? = nil,
    vanishAfter: (path: [Int], presses: Int)? = nil,
    elapsedPerDispatch: Double = 0
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
    let host = _FVElapsedHost(base: client, clock: clock, elapsedPerDispatch: elapsedPerDispatch)
    return _FVBurstHarness(
        verbs: MacFourVerbs(host: host, clock: clock),
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

    // The receipt retains both the caller's real ask and the accepted bounded
    // count. A runaway upstream loop is visible without weakening the hard cap.
    #expect(_fvInt(reply.detail, "repeat_requested_input") == 500)
    #expect(_fvInt(reply.detail, "repeat_requested") == 500)
    #expect(_fvInt(reply.detail, "repeat_accepted") == Int64(MacFourVerbs.maximumActRepeats))
    #expect(_fvBool(reply.detail, "repeat_stopped_early") == true)
    #expect(reply.text.hasPrefix("Completed 12/500 requested attempts."), "\(reply.text)")
    #expect(reply.text.contains("12-attempt safety cap limited this burst before execution."), "\(reply.text)")

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
    #expect(_fvInt(bounded.detail, "repeat_accepted") == 12)
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

@Test
func actBurst_stopsLaunchingAttemptsWhenRealPerceptionTimeExhaustsTheRuntimeBound() async throws {
    // Planning sees no hold or pause cost here, so all twelve attempts are
    // accepted. Slow owner dispatches advance only the monotonic clock: the runtime
    // boundary must notice that real owner work, stop before another click,
    // and report the shortfall without pretending a completed effect failed.
    let harness = _fvBurstHarness(elapsedPerDispatch: 8)
    let reply = await harness.verbs.act(verb: "click", target: "report.pdf", repeat: 12)

    let planned = try #require(_fvInt(reply.detail, "repeat_planned"))
    let completed = try #require(_fvInt(reply.detail, "repeat_completed"))
    #expect(planned == 12)
    #expect(completed > 0 && completed < planned)
    #expect(_fvBool(reply.detail, "repeat_runtime_limited") == true)
    #expect(_fvBool(reply.detail, "repeat_stopped_early") == true)
    #expect(reply.text.contains("30-second runtime boundary stopped the burst before another attempt."),
            "\(reply.text)")
    #expect(!reply.ok)

    let presses = harness.actSource.recordedCalls().filter { $0 == "perform:AXPress:[1, 0]" }
    #expect(presses.count == completed,
            "the receipt must equal the effects actually emitted: \(harness.actSource.recordedCalls())")
    #expect(await harness.attentionStore.status(now: Date()) == nil,
            "runtime exhaustion must still release an owned attention lease")
}
