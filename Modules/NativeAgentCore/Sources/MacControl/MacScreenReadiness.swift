import Foundation
import Synchronization
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Senses
import TrustCenter
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// Blueprint: | `MacScreenReadiness.swift` | Session readiness; event-judged automatic screen wake and caller-requested explicit settling |

// MARK: - Login-session state

/// Saver state alone cannot diagnose authentication; only focused secure-field evidence distinguishes a password prompt.
public struct MacSessionState: Sendable, Equatable {
    /// CGSSessionScreenIsLocked covers both locks and plain savers; it gates capture but permits the inert nudge.
    public let screenIsLocked: Bool
    /// Another user’s console ownership forbids capture and input.
    public let onConsole: Bool
    public let displayAsleep: Bool
    /// Missing session evidence is unreadable, never unlocked; refuse before considering any permissive state.
    public let sessionReadable: Bool
    public let frontmostBundleID: String?
    /// A HID post resets idle age, so before/after readings can establish delivery rather than mere submission.
    public let idleSeconds: Double?
    public let cursorX: Double?
    public let cursorY: Double?

    public init(
        screenIsLocked: Bool,
        onConsole: Bool,
        displayAsleep: Bool,
        sessionReadable: Bool = true,
        frontmostBundleID: String? = nil,
        idleSeconds: Double? = nil,
        cursorX: Double? = nil,
        cursorY: Double? = nil
    ) {
        self.screenIsLocked = screenIsLocked
        self.onConsole = onConsole
        self.displayAsleep = displayAsleep
        self.sessionReadable = sessionReadable
        self.frontmostBundleID = frontmostBundleID
        self.idleSeconds = idleSeconds
        self.cursorX = cursorX
        self.cursorY = cursorY
    }

    public var obstructed: Bool {
        screenIsLocked || displayAsleep || frontmostBundleID == MacWakeGuard.loginWindowBundleID
    }

    public func toJSON() -> JSONValue {
        .object([
            // The saver flag does not prove a password lock.
            "saver_layer_up": .bool(screenIsLocked),
            "on_console": .bool(onConsole),
            "display_asleep": .bool(displayAsleep),
            "session_readable": .bool(sessionReadable),
            "frontmost": frontmostBundleID.map { .string($0) } ?? .null,
            "idle_seconds": idleSeconds.map { .double(($0 * 10).rounded() / 10) } ?? .null,
            // Observed positions let the receipt establish pointer restoration.
            "cursor_x": cursorX.map { .double(($0 * 10).rounded() / 10) } ?? .null,
            "cursor_y": cursorY.map { .double(($0 * 10).rounded() / 10) } ?? .null,
        ])
    }
}

public protocol MacSessionStateSource: Sendable {
    func currentState() -> MacSessionState
}

/// Nudge only a readable console session; inert input cannot authenticate and capture still refuses while covered.
public enum MacWakeGuard {
    public static let loginWindowBundleID = "com.apple.loginwindow"

    /// The capture refusal describes a remaining saver/login obstruction; the session flag alone cannot diagnose a password lock.
    public static let stillObstructedRefusal =
        "display_obstructed: the nudge was delivered (pointer move + shift tap, which cannot "
        + "type text or click anything), but the screensaver/login layer is still covering the "
        + "screen, so there is nothing to photograph yet. If this keeps happening after "
        + "retries, the screen needs a human at the keyboard."

    public static let sessionUnreadableRefusal =
        "session_unreadable: this Mac would not report its login session state, and an "
        + "unreadable session is not an unlocked one, so mac_wake refuses rather than nudge blind."

    public static let notOnConsoleRefusal =
        "session_not_on_console: another login session owns the display, so a nudge from this "
        + "session would not reach it."

    public static func nudgeRefusalReason(for state: MacSessionState) -> String? {
        guard state.sessionReadable else { return sessionUnreadableRefusal }
        guard state.onConsole else { return notOnConsoleRefusal }
        return nil
    }

    /// The guard covers screenshot, marks, legend and view id; an obstructed screen must never become captured data.
    public static func captureRefusalReason(for state: MacSessionState) -> String? {
        guard state.sessionReadable else { return sessionUnreadableRefusal }
        guard state.onConsole else { return notOnConsoleRefusal }
        guard state.screenIsLocked else { return nil }
        return stillObstructedRefusal
    }
}

/// All read, act, send and home paths share readiness; saver state alone never proves a password lock.
public enum MacScreenLock {
    public static func personAway() -> Bool {
        MacPersonInput.presence()?.here == false
    }

    public static let reply = "The screen is still covered, so I can't see or use the apps underneath."
    public static let passiveReply = "raw view · passive observation · screen covered; observation waits"

    /// Observe wake’s session/window evidence without posting input.
    public static func isCovered() throws -> Bool {
        let state = defaultMacSessionStateSource().currentState()
        guard state.sessionReadable else {
            throw Covered(detail: "The macOS screen session could not be read. Read the screen again after restoring session access.",
                code: "screen_readiness_unavailable")
        }
        return try state.screenIsLocked || loginWindowUp()
    }

    private static func loginWindowUp() throws -> Bool {
        #if canImport(CoreGraphics) && os(macOS)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            throw Covered(
                detail: "The window server did not return its on-screen window inventory. Read the screen again after restoring window-server access.",
                code: "screen_readiness_unavailable")
        }
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String else {
                throw Covered(detail: "An on-screen window has unreadable owner identity. Read the screen again before using the apps underneath.",
                    code: "screen_readiness_unavailable")
            }
            guard owner == "loginwindow" else { continue }
            guard let layer = window[kCGWindowLayer as String] as? Int else {
                throw Covered(detail: "The login window's layer could not be read. Read the screen again before using the apps underneath.",
                    code: "screen_readiness_unavailable")
            }
            if layer >= Int(CGWindowLevelForKey(.screenSaverWindow)) { return true }
        }
        return false
        #else
        throw Covered(detail: "Window-server readiness is unavailable on this platform.", code: "screen_readiness_unavailable")
        #endif
    }

    /// Focused-password evidence survives covered wakes; LatestRead orders publication.
    public static var wakeFailed: Bool { passwordFocusedAfterWake.withLock { $0 == true } }
    private static let passwordFocusedAfterWake = Mutex<Bool?>(nil)
    private typealias WakeResult = (before: MacSessionState, after: MacSessionState, mouseEvents: Int, keyEvents: Int)
    private actor WakeReads {
        private let latest = LatestRead()
        func read(_ load: @Sendable () async -> Result<WakeResult, Error>) async -> Result<WakeResult, Error> {
            await latest.read(load) { result in
                passwordFocusedAfterWake.withLock { focused in
                    if case .failure(let error) = result {
                        focused = (error as? Covered)?.code == "mac_locked" ? true : nil
                    } else if case .success(let wake) = result, !wake.after.obstructed {
                        focused = false
                    }
                }
            }
        }
    }
    private static let wakeReads = WakeReads()

    public static func isLocked() -> Bool {
        defaultMacSessionStateSource().currentState().screenIsLocked
    }

    public struct Covered: Error, Sendable {
        public let detail: String
        public let code: String
        public init(detail: String, code: String = "display_obstructed") {
            self.detail = detail
            self.code = code
        }
    }

    /// Automatic readiness allows two nudges; explicit settling requests one even when uncovered, with observed evidence.
    @discardableResult
    @concurrent public static func wakeIfCovered(
        source: any MacSessionStateSource = defaultMacSessionStateSource(),
        before: MacSessionState? = nil, keyTap: Bool = true, settleMs: Int? = nil,
        turn: Turn, context: MacOperationContext, beforeInput: @Sendable () async throws -> Void = {}) async throws -> (before: MacSessionState,
            after: MacSessionState, mouseEvents: Int, keyEvents: Int) {
        let result: Result<(before: MacSessionState, after: MacSessionState, mouseEvents: Int, keyEvents: Int), Error> = await wakeReads.read {
            do {
                return .success(try await performWakeIfCovered(source: source, before: before, keyTap: keyTap, settleMs: settleMs, turn: turn,
                    context: context, beforeInput: beforeInput))
            } catch { return .failure(error) }
        }
        return try result.get()
    }

    private static func performWakeIfCovered(
        source: any MacSessionStateSource, before: MacSessionState?,
        keyTap: Bool, settleMs: Int?, turn: Turn, context: MacOperationContext,
            beforeInput: @Sendable () async throws -> Void) async throws -> (before: MacSessionState, after: MacSessionState, mouseEvents: Int,
            keyEvents: Int) {
        let before = before ?? source.currentState()
        if let reason = MacWakeGuard.nudgeRefusalReason(for: before) {
            throw Covered(detail: reason)
        }
        var after = before
        var mouseEvents = 0
        var keyEvents = 0
        #if canImport(CoreGraphics) && canImport(AppKit) && os(macOS)
        func covered() throws -> Bool {
            guard after.sessionReadable else { throw Covered(detail: "The macOS screen session could not be read.", code: "screen_readiness_unavailable") }
            return try after.screenIsLocked || loginWindowUp()
        }
        func loginPasswordFocused() -> Bool {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            guard let app = MacAXAttributeRead.copyElement(system, kAXFocusedApplicationAttribute, context: context) else { return false }
            var pid: pid_t = 0
            guard AXUIElementGetPid(app, &pid) == .success,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == MacWakeGuard.loginWindowBundleID else { return false }
            AXUIElementSetMessagingTimeout(app, 0.2)
            guard let field = MacAXAttributeRead.copyElement(app, kAXFocusedUIElementAttribute, context: context) else { return false }
            return MacAXAttributeRead.copyString(field, kAXRoleAttribute, context: context) == kAXSecureTextFieldSubrole
                || MacAXAttributeRead.copyString(field, kAXSubroleAttribute, context: context) == kAXSecureTextFieldSubrole
        }
        guard try settleMs != nil || covered() else { return (before, after, 0, 0) }
        guard AXIsProcessTrusted() else {
            throw Covered(detail: "Accessibility permission is required to wake the screensaver; no input was sent.")
        }
        let driver: MacDriverBinding
        if let binding = context.driver { driver = binding }
        else { driver = try await MacAttentionSessionStore.shared.bindDriver() }
        let personActive = Covered(detail: MacAttentionSessionStore.driverRefusal(context: context), code: "human_takeover")
        let inputUnavailable = Covered(detail: "I couldn't create the safe screensaver wake input.")
        for attempt in 0..<(settleMs == nil ? 2 : 1) {
            if attempt > 0 {
                after = source.currentState()
                if let reason = MacWakeGuard.nudgeRefusalReason(for: after) { throw Covered(detail: reason) }
                if try !covered() { return (before, after, mouseEvents, keyEvents) }
            }
            try Task.checkCancellation()
            guard MacPersonInput.activeSecondsAgo() == nil else { throw personActive }
            guard let x = after.cursorX, let y = after.cursorY else { throw inputUnavailable }
            let origin = CGPoint(x: x, y: y)
            guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x + 1, y: y), mouseButton: .left),
                  let back = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: origin, mouseButton: .left),
                  let shiftDown = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true),
                  let shiftUp = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: false) else { throw inputUnavailable }
            for event in [move, back, shiftDown, shiftUp] {
                event.setIntegerValueField(.eventSourceUserData, value: NativeAgentMacEventIdentity.sourceUserData)
            }
            let collector = MacAXEffectCollector()
            let signals = MacWaitSignals(collector: collector)
            var observers: [(NotificationCenter, NSObjectProtocol)] = []
            if settleMs == nil {
                let distributed = DistributedNotificationCenter.default()
                let notifications: [(NotificationCenter, Notification.Name)] = [
                    (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
                    (distributed, Notification.Name("com.apple.screensaver.didstop")),
                    (distributed, Notification.Name("com.apple.screenIsUnlocked")),
                ]
                // Arm before posting input so a fast dismissal remains in the collector.
                observers = notifications.map { center, name in
                    let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                        collector.record(MacAXEffectNotification(kind: name.rawValue, at: Date()))
                    }
                    return (center, token)
                }
            }
            defer {
                for (center, token) in observers { center.removeObserver(token) }
                signals.stop()
            }
            for move in [move, back] {
                try await beforeInput()
                try Task.checkCancellation()
                guard driver.allowsEmission(context: context), MacPersonInput.activeSecondsAgo() == nil else { throw personActive }
                NativeAgentMotorEpoch.notePostedHIDEvent()
                move.post(tap: .cghidEventTap)
                driver.notePostedEvent(turn: turn)
                mouseEvents += 1
            }
            if keyTap {
                try await beforeInput()
                try Task.checkCancellation()
                guard driver.allowsEmission(context: context), MacPersonInput.activeSecondsAgo() == nil else { throw personActive }
                // Once pressed, Shift is released without an interruptible gap.
                for (key, down) in [(shiftDown, true), (shiftUp, false)] {
                    key.flags = down ? .maskShift : []
                    NativeAgentMotorEpoch.notePostedHIDEvent()
                    key.post(tap: .cghidEventTap)
                    driver.notePostedEvent(turn: turn)
                    keyEvents += 1
                }
            }
            if let settleMs {
                if settleMs > 0 { try await Task.sleep(for: .milliseconds(settleMs)) }
                after = source.currentState()
                return (before, after, mouseEvents, keyEvents)
            }
            var readFailure: Error?
            let end = await macSettle("screen_wake", signals: signals, patience: 3) {
                after = source.currentState()
                do {
                    if let reason = MacWakeGuard.nudgeRefusalReason(for: after) { throw Covered(detail: reason) }
                    return try !covered()
                } catch {
                    readFailure = error
                    throw error
                }
            }
            try Task.checkCancellation()
            if let readFailure { throw readFailure }
            if end == .held { return (before, after, mouseEvents, keyEvents) }
        }
        let loginWindow = try loginWindowUp()
        // Focused secure fields prove authentication UI; loginwindow alone may be a passwordless saver.
        let locked = loginWindow && !after.displayAsleep && loginPasswordFocused()
        throw Covered(detail: after.displayAsleep
            ? "The display stayed asleep after two wake nudges."
            : locked
            ? "The login window has a focused password field after two wake nudges, so the Mac is locked. A person must sign in; I won't try to unlock it."
            : loginWindow
            ? "The loginwindow layer is still in front after two wake nudges; I couldn't confirm a password prompt."
            : "The screen is still covered after two wake nudges (macOS still reports the saver/login layer up, with no login window showing).",
            code: locked ? "mac_locked" : "display_obstructed")
        #else
        throw Covered(detail: "Screen readiness is unavailable on this platform.")
        #endif
    }
}

extension SwiftNativeMacControl {
    // MARK: wake

    /// Allow the window server time to dismiss the saver before recapturing, or the receipt may still describe the dismissed layer.
    static let wakeDefaultSettleMs = 700
    static let wakeMaxSettleMs = 3000

    /// Recheck after the bounded nudge and preserve observed wake, restoration and redaction evidence.
    func handleWake(_ body: [String: JSONValue], turn: Turn, context: MacOperationContext) async -> MacControlResult {
        let started = now()

        let before = sessionStateSource.currentState()
        guard before.sessionReadable else {
            return injectionRefusal(action: "wake",
                error: """
                    session_state_unavailable: this build or this Mac would not report the login session, and an unreadable session is not an unlocked one, so \
                    it will not nudge blind
                    """,
                status: 503)
        }

        // Refuse before any input when this session does not own the console.
        if let reason = MacWakeGuard.nudgeRefusalReason(for: before) {
            return injectionRefusal(
                action: "wake",
                error: reason,
                status: 403,
                extra: ["session_before": before.toJSON()]
            )
        }

        // Without Accessibility, the window server swallows CGEventPost; enforce the same grant and sink gates as other input.
        if let refusal = injectionPreconditions(action: "wake", requiresSink: true, context: context) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "wake", body: body, turn: turn, context: context) {
            return refusal
        }

        guard before.cursorX != nil, before.cursorY != nil else {
            return injectionRefusal(action: "wake",
                error: "cursor_position_unreadable: this Mac would not report where the pointer is, so it will not nudge at a guessed origin",
                status: 503, extra: ["session_before": before.toJSON()])
        }
        let settleMs = max(0, min(
            body["settle_ms"]?.integerValue.flatMap(Int.init(exactly:)) ?? Self.wakeDefaultSettleMs,
            Self.wakeMaxSettleMs
        ))
        let after: MacSessionState
        let mouseEvents: Int
        let keyEvents: Int
        do {
            let wake = try await MacScreenLock.wakeIfCovered(
                source: sessionStateSource, before: before,
                keyTap: body["key_tap"] != .bool(false), settleMs: settleMs
            , turn: turn, context: context) {
                if let refusal = await self.attentionActionRefusal(action: "wake", body: body, turn: turn, context: context) {
                    throw WakeAttentionRefusal(result: refusal)
                }
            }
            after = wake.after
            mouseEvents = wake.mouseEvents
            keyEvents = wake.keyEvents
        } catch let refusal as WakeAttentionRefusal {
            await screenViewStore.invalidate()
            return refusal.result
        } catch {
            await screenViewStore.invalidate()
            return injectionRefusal(action: "wake", error: (error as? MacScreenLock.Covered)?.detail ?? error.localizedDescription)
        }
        await screenViewStore.invalidate()

        // Incremental construction keeps the receipt within Swift's type-check budget.
        var wake: [String: JSONValue] = [:]
        wake["nudged"] = .bool(true)
        wake["mouse_events"] = .int(Int64(mouseEvents))
        wake["key_events"] = .int(Int64(keyEvents))
        wake["settle_ms"] = .int(Int64(settleMs))
        wake["was_obstructed"] = .bool(before.obstructed)
        // Restoration is the observed position comparison, or null.
        wake["nudge_origin"] = .object([
            "x": before.cursorX.map { JSONValue.double(($0 * 10).rounded() / 10) } ?? .null,
            "y": before.cursorY.map { JSONValue.double(($0 * 10).rounded() / 10) } ?? .null,
        ])
        wake["pointer_restored"] = Self.pointerRestoredJSON(before: before, after: after)

        // Recheck capture authority from the post-nudge session observation.
        if let reason = MacWakeGuard.captureRefusalReason(for: after) {
            wake["dismissed"] = .bool(false)
            wake["still_obstructed"] = .bool(true)
            wake["note"] = .string(
                "The nudge was delivered and the saver/login layer is still covering "
                    + "the screen, so nothing was photographed or read back. Retrying "
                    + "can help; a screen that never clears needs a human at the "
                    + "keyboard."
            )
            return injectionRefusal(
                action: "wake",
                error: reason,
                status: 403,
                extra: [
                    "session_before": before.toJSON(),
                    "session_after": after.toJSON(),
                    "wake": .object(wake),
                ]
            )
        }
        if let refusal = await attentionActionRefusal(action: "wake", body: body, turn: turn, context: context) {
            return refusal
        }

        let dismissed = !after.obstructed
        let view = await handleView(body, context: context)
        if let refusal = await attentionActionRefusal(action: "wake", body: body, turn: turn, context: context) {
            await screenViewStore.invalidate()
            return refusal
        }

        var output: [String: JSONValue]
        if case .object(let viewOutput) = view.output {
            output = viewOutput
        } else {
            output = [:]
        }
        wake["dismissed"] = .bool(dismissed)
        wake["session_before"] = before.toJSON()
        wake["session_after"] = after.toJSON()
        // Falling idle time across the nudge is evidence the HID post landed.
        wake["idle_reset"] = .bool({
            guard let b = before.idleSeconds, let a = after.idleSeconds else { return false }
            return a < b
        }())
        wake["note"] = .string(
            dismissed
                ? "The screen is awake and showing the real desktop — the view below is it."
                : "The nudge (pointer move + shift tap) was posted but the screen still "
                    + "reports a sleeping display or the saver layer. Retry, or try a larger "
                    + "settle_ms."
        )
        output["wake"] = .object(wake)
        // Verification must use the post-nudge session read rather than an asserted success.
        output["verified"] = .bool(dismissed)
        return MacControlResult(
            ok: view.ok,
            action: "wake",
            output: .object(output),
            error: view.error,
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        )
    }
}

#if canImport(CoreGraphics) && os(macOS)

public struct SystemMacSessionStateSource: MacSessionStateSource {
    public init() {}

    public func currentState() -> MacSessionState {
        // Unreadable session state refuses closed; empty defaults must not fabricate an unlocked console.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["kCGSSessionOnConsoleKey"] != nil else {
            return MacSessionState(
                screenIsLocked: true,
                onConsole: false,
                displayAsleep: false,
                sessionReadable: false,
                idleSeconds: Self.idleSeconds()
            )
        }
        func flag(_ key: String, default def: Bool) -> Bool {
            if let number = session[key] as? NSNumber { return number.boolValue }
            if let value = session[key] as? Bool { return value }
            return def
        }
        // macOS omits CGSSessionScreenIsLocked when uncovered, but the console key is required for a readable session.
        let locked = flag("CGSSessionScreenIsLocked", default: false)
        let onConsole = flag("kCGSSessionOnConsoleKey", default: false)
        var frontmost: String?
        #if canImport(AppKit)
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        #endif
        let cursor = CGEvent(source: nil)?.location
        return MacSessionState(
            screenIsLocked: locked,
            onConsole: onConsole,
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            sessionReadable: true,
            frontmostBundleID: frontmost,
            idleSeconds: Self.idleSeconds(),
            cursorX: cursor?.x.native,
            cursorY: cursor?.y.native
        )
    }

    private static func idleSeconds() -> Double? {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return nil }
        let value = CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: anyEvent
        )
        return value.isFinite ? value : nil
    }

}

#endif

/// Unsupported platforms report unavailability rather than a fabricated unlocked state.
public struct UnavailableMacSessionStateSource: MacSessionStateSource {
    public init() {}
    public func currentState() -> MacSessionState {
        MacSessionState(
            screenIsLocked: true,
            onConsole: false,
            displayAsleep: false,
            sessionReadable: false
        )
    }
}

public func defaultMacSessionStateSource() -> any MacSessionStateSource {
    #if canImport(CoreGraphics) && os(macOS)
    return SystemMacSessionStateSource()
    #else
    return UnavailableMacSessionStateSource()
    #endif
}
