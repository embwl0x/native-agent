import Foundation
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

// Blueprint: | `MacScreenReadiness.swift` | `MacSessionState`, its sources, `MacWakeGuard`, `MacScreenLock.wakeIfCovered` and `SwiftNativeMacControl.handleWake`: checked console/display readiness, bounded inert wake, focused-password evidence ordered through LatestRead and fused-view wake receipts |

// MARK: - Login-session state

/// A read-only snapshot of the login session and display, taken immediately
/// before and immediately after a wake nudge.
///
/// The saver flag alone cannot distinguish a password prompt; only focused
/// secure-field evidence supplies that diagnosis.
public struct MacSessionState: Sendable, Equatable {
    /// `CGSSessionScreenIsLocked` — true for a password lock AND for a plain
    /// screensaver, with nothing in the session dictionary separating them.
    /// True therefore means the saver/login layer is obstructing capture; it
    /// does not prevent the inert nudge. See `MacWakeGuard`.
    public let screenIsLocked: Bool
    /// `kCGSSessionOnConsoleKey` — false when another user owns the display.
    public let onConsole: Bool
    /// `CGDisplayIsAsleep(CGMainDisplayID())`.
    public let displayAsleep: Bool
    /// False when the probe could not actually READ the login session —
    /// `CGSessionCopyCurrentDictionary()` returned nil, or came back without the
    /// keys this decision rests on. An unreadable session is not an unlocked
    /// one, so the guard refuses on it before it looks at anything else.
    public let sessionReadable: Bool
    public let frontmostBundleID: String?
    /// `CGEventSource.secondsSinceLastEventType` — the orthogonal observer.
    /// A successful HID post resets it to ~0, so before/after readings are
    /// EVIDENCE that the event landed rather than a claim that it was sent.
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

    /// True when the screen was in a state a nudge could plausibly clear.
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
            // Observed coordinates let the receipt show pointer restoration.
            "cursor_x": cursorX.map { .double(($0 * 10).rounded() / 10) } ?? .null,
            "cursor_y": cursorY.map { .double(($0 * 10).rounded() / 10) } ?? .null,
        ])
    }
}

/// One checked observation of session, display and pointer evidence.
public protocol MacSessionStateSource: Sendable {
    func currentState() -> MacSessionState
}

/// Nudge only a readable console session. The inert move and bare Shift tap
/// cannot authenticate; capture still refuses while the saver layer is up.
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

    /// Readability and console ownership gate the inert wake sequence.
    public static func nudgeRefusalReason(for state: MacSessionState) -> String? {
        guard state.sessionReadable else { return sessionUnreadableRefusal }
        guard state.onConsole else { return notOnConsoleRefusal }
        return nil
    }

    /// THE CAPTURE GUARD. Governs the screenshot, the marks, the legend and the
    /// view id — everything that turns the screen into data. An obstructed
    /// screen (the saver/login layer still up after the nudge) is never
    /// photographed; that is the entire remaining safety line, and it needs no
    /// lock vocabulary to hold.
    public static func captureRefusalReason(for state: MacSessionState) -> String? {
        guard state.sessionReadable else { return sessionUnreadableRefusal }
        guard state.onConsole else { return notOnConsoleRefusal }
        guard state.screenIsLocked else { return nil }
        return stillObstructedRefusal
    }
}

/// Shared screen readiness for reads, acts, desktop sends and home's MAC line.
/// `CGSSessionScreenIsLocked` also covers a passwordless saver, hiding app
/// windows in both cases. The bounded wake names the remaining obstruction;
/// the session flag alone never proves a password lock.
public enum MacScreenLock {
    public static func personAway() -> Bool {
        MacPersonInput.presence()?.here == false
    }

    public static let reply = "The screen is still covered, so I can't see or use the apps underneath."
    public static let passiveReply = "raw view · passive observation · screen covered; observation waits"

    /// The same session/window evidence used by wake, without posting input.
    public static func isCovered() -> Bool {
        isLocked() || loginWindowUp()
    }

    private static func loginWindowUp() -> Bool {
        #if canImport(CoreGraphics) && os(macOS)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains {
            $0[kCGWindowOwnerName as String] as? String == "loginwindow"
                && ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.screenSaverWindow))
        }
        #else
        return false
        #endif
    }

    /// Focused-password evidence survives covered wakes; LatestRead orders publication.
    public static var wakeFailed: Bool { wakeLock.withLock { passwordFocusedAfterWake == true } }
    private static let wakeLock = NSLock()
    @MainActor private static let wakeReads = LatestRead()
    nonisolated(unsafe) private static var passwordFocusedAfterWake: Bool?

    public static func isLocked() -> Bool {
        defaultMacSessionStateSource().currentState().screenIsLocked
    }

    /// What still covers the screen after `wakeIfCovered` gave up.
    public struct Covered: Error, Sendable {
        public let detail: String
        public let code: String
        public init(detail: String, code: String = "display_obstructed") {
            self.detail = detail
            self.code = code
        }
    }

    /// Automatic readiness retries twice; an explicit settle interval requests
    /// one nudge even on an uncovered screen and returns its observed evidence.
    @discardableResult
    @MainActor public static func wakeIfCovered(
        source: any MacSessionStateSource = defaultMacSessionStateSource(),
        before: MacSessionState? = nil, keyTap: Bool = true, settleMs: Int? = nil,
        beforeInput: @Sendable () async throws -> Void = {}
    ) async throws -> (before: MacSessionState, after: MacSessionState, mouseEvents: Int, keyEvents: Int) {
        let result: Result<(before: MacSessionState, after: MacSessionState, mouseEvents: Int, keyEvents: Int), Error> = await wakeReads.read {
            do {
                return .success(try await performWakeIfCovered(source: source, before: before,
                    keyTap: keyTap, settleMs: settleMs, beforeInput: beforeInput))
            } catch { return .failure(error) }
        } publish: { result in
            wakeLock.withLock {
                if case .failure(let error) = result {
                    passwordFocusedAfterWake = (error as? Covered)?.code == "mac_locked" ? true : nil
                } else if case .success(let wake) = result, !wake.after.obstructed {
                    passwordFocusedAfterWake = false
                }
            }
        }
        return try result.get()
    }

    private static func performWakeIfCovered(
        source: any MacSessionStateSource, before: MacSessionState?,
        keyTap: Bool, settleMs: Int?, beforeInput: @Sendable () async throws -> Void
    ) async throws -> (before: MacSessionState, after: MacSessionState, mouseEvents: Int, keyEvents: Int) {
        let before = before ?? source.currentState()
        if let reason = MacWakeGuard.nudgeRefusalReason(for: before) {
            throw Covered(detail: reason)
        }
        var after = before
        var mouseEvents = 0
        var keyEvents = 0
        #if canImport(CoreGraphics) && canImport(AppKit) && os(macOS)
        func covered() -> Bool { after.screenIsLocked || loginWindowUp() }
        func loginPasswordFocused() -> Bool {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            guard let app = MacAXAttributeRead.copyElement(system, kAXFocusedApplicationAttribute) else { return false }
            var pid: pid_t = 0
            guard AXUIElementGetPid(app, &pid) == .success,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == MacWakeGuard.loginWindowBundleID else { return false }
            AXUIElementSetMessagingTimeout(app, 0.2)
            guard let field = MacAXAttributeRead.copyElement(app, kAXFocusedUIElementAttribute) else { return false }
            return MacAXAttributeRead.copyString(field, kAXRoleAttribute) == kAXSecureTextFieldSubrole
                || MacAXAttributeRead.copyString(field, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
        }
        guard settleMs != nil || covered() else { return (before, after, 0, 0) }
        guard AXIsProcessTrusted() else {
            throw Covered(detail: "Accessibility permission is required to wake the screensaver; no input was sent.")
        }
        let driver: MacDriverBinding
        if let binding = MacDriverContext.binding { driver = binding }
        else { driver = await MacAttentionSessionStore.shared.bindDriver() }
        let personActive = Covered(detail: "Someone is using the Mac right now, so I stopped the wake nudge.")
        let inputUnavailable = Covered(detail: "I couldn't create the safe screensaver wake input.")
        for attempt in 0..<(settleMs == nil ? 2 : 1) {
            if attempt > 0 {
                after = source.currentState()
                if let reason = MacWakeGuard.nudgeRefusalReason(for: after) { throw Covered(detail: reason) }
                if !covered() { return (before, after, mouseEvents, keyEvents) }
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
            for move in [move, back] {
                try await beforeInput()
                try Task.checkCancellation()
                guard driver.allowsEmission, MacPersonInput.activeSecondsAgo() == nil else { throw personActive }
                NativeAgentMotorEpoch.notePostedHIDEvent()
                move.post(tap: .cghidEventTap)
                driver.notePostedEvent()
                mouseEvents += 1
            }
            if keyTap {
                try await beforeInput()
                try Task.checkCancellation()
                guard driver.allowsEmission, MacPersonInput.activeSecondsAgo() == nil else { throw personActive }
                // Once pressed, Shift is released without an interruptible gap.
                for (key, down) in [(shiftDown, true), (shiftUp, false)] {
                    key.flags = down ? .maskShift : []
                    NativeAgentMotorEpoch.notePostedHIDEvent()
                    key.post(tap: .cghidEventTap)
                    driver.notePostedEvent()
                    keyEvents += 1
                }
            }
            if let settleMs {
                if settleMs > 0 { try await Task.sleep(for: .milliseconds(settleMs)) }
                after = source.currentState()
                return (before, after, mouseEvents, keyEvents)
            }
            for _ in 0..<15 {
                try await Task.sleep(for: .milliseconds(200))
                after = source.currentState()
                if let reason = MacWakeGuard.nudgeRefusalReason(for: after) { throw Covered(detail: reason) }
                if !covered() { return (before, after, mouseEvents, keyEvents) }
            }
        }
        let loginWindow = loginWindowUp()
        // A focused secure field is positive authentication evidence;
        // loginwindow alone also draws passwordless savers.
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

    /// The default settle wait between the nudge and the re-capture. The window
    /// server needs a beat to tear the saver down; capturing at zero would
    /// photograph the thing we just dismissed and report it as the screen.
    static let wakeDefaultSettleMs = 700
    static let wakeMaxSettleMs = 3000

    /// Nudge only a readable console session, recheck after settling, then return the
    /// fresh fused view with observed wake and pointer-restoration evidence. The saver
    /// flag gates capture, not the inert nudge; top-level view delivery retains redaction.
    func handleWake(_ body: [String: JSONValue]) async -> MacControlResult {
        let started = now()

        let before = sessionStateSource.currentState()
        guard before.sessionReadable else {
            return injectionRefusal(action: "wake",
                error: "session_state_unavailable: this build or this Mac would not report the login session, and an unreadable session is not an unlocked one, so it will not nudge blind",
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

        // The same TCC + sink preconditions every injection handler applies.
        //    Without the Accessibility grant CGEventPost is swallowed by the
        //    window server, and reporting "woken" would be a lie.
        if let refusal = injectionPreconditions(action: "wake", requiresSink: true) {
            return refusal
        }
        if let refusal = await attentionActionRefusal(action: "wake", body: body) {
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
            ) {
                if let refusal = await self.attentionActionRefusal(action: "wake", body: body) {
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
        if let refusal = await attentionActionRefusal(action: "wake", body: body) {
            return refusal
        }

        let dismissed = !after.obstructed
        let view = await handleView(body)
        if let refusal = await attentionActionRefusal(action: "wake", body: body) {
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
        // `verified` is OBSERVED, not asserted: it is the post-nudge session
        // re-read, which is what `verificationState` picks up.
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

/// Live session probe.
public struct SystemMacSessionStateSource: MacSessionStateSource {
    public init() {}

    public func currentState() -> MacSessionState {
        // FAIL CLOSED. An unreadable session yields a state that the guard
        // refuses on — locked, off-console, unreadable — never an empty
        // dictionary whose defaults read as "unlocked and on console".
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
        // Absent `CGSSessionScreenIsLocked` means "not locked" — macOS publishes
        // the key while the lock/saver UI is up. The console key is not allowed
        // to be absent at all: its absence made the dictionary unreadable above,
        // rather than defaulting to a permissive `true`.
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

/// Platform fallback: honest unavailability, never a fabricated "unlocked".
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
