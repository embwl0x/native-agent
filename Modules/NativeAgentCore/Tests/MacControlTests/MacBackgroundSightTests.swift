import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - BACKGROUND-WINDOW SIGHT (fable51 sweep item 32a)
//
// `screen(app: "Mail")` reads Mail's front window WITHOUT activating it. The
// two things these tests exist to hold:
//
//   1. NOTHING IS ACTIVATED. The app-control adapter records every focus
//      request; a background look must leave that list empty. If this ever
//      regresses, the symptom on User's real machine is his window flipping
//      away mid-sentence, which is exactly the cost the anchor exists to avoid.
//
//   2. THE ANSWER DOES NOT CLAIM "IN FRONT". `act` and `go` are frontmost
//      verbs. A background sighting that renders as front is a look wearing an
//      act's clothes.
//
// Synthetic AX seams throughout — two apps, two trees, no window server.

private struct _BGElement {
    var attributes: MacAXAttributes?
    var children: [Int]
}

/// A source that knows about TWO apps. The default `runningApps()` answers with
/// the frontmost one only (truthful for a single-tree source); this one really
/// has two, which is what makes the anchored path testable at all.
private final class _BGSource: MacAXElementSource, @unchecked Sendable {
    struct App {
        let info: MacAXAppInfo
        let elements: [Int: _BGElement]
        let rootID: Int
    }

    private let lock = NSLock()
    private let apps: [App]
    private var frontIndex: Int
    var accessoryFirst = false
    var alternateDocument = false
    private(set) var windowRootCalls: [Int32] = []

    init(apps: [App], frontIndex: Int = 0) {
        self.apps = apps
        self.frontIndex = frontIndex
    }

    private func app(pid: Int32) -> App? { apps.first { $0.info.processIdentifier == pid } }

    /// Element ids are namespaced by pid so a ref minted for one app can never
    /// resolve inside the other's tree.
    private func ref(pid: Int32, local: Int) -> MacAXElementRef {
        MacAXElementRef(id: Int(pid) * 10_000 + local)
    }

    private func decode(_ ref: MacAXElementRef) -> (pid: Int32, local: Int) {
        (Int32(ref.id / 10_000), ref.id % 10_000)
    }

    func isTrusted() -> Bool { true }

    func frontmostApp() -> MacAXAppInfo? { apps[frontIndex].info }

    func frontmostWindowRoot() -> MacAXElementRef? {
        let front = apps[frontIndex]
        return ref(pid: front.info.processIdentifier, local: front.rootID)
    }

    func windowRoot(pid: Int32) -> MacAXElementRef? {
        lock.lock(); windowRootCalls.append(pid); lock.unlock()
        guard let hit = app(pid: pid) else { return nil }
        return ref(pid: pid, local: alternateDocument ? 9_000 : hit.rootID)
    }

    func windowRoots(pid: Int32) -> [MacAXWindowHandle] {
        guard let root = windowRoot(pid: pid), let attrs = attributes(of: root) else { return [] }
        let document = MacAXWindowHandle(ref: root, identity: MacAXWindowIdentity(
            pid: pid, index: accessoryFirst ? 1 : 0, role: attrs.role,
            title: attrs.title, frame: attrs.frame))
        guard accessoryFirst else { return [document] }
        return [MacAXWindowHandle(ref: ref(pid: pid, local: 9_000),
            identity: MacAXWindowIdentity(pid: pid, index: 0, role: "AXWindow", title: "Window")), document]
    }

    func appInfo(pid: Int32) -> MacAXAppInfo? { app(pid: pid)?.info }

    func runningApps() -> [MacAXAppInfo] { apps.map(\.info) }

    func attributes(of element: MacAXElementRef) -> MacAXAttributes? {
        let (pid, local) = decode(element)
        if local == 9_000 {
            return MacAXAttributes(role: "AXWindow", title: "Window B",
                frame: alternateDocument ? MacAXFrame(x: 0, y: 0, w: 800, h: 600) : nil)
        }
        return app(pid: pid)?.elements[local]?.attributes
    }

    func children(of element: MacAXElementRef) -> [MacAXElementRef] {
        let (pid, local) = decode(element)
        guard let hit = app(pid: pid) else { return [] }
        return (hit.elements[local]?.children ?? []).map { ref(pid: pid, local: $0) }
    }

    func focusedElementPath() -> [Int]? { nil }

    func anchoredPids() -> [Int32] {
        lock.lock(); defer { lock.unlock() }
        return windowRootCalls
    }
}

private final class _BGAppControl: AppControlAdapter, AppStateVerificationAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var focusRequests: [String] = []

    func focusApp(named name: String) async throws -> AppControlRunResult {
        lock.withLock { focusRequests.append(name) }
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

    func isFrontmostApplication(matching name: String) async -> Bool { false }
    func isApplicationRunning(matching name: String) async -> Bool { true }

    func requests() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return focusRequests
    }
}

private func _bgApp(
    name: String,
    bundle: String,
    pid: Int32,
    windowTitle: String,
    rowLabels: [String],
    status: String
) -> _BGSource.App {
    var elements: [Int: _BGElement] = [
        1: _BGElement(attributes: MacAXAttributes(role: "AXList", title: "items"), children: []),
        2: _BGElement(attributes: MacAXAttributes(role: "AXStaticText", value: status), children: []),
    ]
    var rowIDs: [Int] = []
    for (index, label) in rowLabels.enumerated() {
        let id = 100 + index
        rowIDs.append(id)
        elements[id] = _BGElement(
            attributes: MacAXAttributes(role: "AXRow", title: label, actions: ["AXPress"]),
            children: []
        )
    }
    elements[1] = _BGElement(attributes: MacAXAttributes(role: "AXList", title: "items"), children: rowIDs)
    elements[0] = _BGElement(
        attributes: MacAXAttributes(role: "AXWindow", title: windowTitle,
            frame: MacAXFrame(x: 100, y: 100, w: 800, h: 600)),
        children: [1, 2]
    )
    return _BGSource.App(
        info: MacAXAppInfo(name: name, bundleIdentifier: bundle, processIdentifier: pid),
        elements: elements,
        rootID: 0
    )
}

private func _bgHarness(frontIndex: Int = 0, supplementalSource: (any MacFourVerbsSupplementalPerceptionSource)? = nil) -> (source: _BGSource, control: _BGAppControl, verbs: MacFourVerbs) {
    let source = _BGSource(
        apps: [
            _bgApp(
                name: "Finder", bundle: "com.apple.finder", pid: 501,
                windowTitle: "Documents",
                rowLabels: ["report.pdf", "notes.md"],
                status: "2 items"
            ),
            _bgApp(
                name: "Mail", bundle: "com.apple.mail", pid: 777,
                windowTitle: "Inbox — user@example.com",
                rowLabels: ["Invoice from Acme", "Standup notes"],
                status: "2 unread"
            ),
        ],
        frontIndex: frontIndex
    )
    let control = _BGAppControl()
    let client = SwiftNativeMacControl(
        appControlAdapter: control,
        accessibilitySource: source,
        eventSink: InertAvailableMacEventSink(),
        screenCaptureSource: UnavailableMacScreenCaptureSource(),
        screenViewStore: MacScreenViewStore(),
        lookFrameStore: MacLookFrameStore()
    )
    return (source, control, MacFourVerbs(host: client, supplementalSource: supplementalSource))
}

private actor _BGWindowCapture: MacScreenCaptureSource {
    private(set) var windows: [MacAXWindowIdentity] = []
    private(set) var desktopCalls = 0
    nonisolated func isScreenRecordingTrusted() -> Bool { true }
    func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        desktopCalls += 1
        return .failure(.captureFailed)
    }
    func capture(window: MacAXWindowIdentity) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        windows.append(window)
        return .failure(.captureFailed)
    }
}

@Test func backgroundViewCapturesOnlyTheNamedWindowAndNeverFallsBackToDesktop() async throws {
    let harness = _bgHarness()
    let capture = _BGWindowCapture()
    let client = SwiftNativeMacControl(accessibilitySource: harness.source,
        eventSink: InertAvailableMacEventSink(), screenCaptureSource: capture,
        screenViewStore: MacScreenViewStore())
    let result = try await client.dispatch(action: "view", body: ["app": .string("Mail")])
    #expect(await capture.windows.count == 1)
    #expect(await capture.windows.first?.pid == 777)
    #expect(await capture.windows.first?.title == "Inbox — user@example.com")
    #expect(await capture.desktopCalls == 0, "an unavailable isolated image never becomes foreground pixels")
    guard case .object(let output) = result.output else { Issue.record("missing view"); return }
    #expect(output["capture_isolated_window"] == .bool(true))
    #expect(output["image"] == .null || output["image"] == nil)
    #expect(output["pointer"] == .null)
    let unknown = try await client.dispatch(action: "view", body: ["app": .string("missing-app")])
    #expect(!unknown.ok)
    #expect(await capture.windows.count == 1)
    #expect(await capture.desktopCalls == 0)
    #expect(harness.control.requests().isEmpty)
}

@Test func namedFrontmostViewAlsoUsesIdentityBoundCapture() async throws {
    let harness = _bgHarness(frontIndex: 1)
    let capture = _BGWindowCapture()
    let client = SwiftNativeMacControl(accessibilitySource: harness.source,
        eventSink: InertAvailableMacEventSink(), screenCaptureSource: capture,
        screenViewStore: MacScreenViewStore())
    _ = try await client.dispatch(action: "view", body: ["app": .string("Mail")])
    #expect(await capture.windows.first?.pid == 777)
    #expect(await capture.desktopCalls == 0)
}

@Test func supplementalCaptureRequiresSameWindowAndCurrentLookGeneration() async throws {
    let harness = _bgHarness()
    let capture = _BGWindowCapture()
    let frames = MacLookFrameStore()
    let client = SwiftNativeMacControl(accessibilitySource: harness.source,
        eventSink: InertAvailableMacEventSink(), screenCaptureSource: capture,
        screenViewStore: MacScreenViewStore(), lookFrameStore: frames)
    _ = try await client.dispatch(action: "look", body: ["app": .string("Mail"), "grade": .string("look")])
    let frameID = try #require(await frames.latestFrameId())
    let binding = MacSightCaptureBinding(frameID: frameID)
    harness.source.alternateDocument = true // Same PID, different selected document.
    _ = try await MacSightCaptureBinding.$current.withValue(binding) {
        try await client.dispatch(action: "view", body: ["app": .string("Mail")])
    }
    #expect(!binding.isConfirmed)
    #expect(await capture.windows.isEmpty)
    harness.source.alternateDocument = false
    _ = try await client.dispatch(action: "look", body: ["app": .string("Mail"), "grade": .string("look")])
    _ = try await MacSightCaptureBinding.$current.withValue(binding) {
        try await client.dispatch(action: "view", body: ["app": .string("Mail")])
    }
    #expect(!binding.isConfirmed)
    #expect(await capture.windows.isEmpty)
    weak var releasedBinding: MacSightCaptureBinding?
    do {
        let current = MacSightCaptureBinding(frameID: try #require(await frames.latestFrameId()))
        _ = try await MacSightCaptureBinding.$current.withValue(current) {
            try await client.dispatch(action: "view", body: ["app": .string("Mail")])
        }
        #expect(current.isConfirmed)
        releasedBinding = current
    }
    #expect(releasedBinding == nil, "The per-call validation closure must not retain its binding")
    #expect(await capture.windows.count == 1)
}

@Test func sameAppSupplementWithoutCaptureProofIsDiscarded() async {
    struct Unbound: MacFourVerbsSupplementalPerceptionSource {
        func observe() async -> MacFourVerbsSupplement? { nil }
        func observe(app: String?) async -> MacFourVerbsSupplement? {
            MacFourVerbsSupplement(appName: "Mail", bundleIdentifier: "com.apple.mail",
                values: [MacScreenRender.Value(text: MacScreenText("Wrong window B pixels"), provenance: .vision(1))])
        }
    }
    let reply = await _bgHarness(supplementalSource: Unbound()).verbs.screen(app: "Mail")
    #expect(!reply.text.contains("Wrong window B pixels"))
}

@Test func screen_withApp_passesTheAnchorToSupplementalPerception() async {
    struct Supplement: MacFourVerbsSupplementalPerceptionSource {
        func observe() async -> MacFourVerbsSupplement? { Issue.record("unanchored read"); return nil }
        func observe(app: String?) async -> MacFourVerbsSupplement? {
            #expect(app == "Mail")
            MacSightCaptureBinding.current?.confirm()
            return MacFourVerbsSupplement(appName: "Mail", bundleIdentifier: "com.apple.mail",
                values: [MacScreenRender.Value(text: MacScreenText("Named-window pixels"), provenance: .vision(1))])
        }
    }
    let harness = _bgHarness(supplementalSource: Supplement())
    let reply = await harness.verbs.screen(app: "Mail")
    #expect(reply.text.contains("Named-window pixels"))
    #expect(reply.text.contains("not front"))
    #expect(harness.control.requests().isEmpty)
}

// MARK: - 1. The resolver, on its own

@Test
func backgroundSight_exactNameBeatsASubstring() {
    let apps = [
        MacAXAppInfo(name: "Mail", bundleIdentifier: "com.apple.mail", processIdentifier: 10),
        MacAXAppInfo(name: "Mailplane", bundleIdentifier: "com.mailplaneapp.Mailplane", processIdentifier: 11),
    ]
    // Substring alone would call this ambiguous and refuse a read she plainly
    // asked for.
    #expect(MacBackgroundSight.resolve("Mail", among: apps) == .matched(apps[0]))
    #expect(MacBackgroundSight.resolve("mail", among: apps) == .matched(apps[0]))
    #expect(MacBackgroundSight.resolve("Mail.app", among: apps) == .matched(apps[0]))
    #expect(MacBackgroundSight.resolve("com.apple.mail", among: apps) == .matched(apps[0]))
    #expect(MacBackgroundSight.resolve("Mailplane", among: apps) == .matched(apps[1]))
}

@Test
func backgroundSight_refusesToGuessBetweenTwoRealMatches() {
    let apps = [
        MacAXAppInfo(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 10),
        MacAXAppInfo(name: "Notion", bundleIdentifier: "so.notion.desktop", processIdentifier: 11),
    ]
    let resolution = MacBackgroundSight.resolve("Not", among: apps)
    guard case .ambiguous(let candidates) = resolution else {
        Issue.record("guessing which window she meant is the failure this organ avoids: \(resolution)")
        return
    }
    #expect(candidates == ["Notes", "Notion"])
    let words = MacBackgroundSight.words(for: resolution, requested: "Not")
    #expect(words?.contains("Notes") == true)
    #expect(words?.contains("Notion") == true)
}

@Test
func backgroundSight_namesWhatIsRunningWhenTheNameMatchesNothing() {
    let apps = [
        MacAXAppInfo(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 10),
        MacAXAppInfo(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processIdentifier: 11),
    ]
    let resolution = MacBackgroundSight.resolve("Photoshop", among: apps)
    #expect(resolution == .notRunning(candidates: ["Safari", "Xcode"]))
    // A bare code makes a model re-try the same spelling forever.
    let words = try? #require(MacBackgroundSight.words(for: resolution, requested: "Photoshop"))
    #expect(words?.contains("Safari") == true)
}

// MARK: - 2. The read, through the real handler

@Test func screen_withApp_prefersTheDocumentOverFirstInventoryAccessory() async throws {
    let harness = _bgHarness()
    harness.source.accessoryFirst = true
    let reply = await harness.verbs.screen(app: "Mail")
    #expect(reply.ok)
    #expect(reply.text.contains("Inbox"))
    #expect(reply.text.contains("Invoice from Acme"))
    #expect(!reply.text.contains("window \"Window\""))
    #expect(harness.control.requests().isEmpty)
}

@Test
func screen_withApp_readsTheBackgroundWindow_andActivatesNothing() async throws {
    let harness = _bgHarness()  // Finder is in front
    let reply = await harness.verbs.screen(app: "Mail")

    #expect(reply.ok, "\(reply.text)")
    // It really read MAIL, not the frontmost Finder.
    #expect(reply.text.contains("Mail"), "\(reply.text)")
    #expect(reply.text.contains("Inbox"), "\(reply.text)")
    #expect(reply.text.contains("Invoice from Acme"), "\(reply.text)")
    #expect(!reply.text.contains("report.pdf"), "it described the frontmost app instead: \(reply.text)")

    // THE WHOLE POINT: no focus steal.
    #expect(harness.control.requests().isEmpty, "a background look must activate nothing: \(harness.control.requests())")
    #expect(harness.source.anchoredPids().contains(777), "the walk must be anchored to Mail's pid")
}

@Test
func screen_withApp_doesNotClaimTheWindowIsInFront() async throws {
    let harness = _bgHarness()
    let background = await harness.verbs.screen(app: "Mail")
    let frontmost = await harness.verbs.screen()

    // `act` and `go` are frontmost verbs. A background sighting rendered as
    // "in front" is a look wearing an act's clothes.
    #expect(!background.text.lowercased().contains("in front"), "\(background.text)")
    #expect(background.text.contains("nothing was brought to the front"), "\(background.text)")
    // The unanchored look still says front, because it truthfully is.
    #expect(frontmost.text.lowercased().contains("front"), "\(frontmost.text)")
}

@Test
func screen_withApp_saysFrontWhenTheNamedAppHappensToBeFrontmost() async throws {
    let harness = _bgHarness(frontIndex: 1)  // Mail IS in front
    let reply = await harness.verbs.screen(app: "Mail")

    #expect(reply.ok, "\(reply.text)")
    // `front` follows the FACT, not the presence of an anchor.
    #expect(reply.text.lowercased().contains("front"), "\(reply.text)")
}

@Test
func screen_withApp_refusesInWordsWhenNothingByThatNameIsRunning() async throws {
    let harness = _bgHarness()
    let reply = await harness.verbs.screen(app: "Photoshop")

    #expect(!reply.ok)
    // Words, and the running apps — not an empty render she has to interpret.
    #expect(reply.text.contains("Photoshop"), "\(reply.text)")
    #expect(reply.text.contains("Mail") || reply.text.contains("Finder"), "\(reply.text)")
    #expect(harness.control.requests().isEmpty, "a refusal must not have launched anything")
}

@Test
func screen_withoutApp_isUnchanged() async throws {
    let harness = _bgHarness()
    let reply = await harness.verbs.screen()

    #expect(reply.ok, "\(reply.text)")
    #expect(reply.text.contains("Finder"), "\(reply.text)")
    #expect(reply.text.contains("report.pdf"), "\(reply.text)")
    #expect(!reply.text.contains("nothing was brought to the front"))
}

@Test
func look_withApp_atStare_refusesRatherThanSilentlyReadingTheFrontmostTree() async throws {
    let harness = _bgHarness()
    let client = SwiftNativeMacControl(
        appControlAdapter: harness.control,
        accessibilitySource: harness.source,
        eventSink: InertAvailableMacEventSink(),
        screenCaptureSource: UnavailableMacScreenCaptureSource(),
        screenViewStore: MacScreenViewStore(),
        lookFrameStore: MacLookFrameStore()
    )
    let result = try await client.dispatch(
        action: "look",
        body: ["grade": .string("stare"), "app": .string("Mail")]
    )
    // Silently ignoring `app` and staring at Finder would be the worst of both:
    // a payload that looks like an answer about Mail.
    #expect(!result.ok)
    #expect(result.error == "background_stare_unsupported")
}
