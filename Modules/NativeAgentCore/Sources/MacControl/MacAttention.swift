import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(AppKit) && os(macOS)
import AppKit
#endif
#if canImport(CoreGraphics) && os(macOS)
import CoreGraphics
#endif

// MARK: - Ephemeral, explicit computer attention

/// Identifies input synthesized by NativeAgent itself.
///
/// The passive attention monitor sees events at the same system boundary as
/// physical input. Tagging our own events lets it distinguish "the agent moved the
/// pointer" from "the person moved the pointer" without suppressing or
/// intercepting either one. The tag contains no user data and never leaves the
/// process.
enum NativeAgentMacEventIdentity {
    static let sourceUserData: Int64 = 0x4E_41_54_49_56_45 // "NATIVE"
}

/// Bounded, process-local provenance for UI changes caused by NativeAgent's
/// own motor output. ActivityWatch consumes only this timestamp seam; it does
/// not gain a scheduler, store, or dependency on an attention session.
public enum NativeAgentMotorEpoch {
    public static let defaultWindow: TimeInterval = 3
    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastAgentMotorUptime = -Double.infinity

    public static func noteAgentMotorEvent(
        atUptime uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard uptime.isFinite else { return }
        lock.lock()
        lastAgentMotorUptime = max(lastAgentMotorUptime, uptime)
        lock.unlock()
    }

    public static func isAgentDriven(
        atUptime uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        window: TimeInterval = defaultWindow
    ) -> Bool {
        guard uptime.isFinite, window >= 0 else { return false }
        lock.lock()
        let last = lastAgentMotorUptime
        lock.unlock()
        return uptime >= last && uptime - last <= window
    }

    static func resetForTesting() {
        lock.lock()
        lastAgentMotorUptime = -Double.infinity
        lock.unlock()
    }
}

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

/// Opaque lifetime token for the system observers installed only while an
/// explicit attention session is active.
public protocol MacAttentionObservation: AnyObject, Sendable {
    func stop()
}

/// Injectable passive event source. It never suppresses, edits, or records key
/// contents. Tests use a manual source; production uses local/global AppKit
/// monitors and an app-activation notification.
public protocol MacAttentionEventSource: Sendable {
    var isAvailable: Bool { get }
    func start(
        handler: @escaping @Sendable (MacAttentionActivity) -> Void
    ) -> any MacAttentionObservation
}

private final class UnavailableMacAttentionObservation: MacAttentionObservation, @unchecked Sendable {
    func stop() {}
}

public struct UnavailableMacAttentionEventSource: MacAttentionEventSource {
    public init() {}
    public var isAvailable: Bool { false }
    public func start(
        handler: @escaping @Sendable (MacAttentionActivity) -> Void
    ) -> any MacAttentionObservation {
        _ = handler
        return UnavailableMacAttentionObservation()
    }
}

#if canImport(AppKit) && canImport(CoreGraphics) && os(macOS)

private final class SystemMacAttentionObservation: MacAttentionObservation, @unchecked Sendable {
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

private final class MacAttentionEventCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPointerEmission = Date.distantPast
    private let minimumPointerInterval: TimeInterval = 1.0 / 30.0

    func shouldEmit(kind: MacAttentionActivityKind, at date: Date) -> Bool {
        guard kind == .pointerMoved || kind == .pointerDragged else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard date.timeIntervalSince(lastPointerEmission) >= minimumPointerInterval else {
            return false
        }
        lastPointerEmission = date
        return true
    }
}

/// Event-driven production observer. It exists only for the bounded lifetime
/// of an explicit attention session; there is no timer, frame loop, or ambient
/// persistence. Keyboard events are reduced to an activity pulse before they
/// cross this seam — keycode, modifiers, and text are never retained.
public struct SystemMacAttentionEventSource: MacAttentionEventSource {
    public init() {}
    public var isAvailable: Bool { true }

    public func start(
        handler: @escaping @Sendable (MacAttentionActivity) -> Void
    ) -> any MacAttentionObservation {
        let install: () -> SystemMacAttentionObservation = {
            let coalescer = MacAttentionEventCoalescer()
            let mask: NSEvent.EventTypeMask = [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseUp, .rightMouseUp, .otherMouseUp,
                .scrollWheel, .keyDown, .flagsChanged,
            ]

            func activity(from event: NSEvent) -> MacAttentionActivity? {
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                    == NativeAgentMacEventIdentity.sourceUserData {
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
                guard coalescer.shouldEmit(kind: kind, at: date) else { return nil }
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
    // Never install global monitors in a test runner. Focused tests inject a
    // manual source and therefore cannot observe or interfere with the host.
    if NSClassFromString("XCTestCase") != nil {
        return UnavailableMacAttentionEventSource()
    }
    #if canImport(AppKit) && canImport(CoreGraphics) && os(macOS)
    return SystemMacAttentionEventSource()
    #else
    return UnavailableMacAttentionEventSource()
    #endif
}

public struct MacAttentionSnapshot: Sendable, Equatable {
    public let sessionId: String
    public let startedAt: Date
    public let expiresAt: Date
    public let sequence: Int64
    public let observedSequence: Int64
    public let userSequence: Int64
    public let observedUserSequence: Int64
    public let counts: [MacAttentionActivityKind: Int]
    public let lastActivity: MacAttentionActivity?
    public let latestViewId: String?
    public let timedOutWaiting: Bool

    public var yieldRequired: Bool { userSequence > observedUserSequence }
    public var refreshRequired: Bool { sequence > observedSequence }

    public func toJSON() -> JSONValue {
        let formatter = ISO8601DateFormatter()
        var countObject: [String: JSONValue] = [:]
        for kind in MacAttentionActivityKind.allCases {
            countObject[kind.rawValue] = .int(Int64(counts[kind, default: 0]))
        }
        var object: [String: JSONValue] = [
            "active": .bool(true),
            "session": .string(sessionId),
            "started_at": .string(formatter.string(from: startedAt)),
            "expires_at": .string(formatter.string(from: expiresAt)),
            "sequence": .int(sequence),
            "observed_sequence": .int(observedSequence),
            "user_sequence": .int(userSequence),
            "observed_user_sequence": .int(observedUserSequence),
            "yield_required": .bool(yieldRequired),
            "refresh_required": .bool(refreshRequired),
            "counts": .object(countObject),
            "view": latestViewId.map { .string($0) } ?? .null,
            "wait_timed_out": .bool(timedOutWaiting),
        ]
        if let lastActivity {
            var activity: [String: JSONValue] = [
                "kind": .string(lastActivity.kind.rawValue),
                "at": .string(formatter.string(from: lastActivity.occurredAt)),
            ]
            if let x = lastActivity.pointerX, let y = lastActivity.pointerY {
                activity["pointer"] = .object(["x": .double(x), "y": .double(y)])
            }
            object["last_activity"] = .object(activity)
        } else {
            object["last_activity"] = .null
        }
        return .object(object)
    }
}

public enum MacAttentionActionPermission: Sendable, Equatable {
    case allowed
    case refused(reason: String, current: MacAttentionSnapshot)
}

/// The one ephemeral owner of a bounded attention session.
///
/// It stores no screenshots, text, key contents, history, or persona state.
/// It only holds the current session token, coarse activity counters, and the
/// last fused-view id. Stop/expiry tears down every observer and forgets all of
/// it, making rollback immediate and complete.
public actor MacAttentionSessionStore {
    public static let shared = MacAttentionSessionStore(screenViewStore: .shared)

    public static let defaultDurationSeconds = 300
    public static let minimumDurationSeconds = 15
    public static let maximumDurationSeconds = 1_800
    public static let maximumWaitMilliseconds = 15_000

    private struct Session {
        let id: String
        let startedAt: Date
        let expiresAt: Date
        var sequence: Int64 = 0
        var observedSequence: Int64 = 0
        var userSequence: Int64 = 0
        var observedUserSequence: Int64 = 0
        var counts: [MacAttentionActivityKind: Int] = [:]
        var lastActivity: MacAttentionActivity?
        var latestViewId: String?
    }

    private struct Waiter {
        let after: Int64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let screenViewStore: MacScreenViewStore
    private var session: Session?
    private var observation: (any MacAttentionObservation)?
    private var expiryTask: Task<Void, Never>?
    private var waiters: [UUID: Waiter] = [:]

    public init(screenViewStore: MacScreenViewStore) {
        self.screenViewStore = screenViewStore
    }

    deinit {
        observation?.stop()
        expiryTask?.cancel()
        for waiter in waiters.values { waiter.continuation.resume() }
    }

    @discardableResult
    public func start(
        durationSeconds: Int,
        now: Date,
        eventSource: any MacAttentionEventSource
    ) async -> MacAttentionSnapshot? {
        stopInternal()
        await screenViewStore.invalidate()
        guard eventSource.isAvailable else { return nil }
        let duration = max(
            Self.minimumDurationSeconds,
            min(durationSeconds, Self.maximumDurationSeconds)
        )
        let id = UUID().uuidString
        let expiresAt = now.addingTimeInterval(TimeInterval(duration))
        session = Session(id: id, startedAt: now, expiresAt: expiresAt)
        observation = eventSource.start { [weak self] activity in
            Task { await self?.record(activity) }
        }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await self?.expire(sessionId: id)
        }
        return snapshot(timedOutWaiting: false)
    }

    public func status(now: Date) async -> MacAttentionSnapshot? {
        await expireIfNeeded(now: now)
        return snapshot(timedOutWaiting: false)
    }

    @discardableResult
    public func stop() async -> Bool {
        let wasActive = session != nil
        stopInternal()
        await screenViewStore.invalidate()
        return wasActive
    }

    public func waitForActivity(
        sessionId: String,
        after sequence: Int64,
        timeoutMilliseconds: Int,
        now: Date
    ) async -> MacAttentionSnapshot? {
        await expireIfNeeded(now: now)
        guard session?.id == sessionId else { return nil }
        let waitMs = max(0, min(timeoutMilliseconds, Self.maximumWaitMilliseconds))
        var timedOut = false
        if session?.sequence ?? 0 <= sequence, waitMs > 0 {
            timedOut = await suspendUntilActivity(after: sequence, timeoutMilliseconds: waitMs)
        }
        await expireIfNeeded(now: Date())
        guard session?.id == sessionId else { return nil }
        return snapshot(timedOutWaiting: timedOut)
    }

    /// Marks one freshly captured fused view as the scene observed after all
    /// user activity up through `userSequence`.
    public func observed(
        sessionId: String,
        viewId: String,
        sequence: Int64,
        userSequence: Int64,
        now: Date
    ) async -> MacAttentionSnapshot? {
        await expireIfNeeded(now: now)
        guard var current = session, current.id == sessionId else { return nil }
        current.latestViewId = viewId
        current.observedSequence = min(current.sequence, max(0, sequence))
        current.observedUserSequence = min(current.userSequence, max(0, userSequence))
        session = current
        return snapshot(timedOutWaiting: false)
    }

    /// Rechecked before every emitted motor event. This is the effect-time
    /// human-takeover boundary, not merely a tool-entry check.
    public func permissionForAction(
        sessionId: String?,
        observedUserSequence: Int64?,
        now: Date
    ) async -> MacAttentionActionPermission {
        await expireIfNeeded(now: now)
        guard let current = session else { return .allowed }
        guard sessionId == current.id else {
            return .refused(
                reason: "attention_session_required: an explicit Mac attention session is active; "
                    + "act with its session and latest observed user sequence, or stop it",
                current: snapshot(timedOutWaiting: false)!
            )
        }
        if observedUserSequence != current.userSequence
            || current.observedUserSequence != current.userSequence {
            return .refused(
                reason: "human_takeover: physical user input occurred after the agent's last fused view; "
                    + "yield and call mac_attention next before acting again",
                current: snapshot(timedOutWaiting: false)!
            )
        }
        guard current.observedSequence == current.sequence,
              current.latestViewId != nil else {
            return .refused(
                reason: "scene_changed: the active app or screen changed after the agent's last fused view; "
                    + "call mac_attention next before acting again",
                current: snapshot(timedOutWaiting: false)!
            )
        }
        return .allowed
    }

    private func record(_ activity: MacAttentionActivity) async {
        guard var current = session else { return }
        if activity.occurredAt >= current.expiresAt {
            stopInternal()
            await screenViewStore.invalidate()
            return
        }
        current.sequence += 1
        if activity.kind.isPhysicalUserInput { current.userSequence += 1 }
        current.counts[activity.kind, default: 0] += 1
        current.lastActivity = activity
        session = current

        // The frozen marks no longer describe the same scene. Physical input
        // additionally invokes human takeover; app activation requires a
        // refresh without falsely claiming the human caused it.
        await screenViewStore.invalidate()
        resumeReadyWaiters(sequence: current.sequence)
    }

    private func snapshot(timedOutWaiting: Bool) -> MacAttentionSnapshot? {
        guard let current = session else { return nil }
        return MacAttentionSnapshot(
            sessionId: current.id,
            startedAt: current.startedAt,
            expiresAt: current.expiresAt,
            sequence: current.sequence,
            observedSequence: current.observedSequence,
            userSequence: current.userSequence,
            observedUserSequence: current.observedUserSequence,
            counts: current.counts,
            lastActivity: current.lastActivity,
            latestViewId: current.latestViewId,
            timedOutWaiting: timedOutWaiting
        )
    }

    /// Returns true when the wait ended only because the deadline elapsed.
    private func suspendUntilActivity(after sequence: Int64, timeoutMilliseconds: Int) async -> Bool {
        let id = UUID()
        let before = session?.sequence ?? sequence
        let owner = self
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if session == nil || (session?.sequence ?? 0) > sequence {
                    continuation.resume()
                    return
                }
                waiters[id] = Waiter(after: sequence, continuation: continuation)
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                    await self?.resumeWaiter(id: id)
                }
            }
        } onCancel: {
            Task { await owner.resumeWaiter(id: id) }
        }
        return (session?.sequence ?? before) <= sequence
    }

    private func resumeWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func resumeReadyWaiters(sequence: Int64) {
        let ids = waiters.compactMap { id, waiter in waiter.after < sequence ? id : nil }
        for id in ids { resumeWaiter(id: id) }
    }

    private func expire(sessionId: String) async {
        guard session?.id == sessionId else { return }
        stopInternal()
        await screenViewStore.invalidate()
    }

    private func expireIfNeeded(now: Date) async {
        guard let current = session, now >= current.expiresAt else { return }
        stopInternal()
        await screenViewStore.invalidate()
    }

    private func stopInternal() {
        observation?.stop()
        observation = nil
        expiryTask?.cancel()
        expiryTask = nil
        session = nil
        let continuations = waiters.values.map(\.continuation)
        waiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
