import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - native-look item 3: the CLOSED LOOP (`mac_act`)
//
// A live act needs a window server, a frontmost app, an AX TCC grant and a real
// AXObserver — none of which exist in CI. So the loop is pinned against three
// injected seams, all of them the PRODUCTION ones with a synthetic
// implementation behind them:
//
//   • `MacAXElementSource`         — the tree the post-action look compiles from.
//   • `MacAXActSource`             — the actuator's element handles; the fake
//     RECORDS every resolve/perform/setValue so "verb → mechanism" is asserted
//     rather than assumed.
//   • `MacAXEffectObserverSource`  — the effect seam, with scripted
//     notifications and COUNTED installs/removals. That count is what makes
//     "the observer is always removed" a pinned fact.

// MARK: - Synthetic element source (mutable, so before ≠ after)

private struct _Element {
    var attributes: MacAXAttributes?
    var children: [Int]
}

/// The look source, mutable between the look and the act so the effect DIFF has
/// something real to find.
private final class _MutableLookSource: MacAXElementSource, @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Int: _Element]
    private var rootID: Int?
    private var focus: [Int]?
    private var app: MacAXAppInfo?

    /// Round 7: the acceptance case is "another app took the front between the
    /// look and the act", so the harness has to be able to model it.
    func setFrontmostApp(_ next: MacAXAppInfo?) {
        lock.lock(); defer { lock.unlock() }
        app = next
    }

    init(
        elements: [Int: _Element],
        rootID: Int?,
        focus: [Int]? = nil,
        app: MacAXAppInfo? = MacAXAppInfo(
            name: "Mail", bundleIdentifier: "com.apple.mail", processIdentifier: 4242
        )
    ) {
        self.elements = elements
        self.rootID = rootID
        self.focus = focus
        self.app = app
    }

    func mutate(_ body: (inout [Int: _Element], inout Int?, inout [Int]?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&elements, &rootID, &focus)
    }

    func isTrusted() -> Bool { true }
    /// Round 9 (envelope 7FCDC92E): activation is ASYNCHRONOUS. A fixture
    /// where the front flips the instant `raise` returns cannot reach the bug —
    /// it is the reason a 571-green suite shipped a coordinate click into
    /// Chrome. `activationLagReads` is how many `frontmostApp()` reads happen
    /// before the pending app becomes visible; nil `pendingApp` models a
    /// request the window server simply never honours.
    private var activationLagReads = 0
    private var pendingApp: MacAXAppInfo?

    /// The app becomes frontmost only after `afterReads` further reads.
    func setFrontmostAppAfterLag(_ next: MacAXAppInfo, afterReads: Int) {
        lock.lock(); defer { lock.unlock() }
        pendingApp = next
        activationLagReads = afterReads
    }

    /// The WORSE shape, and the one that matches Agent's 7FCDC92E receipt:
    /// right after `activate()` the workspace answers OPTIMISTICALLY with the
    /// app whose activation is still in flight, for `reads` reads, and then
    /// tells the truth again because the switch never actually happened. A
    /// gate that believes one matching read posts into the wrong app and calls
    /// it success.
    private var optimisticApp: MacAXAppInfo?
    private var optimisticReads = 0
    func setOptimisticFrontmostApp(_ next: MacAXAppInfo, forReads reads: Int) {
        lock.lock(); defer { lock.unlock() }
        optimisticApp = next
        optimisticReads = reads
    }

    func frontmostApp() -> MacAXAppInfo? {
        lock.lock(); defer { lock.unlock() }
        if let optimisticApp, optimisticReads > 0 {
            optimisticReads -= 1
            return optimisticApp
        }
        if pendingApp != nil {
            if activationLagReads > 0 {
                activationLagReads -= 1
            } else {
                app = pendingApp
                pendingApp = nil
            }
        }
        return app
    }
    func frontmostWindowRoot() -> MacAXElementRef? {
        lock.lock()
        defer { lock.unlock() }
        return rootID.map { MacAXElementRef(id: $0) }
    }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? {
        lock.lock()
        defer { lock.unlock() }
        return elements[ref.id]?.attributes
    }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        lock.lock()
        defer { lock.unlock() }
        return (elements[ref.id]?.children ?? []).map { MacAXElementRef(id: $0) }
    }
    func focusedElementPath() -> [Int]? {
        lock.lock()
        defer { lock.unlock() }
        return focus
    }
}

// MARK: - Synthetic act source (records every call)

private struct _ActElement {
    var role: String
    var title: String?
    var value: String?
    var enabled: Bool = true
    var frame: MacAXFrame? = MacAXFrame(x: 10, y: 20, w: 40, h: 20)
    var actions: [String] = ["AXPress"]
}

private final class _ActSource: MacAXActSource, @unchecked Sendable {
    private let lock = NSLock()
    private var byPath: [[Int]: _ActElement]
    private var handles: [Int: [Int]] = [:]
    private var nextHandle = 0
    private(set) var calls: [String] = []
    /// Live AX refuses `AXValue` on plenty of editable views (a web input, a
    /// terminal, a rich-text view). This is how a test reaches that branch.
    var valueSettable = true
    /// …and `AXFocused` is not universally settable either.
    var focusSettable = true
    /// Round 5: an element can ADVERTISE an action and still refuse it — that
    /// is exactly what Agent's live Finder cell did with `AXOpen`
    /// (`fallback_reason=ax_action_refused`). Advertising is not doing, and a
    /// fixture that cannot express the difference cannot reach the bug.
    var refuseActions: Set<String> = []
    /// Round 6: AXSelected is settable on a real Finder row. A source that
    /// cannot select says so, and the Open-command rung must not fire.
    var selectSettable = true
    /// Fires AFTER a successful pid/window resolve, with the path resolved.
    var afterResolve: (@Sendable ([Int]) -> Void)?
    /// Fires INSIDE `perform`, before its status is computed.
    var afterPerform: (@Sendable (String) -> Void)?
    /// User's raise-don't-refuse change: what `raise` answers, and a hook the
    /// test uses to model the world actually changing (the app really becoming
    /// frontmost). Default `.unsupported` — a fake that cannot raise must not
    /// pretend it did, or the gate it feeds becomes vacuous.
    var raiseOutcome: MacAXActOutcome = .unsupported
    var onRaise: (@Sendable () -> Void)?
    /// B2 — the pid this source believes it belongs to. A resolve asked for any
    /// OTHER pid answers `.appGone`, exactly like the live source asked for a
    /// process that has exited.
    var livePid: Int32? = 4242
    private(set) var resolvedPids: [Int32] = []

    init(_ byPath: [[Int]: _ActElement], livePid: Int32? = 4242) {
        self.byPath = byPath
        self.livePid = livePid
    }

    private func record(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func raise(_ window: MacAXWindowRef) -> MacAXActOutcome {
        lock.lock(); calls.append("raise:\(window.handle)"); lock.unlock()
        onRaise?()
        return raiseOutcome
    }

    /// Round 9: selecting a row is itself a mutation, and the key window can
    /// move between it and the Open chord. Without a hook here that gap is
    /// unreachable from a test, which is why it went unpinned.
    var afterSetSelected: (@Sendable () -> Void)?

    func setSelected(_ target: MacAXActTarget) -> MacAXActOutcome {
        lock.lock(); let path = handles[target.handle]; let hook = afterSetSelected; lock.unlock()
        record("setSelected:\(path ?? [])")
        hook?()
        guard selectSettable else { return .unsupported }
        return path == nil ? .invalidTarget : .performed
    }

    func recordedCalls() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    /// Round 5: change the tree BETWEEN the ancestor probe and the act, which is
    /// the TOCTOU window the redirect opened and the only way to reach the
    /// vanished/drifted guards.
    func mutate(_ body: (inout [[Int]: _ActElement]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&byPath)
    }

    func isTrusted() -> Bool { true }

    func resolve(path: [Int]) -> MacAXActTarget? {
        record("resolve:\(path)")
        return resolveUnrecorded(path: path)
    }

    /// The same walk with NO call recorded, so a pid-anchored resolve does not
    /// leave a frontmost-anchored footprint a test would then have to ignore.
    private func resolveUnrecorded(path: [Int]) -> MacAXActTarget? {
        lock.lock()
        defer { lock.unlock() }
        guard let element = byPath[path] else { return nil }
        nextHandle += 1
        handles[nextHandle] = path
        return target(handle: nextHandle, element: element)
    }

    private func target(handle: Int, element: _ActElement) -> MacAXActTarget {
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
        lock.lock()
        resolvedPids.append(pid)
        let live = livePid
        let hook = afterResolve
        lock.unlock()
        guard let live, live == pid else { return .appGone }
        guard let hit = resolveUnrecorded(path: path) else { return .pathNotFound }
        // Round 5: the ONLY way to reach the redirect's TOCTOU guards is to
        // change the tree BETWEEN the ancestor probe and the re-resolve, which
        // are two calls to this very method for the same path.
        hook?(path)
        return .resolved(hit)
    }

    func pidsAskedFor() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return resolvedPids
    }

    func setFocused(_ target: MacAXActTarget) -> MacAXActOutcome {
        lock.lock()
        let path = handles[target.handle]
        lock.unlock()
        record("setFocused:\(path ?? [])")
        guard focusSettable else { return .unsupported }
        return path == nil ? .invalidTarget : .performed
    }

    func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome {
        lock.lock()
        let path = handles[target.handle]
        let sideEffect = afterPerform
        lock.unlock()
        record("perform:\(action):\(path ?? [])")
        // Round 8: a REAL AX action can have its effect and still report a
        // status other than `.performed` — Finder's AXOpen launched a .json in
        // Xcode and did exactly that. The hook lets a test model the world
        // moving underneath the call, which is the whole defect.
        sideEffect?(action)
        guard let path, let element = byPath[path] else { return .invalidTarget }
        if refuseActions.contains(action) { return .unsupported }
        return element.actions.contains(action) ? .performed : .unsupported
    }

    func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome {
        lock.lock()
        let path = handles[target.handle]
        lock.unlock()
        record("setValue:\(path ?? []):\(value)")
        guard valueSettable else { return .unsupported }
        lock.lock()
        defer { lock.unlock() }
        guard let path, var element = byPath[path] else { return .invalidTarget }
        // Only a text field takes a value, exactly like the live source's
        // settable probe.
        guard element.role == "AXTextField" || element.role == "AXTextArea" else { return .unsupported }
        element.value = value
        byPath[path] = element
        return .performed
    }

    func reread(_ target: MacAXActTarget) -> MacAXActTarget? {
        lock.lock()
        let path = handles[target.handle]
        lock.unlock()
        record("reread:\(path ?? [])")
        lock.lock()
        defer { lock.unlock() }
        guard let path, let element = byPath[path] else { return nil }
        return self.target(handle: target.handle, element: element)
    }
}

// MARK: - Synthetic effect observer (counts installs AND removals)

private final class _Observation: MacAXEffectObservation, @unchecked Sendable {
    private let onStop: @Sendable () -> Void
    private let lock = NSLock()
    private var stopped = false
    init(onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }
    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        onStop()
    }
}

private final class _EffectSource: MacAXEffectObserverSource, @unchecked Sendable {
    private let lock = NSLock()
    private var installCount = 0
    private var stopCount = 0
    private var lastPid: Int32?
    private var lastKinds: [String] = []
    /// Kinds emitted synchronously at install time. Empty ⇒ nothing ever
    /// fires, which is the `none_observed` fixture.
    private let script: [String]
    private let installable: Bool

    init(script: [String] = [], installable: Bool = true) {
        self.script = script
        self.installable = installable
    }

    func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)? {
        lock.lock()
        installCount += 1
        lastPid = pid
        lastKinds = kinds
        lock.unlock()
        guard installable else { return nil }
        for kind in script {
            onNotification(MacAXEffectNotification(kind: kind, at: Date()))
        }
        return _Observation(onStop: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.stopCount += 1
            self.lock.unlock()
        })
    }

    func installs() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return installCount
    }
    func stops() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCount
    }
    func pid() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return lastPid
    }
    func kinds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lastKinds
    }
}

// MARK: - Fixtures

private func _object(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let object) = value else { return [:] }
    return object
}

private func _array(_ value: JSONValue?) -> [JSONValue] {
    guard case .array(let array)? = value else { return [] }
    return array
}

/// A compose window: toolbar with Send/Cancel, a Subject field, and (optionally)
/// a save-draft SHEET carrying Cancel + Save Draft.
///
/// Paths (child-index, window = []):
///   [0]      AXToolbar
///   [0,0]    AXButton "Send"
///   [0,1]    AXButton "Cancel"
///   [1]      AXTextField "Subject"
///   [2]      AXSheet                (withSheet)
///   [2,0]    AXStaticText "Save…?"  (withSheet)
///   [2,1]    AXButton "Cancel"      (withSheet)
///   [2,2]    AXButton "Save Draft"  (withSheet)
private func _composeElements(withSheet: Bool = false) -> [Int: _Element] {
    var elements: [Int: _Element] = [
        100: _Element(attributes: MacAXAttributes(role: "AXButton", title: "Send", actions: ["AXPress"]), children: []),
        101: _Element(attributes: MacAXAttributes(role: "AXButton", title: "Cancel", actions: ["AXPress"]), children: []),
        10: _Element(attributes: MacAXAttributes(role: "AXToolbar", title: "Compose toolbar"), children: [100, 101]),
        11: _Element(
            attributes: MacAXAttributes(role: "AXTextField", title: "Subject", value: "Lunch", actions: ["AXPress"]),
            children: []
        ),
    ]
    var rootChildren = [10, 11]
    if withSheet {
        elements[200] = _Element(
            attributes: MacAXAttributes(role: "AXStaticText", title: "Save this message as a draft?"),
            children: []
        )
        elements[201] = _Element(
            attributes: MacAXAttributes(role: "AXButton", title: "Cancel", actions: ["AXPress"]),
            children: []
        )
        elements[202] = _Element(
            attributes: MacAXAttributes(role: "AXButton", title: "Save Draft", actions: ["AXPress"]),
            children: []
        )
        elements[20] = _Element(attributes: MacAXAttributes(role: "AXSheet"), children: [200, 201, 202])
        rootChildren.append(20)
    }
    elements[0] = _Element(
        attributes: MacAXAttributes(role: "AXWindow", title: "Lunch tomorrow"),
        children: rootChildren
    )
    return elements
}

private func _composeActElements(withSheet: Bool = false) -> [[Int]: _ActElement] {
    var out: [[Int]: _ActElement] = [
        []: _ActElement(role: "AXWindow", title: "Lunch tomorrow", actions: []),
        [0]: _ActElement(role: "AXToolbar", title: "Compose toolbar", actions: []),
        [0, 0]: _ActElement(role: "AXButton", title: "Send"),
        [0, 1]: _ActElement(role: "AXButton", title: "Cancel"),
        [1]: _ActElement(role: "AXTextField", title: "Subject", value: "Lunch"),
    ]
    if withSheet {
        out[[2]] = _ActElement(role: "AXSheet", title: nil, actions: [])
        out[[2, 0]] = _ActElement(role: "AXStaticText", title: "Save this message as a draft?", actions: [])
        out[[2, 1]] = _ActElement(role: "AXButton", title: "Cancel")
        out[[2, 2]] = _ActElement(role: "AXButton", title: "Save Draft")
    }
    return out
}

private struct _Harness {
    let client: SwiftNativeMacControl
    let source: _MutableLookSource
    let actSource: _ActSource
    let effects: _EffectSource
    let store: MacLookFrameStore
}

private func _harness(
    withSheet: Bool = false,
    focus: [Int]? = nil,
    script: [String] = ["AXValueChanged", "AXTitleChanged"],
    installable: Bool = true,
    now: (@Sendable () -> Date)? = nil
) -> _Harness {
    let source = _MutableLookSource(
        elements: _composeElements(withSheet: withSheet),
        rootID: 0,
        focus: focus
    )
    let actSource = _ActSource(_composeActElements(withSheet: withSheet))
    let effects = _EffectSource(script: script, installable: installable)
    let store = MacLookFrameStore()
    let client = SwiftNativeMacControl(
        now: now ?? { Date() },
        accessibilitySource: source,
        eventSink: InertAvailableMacEventSink(),
        accessibilityActSource: actSource,
        effectObserverSource: effects,
        lookFrameStore: store
    )
    return _Harness(client: client, source: source, actSource: actSource, effects: effects, store: store)
}

/// Take a look, return its frame id and the handle of the affordance with
/// `label`.
private func _lookForHandle(
    _ harness: _Harness,
    label: String
) async throws -> (frameId: String, handle: String) {
    let look = try await harness.client.dispatch(action: "look", body: [:])
    #expect(look.ok, "the fixture look must succeed: \(look.error ?? "nil")")
    let output = _object(look.output)
    guard case .string(let frameId)? = output["frame_id"] else {
        Issue.record("look returned no frame_id")
        return ("", "")
    }
    for row in _array(output["affordances"]) {
        let object = _object(row)
        if object["label"] == .string(label), case .string(let handle)? = object["handle"] {
            return (frameId, handle)
        }
    }
    Issue.record("look exposed no affordance labeled \(label): \(output["affordances"] ?? .null)")
    return (frameId, "")
}

// MARK: - Pure: clamps

@Test
func waitMs_defaultsTo300_andIsHardCappedAt2000() {
    #expect(MacActClosedLoop.clampedWaitMs(nil) == 300)
    #expect(MacActClosedLoop.clampedWaitMs(120) == 120)
    #expect(MacActClosedLoop.clampedWaitMs(99_999) == MacActClosedLoop.maxWaitMs)
    #expect(MacActClosedLoop.maxWaitMs == 2000, "the hard cap is a contract, not a default")
    #expect(MacActClosedLoop.clampedWaitMs(-5) == 0, "a negative wait is zero, never a deadline in the past")
}

@Test
func theTwelveNotificationKinds_areTheSpikesSet() {
    #expect(MacActClosedLoop.notificationKinds.count == 12)
    for kind in ["AXValueChanged", "AXFocusedUIElementChanged", "AXSheetCreated", "AXUIElementDestroyed"] {
        #expect(MacActClosedLoop.notificationKinds.contains(kind), "\(kind) must be subscribed")
    }
}

// MARK: - Pure: the drift guard

@Test
func drift_isReported_whenTheLiveRoleOrLabelNoLongerMatchTheFrame() {
    // Same control: no drift.
    #expect(MacActClosedLoop.driftReason(
        expectedRole: "AXButton", expectedLabel: "Send",
        liveRole: "AXButton", liveTitle: "Send", liveValue: nil
    ) == nil)

    // The window was rebuilt and the path now addresses a different KIND of
    // thing. This is the case that would press Delete instead of Save.
    #expect(MacActClosedLoop.driftReason(
        expectedRole: "AXButton", expectedLabel: "Send",
        liveRole: "AXTextField", liveTitle: "Send", liveValue: nil
    ) == "role")

    // Same role, different control.
    #expect(MacActClosedLoop.driftReason(
        expectedRole: "AXButton", expectedLabel: "Send",
        liveRole: "AXButton", liveTitle: "Delete", liveValue: nil
    ) == "label")

    // The frame recorded NO label (an unlabeled control resolved through
    // focus): there is nothing to compare, and inventing a comparison would
    // refuse acts that are perfectly fine.
    #expect(MacActClosedLoop.driftReason(
        expectedRole: "AXButton", expectedLabel: nil,
        liveRole: "AXButton", liveTitle: "anything", liveValue: nil
    ) == nil)

    // A VALUE-derived label (a popup button publishes its state as its name) is
    // read the same way the compiler read it: title first, value as fallback.
    #expect(MacActClosedLoop.driftReason(
        expectedRole: "AXPopUpButton", expectedLabel: "Medium",
        liveRole: "AXPopUpButton", liveTitle: nil, liveValue: "Medium"
    ) == nil)

    // The live element lost its name entirely — still drift, not a free pass.
    #expect(MacActClosedLoop.driftReason(
        expectedRole: "AXButton", expectedLabel: "Send",
        liveRole: "AXButton", liveTitle: nil, liveValue: nil
    ) == "label")
}

// MARK: - Pure: the effect diff

private func _entry(_ handle: String, _ path: [Int], _ role: String, _ label: String?, value: String? = nil, enabled: Bool = true) -> MacLookFrameEntry {
    MacLookFrameEntry(handle: handle, path: path, role: role, label: label, frame: nil, value: value, enabled: enabled)
}

private func _affordance(_ handle: String, _ path: [Int], _ role: String, _ label: String, value: String? = nil, enabled: Bool = true) -> MacLookAffordance {
    MacLookAffordance(
        handle: handle, role: role, label: label, labelSource: "title",
        value: value, enabled: enabled, path: path
    )
}

@Test
func effectDiff_namesWhatWasAdded_removed_changed_plusFocusModalAndTitle() {
    let before = MacLookFrame(
        frameId: "f1",
        capturedAt: Date(),
        appName: "Mail",
        bundleId: "com.apple.mail",
        windowTitle: "Lunch tomorrow",
        entries: [
            "aaa": _entry("aaa", [0, 0], "AXButton", "Send"),
            "bbb": _entry("bbb", [0, 1], "AXButton", "Cancel"),
            "ccc": _entry("ccc", [1], "AXTextField", "Subject", value: "Lunch", enabled: true),
        ],
        pid: 4242,
        focusHandle: "ccc",
        hasModal: false,
        modalPath: nil
    )
    let after = MacLookPercept(
        app: MacAXAppInfo(name: "Mail", bundleIdentifier: "com.apple.mail", processIdentifier: 4242),
        windowTitle: "Dinner tonight",
        focus: MacLookFocus(role: "AXButton", label: "Send", handle: "aaa", path: [0, 0]),
        modal: MacLookModal(role: "AXSheet", subrole: nil, label: "Save this message as a draft?", path: [2]),
        landmarks: [],
        affordances: [
            _affordance("aaa", [0, 0], "AXButton", "Send"),
            // ccc's value moved and it went disabled.
            _affordance("ccc", [1], "AXTextField", "Subject", value: "Dinner", enabled: false),
            // brand new.
            _affordance("ddd", [2, 1], "AXButton", "Save Draft"),
        ],
        unlabeledByRole: [:],
        affordancesOmitted: 0,
        interactiveCount: 3,
        labeledCount: 3,
        truncated: false,
        truncationReasons: [],
        skippedAtLeast: 0
    )

    let diff = MacActClosedLoop.diff(before: before, after: after, afterWindowTitle: "Dinner tonight")
    #expect(diff.added.map(\.handle) == ["ddd"])
    #expect(diff.removed.map(\.handle) == ["bbb"], "Cancel vanished with the toolbar")
    #expect(diff.changed.map(\.handle) == ["ccc"])
    let changed = diff.changed.first
    #expect(changed?.beforeValue == "Lunch")
    #expect(changed?.afterValue == "Dinner")
    #expect(changed?.beforeEnabled == true)
    #expect(changed?.afterEnabled == false)
    #expect(diff.focusChanged, "focus moved from the field to Send")
    #expect(diff.focusHandleAfter == "aaa")
    #expect(diff.modalAppeared)
    #expect(!diff.modalDisappeared)
    #expect(diff.modalLabelAfter == "Save this message as a draft?")
    #expect(diff.windowTitleChanged)
    #expect(diff.windowTitleAfter == "Dinner tonight")
    #expect(!diff.isEmpty)
}

@Test
func effectDiff_isEmpty_whenNothingMoved() {
    let entries = ["aaa": _entry("aaa", [0, 0], "AXButton", "Send")]
    let before = MacLookFrame(
        frameId: "f1", capturedAt: Date(), appName: "Mail", bundleId: nil,
        windowTitle: "W", entries: entries, pid: 1, focusHandle: nil, hasModal: false, modalPath: nil
    )
    let after = MacLookPercept(
        app: nil, windowTitle: "W", focus: nil, modal: nil, landmarks: [],
        affordances: [_affordance("aaa", [0, 0], "AXButton", "Send")],
        unlabeledByRole: [:], affordancesOmitted: 0, interactiveCount: 1, labeledCount: 1,
        truncated: false, truncationReasons: [], skippedAtLeast: 0
    )
    let diff = MacActClosedLoop.diff(before: before, after: after, afterWindowTitle: "W")
    #expect(diff.isEmpty, "an unchanged window must diff to nothing — the honest answer")
    #expect(!diff.modalDisappeared)
}

@Test
func effectDiff_reportsAModalDisappearing() {
    let before = MacLookFrame(
        frameId: "f1", capturedAt: Date(), appName: "Mail", bundleId: nil,
        windowTitle: "W", entries: [:], pid: 1, focusHandle: nil, hasModal: true, modalPath: [2]
    )
    let after = MacLookPercept(
        app: nil, windowTitle: "W", focus: nil, modal: nil, landmarks: [], affordances: [],
        unlabeledByRole: [:], affordancesOmitted: 0, interactiveCount: 0, labeledCount: 0,
        truncated: false, truncationReasons: [], skippedAtLeast: 0
    )
    let diff = MacActClosedLoop.diff(before: before, after: after, afterWindowTitle: "W")
    #expect(diff.modalDisappeared)
    #expect(!diff.modalAppeared)
    #expect(!diff.isEmpty, "a sheet closing IS a change")
}

// MARK: - Pure: dismiss-target selection

@Test
func dismissTarget_prefersCancel_andIsScopedToTheModalsOwnButtons() {
    let frame = MacLookFrame(
        frameId: "f1", capturedAt: Date(), appName: "Mail", bundleId: nil,
        windowTitle: "W",
        entries: [
            // The window BEHIND the sheet has its own Close. Pressing it would
            // act on the wrong surface entirely.
            "win": _entry("win", [0, 3], "AXButton", "Close"),
            "ok": _entry("ok", [2, 2], "AXButton", "OK"),
            "cancel": _entry("cancel", [2, 1], "AXButton", "Cancel"),
        ],
        pid: 1, focusHandle: nil, hasModal: true, modalPath: [2]
    )
    #expect(MacActClosedLoop.dismissTarget(in: frame)?.handle == "cancel",
            "Cancel before OK: dismiss must not confirm a dialog it was asked to close")

    let onlyOK = MacLookFrame(
        frameId: "f1", capturedAt: Date(), appName: "Mail", bundleId: nil,
        windowTitle: "W",
        entries: ["ok": _entry("ok", [2, 2], "AXButton", "OK"), "win": _entry("win", [0, 3], "AXButton", "Close")],
        pid: 1, focusHandle: nil, hasModal: true, modalPath: [2]
    )
    #expect(MacActClosedLoop.dismissTarget(in: onlyOK)?.handle == "ok")

    let noModal = MacLookFrame(
        frameId: "f1", capturedAt: Date(), appName: "Mail", bundleId: nil,
        windowTitle: "W", entries: ["win": _entry("win", [0, 3], "AXButton", "Close")],
        pid: 1, focusHandle: nil, hasModal: false, modalPath: nil
    )
    #expect(MacActClosedLoop.dismissTarget(in: noModal) == nil,
            "no modal ⇒ no dismiss target; the window's own Close is NOT it")
}

// MARK: - Pure: the wait

@Test
func waitForEffect_reportsNoneObserved_whenNothingArrivesInsideWaitMs() async {
    let collector = MacAXEffectCollector()
    let started = Date()
    let wait = await MacActClosedLoop.waitForEffect(
        collector: collector, waitMs: 0, quietMs: 0, startedAt: started, clock: { Date() }
    )
    #expect(!wait.observed)
    #expect(wait.firstNotificationMs == nil)
    #expect(wait.notifications.isEmpty)
}

@Test
func waitForEffect_collectsTheSiblingBurst_afterTheFirstNotification() async {
    let collector = MacAXEffectCollector()
    let started = Date()
    collector.record(MacAXEffectNotification(kind: "AXValueChanged", at: started.addingTimeInterval(0.032)))
    collector.record(MacAXEffectNotification(kind: "AXTitleChanged", at: started.addingTimeInterval(0.040)))
    let wait = await MacActClosedLoop.waitForEffect(
        collector: collector, waitMs: 300, quietMs: 5, startedAt: started, clock: { Date() }
    )
    #expect(wait.observed)
    #expect(wait.notifications == ["AXValueChanged", "AXTitleChanged"],
            "the quiet window is what makes the burst visible — one notification describes half the effect")
    #expect((wait.firstNotificationMs ?? -1) >= 30)
}

@Test
func effectCollector_capsWhatItRetains_andSaysHowMuchItDropped() {
    let collector = MacAXEffectCollector()
    for index in 0..<(MacAXEffectCollector.hardCap + 7) {
        collector.record(MacAXEffectNotification(kind: "AXValueChanged\(index)", at: Date()))
    }
    #expect(collector.snapshot().count == MacAXEffectCollector.hardCap)
    #expect(collector.droppedCount() == 7, "a dropped notification is reported, never silently lost")
}

// MARK: - Request validation

@Test
func act_refusesEveryMalformedRequest_byName() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")

    let noVerb = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId)]
    )
    #expect(!noVerb.ok)
    #expect(noVerb.error?.contains("missing required field: verb") == true)

    let badVerb = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("smash")]
    )
    #expect(badVerb.error?.hasPrefix("unknown_verb") == true)

    let noHandle = try await harness.client.dispatch(
        action: "act",
        body: ["frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(noHandle.error?.contains("missing required field: handle") == true)

    let noFrameId = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "verb": .string("click")]
    )
    #expect(noFrameId.error?.contains("missing required field: frame_id") == true)

    let noText = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("type")]
    )
    #expect(noText.error?.contains("missing required field: text") == true,
            "typing nothing is not a type — it is a malformed request")

    // Nothing above may have installed an observer: every one of these refuses
    // BEFORE the loop is armed.
    #expect(harness.effects.installs() == 0)
}

// MARK: - Resolve failures, by name

@Test
func act_failsLoud_onEveryFrameStoreResolveFailure() async throws {
    // no_frame — nothing was ever looked at.
    let fresh = _harness()
    let noFrame = try await fresh.client.dispatch(
        action: "act",
        body: ["handle": .string("abc123"), "frame_id": .string("nope"), "verb": .string("click")]
    )
    #expect(noFrame.error == "no_frame")
    #expect(_object(noFrame.output)["guidance"] == .string(MacLookFrameStore.ResolveFailure.noFrame.guidance))

    // stale_frame — a frame id that is not the latest.
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    let stale = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string("some-older-frame"), "verb": .string("click")]
    )
    #expect(stale.error == "stale_frame")

    // unknown_handle — the right frame, a handle it never issued.
    let unknown = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string("zzzzzz"), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(unknown.error == "unknown_handle")

    // frame_expired — past the TTL.
    let expiredStore = MacLookFrameStore()
    await expiredStore.record(MacLookFrame(
        frameId: "old-frame",
        capturedAt: Date().addingTimeInterval(-(MacLookFrameStore.ttlSeconds + 60)),
        appName: "Mail",
        bundleId: "com.apple.mail",
        windowTitle: "Lunch tomorrow",
        entries: ["aaa": _entry("aaa", [0, 0], "AXButton", "Send")],
        pid: 4242
    ))
    let expiredClient = SwiftNativeMacControl(
        accessibilitySource: _MutableLookSource(elements: _composeElements(), rootID: 0),
        eventSink: InertAvailableMacEventSink(),
        accessibilityActSource: _ActSource(_composeActElements()),
        effectObserverSource: _EffectSource(),
        lookFrameStore: expiredStore
    )
    let expired = try await expiredClient.dispatch(
        action: "act",
        body: ["handle": .string("aaa"), "frame_id": .string("old-frame"), "verb": .string("click")]
    )
    #expect(expired.error == "frame_expired")
    #expect(_object(expired.output)["guidance"] != nil)
}

// MARK: - The drift guard, end to end

@Test
func act_refusesWithHandleDrifted_andNamesWhatIsThereNow() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")

    // The app rebuilt the window between the look and the act: path [0,0] is
    // now "Delete". Acting on it would press the wrong button.
    let drifted = _ActSource([
        []: _ActElement(role: "AXWindow", title: "Lunch tomorrow", actions: []),
        [0]: _ActElement(role: "AXToolbar", title: "Compose toolbar", actions: []),
        [0, 0]: _ActElement(role: "AXButton", title: "Delete"),
    ])
    let effects = _EffectSource()
    let client = SwiftNativeMacControl(
        accessibilitySource: harness.source,
        eventSink: InertAvailableMacEventSink(),
        accessibilityActSource: drifted,
        effectObserverSource: effects,
        lookFrameStore: harness.store
    )
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(!result.ok)
    #expect(result.error == "handle_drifted")
    let output = _object(result.output)
    #expect(output["drifted_on"] == .string("label"))
    #expect(_object(output["found"] ?? .null)["label"] == .string("Delete"),
            "the refusal must name what is actually there now")
    #expect(_object(output["expected"] ?? .null)["label"] == .string("Send"))
    // Nothing was pressed and no observer was armed.
    #expect(!drifted.recordedCalls().contains { $0.hasPrefix("perform:") },
            "a drifted handle must never reach the actuator's perform")
    #expect(effects.installs() == 0)
}

// MARK: - B2: the act is anchored to the FRAME's app, not to whatever is in front

@Test
func act_resolvesInsideTheFramesPid_notWhateverIsFrontmost() async throws {
    // gpt-5.5 round-2 B2. The observer has always gone on the frame's pid; the
    // RESOLVE walked NSWorkspace.frontmostApplication. If anything stole front
    // between the look and the act, the same path/role/label could name a
    // plausible control in the wrong app and the verb fired there.
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok)
    #expect(!harness.actSource.pidsAskedFor().isEmpty, "the act path must ask by pid at all")
    #expect(harness.actSource.pidsAskedFor().allSatisfy { $0 == 4242 },
            "every resolve must name the pid the frame was captured from: \(harness.actSource.pidsAskedFor())")
    #expect(!harness.actSource.recordedCalls().contains { $0 == "resolve:[0, 0]" },
            "the frontmost-anchored resolve must not be on the act path: \(harness.actSource.recordedCalls())")
    #expect(harness.effects.pid() == 4242, "…the same pid the observer watches")
}

@Test
func act_refusesFrameAppGone_whenTheAppSheLookedAtIsNotThereAnyMore() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    // The app exited: its pid resolves nothing, even though SOME app is
    // frontmost and would happily have offered a path [0,0].
    harness.actSource.livePid = 9999

    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(!result.ok)
    #expect(result.error == "frame_app_gone")
    #expect(_object(result.output)["pid"] == .int(4242))
    let calls = harness.actSource.recordedCalls()
    #expect(!calls.contains { $0.hasPrefix("perform:") }, "a dead frame app must never be acted in: \(calls)")
    #expect(harness.effects.installs() == 0, "…and no observer is armed for it")
}

// MARK: - B3: the FULL identity re-check

/// Three same-label buttons in a row, each with its own rect. Handles are
/// `token`, `token.2`, `token.3` — genuinely position-derived, which is the
/// case role+label drift detection cannot see through.
private func _tripleSendElements(dropFirst: Bool = false) -> [Int: _Element] {
    func button(_ id: Int, y: Double) -> _Element {
        _Element(
            attributes: MacAXAttributes(
                role: "AXButton",
                title: "Send",
                frame: MacAXFrame(x: 10, y: y, w: 40, h: 20),
                actions: ["AXPress"]
            ),
            children: []
        )
    }
    var toolbarChildren = [100, 101, 102]
    var elements: [Int: _Element] = [
        100: button(100, y: 20),
        101: button(101, y: 60),
        102: button(102, y: 100),
    ]
    if dropFirst {
        // The first Send disappeared and the rest slid UP one position: path
        // [0,1] now addresses what used to be at [0,2].
        elements[101] = button(101, y: 20)
        elements[102] = button(102, y: 60)
        toolbarChildren = [101, 102]
    }
    elements[10] = _Element(attributes: MacAXAttributes(role: "AXToolbar", title: "Compose toolbar"), children: toolbarChildren)
    elements[0] = _Element(attributes: MacAXAttributes(role: "AXWindow", title: "Lunch tomorrow"), children: [10])
    return elements
}

private func _tripleSendActElements() -> [[Int]: _ActElement] {
    [
        []: _ActElement(role: "AXWindow", title: "Lunch tomorrow", actions: []),
        [0]: _ActElement(role: "AXToolbar", title: "Compose toolbar", actions: []),
        [0, 0]: _ActElement(role: "AXButton", title: "Send", frame: MacAXFrame(x: 10, y: 20, w: 40, h: 20)),
        [0, 1]: _ActElement(role: "AXButton", title: "Send", frame: MacAXFrame(x: 10, y: 60, w: 40, h: 20)),
        [0, 2]: _ActElement(role: "AXButton", title: "Send", frame: MacAXFrame(x: 10, y: 100, w: 40, h: 20)),
    ]
}

@Test
func act_refusesWhenASameLabelSiblingShifted_underTheHandleSheNamed() async throws {
    // Agent #3b / gpt-5.5 B3 — "Send #2 became Send #1". Role matches, label
    // matches, and the OLD guard pressed a different button.
    let source = _MutableLookSource(elements: _tripleSendElements(), rootID: 0)
    let actSource = _ActSource(_tripleSendActElements())
    let effects = _EffectSource()
    let store = MacLookFrameStore()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: InertAvailableMacEventSink(),
        accessibilityActSource: actSource,
        effectObserverSource: effects,
        lookFrameStore: store
    )
    let look = try await client.dispatch(action: "look", body: [:])
    let output = _object(look.output)
    guard case .string(let frameId)? = output["frame_id"] else {
        Issue.record("no frame_id")
        return
    }
    // The SECOND Send — path [0,1], an ordinal handle by construction.
    var second: (handle: String, ambiguous: Bool)?
    for row in _array(output["affordances"]) {
        let object = _object(row)
        guard object["path"] == .array([.int(0), .int(1)]), case .string(let handle)? = object["handle"] else { continue }
        second = (handle, object["handle_ambiguous"] == .bool(true))
    }
    guard let second else {
        Issue.record("the look must expose the second Send: \(output["affordances"] ?? .null)")
        return
    }
    #expect(second.ambiguous, "three identical Sends can only be told apart by position")

    // A sibling ABOVE disappears; [0,1] is now the button that was at [0,2].
    source.mutate { elements, _, _ in elements = _tripleSendElements(dropFirst: true) }

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(second.handle), "frame_id": .string(frameId), "verb": .string("click")]
    )
    #expect(!result.ok)
    #expect(result.error == "handle_drifted")
    // The handle string is IDENTICAL after the shift (`token.2` of two Sends
    // instead of three) and the re-flowed list even REUSES the rect the second
    // button had. What moved is the cohort the ordinal was drawn from.
    #expect(_object(result.output)["drifted_on"] == .string("positional_cohort"),
            "\(result.output)")
    #expect(!actSource.recordedCalls().contains { $0.hasPrefix("perform:") },
            "the actuator must never see a perform for a drifted handle: \(actSource.recordedCalls())")
    #expect(effects.installs() == 0)
}

@Test
func act_refusesWhenAPositionalHandlesElementMoved() async throws {
    // The other half of the positional guard: the cohort is unchanged (still
    // three Sends) but the element at her ordinal is drawn somewhere else, so
    // the position her handle stands for is no longer the same place.
    let source = _MutableLookSource(elements: _tripleSendElements(), rootID: 0)
    let actSource = _ActSource(_tripleSendActElements())
    let effects = _EffectSource()
    let store = MacLookFrameStore()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: InertAvailableMacEventSink(),
        accessibilityActSource: actSource,
        effectObserverSource: effects,
        lookFrameStore: store
    )
    let look = try await client.dispatch(action: "look", body: [:])
    let output = _object(look.output)
    guard case .string(let frameId)? = output["frame_id"] else {
        Issue.record("no frame_id")
        return
    }
    var handle = ""
    for row in _array(output["affordances"]) where _object(row)["path"] == .array([.int(0), .int(1)]) {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    #expect(!handle.isEmpty)

    source.mutate { elements, _, _ in
        elements[101]?.attributes = MacAXAttributes(
            role: "AXButton",
            title: "Send",
            frame: MacAXFrame(x: 10, y: 400, w: 40, h: 20),
            actions: ["AXPress"]
        )
    }
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("click")]
    )
    #expect(!result.ok)
    #expect(result.error == "handle_drifted")
    #expect(_object(result.output)["drifted_on"] == .string("positional_rect"), "\(result.output)")
    #expect(!actSource.recordedCalls().contains { $0.hasPrefix("perform:") })
}

@Test
func act_refusesWhenTheLiveElementRendersADifferentHandle() async throws {
    // The identity component that is NOT role or label: the element at her path
    // now fingerprints differently (its container was retitled), so the handle
    // she holds no longer names it.
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    harness.source.mutate { elements, _, _ in
        elements[10]?.attributes = MacAXAttributes(role: "AXToolbar", title: "Reply toolbar")
    }
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(!result.ok)
    #expect(result.error == "handle_drifted")
    #expect(_object(result.output)["drifted_on"] == .string("handle"))
    let found = _object(_object(result.output)["found"] ?? .null)
    #expect(found["role"] == .string("AXButton"), "the refusal names what is there now: \(found)")
    #expect(!harness.actSource.recordedCalls().contains { $0.hasPrefix("perform:") })
}

@Test
func act_stillActs_whenNothingAboutTheElementsIdentityMoved() async throws {
    // The negative control for both new guards: an unchanged window acts.
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok, "an unchanged control must still be actable: \(result.error ?? "nil")")
    #expect(harness.actSource.recordedCalls().contains("perform:AXPress:[0, 0]"))
}

@Test
func handleSurvivesAWindowTitleChange_soTheIdentityGuardIsNotAlwaysOn() async throws {
    // Agent round 2 — the window title used to be in every element's ancestor
    // chain, so a document rename reminted every handle in the window. With B3
    // comparing handles, that would have refused every act after any title
    // change. The window's ROLE stays in the chain; its title does not.
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    harness.source.mutate { elements, _, _ in
        elements[0]?.attributes = MacAXAttributes(role: "AXWindow", title: "Dinner tonight")
    }
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok, "a retitled window must not invalidate the controls inside it: \(result.error ?? "nil")")
}

// MARK: - Verb → mechanism

@Test
func click_pressesTheElementThroughTheActuator() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok)
    let output = _object(result.output)
    #expect(output["verb"] == .string("click"))
    #expect(output["performed"] == .bool(true))
    #expect(output["method"] == .string("ax_action"))
    #expect(harness.actSource.recordedCalls().contains("perform:AXPress:[0, 0]"),
            "click must AXPress the element she named: \(harness.actSource.recordedCalls())")
}

@Test
func select_andToggle_pressTheSameWay() async throws {
    for verb in ["select", "toggle"] {
        let harness = _harness()
        let looked = try await _lookForHandle(harness, label: "Send")
        let result = try await harness.client.dispatch(
            action: "act",
            body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string(verb)]
        )
        #expect(result.ok, "\(verb)")
        #expect(_object(result.output)["verb"] == .string(verb))
        #expect(harness.actSource.recordedCalls().contains("perform:AXPress:[0, 0]"), "\(verb)")
    }
}

@Test
func type_setsTheValueWhenTheControlTakesOne_andNeverEchoesTheCharacters() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Subject")
    let result = try await harness.client.dispatch(
        action: "act",
        body: [
            "handle": .string(looked.handle),
            "frame_id": .string(looked.frameId),
            "verb": .string("type"),
            "text": .string("hunter2-correct-horse"),
        ]
    )
    #expect(result.ok)
    let output = _object(result.output)
    #expect(output["method"] == .string("ax_set_value"))
    #expect(output["value_redacted"] == .bool(true))
    #expect(harness.actSource.recordedCalls().contains { $0.hasPrefix("setValue:[1]:") },
            "type must set the value directly rather than simulating 21 keystrokes")
    // THE WHOLE PAYLOAD must not carry the characters anywhere.
    let serialized = String(data: try result.output.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!serialized.contains("hunter2-correct-horse"),
            "a typed secret must never ride out in the result: \(serialized)")
}

@Test
func type_refusesOnAButton_andNeverPressesIt() async throws {
    // gpt-5.5 round-2 B1, and the whole reason `type` has a role gate: the old
    // fallback "focused" the control by pressing it, so `type` aimed at Send
    // SENT THE MAIL. The refusal must be by name, and the actuator must show
    // no press at all.
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: [
            "handle": .string(looked.handle),
            "frame_id": .string(looked.frameId),
            "verb": .string("type"),
            "text": .string("abc"),
        ]
    )
    #expect(!result.ok)
    #expect(result.error == "verb_not_supported_on_element")
    let calls = harness.actSource.recordedCalls()
    #expect(!calls.contains { $0.hasPrefix("perform:") },
            "typing into a button must not press it: \(calls)")
    #expect(!calls.contains { $0.hasPrefix("setValue:") },
            "…and must not set its value either: \(calls)")
    let output = _object(result.output)
    #expect(_object(output["element"] ?? .null)["role"] == .string("AXButton"))
}

@Test
func type_focusesWithoutActivating_whenAnEditableControlRefusesTheValue() async throws {
    let harness = _harness()
    // An editable field whose AXValue is not settable — a web input, a
    // terminal, a rich-text view. The fallback is legitimate here.
    harness.actSource.valueSettable = false
    let looked = try await _lookForHandle(harness, label: "Subject")
    let result = try await harness.client.dispatch(
        action: "act",
        body: [
            "handle": .string(looked.handle),
            "frame_id": .string(looked.frameId),
            "verb": .string("type"),
            "text": .string("abc"),
        ]
    )
    #expect(result.ok)
    let output = _object(result.output)
    #expect(output["method"] == .string("keystroke_injection"))
    #expect(output["fallback_reason"] == .string("value_not_settable"))
    #expect(output["focus_method"] == .string("ax_focus"),
            "focus is the AXFocused ATTRIBUTE, never the element's action")
    #expect(output["text_character_count"] == .int(3))
    let calls = harness.actSource.recordedCalls()
    #expect(calls.contains("setFocused:[1]"), "\(calls)")
    #expect(!calls.contains { $0.hasPrefix("perform:") },
            "even on a text field, focusing must not invoke the app's handler: \(calls)")
}

@Test
func type_refusesWhenTheFieldCannotEvenTakeFocus() async throws {
    let harness = _harness()
    harness.actSource.valueSettable = false
    harness.actSource.focusSettable = false
    let looked = try await _lookForHandle(harness, label: "Subject")
    let result = try await harness.client.dispatch(
        action: "act",
        body: [
            "handle": .string(looked.handle),
            "frame_id": .string(looked.frameId),
            "verb": .string("type"),
            "text": .string("abc"),
        ]
    )
    let output = _object(result.output)
    #expect(output["ok"] == .bool(false) || result.ok == false)
    #expect(output["error"] == .string("focus_not_settable"),
            "unfocusable ⇒ say so; typing anyway scatters the text wherever focus already was")
    #expect(output["method"] == .string("none"))
}

@Test
func open_usesAXOpen_whenTheElementAdvertisesIt() async throws {
    // Agent round 2 — Finder is unnavigable without an open verb.
    let source = _MutableLookSource(elements: _composeElements(), rootID: 0)
    let actSource = _ActSource([
        []: _ActElement(role: "AXWindow", title: "Lunch tomorrow", actions: []),
        [0]: _ActElement(role: "AXToolbar", title: "Compose toolbar", actions: []),
        [0, 0]: _ActElement(role: "AXButton", title: "Send", actions: ["AXPress", "AXOpen"]),
        [0, 1]: _ActElement(role: "AXButton", title: "Cancel"),
        [1]: _ActElement(role: "AXTextField", title: "Subject", value: "Lunch"),
    ])
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXValueChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else {
        Issue.record("no frame")
        return
    }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string("Send") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    #expect(result.ok)
    let output = _object(result.output)
    #expect(output["method"] == .string("ax_action"))
    #expect(output["requested_action"] == .string("AXOpen"))
    #expect(actSource.recordedCalls().contains("perform:AXOpen:[0, 0]"), "\(actSource.recordedCalls())")
    #expect(sink.mouse.isEmpty, "the semantic form needs no synthesized input")
}

@Test
func open_fallsBackToADoubleClickThroughTheExistingClickPath() async throws {
    let source = _MutableLookSource(elements: _composeElements(), rootID: 0)
    let actSource = _ActSource(_composeActElements())
    let sink = _RecordingEventSink()
    let store = MacLookFrameStore()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXValueChanged"]),
        lookFrameStore: store
    )
    let harness = _Harness(client: client, source: source, actSource: actSource, effects: _EffectSource(), store: store)
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("open")]
    )
    #expect(result.ok)
    let output = _object(result.output)
    #expect(output["method"] == .string("cgevent_double_click_fallback"))
    #expect(output["click_count"] == .int(2))
    // The SAME planner every other click goes through: move, then two full
    // down/up pairs with an incrementing click state.
    let mouse = sink.mouse
    #expect(mouse.count == 5, "move + (down,up) × 2: \(mouse)")
    #expect(mouse.last?.clickCount == 2, "the second click must carry clickCount 2 or no app reads it as a double: \(mouse)")
}

@Test
func act_summarizesABulkChange_insteadOfShowingTenOfFortyFour() async throws {
    // Agent round 2 — a Finder view switch added 44 affordances and the effect
    // showed 10 of them, with 222 notifications dropped. Ten rows is not a
    // description of what happened.
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    harness.source.mutate { elements, root, focus in
        var rows: [Int] = []
        for index in 0..<24 {
            let id = 300 + index
            elements[id] = _Element(
                attributes: MacAXAttributes(role: "AXRow", title: "Row \(index)", actions: ["AXPress"]),
                children: []
            )
            rows.append(id)
        }
        elements[30] = _Element(attributes: MacAXAttributes(role: "AXTable", title: "Files"), children: rows)
        elements[0] = _Element(
            attributes: MacAXAttributes(role: "AXWindow", title: "Lunch tomorrow"),
            children: [10, 11, 30]
        )
        root = 0
        focus = [2, 3]
    }
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok)
    let effect = _object(_object(result.output)["effect"] ?? .null)
    #expect(_array(effect["affordances_added"]).count == MacActClosedLoop.maxDiffRows,
            "the capped list is still there — the summary is ALONGSIDE it, never instead of it")
    let summary = _object(effect["summary"] ?? .null)
    #expect(_object(summary["added_by_role"] ?? .null)["AXRow"] == .int(24),
            "the census counts the WHOLE change, not the ten rows that fit: \(summary)")
    let container = _object(summary["new_focus_container"] ?? .null)
    #expect(container["role"] == .string("AXTable"))
    #expect(container["label"] == .string("Files"))
    #expect(container["child_count"] == .int(24))
    #expect(_array(container["first_children"]).count == 10, "first children are capped at ten: \(container)")
    #expect(_array(container["first_children"]).first == .string("Row 0"))
}

@Test
func act_doesNotSummarize_whenTheChangeIsSmallEnoughToJustShow() async throws {
    // The negative control: an ordinary change carries no summary block, so the
    // presence of one really does mean "this was too big to list".
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    harness.source.mutate { elements, _, _ in elements = _composeElements(withSheet: true) }
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok)
    #expect(_object(_object(result.output)["effect"] ?? .null)["summary"] == nil)
}

@Test
func dismiss_pressesTheModalsOwnCancelButton() async throws {
    let harness = _harness(withSheet: true)
    let looked = try await _lookForHandle(harness, label: "Save Draft")
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("dismiss")]
    )
    #expect(result.ok)
    let output = _object(result.output)
    #expect(output["verb"] == .string("dismiss"))
    #expect(harness.actSource.recordedCalls().contains("perform:AXPress:[2, 1]"),
            "dismiss presses the sheet's Cancel, not the handle she named: \(harness.actSource.recordedCalls())")
    #expect(_object(output["dismiss_target"] ?? .null)["label"] == .string("Cancel"))
}

@Test
func dismiss_failsLoudWithNoDismissTarget_whenThereIsNothingToClose() async throws {
    let harness = _harness(withSheet: false)
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("dismiss")]
    )
    #expect(!result.ok)
    #expect(result.error == "no_dismiss_target", "a dismiss with nothing to dismiss must never be a silent no-op")
    // The observer WAS armed by then — and it must still have been removed.
    #expect(harness.effects.installs() == 1)
    #expect(harness.effects.stops() == 1, "the observer is removed on the ERROR path too")
}

@Test
func scroll_usesAXScrollToVisible_whenTheElementAdvertisesIt() async throws {
    let source = _MutableLookSource(elements: _composeElements(), rootID: 0)
    let actSource = _ActSource([
        []: _ActElement(role: "AXWindow", title: "Lunch tomorrow", actions: []),
        [0]: _ActElement(role: "AXToolbar", title: "Compose toolbar", actions: []),
        [0, 0]: _ActElement(role: "AXButton", title: "Send", actions: ["AXPress", "AXScrollToVisible"]),
    ])
    let effects = _EffectSource()
    let store = MacLookFrameStore()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: InertAvailableMacEventSink(),
        accessibilityActSource: actSource,
        effectObserverSource: effects,
        lookFrameStore: store
    )
    let harness = _Harness(client: client, source: source, actSource: actSource, effects: effects, store: store)
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await client.dispatch(
        action: "act",
        body: [
            "handle": .string(looked.handle),
            "frame_id": .string(looked.frameId),
            "verb": .string("scroll"),
            "direction": .string("up"),
        ]
    )
    #expect(result.ok)
    #expect(_object(result.output)["requested_action"] == .string("AXScrollToVisible"))
    #expect(actSource.recordedCalls().contains("perform:AXScrollToVisible:[0, 0]"))
}

@Test
func scroll_fallsBackToTheWheelPath_whenTheElementDoesNot() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: [
            "handle": .string(looked.handle),
            "frame_id": .string(looked.frameId),
            "verb": .string("scroll"),
        ]
    )
    #expect(result.ok)
    let output = _object(result.output)
    #expect(output["method"] == .string("cgevent_scroll_fallback"))
    #expect(output["direction"] == .string("down"), "direction defaults to down")
    #expect(output["dy"] == .int(-3), "down moves the content up, the way a human means it")

    let badDirection = try await harness.client.dispatch(
        action: "act",
        body: [
            "handle": .string(looked.handle),
            "frame_id": .string(looked.frameId),
            "verb": .string("scroll"),
            "direction": .string("sideways"),
        ]
    )
    #expect(badDirection.error?.hasPrefix("unknown_direction") == true)
}

// MARK: - The closed loop itself

@Test
func act_returnsTheEffect_theNewFrameAndAGlance_inTheSameCall() async throws {
    let harness = _harness(focus: [1])
    let looked = try await _lookForHandle(harness, label: "Send")

    // The app reacts: the sheet opens, the subject changes, focus moves.
    harness.source.mutate { elements, root, focus in
        elements = _composeElements(withSheet: true)
        elements[11]?.attributes = MacAXAttributes(
            role: "AXTextField", title: "Subject", value: "Dinner", actions: ["AXPress"]
        )
        root = 0
        focus = [2, 1]
    }

    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok)
    let output = _object(result.output)
    let effect = _object(output["effect"] ?? .null)

    // 1. THE EFFECT — observed, timed, named.
    #expect(effect["observed"] == .bool(true))
    #expect(effect["observer_installed"] == .bool(true))
    #expect(effect["first_notification_ms"] != nil, "an observed effect must carry its latency")
    #expect(_array(effect["notifications"]) == [.string("AXValueChanged"), .string("AXTitleChanged")])
    #expect(harness.effects.pid() == 4242, "the observer goes on the app SHE LOOKED AT, not whatever is frontmost")
    #expect(harness.effects.kinds().count == 12)

    // 2. THE DIFF — the sheet's buttons appeared, the subject changed, focus
    //    moved, the modal opened, the title changed.
    #expect(effect["window_changed"] == .bool(true))
    let added = _array(effect["affordances_added"]).map { _object($0)["label"] ?? .null }
    #expect(added.contains(.string("Save Draft")), "the sheet's buttons are new affordances: \(added)")
    let changed = _array(effect["changed"])
    #expect(changed.contains { _object($0)["value_after"] == .string("Dinner") },
            "the subject field's new value must show up as a change: \(changed)")
    #expect(effect["focus_changed"] == .bool(true))
    #expect(effect["focus_changed_to"] != nil)
    #expect(_object(effect["modal"] ?? .null)["appeared"] == .bool(true))
    #expect(effect["window_title"] == nil, "the window title did not move in this fixture")

    // 3. THE ACTED ELEMENT, before and after.
    let acted = _object(effect["acted_element"] ?? .null)
    #expect(_object(acted["before"] ?? .null)["label"] == .string("Send"))
    #expect(acted["after"] != nil)

    // 4. A NEW FRAME + a glance, so the next verb continues from here and the
    //    model NEVER has to look again to find out what happened.
    guard case .string(let newFrameId)? = output["frame_id"] else {
        Issue.record("act must return a fresh frame_id")
        return
    }
    #expect(newFrameId != looked.frameId, "the new frame is a NEW frame")
    #expect(await harness.store.latestFrameId() == newFrameId, "the new frame is the one the store holds")
    guard case .string(let glance)? = output["glance"] else {
        Issue.record("act must return a glance of the new state")
        return
    }
    #expect(glance.contains("MODAL"), "the glance describes the state the act produced: \(glance)")

    // …and a handle from the OLD frame is dead.
    let stale = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(stale.error == "stale_frame")
}

/// gpt-5.5 round-3 N8. This test used to claim the opposite — that a window
/// retitle reminted every handle — and asserted it as
/// `added_total == removed_total`, which is `0 == 0` under the round-2 rule
/// that took the window title OUT of the ancestor chain. A pin that passes
/// whether or not the thing it names happened is not a pin.
///
/// The invariant now: a TITLE-ONLY change moves the title and NOTHING else. No
/// handle churn at all, so a handle she is holding survives her app renaming
/// its own window (which Mail, Xcode and every editor do constantly).
@Test
func act_reportsAWindowTitleChange_withNoHandleChurnAtAll() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    harness.source.mutate { elements, _, _ in
        elements[0]?.attributes = MacAXAttributes(role: "AXWindow", title: "Dinner tonight")
    }
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok)
    let effect = _object(_object(result.output)["effect"] ?? .null)
    #expect(effect["window_title"] == .string("Dinner tonight"), "the retitle is reported: \(effect)")
    #expect(effect["affordances_added_total"] == .int(0),
            "a retitle adds no control: \(_array(effect["affordances_added"]))")
    #expect(effect["affordances_removed_total"] == .int(0),
            "a retitle removes no control: \(_array(effect["affordances_removed"]))")
    #expect(_array(effect["changed"]).isEmpty, "and nothing about any control changed either")
    // The handle she is HOLDING is the same handle afterwards — the whole point
    // of dropping the window title from the fingerprint.
    guard case .string(let newFrameId)? = _object(result.output)["frame_id"] else {
        Issue.record("act must return a fresh frame_id")
        return
    }
    let newFrame = await harness.store.frame(frameId: newFrameId)
    #expect(newFrame?.entries[looked.handle] != nil,
            "the handle must survive a title-only change: \(newFrame?.entries.keys.sorted() ?? [])")
}

@Test
func act_reportsNoneObserved_whenTheAppPublishesNothing() async throws {
    let harness = _harness(script: [])
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: [
            "handle": .string(looked.handle),
            "frame_id": .string(looked.frameId),
            "verb": .string("click"),
            "wait_ms": .int(0),
        ]
    )
    #expect(result.ok, "nothing observed is a real OUTCOME, not a failure")
    let effect = _object(_object(result.output)["effect"] ?? .null)
    #expect(effect["observed"] == .bool(false))
    #expect(effect["reason"] == .string("none_observed"))
    #expect(effect["first_notification_ms"] == nil)
    #expect(_array(effect["notifications"]).isEmpty)
    // The observer went in and came back out even though it never fired.
    #expect(harness.effects.installs() == 1)
    #expect(harness.effects.stops() == 1, "the observer is removed on the TIMEOUT path")
}

@Test
func act_refusesEntirely_whenNoEffectObserverCanBeInstalled() async throws {
    // gpt-5.5 round-2 B2. This used to ACT and then say "observer_installed:
    // false" — a blind press wearing the closed loop's costume, on the one
    // tool whose entire promise is that she never has to re-look to learn
    // whether it landed. No observer, no act, and say so.
    let harness = _harness(installable: false)
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(!result.ok)
    #expect(result.error == "observer_unavailable")
    let output = _object(result.output)
    #expect(output["pid"] == .int(4242), "the refusal names the app it could not watch")
    guard case .string(let guidance)? = output["guidance"] else {
        Issue.record("an uninstallable observer must be REPORTED with what to do next")
        return
    }
    #expect(guidance.contains("NOTHING WAS ACTED ON"))
    #expect(!harness.actSource.recordedCalls().contains { $0.hasPrefix("perform:") },
            "nothing may be pressed when the effect cannot be observed: \(harness.actSource.recordedCalls())")
}

@Test
func act_installsExactlyOneObserver_andRemovesIt_onTheSuccessPath() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok)
    #expect(harness.effects.installs() == 1, "exactly one observer per act")
    #expect(harness.effects.stops() == 1, "…and it is removed")
}

@Test
func act_clampsWaitMsToTheHardCap_andEchoesWhatItUsed() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: [
            "handle": .string(looked.handle),
            "frame_id": .string(looked.frameId),
            "verb": .string("click"),
            "wait_ms": .int(99_999),
        ]
    )
    #expect(result.ok)
    #expect(_object(_object(result.output)["effect"] ?? .null)["wait_ms"] == .int(Int64(MacActClosedLoop.maxWaitMs)),
            "a caller cannot widen the hard cap")
}

@Test
func act_refusesAndKillsTheFrame_whenTheWindowIsGoneBeforeItCanVerify() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    // The window closed between the look and the act.
    harness.source.mutate { _, root, _ in root = nil }

    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    // B3: with no live window there is nothing to re-check the handle against,
    // so the act is refused rather than fired at a path in a vanished tree.
    #expect(!result.ok)
    #expect(result.error == "frame_app_gone")
    let output = _object(result.output)
    #expect(output["reason"] == .string("no_window_to_verify_against"))
    #expect(await harness.store.latestFrameId() == nil, "handles from a dead window must never resolve")
    #expect(!harness.actSource.recordedCalls().contains { $0.hasPrefix("perform:") },
            "nothing may be pressed in a window that is gone")
    #expect(harness.effects.installs() == 0, "the refusal happens before the observer is armed")
}

// MARK: - Tier + inventory

@Test
func act_isInjectionTier_notReadTier() {
    #expect(macControlAccessibilityInjectionActions.contains("act"),
            "act presses and types — read tier for it would be a bypass with a percept stapled on")
    #expect(macControlAccessibilityActActions.contains("act"))
    #expect(!macControlAccessibilityReadActions.contains("act"))
    #expect(macControlDispatchableActions.contains("act"))
    #expect(macControlGateCategory(forAction: "act") == "accessibility")
    #expect(!macControlAllActions.contains("act"), "act has no retired-daemon ancestor")
    #expect(MacInjectionToolNames.isInjectionTool("mac_act"))
    #expect(MacInjectionToolNames.action(forTool: "mac_act") == "act")
    #expect(MacInjectionArgRedaction.carriesSecretArgs(tool: "mac_act"),
            "mac_act{verb:type,text:…} carries literal characters — the same class of secret as mac_keystroke.text")
}

@Test
func act_requiresACapabilityBoundToIt() {
    // The mint refuses an action outside the injection set, so this also pins
    // that `act` really is inside it.
    let capability = MacInjectionCapability.mint(
        approvalID: "test-approval",
        action: "act",
        body: ["handle": .string("aaa"), "verb": .string("click")]
    )
    #expect(capability != nil, "act must be mintable — it is an injection action")
    // …and a capability minted for a DIFFERENT body authorizes nothing.
    #expect(capability?.authorizationFailure(
        action: "act",
        body: ["handle": .string("bbb"), "verb": .string("click")],
        now: Date()
    ) == .bodyMismatch)
}

@Test
func actArgumentRedaction_replacesTheTypedCharactersWithCountAndDigest() {
    let redacted = MacInjectionArgRedaction.redacted(
        tool: "mac_act",
        input: ["verb": .string("type"), "text": .string("hunter2"), "handle": .string("aaa")]
    )
    #expect(redacted["text"] == nil, "the characters must not survive into anything that persists a request")
    #expect(redacted["text_character_count"] == .int(7))
    #expect(redacted["text_redacted"] == .bool(true))
    #expect(redacted["handle"] == .string("aaa"), "non-secret arguments pass through untouched")
}

// MARK: - B1/B2: the frame's WINDOW, not just its app
//
// gpt-5.5 round-3. Round 2 anchored the act to the frame's PID; inside the
// right app the resolve still took "focused, else main, else first". Two
// windows of one app plus a focus change between the look and the act put the
// verb in the WRONG window while every pid check passed — and the post-act
// read, which had no anchor at all, then described and STORED whatever was
// frontmost as the new frame.
//
// These fakes are deliberately MULTI-WINDOW on both seams, and both record
// which window each call landed in, so "it acted in the window she looked at"
// is an assertion about behaviour rather than about a single-window fixture
// that could not have failed.

private struct _WindowFixture {
    var title: String?
    var frame: MacAXFrame
    /// The one button this window has, as `role`/`label`.
    var buttonLabel: String
}

private final class _MultiWindowLookSource: MacAXElementSource, @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [_WindowFixture]
    /// Which window `frontmostWindowRoot()` answers with — the thing that
    /// MOVES between the look and the act.
    private var front: Int
    private let pid: Int32
    /// Which app is FRONTMOST — not necessarily the app being read. S7: a
    /// pid-anchored read that labels itself with `frontmostApp()` puts another
    /// app's name and pid on a correct background read.
    private var frontApp: MacAXAppInfo?

    init(windows: [_WindowFixture], front: Int = 0, pid: Int32 = 4242) {
        self.windows = windows
        self.front = front
        self.pid = pid
        self.frontApp = MacAXAppInfo(name: "Mail", bundleIdentifier: "com.apple.mail", processIdentifier: pid)
    }

    func setFront(_ index: Int) {
        lock.lock(); front = index; lock.unlock()
    }

    func setFrontmostApp(_ app: MacAXAppInfo?) {
        lock.lock(); frontApp = app; lock.unlock()
    }

    func closeWindow(at index: Int) {
        lock.lock(); windows.remove(at: index); front = 0; lock.unlock()
    }

    private func snapshotWindows() -> ([_WindowFixture], Int) {
        lock.lock(); defer { lock.unlock() }
        return (windows, front)
    }

    // Element ids: window w is `10 * (w + 1)`, its button `10 * (w + 1) + 1`.
    private func windowIndex(for ref: MacAXElementRef) -> Int? {
        let candidate = ref.id / 10 - 1
        let (all, _) = snapshotWindows()
        return candidate >= 0 && candidate < all.count ? candidate : nil
    }

    func isTrusted() -> Bool { true }
    func frontmostApp() -> MacAXAppInfo? {
        lock.lock(); defer { lock.unlock() }
        return frontApp
    }
    func frontmostWindowRoot() -> MacAXElementRef? {
        let (all, front) = snapshotWindows()
        guard front < all.count else { return nil }
        return MacAXElementRef(id: 10 * (front + 1))
    }
    func windowRoots(pid requested: Int32) -> [MacAXWindowHandle] {
        guard requested == pid else { return [] }
        let (all, _) = snapshotWindows()
        return all.enumerated().map { index, window in
            MacAXWindowHandle(
                ref: MacAXElementRef(id: 10 * (index + 1)),
                identity: MacAXWindowIdentity(
                    pid: pid,
                    index: index,
                    role: "AXWindow",
                    subrole: "AXStandardWindow",
                    title: window.title,
                    frame: window.frame
                )
            )
        }
    }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? {
        let (all, _) = snapshotWindows()
        guard let index = windowIndex(for: ref) else { return nil }
        let window = all[index]
        if ref.id % 10 == 0 {
            return MacAXAttributes(
                role: "AXWindow",
                subrole: "AXStandardWindow",
                title: window.title,
                frame: window.frame
            )
        }
        return MacAXAttributes(
            role: "AXButton",
            title: window.buttonLabel,
            frame: MacAXFrame(x: window.frame.x + 10, y: window.frame.y + 10, w: 40, h: 20),
            actions: ["AXPress"]
        )
    }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        guard ref.id % 10 == 0, windowIndex(for: ref) != nil else { return [] }
        return [MacAXElementRef(id: ref.id + 1)]
    }
}

private final class _MultiWindowActSource: MacAXActSource, @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [_WindowFixture]
    /// The window a NON-window-anchored resolve lands in — the old
    /// "focused, else main, else first" behaviour, kept so the anchored path
    /// has something to be different from.
    private var front: Int
    private let pid: Int32
    private var handleWindow: [Int: Int] = [:]
    private var nextHandle = 0
    private(set) var resolvedWindowLabels: [String] = []

    init(windows: [_WindowFixture], front: Int = 0, pid: Int32 = 4242) {
        self.windows = windows
        self.front = front
        self.pid = pid
    }

    func setFront(_ index: Int) { lock.lock(); front = index; lock.unlock() }
    func closeWindow(at index: Int) { lock.lock(); windows.remove(at: index); front = 0; lock.unlock() }
    func windowsActedIn() -> [String] { lock.lock(); defer { lock.unlock() }; return resolvedWindowLabels }

    private func describe(windowIndex: Int, path: [Int]) -> MacAXPidResolution {
        lock.lock(); defer { lock.unlock() }
        guard windowIndex < windows.count else { return .windowGone }
        let window = windows[windowIndex]
        nextHandle += 1
        handleWindow[nextHandle] = windowIndex
        if path.isEmpty {
            return .resolved(MacAXActTarget(
                handle: nextHandle,
                role: "AXWindow",
                title: window.title,
                value: nil,
                enabled: true,
                frame: window.frame,
                actions: []
            ))
        }
        guard path == [0] else { return .pathNotFound }
        resolvedWindowLabels.append(window.buttonLabel)
        return .resolved(MacAXActTarget(
            handle: nextHandle,
            role: "AXButton",
            title: window.buttonLabel,
            value: nil,
            enabled: true,
            frame: MacAXFrame(x: window.frame.x + 10, y: window.frame.y + 10, w: 40, h: 20),
            actions: ["AXPress"]
        ))
    }

    func isTrusted() -> Bool { true }
    func resolve(path: [Int]) -> MacAXActTarget? {
        lock.lock(); let index = front; lock.unlock()
        guard case .resolved(let hit) = describe(windowIndex: index, path: path) else { return nil }
        return hit
    }
    /// The ROUND-2 anchor: right app, and then whatever window is focused. This
    /// is exactly the call the act path must NOT be making any more.
    func resolve(path: [Int], inAppPid requested: Int32) -> MacAXPidResolution {
        guard requested == pid else { return .appGone }
        lock.lock(); let index = front; lock.unlock()
        return describe(windowIndex: index, path: path)
    }
    func windows(pid requested: Int32) -> [MacAXWindowRef] {
        guard requested == pid else { return [] }
        lock.lock(); let all = windows; lock.unlock()
        return all.enumerated().map { index, window in
            MacAXWindowRef(
                handle: 1_000 + index,
                identity: MacAXWindowIdentity(
                    pid: pid,
                    index: index,
                    role: "AXWindow",
                    subrole: "AXStandardWindow",
                    title: window.title,
                    frame: window.frame
                )
            )
        }
    }
    func resolve(path: [Int], inWindow window: MacAXWindowRef) -> MacAXPidResolution {
        guard window.identity.pid == pid else { return .appGone }
        return describe(windowIndex: window.handle - 1_000, path: path)
    }
    func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome {
        target.actions.contains(action) ? .performed : .unsupported
    }
    func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome { .unsupported }
    func reread(_ target: MacAXActTarget) -> MacAXActTarget? { target }
}

private struct _WindowHarness {
    let client: SwiftNativeMacControl
    let look: _MultiWindowLookSource
    let act: _MultiWindowActSource
    let effects: _EffectSource
    let store: MacLookFrameStore
}

/// The same "look, then find the handle labelled X" step, for the multi-window
/// harness.
private func _lookForHandle(
    _ harness: _WindowHarness,
    label: String
) async throws -> (frameId: String, handle: String) {
    let look = try await harness.client.dispatch(action: "look", body: [:])
    #expect(look.ok, "the fixture look must succeed: \(look.error ?? "nil")")
    let output = _object(look.output)
    guard case .string(let frameId)? = output["frame_id"] else {
        Issue.record("look returned no frame_id")
        return ("", "")
    }
    for row in _array(output["affordances"]) {
        let object = _object(row)
        if object["label"] == .string(label), case .string(let handle)? = object["handle"] {
            return (frameId, handle)
        }
    }
    Issue.record("look exposed no affordance labeled \(label): \(output["affordances"] ?? .null)")
    return (frameId, "")
}

private func _windowHarness(_ windows: [_WindowFixture]) -> _WindowHarness {
    let look = _MultiWindowLookSource(windows: windows)
    let act = _MultiWindowActSource(windows: windows)
    let effects = _EffectSource(script: ["AXValueChanged"], installable: true)
    let store = MacLookFrameStore()
    return _WindowHarness(
        client: SwiftNativeMacControl(
            accessibilitySource: look,
            eventSink: InertAvailableMacEventSink(),
            accessibilityActSource: act,
            effectObserverSource: effects,
            lookFrameStore: store
        ),
        look: look,
        act: act,
        effects: effects,
        store: store
    )
}

private let _twoWindows = [
    _WindowFixture(title: "Compose", frame: MacAXFrame(x: 0, y: 0, w: 800, h: 600), buttonLabel: "Send"),
    _WindowFixture(title: "Inbox", frame: MacAXFrame(x: 300, y: 200, w: 900, h: 700), buttonLabel: "Archive"),
]

@Test
func act_staysInTheFramesWindow_whenAnotherWindowOfTheSameAppTakesFocus() async throws {
    let harness = _windowHarness(_twoWindows)
    let looked = try await _lookForHandle(harness, label: "Send")
    #expect(!looked.handle.isEmpty)

    // The frame recorded WHICH window, not just which app.
    let frame = await harness.store.frame(frameId: looked.frameId)
    #expect(frame?.windowIdentity?.title == "Compose",
            "the frame must name the window it was taken of: \(String(describing: frame?.windowIdentity))")

    // …and now the OTHER window of the same app takes focus.
    harness.look.setFront(1)
    harness.act.setFront(1)

    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok, "a background window act is legitimate: \(result.error ?? "nil")")
    #expect(harness.act.windowsActedIn() == ["Send"],
            "the verb must land in the window she LOOKED at, not the one that took focus: \(harness.act.windowsActedIn())")

    // B2 — and the post-act read is of that same window, so the diff and the
    // NEW FRAME describe what she acted on rather than what is in front.
    let output = _object(result.output)
    let acted = _object(_object(output["effect"] ?? .null)["acted_element"] ?? .null)
    #expect(_object(acted["before"] ?? .null)["label"] == .string("Send"))
    guard case .string(let newFrameId)? = output["frame_id"] else {
        Issue.record("act must return a fresh frame_id")
        return
    }
    let newFrame = await harness.store.frame(frameId: newFrameId)
    #expect(newFrame?.windowIdentity?.title == "Compose",
            "the frame the next verb acts from must still be the acted window: \(String(describing: newFrame?.windowIdentity))")
    #expect(newFrame?.entries.values.contains { $0.label == "Send" } == true,
            "the post-act percept is of the acted window, not of the frontmost one")
    #expect(newFrame?.entries.values.contains { $0.label == "Archive" } == false,
            "the frontmost window's controls must not appear in the acted window's frame")
}

@Test
func act_refusesFrameWindowGone_whenTheWindowSheLookedAtClosed() async throws {
    let harness = _windowHarness(_twoWindows)
    let looked = try await _lookForHandle(harness, label: "Send")
    // The composed window closes; the app and its OTHER window live on, so the
    // pid anchor alone would happily act in the survivor.
    harness.look.closeWindow(at: 0)
    harness.act.closeWindow(at: 0)
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(!result.ok)
    #expect(result.error == "frame_window_gone",
            "a surviving sibling window is not the window she looked at: \(result.error ?? "nil")")
    #expect(harness.act.windowsActedIn().isEmpty, "NOTHING may be pressed on this path")
    #expect(harness.effects.installs() == 0, "no observer is armed for an act that never happens")
}

@Test
func act_refusesWindowDrifted_whenTwoWindowsAreEquallyPlausible() async throws {
    // Two windows the app renders identically — same title, same rect. There is
    // no read-only public attribute left that tells them apart, and picking one
    // would be a coin flip on an irreversible act.
    let twins = [
        _WindowFixture(title: "Untitled", frame: MacAXFrame(x: 0, y: 0, w: 800, h: 600), buttonLabel: "Send"),
        _WindowFixture(title: "Untitled", frame: MacAXFrame(x: 0, y: 0, w: 800, h: 600), buttonLabel: "Send"),
    ]
    let harness = _windowHarness(twins)
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(!result.ok)
    #expect(result.error == "window_drifted", "an ambiguous window must refuse: \(result.error ?? "nil")")
    #expect(harness.act.windowsActedIn().isEmpty, "NOTHING may be pressed on a coin flip")
    #expect(harness.effects.installs() == 0)
}

@Test
func windowIdentity_matchesARetitledWindow_butNotAReplacedOne() {
    let looked = MacAXWindowIdentity(
        pid: 7,
        index: 0,
        role: "AXWindow",
        subrole: "AXStandardWindow",
        title: "Draft",
        frame: MacAXFrame(x: 0, y: 0, w: 800, h: 600)
    )
    func candidate(_ title: String?, _ frame: MacAXFrame, index: Int = 0) -> MacAXWindowIdentity {
        MacAXWindowIdentity(pid: 7, index: index, role: "AXWindow", subrole: "AXStandardWindow", title: title, frame: frame)
    }
    let sameRect = MacAXFrame(x: 0, y: 0, w: 800, h: 600)
    let movedRect = MacAXFrame(x: 400, y: 300, w: 800, h: 600)

    // A dirty marker / tab switch retitles the window in place: still it.
    if case .matched = MacAXWindowIdentity.match(
        looked,
        among: [(handle: 1, identity: candidate("Draft — Edited", sameRect)),
                (handle: 2, identity: candidate("Inbox", movedRect, index: 1))]
    ) {} else {
        Issue.record("a retitled window in the same place is the same window")
    }
    // Dragged across the screen, same title: still it.
    if case .matched = MacAXWindowIdentity.match(
        looked,
        among: [(handle: 1, identity: candidate("Draft", movedRect))]
    ) {} else {
        Issue.record("a moved window with the same title is the same window")
    }
    // Both moved: the app closed hers and put a different window there. The
    // SOLE-WINDOW shortcut must not swallow this — that is the whole reason the
    // contradiction test exists.
    if case .gone = MacAXWindowIdentity.match(
        looked,
        among: [(handle: 1, identity: candidate("Inbox", movedRect))]
    ) {} else {
        Issue.record("a differently-titled window in a different place is a different window")
    }
    // A sheet is not the document window behind it.
    if case .gone = MacAXWindowIdentity.match(
        looked,
        among: [(handle: 1, identity: MacAXWindowIdentity(
            pid: 7, index: 0, role: "AXSheet", subrole: nil, title: "Draft", frame: sameRect
        ))]
    ) {} else {
        Issue.record("a different ROLE is never the same window")
    }
    // Another process entirely.
    if case .gone = MacAXWindowIdentity.match(
        looked,
        among: [(handle: 1, identity: MacAXWindowIdentity(
            pid: 8, index: 0, role: "AXWindow", subrole: "AXStandardWindow", title: "Draft", frame: sameRect
        ))]
    ) {} else {
        Issue.record("the pid filter is absolute")
    }
}

// MARK: - B3/B4: the effect's own text channels are redacted UNDER CONTEXT
//
// gpt-5.5 round-3. Round 2 closed the affordance diff by carrying the compile's
// `labelJSON`/`valueJSON` through the frame; two channels were left running a
// context-free second opinion on stored strings — `readouts_changed`, and the
// dense bulk-change summary's `new_focus_container`. Neither can see the group
// titled "CVV" two rows up, so the value the look correctly withheld came back
// in the clear the moment it MOVED, or the moment 44 rows appeared at once.

// 2026-09-06: e1e14b27's whole-payload check for ASCII "123" can collide
// with a random frame UUID or digest. These remain three-digit CVVs under
// the shipped isNumber rule, but cannot occur in generated ASCII metadata.
private let _cvvBefore = "١٢٣"
private let _cvvAfter = "٤٥٦"

/// A checkout window: a CVV group holding a caption, a value-only readout and
/// the Pay button, plus an order-total readout OUTSIDE the group as the
/// negative control.
///
/// Paths: [0] AXGroup "CVV" / [0,0] caption / [0,1] the CVV readout /
///        [0,2] "Pay now" / [1] the order total.
private func _cvvElements(extraButtons: Int = 0) -> [Int: _Element] {
    var elements: [Int: _Element] = [
        40: _Element(
            attributes: MacAXAttributes(
                role: "AXStaticText", title: "Card details",
                frame: MacAXFrame(x: 10, y: 10, w: 200, h: 20)
            ),
            children: []
        ),
        41: _Element(
            attributes: MacAXAttributes(
                role: "AXStaticText", value: _cvvBefore,
                frame: MacAXFrame(x: 20, y: 40, w: 60, h: 24)
            ),
            children: []
        ),
        42: _Element(
            attributes: MacAXAttributes(
                role: "AXButton", title: "Pay now",
                frame: MacAXFrame(x: 20, y: 80, w: 90, h: 24), actions: ["AXPress"]
            ),
            children: []
        ),
        30: _Element(
            attributes: MacAXAttributes(
                role: "AXGroup", title: "CVV",
                frame: MacAXFrame(x: 0, y: 0, w: 300, h: 200)
            ),
            children: [40, 41, 42]
        ),
        50: _Element(
            attributes: MacAXAttributes(
                role: "AXStaticText", value: "Order total: $42",
                frame: MacAXFrame(x: 0, y: 300, w: 200, h: 20)
            ),
            children: []
        ),
    ]
    var rootChildren = [30, 50]
    for index in 0..<extraButtons {
        let id = 600 + index
        elements[id] = _Element(
            attributes: MacAXAttributes(
                role: "AXButton", title: "Extra \(index)",
                frame: MacAXFrame(x: 0, y: Double(400 + index * 20), w: 80, h: 18),
                actions: ["AXPress"]
            ),
            children: []
        )
        rootChildren.append(id)
    }
    elements[0] = _Element(
        attributes: MacAXAttributes(
            role: "AXWindow", title: "Checkout",
            frame: MacAXFrame(x: 0, y: 0, w: 400, h: 400)
        ),
        children: rootChildren
    )
    return elements
}

private func _cvvActElements() -> [[Int]: _ActElement] {
    [
        []: _ActElement(role: "AXWindow", title: "Checkout", actions: []),
        [0]: _ActElement(role: "AXGroup", title: "CVV", actions: []),
        [0, 0]: _ActElement(role: "AXStaticText", title: "Card details", actions: []),
        [0, 1]: _ActElement(role: "AXStaticText", title: nil, value: _cvvBefore, actions: []),
        [0, 2]: _ActElement(role: "AXButton", title: "Pay now"),
        [1]: _ActElement(role: "AXStaticText", title: nil, value: "Order total: $42", actions: []),
    ]
}

private func _cvvHarness(focus: [Int]? = nil, extraButtons: Int = 0) -> _Harness {
    let source = _MutableLookSource(
        elements: _cvvElements(),
        rootID: 0,
        focus: focus
    )
    let actSource = _ActSource(_cvvActElements())
    let effects = _EffectSource(script: ["AXValueChanged"], installable: true)
    let store = MacLookFrameStore()
    return _Harness(
        client: SwiftNativeMacControl(
            accessibilitySource: source,
            eventSink: InertAvailableMacEventSink(),
            accessibilityActSource: actSource,
            effectObserverSource: effects,
            lookFrameStore: store
        ),
        source: source,
        actSource: actSource,
        effects: effects,
        store: store
    )
}

private func _serialized(_ result: MacControlResult) -> String {
    (try? result.output.serializedData(pretty: false))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

@Test
func readoutsChanged_neverShipsAContextualSecret_beforeOrAfter() async throws {
    let harness = _cvvHarness()
    let looked = try await _lookForHandle(harness, label: "Pay now")
    // The CVV display changes, and the order total moves with it.
    harness.source.mutate { elements, _, _ in
        elements[41]?.attributes = MacAXAttributes(
            role: "AXStaticText", value: _cvvAfter,
            frame: MacAXFrame(x: 20, y: 40, w: 60, h: 24)
        )
        elements[50]?.attributes = MacAXAttributes(
            role: "AXStaticText", value: "Order total: $84",
            frame: MacAXFrame(x: 0, y: 300, w: 200, h: 20)
        )
    }
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok)
    let payload = _serialized(result)
    // The WHOLE payload — this rides the turn trace, the operation store and
    // the iOS/Telegram sync.
    // Scan the escaped contents without their quotes, so embedded leaks count too.
    let beforeNeedle = String(try JSONValue.string(_cvvBefore).serialize(pretty: false).dropFirst().dropLast())
    let afterNeedle = String(try JSONValue.string(_cvvAfter).serialize(pretty: false).dropFirst().dropLast())
    #expect(!payload.contains(beforeNeedle), "the CVV value before the change leaked: \(payload)")
    #expect(!payload.contains(afterNeedle), "the CVV value after the change leaked: \(payload)")

    let effect = _object(_object(result.output)["effect"] ?? .null)
    let changes = _array(effect["readouts_changed"]).map(_object)
    #expect(!changes.isEmpty, "the readout diff must still REPORT the change, just not in the clear")
    let cvv = changes.first { _array($0["path"]).count == 2 }
    #expect(cvv != nil, "the CVV readout must appear as changed: \(changes)")
    if let cvv {
        #expect(cvv["before"] != .string(_cvvBefore))
        #expect(cvv["after"] != .string(_cvvAfter))
        #expect(_object(cvv["before"] ?? .null)["reason"] == .string("enclosing_cvv"))
        #expect(_object(cvv["after"] ?? .null)["reason"] == .string("enclosing_cvv"))
    }
    // THE NEGATIVE CONTROL: the harmless total is the point of this channel and
    // must still arrive as characters, or "redacted everything" would pass too.
    let total = changes.first { _array($0["path"]).count == 1 }
    #expect(total?["before"] == .string("Order total: $42"), "a harmless readout must not be redacted: \(changes)")
    #expect(total?["after"] == .string("Order total: $84"))
}

@Test
func denseChangeSummary_neverShipsAContextualSecret_inItsFocusContainer() async throws {
    // Focus sits in the CVV box, so the summary's `new_focus_container` is the
    // CVV group and its `first_children` include the value the look withheld.
    let harness = _cvvHarness(focus: [0, 1])
    let looked = try await _lookForHandle(harness, label: "Pay now")
    // A bulk change — more additions than the row cap — is what turns the dense
    // summary on at all.
    harness.source.mutate { elements, _, _ in
        var rootChildren = elements[0]?.children ?? []
        for index in 0..<(MacActClosedLoop.maxDiffRows + 2) {
            let id = 700 + index
            elements[id] = _Element(
                attributes: MacAXAttributes(
                    role: "AXButton", title: "Row \(index)",
                    frame: MacAXFrame(x: 0, y: Double(400 + index * 20), w: 80, h: 18),
                    actions: ["AXPress"]
                ),
                children: []
            )
            rootChildren.append(id)
        }
        elements[0]?.children = rootChildren
    }
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok)
    let effect = _object(_object(result.output)["effect"] ?? .null)
    let summary = _object(effect["summary"] ?? .null)
    #expect(!summary.isEmpty, "a bulk change must produce the dense summary: \(effect)")
    let container = _object(summary["new_focus_container"] ?? .null)
    #expect(container["role"] == .string("AXGroup"), "the focus container must be the CVV group: \(container)")
    let children = _array(container["first_children"])
    #expect(!children.isEmpty)
    #expect(!children.contains(.string(_cvvBefore)), "the CVV value leaked through first_children: \(children)")
    // The negative control lives in the same list: the group's own caption is
    // harmless and must still read as characters.
    #expect(children.contains(.string("Card details")),
            "a harmless sibling label must survive the redaction: \(children)")
    let needle = String(try JSONValue.string(_cvvBefore).serialize(pretty: false).dropFirst().dropLast())
    #expect(!_serialized(result).contains(needle), "the CVV value leaked somewhere in the act payload")
}

@Test
func pidAnchoredRead_neverReportsTheFrontmostAppsIdentity() async throws {
    // gpt-5.5 round-3 S7. The post-act read is anchored to the FRAME's pid; it
    // used to take its `app` metadata from `frontmostApp()` regardless, so a
    // correct background act came back labelled with whatever the user had
    // switched to — and that label is what the NEW FRAME's pid is read from,
    // which is the anchor the next act hangs off.
    let harness = _windowHarness(_twoWindows)
    let looked = try await _lookForHandle(harness, label: "Send")
    // The user cmd-tabs to something else entirely between the look and the act.
    harness.look.setFrontmostApp(
        MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 999)
    )
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    #expect(result.ok)
    guard case .string(let newFrameId)? = _object(result.output)["frame_id"] else {
        Issue.record("act must return a fresh frame_id")
        return
    }
    let newFrame = await harness.store.frame(frameId: newFrameId)
    #expect(newFrame?.pid == 4242,
            "the new frame must stay anchored to the app that was acted on: \(String(describing: newFrame?.pid))")
    #expect(newFrame?.appName != "Finder",
            "a pid-anchored read must never wear the frontmost app's name: \(String(describing: newFrame?.appName))")
    #expect(newFrame?.bundleId != "com.apple.finder")
    #expect(harness.act.windowsActedIn() == ["Send"])
}

@Test
func appInfoForPid_answersAbsence_ratherThanTheFrontmostApp() {
    // The protocol default, in isolation: a source that only knows what is in
    // front says NOTHING about another pid rather than answering with the
    // frontmost app's name under someone else's pid.
    let source = _MultiWindowLookSource(windows: _twoWindows)
    #expect(source.appInfo(pid: 4242)?.name == "Mail")
    source.setFrontmostApp(
        MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 999)
    )
    #expect(source.appInfo(pid: 4242) == nil, "absence over a wrong answer")
    #expect(source.appInfo(pid: 999)?.name == "Finder")
}

// MARK: - Round 4: the acted/acted_unobserved verdict, through the REAL act path
//
// The classifier itself is pinned in MacActRound4NavigationTests. These three
// pin the WIRING: gpt-5.5 review of the round-4 fix noted that deleting the
// post-diff override in MacControl+Client would leave the pure-unit tests green
// while the live Finder bug walked straight back in. So these go through
// `client.dispatch(action: "act")` and read `status` off the envelope.

@Test
func act_open_thatMovedNothing_reportsActedUnobserved_throughTheRealPath() async throws {
    // A notification DOES fire (the default script) and the window is otherwise
    // untouched — Agent round 4's Finder `open` in fixture form.
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("open")]
    )
    #expect(result.ok, "the event still went out — ok is about delivery")
    let output = _object(result.output)
    #expect(output["performed"] == .bool(true))
    #expect(output["status"] == .string("acted_unobserved"),
            "an open that navigated nowhere must not read as success: \(output["status"] ?? .null)")
    #expect(output["status_reason"] == .string("navigation_unverified"))
    #expect(_object(output["effect"] ?? .null)["window_changed"] == .bool(false))
}

@Test
func act_open_thatRetitledTheWindow_reportsActed_throughTheRealPath() async throws {
    // NEGATIVE CONTROL in the reachable position: identical call, one real
    // navigation channel moves. Without this, the test above would pass just as
    // well if `open` were hardcoded to acted_unobserved.
    //
    // ROUND 6: the retitle must name the element we ACTED ON, because that is
    // what a real navigation looks like — Finder retitles the window to the
    // folder you opened. A retitle to something unrelated is covered by
    // act_open_thatRetitledToTheWrongPlace_isNotActed below.
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    harness.source.mutate { elements, _, _ in
        elements[0]?.attributes = MacAXAttributes(role: "AXWindow", title: "Send")
    }
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(output["status"] == .string("acted"))
    #expect(output["status_reason"] == nil)
}

@Test
func act_click_thatMovedNothing_stillReportsActed_throughTheRealPath() async throws {
    // REGRESSION FENCE for Agent's round-4 PASSES (Notes type, Calculator
    // equals): the navigation rule reaches `open` and nothing else.
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("click")]
    )
    let output = _object(result.output)
    #expect(output["status"] == .string("acted"))
    #expect(output["status_reason"] == nil)
}

// MARK: - Round 5 / finding 1(a): open lands on the ROW, through the REAL path
//
// Pure resolver coverage lives in MacActRound5OpenTargetTests. These pin the
// WIRING — a filename-cell handle taken from a real `look`, pushed through
// `client.dispatch(action:"act", verb:"open")`, must AXOpen the ROW and post no
// mouse events at all. Without these, deleting the resolver call in performAct
// would leave the pure tests green while Finder stayed unnavigable.

/// Agent's live Finder shape: window → outline → row → filename cell. The cell
/// is what `look` surfaces a handle for; the row is what opens.
private func _finderElements() -> [Int: _Element] {
    [
        300: _Element(
            attributes: MacAXAttributes(
                role: "AXTextField", title: ".agents", value: ".agents", actions: ["AXPress"]
            ),
            children: []
        ),
        30: _Element(
            attributes: MacAXAttributes(role: "AXRow", title: nil, actions: ["AXPress", "AXOpen"]),
            children: [300]
        ),
        3: _Element(attributes: MacAXAttributes(role: "AXOutline", title: nil), children: [30]),
        0: _Element(attributes: MacAXAttributes(role: "AXWindow", title: "home-folder"), children: [3]),
    ]
}

private func _finderActElements() -> [[Int]: _ActElement] {
    [
        []: _ActElement(role: "AXWindow", title: "home-folder", actions: []),
        [0]: _ActElement(role: "AXOutline", title: nil, actions: []),
        // The ROW opens…
        [0, 0]: _ActElement(role: "AXRow", title: nil, actions: ["AXPress", "AXOpen"]),
        // …the filename CELL does not. Double-clicking it renames.
        [0, 0, 0]: _ActElement(role: "AXTextField", title: ".agents", value: ".agents", actions: ["AXPress"]),
    ]
}

@Test
func open_onAFilenameCell_axOpensTheRow_andPostsNoMouseEvents() async throws {
    let source = _MutableLookSource(elements: _finderElements(), rootID: 0)
    let actSource = _ActSource(_finderActElements())
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else {
        Issue.record("no frame: \(look)")
        return
    }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    #expect(!handle.isEmpty, "the look must surface the filename cell: \(look["affordances"] ?? .null)")

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    #expect(result.ok)
    let output = _object(result.output)
    // THE FIX: AXOpen on the ROW's path, not a double-click on the text.
    #expect(actSource.recordedCalls().contains("perform:AXOpen:[0, 0]"),
            "must AXOpen the ROW: \(actSource.recordedCalls())")
    #expect(output["method"] == .string("ax_action"))
    #expect(sink.mouse.isEmpty,
            "no double-click may be synthesized when the row opens semantically: \(sink.mouse)")
    // And the redirect is REPORTED — an act landing off the named handle is
    // never allowed to be silent.
    let actedOn = _object(output["acted_on"] ?? .null)
    #expect(actedOn["role"] == .string("AXRow"))
    #expect(actedOn["hops"] == .int(1))
    #expect(actedOn["redirected"] == .bool(true))
    #expect(actedOn["reason"] == .string("ancestor_advertises_open"))
}

@Test
func open_withNoOpenableAncestor_stillFallsBackToTheHandlesDoubleClick() async throws {
    // NEGATIVE CONTROL in the reachable position: same call, no row anywhere.
    // The old behaviour must survive — otherwise the test above is pinning
    // "open always redirects" rather than the fix.
    var elements = _finderElements()
    elements[30] = _Element(
        attributes: MacAXAttributes(role: "AXGroup", title: nil, actions: []),
        children: [300]
    )
    var actElements = _finderActElements()
    actElements[[0, 0]] = _ActElement(role: "AXGroup", title: nil, actions: [])
    let source = _MutableLookSource(elements: elements, rootID: 0)
    let actSource = _ActSource(actElements)
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else {
        Issue.record("no frame")
        return
    }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(output["method"] == .string("cgevent_double_click_fallback"))
    #expect(!sink.mouse.isEmpty, "with nothing openable above it, the handle is still double-clicked")
    let actedOn = _object(output["acted_on"] ?? .null)
    #expect(actedOn["redirected"] == .bool(false))
    #expect(actedOn["reason"] == .string("no_openable_ancestor"))
}

/// AGENT'S ENVELOPE, EXACTLY. Her filename cell DID advertise `AXOpen` —
/// `fallback_reason=ax_action_refused` proves it — and refused it. A redirect
/// that only fires when the handle does not advertise `AXOpen` never fires for
/// her, and Finder stays unnavigable. Advertising is not doing.
@Test
func open_onACellThatAdvertisesAXOpenAndRefusesIt_stillReachesTheRow() async throws {
    var actElements = _finderActElements()
    // The cell advertises it, like hers.
    actElements[[0, 0, 0]] = _ActElement(
        role: "AXTextField", title: ".agents", value: ".agents", actions: ["AXPress", "AXOpen"]
    )
    var elements = _finderElements()
    elements[300] = _Element(
        attributes: MacAXAttributes(
            role: "AXTextField", title: ".agents", value: ".agents", actions: ["AXPress", "AXOpen"]
        ),
        children: []
    )
    let source = _MutableLookSource(elements: elements, rootID: 0)
    let actSource = _ActSource(actElements)
    // …and refuses it when asked, like hers.
    actSource.refuseActions = ["AXOpen"]
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else {
        Issue.record("no frame")
        return
    }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    #expect(!handle.isEmpty)
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    let actedOn = _object(output["acted_on"] ?? .null)
    // The refusal must escalate to the ROW, not fall straight to a rename click.
    #expect(actedOn["redirected"] == .bool(true),
            "a refused AXOpen on the cell must escalate to the row: \(actedOn)")
    #expect(actedOn["path"] == .array([.int(0), .int(0)]))
    let calls = actSource.recordedCalls()
    #expect(calls.contains("perform:AXOpen:[0, 0]"), "the ROW must be asked to open: \(calls)")
    #expect(sink.mouse.isEmpty || actedOn["role"] == .string("AXRow"),
            "any synthesized click must land on the row, never the filename text")
}

/// gpt-5.5 round-5 review: a redirected ancestor that cannot be re-resolved used
/// to fall back to double-clicking the ORIGINAL handle — re-running the exact
/// rename gesture the redirect exists to avoid, on a window that just changed
/// under us. It must refuse loudly and post NOTHING.
@Test
func open_whenTheOpenableAncestorVanishes_refusesInsteadOfClickingTheCell() async throws {
    let source = _MutableLookSource(elements: _finderElements(), rootID: 0)
    let actSource = _ActSource(_finderActElements())
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else {
        Issue.record("no frame")
        return
    }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    // The row is what the walk PROBES; it becomes an AXGroup immediately after,
    // so the RE-RESOLVE that the act performs sees a different element.
    let flipped = _Box(false)
    actSource.afterResolve = { path in
        guard path == [0, 0], !flipped.get() else { return }
        flipped.set(true)
        actSource.mutate { byPath in
            byPath[[0, 0]] = _ActElement(role: "AXGroup", title: nil, actions: [])
        }
    }
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(output["performed"] == .bool(false), "nothing may be performed: \(output)")
    #expect(output["fallback_reason"] == .string("openable_ancestor_drifted"))
    #expect(sink.mouse.isEmpty, "NO synthesized click on the filename cell: \(sink.mouse)")
    // Nothing was acted on, so nothing may CLAIM to have been.
    #expect(output["acted_on"] == nil, "a refusal must not report acted_on: \(output)")
    #expect(_object(output["attempted_on"] ?? .null)["role"] == .string("AXRow"))
}

private final class _Box: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Bool) { lock.lock(); value = new; lock.unlock() }
}

/// The same shape end to end: AXRow > AXCell(advertises AXOpen, refuses) >
/// AXTextField. The cell is asked to open, refuses, and the synthesized
/// double-click must land on the ROW — never back on the cell.
@Test
func open_whenAnAdvertisingCellRefuses_theClickLandsOnTheRowNotTheCell() async throws {
    let elements: [Int: _Element] = [
        400: _Element(
            attributes: MacAXAttributes(
                role: "AXTextField", title: ".agents", value: ".agents", actions: ["AXPress"]
            ),
            children: []
        ),
        40: _Element(
            attributes: MacAXAttributes(role: "AXCell", title: nil, actions: ["AXPress", "AXOpen"]),
            children: [400]
        ),
        4: _Element(attributes: MacAXAttributes(role: "AXRow", title: nil, actions: ["AXPress"]), children: [40]),
        3: _Element(attributes: MacAXAttributes(role: "AXOutline", title: nil), children: [4]),
        0: _Element(attributes: MacAXAttributes(role: "AXWindow", title: "home-folder"), children: [3]),
    ]
    let actElements: [[Int]: _ActElement] = [
        []: _ActElement(role: "AXWindow", title: "home-folder", actions: []),
        [0]: _ActElement(role: "AXOutline", title: nil, actions: []),
        [0, 0]: _ActElement(
            role: "AXRow", title: nil,
            frame: MacAXFrame(x: 0, y: 100, w: 400, h: 20), actions: ["AXPress"]
        ),
        [0, 0, 0]: _ActElement(
            role: "AXCell", title: nil,
            frame: MacAXFrame(x: 20, y: 100, w: 200, h: 20), actions: ["AXPress", "AXOpen"]
        ),
        [0, 0, 0, 0]: _ActElement(
            role: "AXTextField", title: ".agents", value: ".agents",
            frame: MacAXFrame(x: 24, y: 100, w: 100, h: 20), actions: ["AXPress"]
        ),
    ]
    let source = _MutableLookSource(elements: elements, rootID: 0)
    let actSource = _ActSource(actElements)
    actSource.refuseActions = ["AXOpen"]   // advertised, declined — like hers
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else {
        Issue.record("no frame: \(look)")
        return
    }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    if handle.isEmpty {
        Issue.record("look exposed: \(look["affordances"] ?? .null)")
        return
    }
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    let actedOn = _object(output["acted_on"] ?? .null)
    #expect(actedOn["role"] == .string("AXRow"), "the CLICK target must be the row: \(actedOn)")
    #expect(actedOn["path"] == .array([.int(0), .int(0)]))
    // The row's centre is y=110; the cell's centre is also y=110 but x=120 vs
    // the row's x=200. The click must be at the ROW's centre.
    #expect(sink.mouse.contains { $0.x == 200.0 },
            "the double-click must land at the ROW's centre, not the cell's: \(sink.mouse)")
    #expect(!sink.mouse.contains { $0.x == 120.0 },
            "nothing may be clicked at the cell's centre: \(sink.mouse)")
}

/// gpt-5.5 round-5 review, second pass SHOULD-FIX: the drifted branch was tested
/// and the VANISHED branch was not, while the response claimed both. This is the
/// row disappearing outright between the probe and the act.
@Test
func open_whenTheOpenableAncestorVanishesEntirely_refusesAndPostsNothing() async throws {
    let source = _MutableLookSource(elements: _finderElements(), rootID: 0)
    let actSource = _ActSource(_finderActElements())
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else {
        Issue.record("no frame")
        return
    }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    // The row RESOLVES for the walk, then ceases to exist before the act.
    let flipped = _Box(false)
    actSource.afterResolve = { path in
        guard path == [0, 0], !flipped.get() else { return }
        flipped.set(true)
        actSource.mutate { byPath in byPath[[0, 0]] = nil }
    }
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(output["performed"] == .bool(false), "nothing may be performed: \(output)")
    #expect(output["fallback_reason"] == .string("openable_ancestor_vanished"))
    #expect(sink.mouse.isEmpty, "NO synthesized click anywhere: \(sink.mouse)")
    #expect(output["acted_on"] == nil, "a refusal must not report acted_on: \(output)")
    #expect(output["attempted_on"] != nil, "but it must say what it was aiming at")
}

/// ROUND 6, the mechanism that actually navigates. Measured live: Finder's
/// filename field advertises AXOpen and returns kAXErrorActionUnsupported, and
/// a synthesized double-click is inert at both the row centre and the filename.
/// Selecting the row and pressing ⌘↓ opens the folder.
@Test
func open_inFinder_selectsTheRowAndPressesTheOpenCommand() async throws {
    let source = _MutableLookSource(elements: _finderElements(), rootID: 0, app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242))
    let actSource = _ActSource(_finderActElements())
    actSource.refuseActions = ["AXOpen"]   // advertised and unsupported, like the real thing
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(output["method"] == .string("select_and_open_command"), "\(output)")
    #expect(output["open_command"] == .string("cmd+down"))
    #expect(actSource.recordedCalls().contains { $0.hasPrefix("setSelected:") },
            "the row must be selected first: \(actSource.recordedCalls())")
    // The Open chord, not a click — the click is what was measured inert.
    #expect(sink.mouse.isEmpty, "no synthesized click may be posted: \(sink.mouse)")
    #expect(sink.keys.contains { $0.keyCode == 0x7D && $0.modifiers == .command },
            "cmd+down must be posted: \(sink.keys)")
}

/// Agent round 8, envelope 70DA30C4 — THE LYING RECEIPT.
///
/// `AXOpen` on a .json filename LAUNCHED Xcode and still returned a status
/// other than `.performed`, so the open path fell through to the chord branch.
/// The key-window re-read there saw XCODE — the window this act had just
/// opened — and returned `window_not_key, performed:false, method:none,
/// posted_events:0, status:failed`, while the same envelope carried
/// `AXWindowCreated` and the file was visibly on screen.
///
/// The rule this pins: AN AX ACTION'S RETURN STATUS IS NOT EVIDENCE THAT IT DID
/// NOTHING. Once an action has been delivered, a later focus change is evidence
/// of SUCCESS, and the envelope may never describe the call as having done
/// nothing. We still refuse to POST (an event into the new key window is never
/// what she asked for) — but that is a different sentence.
@Test
func openThatLaunchesAnotherApp_isNeverReportedAsNothingHappened() async throws {
    let source = _MutableLookSource(elements: _finderElements(), rootID: 0, app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242))
    let actSource = _ActSource(_finderActElements())
    // Advertised AND refused — exactly what Finder does, and exactly the case
    // where the action still had its effect.
    actSource.refuseActions = ["AXOpen"]
    let sink = _RecordingEventSink()
    // The act "launches Xcode": the front moves to another app DURING perform.
    actSource.afterPerform = { @Sendable action in
        guard action == "AXOpen" else { return }
        source.setFrontmostApp(
            MacAXAppInfo(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processIdentifier: 90210)
        )
    }
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXWindowCreated"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    // THE LIE, in the three forms she quoted:
    #expect(output["error"] != .string("window_not_key"),
            "a delivered AXOpen must not be reported as a pre-emission refusal: \(output)")
    #expect(output["status"] != .string("failed"), "\(output)")
    #expect(output["method"] != .string("none"), "\(output)")
    // …and the truth it must tell instead.
    #expect(output["performed"] == .bool(true))
    #expect(sink.keys.isEmpty, "still no event into the app that is key NOW: \(sink.keys)")
    // The envelope must NAME what was actually delivered. Serialize and look:
    // the record may ride the top level or inside `effect`, and which one it is
    // is not the point of this test.
    let serialized = String(
        data: (try? JSONValue.object(output).serializedData(pretty: false)) ?? Data(),
        encoding: .utf8
    ) ?? ""
    #expect(serialized.contains("actuations_attempted"),
            "the envelope must record the delivered action: \(serialized)")
    #expect(serialized.contains("AXOpen"))
}

/// Agent's ROUND-8 CONTRACT, ratified 2026-08-22 18:57Z: reusing a handle from
/// before an act is `stale_frame` — NOT `handle_drifted` — with ZERO input and an
/// immediate refusal. Her reasoning, adopted: the frame is superseded before any
/// resolution, so `handle_drifted` would be less truthful AND would add work
/// solely to manufacture a different label.
///
/// The existing tests already assert the ERROR STRING. What was never pinned is
/// the part that makes the refusal worth having: that it costs nothing and
/// touches nothing.
@Test
func staleHandleReuse_isStaleFrame_withZeroInputAndNoAXMutation() async throws {
    let source = _MutableLookSource(elements: _finderElements(), rootID: 0, app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242))
    let actSource = _ActSource(_finderActElements())
    actSource.refuseActions = ["AXOpen"]
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    // One real act mints a NEW frame; the handle above now belongs to a dead one.
    _ = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let before = actSource.recordedCalls().count
    let keysBefore = sink.keys.count
    let mouseBefore = sink.mouse.count

    let stale = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    #expect(!stale.ok)
    #expect(stale.error == "stale_frame", "ratified round-8 contract, not handle_drifted")
    #expect(sink.keys.count == keysBefore, "zero input: \(sink.keys)")
    #expect(sink.mouse.count == mouseBefore, "zero input: \(sink.mouse)")
    #expect(actSource.recordedCalls().count == before,
            "an immediate refusal touches no element at all")
    // The guidance rides whichever key this refusal family uses; what matters is
    // that it points at the act's own fresh frame rather than at another look.
    let serialized = String(
        data: (try? JSONValue.object(_object(stale.output)).serializedData(pretty: false)) ?? Data(),
        encoding: .utf8
    ) ?? ""
    #expect(serialized.contains("mac_act"),
            "the refusal must point at the act's own fresh frame_id: \(serialized)")
}

/// Agent round 7, envelope 173E1B08 — THE NON-KEY GATE, end to end.
///
/// The identical happy-path setup as the test above, with ONE difference: User
/// (or `mac_focus_app`) put another app in front between the look and the act.
/// The chord would have been delivered to THAT app by the window server. The
/// act must refuse before it selects anything and post nothing at all.
@Test
func open_whenAnotherAppIsFrontmost_postsNothingAndSelectsNothing() async throws {
    let source = _MutableLookSource(elements: _finderElements(), rootID: 0, app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242))
    let actSource = _ActSource(_finderActElements())
    actSource.refuseActions = ["AXOpen"]
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    // Chrome takes the front AFTER the look, exactly as in her run.
    source.setFrontmostApp(
        MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 71301)
    )
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(!result.ok)
    #expect(output["error"] == .string("window_not_key"), "\(output)")
    #expect(sink.keys.isEmpty, "NOTHING may be posted into the app that is actually key: \(sink.keys)")
    #expect(sink.mouse.isEmpty, "no clicks either: \(sink.mouse)")
    #expect(!actSource.recordedCalls().contains { $0.hasPrefix("setSelected:") },
            "the row must not even be SELECTED: \(actSource.recordedCalls())")
}

/// NEGATIVE CONTROL, reachable: an app with no measured Open chord must NOT
/// get an invented keystroke — it falls back to the old double-click path.
@Test
func open_inAnUnmeasuredApp_getsNoInventedKeystroke() async throws {
    let source = _MutableLookSource(elements: _finderElements(), rootID: 0, app: MacAXAppInfo(name: "Photos", bundleIdentifier: "com.apple.Photos", processIdentifier: 4242))
    let actSource = _ActSource(_finderActElements())
    actSource.refuseActions = ["AXOpen"]
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(output["method"] != .string("select_and_open_command"))
    #expect(sink.keys.isEmpty, "no chord may be invented for an unmeasured app: \(sink.keys)")
}

/// gpt-5.5 round-7 review, BLOCKING: an element with settable AXSelected but NO
/// openable ROW ancestor must never reach the chord — Cmd-Down would then open
/// whatever Finder happened to have selected, which is not what was named.
@Test
func open_inFinder_withNoRowAncestor_postsNoOpenCommand() async throws {
    // Same Finder identity, but the row is a plain group: no click candidate.
    var elements = _finderElements()
    elements[30] = _Element(
        attributes: MacAXAttributes(role: "AXGroup", title: nil, actions: []), children: [300]
    )
    var actElements = _finderActElements()
    actElements[[0, 0]] = _ActElement(role: "AXGroup", title: nil, actions: [])
    let source = _MutableLookSource(
        elements: elements, rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(actElements)
    actSource.refuseActions = ["AXOpen"]
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    #expect(_object(result.output)["method"] != .string("select_and_open_command"))
    #expect(sink.keys.isEmpty, "no row ⇒ no Open chord: \(sink.keys)")
}

/// …and when the source cannot select at all, the chord must not fire either.
@Test
func open_inFinder_whenSelectionIsUnsupported_postsNoOpenCommand() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderActElements())
    actSource.refuseActions = ["AXOpen"]
    actSource.selectSettable = false
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    _ = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    #expect(sink.keys.isEmpty, "selection refused ⇒ never press Open: \(sink.keys)")
}

/// ROUND 6 intent match, through the real path: the window really did move,
/// but to a destination this act did not name. Structural change is the floor,
/// not the verdict.
@Test
func act_open_thatRetitledToTheWrongPlace_isNotActed() async throws {
    let harness = _harness()
    let looked = try await _lookForHandle(harness, label: "Send")
    harness.source.mutate { elements, _, _ in
        elements[0]?.attributes = MacAXAttributes(role: "AXWindow", title: "Somewhere Else")
    }
    let result = try await harness.client.dispatch(
        action: "act",
        body: ["handle": .string(looked.handle), "frame_id": .string(looked.frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(output["status"] == .string("acted_unobserved"), "\(output)")
    #expect(output["status_reason"] == .string("navigation_intent_unmatched"))
    if case .string(let note)? = output["status_note"] {
        #expect(note.contains("Somewhere Else"), "the note must name what DID change: \(note)")
    } else {
        Issue.record("no status_note: \(output)")
    }
}

// MARK: - Verb-semantic `type`: editLandedInField (gpt-5.5 round-7 BLOCKING)

/// The false-success gpt-5.5 caught: a pre-existing substring satisfies
/// `contains` while the field goes UNTOUCHED. An unchanged read-back is not a
/// landed edit, whatever it happens to contain.
@Test("type: stale pre-existing text with an unchanged field is NOT a landed edit")
func editLandedRefusesStaleUnchangedContent() {
    #expect(MacActClosedLoop.editLandedInField(
        typed: "abc", valueBefore: "abc xyz", valueAfter: "abc xyz"
    ) == false)
    // Replace-mode retyping the field's exact current text is indistinguishable
    // from an inert field from here — conservative refusal is the contract.
    #expect(MacActClosedLoop.editLandedInField(
        typed: "abc", valueBefore: "abc", valueAfter: "abc"
    ) == false)
    // The value changed SOMEWHERE ELSE while a pre-existing occurrence sat
    // still: occurrence count did not grow, so nothing this act typed landed.
    #expect(MacActClosedLoop.editLandedInField(
        typed: "abc", valueBefore: "abc xyz", valueAfter: "abc xyz!"
    ) == false)
    // …but a genuine second occurrence IS the edit landing in a field that
    // already contained the text once.
    #expect(MacActClosedLoop.editLandedInField(
        typed: "abc", valueBefore: "abc xyz", valueAfter: "abc xyz abc"
    ) == true)
}

@Test("type: a changed read-back containing the text IS a landed edit — replace and append")
func editLandedAcceptsRealEdits() {
    // Replace mode: the field now reads exactly the text.
    #expect(MacActClosedLoop.editLandedInField(
        typed: "abc", valueBefore: "old", valueAfter: "abc"
    ) == true)
    // Append mode: the text landed at the end of what was already there.
    #expect(MacActClosedLoop.editLandedInField(
        typed: "abc", valueBefore: "z", valueAfter: "zabc"
    ) == true)
    // Unknown pre-act value (the view refused AXValue before the act):
    // `contains` stays the best available evidence, not a manufactured refusal.
    #expect(MacActClosedLoop.editLandedInField(
        typed: "abc", valueBefore: nil, valueAfter: "abc"
    ) == true)
}

@Test("type: unreadable or absent evidence is NOT CHECKABLE, never a verdict")
func editLandedNilMeansNotCheckable() {
    #expect(MacActClosedLoop.editLandedInField(
        typed: "abc", valueBefore: "x", valueAfter: nil
    ) == nil)
    #expect(MacActClosedLoop.editLandedInField(
        typed: "abc", valueBefore: "x", valueAfter: ""
    ) == nil)
    #expect(MacActClosedLoop.editLandedInField(
        typed: nil, valueBefore: "x", valueAfter: "x"
    ) == nil)
    #expect(MacActClosedLoop.editLandedInField(
        typed: "", valueBefore: "x", valueAfter: "x"
    ) == nil)
}

/// classify() wiring: the three editLandedInField outcomes must surface as the
/// three distinct verdicts — and the stale-content case must NOT ride a fired
/// notification to `acted`.
@Test("type: classify surfaces landed / not-in-field / unverifiable distinctly")
func classifyTypeVerdictWiring() {
    func verdict(_ before: String?, _ after: String?) -> MacActClosedLoop.ActClassification {
        MacActClosedLoop.classify(
            performedOK: true, verb: .type, notificationObserved: true,
            diff: nil, typedText: "abc", valueBefore: before, valueAfter: after
        )
    }
    #expect(verdict("old", "abc").status == "acted")
    let stale = verdict("abc xyz", "abc xyz")
    #expect(stale.status == "acted_unobserved")
    #expect(stale.reason == "edit_not_in_field")
    let masked = verdict(nil, nil)
    #expect(masked.status == "acted_unobserved")
    #expect(masked.reason == "edit_unverifiable")
    // No typedText supplied ⇒ nothing semantic to check ⇒ the pre-existing
    // notification licensing stands (the round-4/6 fence contract).
    #expect(MacActClosedLoop.classify(
        performedOK: true, verb: .type, notificationObserved: true, diff: nil
    ).status == "acted")
}

// MARK: - Raise, don't refuse (User, 2026-08-22: "a live screen with hands")

/// THE HOMEWORK TEST. Every round before this answered "your window isn't key"
/// by refusing and telling her to bring it forward and look again — bookkeeping
/// handed back to the caller for something the tool can do itself. Now `act`
/// RAISES that window and proceeds, and the caller never learns there was a
/// problem, because there wasn't one.
@Test func actRaisesTheFramesWindowInsteadOfHandingBackHomework() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderActElements())
    actSource.refuseActions = ["AXOpen"]
    // Raising really works here, and it really makes Finder frontmost again —
    // the fake models the WORLD changing, not just a return value.
    actSource.raiseOutcome = .performed
    actSource.onRaise = { [weak source] in
        source?.setFrontmostApp(
            MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
        )
    }
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    // Chrome steals the front after the look, exactly as in Agent's envelope.
    source.setFrontmostApp(
        MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 71301)
    )

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(actSource.recordedCalls().contains { $0.hasPrefix("raise:") },
            "the window must be RAISED, not refused: \(actSource.recordedCalls())")
    #expect(output["error"] != .string("window_not_key"),
            "raising made it key; there is nothing left to refuse: \(output)")
    #expect(sink.keys.count == 2, "the open chord fires once the window is key: \(sink.keys)")
}

/// …and the safety property survives a raise that DOESN'T take. This is the
/// half that matters: raising is an attempt, not a guarantee, and a failed
/// raise must leave the round-7/8 refusal exactly as Agent verified it.
@Test func aRaiseThatDoesNotTakeStillRefusesAndPostsNothing() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderActElements())
    actSource.refuseActions = ["AXOpen"]
    // The call is made and reports success, but the front does NOT move — the
    // window server refused, which it is entitled to do.
    actSource.raiseOutcome = .performed
    actSource.onRaise = nil
    let sink = _RecordingEventSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(".agents") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    source.setFrontmostApp(
        MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 71301)
    )

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(!result.ok)
    #expect(output["error"] == .string("window_not_key"), "\(output)")
    #expect(sink.keys.isEmpty, "nothing may be posted into the app that is actually key")
    #expect(sink.mouse.isEmpty)
    #expect(!actSource.recordedCalls().contains { $0.hasPrefix("setSelected:") },
            "the row must not even be selected: \(actSource.recordedCalls())")
    // And it must say it TRIED, so she is not told to do what the tool already did.
    if case .string(let note)? = output["guidance"] {
        #expect(note.contains("RAISE"), "the refusal must report the raise attempt: \(note)")
    }
}

// MARK: - Agent round 9, envelope 62D093EB — THE GATE WAS BELOW THE FIRST ACTUATION

/// Her live case, and the one shape every round-7/8 test missed: the handle SHE
/// NAMED advertises `AXOpen` itself. The Finder folder row `TargetFolder` did;
/// every fixture above hands `open` the filename CELL, which does not, so the
/// verb's very first line — `if target.actions.contains("AXOpen")` — was never
/// once executed by the suite that was supposed to be pinning this seam.
private func _finderRowOpensItselfActElements() -> [[Int]: _ActElement] {
    [
        []: _ActElement(role: "AXWindow", title: "window-a", actions: []),
        [0]: _ActElement(role: "AXOutline", title: nil, actions: []),
        [0, 0]: _ActElement(role: "AXRow", title: nil, actions: ["AXPress", "AXOpen"]),
        // THE DIFFERENCE: the labelled element she gets a handle for
        // advertises AXOpen — and, like the live one, refuses it while still
        // navigating.
        // (The LOOK fixture is `_finderElements()`, whose labelled row is
        // ".agents"; the label has to match or the drift guard refuses first.)
        [0, 0, 0]: _ActElement(
            role: "AXTextField", title: ".agents", value: ".agents",
            actions: ["AXPress", "AXOpen"]
        ),
    ]
}

private func _round9Client(
    _ source: _MutableLookSource,
    _ actSource: _ActSource,
    _ sink: _RecordingEventSink
) -> SwiftNativeMacControl {
    SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(script: ["AXRowCountChanged", "AXTitleChanged"]),
        lookFrameStore: MacLookFrameStore()
    )
}

private func _round9Handle(_ look: [String: JSONValue], label: String) -> String {
    for row in _array(look["affordances"]) where _object(row)["label"] == .string(label) {
        if case .string(let found)? = _object(row)["handle"] { return found }
    }
    return ""
}

/// THE ROUND-9 LIE, pinned. The window is key when the act starts, the handle's
/// own `AXOpen` is DELIVERED and navigates Finder into TargetFolder (title
/// change, 34 notifications, sentinel visible) while reporting a status other
/// than `.performed` — and because that first attempt sat OUTSIDE the actuation
/// ledger, the next gate call saw `didActuate == false` and returned
/// `ok:false, error:window_not_key, performed:false, posted_events:0` about an
/// act that had already happened. "Refuse means nothing acted" broken by the
/// tool's own effect.
@Test
func firstAXOpenOnTheNamedHandle_isLedgered_soALaterFrontChangeIsNotReportedAsNothingHappened() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderRowOpensItselfActElements())
    actSource.refuseActions = ["AXOpen"]
    let sink = _RecordingEventSink()
    // The open really happens, and the front moves BECAUSE of it.
    actSource.afterPerform = { @Sendable action in
        guard action == "AXOpen" else { return }
        source.setFrontmostApp(
            MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 71301)
        )
    }
    let client = _round9Client(source, actSource, sink)
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    let handle = _round9Handle(look, label: ".agents")
    #expect(!handle.isEmpty, "the look must surface the folder row: \(look["affordances"] ?? .null)")

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    // The attempt that Agent's effect proves happened:
    #expect(actSource.recordedCalls().contains("perform:AXOpen:[0, 0, 0]"),
            "the named handle's own AXOpen must be the first thing tried: \(actSource.recordedCalls())")
    // …and the three forms of the lie it must never be reported as.
    #expect(output["error"] != .string("window_not_key"),
            "a DELIVERED AXOpen may not be reported as a pre-emission refusal: \(output)")
    #expect(output["method"] != .string("none"), "\(output)")
    #expect(output["performed"] == .bool(true), "\(output)")
    #expect(sink.keys.isEmpty, "still nothing posted into the app that is key NOW: \(sink.keys)")
    #expect(sink.mouse.isEmpty, "and no click either: \(sink.mouse)")
    let serialized = String(
        data: (try? JSONValue.object(output).serializedData(pretty: false)) ?? Data(),
        encoding: .utf8
    ) ?? ""
    #expect(serialized.contains("actuations_attempted"),
            "the envelope must name what was delivered: \(serialized)")
    #expect(serialized.contains("AXOpen"))
}

/// The other half: the gate is now genuinely ABOVE the first actuation, so a
/// window that is not key and cannot be raised gets ZERO AX mutation — not "no
/// events posted, but an AXOpen delivered anyway". Before this fix the handle's
/// own AXOpen fired unconditionally, which is how a refused call could still
/// open a folder.
@Test
func openOnANonKeyWindow_deliversNoAXOpenAtAll() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderRowOpensItselfActElements())
    actSource.refuseActions = ["AXOpen"]
    // The raise is attempted and does not take — the branch that must still
    // refuse (and the only one where "nothing acted" is the truth).
    actSource.raiseOutcome = .performed
    actSource.onRaise = nil
    let sink = _RecordingEventSink()
    let client = _round9Client(source, actSource, sink)
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    let handle = _round9Handle(look, label: ".agents")
    source.setFrontmostApp(
        MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 71301)
    )

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(!result.ok)
    #expect(output["error"] == .string("window_not_key"), "\(output)")
    #expect(!actSource.recordedCalls().contains { $0.hasPrefix("perform:AXOpen:") },
            "a refusal must deliver NO AXOpen: \(actSource.recordedCalls())")
    #expect(sink.keys.isEmpty)
    #expect(sink.mouse.isEmpty)
}

/// Round 9, second finding — the refusal named the wrong window. Both call
/// sites in `performAct` built the verdict by hand and passed
/// `focusedWindowTitle: nil`, so EVERY wrong-window refusal she has ever
/// received said "key: untitled" regardless of what was actually key. Her
/// round-9 receipt says exactly that.
///
/// HONEST SCOPE: this pins the pure function's CONTRACT, and it passed before
/// the fix too — the defect was two call sites hardcoding `nil` into it, which
/// no unit test at this layer can catch. `performAct` now has exactly one
/// `liveKeyWindowRefusal()` builder and no hand-rolled call, which is the
/// structural half of the fix; this is the half that says what the answer has
/// to look like.
@Test
func wrongWindowRefusal_namesTheKeyWindow_neverUntitled() {
    let refusal = MacActClosedLoop.keyWindowRefusal(
        framePid: 612,
        frontmostPid: 612,
        frontmostName: "Finder",
        frameWindowHandle: 9,
        focusedWindowHandle: 3,
        frameWindowTitle: "window-a",
        focusedWindowTitle: "TargetFolder"
    )
    #expect(refusal?.reason == "window_not_key")
    #expect(refusal?.note.contains("TargetFolder") == true, "\(refusal?.note ?? "nil")")
    #expect(refusal?.note.contains("untitled") == false,
            "a placeholder where the key window's name belongs is not a refusal she can act on")
}

/// Round 9, third finding — the actuator's OWN synthesized-click fallback was
/// the one CGEvent emitter in `mac_act` the key-window gate never saw. A
/// `click` on a background window whose element advertises `AXPress` and
/// refuses it fell through to a click at those screen COORDINATES, delivered by
/// the window server to whatever was actually key.
@Test
func click_whoseAXPressRefuses_postsNoClickIntoTheAppThatIsKey() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderActElements())
    // Advertised and refused — the exact condition that reaches fallbackClick.
    actSource.refuseActions = ["AXPress"]
    actSource.raiseOutcome = .performed
    actSource.onRaise = nil
    let sink = _RecordingEventSink()
    let client = _round9Client(source, actSource, sink)
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    let handle = _round9Handle(look, label: ".agents")
    source.setFrontmostApp(
        MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 71301)
    )

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("click")]
    )
    let output = _object(result.output)
    #expect(sink.mouse.isEmpty,
            "the fallback click would have landed in Chrome at Finder's coordinates: \(sink.mouse)")
    // AXPress was ADVERTISED and refused, i.e. DELIVERED — round 8's rule
    // applies, so the honest envelope is "an AX action went out, no event was
    // posted", never a bare window_not_key claiming nothing happened.
    #expect(output["fallback_reason"] == .string("key_window_changed_after_actuation"), "\(output)")
    #expect(output["error"] != .string("window_not_key"), "\(output)")
}

/// NEGATIVE CONTROL for the gate above: with the frame's own window key, the
/// same refused AXPress still falls back to the click. The gate must stop input
/// going to the wrong place, not stop `click` from working.
@Test
func click_whoseAXPressRefuses_stillClicksWhenTheWindowIsKey() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderActElements())
    actSource.refuseActions = ["AXPress"]
    let sink = _RecordingEventSink()
    let client = _round9Client(source, actSource, sink)
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    let handle = _round9Handle(look, label: ".agents")

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("click")]
    )
    let output = _object(result.output)
    #expect(!sink.mouse.isEmpty, "the fallback click must still fire on a key window: \(output)")
    #expect(output["method"] == .string("cgevent_click_fallback"), "\(output)")
}

/// gpt-5.5 round-9 BLOCKING: the Open chord was gated BEFORE the selection and
/// then posted two statements later. Selecting a row moves focus; the emission
/// boundary is the post. With the front moving during `setSelected`, the chord
/// must not go out — and because the selection is in the ledger, the envelope
/// must report what it DID do rather than "nothing was posted".
@Test
func openChord_isGatedAtThePost_notMerelyBeforeTheSelection() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderActElements())
    actSource.refuseActions = ["AXOpen"]
    actSource.afterSetSelected = { @Sendable in
        source.setFrontmostApp(
            MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 71301)
        )
    }
    let sink = _RecordingEventSink()
    let client = _round9Client(source, actSource, sink)
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    let handle = _round9Handle(look, label: ".agents")

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("open")]
    )
    let output = _object(result.output)
    #expect(actSource.recordedCalls().contains { $0.hasPrefix("setSelected:") },
            "the selection has to happen for this gap to exist: \(actSource.recordedCalls())")
    #expect(sink.keys.isEmpty,
            "the Open chord would have gone to Chrome: \(sink.keys)")
    // …and the honest half: a mutation WAS delivered, so this is not a
    // "nothing happened" refusal.
    #expect(output["error"] != .string("window_not_key"), "\(output)")
    #expect(output["performed"] == .bool(true), "\(output)")
}

// MARK: - Agent round 9, envelope 7FCDC92E — ACTIVATION IS ASYNCHRONOUS

/// Her receipt was `method: cgevent_click_fallback`, which means the element
/// advertised NO action at all: an advertised-and-refused `AXPress` ledgers as
/// a delivered actuation, and the raise is deliberately skipped once anything
/// has been delivered. Only the no-action element reaches the raise-then-click
/// path where the activation race lives.
private func _finderCellWithNoActionsActElements() -> [[Int]: _ActElement] {
    [
        []: _ActElement(role: "AXWindow", title: "home-folder", actions: []),
        [0]: _ActElement(role: "AXOutline", title: nil, actions: []),
        [0, 0]: _ActElement(role: "AXRow", title: nil, actions: []),
        [0, 0, 0]: _ActElement(
            role: "AXTextField", title: ".agents", value: ".agents", actions: []
        ),
    ]
}

/// `raise` does AXRaise + `NSRunningApplication.activate()`, and `activate()`
/// returns true when the REQUEST is accepted. The gate re-read the frontmost
/// app on the next line, got the pre-activation answer or a stale-but-matching
/// one, cleared the entry refusal, and let a coordinate click go out while
/// Chrome still owned the screen: `ok:true, method:cgevent_click_fallback`,
/// and Agent's independent post-check found Chrome still frontmost with its
/// title and URL unchanged. `act` now WAITS for the world.
@Test
func raiseThatActivatesLate_isWaitedFor_andTheActLandsInTheRightApp() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderCellWithNoActionsActElements())
    actSource.raiseOutcome = .performed
    // The raise is accepted and the front flips only after several further
    // reads — which is what an app switch actually looks like.
    actSource.onRaise = { [weak source] in
        source?.setFrontmostAppAfterLag(
            MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242),
            afterReads: 3
        )
    }
    let sink = _RecordingEventSink()
    let client = _round9Client(source, actSource, sink)
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    let handle = _round9Handle(look, label: ".agents")
    source.setFrontmostApp(
        MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 71301)
    )

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("click")]
    )
    let output = _object(result.output)
    #expect(actSource.recordedCalls().contains { $0.hasPrefix("raise:") }, "\(actSource.recordedCalls())")
    // The wait pays off: by the time the gate answers, Finder really IS front,
    // so the click is legitimate and goes out.
    #expect(!sink.mouse.isEmpty, "the click must fire once activation has actually settled: \(output)")
    #expect(output["method"] == .string("cgevent_click_fallback"), "\(output)")
}

/// The half that matters more: an activation request that is NEVER honoured
/// must time out and refuse, with nothing posted. Before the wait this case and
/// the one above were indistinguishable — both "activate() said true".
@Test
func raiseThatNeverActivates_timesOutAndPostsNothing() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderCellWithNoActionsActElements())
    actSource.raiseOutcome = .performed
    // Accepted, never honoured: the front stays Chrome for the whole budget.
    actSource.onRaise = nil
    let sink = _RecordingEventSink()
    let client = _round9Client(source, actSource, sink)
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    let handle = _round9Handle(look, label: ".agents")
    source.setFrontmostApp(
        MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 71301)
    )

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("click")]
    )
    let output = _object(result.output)
    #expect(sink.mouse.isEmpty, "no coordinate click may go out into Chrome: \(sink.mouse)")
    #expect(sink.keys.isEmpty)
    // Nothing was delivered here — no AX action was even advertised — so this
    // is a genuine refusal and must say so.
    #expect(output["error"] == .string("window_not_key"), "\(output)")
}

/// AGENT'S ACTUAL 7FCDC92E SHAPE. `activate()` is accepted, the workspace
/// answers optimistically with Finder for one read, and the switch never
/// happens — Chrome keeps the screen. One matching read is not evidence: the
/// answer has to HOLD. Otherwise `ok:true, method:cgevent_click_fallback` for a
/// click Finder never saw, which is exactly what her post-check found.
@Test
func optimisticFrontmostReadAfterRaise_doesNotLicenseTheClick() async throws {
    let source = _MutableLookSource(
        elements: _finderElements(), rootID: 0,
        app: MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242)
    )
    let actSource = _ActSource(_finderCellWithNoActionsActElements())
    actSource.raiseOutcome = .performed
    actSource.onRaise = { [weak source] in
        source?.setOptimisticFrontmostApp(
            MacAXAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 4242),
            forReads: 1
        )
    }
    let sink = _RecordingEventSink()
    let client = _round9Client(source, actSource, sink)
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else { Issue.record("no frame"); return }
    let handle = _round9Handle(look, label: ".agents")
    source.setFrontmostApp(
        MacAXAppInfo(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 71301)
    )

    let result = try await client.dispatch(
        action: "act",
        body: ["handle": .string(handle), "frame_id": .string(frameId), "verb": .string("click")]
    )
    let output = _object(result.output)
    #expect(sink.mouse.isEmpty,
            "a single optimistic read must not license a coordinate click into Chrome: \(sink.mouse)")
    #expect(output["method"] != .string("cgevent_click_fallback"), "\(output)")
    #expect(output["error"] == .string("window_not_key"), "\(output)")
}

/// ROUND 9, FOURTH FINDING — "CANNOT TELL" WAS A PASS.
///
/// The wrong-window guard is asserted only when BOTH window handles are known,
/// on the reasoning that "a source that cannot name its focused window has told
/// us nothing, and silence is not a mismatch." True — but silence is not a
/// MATCH either, and the function fell through to `nil`, i.e. to "post the
/// event." With one window that is harmless (the app being frontmost already
/// proves it); with several it is precisely the multi-window Finder hole the
/// second guard was added to close, reopened from the other side.
@Test
func unnamedKeyWindow_isARefusalWhenTheAppHasSeveral_andAPassWhenItHasOne() {
    let cannotTell = MacActClosedLoop.keyWindowRefusal(
        framePid: 612,
        frontmostPid: 612,
        frontmostName: "Finder",
        frameWindowHandle: 9,
        focusedWindowHandle: nil,
        frameWindowTitle: "window-a",
        focusedWindowTitle: nil,
        appWindowCount: 6
    )
    #expect(cannotTell?.reason == "key_window_unknown", "\(String(describing: cannotTell))")
    #expect(cannotTell?.note.contains("window-a") == true, "\(cannotTell?.note ?? "nil")")

    let onlyWindow = MacActClosedLoop.keyWindowRefusal(
        framePid: 612,
        frontmostPid: 612,
        frontmostName: "Finder",
        frameWindowHandle: 9,
        focusedWindowHandle: nil,
        frameWindowTitle: "window-a",
        focusedWindowTitle: nil,
        appWindowCount: 1
    )
    #expect(onlyWindow == nil, "one window and the app is frontmost — that window IS key")

    // Unasked stays unasked: a caller that does not supply the count keeps the
    // old tolerance rather than silently starting to refuse.
    let uncounted = MacActClosedLoop.keyWindowRefusal(
        framePid: 612,
        frontmostPid: 612,
        frontmostName: "Finder",
        frameWindowHandle: 9,
        focusedWindowHandle: nil,
        frameWindowTitle: "window-a",
        focusedWindowTitle: nil
    )
    #expect(uncounted == nil)
}

/// The pass side of the SAME guard, and the reason the live source now mints
/// one handle per element. Equal handles must mean "this IS the key window" —
/// if that can never be true the guard is not a guard, it is a permanent
/// refusal, and `windows(pid:)`/`focusedWindow(pid:)` handing out a fresh
/// integer for one window made it exactly that.
@Test
func matchingWindowHandles_areAPass_notARefusal() {
    #expect(MacActClosedLoop.keyWindowRefusal(
        framePid: 612,
        frontmostPid: 612,
        frontmostName: "Finder",
        frameWindowHandle: 9,
        focusedWindowHandle: 9,
        frameWindowTitle: "window-a",
        focusedWindowTitle: "window-a"
    ) == nil)
}

// MARK: - Sweep item 8: SECURE KEYBOARD ENTRY
//
// Two different silences, one symptom. While macOS secure input is on the
// window server drops every synthesized keystroke without telling anyone, so
// the closed loop reported "the fresh screen did not visibly change" and never
// named the cause. And `AXSecureTextField` sat in `typeableRoles`, so `type`
// aimed at a password box was an ordinary act.

private func _guidance(_ output: [String: JSONValue]) -> String {
    if case .string(let text)? = output["guidance"] { return text }
    return ""
}

/// Records what it was asked to post AND reports secure input on, which is the
/// only combination that can prove "refused, and nothing went out".
private final class _SecureInputSink: MacEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [MacKeyEvent] = []
    var isAvailable: Bool { true }
    var secureKeyboardEntryActive: Bool { true }
    var keys: [MacKeyEvent] { lock.lock(); defer { lock.unlock() }; return _keys }
    func post(key: MacKeyEvent) { lock.lock(); _keys.append(key); lock.unlock() }
    func post(mouse: MacMouseEvent) {}
    func post(scroll: MacScrollEvent) {}
}

@Test
func secureInputRefusal_namesTheCauseInWords_andOnlyWhenItIsActuallyOn() {
    #expect(MacActClosedLoop.secureInputRefusal(active: false) == nil,
            "secure input off is not a refusal — this must never become a standing block")
    let refusal = MacActClosedLoop.secureInputRefusal(active: true)
    #expect(refusal?.reason == MacActClosedLoop.secureInputReason)
    #expect(refusal?.note.contains("secure keyboard entry") == true,
            "the refusal has to say the cause, not just fail: \(refusal?.note ?? "nil")")
    #expect(refusal?.note.contains("would go nowhere") == true)
}

@Test
func secureFieldRefusal_firesOnPasswordFieldsOnly_andTypeStillKnowsTheRole() {
    #expect(MacActClosedLoop.secureFieldRefusal(role: "AXTextField") == nil)
    #expect(MacActClosedLoop.secureFieldRefusal(role: "AXSecureTextField")?.reason
            == MacActClosedLoop.secureFieldReason)
    #expect(MacActClosedLoop.secureFieldRefusal(role: "AXSecureTextField")?
        .note.contains("password field") == true)
    // The role stays TYPEABLE on purpose: a password box must get its own
    // named refusal, not the generic `verb_not_supported_on_element` shrug the
    // buttons get.
    #expect(MacActClosedLoop.canType(role: "AXSecureTextField"))
}

@Test
func type_refusesAPasswordField_byName_andTouchesNothing() async throws {
    var elements = _composeElements()
    elements[12] = _Element(
        attributes: MacAXAttributes(role: "AXSecureTextField", title: "Password", value: "•••"),
        children: []
    )
    elements[0] = _Element(
        attributes: MacAXAttributes(role: "AXWindow", title: "Lunch tomorrow"),
        children: [10, 11, 12]
    )
    let source = _MutableLookSource(elements: elements, rootID: 0)
    var actElements = _composeActElements()
    actElements[[2]] = _ActElement(role: "AXSecureTextField", title: "Password", value: "•••")
    let actSource = _ActSource(actElements)
    let sink = _SecureInputSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else {
        Issue.record("no frame")
        return
    }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string("Password") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    #expect(!handle.isEmpty, "a login sheet's one control must be visible to a look")
    let result = try await client.dispatch(
        action: "act",
        body: [
            "handle": .string(handle),
            "frame_id": .string(frameId),
            "verb": .string("type"),
            "text": .string("hunter2"),
        ]
    )
    #expect(!result.ok)
    #expect(result.error == MacActClosedLoop.secureFieldReason)
    let output = _object(result.output)
    #expect(_guidance(output).contains("password field"),
            "an honest reason, not a mechanism shrug: \(output["guidance"] ?? .null)")
    let calls = actSource.recordedCalls()
    #expect(!calls.contains { $0.hasPrefix("setValue:") },
            "AXSetValue would have filled the credential box: \(calls)")
    #expect(!calls.contains { $0.hasPrefix("setFocused:") }, "\(calls)")
    #expect(sink.keys.isEmpty, "nothing may be posted")
    let serialized = String(data: try result.output.serializedData(pretty: false), encoding: .utf8) ?? ""
    #expect(!serialized.contains("hunter2"))
}

@Test
func type_refusesWhenSecureInputIsOn_andPostsNothing() async throws {
    let source = _MutableLookSource(elements: _composeElements(), rootID: 0)
    let actSource = _ActSource(_composeActElements())
    // An editable field whose AXValue is not settable, so the verb reaches the
    // keystroke fallback — the branch secure input actually eats.
    actSource.valueSettable = false
    let sink = _SecureInputSink()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: sink,
        accessibilityActSource: actSource,
        effectObserverSource: _EffectSource(),
        lookFrameStore: MacLookFrameStore()
    )
    let look = _object(try await client.dispatch(action: "look", body: [:]).output)
    guard case .string(let frameId)? = look["frame_id"] else {
        Issue.record("no frame")
        return
    }
    var handle = ""
    for row in _array(look["affordances"]) where _object(row)["label"] == .string("Subject") {
        if case .string(let found)? = _object(row)["handle"] { handle = found }
    }
    let result = try await client.dispatch(
        action: "act",
        body: [
            "handle": .string(handle),
            "frame_id": .string(frameId),
            "verb": .string("type"),
            "text": .string("abc"),
        ]
    )
    #expect(!result.ok)
    #expect(result.error == MacActClosedLoop.secureInputReason)
    let output = _object(result.output)
    #expect(output["method"] == .string("none"))
    #expect(_guidance(output).contains("secure keyboard entry"),
            "\(output["guidance"] ?? .null)")
    #expect(sink.keys.isEmpty,
            "the whole point: not one character goes out into a void")
}
