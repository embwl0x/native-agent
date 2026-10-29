import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CoreGraphics) && os(macOS)
import CoreGraphics
import Darwin
#endif
// Blueprint: | `MacPersonInput.swift` | `MacPersonInput` owns exact person/synthetic input provenance and canonical presence; motor-fenced session activity permits capture resumption without Input Monitoring and never asserts presence; `NativeAgentMacEventIdentity`, `ScriptedInputSources` and `NativeAgentMotorEpoch` identify their input and motor output |

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

    /// Age of the last agent motor event, `.infinity` when none. Comparing
    /// it with system input age attributes activity at any sampling cadence.
    public static func secondsSinceLastAgentMotorEvent(
        atUptime uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        lock.lock()
        let last = lastAgentMotorUptime
        lock.unlock()
        guard uptime.isFinite, last.isFinite, uptime >= last else { return .infinity }
        return uptime - last
    }

    /// Only HID-tap posts reset the idle clock; accessibility actions and
    /// targeted posts must not hide the person's input when comparing ages.
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

/// The person's exact input and presence, independent of driver authority.
/// Recent input can stop an effect; idle never authorizes foregrounding.
///
/// Idle clocks include synthetic events, so provenance uses poster PID:
/// hardware input carries pid 0 or WindowServer's; her posts, scripts and
/// helpers carry theirs. Targeted posts bypass the session tap and are
/// stamped at their post site.
///
/// Unseen system input is the person's unless it predates the tap or her
/// own post or script could be hidden; then person idle stays unknown until
/// their own input is seen again.
///
/// Privacy: the listen-only tap reads only type, arrival time and poster PID.
/// It retains timestamps for newest person, synthetic and unseen input,
/// never key contents, modifiers or positions; nothing is written or sent.
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
        // While the person's own chat is up, only Stop hands the Mac back.
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
