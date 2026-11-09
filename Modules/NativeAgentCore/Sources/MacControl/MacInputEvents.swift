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

// Blueprint: | `MacInputEvents.swift` | Per-event driver and target Write checks; reading and held-input release remain available |

/// Centralized emission keeps synthesized input under one authority boundary.
public protocol MacEventSink: Sendable {
    /// Unsupported sinks refuse rather than claim a no-op succeeded.
    var isAvailable: Bool { get }
    /// Secure Keyboard Entry silently drops synthesized keys despite successful posting; gate keys while leaving mouse and scroll usable.
    var secureKeyboardEntryActive: Bool { get }
    func post(key: MacKeyEvent, turn: Turn, context: MacOperationContext)
    func post(mouse: MacMouseEvent, turn: Turn, context: MacOperationContext, routingToken: Int64?) -> Bool
    func post(scroll: MacScrollEvent, turn: Turn, context: MacOperationContext, routingToken: Int64?) -> Bool
    /// Per-process delivery must not depend on which window owns the keyboard.
    func post(key: MacKeyEvent, toPid pid: Int32, turn: Turn, context: MacOperationContext) -> Bool
}

public extension MacEventSink {
    /// Unknown secure-input state must not become an invented true that blocks keys indefinitely.
    var secureKeyboardEntryActive: Bool { false }
    /// Missing per-process delivery must not redirect input into the global key window.
    func post(key: MacKeyEvent, toPid pid: Int32, turn: Turn, context: MacOperationContext) -> Bool { false }

    func send(key: MacKeyEvent, toPid pid: Int32? = nil, turn: Turn, context: MacOperationContext) async throws -> Bool {
        if let pid { return post(key: key, toPid: pid, turn: turn, context: context) }
        if key.down { try await waitForPersonKeyboard(context: context) }
        guard !key.down || context.driver?.allowsEmission(context: context) == true else { return false }
        post(key: key, turn: turn, context: context)
        return true
    }

    func send(mouse: MacMouseEvent, turn: Turn, context: MacOperationContext) async throws {
        try await PersonOnlyWindows.withAgentPointer(at: CGPoint(x: mouse.x, y: mouse.y), driver: turn.windowDriver) { connections in
            try await MacInputRouting.post(connections: connections) { token in
                self.post(mouse: mouse, turn: turn, context: context, routingToken: token)
            }
        }
    }

    func send(scroll: MacScrollEvent, turn: Turn, context: MacOperationContext) async throws {
        guard let point = AgentPointerHold.lastAgentPoint ?? SystemMacPointerPositionSource().currentPosition().map({ CGPoint(x: $0.x, y: $0.y) }) else {
            throw PersonOnlyWindows.MotorFailure(detail: "The pointer position is unavailable; no scroll was posted.")
        }
        try await PersonOnlyWindows.withAgentPointer(at: point, driver: turn.windowDriver) { connections in
            try await MacInputRouting.post(connections: connections) { token in
                self.post(scroll: scroll, turn: turn, context: context, routingToken: token)
            }
        }
    }
}

private func waitForPersonKeyboard(context: MacOperationContext) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await PersonOnlyWindows.waitForKeyboard()
        }
        group.addTask {
            for await _ in await MacAttentionSessionStore.shared.driverChanges() {
                guard context.driver?.allowsEmission(context: context) == true else {
                    throw PersonOnlyWindows.MotorFailure(detail: "Mac driver authority ended while waiting for the person's keyboard.")
                }
            }
            throw PersonOnlyWindows.MotorFailure(detail: "The Mac driver owner shut down while waiting for the person's keyboard.")
        }
        defer { group.cancelAll() }
        _ = try await group.next()
    }
    try Task.checkCancellation()
}

/// Every post checks the operation’s explicit driver; release authority covers only inputs this act pressed.
struct DriverCheckedMacEventSink: MacEventSink {
    let base: any MacEventSink
    var isAvailable: Bool { base.isAvailable }
    var secureKeyboardEntryActive: Bool { base.secureKeyboardEntryActive }

    func post(key event: MacKeyEvent, turn: Turn, context: MacOperationContext) {
        guard let binding = context.driver, binding.allowsEmission(context: context) else { return }
        if event.down, !MacAppActGate.admit(MacAppActGate.frontRefusal(context: context), context: context) { return }
        base.post(key: event, turn: turn, context: context)
        guard binding.appActRefusal == nil else { return }
        binding.notePostedEvent(turn: turn)
        let key = "key:\(event.keyCode)"
        if event.down {
            binding.held(key, context: context, release: { [base] in
                base.post(key: MacKeyEvent(keyCode: event.keyCode, down: false), turn: turn, context: context)
            })
        } else { binding.held(key, context: context, release: nil) }
    }

    func post(key event: MacKeyEvent, toPid pid: Int32, turn: Turn, context: MacOperationContext) -> Bool {
        guard let binding = context.driver, binding.allowsAction(context: context),
              base.post(key: event, toPid: pid, turn: turn, context: context) else { return false }
        guard binding.appActRefusal == nil else { return false }
        binding.notePostedEvent(turn: turn)
        let key = "pid:\(pid):\(event.keyCode)"
        if event.down {
            binding.held(key, context: context, release: { [base] in
                _ = base.post(key: MacKeyEvent(keyCode: event.keyCode, down: false), toPid: pid, turn: turn, context: context)
            })
        } else { binding.held(key, context: context, release: nil) }
        return true
    }

    func post(mouse event: MacMouseEvent, turn: Turn, context: MacOperationContext, routingToken: Int64?) -> Bool {
        guard let binding = context.driver, binding.allowsEmission(context: context),
              base.post(mouse: event, turn: turn, context: context, routingToken: routingToken) else { return false }
        binding.notePostedEvent(turn: turn)
        let key = "mouse:\(event.button)"
        if event.phase == .down {
            binding.held(key, context: context, release: { [base] in
                guard let point = SystemMacPointerPositionSource().currentPosition() else { return }
                _ = base.post(mouse: MacMouseEvent(phase: .up, button: event.button, x: point.x, y: point.y),
                    turn: turn, context: context, routingToken: nil)
            })
        } else if event.phase == .up { binding.held(key, context: context, release: nil) }
        return true
    }

    func post(scroll event: MacScrollEvent, turn: Turn, context: MacOperationContext, routingToken: Int64?) -> Bool {
        guard let binding = context.driver, binding.allowsEmission(context: context),
              base.post(scroll: event, turn: turn, context: context, routingToken: routingToken) else { return false }
        binding.notePostedEvent(turn: turn)
        return true
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

    public func post(key event: MacKeyEvent, toPid pid: Int32, turn: Turn, context: MacOperationContext) -> Bool {
        guard pid > 0, !PersonOnlyWindows.isOwnProcess(pid), let cg = keyEvent(event) else { return false }
        guard !event.down || MacAppActGate.admit(MacAppActGate.refusal(pid: pid, looking: context.looking, context: context),
            context: context) else { return false }
        NativeAgentMotorEpoch.noteAgentMotorEvent()
        MacPersonInput.noteAgentPost(targeted: true)
        cg.postToPid(pid)
        return true
    }

    public func post(key event: MacKeyEvent, turn: Turn, context: MacOperationContext) {
        guard let cg = keyEvent(event) else { return }
        emitNative(cg, context: context)
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

    /// Prepare both halves before mutating clipboard or composer; retain the operation’s original driver binding.
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

    package func postNative(_ event: CGEvent, context: MacOperationContext) async throws {
        switch event.type {
        case .keyDown:
            try await waitForPersonKeyboard(context: context)
            guard emitTrackedNative(event, context: context) else {
                throw PersonOnlyWindows.MotorFailure(detail: "Key emission was refused after the keyboard hold ended; no key was posted.")
            }
        case .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel:
            try await PersonOnlyWindows.withAgentPointer(at: event.location) { connections in
                try await MacInputRouting.post(connections: connections) { token in
                    event.setIntegerValueField(.eventSourceUserData, value: token)
                    return emitTrackedNative(event, context: context)
                }
            }
        default: emitTrackedNative(event, context: context)
        }
    }

    @discardableResult private func emitTrackedNative(_ event: CGEvent, context: MacOperationContext) -> Bool {
        guard emitNative(event, context: context) else { return false }
        guard let binding = context.driver else { return true }
        let button: MacMouseButton
        switch event.type {
        case .keyDown, .keyUp:
            let code = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
            let key = "key:\(code)"
            if event.type == .keyDown {
                binding.held(key, context: context, release: {
                    guard let release = self.keyEvent(.init(keyCode: code, down: false)) else { return }
                    self.emitNative(release, context: context)
                })
            } else { binding.held(key, context: context, release: nil) }
            return true
        case .leftMouseDown, .leftMouseUp: button = .left
        case .rightMouseDown, .rightMouseUp: button = .right
        default: return true
        }
        let key = "mouse:\(button)"
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let point = event.location
            binding.held(key, context: context, release: {
                guard let release = self.mouseEvent(.init(phase: .up, button: button, x: point.x, y: point.y)) else { return }
                self.emitNative(release, context: context)
            })
        } else { binding.held(key, context: context, release: nil) }
        return true
    }

    @discardableResult private func emitNative(_ event: CGEvent, context: MacOperationContext) -> Bool {
        switch event.type {
        case .keyUp, .leftMouseUp, .rightMouseUp, .otherMouseUp: break
        default: guard context.driver?.allowsEmission(context: context) == true else { return false }
        }
        // Releases must settle held input even after a switch change; only agent-synthesized input enters here.
        let refusal: MacAppActRefusal?
        switch event.type {
        case .keyDown: refusal = MacAppActGate.frontRefusal(context: context)
        case .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            refusal = MacAppActGate.pointRefusal(x: event.location.x, y: event.location.y, context: context)
        default: refusal = nil
        }
        guard MacAppActGate.admit(refusal, context: context) else { return false }
        NativeAgentMotorEpoch.notePostedHIDEvent()
        event.post(tap: .cghidEventTap)
        return true
    }

    public func post(mouse event: MacMouseEvent, turn: Turn, context: MacOperationContext, routingToken: Int64?) -> Bool {
        let point = CGPoint(x: event.x, y: event.y)
        guard let cg = mouseEvent(event) else { return false }
        if let routingToken { cg.setIntegerValueField(.eventSourceUserData, value: routingToken) }
        AgentPointerHold.begin(warpTo: nil)
        let posted = emitNative(cg, context: context)
        AgentPointerHold.posted(phase: event.phase, button: event.button, at: point, emitted: posted)
        return posted
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
        // Await modifier key-down before creating the dependent event; preserve genuine HID flags.
        cg.flags.formUnion(flags(event.modifiers))
        // Tag every pointer event so idle-clock consumers can distinguish agent input from the person's activity.
        return cg
    }

    public func post(scroll event: MacScrollEvent, turn: Turn, context: MacOperationContext, routingToken: Int64?) -> Bool {
        let units: CGScrollEventUnit = event.unit == .pixel ? .pixel : .line
        // Scroll follows the cursor, so restore the agent’s point after returning the person’s cursor.
        let scrollPoint = AgentPointerHold.begin(warpTo: AgentPointerHold.lastAgentPoint)
        var posted = false
        defer { scrollPoint.map { AgentPointerHold.posted(phase: nil, at: $0, emitted: posted) } }
        guard let cg = CGEvent(
            scrollWheelEvent2Source: source(),
            units: units,
            wheelCount: 2,
            wheel1: event.deltaY,
            wheel2: event.deltaX,
            wheel3: 0
        ) else { return false }
        cg.setIntegerValueField(
            .eventSourceUserData,
            value: NativeAgentMacEventIdentity.sourceUserData
        )
        cg.flags.formUnion(flags(event.modifiers))
        if let routingToken { cg.setIntegerValueField(.eventSourceUserData, value: routingToken) }
        posted = emitNative(cg, context: context)
        return posted
    }
}

#endif

/// Unsupported platforms report unavailability rather than a silent no-op.
public struct UnavailableMacEventSink: MacEventSink {
    public init() {}
    public var isAvailable: Bool { false }
    public func post(key: MacKeyEvent, turn: Turn, context: MacOperationContext) {}
    public func post(mouse: MacMouseEvent, turn: Turn, context: MacOperationContext, routingToken: Int64?) -> Bool { false }
    public func post(scroll: MacScrollEvent, turn: Turn, context: MacOperationContext, routingToken: Int64?) -> Bool { false }
}

public func defaultMacEventSink() -> any MacEventSink {
    #if canImport(CoreGraphics) && os(macOS)
    return CGEventSink()
    #else
    return UnavailableMacEventSink()
    #endif
}
