import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon) && os(macOS)
import Carbon
#endif

// Blueprint: | `MacInputEvents.swift` | `MacEventSink`, `DriverCheckedMacEventSink` and `CGEventSink`: driver-checked input, native event preparation and HID/per-process emission |

/// The ONLY route to synthesized input in this module. Tests inject a recorder
/// so the whole executor is exercised without moving the real cursor.
public protocol MacEventSink: Sendable {
    /// False when this build/platform cannot synthesize events at all. The
    /// handlers then refuse honestly instead of reporting a no-op as success.
    var isAvailable: Bool { get }
    /// True while macOS SECURE KEYBOARD ENTRY is on anywhere on this Mac.
    ///
    /// This is not an availability question — the sink is perfectly able to
    /// post, and `CGEvent.post` returns nothing to say otherwise. The window
    /// server simply does not DELIVER synthesized keystrokes while secure
    /// input is enabled, so a keyboard site that posts anyway types into a
    /// void and the closed loop reports an unexplained unchanged screen.
    /// Keyboard only: mouse and scroll are unaffected and stay ungated.
    var secureKeyboardEntryActive: Bool { get }
    func post(key: MacKeyEvent)
    func post(mouse: MacMouseEvent)
    func post(scroll: MacScrollEvent)
    /// Address one process with CGEvent.postToPid, independently of the key window; false means not sent.
    func post(key: MacKeyEvent, toPid pid: Int32) -> Bool
}

public extension MacEventSink {
    /// A sink that cannot measure it must not INVENT it: an unmeasured `true`
    /// would refuse every keystroke forever.
    var secureKeyboardEntryActive: Bool { false }
    /// A sink with no per-process route says so; it never falls back to the
    /// global post, which would type into the key window.
    func post(key: MacKeyEvent, toPid pid: Int32) -> Bool { false }
}

/// The client's sink checks the inherited driver at every post. The binding
/// retains only releases for inputs this act actually pressed.
struct DriverCheckedMacEventSink: MacEventSink {
    let base: any MacEventSink
    var isAvailable: Bool { base.isAvailable }
    var secureKeyboardEntryActive: Bool { base.secureKeyboardEntryActive }

    func post(key event: MacKeyEvent) {
        guard !event.down || Self.waitWhilePersonTypes(), let binding = MacDriverContext.binding, binding.allowsEmission else { return }
        base.post(key: event)
        binding.notePostedEvent()
        let key = "key:\(event.keyCode)"
        if event.down {
            binding.held(key, release: { [base] in
                base.post(key: MacKeyEvent(keyCode: event.keyCode, down: false))
            })
        } else { binding.held(key, release: nil) }
    }

    /// Global key-down waits while the person owns Shotgun's keyboard; key-up and per-process input never wait, and the main thread never blocks.
    static func waitWhilePersonTypes() -> Bool {
        while PersonOnlyWindows.keyboardHeldByPerson {
            guard !Thread.isMainThread, !Task.isCancelled,
                  MacDriverContext.binding?.allowsEmission == true else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    func post(key event: MacKeyEvent, toPid pid: Int32) -> Bool {
        guard let binding = MacDriverContext.binding, binding.allowsAction,
              base.post(key: event, toPid: pid) else { return false }
        binding.notePostedEvent()
        let key = "pid:\(pid):\(event.keyCode)"
        if event.down {
            binding.held(key, release: { [base] in
                _ = base.post(key: MacKeyEvent(keyCode: event.keyCode, down: false), toPid: pid)
            })
        } else { binding.held(key, release: nil) }
        return true
    }

    func post(mouse event: MacMouseEvent) {
        guard let binding = MacDriverContext.binding, binding.allowsEmission else { return }
        base.post(mouse: event)
        binding.notePostedEvent()
        let key = "mouse:\(event.button)"
        if event.phase == .down {
            binding.held(key, release: { [base] in
                guard let point = SystemMacPointerPositionSource().currentPosition() else { return }
                base.post(mouse: MacMouseEvent(phase: .up, button: event.button, x: point.x, y: point.y))
            })
        } else if event.phase == .up { binding.held(key, release: nil) }
    }

    func post(scroll event: MacScrollEvent) {
        guard let binding = MacDriverContext.binding, binding.allowsEmission else { return }
        base.post(scroll: event)
        binding.notePostedEvent()
    }
}

#if canImport(CoreGraphics) && os(macOS)

/// Live HID-tap emission requires the owner's macOS Accessibility grant; this code never prompts or toggles it.
public struct CGEventSink: MacEventSink {
    public init() {}

    public var isAvailable: Bool { true }

    public var secureKeyboardEntryActive: Bool { MacSecureEventInput.isEnabled() }

    private func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private func flags(_ modifiers: MacKeyModifiers) -> CGEventFlags {
        var out: CGEventFlags = []
        if modifiers.contains(.command) { out.insert(.maskCommand) }
        if modifiers.contains(.shift) { out.insert(.maskShift) }
        if modifiers.contains(.option) { out.insert(.maskAlternate) }
        if modifiers.contains(.control) { out.insert(.maskControl) }
        if modifiers.contains(.function) { out.insert(.maskSecondaryFn) }
        return out
    }

    public func post(key event: MacKeyEvent, toPid pid: Int32) -> Bool {
        guard pid > 0, pid != getpid(), let cg = keyEvent(event) else { return false }
        NativeAgentMotorEpoch.noteAgentMotorEvent()
        MacPersonInput.noteHerPost(targeted: true)
        cg.postToPid(pid)
        return true
    }

    public func post(key event: MacKeyEvent) {
        guard let cg = keyEvent(event) else { return }
        postNative(cg)
    }

    private func keyEvent(_ event: MacKeyEvent) -> CGEvent? {
        guard let cg = CGEvent(
            keyboardEventSource: source(),
            virtualKey: CGKeyCode(event.keyCode),
            keyDown: event.down
        ) else { return nil }
        cg.setIntegerValueField(
            .eventSourceUserData,
            value: NativeAgentMacEventIdentity.sourceUserData
        )
        cg.flags = flags(event.modifiers)
        if let text = event.unicodeText {
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                cg.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        return cg
    }

    /// Prepare both halves before a native client changes the clipboard or
    /// composer. Emission stays under that operation's original driver binding.
    package func keyEvents(_ code: CGKeyCode, flags: CGEventFlags = []) -> [CGEvent]? {
        guard let down = keyEvent(MacKeyEvent(keyCode: code, down: true)),
              let up = keyEvent(MacKeyEvent(keyCode: code, down: false)) else { return nil }
        down.flags = flags; up.flags = flags
        return [down, up]
    }

    package func clickEvents(at point: CGPoint) -> [CGEvent]? {
        guard let down = mouseEvent(MacMouseEvent(phase: .down, button: .left, x: point.x, y: point.y)),
              let up = mouseEvent(MacMouseEvent(phase: .up, button: .left, x: point.x, y: point.y)) else { return nil }
        return [down, up]
    }

    package func postNative(_ event: CGEvent) {
        NativeAgentMotorEpoch.notePostedHIDEvent()
        event.post(tap: .cghidEventTap)
    }

    public func post(mouse event: MacMouseEvent) {
        let point = CGPoint(x: event.x, y: event.y)
        // Her own pointer: the person's mouse is unhooked for her action and
        // their cursor goes back where it was after it.
        AgentPointerHold.begin(warpTo: nil)
        defer { AgentPointerHold.posted(phase: event.phase, at: point) }
        guard let cg = mouseEvent(event) else { return }
        PersonOnlyWindows.beforeAgentPointer(at: point)
        postNative(cg)
    }

    private func mouseEvent(_ event: MacMouseEvent) -> CGEvent? {
        let point = CGPoint(x: event.x, y: event.y)
        let type: CGEventType
        let button: CGMouseButton
        switch (event.phase, event.button) {
        case (.move, _):          type = .mouseMoved;        button = .left
        case (.down, .left):      type = .leftMouseDown;     button = .left
        case (.up, .left):        type = .leftMouseUp;       button = .left
        case (.drag, .left):      type = .leftMouseDragged;  button = .left
        case (.down, .right):     type = .rightMouseDown;    button = .right
        case (.up, .right):       type = .rightMouseUp;      button = .right
        case (.drag, .right):     type = .rightMouseDragged; button = .right
        }
        guard let cg = CGEvent(
            mouseEventSource: source(),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return nil }
        cg.setIntegerValueField(
            .eventSourceUserData,
            value: NativeAgentMacEventIdentity.sourceUserData
        )
        if event.phase != .move {
            cg.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, event.clickCount)))
        }
        // Do not race the asynchronously posted modifier key-down against
        // creation of this event. Preserve any genuine HID flags as before.
        cg.flags.formUnion(flags(event.modifiers))
        // Tag every pointer event so idle-clock consumers can distinguish agent input from the person's activity.
        return cg
    }

    public func post(scroll event: MacScrollEvent) {
        let units: CGScrollEventUnit = event.unit == .pixel ? .pixel : .line
        // A scroll goes where the cursor is: back to her last point first, if
        // the person's cursor had been given back since.
        let scrollPoint = AgentPointerHold.begin(warpTo: AgentPointerHold.lastAgentPoint)
        defer { scrollPoint.map { AgentPointerHold.posted(phase: nil, at: $0) } }
        guard let cg = CGEvent(
            scrollWheelEvent2Source: source(),
            units: units,
            wheelCount: 2,
            wheel1: event.deltaY,
            wheel2: event.deltaX,
            wheel3: 0
        ) else { return }
        cg.setIntegerValueField(
            .eventSourceUserData,
            value: NativeAgentMacEventIdentity.sourceUserData
        )
        cg.flags.formUnion(flags(event.modifiers))
        PersonOnlyWindows.beforeAgentPointer(at: cg.location)
        postNative(cg)
    }
}

#endif

/// Platform fallback: honest unavailability, never a silent no-op success.
public struct UnavailableMacEventSink: MacEventSink {
    public init() {}
    public var isAvailable: Bool { false }
    public func post(key: MacKeyEvent) {}
    public func post(mouse: MacMouseEvent) {}
    public func post(scroll: MacScrollEvent) {}
}

public func defaultMacEventSink() -> any MacEventSink {
    #if canImport(CoreGraphics) && os(macOS)
    return CGEventSink()
    #else
    return UnavailableMacEventSink()
    #endif
}
