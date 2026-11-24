import CoreFoundation
import Dispatch
import Foundation
import Synchronization
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import CoreGraphics
import Darwin
// Blueprint: | `MacPersonInput.swift` | `MacPersonInput`, `observeReturn`, `NativeAgentMacEventIdentity`, `ScriptedInputSources` |

/// The tag contains no user data; shared poster-PID classification distinguishes person and synthetic input.
public enum NativeAgentMacEventIdentity {
    public static let sourceUserData: Int64 = 0x4E_41_54_49_56_45
}

/// Scripts may hide synthetic input from the tap; unseen input stays unknown while they run.
public enum ScriptedInputSources {
    private static let running = Mutex(0)

    public static func during<T>(_ body: () async throws -> T) async rethrows -> T {
        running.withLock { $0 += 1 }
        defer { running.withLock { $0 -= 1 } }
        return try await body()
    }

    static var isRunning: Bool { running.withLock { $0 > 0 } }

}

/// Recent person input can stop an effect; idle never authorizes foregrounding. Classify poster PIDs because system idle includes synthetic input; stamp
/// targeted posts at emission since they bypass the tap. Unseen input stays unknown if it predates the tap or could be hidden synthetic input, until person
/// input is seen again. Retain only event type, time and poster PID; never key contents, modifiers or positions, and never persist or send them.
public enum MacPersonInput {
    /// The window spans gaps in typing and pointing but ends before a submitted chat request reaches its call.
    public static let activeWindow: TimeInterval = 3

    /// Treat near-equal ages as one event to account for stamping just before posting and just after arrival.
    static let ownEventTolerance: TimeInterval = 0.1

    private static let lastPostedHIDUptime = Mutex(-Double.infinity)

    static func notePostedHIDEvent() {
        noteAgentPost(targeted: false)
        lastPostedHIDUptime.withLock { $0 = ProcessInfo.processInfo.systemUptime }
        PersonOnlyWindows.noteAgentMotor()
    }

    private static func secondsSinceLastPostedHIDEvent() -> TimeInterval {
        lastPostedHIDUptime.withLock { ProcessInfo.processInfo.systemUptime - $0 }
    }

    /// Unknown person idle cannot prove absence; recent combined input not attributed to the agent requires waiting.
    public static func activeSecondsAgo() -> Double? {
        // While the person's own chat is up, only Stop hands the Mac back.
        guard !PersonOnlyWindows.isShowing else { return nil }
        if let seconds = idle()?.seconds {
            guard seconds < activeWindow, PersonOnlyWindows.secondsSincePersonInput() > seconds + ownEventTolerance
            else { return nil }
            return seconds
        }
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null
        )
        guard idle.isFinite, idle >= 0, idle < activeWindow,
              abs(idle - secondsSinceLastPostedHIDEvent()) > ownEventTolerance,
              abs(idle - PersonOnlyWindows.secondsSincePersonInput()) > ownEventTolerance
        else { return nil }
        return idle
    }

    private struct State {
        var lastPerson = -Double.infinity
        var lastSynthetic = -Double.infinity
        var lastBlind = -Double.infinity
        var started = Double.infinity
        var port: HeldHandle<CFMachPort>?
        var away = false
        var presenceTransition: (here: Bool, since: Date)?
        var returnAfter: Date?
        var awayDue: HeldHandle<CFRunLoopTimer>?
        var inputRunLoop: HeldHandle<CFRunLoop>?
        var inputSource: HeldHandle<CFRunLoopSource>?
        var inputThread: HeldHandle<Thread>?
        var stopping = false
        var settleAgain = false
    }
    private static let clock = Mutex(State())
    private static let threadExit = DispatchGroup()

    /// Post each transition once on the input thread; only person input, including an armed phone return, may signal person.here.
    public struct PresenceChanged: NotificationCenter.AsyncMessage {
        public typealias Subject = NSObject
        public let here: Bool
        public let idleSeconds: Double
    }

    /// Input Monitoring grants apply at launch, so later grants require another launch before the tap can run.
    private static let launchListening: Bool = listen()
    public static var listening: Bool {
        _ = launchListening
        return clock.withLock { $0.port != nil }
    }

    /// Close admission before retiring resources, then acknowledge the actual input-thread exit.
    public static func shutdown() async {
        let retire: @Sendable () -> Void = clock.withLock { state in
            state.stopping = true
            let resources = (tap: state.port.take()?.value, timer: state.awayDue.take()?.value,
                             source: state.inputSource.take()?.value, loop: state.inputRunLoop.take()?.value)
            nonisolated(unsafe) let held = resources
            return {
                if let tap = unsafe held.tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
                if let timer = unsafe held.timer { CFRunLoopTimerInvalidate(timer) }
                if let source = unsafe held.source { CFRunLoopSourceInvalidate(source) }
                if let loop = unsafe held.loop {
                    CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
                    CFRunLoopWakeUp(loop)
                }
            }
        }
        retire()
        await withCheckedContinuation { done in
            threadExit.notify(queue: .global(qos: .utility)) { done.resume() }
        }
    }

    /// Arm the first presence deadline only after its wake observer is ready.
    public static func startPresenceWakes() {
        guard listening else { return }
        settleSoon()
    }

    private static func listen() -> Bool {
        // Preflight never prompts; creating the tap without the grant would.
        guard !clock.withLock({ $0.stopping }), CGPreflightListenEventAccess() else { return false }
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
                    MacPersonInput.clock.withLock { state in
                        state.port.map { CGEvent.tapEnable(tap: $0.value, enable: true) }
                    }
                } else {
                    if MacPersonInput.note(event),
                       MacPersonInput.clock.withLock({ $0.away || $0.returnAfter != nil }) {
                        MacPersonInput.settle()
                    }
                }
                return unsafe Unmanaged.passUnretained(event)
            }, userInfo: nil
        ), let made = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        nonisolated(unsafe) let source = made
        nonisolated(unsafe) let due = CFRunLoopTimerCreateWithHandler(nil, Double.greatestFiniteMagnitude, awayAfter, 0, 0) { _ in
            MacPersonInput.settle()
        }
        // Its own thread, so a busy main thread never stamps late.
        nonisolated(unsafe) let ownedTap = tap
        let thread = Thread {
            defer {
                unsafe CFRunLoopSourceInvalidate(source)
                unsafe CFRunLoopTimerInvalidate(due)
                unsafe CFMachPortInvalidate(ownedTap)
                clock.withLock { state in
                    state.port = nil; state.awayDue = nil; state.inputSource = nil; state.inputRunLoop = nil; state.inputThread = nil
                }
                threadExit.leave()
            }
            let run = clock.withLock { state in
                guard !state.stopping else { return false }
                let loop = CFRunLoopGetCurrent()
                state.inputRunLoop = HeldHandle(loop!)
                unsafe CFRunLoopAddSource(loop, source, .commonModes)
                unsafe CFRunLoopAddTimer(loop, due, .commonModes)
                return true
            }
            if run { CFRunLoopRun() }
        }
        thread.name = "com.nativeagent.person-input"
        let admitted = clock.withLock { state in
            guard !state.stopping else { return false }
            state.awayDue = unsafe HeldHandle(due!)
            state.port = unsafe HeldHandle(ownedTap)
            state.inputSource = unsafe HeldHandle(source)
            state.started = ProcessInfo.processInfo.systemUptime
            state.inputThread = HeldHandle(thread)
            threadExit.enter()
            thread.start()
            return true
        }
        if !admitted {
            unsafe CFMachPortInvalidate(ownedTap)
            unsafe CFRunLoopSourceInvalidate(source)
            unsafe CFRunLoopTimerInvalidate(due)
        }
        return admitted
    }

    private static func note(_ event: CGEvent) -> Bool {
        let person = NativePersonInput.isPerson(event)
        let uptime = TimeInterval(event.timestamp) / 1_000_000_000
        clock.withLock { state in
            if person { state.lastPerson = max(state.lastPerson, uptime) }
            else { state.lastSynthetic = max(state.lastSynthetic, uptime) }
        }
        if person { MacBodyNerve.shared.notePersonInput() }
        return person
    }

    /// Settle away once at the idle deadline and here only on person input; then arm the next exact deadline.
    private static func settle() {
        clock.withLock { $0.settleAgain = false }
        let fact = presence()
        if let fact {
            let since = Date().addingTimeInterval((fact.here ? 0 : awayAfter) - fact.seconds)
            let changed = clock.withLock { state in
                let returned = fact.here && (state.returnAfter.map { since > $0 } ?? false)
                guard fact.here == state.away || returned else { return false }
                state.away = !fact.here
                if returned || !fact.here { state.returnAfter = nil }
                state.presenceTransition = (fact.here, since)
                return true
            }
            if changed {
                NotificationCenter.default.post(PresenceChanged(here: fact.here, idleSeconds: fact.seconds.rounded()))
            }
        }
        // Away, nothing is due until their own input says here.
        let wait = clock.withLock { $0.away } ? 315_360_000 : awayAfter - min(fact?.seconds ?? idleAtLeast() ?? 0, awayAfter)
        // Use settleSoon’s lock so intervening input is settled next rather than overwritten.
        clock.withLock { state in
            state.awayDue.map { CFRunLoopTimerSetNextFireDate($0.value, CFAbsoluteTimeGetCurrent() + (state.settleAgain ? 0 : wait)) }
        }
    }

    /// Under `clock`, unseen input is the person’s only when neither pre-tap nor possibly hidden synthetic provenance explains it.
    private static func markUnseen(now: Double, state: inout State) -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null)
        let input = now - idle
        guard idle.isFinite, input > max(state.lastPerson, state.lastSynthetic) + ownEventTolerance else { return false }
        let ownInput = ScriptedInputSources.isRunning
            || abs(idle - secondsSinceLastPostedHIDEvent()) <= ownEventTolerance
        if input > state.started, !ownInput { state.lastPerson = input; return true }
        state.lastBlind = now
        return false
    }

    /// Secure Event Input can hide person input from the tap; settle read-observed input on the owner thread so transitions and deadlines follow.
    private static func settleSoon() {
        clock.withLock { state in
            state.settleAgain = true
            state.awayDue.map { CFRunLoopTimerSetNextFireDate($0.value, CFAbsoluteTimeGetCurrent()) }
        }
    }

    /// Mark missed input before posting so synthetic output cannot make it appear seen; stamp targeted posts here because they bypass the tap.
    static func noteAgentPost(targeted: Bool) {
        guard listening else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let seen = clock.withLock { state in
            let seen = markUnseen(now: now, state: &state)
            if targeted { state.lastSynthetic = now }
            return seen
        }
        if seen { settleSoon() }
    }

    /// No tap or unresolved provenance yields no person-idle number; retain whose input was newest.
    public static func idle() -> (seconds: Double?, lastInput: String)? {
        guard listening, CGPreflightListenEventAccess() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let (seen, idle): (Bool, (seconds: Double?, lastInput: String)) = clock.withLock { state in
            let seen = markUnseen(now: now, state: &state)
            let newest = max(state.lastPerson, state.lastSynthetic)
            return (seen, (state.lastPerson > state.lastBlind ? now - state.lastPerson : nil,
                           newest <= state.lastBlind ? "unknown" : state.lastSynthetic > state.lastPerson ? "agent" : "person"))
        }
        if seen { settleSoon() }
        return idle
    }

    /// Combined idle supplies an absence floor while person provenance is unknown; it can prove away, never here.
    public static func idleAtLeast() -> Double? {
        let any = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null
        )
        return any.isFinite && any >= 0 ? any : nil
    }

    static func hasRecentPersonInput(after boundary: TimeInterval, within threshold: TimeInterval) -> Bool {
        guard !MacBodyNerve.shared.hasActiveForegroundScope else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let age: TimeInterval
        if let monitored = idle() {
            guard let seconds = monitored.seconds else { return false }
            age = seconds
        } else {
            age = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0) ?? .null)
            guard age + ownEventTolerance < secondsSinceLastPostedHIDEvent() else { return false }
        }
        return age >= 0 && age <= threshold && now - age > boundary
    }

    public static let awayAfter: TimeInterval = 300

    /// Repeated reads cannot move an armed phone return or replay a settled one.
    public static func observeReturn(after departure: Date) {
        guard listening else { return }
        let armed = clock.withLock { state in
            if let settled = state.presenceTransition,
               !settled.here || settled.since >= departure { return false }
            if let pending = state.returnAfter, pending <= departure { return false }
            state.returnAfter = departure
            return true
        }
        // Reconcile input that arrived between reading phone evidence and arming the wake, including hidden secure input.
        if armed { settleSoon() }
    }

    /// Presence excludes synthetic input; while provenance is unknown, combined idle may prove away but never here.
    public static func presence() -> (here: Bool, seconds: Double)? {
        let seconds = idle()?.seconds ?? idleAtLeast().flatMap { $0 >= awayAfter ? $0 : nil }
        return seconds.map { ($0 < awayAfter, $0) }
    }

    /// Reads cannot invent arrivals or advance timestamps; only the input owner settles transitions.
    public static func presenceChange() -> (here: Bool, since: Date)? {
        guard let fact = presence() else { return nil }
        return clock.withLock { state in
            guard let transition = state.presenceTransition, transition.here == fact.here else { return nil }
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
