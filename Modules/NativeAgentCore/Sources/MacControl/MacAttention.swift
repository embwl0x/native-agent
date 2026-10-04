import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
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

    /// Age of the last agent-synthesized motor event, `.infinity` when there
    /// has been none.
    ///
    /// 2026-09-06: `isAgentDriven` answers a 3 s window, which is useless to a
    /// consumer whose own tick is a minute long — an agent click 30 s ago has
    /// reset the system idle clock and is long out of the window, so the read
    /// came back "human". Comparing this age against the system's
    /// seconds-since-last-input tells the two apart at any cadence.
    public static func secondsSinceLastAgentMotorEvent(
        atUptime uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        lock.lock()
        let last = lastAgentMotorUptime
        lock.unlock()
        guard uptime.isFinite, last.isFinite, uptime >= last else { return .infinity }
        return uptime - last
    }

    /// Walk 3 (09-25): the person check compared the system idle clock with
    /// `lastAgentMotorUptime`, which accessibility actions (raise, press,
    /// focus) also stamp — but those never reset the idle clock. So her own
    /// real click or key, followed within 3 s by a raise or restore, read as
    /// "the person, 1s ago". Only events posted to the HID tap are compared:
    /// measured 09-25, a `postToPid` event leaves the idle clock untouched, so
    /// a stamp for it could only hide the person's own keystroke.
    private nonisolated(unsafe) static var lastPostedHIDUptime = -Double.infinity

    /// Call just before posting an event to the HID tap (`.cghidEventTap`).
    public static func notePostedHIDEvent() {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastPostedHIDUptime = uptime
        lastAgentMotorUptime = max(lastAgentMotorUptime, uptime)
        lock.unlock()
    }

    /// Age of her last HID-tap post, `.infinity` when there has been none.
    static func secondsSinceLastPostedHIDEvent() -> TimeInterval {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let hid = lastPostedHIDUptime
        lock.unlock()
        return hid.isFinite ? uptime - hid : .infinity
    }

    static func resetForTesting() {
        lock.lock()
        lastAgentMotorUptime = -Double.infinity
        lastPostedHIDUptime = -Double.infinity
        lock.unlock()
    }
}

/// Is the person at the keyboard or mouse right now? Recent input can stop
/// an effect; idle time never authorizes bringing an app to the front.
public enum MacPersonInput {
    /// Typing and pointing leave gaps well under this; a chat message sent to
    /// her is older than this by the time her call lands.
    public static let activeWindow: TimeInterval = 3

    /// Our own posted event is noted just before it is posted, so the system's
    /// newest input is ours only when the two ages agree this closely. A human
    /// keystroke seconds after our click is still the human's.
    static let ownEventTolerance: TimeInterval = 0.1

    /// Seconds since the person's last input when that is under `activeWindow`;
    /// nil when they are idle, or the newest input was NativeAgent's own.
    public static func activeSecondsAgo() -> Double? {
        #if canImport(CoreGraphics) && os(macOS)
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null
        )
        guard idle.isFinite, idle >= 0, idle < activeWindow,
              abs(idle - NativeAgentMotorEpoch.secondsSinceLastPostedHIDEvent()) > ownEventTolerance
        else { return nil }
        return idle
        #else
        return nil
        #endif
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

/// Opaque lifetime token for passive driver and attention observation.
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
    ) -> any MacAttentionObservation {
        let install: () -> SystemMacAttentionObservation = {
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
    public let driverAllowed: Bool
    public let driverGeneration: UInt64

    public var yieldRequired: Bool { !driverAllowed || userSequence > observedUserSequence }
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
            "driver": .string(driverAllowed ? "agent" : "user"),
            "driver_generation": .int(Int64(clamping: driverGeneration)),
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
    case refused(reason: String, current: MacAttentionSnapshot?)
}

/// Inherited by an act and all of its effects; observation cannot renew it.
public enum MacDriverContext {
    @TaskLocal public static var binding: MacDriverBinding?
    @TaskLocal static var inputStartCount = 0
}

public final class MacDriverBinding: @unchecked Sendable {
    public let generation: UInt64
    private let owner: MacAttentionSessionStore
    private let lock = NSLock()
    private var cancelled = false
    private var postedEvents = 0
    private var releases: [String: @Sendable () -> Void] = [:]

    init(owner: MacAttentionSessionStore, generation: UInt64) {
        self.owner = owner
        self.generation = generation
    }

    public var allowsEmission: Bool {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        return !stopped && !Task.isCancelled && owner.permitsDriver(generation)
    }

    public var takenOver: Bool { !owner.permitsDriver(generation) }

    var inputCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return postedEvents
    }

    func notePostedEvent() {
        lock.lock()
        postedEvents += 1
        lock.unlock()
        MacWorkContinuation.current?.actionStarted()
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        releaseHeldInputs()
    }

    func held(_ key: String, release: (@Sendable () -> Void)?) {
        lock.lock()
        releases[key] = release
        lock.unlock()
        owner.trackHeldInputs(self)
        if !allowsEmission { releaseHeldInputs() }
    }

    func releaseHeldInputs() {
        lock.lock()
        let pending = Array(releases.values)
        releases.removeAll()
        lock.unlock()
        for release in pending { release() }
    }
}

/// The one ephemeral owner of driver authority and a bounded view session.
///
/// It stores no screenshots, text, key contents, history, or persona state.
/// It holds the driver generation, current session token, coarse activity
/// counters, and last fused-view id. Stop/expiry forgets the view session;
/// only an explicit physical handoff can grant driver authority again.
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
        let timeoutTask: Task<Void, Never>
    }

    private let screenViewStore: MacScreenViewStore
    private let waitSleep: @Sendable (Int) async throws -> Void
    private var session: Session?
    private var observation: (any MacAttentionObservation)?
    private var expiryTask: Task<Void, Never>?
    private var waiters: [UUID: Waiter] = [:]
    private nonisolated let driverLock = NSLock()
    private nonisolated(unsafe) var agentDriving = false
    private nonisolated(unsafe) var driverGeneration: UInt64 = 0
    private nonisolated(unsafe) weak var inputBinding: MacDriverBinding?
    private var driverObservers: [UUID: AsyncStream<UInt64>.Continuation] = [:]

    public nonisolated func permitsDriver(_ generation: UInt64) -> Bool {
        driverLock.lock()
        defer { driverLock.unlock() }
        return agentDriving && generation == driverGeneration
    }

    public nonisolated var currentDriverAllowed: Bool {
        driverLock.lock()
        defer { driverLock.unlock() }
        return agentDriving
    }

    nonisolated func trackHeldInputs(_ binding: MacDriverBinding) {
        driverLock.lock()
        inputBinding = binding
        driverLock.unlock()
    }

    public nonisolated func takeUserControl() {
        driverLock.lock()
        let changed = agentDriving
        agentDriving = false
        driverGeneration &+= 1
        let held = inputBinding
        inputBinding = nil
        driverLock.unlock()
        held?.releaseHeldInputs()
        if changed { Task { await self.publishDriver() } }
    }

    public nonisolated func userHandoffGeneration() -> UInt64? {
        #if canImport(AppKit) && os(macOS)
        guard Thread.isMainThread, let event = NSApp.currentEvent,
              [.leftMouseUp, .keyDown].contains(event.type),
              event.cgEvent?.getIntegerValueField(.eventSourceUserData) != NativeAgentMacEventIdentity.sourceUserData
        else { return nil }
        driverLock.lock()
        defer { driverLock.unlock() }
        return driverGeneration
        #else
        return nil
        #endif
    }

    /// Only the person's explicit UI handoff calls this, or a bind under the
    /// Full Mac they granted; never a tool or view on its own.
    public func giveAgentControl(userGeneration: UInt64) {
        ensureDriverObservation(eventSource: defaultMacAttentionEventSource())
        guard observation != nil else { return }
        driverLock.lock()
        guard driverGeneration == userGeneration else {
            driverLock.unlock()
            return
        }
        driverGeneration &+= 1
        agentDriving = true
        driverLock.unlock()
        publishDriver()
    }

    public func bindDriver(eventSource: any MacAttentionEventSource = defaultMacAttentionEventSource()) async -> MacDriverBinding {
        ensureDriverObservation(eventSource: eventSource)
        // Full Mac means her hands are on (User, 10-04): her next act is the
        // handback. Physical input still revokes every earlier binding, and
        // input during the policy read moves the generation, so no handback.
        let generation = makeDriverBinding().generation
        if !currentDriverAllowed, await Self.savedFullMac() {
            giveAgentControl(userGeneration: generation)
        }
        return makeDriverBinding()
    }

    private static func savedFullMac() async -> Bool {
        guard let snapshot = try? await SwiftNativeTrustCenter().loadAuthorizationSnapshotChecked(),
              let trust = MacControlPolicy.fromTrustPolicyObject(snapshot.policy).trustPolicy else { return false }
        return MacControlGate.fullMacActive(trust)
    }

    private nonisolated func makeDriverBinding() -> MacDriverBinding {
        driverLock.lock()
        defer { driverLock.unlock() }
        return MacDriverBinding(owner: self, generation: driverGeneration)
    }

    public func driverChanges() -> AsyncStream<UInt64> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        driverObservers[id] = continuation
        continuation.yield(makeDriverBinding().generation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDriverObserver(id) }
        }
        return stream
    }

    private func removeDriverObserver(_ id: UUID) { driverObservers[id] = nil }

    private func publishDriver() {
        let generation = makeDriverBinding().generation
        for observer in driverObservers.values { observer.yield(generation) }
    }

    private func ensureDriverObservation(eventSource: any MacAttentionEventSource) {
        guard observation == nil, eventSource.isAvailable else { return }
        #if canImport(AppKit) && canImport(CoreGraphics) && os(macOS)
        let coalescer = MacAttentionEventCoalescer()
        #endif
        observation = eventSource.start { [weak self] activity in
            // Revoke before hopping to the actor: a synchronous typing loop
            // must see physical input even while this actor is occupied.
            if activity.kind.isPhysicalUserInput { self?.takeUserControl() }
            #if canImport(AppKit) && canImport(CoreGraphics) && os(macOS)
            guard coalescer.shouldEmit(kind: activity.kind, atUptime: ProcessInfo.processInfo.systemUptime) else { return }
            #endif
            Task { await self?.record(activity) }
        }
    }

    public init(screenViewStore: MacScreenViewStore) {
        self.screenViewStore = screenViewStore
        self.waitSleep = { try await Task.sleep(for: .milliseconds($0)) }
    }

    init(screenViewStore: MacScreenViewStore, waitSleep: @escaping @Sendable (Int) async throws -> Void) {
        self.screenViewStore = screenViewStore
        self.waitSleep = waitSleep
    }

    deinit {
        observation?.stop()
        expiryTask?.cancel()
        for waiter in waiters.values {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
        }
    }

    @discardableResult
    public func start(
        durationSeconds: Int,
        now: Date,
        eventSource: any MacAttentionEventSource
    ) async -> MacAttentionSnapshot? {
        let startingDriverGeneration = makeDriverBinding().generation
        stopInternal()
        await screenViewStore.invalidate()
        ensureDriverObservation(eventSource: eventSource)
        guard observation != nil, !Task.isCancelled,
              makeDriverBinding().generation == startingDriverGeneration else { return nil }
        let duration = max(
            Self.minimumDurationSeconds,
            min(durationSeconds, Self.maximumDurationSeconds)
        )
        let id = UUID().uuidString
        let expiresAt = now.addingTimeInterval(TimeInterval(duration))
        session = Session(id: id, startedAt: now, expiresAt: expiresAt)
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

    public func revokeDriverControl() async {
        takeUserControl()
        stopInternal()
        await screenViewStore.invalidate()
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
        guard let binding = MacDriverContext.binding, binding.allowsEmission else {
            return .refused(reason: Self.driverRefusal, current: snapshot(timedOutWaiting: false))
        }
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
                    + "yield until the person explicitly returns Mac control",
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

    /// Driver revocation happened synchronously at the observer. This actor
    /// projects the pulse into the current optional view session.
    func record(_ activity: MacAttentionActivity) async {
        await screenViewStore.invalidate()
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
        guard session?.id == current.id else { return }
        resumeReadyWaiters(sequence: current.sequence)
    }

    private func snapshot(timedOutWaiting: Bool) -> MacAttentionSnapshot? {
        guard let current = session else { return nil }
        let driver = makeDriverBinding()
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
            timedOutWaiting: timedOutWaiting,
            driverAllowed: driver.allowsEmission,
            driverGeneration: driver.generation
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
                let timeoutTask = Task { [weak self, waitSleep] in
                    do {
                        try await waitSleep(timeoutMilliseconds)
                        try Task.checkCancellation()
                    } catch { return }
                    await self?.resumeWaiter(id: id)
                }
                waiters[id] = Waiter(after: sequence, continuation: continuation, timeoutTask: timeoutTask)
            }
        } onCancel: {
            Task { await owner.resumeWaiter(id: id) }
        }
        return (session?.sequence ?? before) <= sequence
    }

    private func resumeWaiter(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume()
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
        expiryTask?.cancel()
        expiryTask = nil
        session = nil
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
        }
    }

    public static let driverRefusal = "human_takeover: the person used the Mac, so this action stopped. Under Full Mac, act again when they ask; otherwise wait until they return control with Let agent use Mac."
}
