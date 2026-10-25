import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(AppKit) && os(macOS)
import AppKit
#endif
#if canImport(CoreGraphics) && os(macOS)
import CoreGraphics
// Blueprint: | `MacAttention.swift` | `MacPersonInput` owns exact person input and canonical presence; its motor-fenced session-activity read lets capture resume without Input Monitoring and never publishes presence; motor provenance, attention monitoring and attention sessions; `MacPersonInput` owns person/synthetic input provenance and the presence fact; attention uses that provenance for synchronous takeover, retaining scene events and person-only-window exclusions; `MacDriverBinding.settlementBinding` gives `settle` an independent cancellation lifetime under the original authority and driver generation; `stopAttentionSession` ends only the optional session, `revokeDriverControl` hands back control |
#endif

// MARK: - Ephemeral, explicit computer attention

/// Identifies input synthesized by NativeAgent itself.
///
/// The tag contains no user data. Person provenance is classified by poster PID
/// in `MacPersonInput`, shared by the tap and attention observer.
public enum NativeAgentMacEventIdentity {
    public static let sourceUserData: Int64 = 0x4E_41_54_49_56_45 // "NATIVE"
}

/// While her script runs, the input it drives is hers, not the person's. A
/// script can hide input from the tap; while it runs, unseen input is unknown.
public enum ScriptedInputSources {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var running = 0

    public static func during<T>(_ body: () async throws -> T) async rethrows -> T {
        lock.withLock { running += 1 }
        defer { lock.withLock { running -= 1 } }
        return try await body()
    }

    static var isRunning: Bool { lock.withLock { running > 0 } }

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
        PersonOnlyWindows.noteAgentMotor()
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
        MacPersonInput.noteHerPost(targeted: false)
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastPostedHIDUptime = uptime
        lastAgentMotorUptime = max(lastAgentMotorUptime, uptime)
        lock.unlock()
        PersonOnlyWindows.noteAgentMotor()
    }

    /// Age of her last HID-tap post, `.infinity` when there has been none.
    static func secondsSinceLastPostedHIDEvent() -> TimeInterval {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let hid = lastPostedHIDUptime
        lock.unlock()
        return hid.isFinite ? uptime - hid : .infinity
    }
}

/// Is the person at the keyboard or mouse right now, and how long have they
/// been idle? Recent input can stop an effect; idle time never authorizes
/// bringing an app to the front.
///
/// The idle clocks count every input, hers too (measured 10-21: a synthetic
/// event resets the hardware clock once it is ~5 s idle, whatever the route),
/// so no window on them can tell the two apart. Every event names its poster
/// instead: hardware input carries pid 0 (or the WindowServer's); her own
/// posts, System Events driven by her scripts and any helper she runs carry
/// theirs. Her `postToPid` posts never pass the session tap, so they cannot
/// touch the person's clock; their one post site stamps them hers.
///
/// One rule keeps it honest: input the system saw that the tap never did
/// (typing under Secure Event Input, a touch or gesture the tap does not
/// list, anything while the tap was off) is the person's, since hers passes
/// the tap or is stamped as she posts it. It is unknown only when it came
/// before the tap started or while her own post or script could be the
/// hidden one; then the person's idle is unknown until they are seen again.
///
/// Privacy contract: the tap is listen-only and reads three things of an
/// event — its type, the moment it arrived and its source process id. It
/// never reads key codes, characters, modifiers or positions, and keeps
/// nothing but timestamps: the person's newest input, the newest synthetic
/// one and the last moment it could not see. Nothing is written or leaves
/// the process.
public enum MacPersonInput {
    /// Typing and pointing leave gaps well under this; a chat message sent to
    /// her is older than this by the time her call lands.
    public static let activeWindow: TimeInterval = 3

    /// Her own post is noted just before it is posted, and input in the
    /// person's own window a moment after it lands, so two ages this close
    /// are the same input.
    static let ownEventTolerance: TimeInterval = 0.1

    /// Seconds since the person's last input when that is under `activeWindow`;
    /// nil when they are idle. Only the exact fact may say they are not at the
    /// keys: while it is unknown, any recent input on the combined clock that
    /// was not her own HID post is possibly theirs, and she waits.
    public static func activeSecondsAgo() -> Double? {
        // Shotgun (User, 10-04): typing to her in his own small chat is not
        // being at the keys over her work; while it is up, nothing is (Stop is).
        guard !PersonOnlyWindows.isShowing else { return nil }
        if let seconds = idle()?.seconds {
            guard seconds < activeWindow, PersonOnlyWindows.secondsSincePersonInput() > seconds + ownEventTolerance
            else { return nil }
            return seconds
        }
        #if canImport(CoreGraphics) && os(macOS)
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null
        )
        guard idle.isFinite, idle >= 0, idle < activeWindow,
              abs(idle - NativeAgentMotorEpoch.secondsSinceLastPostedHIDEvent()) > ownEventTolerance,
              abs(idle - PersonOnlyWindows.secondsSincePersonInput()) > ownEventTolerance
        else { return nil }
        return idle
        #else
        return nil
        #endif
    }

    private static let clock = NSLock()
    private nonisolated(unsafe) static var lastPerson = -Double.infinity
    private nonisolated(unsafe) static var lastSynthetic = -Double.infinity
    /// The last moment the system was found to have input the tap never saw
    /// and that may have been hers: the person's idle is unknown until they
    /// are seen after it.
    private nonisolated(unsafe) static var lastBlind = -Double.infinity
    /// When the tap started: input before it was never its to see.
    private nonisolated(unsafe) static var started = Double.infinity
    private nonisolated(unsafe) static var windowServer: pid_t = 0
    private nonisolated(unsafe) static var port: CFMachPort?
    /// Whether the last transition said away. Only the person-input thread touches it.
    private nonisolated(unsafe) static var away = false
    /// Due when the person would be away, set from the fact each time; never a poll.
    private nonisolated(unsafe) static var awayDue: CFRunLoopTimer?
    private nonisolated(unsafe) static var inputRunLoop: CFRunLoop?
    private nonisolated(unsafe) static var inputSource: CFRunLoopSource?
    private nonisolated(unsafe) static var inputThread: Thread?
    private nonisolated(unsafe) static var stopping = false
    private static let threadExit = DispatchGroup()

    /// Posted once per transition, on the person-input thread: userInfo
    /// `signal` is "person.away" (idle `awayAfter`) or "person.here" (their own
    /// input again, never hers), `idle_seconds` the fact's.
    public static let presenceChanged = Notification.Name("NativeAgent.personPresence")

    /// Whether the tap runs. Touched once at launch: macOS applies an Input
    /// Monitoring grant at launch, so one made later waits for the next one
    /// (the permission card says so).
    private static let launchListening: Bool = listen()
    public static var listening: Bool {
        _ = launchListening
        return clock.withLock { port != nil }
    }

    /// Terminal engine shutdown; closes input admission before retiring the
    /// resources on their own run loop, then acknowledges the actual thread exit.
    public static func shutdown() async {
        #if canImport(CoreGraphics) && os(macOS)
        let retiring = clock.withLock {
            stopping = true
            let resources = (port, awayDue, inputSource, inputRunLoop)
            port = nil; awayDue = nil; inputSource = nil
            return resources
        }
        // Admission is already closed. Retire OS resources without holding the
        // timestamp lock that an already-entered input callback may need.
        if let tap = retiring.0 { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let timer = retiring.1 { CFRunLoopTimerInvalidate(timer) }
        if let source = retiring.2 { CFRunLoopSourceInvalidate(source) }
        if let runLoop = retiring.3 {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
            CFRunLoopWakeUp(runLoop)
        }
        await withCheckedContinuation { done in
            threadExit.notify(queue: .global(qos: .utility)) { done.resume() }
        }
        #endif
    }

    /// Arm the first presence deadline only after its wake observer is ready.
    public static func startPresenceWakes() {
        #if canImport(CoreGraphics) && os(macOS)
        guard listening else { return }
        settleSoon()
        #endif
    }

    private static func listen() -> Bool {
        #if canImport(CoreGraphics) && os(macOS)
        // Preflight never prompts; creating the tap without the grant would.
        guard !clock.withLock({ stopping }), CGPreflightListenEventAccess() else { return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .mouseMoved,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            // Plus system-defined events (14: media keys), so those are accounted for too.
            eventsOfInterest: types.reduce(CGEventMask(1) << 14) { $0 | CGEventMask(1) << $1.rawValue },
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MacPersonInput.clock.withLock {
                        MacPersonInput.port.map { CGEvent.tapEnable(tap: $0, enable: true) }
                    }
                } else if MacPersonInput.note(event),
                          MacPersonInput.away {
                    MacPersonInput.settle()
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil
        ), let made = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        nonisolated(unsafe) let source = made
        nonisolated(unsafe) let due = CFRunLoopTimerCreateWithHandler(nil, Double.greatestFiniteMagnitude, awayAfter, 0, 0) { _ in
            MacPersonInput.settle()
        }
        clock.lock()
        guard !stopping else {
            clock.unlock()
            CFMachPortInvalidate(tap)
            CFRunLoopSourceInvalidate(source)
            CFRunLoopTimerInvalidate(due)
            return false
        }
        awayDue = due
        port = tap
        inputSource = source
        started = ProcessInfo.processInfo.systemUptime
        threadExit.enter()
        // Its own thread, so a busy main thread never stamps late.
        nonisolated(unsafe) let ownedTap = tap
        let thread = Thread {
            defer {
                CFRunLoopSourceInvalidate(source)
                CFRunLoopTimerInvalidate(due)
                CFMachPortInvalidate(ownedTap)
                clock.withLock {
                    port = nil; awayDue = nil; inputSource = nil; inputRunLoop = nil; inputThread = nil
                }
                threadExit.leave()
            }
            clock.lock()
            guard !stopping else { clock.unlock(); return }
            let loop = CFRunLoopGetCurrent()
            inputRunLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CFRunLoopAddTimer(loop, due, .commonModes)
            clock.unlock()
            CFRunLoopRun()
        }
        thread.name = "com.nativeagent.person-input"
        inputThread = thread
        thread.start()
        clock.unlock()
        return true
        #else
        return false
        #endif
    }

    #if canImport(CoreGraphics) && os(macOS)
    /// Shared provenance for the tap and synchronous attention takeover.
    static func isPerson(_ event: CGEvent) -> Bool {
        let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
        if pid == 0 { return true }
        return clock.withLock {
            if pid == windowServer { return true }
            var name = [UInt8](repeating: 0, count: 64)
            let length = pid == getpid() ? 0 : proc_name(pid, &name, UInt32(name.count))
            guard length > 0, String(decoding: name.prefix(Int(length)), as: UTF8.self) == "WindowServer" else { return false }
            windowServer = pid
            return true
        }
    }

    private static func note(_ event: CGEvent) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let person = isPerson(event)
        clock.withLock { if person { lastPerson = now } else { lastSynthetic = now } }
        return person
    }

    /// The fact's transition, posted once: away once the person has been idle
    /// `awayAfter`, here again on their own input. Then due when they would be away.
    private static func settle() {
        clock.withLock { settleAgain = false }
        let fact = presence()
        if let fact, fact.here == away {
            away = !fact.here
            NotificationCenter.default.post(name: presenceChanged, object: nil, userInfo: [
                "signal": away ? "person.away" : "person.here", "idle_seconds": fact.seconds.rounded()])
        }
        // Away, nothing is due until their own input says here.
        let wait = away ? 315_360_000 : awayAfter - min(fact?.seconds ?? idleAtLeast() ?? 0, awayAfter)
        // The deadline is set under the same lock settleSoon takes: input noticed
        // meanwhile is settled next, never overwritten by this pass (once, no loop).
        clock.withLock {
            awayDue.map { CFRunLoopTimerSetNextFireDate($0, CFAbsoluteTimeGetCurrent() + (settleAgain ? 0 : wait)) }
        }
    }

    /// Input the system saw after everything the tap did: the person's, unless
    /// it predates the tap or her own post or script may be what was hidden.
    /// Under `clock`; true when it was the person's.
    private static func markUnseen(now: Double) -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null)
        let input = now - idle
        guard idle.isFinite, input > max(lastPerson, lastSynthetic) + ownEventTolerance else { return false }
        let hers = ScriptedInputSources.isRunning
            || abs(idle - NativeAgentMotorEpoch.secondsSinceLastPostedHIDEvent()) <= ownEventTolerance
        if input > started, !hers { lastPerson = input; return true }
        lastBlind = now
        return false
    }

    /// The person's input only a read saw (Secure Event Input hides it from the
    /// tap): the presence transition is settled on the input thread, now,
    /// through its own timer, so person.here and the next away deadline follow.
    private static func settleSoon() {
        clock.withLock {
            settleAgain = true
            awayDue.map { CFRunLoopTimerSetNextFireDate($0, CFAbsoluteTimeGetCurrent()) }
        }
    }
    /// A read saw their input since the running settle began; under `clock`.
    private nonisolated(unsafe) static var settleAgain = false
    #endif

    /// Her own post, just before it goes out: input the tap missed is marked
    /// first, so her post can't make it look seen. A targeted post never
    /// passes the tap, so it is stamped hers here.
    static func noteHerPost(targeted: Bool) {
        #if canImport(CoreGraphics) && os(macOS)
        guard listening else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let seen = clock.withLock {
            let seen = markUnseen(now: now)
            if targeted { lastSynthetic = now }
            return seen
        }
        if seen { settleSoon() }
        #endif
    }

    /// Seconds since the person's last input (nil while unknown: not seen
    /// since launch or since missed input that may have been hers) and whose input was
    /// newest ("person", "hers" or "unknown"). Nil when the tap cannot run.
    public static func idle() -> (seconds: Double?, lastInput: String)? {
        #if canImport(CoreGraphics) && os(macOS)
        guard listening, CGPreflightListenEventAccess() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let (seen, idle): (Bool, (seconds: Double?, lastInput: String)) = clock.withLock {
            let seen = markUnseen(now: now)
            let newest = max(lastPerson, lastSynthetic)
            return (seen, (lastPerson > lastBlind ? now - lastPerson : nil,
                           newest <= lastBlind ? "unknown" : lastSynthetic > lastPerson ? "hers" : "person"))
        }
        if seen { settleSoon() }
        return idle
        #else
        return nil
        #endif
    }

    /// Seconds since anyone's input, hers included. The person has been idle
    /// at least this long whatever the tap saw, so it can say away (never
    /// here) while their own clock is unknown, e.g. after a launch.
    public static func idleAtLeast() -> Double? {
        #if canImport(CoreGraphics) && os(macOS)
        let any = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null
        )
        return any.isFinite && any >= 0 ? any : nil
        #else
        return nil
        #endif
    }

    /// Session input newer than our last motor output by its attribution
    /// window. Capture uses this in every permission state to resume its
    /// metadata span after idle; it does not assert that the person is here.
    /// Comparing ages keeps our input excluded even on a minute-long tick.
    /// Unlike the person's exact clock, this read needs no Input Monitoring.
    public static func sessionIdleAfterAgentMotor() -> Double? {
        idleAtLeast().flatMap { seconds in
            seconds + NativeAgentMotorEpoch.defaultWindow
                < NativeAgentMotorEpoch.secondsSinceLastAgentMotorEvent() ? seconds : nil
        }
    }

    /// Idle this long, the person is away.
    public static let awayAfter: TimeInterval = 300

    /// The one presence fact home, her abilities and the presence wakes read:
    /// here or away and seconds since the person's own input (hers never
    /// counts). While their own clock is unknown, the floor nobody has touched
    /// the Mac for still says away, never here; nil while unknown.
    public static func presence() -> (here: Bool, seconds: Double)? {
        let seconds = idle()?.seconds ?? idleAtLeast().flatMap { $0 >= awayAfter ? $0 : nil }
        return seconds.map { ($0 < awayAfter, $0) }
    }

    /// `presence()` as an action carries it.
    public static var presenceDetail: JSONValue {
        guard let fact = presence() else {
            return .object(["here": .null, "idle_seconds": .null,
                            "unknown": .string(idle() == nil ? "input_monitoring_needed" : "not_seen_since_launch")])
        }
        return .object(["here": .bool(fact.here), "idle_seconds": .int(Int64(fact.seconds.rounded()))])
    }

    /// `idle()` as a window read carries it: no number while it is unknown.
    public static var idleDetail: [String: JSONValue] {
        guard let idle = idle() else {
            return ["permission": .string("input_monitoring_needed"), "last_input": .string("unknown")]
        }
        var detail: [String: JSONValue] = ["last_input": .string(idle.lastInput)]
        if let seconds = idle.seconds { detail["person_idle_seconds"] = .double((seconds * 10).rounded() / 10) }
        return detail
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
                guard let input = event.cgEvent, MacPersonInput.isPerson(input) else { return nil }
                // Shotgun (User, 10-04): while it is up, Stop in it is the only
                // hand-back — his input anywhere never takes the Mac from her.
                // With it closed, real input is a takeover as always.
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
    /// The admitted action runs in an app in the back: it needs none of his
    /// cursor, keys, focus or screen. Off unless the action said so.
    @TaskLocal public static var background = false
    @TaskLocal static var inputStartCount = 0
    /// A watch's own binding keeps a pressed key down across its hands, until
    /// its key-up, its end or the person's input releases it (MacScreenWatch).
    @TaskLocal static var holdsAcrossCalls = false
}

public final class MacDriverBinding: @unchecked Sendable {
    public let generation: UInt64
    private let owner: MacAttentionSessionStore
    /// She held the Mac when this act began.
    private let granted: Bool
    private let handback: UInt64
    private let lock = NSLock()
    private var cancelled = false
    private var yielded = false
    private var postedEvents = 0
    private var releases: [String: @Sendable () -> Void] = [:]

    init(owner: MacAttentionSessionStore, generation: UInt64, granted: Bool, handback: UInt64) {
        self.owner = owner
        self.generation = generation
        self.granted = granted
        self.handback = handback
    }

    private var stopped: Bool { lock.withLock { cancelled } || Task.isCancelled }

    /// Her hands on his cursor, keys, focus or screen: his own input ends it.
    public var allowsEmission: Bool {
        guard !stopped else { return false }
        if owner.permitsDriver(generation) { return true }
        lock.withLock { yielded = true }
        return false
    }

    /// Work that moves none of his cursor, keys, focus or screen — an
    /// action admitted to run in an app in the back, her own Chrome tab —
    /// goes on while he uses the Mac (User, 10-04: his clicking around never
    /// stops her Chrome work). "Let me take over" ends it in every session.
    public var allowsBackgroundEmission: Bool {
        guard granted, !stopped else { return false }
        if owner.permitsBackground(handback) { return true }
        lock.withLock { yielded = true }
        return false
    }

    /// He took the Mac back explicitly since this act began.
    public var handedBack: Bool { !owner.permitsBackground(handback) }

    /// The permission the admitted action needs: in the back, only hers.
    public var allowsAction: Bool { MacDriverContext.background ? allowsBackgroundEmission : allowsEmission }

    /// An effect that needed his cursor, keys, focus or screen was refused
    /// because he took the Mac.
    public var yieldedToPerson: Bool { lock.withLock { yielded } }

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

    /// Releasing what the act held runs through `settle` with its own
    /// cancellation lifetime. Keep the original authority: physical takeover,
    /// explicit handback and shutdown still revoke this generation.
    public func settlementBinding() -> MacDriverBinding {
        MacDriverBinding(owner: owner, generation: generation, granted: granted, handback: handback)
    }

    func held(_ key: String, release: (@Sendable () -> Void)?) {
        lock.lock()
        releases[key] = release
        lock.unlock()
        owner.trackHeldInputs(self)
        if stopped || !owner.permitsDriver(generation) { releaseHeldInputs() }
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
/// Passive driver observation deliberately outlives session stop/expiry: it
/// protects ordinary acts without a view session. Only terminal shutdown ends it.
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
    private var sessionGeneration: UInt64 = 0
    private var observation: (any MacAttentionObservation)?
    private var expiryTask: Task<Void, Never>?
    private var isShutDown = false
    private var waiters: [UUID: Waiter] = [:]
    private nonisolated let driverLock = NSLock()
    private nonisolated(unsafe) var agentDriving = false
    private nonisolated(unsafe) var driverOpen = true
    private nonisolated(unsafe) var driverGeneration: UInt64 = 0
    /// Moves only on "let me take over" or a hand-back Stop, never on input.
    private nonisolated(unsafe) var handbackGeneration: UInt64 = 0
    private nonisolated(unsafe) weak var inputBinding: MacDriverBinding?
    private var driverObservers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var driverReturnWaiters: Set<UUID> = []

    public nonisolated func permitsDriver(_ generation: UInt64) -> Bool {
        driverLock.lock()
        defer { driverLock.unlock() }
        return driverOpen && agentDriving && generation == driverGeneration
    }

    nonisolated func permitsBackground(_ handback: UInt64) -> Bool {
        driverLock.lock()
        defer { driverLock.unlock() }
        return driverOpen && handback == handbackGeneration
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
              let input = event.cgEvent, MacPersonInput.isPerson(input)
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
        // input during the policy read moves the generation, so no handback;
        // her background work is still granted.
        let generation = makeDriverBinding().generation
        var granted = currentDriverAllowed
        if !granted, await Self.savedFullMac() {
            granted = true
            giveAgentControl(userGeneration: generation)
        }
        return makeDriverBinding(granted: granted)
    }

    /// Whether the composer's hand-back would change anything now: a Mac
    /// action has asked for the driver this run, the person holds it, and the
    /// posture is below Full Mac, or a turn is waiting for control to return.
    public func handoffWouldChange() async -> Bool {
        guard observation != nil, !currentDriverAllowed else { return false }
        if !driverReturnWaiters.isEmpty { return true }
        return !(await Self.savedFullMac())
    }

    private static func savedFullMac() async -> Bool {
        guard let snapshot = try? await SwiftNativeTrustCenter().loadAuthorizationSnapshotChecked(),
              let trust = MacControlPolicy.fromTrustPolicyObject(snapshot.policy).trustPolicy else { return false }
        return MacControlGate.fullMacActive(trust)
    }

    private nonisolated func makeDriverBinding(granted: Bool = false) -> MacDriverBinding {
        driverLock.lock()
        defer { driverLock.unlock() }
        return MacDriverBinding(owner: self, generation: driverGeneration, granted: granted,
                                handback: handbackGeneration)
    }

    public func driverChanges(waitingForReturn: Bool = false) -> AsyncStream<UInt64> {
        guard !isShutDown else { return AsyncStream { $0.finish() } }
        let id = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        driverObservers[id] = continuation
        if waitingForReturn {
            driverReturnWaiters.insert(id)
            publishDriver()
        }
        continuation.yield(makeDriverBinding().generation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDriverObserver(id) }
        }
        return stream
    }

    private func removeDriverObserver(_ id: UUID) {
        driverObservers[id] = nil
        if driverReturnWaiters.remove(id) != nil { publishDriver() }
    }

    private func publishDriver() {
        guard !isShutDown else { return }
        let generation = makeDriverBinding().generation
        for observer in driverObservers.values { observer.yield(generation) }
    }

    private func ensureDriverObservation(eventSource: any MacAttentionEventSource) {
        guard !isShutDown, observation == nil, eventSource.isAvailable else { return }
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
        // The first ask for the driver is news to the composer's hand-back.
        if observation != nil { publishDriver() }
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
        driverObservers.values.forEach { $0.finish() }
        for waiter in waiters.values {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
        }
    }

    /// Terminal domain retirement, distinct from stopping a bounded view session.
    /// The engine drain owns calling this; no later bind/start reopens admission.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        driverLock.withLock { driverOpen = false; handbackGeneration &+= 1 }
        takeUserControl()
        stopInternal()
        observation?.stop()
        observation = nil
        driverObservers.values.forEach { $0.finish() }
        driverObservers.removeAll()
        driverReturnWaiters.removeAll()
        await screenViewStore.invalidate()
    }

    @discardableResult
    public func start(
        durationSeconds: Int,
        now: Date,
        eventSource: any MacAttentionEventSource
    ) async -> MacAttentionSnapshot? {
        guard !isShutDown else { return nil }
        let startingDriverGeneration = makeDriverBinding().generation
        stopInternal()
        let startingSessionGeneration = sessionGeneration
        await screenViewStore.invalidate()
        guard sessionGeneration == startingSessionGeneration else { return nil }
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
    public func stopAttentionSession() async -> Bool {
        let wasActive = session != nil
        stopInternal()
        await screenViewStore.invalidate()
        return wasActive
    }

    public func revokeDriverControl() async {
        driverLock.withLock { handbackGeneration &+= 1 }
        takeUserControl()
        publishDriver()
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
        guard let binding = MacDriverContext.binding, binding.allowsAction else {
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
        // Work in the back never waits on his input (see MacDriverBinding).
        if MacDriverContext.background { return .allowed }
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
        // Also supersede a start still awaiting screen invalidation.
        sessionGeneration &+= 1
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

    public static let driverRefusal = "human_takeover: the person used the Mac, so this action stopped. Under Full Mac, your next action reacquires control; otherwise ask them to use NativeAgent Mac chat > composer controls > Let [agent name] use the Mac."
}
