import Foundation
import NativeAgentCore
#if canImport(AppKit) && os(macOS)
import AppKit
#endif
#if canImport(CoreGraphics) && os(macOS)
import CoreGraphics
#endif
// Blueprint: | `MacAttentionEvents.swift` | Passive attention activity and observation sources; AppKit monitors share person-input provenance and person-only-window exclusions, retain scene-change events and reduce keyboard events to pulses; pointer coalescing never delays synchronous takeover |

public enum MacAttentionActivityKind: String, Sendable, Equatable, CaseIterable {
    case pointerMoved = "pointer_moved"
    case pointerDragged = "pointer_dragged"
    case pointerPressed = "pointer_pressed"
    case pointerReleased = "pointer_released"
    case scrolled
    case keyboardActivity = "keyboard_activity"
    case appChanged = "app_changed"

    /// App activation is useful scene-change evidence, but it can be caused by
    /// NativeAgent's own click. Physical input is the only signal that invokes
    /// the immediate human-takeover rule.
    var isPhysicalUserInput: Bool { self != .appChanged }
}

public struct MacAttentionActivity: Sendable, Equatable {
    public let kind: MacAttentionActivityKind
    public let occurredAt: Date
    public let pointerX: Double?
    public let pointerY: Double?

    public init(
        kind: MacAttentionActivityKind,
        occurredAt: Date = Date(),
        pointerX: Double? = nil,
        pointerY: Double? = nil
    ) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.pointerX = pointerX
        self.pointerY = pointerY
    }
}

/// Passive event source; never suppresses, edits or records key contents.
/// AppKit monitors and app-activation notifications supply system events.
public protocol MacAttentionEventSource: Sendable {
    var isAvailable: Bool { get }
    func start(
        handler: @escaping @Sendable (MacAttentionActivity) -> Void
    ) -> any MacAXEffectObservation
}

private final class UnavailableMacAttentionObservation: MacAXEffectObservation, @unchecked Sendable {
    func stop() {}
}

public struct UnavailableMacAttentionEventSource: MacAttentionEventSource {
    public init() {}
    public var isAvailable: Bool { false }
    public func start(
        handler: @escaping @Sendable (MacAttentionActivity) -> Void
    ) -> any MacAXEffectObservation {
        _ = handler
        return UnavailableMacAttentionObservation()
    }
}

#if canImport(AppKit) && canImport(CoreGraphics) && os(macOS)

private final class SystemMacAttentionObservation: MacAXEffectObservation, @unchecked Sendable {
    private let lock = NSLock()
    private var eventMonitors: [Any]
    private var workspaceObserver: NSObjectProtocol?
    private var stopped = false

    init(eventMonitors: [Any], workspaceObserver: NSObjectProtocol?) {
        self.eventMonitors = eventMonitors
        self.workspaceObserver = workspaceObserver
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let monitors = eventMonitors
        let observer = workspaceObserver
        eventMonitors.removeAll()
        workspaceObserver = nil
        lock.unlock()

        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    deinit { stop() }
}

final class MacAttentionEventCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPointerEmissionUptime = -Double.infinity
    private let minimumPointerInterval: TimeInterval = 1.0 / 30.0

    func shouldEmit(kind: MacAttentionActivityKind, atUptime uptime: TimeInterval) -> Bool {
        guard kind == .pointerMoved || kind == .pointerDragged else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard uptime - lastPointerEmissionUptime >= minimumPointerInterval else {
            return false
        }
        lastPointerEmissionUptime = uptime
        return true
    }
}

/// Event-driven production observer. Driver ownership outlives a bounded
/// view session; there is no timer, frame loop, or ambient
/// persistence. Keyboard events are reduced to an activity pulse before they
/// cross this seam — keycode, modifiers, and text are never retained.
public struct SystemMacAttentionEventSource: MacAttentionEventSource {
    public init() {}
    public var isAvailable: Bool { true }

    public func start(
        handler: @escaping @Sendable (MacAttentionActivity) -> Void
    ) -> any MacAXEffectObservation {
        let install: () -> SystemMacAttentionObservation = {
            let mask: NSEvent.EventTypeMask = [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseUp, .rightMouseUp, .otherMouseUp,
                .scrollWheel, .keyDown, .flagsChanged,
            ]

            func activity(from event: NSEvent) -> MacAttentionActivity? {
                guard let input = event.cgEvent, MacPersonInput.isPerson(input) else { return nil }
                // While the person's own chat is up, only Stop hands back
                // control; otherwise physical input revokes it immediately.
                if PersonOnlyWindows.isShowing {
                    PersonOnlyWindows.notePersonInput()
                    return nil
                }
                if PersonOnlyWindows.contains(number: event.windowNumber)
                    || (event.type == .mouseMoved
                        && event.cgEvent.map { PersonOnlyWindows.contains(point: $0.location) } == true) {
                    PersonOnlyWindows.notePersonInput()
                    return nil
                }
                let kind: MacAttentionActivityKind
                switch event.type {
                case .mouseMoved: kind = .pointerMoved
                case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .pointerDragged
                case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .pointerPressed
                case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .pointerReleased
                case .scrollWheel: kind = .scrolled
                case .keyDown, .flagsChanged: kind = .keyboardActivity
                default: return nil
                }
                let date = Date()
                var pointerX: Double?
                var pointerY: Double?
                if kind != .keyboardActivity, let cgEvent = event.cgEvent {
                    let point = cgEvent.location
                    pointerX = Double(point.x)
                    pointerY = Double(point.y)
                }
                return MacAttentionActivity(
                    kind: kind,
                    occurredAt: date,
                    pointerX: pointerX,
                    pointerY: pointerY
                )
            }

            var monitors: [Any] = []
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
                if let activity = activity(from: event) { handler(activity) }
            }) {
                monitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
                if let activity = activity(from: event) { handler(activity) }
                return event
            }) {
                monitors.append(local)
            }
            let workspace = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { _ in
                handler(MacAttentionActivity(kind: .appChanged))
            }
            return SystemMacAttentionObservation(
                eventMonitors: monitors,
                workspaceObserver: workspace
            )
        }
        if Thread.isMainThread { return install() }
        return DispatchQueue.main.sync(execute: install)
    }
}

#endif

public func defaultMacAttentionEventSource() -> any MacAttentionEventSource {
    #if canImport(AppKit) && canImport(CoreGraphics) && os(macOS)
    return SystemMacAttentionEventSource()
    #else
    return UnavailableMacAttentionEventSource()
    #endif
}
