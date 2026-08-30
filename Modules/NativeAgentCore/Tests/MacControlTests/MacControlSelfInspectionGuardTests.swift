import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - The self-inspection fence (P1 deadlock, sample 2026-08-28)
//
// An AX walk of NativeAgent's OWN process re-enters AppKit in-process:
// `AXUIElementCopyActionNames` on our own toolbar ran
// `+[NSToolbarView defaultMenu]` → `-[NSOperation waitUntilFinished]` on a
// background cooperative thread while the main thread was parked in SwiftUI's
// update lock — mutual wait, force-kill to recover. A live self-walk cannot be
// safely reproduced in-process, so these tests pin the GUARD: any snapshot
// whose target resolves to `getpid()` refuses before a single element is read.
// The synthetic source deliberately WOULD answer a walk — a recorded read is
// proof the guard did not fire first.

private struct _SelfElement {
    var attributes: MacAXAttributes?
    var children: [Int]
}

private final class _SelfPidAXSource: MacAXElementSource, @unchecked Sendable {
    private let lock = NSLock()
    private let elements: [Int: _SelfElement]
    private let app: MacAXAppInfo?
    /// Every ref the walker asked about — the fence holds only if this stays
    /// EMPTY on a self-process target.
    private var reads: [Int] = []

    init(pid: Int32) {
        self.elements = [
            0: _SelfElement(
                attributes: MacAXAttributes(role: "AXWindow", title: "Chat"),
                children: [1]
            ),
            1: _SelfElement(
                attributes: MacAXAttributes(
                    role: "AXButton", title: "Send", enabled: true,
                    frame: MacAXFrame(x: 10, y: 20, w: 60, h: 24), actions: ["AXPress"]
                ),
                children: []
            ),
        ]
        self.app = MacAXAppInfo(
            name: "NativeAgent",
            bundleIdentifier: "test.nativeagent.self",
            processIdentifier: pid
        )
    }

    func isTrusted() -> Bool { true }
    func frontmostApp() -> MacAXAppInfo? { app }
    func frontmostWindowRoot() -> MacAXElementRef? { MacAXElementRef(id: 0) }
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes? {
        lock.lock(); defer { lock.unlock() }
        reads.append(ref.id)
        return elements[ref.id]?.attributes
    }
    func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        (elements[ref.id]?.children ?? []).map { MacAXElementRef(id: $0) }
    }
    func readCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return reads.count
    }
}

private struct _SelfStubCapture: MacScreenCaptureSource {
    func isScreenRecordingTrusted() -> Bool { false }
    func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        .failure(.captureFailed)
    }
}

private func _client(_ source: _SelfPidAXSource) -> SwiftNativeMacControl {
    SwiftNativeMacControl(
        accessibilitySource: source,
        screenCaptureSource: _SelfStubCapture(),
        lookFrameStore: MacLookFrameStore()
    )
}

private func _object(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let object) = value else { return [:] }
    return object
}

// MARK: - Frontmost branch: our own window in front

@Test
func axTree_onOwnProcessFrontmost_refusesWithoutReadingOneElement() async throws {
    let source = _SelfPidAXSource(pid: getpid())
    let result = try await _client(source).dispatch(action: "ax_tree", body: [:])

    #expect(!result.ok)
    #expect(result.error == SwiftNativeMacControl.selfInspectionError)
    #expect(source.readCount() == 0, "the walk must be refused BEFORE any element is read")
}

@Test
func axFind_onOwnProcessFrontmost_refusesWithoutReadingOneElement() async throws {
    let source = _SelfPidAXSource(pid: getpid())
    let result = try await _client(source).dispatch(
        action: "ax_find", body: ["title": .string("Send")]
    )

    #expect(!result.ok)
    #expect(result.error == SwiftNativeMacControl.selfInspectionError)
    #expect(source.readCount() == 0)
}

@Test
func look_onOwnProcessFrontmost_refusesWithTheNamedReason() async throws {
    let source = _SelfPidAXSource(pid: getpid())
    let result = try await _client(source).dispatch(
        action: "look", body: ["grade": .string("look")]
    )

    #expect(!result.ok)
    #expect(result.error == SwiftNativeMacControl.selfInspectionError)
    #expect(source.readCount() == 0)
}

@Test
func view_onOwnProcessFrontmost_degradesToPixelsAndSaysWhy() async throws {
    let source = _SelfPidAXSource(pid: getpid())
    let result = try await _client(source).dispatch(action: "view", body: [:])

    // The view itself still answers (pixels-only degrade, like untrusted AX);
    // what it must never do is walk our own tree.
    #expect(source.readCount() == 0)
    let output = _object(result.output)
    #expect(
        output["accessibility_note"] == .string(SwiftNativeMacControl.selfInspectionNote),
        "the payload must name the self-inspection refusal: \(output)"
    )
}

// MARK: - The pid-anchored branch, and the positive control

@Test
func anchoredSnapshot_pidAnchoredToSelf_refusesBeforeResolvingAnything() async {
    let source = _SelfPidAXSource(pid: getpid())
    let client = _client(source)

    // The synthetic source WOULD answer this walk (positive control below
    // proves it) — `.selfProcess` here means the guard fired first.
    let anchored = await client.anchoredSnapshot(
        limits: MacAXLimits(), pid: getpid(), window: nil
    )
    guard case .selfProcess = anchored else {
        Issue.record("pid == getpid() must refuse as .selfProcess, got \(anchored)")
        return
    }
    #expect(source.readCount() == 0)
}

// MARK: - The injection lane

/// Records every call; the fences hold only if it is NEVER touched on a
/// self-process target.
private final class _RecordingActSource: MacAXActSource, @unchecked Sendable {
    private let lock = NSLock()
    private var callLog: [String] = []
    var raiseDiagnostic: String? { nil }

    private func note(_ call: String) {
        lock.lock(); defer { lock.unlock() }
        callLog.append(call)
    }
    func isTrusted() -> Bool { true }
    func resolve(path: [Int]) -> MacAXActTarget? { note("resolve"); return nil }
    func resolve(path: [Int], inAppPid pid: Int32) -> MacAXPidResolution {
        note("resolve_pid"); return .appGone
    }
    func perform(_ target: MacAXActTarget, action: String) -> MacAXActOutcome {
        note("perform"); return .unsupported
    }
    func setValue(_ target: MacAXActTarget, value: String) -> MacAXActOutcome {
        note("setValue"); return .unsupported
    }
    func reread(_ target: MacAXActTarget) -> MacAXActTarget? { note("reread"); return nil }
    func calls() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return callLog
    }
}

@Test
func act_onAFrameNamingOurOwnPid_refusesBeforeAnyActuatorCall() async throws {
    // Only a store populated BEFORE the self-inspection fence shipped can hold
    // such a frame — the guard must still kill it before `windows(pid:)`.
    let source = _SelfPidAXSource(pid: getpid())
    let actSource = _RecordingActSource()
    let store = MacLookFrameStore()
    await store.record(MacLookFrame(
        frameId: "F1",
        capturedAt: Date(),
        appName: "NativeAgent",
        bundleId: "test.nativeagent.self",
        windowTitle: "Chat",
        entries: ["h1": MacLookFrameEntry(
            handle: "h1", path: [0], role: "AXButton", label: "Send",
            frame: MacAXFrame(x: 10, y: 20, w: 60, h: 24)
        )],
        pid: getpid()
    ))
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        accessibilityActSource: actSource,
        screenCaptureSource: _SelfStubCapture(),
        lookFrameStore: store
    )
    let result = try await client.dispatch(action: "act", body: [
        "verb": .string("click"), "handle": .string("h1"), "frame_id": .string("F1"),
    ])

    #expect(!result.ok)
    #expect(result.error == SwiftNativeMacControl.selfInspectionError)
    #expect(actSource.calls().isEmpty, "no actuator call may start against our own pid")
}

@Test
func axAct_whenOurOwnAppIsFrontmost_refusesWithTheNamedReason() async throws {
    let source = _SelfPidAXSource(pid: getpid())
    let actSource = _RecordingActSource()
    let client = SwiftNativeMacControl(
        accessibilitySource: source,
        accessibilityActSource: actSource,
        screenCaptureSource: _SelfStubCapture(),
        lookFrameStore: MacLookFrameStore()
    )
    let result = try await client.dispatch(action: "ax_act", body: [
        "path": .array([.int(0)]),
    ])

    #expect(!result.ok)
    #expect(result.error == SwiftNativeMacControl.selfInspectionError)
    #expect(actSource.calls().isEmpty)
}

@Test
func axTree_onAnotherProcess_stillWalks_provingTheFenceKeysOnPid() async throws {
    // Same tree, same handlers, only the pid differs — the fence must key on
    // the pid, never blanket-refuse.
    let source = _SelfPidAXSource(pid: 4242)
    let result = try await _client(source).dispatch(action: "ax_tree", body: [:])

    #expect(result.ok)
    #expect(source.readCount() > 0, "a non-self read must actually walk")
}
