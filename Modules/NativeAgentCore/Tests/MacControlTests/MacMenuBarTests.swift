import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - THE MENU BAR ORGAN (fable51 sweep item 29)
//
// `AXMenuBar` was explicitly excluded from every walk in this module, so
// File › Export › PDF — the cheapest deterministic route to anything an app can
// do — was unreachable. These tests hold the four things that make the new
// organ worth having and safe to have:
//
//   1. It LISTS real paths, bounded, in one walk.
//   2. It never lies by omission: a greyed-out item is present-and-disabled,
//      and a bound that cut the walk is REPORTED, so "this app has no Export"
//      is distinguishable from "I stopped looking".
//   3. The press goes through the MENU BAR address space, never a window's. A
//      menu bar is not under any window root, so resolving [0,0,2,0,0] against
//      a window would press whatever sits at those indices inside the document.
//   4. Every refusal is words: disabled, ambiguous, absent.
//
// Synthetic AX seams throughout.

private struct _MenuElement {
    var attributes: MacAXAttributes
    var children: [Int]
}

private final class _MenuSource: MacAXElementSource, @unchecked Sendable {
    private let elements: [Int: _MenuElement]
    private let menuBarID: Int?
    private let app: MacAXAppInfo

    init(elements: [Int: _MenuElement], menuBarID: Int?, app: MacAXAppInfo) {
        self.elements = elements
        self.menuBarID = menuBarID
        self.app = app
    }

    func isTrusted() -> Bool { true }
    func frontmostApp() -> MacAXAppInfo? { app }
    func frontmostWindowRoot() -> MacAXElementRef? { nil }
    func runningApps() -> [MacAXAppInfo] { [app] }
    func menuBarRoot(pid: Int32) -> MacAXElementRef? {
        menuBarID.map { MacAXElementRef(id: $0) }
    }
    func attributes(of element: MacAXElementRef) -> MacAXAttributes? {
        elements[element.id]?.attributes
    }
    func children(of element: MacAXElementRef) -> [MacAXElementRef] {
        (elements[element.id]?.children ?? []).map { MacAXElementRef(id: $0) }
    }
    func focusedElementPath() -> [Int]? { nil }
}

private final class _MenuActSource: MacAXActSource, @unchecked Sendable {
    private let lock = NSLock()
    /// index chain → the element it names, so a WRONG address presses the
    /// wrong thing and the test sees it.
    private let menuTargets: [[Int]: MacAXActTarget]
    private(set) var presses: [Int] = []
    /// Window-relative resolves are recorded separately: a menu press that ever
    /// reaches this is addressing the document, which is the bug.
    private(set) var windowResolves: [[Int]] = []

    init(menuTargets: [[Int]: MacAXActTarget]) { self.menuTargets = menuTargets }

    func isTrusted() -> Bool { true }

    func resolve(path: [Int]) -> MacAXActTarget? {
        lock.withLock { windowResolves.append(path) }
        return nil
    }

    func resolve(path: [Int], inAppPid pid: Int32) -> MacAXPidResolution {
        lock.withLock { windowResolves.append(path) }
        return .pathNotFound
    }

    func resolve(menuPath: [Int], inAppPid pid: Int32) -> MacAXPidResolution {
        guard let target = menuTargets[menuPath] else { return .pathNotFound }
        return .resolved(target)
    }

    func resolve(path: [Int], inWindow window: MacAXWindowRef) -> MacAXPidResolution {
        .pathNotFound
    }

    func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome {
        guard action == "AXPress" else { return .unsupported }
        lock.withLock { presses.append(target.handle) }
        return .performed
    }

    func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome { .unsupported }
    func reread(_ target: MacAXActTarget) -> MacAXActTarget? { target }

    func pressed() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return presses
    }

    func windowResolveAttempts() -> [[Int]] {
        lock.lock(); defer { lock.unlock() }
        return windowResolves
    }
}

// The fixture, and the exact index chains it implies.
//
//   AXMenuBar (1)
//    [0] AXMenuBarItem "File" (10)
//         [0] AXMenu (11)
//              [0] AXMenuItem "New" (12)
//              [1] AXMenuItem <no title — a separator> (13)
//              [2] AXMenuItem "Export" (14)
//                   [0] AXMenu (15)
//                        [0] AXMenuItem "PDF…" (16)
//                        [1] AXMenuItem "PNG" (17)
//                             [0] AXMenu (18)   ← a FOURTH named level
//                                  [0] AXMenuItem "72 dpi" (19)
//              [3] AXMenuItem "Print…" (20, DISABLED)
//    [1] AXMenuBarItem "Edit" (30)
//         [0] AXMenu (31)
//              [0] AXMenuItem "Export" (32)   ← same NAME, different branch
//
//   "File › Export › PDF…"  → [0, 0, 2, 0, 0]
//   "File › Print…"         → [0, 0, 3]
private func _menuElements() -> [Int: _MenuElement] {
    func item(_ role: String, _ title: String?, _ children: [Int] = [], enabled: Bool = true) -> _MenuElement {
        _MenuElement(
            attributes: MacAXAttributes(role: role, title: title, enabled: enabled),
            children: children
        )
    }
    return [
        1: item("AXMenuBar", nil, [10, 30]),
        10: item("AXMenuBarItem", "File", [11]),
        11: item("AXMenu", nil, [12, 13, 14, 20]),
        12: item("AXMenuItem", "New"),
        13: item("AXMenuItem", nil),
        14: item("AXMenuItem", "Export", [15]),
        15: item("AXMenu", nil, [16, 17]),
        16: item("AXMenuItem", "PDF…"),
        17: item("AXMenuItem", "PNG", [18]),
        18: item("AXMenu", nil, [19]),
        19: item("AXMenuItem", "72 dpi"),
        20: item("AXMenuItem", "Print…", [], enabled: false),
        30: item("AXMenuBarItem", "Edit", [31]),
        31: item("AXMenu", nil, [32]),
        32: item("AXMenuItem", "Export"),
    ]
}

private let _menuApp = MacAXAppInfo(
    name: "Preview", bundleIdentifier: "com.apple.Preview", processIdentifier: 909
)

private func _menuHarness(
    menuBarID: Int? = 1,
    elements: [Int: _MenuElement]? = nil
) -> (client: SwiftNativeMacControl, source: _MenuSource, act: _MenuActSource) {
    let source = _MenuSource(
        elements: elements ?? _menuElements(),
        menuBarID: menuBarID,
        app: _menuApp
    )
    let act = _MenuActSource(menuTargets: [
        [0]: MacAXActTarget(handle: 10, role: "AXMenuBarItem", title: "File"),
        [0, 0, 0]: MacAXActTarget(handle: 12, role: "AXMenuItem", title: "New"),
        [0, 0, 2]: MacAXActTarget(handle: 14, role: "AXMenuItem", title: "Export"),
        [0, 0, 2, 0, 0]: MacAXActTarget(handle: 16, role: "AXMenuItem", title: "PDF…"),
        [0, 0, 2, 0, 1]: MacAXActTarget(handle: 17, role: "AXMenuItem", title: "PNG"),
        [0, 0, 3]: MacAXActTarget(handle: 20, role: "AXMenuItem", title: "Print…", enabled: false),
        [1, 0, 0]: MacAXActTarget(handle: 32, role: "AXMenuItem", title: "Export"),
    ])
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        eventSink: InertAvailableMacEventSink(),
        accessibilityActSource: act,
        screenCaptureSource: UnavailableMacScreenCaptureSource(),
        lookFrameStore: MacLookFrameStore()
    )
    return (client, source, act)
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
private func _paths(_ out: [String: JSONValue]) -> [(path: String, enabled: Bool)] {
    guard case .array(let rows)? = out["paths"] else { return [] }
    return rows.compactMap { row in
        let object = _object(row)
        guard let path = _string(object["path"]) else { return nil }
        return (path, _bool(object["enabled"]) ?? true)
    }
}

// MARK: - 1. The walk

@Test
func menu_listsNameablePaths_boundedToThreeLevels() async throws {
    let harness = _menuHarness()
    let result = try await harness.client.dispatch(action: "menu", body: [:])
    let out = _object(result.output)

    #expect(result.ok, "\(out)")
    let paths = _paths(out).map(\.path)
    #expect(paths.contains("File"), "\(paths)")
    #expect(paths.contains("File › Export"), "\(paths)")
    #expect(paths.contains("File › Export › PDF…"), "the whole point of the organ: \(paths)")
    #expect(paths.contains("Edit › Export"), "\(paths)")

    // Three NAMED levels. The AXMenu wrappers cost tree depth, not path depth —
    // a cap that counted them would stop at File › Export.
    #expect(!paths.contains { $0.contains("72 dpi") }, "depth cap breached: \(paths)")
    // And the cap that bit is REPORTED, so "no 72 dpi" is not read as "this app
    // cannot do 72 dpi".
    #expect(_bool(out["truncated"]) == true, "a bound that cut the walk must be said: \(out)")
}

@Test
func menu_listsADisabledItemAsPresentAndOff_notAsAbsent() async throws {
    let harness = _menuHarness()
    let out = _object(try await harness.client.dispatch(action: "menu", body: [:]).output)
    let print = _paths(out).first { $0.path == "File › Print…" }

    // Omitting it would tell her the app cannot print. It can — just not now.
    let row = try #require(print, "a greyed-out item must still be listed: \(_paths(out))")
    #expect(row.enabled == false)
}

@Test
func menu_skipsSeparators_whichAreFurnitureNotAddresses() async throws {
    let harness = _menuHarness()
    let out = _object(try await harness.client.dispatch(action: "menu", body: [:]).output)
    let fileItems = _paths(out).map(\.path).filter { $0.hasPrefix("File › ") }
    // New, Export, Print… — and NOT the untitled separator between them.
    #expect(fileItems.sorted() == ["File › Export", "File › Export › PDF…", "File › Export › PNG", "File › New", "File › Print…"],
            "\(fileItems)")
}

@Test
func menu_saysSoWhenTheAppPublishesNoMenuBar() async throws {
    let harness = _menuHarness(menuBarID: nil)
    let result = try await harness.client.dispatch(action: "menu", body: [:])
    let out = _object(result.output)

    #expect(!result.ok)
    #expect(result.error == "no_menu_bar")
    #expect(_string(out["message"])?.contains("Preview") == true, "\(out)")
}

// MARK: - 2. Naming a path

@Test
func menuPath_toleratesTheSeparatorsAPersonActuallyTypes() {
    let items = MacMenuBar.read(source: _menuHarness().source, pid: 909).items
    for spelling in [
        "File › Export › PDF…",
        "File > Export > PDF",
        "File / Export / PDF",
        "file->export->pdf",
    ] {
        guard case .matched(let item) = MacMenuBar.resolve(spelling, among: items) else {
            Issue.record("refusing a path over its typography: \(spelling)")
            continue
        }
        #expect(item.display == "File › Export › PDF…")
    }
}

@Test
func menuPath_exactNameBeatsALongerOne() {
    let items = MacMenuBar.read(source: _menuHarness().source, pid: 909).items
    // "File › Export" is a real item AND a prefix of "File › Export › PDF…".
    // Depth is what separates them, and an exact match must never lose.
    guard case .matched(let item) = MacMenuBar.resolve("File › Export", among: items) else {
        Issue.record("exact two-level path lost to a three-level one")
        return
    }
    #expect(item.display == "File › Export")
    #expect(item.hasSubmenu)
}

@Test
func menuPath_refusesToGuessBetweenTwoEquallyGoodLeaves() {
    let items = MacMenuBar.read(source: _menuHarness().source, pid: 909).items
    // "File › Export › P" fits both PDF… and PNG. Picking one is exactly the
    // wrong-element act this organ exists to avoid.
    let resolution = MacMenuBar.resolve("File › Export › P", among: items)
    guard case .ambiguous(let candidates) = resolution else {
        Issue.record("a coin flip between two menu items: \(resolution)")
        return
    }
    #expect(candidates == ["File › Export › PDF…", "File › Export › PNG"], "\(candidates)")
    let words = MacMenuBar.words(for: resolution, requested: "File › Export › P")
    #expect(words?.contains("PDF") == true && words?.contains("PNG") == true, "\(words ?? "")")
}

@Test
func menuPath_doesNotFindADeepItemAtTheWrongDepth() {
    let items = MacMenuBar.read(source: _menuHarness().source, pid: 909).items
    // "Export" on its own would name a TOP-LEVEL menu called Export, and there
    // is none. Silently promoting it to File › Export would make the path
    // vocabulary mean two different things.
    guard case .notFound(let nearest) = MacMenuBar.resolve("Export", among: items) else {
        Issue.record("a one-level path must not resolve to a two-level item")
        return
    }
    #expect(nearest.sorted() == ["Edit", "File"], "\(nearest)")
}

@Test
func menuPath_teachesWhenItCannotFindThePath() {
    let items = MacMenuBar.read(source: _menuHarness().source, pid: 909).items
    let resolution = MacMenuBar.resolve("File › Publish", among: items)
    guard case .notFound(let nearest) = resolution else {
        Issue.record("\(resolution)")
        return
    }
    // The alternatives are FILE's items, not the whole menu bar.
    #expect(nearest.allSatisfy { $0.hasPrefix("File") }, "\(nearest)")
    let words = try? #require(MacMenuBar.words(for: resolution, requested: "File › Publish"))
    #expect(words?.contains("File › New") == true, "\(words ?? "")")
}

// MARK: - 3. The press

@Test
func menuPress_pressesTheNamedItem_throughTheMenuBarAddressSpace() async throws {
    let harness = _menuHarness()
    let result = try await harness.client.dispatch(
        action: "menu_press",
        body: ["path": .string("File › Export › PDF…")]
    )
    let out = _object(result.output)

    #expect(result.ok, "\(out)")
    #expect(_bool(out["pressed"]) == true)
    // Element 16 is "PDF…". Anything else is the wrong-element act.
    #expect(harness.act.pressed() == [16], "\(harness.act.pressed())")
    // AND it never went through a WINDOW resolve. A menu bar is not under any
    // window root; resolving [0,0,2,0,0] there would press whatever sits at
    // those indices inside the document.
    #expect(harness.act.windowResolveAttempts().isEmpty,
            "a menu press must never address a window: \(harness.act.windowResolveAttempts())")
    // The press ran the app's handler; whether the intended thing HAPPENED is
    // for the next look to say.
    #expect(_bool(out["verified"]) == false)
}

@Test
func menuPress_refusesADisabledItemInWords_andPressesNothing() async throws {
    let harness = _menuHarness()
    let result = try await harness.client.dispatch(
        action: "menu_press",
        body: ["path": .string("File › Print…")]
    )
    let out = _object(result.output)

    #expect(!result.ok)
    #expect(result.error == "menu_item_disabled")
    // The refusal has to say it is THERE and OFF — "not found" would send her
    // hunting for a different menu.
    #expect(_string(out["message"])?.contains("greyed out") == true, "\(out)")
    #expect(harness.act.pressed().isEmpty, "a refusal must not have pressed first")
}

@Test
func menuPress_refusesAnAmbiguousPath_andPressesNothing() async throws {
    let harness = _menuHarness()
    let result = try await harness.client.dispatch(
        action: "menu_press",
        body: ["path": .string("File › Export › P")]
    )

    #expect(!result.ok)
    #expect(result.error == "menu_path_ambiguous")
    #expect(harness.act.pressed().isEmpty)
}

@Test
func menuPress_refusesAnUnknownPath_andNamesWhatIsThere() async throws {
    let harness = _menuHarness()
    let result = try await harness.client.dispatch(
        action: "menu_press",
        body: ["path": .string("File › Publish to Web")]
    )
    let out = _object(result.output)

    #expect(!result.ok)
    #expect(result.error == "menu_path_not_found")
    #expect(_string(out["message"])?.contains("File › New") == true, "\(out)")
    #expect(harness.act.pressed().isEmpty)
}

@Test
func menuPress_needsAPath() async throws {
    let harness = _menuHarness()
    let result = try await harness.client.dispatch(action: "menu_press", body: [:])
    #expect(!result.ok)
    #expect(result.error == "missing_path")
    #expect(harness.act.pressed().isEmpty)
}

// MARK: - 4. The tiers, pinned

@Test
func menuActions_sitInTheRightTiers() {
    #expect(macControlDispatchableActions.contains("menu"))
    #expect(macControlDispatchableActions.contains("menu_press"))
    #expect(macControlGateCategory(forAction: "menu") == "accessibility")
    #expect(macControlGateCategory(forAction: "menu_press") == "accessibility")
    // The WALK is perception: it must stay in the read set, whose contract is
    // "no CGEvent, no AX action, no attribute write".
    #expect(macControlAccessibilityReadActions.contains("menu"))
    #expect(!macControlAccessibilityInjectionActions.contains("menu"))
    // The PRESS runs the app's own handler, so it carries the full injection
    // contract — a body-bound single-use capability, like every other act.
    #expect(macControlAccessibilityInjectionActions.contains("menu_press"))
    #expect(!macControlAccessibilityReadActions.contains("menu_press"))
}
