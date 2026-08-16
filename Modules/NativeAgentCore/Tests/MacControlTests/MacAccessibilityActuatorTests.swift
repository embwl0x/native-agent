import Foundation
import Testing
@testable import MacControl
import NativeAgentCore

/// W2 + W3 — the INJECTION organ.
///
/// HERMETICITY / SAFETY: every test here drives a `_RecordingEventSink` and a
/// `_FakeAXActSource`. No test in this file can move the real mouse, press a
/// real key, or touch a real AXUIElement — the production `CGEventSink` and
/// `SystemMacAXActSource` are never constructed. That is the whole reason the
/// sink and the act source are protocols.

// MARK: - Fakes

final class _RecordingEventSink: MacEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [MacKeyEvent] = []
    private var _mouse: [MacMouseEvent] = []
    private var _scroll: [MacScrollEvent] = []
    let available: Bool

    init(available: Bool = true) { self.available = available }

    var isAvailable: Bool { available }

    var keys: [MacKeyEvent] { lock.lock(); defer { lock.unlock() }; return _keys }
    var mouse: [MacMouseEvent] { lock.lock(); defer { lock.unlock() }; return _mouse }
    var scrolls: [MacScrollEvent] { lock.lock(); defer { lock.unlock() }; return _scroll }

    func post(key: MacKeyEvent) { lock.lock(); _keys.append(key); lock.unlock() }
    func post(mouse: MacMouseEvent) { lock.lock(); _mouse.append(mouse); lock.unlock() }
    func post(scroll: MacScrollEvent) { lock.lock(); _scroll.append(scroll); lock.unlock() }
}

/// A synthetic AX tree addressed by child-index path, mirroring what the real
/// window server would hand back.
final class _FakeAXActNode {
    var role: String
    var title: String?
    var value: String?
    var enabled: Bool
    var frame: MacAXFrame?
    var actions: [String]
    var settable: Bool
    var children: [_FakeAXActNode]
    /// Recorded so a test can prove the app's own handler was the thing invoked.
    var performed: [String] = []

    init(
        role: String,
        title: String? = nil,
        value: String? = nil,
        enabled: Bool = true,
        frame: MacAXFrame? = nil,
        actions: [String] = [],
        settable: Bool = false,
        children: [_FakeAXActNode] = []
    ) {
        self.role = role
        self.title = title
        self.value = value
        self.enabled = enabled
        self.frame = frame
        self.actions = actions
        self.settable = settable
        self.children = children
    }
}

final class _FakeAXActSource: MacAXActSource, @unchecked Sendable {
    private let lock = NSLock()
    let root: _FakeAXActNode?
    let trusted: Bool
    private var table: [Int: _FakeAXActNode] = [:]
    private var nextID = 0
    /// Every action the source was ASKED to perform, in order — including ones
    /// it refused, so a test can distinguish "not attempted" from "refused".
    private(set) var attempted: [String] = []

    init(root: _FakeAXActNode?, trusted: Bool = true) {
        self.root = root
        self.trusted = trusted
    }

    func isTrusted() -> Bool { trusted }

    private func target(for node: _FakeAXActNode, reusing handle: Int? = nil) -> MacAXActTarget {
        lock.lock()
        let id: Int
        if let handle {
            id = handle
        } else {
            nextID += 1
            id = nextID
            table[id] = node
        }
        lock.unlock()
        return MacAXActTarget(
            handle: id,
            role: node.role,
            title: node.title,
            value: node.value,
            enabled: node.enabled,
            frame: node.frame,
            actions: node.actions
        )
    }

    private func node(_ handle: Int) -> _FakeAXActNode? {
        lock.lock(); defer { lock.unlock() }
        return table[handle]
    }

    func resolve(path: [Int]) -> MacAXActTarget? {
        guard var current = root else { return nil }
        for index in path {
            guard index >= 0, index < current.children.count else { return nil }
            current = current.children[index]
        }
        return target(for: current)
    }

    func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome {
        lock.lock(); attempted.append("perform:\(action)"); lock.unlock()
        guard let node = node(target.handle) else { return .invalidTarget }
        guard node.actions.contains(action) else { return .unsupported }
        guard node.enabled else { return .failed }
        node.performed.append(action)
        // A press on this fake toggles the value, so a test can SEE the
        // post-state differ from the pre-state.
        if action == "AXPress" { node.value = "pressed" }
        return .performed
    }

    func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome {
        lock.lock(); attempted.append("setValue"); lock.unlock()
        guard let node = node(target.handle) else { return .invalidTarget }
        guard node.settable else { return .unsupported }
        node.value = value
        return .performed
    }

    func reread(_ target: MacAXActTarget) -> MacAXActTarget? {
        guard let node = node(target.handle) else { return nil }
        return self.target(for: node, reusing: target.handle)
    }
}

// MARK: - Key syntax: literals, chords, modifiers, named keys, raw codes

@Test func keySyntaxParsesASingleNamedKey() throws {
    let chords = try MacKeySyntax.parseChords("return")
    #expect(chords.count == 1)
    #expect(chords[0].keyCode == 36)
    #expect(chords[0].modifiers == [])
}

@Test func keySyntaxParsesEveryModifierSpelling() throws {
    for (spelling, expected) in [
        ("cmd+a", MacKeyModifiers.command), ("command+a", .command),
        ("meta+a", .command), ("super+a", .command),
        ("shift+a", .shift),
        ("opt+a", .option), ("option+a", .option), ("alt+a", .option),
        ("ctrl+a", .control), ("control+a", .control),
        ("fn+a", .function), ("function+a", .function),
    ] {
        let chords = try MacKeySyntax.parseChords(spelling)
        #expect(chords.count == 1, "\(spelling)")
        #expect(chords[0].modifiers == expected, "\(spelling) → \(chords[0].modifiers.slugs)")
        #expect(chords[0].keyCode == 0, "\(spelling) key is 'a' = keycode 0")
    }
}

@Test func keySyntaxParsesAMultiModifierCombo() throws {
    let chords = try MacKeySyntax.parseChords("cmd+shift+4")
    #expect(chords.count == 1)
    #expect(chords[0].modifiers == [.command, .shift])
    #expect(chords[0].keyCode == 21, "'4' is virtual keycode 21")
    #expect(chords[0].modifiers.slugs == ["cmd", "shift"])
}

@Test func keySyntaxParsesAChordSEQUENCE() throws {
    let chords = try MacKeySyntax.parseChords("cmd+a cmd+c escape")
    #expect(chords.count == 3)
    #expect(chords.map(\.keyCode) == [0, 8, 53])
    #expect(chords.map(\.modifiers) == [.command, .command, []])
}

@Test func keySyntaxUppercaseLetterImpliesShift() throws {
    let lower = try MacKeySyntax.parseChords("a")[0]
    let upper = try MacKeySyntax.parseChords("A")[0]
    #expect(lower.keyCode == upper.keyCode, "same physical key")
    #expect(lower.modifiers == [])
    #expect(upper.modifiers == .shift, "an uppercase letter is shift + the key")
}

@Test func keySyntaxShiftedGlyphsResolveToTheirBaseKeyPlusShift() throws {
    for (glyph, baseCode) in [("!", UInt16(18)), ("?", 44), (":", 41), ("~", 50), ("_", 27)] {
        let chord = try MacKeySyntax.parseChords(glyph)[0]
        #expect(chord.keyCode == baseCode, "\(glyph)")
        #expect(chord.modifiers == .shift, "\(glyph) needs shift")
    }
}

@Test func keySyntaxAcceptsBareAndNamedPlus() throws {
    // "+" as a chord on its own is the plus KEY, not a dangling separator.
    let bare = try MacKeySyntax.parseChords("+")[0]
    let named = try MacKeySyntax.parseChords("plus")[0]
    #expect(bare.keyCode == 24 && bare.modifiers == .shift)
    #expect(named.keyCode == 24 && named.modifiers == .shift)
    // And it composes as a chord key.
    let combo = try MacKeySyntax.parseChords("cmd+plus")[0]
    #expect(combo.modifiers == [.command, .shift])
}

@Test func keySyntaxAcceptsRawKeyCodeEscapeHatch() throws {
    #expect(try MacKeySyntax.parseChords("key:96")[0].keyCode == 96)
    #expect(try MacKeySyntax.parseChords("code:0")[0].keyCode == 0)
    #expect(try MacKeySyntax.parseChords("cmd+key:127")[0].modifiers == .command)
}

@Test func keySyntaxCoversTheWholeNamedKeyTable() throws {
    // Exhaustive: every advertised name must parse. A name in the schema copy
    // that the parser rejects is an advertised-capability lie.
    let names = [
        "return", "enter", "tab", "space", "delete", "backspace", "escape", "esc",
        "forward_delete", "del", "home", "end", "pageup", "pagedown",
        "up", "down", "left", "right", "capslock", "help",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10",
        "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20",
    ]
    for name in names {
        let chords = try MacKeySyntax.parseChords(name)
        #expect(chords.count == 1, "\(name) must parse to exactly one chord")
    }
    // Case-insensitive.
    #expect(try MacKeySyntax.parseChords("RETURN")[0].keyCode == 36)
}

// MARK: - Key syntax: malformed input is REFUSED, never partially executed

@Test func keySyntaxRejectsEmptyInput() {
    #expect(throws: MacKeySyntaxError.empty) { _ = try MacKeySyntax.parseChords("") }
    #expect(throws: MacKeySyntaxError.empty) { _ = try MacKeySyntax.parseChords("   \n ") }
}

@Test func keySyntaxRejectsDanglingSeparators() {
    for bad in ["cmd+", "+a", "cmd++a", "shift+cmd+"] {
        #expect(throws: (any Error).self, "\(bad) must not parse") {
            _ = try MacKeySyntax.parseChords(bad)
        }
    }
}

@Test func keySyntaxRejectsUnknownModifiersAndKeys() {
    #expect(throws: MacKeySyntaxError.unknownModifier("hyper", chord: "hyper+a")) {
        _ = try MacKeySyntax.parseChords("hyper+a")
    }
    #expect(throws: MacKeySyntaxError.unknownKey("bogus", chord: "bogus")) {
        _ = try MacKeySyntax.parseChords("bogus")
    }
    // A multi-character token is a NAME lookup, not a per-character type-out.
    #expect(throws: (any Error).self) { _ = try MacKeySyntax.parseChords("hello") }
}

@Test func keySyntaxRejectsOutOfRangeKeyCodes() {
    for bad in ["key:128", "key:-1", "key:abc", "code:99999"] {
        #expect(throws: (any Error).self, "\(bad)") { _ = try MacKeySyntax.parseChords(bad) }
    }
}

@Test func keySyntaxEnforcesTheChordCap() {
    let spec = Array(repeating: "a", count: MacKeySyntax.maxChords + 1).joined(separator: " ")
    #expect(throws: (any Error).self) { _ = try MacKeySyntax.parseChords(spec) }
}

@Test func keySyntaxEnforcesTheTextCap() {
    #expect(throws: (any Error).self) {
        _ = try MacKeySyntax.validateText(String(repeating: "x", count: MacKeySyntax.maxTextCharacters + 1))
    }
    #expect(throws: MacKeySyntaxError.empty) { _ = try MacKeySyntax.validateText("") }
}

// MARK: - Event construction against the fake sink

@Test func typeTextEmitsAUnicodeDownUpPairPerCharacter() {
    let events = MacEventPlanner.typeText("héllo")
    #expect(events.count == 10, "5 characters × down+up")
    #expect(events.map(\.down) == [true, false, true, false, true, false, true, false, true, false])
    #expect(events.compactMap(\.unicodeText) == ["h", "h", "é", "é", "l", "l", "l", "l", "o", "o"])
    // Literal typing must not carry modifier flags — that is what turns
    // typing "s" into cmd+S.
    #expect(events.allSatisfy { $0.modifiers == [] })
}

@Test func chordEmitsDownThenUpWithFlagsOnBOTHEvents() throws {
    let chord = try MacKeySyntax.parseChords("cmd+shift+4")[0]
    let events = MacEventPlanner.chord(chord)
    #expect(events.count == 2)
    #expect(events[0].down == true && events[1].down == false)
    #expect(events[0].keyCode == 21 && events[1].keyCode == 21)
    // A missing flag on keyUp leaves modifier-tracking apps believing the
    // modifier is still held down.
    #expect(events[0].modifiers == [.command, .shift])
    #expect(events[1].modifiers == [.command, .shift])
    #expect(events.allSatisfy { $0.unicodeText == nil })
}

@Test func clickPlanIsMoveThenDownThenUp() {
    let events = MacEventPlanner.click(x: 100, y: 250, button: .left, count: 1)
    #expect(events.map(\.phase) == [.move, .down, .up])
    #expect(events.allSatisfy { $0.x == 100 && $0.y == 250 })
    #expect(events.allSatisfy { $0.button == .left })
}

@Test func doubleClickPlanCarriesAnIncrementingClickState() {
    let events = MacEventPlanner.click(x: 10, y: 20, button: .left, count: 2)
    #expect(events.map(\.phase) == [.move, .down, .up, .down, .up])
    // clickState 1 then 2 is what makes the second pair a DOUBLE-click rather
    // than two unrelated clicks.
    #expect(events.filter { $0.phase == .down }.map(\.clickCount) == [1, 2])
}

@Test func rightClickPlanUsesTheRightButton() {
    let events = MacEventPlanner.click(x: 5, y: 6, button: .right, count: 1)
    #expect(events.filter { $0.phase != .move }.allSatisfy { $0.button == .right })
}

@Test func dragPlanIsMovePressDragRelease() {
    let events = MacEventPlanner.drag(fromX: 1, fromY: 2, toX: 30, toY: 40, button: .left)
    #expect(events.map(\.phase) == [.move, .down, .drag, .up])
    #expect(events[0].x == 1 && events[0].y == 2)
    #expect(events[1].x == 1 && events[1].y == 2)
    #expect(events[2].x == 30 && events[2].y == 40)
    #expect(events[3].x == 30 && events[3].y == 40)
}

@Test func smoothDragInterpolatesLocallyAndEndsExactlyAtTheTarget() {
    let events = MacEventPlanner.smoothDrag(
        fromX: 10,
        fromY: 20,
        toX: 110,
        toY: 220,
        button: .left,
        steps: 5
    )
    #expect(events.count == 8)
    #expect(events.prefix(2).map(\.phase) == [.move, .down])
    #expect(events.dropFirst(2).dropLast().allSatisfy { $0.phase == .drag })
    #expect(events[2].x == 30 && events[2].y == 60)
    #expect(events.last?.phase == .up)
    #expect(events.last?.x == 110 && events.last?.y == 220)
}

@Test func clickCountIsClampedToThree() {
    let events = MacEventPlanner.click(x: 0, y: 0, button: .left, count: 99)
    #expect(events.filter { $0.phase == .down }.count == 3)
}

// MARK: - ax_act semantics

private func _buttonTree() -> _FakeAXActNode {
    _FakeAXActNode(
        role: "AXWindow",
        title: "Compose",
        frame: MacAXFrame(x: 0, y: 0, w: 800, h: 600),
        children: [
            _FakeAXActNode(
                role: "AXTextField",
                title: "Body",
                value: "",
                frame: MacAXFrame(x: 10, y: 40, w: 400, h: 200),
                actions: [],
                settable: true
            ),
            _FakeAXActNode(
                role: "AXButton",
                title: "Send",
                frame: MacAXFrame(x: 600, y: 500, w: 100, h: 40),
                actions: ["AXPress", "AXShowMenu"]
            ),
            // Decorative: advertises nothing and has a frame → fallback target.
            _FakeAXActNode(
                role: "AXImage",
                title: "Logo",
                frame: MacAXFrame(x: 20, y: 20, w: 60, h: 60),
                actions: []
            ),
            // Pathological: no actions AND no frame → must fail honestly.
            _FakeAXActNode(role: "AXGroup", title: "Invisible", frame: nil, actions: []),
        ]
    )
}

@Test func axActResolvesThePathAndPerformsTheAdvertisedAction() throws {
    let tree = _buttonTree()
    let source = _FakeAXActSource(root: tree)
    let sink = _RecordingEventSink()

    let outcome = MacAccessibilityActuator.act(
        source: source, sink: sink, path: [1], action: nil, value: nil
    )
    let result = try #require(try? outcome.get())
    #expect(result.ok)
    #expect(result.method == "ax_action")
    #expect(result.requestedAction == "AXPress", "AXPress is the default action")
    #expect(result.target.title == "Send", "path [1] must resolve to the Send button, not the text field")
    // The APP's handler ran…
    #expect(tree.children[1].performed == ["AXPress"])
    // …and NO synthesized event was emitted. That is the whole point of the
    // semantic path.
    #expect(sink.mouse.isEmpty)
    #expect(sink.keys.isEmpty)
}

@Test func axActPerformsANonDefaultAdvertisedAction() throws {
    let tree = _buttonTree()
    let source = _FakeAXActSource(root: tree)
    let result = try #require(try? MacAccessibilityActuator.act(
        source: source, sink: _RecordingEventSink(), path: [1], action: "AXShowMenu", value: nil
    ).get())
    #expect(result.ok && result.method == "ax_action")
    #expect(tree.children[1].performed == ["AXShowMenu"])
}

@Test func axActReturnsThePostStateSoTheCallerCanConfirm() throws {
    let tree = _buttonTree()
    let source = _FakeAXActSource(root: tree)
    let result = try #require(try? MacAccessibilityActuator.act(
        source: source, sink: _RecordingEventSink(), path: [1], action: nil, value: nil
    ).get())
    #expect(result.target.value == nil, "pre-state, captured before the act")
    #expect(result.postState?.value == "pressed", "post-state is a FRESH read after the act")
}

@Test func axActSetsAValueOnASettableElement() throws {
    let tree = _buttonTree()
    let source = _FakeAXActSource(root: tree)
    let sink = _RecordingEventSink()
    let result = try #require(try? MacAccessibilityActuator.act(
        source: source, sink: sink, path: [0], action: nil, value: "hello world"
    ).get())
    #expect(result.ok)
    #expect(result.method == "ax_set_value")
    #expect(result.requestedAction == "AXSetValue")
    #expect(tree.children[0].value == "hello world")
    #expect(result.postState?.value == "hello world")
    #expect(sink.keys.isEmpty, "AXSetValue must not fall back to typing 11 keystrokes")
}

@Test func axActRefusesRatherThanClickingWhenAValueSetIsUnsupported() throws {
    // The Send BUTTON is not settable. A value request that cannot be honored
    // must fail — clicking instead would be a different effect than asked for.
    let tree = _buttonTree()
    let source = _FakeAXActSource(root: tree)
    let sink = _RecordingEventSink()
    let result = try #require(try? MacAccessibilityActuator.act(
        source: source, sink: sink, path: [1], action: nil, value: "nope"
    ).get())
    #expect(!result.ok)
    #expect(result.method == "none")
    #expect(result.error == "ax_set_value_unsupported")
    #expect(sink.mouse.isEmpty, "a refused set-value must NOT degrade into a click")
    #expect(tree.children[1].performed.isEmpty)
}

@Test func axActFallsBackToAFrameCentreClickWhenNoAXActionExists() throws {
    let tree = _buttonTree()
    let source = _FakeAXActSource(root: tree)
    let sink = _RecordingEventSink()
    // path [2] is the decorative image: frame 20,20 60×60 → centre 50,50.
    let result = try #require(try? MacAccessibilityActuator.act(
        source: source, sink: sink, path: [2], action: nil, value: nil
    ).get())
    #expect(result.ok)
    #expect(result.method == "cgevent_click_fallback", "the caller must be able to tell which mechanism fired")
    #expect(result.fallbackReason == "element_does_not_advertise_AXPress")
    #expect(sink.mouse.map(\.phase) == [.move, .down, .up])
    #expect(sink.mouse.allSatisfy { $0.x == 50 && $0.y == 50 }, "click lands at the element's frame CENTRE")
}

@Test func axActFailsHonestlyWithNeitherAnActionNorAFrame() throws {
    let source = _FakeAXActSource(root: _buttonTree())
    let sink = _RecordingEventSink()
    let result = try #require(try? MacAccessibilityActuator.act(
        source: source, sink: sink, path: [3], action: nil, value: nil
    ).get())
    #expect(!result.ok)
    #expect(result.error == "no_ax_action_and_no_frame")
    #expect(sink.mouse.isEmpty, "a frameless element must never produce a guessed click")
}

@Test func axActReportsPathNotFoundRatherThanActingOnSomethingElse() {
    let source = _FakeAXActSource(root: _buttonTree())
    let sink = _RecordingEventSink()
    for badPath in [[9], [0, 0], [1, 2, 3]] {
        let outcome = MacAccessibilityActuator.act(
            source: source, sink: sink, path: badPath, action: nil, value: nil
        )
        switch outcome {
        case .failure(let error):
            #expect(error == .pathNotFound, "\(badPath)")
        case .success:
            Issue.record("path \(badPath) must not resolve")
        }
    }
    #expect(sink.mouse.isEmpty, "an unresolvable path must emit nothing at all")
}

@Test func axActFallbackRefusesWhenTheEventSinkIsUnavailable() throws {
    let source = _FakeAXActSource(root: _buttonTree())
    let sink = _RecordingEventSink(available: false)
    let result = try #require(try? MacAccessibilityActuator.act(
        source: source, sink: sink, path: [2], action: nil, value: nil
    ).get())
    #expect(!result.ok)
    #expect(result.error == "event_injection_unavailable", "an unavailable sink must not be reported as a click")
}

@Test func axActTargetCentreIgnoresADegenerateFrame() {
    #expect(MacAXActTarget(handle: 1, role: "AXButton", frame: nil).centre == nil)
    #expect(MacAXActTarget(handle: 1, role: "AXButton",
                          frame: MacAXFrame(x: 0, y: 0, w: 0, h: 10)).centre == nil)
    let centre = MacAXActTarget(handle: 1, role: "AXButton",
                                frame: MacAXFrame(x: 10, y: 20, w: 100, h: 40)).centre
    #expect(centre?.x == 60 && centre?.y == 40)
}

// MARK: - Structural: reads stay injection-free

/// The read organ's guarantee is STRUCTURAL, so assert it structurally: the
/// reader's source file must contain no mutation or event API at all. A grep
/// test rather than a behavioural one because the guarantee is "there is no
/// code path", which no amount of calling can prove.
@Test func perceptionOrganContainsNoInjectionAPIs() throws {
    /// Strip `//` line comments so the audit reads CODE, not prose. The reader's
    /// own header says "no CGEvent, no AXUIElementPerformAction" — a naive grep
    /// matches that sentence and fails on the very comment documenting the
    /// guarantee. (String literals are not stripped; none of the forbidden
    /// symbols appear in one, and stripping them would weaken the audit.)
    func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[line.startIndex..<range.lowerBound]
            }
            .joined(separator: "\n")
    }

    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // MacControlTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // NativeAgentCore
        .appendingPathComponent("Sources/MacControl")
    let reader = sources.appendingPathComponent("MacAccessibilityReader.swift")
    let raw = try String(contentsOf: reader, encoding: .utf8)
    #expect(!raw.isEmpty, "the reader source must be readable for this audit to mean anything")
    let source = codeOnly(raw)
    let forbidden = [
        "AXUIElementPerformAction",
        "AXUIElementSetAttributeValue",
        "CGEvent(",
        "CGEventPost",
        ".post(tap:",
        "keyboardSetUnicodeString",
    ]
    for symbol in forbidden {
        #expect(!source.contains(symbol),
                "MacAccessibilityReader.swift must never call \(symbol) — perception cannot mutate")
    }
    // POSITIVE CONTROL: the ACT organ's code does contain them, so this audit
    // cannot pass merely because the symbols are misspelled or the comment
    // stripper ate everything.
    let actSource = codeOnly(try String(
        contentsOf: sources.appendingPathComponent("MacAccessibilityActuator.swift"),
        encoding: .utf8
    ))
    // (`CGEventPost` is the C free function; the act organ uses the Swift
    // method form `event.post(tap:)`. Both are banned in the reader — only the
    // form actually in use can serve as the positive control.)
    for symbol in ["AXUIElementPerformAction", "AXUIElementSetAttributeValue",
                   "CGEvent(", ".post(tap:", "keyboardSetUnicodeString"] {
        #expect(actSource.contains(symbol),
                "the injection audit greps must actually match something — \(symbol) is missing from the act organ")
    }
}

// MARK: - Inventory invariants

@Test func injectionActionsAreDispatchableUnderTheAccessibilityCategory() {
    for action in macControlAccessibilityInjectionActions {
        #expect(macControlDispatchableActions.contains(action), "\(action)")
        #expect(macControlGateCategory(forAction: action) == "accessibility", "\(action)")
        #expect(!macControlUnsupportedActions.contains(action),
                "\(action) is implemented now — it must not 501")
    }
    // W6 added `wake`. This set is the security predicate, so it is pinned
    // EXACTLY rather than by containment: a new action arriving here silently
    // would be a new injection nobody reviewed, and one LEAVING would be an
    // injection that quietly dropped to read tier.
    #expect(macControlAccessibilityInjectionActions == ["keystroke", "click", "scroll", "ax_act", "wake"])
}

@Test func keystrokeAndClickMovedIntoThePortedSetWithoutDisturbingDaemonParity() {
    // They have daemon ancestors, so they stay INSIDE macControlAllActions —
    // the byte-pinned parity inventory must not shift when an action is
    // implemented.
    #expect(macControlNativePortedActions.contains("keystroke"))
    #expect(macControlNativePortedActions.contains("click"))
    #expect(macControlAllActions.contains("keystroke"))
    #expect(macControlAllActions.contains("click"))
    // scroll/ax_act have NO daemon ancestor, so they must stay out of it.
    #expect(!macControlAllActions.contains("scroll"))
    #expect(!macControlAllActions.contains("ax_act"))
}
