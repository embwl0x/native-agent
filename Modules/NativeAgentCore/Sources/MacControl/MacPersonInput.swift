import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CoreGraphics) && os(macOS)
import CoreGraphics
import Darwin
#endif
// Blueprint: | `MacPersonInput.swift` | `MacPersonInput`, `observeReturn`, `NativeAgentMacEventIdentity`, `ScriptedInputSources`, `NativeAgentMotorEpoch` |

/// The tag contains no user data; shared poster-PID classification distinguishes person and synthetic input.
public enum NativeAgentMacEventIdentity {
    public static let sourceUserData: Int64 = 0x4E_41_54_49_56_45
}

/// Scripts may hide synthetic input from the tap; unseen input stays unknown while they run.
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

/// ActivityWatch consumes only motor timestamps, without acquiring a scheduler, store or attention-session dependency.
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

    /// Compare motor age with system input age so attribution works at any sampling cadence.
    public static func secondsSinceLastAgentMotorEvent(
        atUptime uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        lock.lock()
        let last = lastAgentMotorUptime
        lock.unlock()
        guard uptime.isFinite, last.isFinite, uptime >= last else { return .infinity }
        return uptime - last
    }

    /// Only HID-tap posts reset idle; AX and targeted posts must not conceal the person’s input.
    private nonisolated(unsafe) static var lastPostedHIDUptime = -Double.infinity

    /// Stamp before HID posting so idle attribution cannot race the event.
    public static func notePostedHIDEvent() {
        MacPersonInput.noteAgentPost(targeted: false)
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastPostedHIDUptime = uptime
        lastAgentMotorUptime = max(lastAgentMotorUptime, uptime)
        lock.unlock()
        PersonOnlyWindows.noteAgentMotor()
    }

    static func secondsSinceLastPostedHIDEvent() -> TimeInterval {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let hid = lastPostedHIDUptime
        lock.unlock()
        return hid.isFinite ? uptime - hid : .infinity
    }
}

/// Recent person input can stop an effect; idle never authorizes foregrounding. Classify poster PIDs because system idle includes synthetic input; stamp
/// targeted posts at emission since they bypass the tap. Unseen input stays unknown if it predates the tap or could be hidden synthetic input, until person
/// input is seen again. Retain only event type, time and poster PID; never key contents, modifiers or positions, and never persist or send them.
public enum MacPersonInput {
    /// The window spans gaps in typing and pointing but ends before a submitted chat request reaches its call.
    public static let activeWindow: TimeInterval = 3

    /// Treat near-equal ages as one event to account for stamping just before posting and just after arrival.
    static let ownEventTolerance: TimeInterval = 0.1

    /// Unknown person idle cannot prove absence; recent combined input not attributed to the agent requires waiting.
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
    /// Possibly synthetic input missed by the tap makes person idle unknown until their next observed input.
    private nonisolated(unsafe) static var lastBlind = -Double.infinity
    /// Input before tap startup cannot establish tap provenance.
    private nonisolated(unsafe) static var started = Double.infinity
    private nonisolated(unsafe) static var windowServer: pid_t = 0
    private nonisolated(unsafe) static var port: CFMachPort?
    /// Only the person-input thread touches this transition state.
    private nonisolated(unsafe) static var away = false
    /// Read settled transitions under `clock`; unknown input cannot invent arrival or advance time except for an armed phone return.
    private nonisolated(unsafe) static var presenceTransition: (here: Bool, since: Date)?
    /// Arm a phone-evidenced return before Mac idle if needed; only observed physical input may settle it.
    private nonisolated(unsafe) static var returnAfter: Date?
    /// Due when the person would be away, set from the fact each time; never a poll.
    private nonisolated(unsafe) static var awayDue: CFRunLoopTimer?
    private nonisolated(unsafe) static var inputRunLoop: CFRunLoop?
    private nonisolated(unsafe) static var inputSource: CFRunLoopSource?
    private nonisolated(unsafe) static var inputThread: Thread?
    private nonisolated(unsafe) static var stopping = false
    private static let threadExit = DispatchGroup()

    /// Post each transition once on the input thread; only person input, including an armed phone return, may signal person.here.
    public static let presenceChanged = Notification.Name("NativeAgent.personPresence")

    /// Input Monitoring grants apply at launch, so later grants require another launch before the tap can run.
    private static let launchListening: Bool = listen()
    public static var listening: Bool {
        _ = launchListening
        return clock.withLock { port != nil }
    }

    /// Close admission before retiring resources, then acknowledge the actual input-thread exit.
    public static func shutdown() async {
        #if canImport(CoreGraphics) && os(macOS)
        let retiring = clock.withLock {
            stopping = true
            let resources = (port, awayDue, inputSource, inputRunLoop)
            port = nil; awayDue = nil; inputSource = nil
            return resources
        }
        // Release the timestamp lock before resource retirement because an entered callback may need it.
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
            // Include system-defined media events so their input is attributed too.
            eventsOfInterest: types.reduce(CGEventMask(1) << 14) { $0 | CGEventMask(1) << $1.rawValue },
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MacPersonInput.clock.withLock {
                        MacPersonInput.port.map { CGEvent.tapEnable(tap: $0, enable: true) }
                    }
                } else if MacPersonInput.note(event),
                          MacPersonInput.away || MacPersonInput.clock.withLock({ MacPersonInput.returnAfter != nil }) {
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
    /// The tap and synchronous takeover must classify provenance identically.
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

    /// Settle away once at the idle deadline and here only on person input; then arm the next exact deadline.
    private static func settle() {
        clock.withLock { settleAgain = false }
        let fact = presence()
        if let fact {
            let since = Date().addingTimeInterval((fact.here ? 0 : awayAfter) - fact.seconds)
            let changed = clock.withLock {
                let returned = fact.here && (returnAfter.map { since > $0 } ?? false)
                guard fact.here == away || returned else { return false }
                away = !fact.here
                if returned || !fact.here { returnAfter = nil }
                presenceTransition = (fact.here, since)
                return true
            }
            if changed {
                NotificationCenter.default.post(name: presenceChanged, object: nil, userInfo: [
                    "signal": away ? "person.away" : "person.here", "idle_seconds": fact.seconds.rounded()])
            }
        }
        // Away, nothing is due until their own input says here.
        let wait = away ? 315_360_000 : awayAfter - min(fact?.seconds ?? idleAtLeast() ?? 0, awayAfter)
        // Use settleSoon’s lock so intervening input is settled next rather than overwritten.
        clock.withLock {
            awayDue.map { CFRunLoopTimerSetNextFireDate($0, CFAbsoluteTimeGetCurrent() + (settleAgain ? 0 : wait)) }
        }
    }

    /// Under `clock`, unseen input is the person’s only when neither pre-tap nor possibly hidden synthetic provenance explains it.
    private static func markUnseen(now: Double) -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null)
        let input = now - idle
        guard idle.isFinite, input > max(lastPerson, lastSynthetic) + ownEventTolerance else { return false }
        let ownInput = ScriptedInputSources.isRunning
            || abs(idle - NativeAgentMotorEpoch.secondsSinceLastPostedHIDEvent()) <= ownEventTolerance
        if input > started, !ownInput { lastPerson = input; return true }
        lastBlind = now
        return false
    }

    /// Secure Event Input can hide person input from the tap; settle read-observed input on the owner thread so transitions and deadlines follow.
    private static func settleSoon() {
        clock.withLock {
            settleAgain = true
            awayDue.map { CFRunLoopTimerSetNextFireDate($0, CFAbsoluteTimeGetCurrent()) }
        }
    }
    /// Read-observed input after settlement began must be reconciled under `clock`.
    private nonisolated(unsafe) static var settleAgain = false
    #endif

    /// Mark missed input before posting so synthetic output cannot make it appear seen; stamp targeted posts here because they bypass the tap.
    static func noteAgentPost(targeted: Bool) {
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

    /// No tap or unresolved provenance yields no person-idle number; retain whose input was newest.
    public static func idle() -> (seconds: Double?, lastInput: String)? {
        #if canImport(CoreGraphics) && os(macOS)
        guard listening, CGPreflightListenEventAccess() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let (seen, idle): (Bool, (seconds: Double?, lastInput: String)) = clock.withLock {
            let seen = markUnseen(now: now)
            let newest = max(lastPerson, lastSynthetic)
            return (seen, (lastPerson > lastBlind ? now - lastPerson : nil,
                           newest <= lastBlind ? "unknown" : lastSynthetic > lastPerson ? "agent" : "person"))
        }
        if seen { settleSoon() }
        return idle
        #else
        return nil
        #endif
    }

    /// Combined idle supplies an absence floor while person provenance is unknown; it can prove away, never here.
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

    /// Motor-relative input age resumes capture metadata without asserting presence or requiring Input Monitoring. Compare ages so synthetic input remains
    /// excluded even across a minute-long sampling interval.
    public static func sessionIdleAfterAgentMotor() -> Double? {
        idleAtLeast().flatMap { seconds in
            seconds + NativeAgentMotorEpoch.defaultWindow
                < NativeAgentMotorEpoch.secondsSinceLastAgentMotorEvent() ? seconds : nil
        }
    }

    public static let awayAfter: TimeInterval = 300

    /// Repeated reads cannot move an armed phone return or replay a settled one.
    public static func observeReturn(after departure: Date) {
        #if canImport(CoreGraphics) && os(macOS)
        guard listening else { return }
        let armed = clock.withLock {
            if let settled = presenceTransition,
               !settled.here || settled.since >= departure { return false }
            if let pending = returnAfter, pending <= departure { return false }
            returnAfter = departure
            return true
        }
        // Reconcile input that arrived between reading phone evidence and arming the wake, including hidden secure input.
        if armed { settleSoon() }
        #endif
    }

    /// Presence excludes synthetic input; while provenance is unknown, combined idle may prove away but never here.
    public static func presence() -> (here: Bool, seconds: Double)? {
        let seconds = idle()?.seconds ?? idleAtLeast().flatMap { $0 >= awayAfter ? $0 : nil }
        return seconds.map { ($0 < awayAfter, $0) }
    }

    /// Reads cannot invent arrivals or advance timestamps; only the input owner settles transitions.
    public static func presenceChange() -> (here: Bool, since: Date)? {
        guard let fact = presence() else { return nil }
        return clock.withLock {
            guard let transition = presenceTransition, transition.here == fact.here else { return nil }
            return transition
        }
    }

    public static var presenceDetail: JSONValue {
        guard let fact = presence() else {
            return .object(["here": .null, "idle_seconds": .null,
                            "unknown": .string(idle() == nil ? "input_monitoring_needed" : "not_seen_since_launch")])
        }
        return .object(["here": .bool(fact.here), "idle_seconds": .int(Int64(fact.seconds.rounded()))])
    }

    /// Unknown idle must remain absent in window reads.
    public static var idleDetail: [String: JSONValue] {
        guard let idle = idle() else {
            return ["permission": .string("input_monitoring_needed"), "last_input": .string("unknown")]
        }
        var detail: [String: JSONValue] = ["last_input": .string(idle.lastInput)]
        if let seconds = idle.seconds { detail["person_idle_seconds"] = .double((seconds * 10).rounded() / 10) }
        return detail
    }
}
