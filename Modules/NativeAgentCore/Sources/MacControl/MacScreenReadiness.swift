import Foundation
import Synchronization
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Senses
import TrustCenter
import CoreGraphics
import AppKit
import ApplicationServices
import UserNotifications

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
}

public protocol MacSessionStateSource: Sendable {
    func currentState() -> MacSessionState
}

/// Nudge only a readable console session; inert input cannot authenticate and capture still refuses while covered.
public enum MacWakeGuard {
    public static let loginWindowBundleID = "com.apple.loginwindow"

    public static let sessionUnreadableRefusal =
        "session_unreadable: this Mac would not report its login session state, and an "
        + "unreadable session is not an unlocked one, so the wake refuses rather than nudge blind."

    public static let notOnConsoleRefusal =
        "session_not_on_console: another login session owns the display, so a nudge from this "
        + "session would not reach it."

    public static func nudgeRefusalReason(for state: MacSessionState) -> String? {
        guard state.sessionReadable else { return sessionUnreadableRefusal }
        guard state.onConsole else { return notOnConsoleRefusal }
        return nil
    }
}

/// All read, act, send and home paths share readiness; saver state alone never proves a password lock.
public enum MacScreenLock {
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

    /// Readiness allows two nudges, each settled on observed evidence.
    @discardableResult
    @concurrent public static func wakeIfCovered(
        source: any MacSessionStateSource = defaultMacSessionStateSource(),
        before: MacSessionState? = nil, keyTap: Bool = true,
        turn: Turn, context: MacOperationContext, beforeInput: @Sendable () async throws -> Void = {}) async throws -> (before: MacSessionState,
            after: MacSessionState, mouseEvents: Int, keyEvents: Int) {
        let result: Result<(before: MacSessionState, after: MacSessionState, mouseEvents: Int, keyEvents: Int), Error> = await wakeReads.read {
            do {
                return .success(try await performWakeIfCovered(source: source, before: before, keyTap: keyTap, turn: turn,
                    context: context, beforeInput: beforeInput))
            } catch { return .failure(error) }
        }
        return try result.get()
    }

    private static func performWakeIfCovered(
        source: any MacSessionStateSource, before: MacSessionState?,
        keyTap: Bool, turn: Turn, context: MacOperationContext,
            beforeInput: @Sendable () async throws -> Void) async throws -> (before: MacSessionState, after: MacSessionState, mouseEvents: Int,
            keyEvents: Int) {
        let before = before ?? source.currentState()
        if let reason = MacWakeGuard.nudgeRefusalReason(for: before) {
            throw Covered(detail: reason)
        }
        var after = before
        var mouseEvents = 0
        var keyEvents = 0
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
        guard try covered() else { return (before, after, 0, 0) }
        guard AXIsProcessTrusted() else {
            throw Covered(detail: "Accessibility permission is required to wake the screensaver; no input was sent.")
        }
        let driver: MacDriverBinding
        if let binding = context.driver { driver = binding }
        else { driver = try await MacAttentionSessionStore.shared.bindDriver() }
        let personActive = Covered(detail: MacAttentionSessionStore.driverRefusal(context: context), code: "human_takeover")
        let inputUnavailable = Covered(detail: "I couldn't create the safe screensaver wake input.")
        for attempt in 0..<2 {
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
            let distributed = DistributedNotificationCenter.default()
            let notifications: [(NotificationCenter, Notification.Name)] = [
                (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
                (distributed, Notification.Name("com.apple.screensaver.didstop")),
                (distributed, Notification.Name("com.apple.screenIsUnlocked")),
            ]
            // Arm before posting input so a fast dismissal remains in the collector.
            let observers: [(NotificationCenter, NSObjectProtocol)] = notifications.map { center, name in
                let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    collector.record(MacAXEffectNotification(kind: name.rawValue, at: Date()))
                }
                return (center, token)
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
    }
}


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
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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


public func defaultMacSessionStateSource() -> any MacSessionStateSource {
    return SystemMacSessionStateSource()
}
