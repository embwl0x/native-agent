import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Legacy HTTP seam

/// Retained temporarily for older constructor call sites. SwiftNativeMacControl
/// does not call this in the zero-daemon runtime.
public protocol HTTPClient: Sendable {
    func postJSON(
        url: URL,
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, data: Data)
}

public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }
    public func postJSON(
        url: URL,
        body: Data,
        timeout: TimeInterval
    ) async throws -> (status: Int, data: Data) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

// MARK: - Result type

public struct MacControlResult: Sendable, Equatable {
    public let ok: Bool
    public let action: String
    public let output: JSONValue
    public let error: String?
    public let durationMs: Int
    /// True for Swift-handled results. Zero-daemon MacControl always returns
    /// Swift-shaped results.
    public let viaSwift: Bool
    /// Status code hint for refusal/unsupported results. Successful native
    /// in-process results leave this nil.
    public let httpStatus: Int?
    /// Durable payload-free operation identity. Present when a canonical
    /// MacControlOperationStore owns this dispatch.
    public let operationId: String?
    public let operationState: MacControlOperationState?
    public let verification: MotorVerificationState?

    public init(
        ok: Bool,
        action: String,
        output: JSONValue,
        error: String?,
        durationMs: Int,
        viaSwift: Bool,
        httpStatus: Int? = nil,
        operationId: String? = nil,
        operationState: MacControlOperationState? = nil,
        verification: MotorVerificationState? = nil
    ) {
        self.ok = ok
        self.action = action
        self.output = output
        self.error = error
        self.durationMs = durationMs
        self.viaSwift = viaSwift
        self.httpStatus = httpStatus
        self.operationId = operationId
        self.operationState = operationState
        self.verification = verification
    }

    public func toJSON() -> JSONValue {
        .object([
            "ok": .bool(ok),
            "action": .string(action),
            "output": output,
            "error": error.map { .string($0) } ?? .null,
            "durationMs": .int(Int64(durationMs)),
            "viaSwift": .bool(viaSwift),
            "httpStatus": httpStatus.map { .int(Int64($0)) } ?? .null,
            "operationId": operationId.map { .string($0) } ?? .null,
            "operationState": operationState.map { .string($0.rawValue) } ?? .null,
            "verification": verification.map { .string($0.rawValue) } ?? .null,
        ])
    }
}

public struct MacControlCancellationResult: Sendable, Equatable {
    public let operationId: String
    public let state: MacControlOperationState
    /// True only once the underlying work has stopped. A mere signal/request
    /// returns false and remains `cancel_requested`.
    public let acknowledged: Bool

    public init(operationId: String, state: MacControlOperationState, acknowledged: Bool) {
        self.operationId = operationId
        self.state = state
        self.acknowledged = acknowledged
    }
}

// MARK: - Errors

public enum MacControlError: Error, Sendable, Equatable, LocalizedError {
    case unknownAction(String)
    case missingField(String)
    case sensitivePathDenied(String)
    case shellNotWhitelisted(String)
    case appControlFailed(String)
    case applescriptFailed(String)
    case notificationFailed(String)
    case proxyFailed(status: Int, detail: String)
    case transport(String)
    case malformedResponse(String)
    case ioFailure(String)
    case operation(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAction(let a): return "unknown mac_control action: \(a)"
        case .missingField(let f): return "missing required field: \(f)"
        case .sensitivePathDenied(let p): return "sensitive_path_denied: \(p)"
        case .shellNotWhitelisted(let c): return "shell command not in whitelist: \(c)"
        case .appControlFailed(let s): return "app control failed: \(s)"
        case .applescriptFailed(let s): return "applescript failed: \(s)"
        case .notificationFailed(let s): return "notification failed: \(s)"
        case .proxyFailed(let status, let detail): return "legacy proxy disabled: HTTP \(status) \(detail)"
        case .transport(let s): return "transport error: \(s)"
        case .malformedResponse(let s): return "malformed response: \(s)"
        case .ioFailure(let s): return "io failure: \(s)"
        case .operation(let s): return "operation error: \(s)"
        }
    }
}

// MARK: - Protocol

public protocol MacControlClient: MotorActionReadModelProviding, Sendable {
    /// Dispatch a mac_control sub-action. `action` is the sub-path under
    /// `/v1/mac_control/` (e.g. `"notify"`, `"file/read"`, `"shortcut/run"`).
    /// `body` is the JSON body the daemon route expects (mirrors the iOS
    /// payload shape — see the retired daemon–53747).
    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult
    func cancel(operationId: String) async throws -> MacControlCancellationResult

    /// The privileged injection entry point (W2/W3-FIX 1). Separate from
    /// `dispatch` so that the UNPRIVILEGED signature — the one the HTTP/iOS
    /// bridge, the app's direct callers and every raw dispatcher use — has no
    /// parameter capable of carrying an authorization.
    ///
    /// Defaulted below to a REFUSAL, so a conformer that does not deliberately
    /// implement injection cannot accidentally acquire it.
    func dispatchApprovedInjection(
        action: String,
        body: [String: JSONValue],
        capability: MacInjectionCapability
    ) async throws -> MacControlResult
}

extension MacControlClient {
    /// Fail-closed default: a MacControlClient that has not implemented the
    /// privileged path does not inject, it refuses. Adding a new conformer
    /// therefore cannot widen the injection surface by omission.
    public func dispatchApprovedInjection(
        action: String,
        body: [String: JSONValue],
        capability: MacInjectionCapability
    ) async throws -> MacControlResult {
        _ = capability
        _ = body
        return MacControlResult(
            ok: false,
            action: action,
            output: .object([
                "ok": .bool(false),
                "status": .string("blocked"),
                "error": .string("injection_unsupported_client"),
            ]),
            error: "injection_unsupported_client: this MacControl client does not implement "
                + "approved injection",
            durationMs: 0,
            viaSwift: true,
            httpStatus: 403
        )
    }
}

// MARK: - Sub-action classification

    /// The set of sub-actions implemented in-process by Swift.
public let macControlNativePortedActions: Set<String> = [
    "notify",
    "applescript",
    "file/read",
    "file/write",
    "file/list",
    "file/move",
    "file/trash",
    "focus_app",
    "quit_app",
    "spotlight",
    "shell",
    // W2 (2026-08-12): the physical input executor landed, so these two moved
    // out of `macControlUnsupportedActions` (where they 501'd) and into the
    // ported set. `macControlAllActions` — the daemon-parity inventory a test
    // pins byte-for-byte — is unchanged by the move, because it is the UNION
    // of the two buckets.
    "keystroke",
    "click",
]

/// Known MacControl actions that are intentionally not implemented in Swift
/// yet. They fail closed with a Swift 501 result rather than proxying.
public let macControlUnsupportedActions: Set<String> = [
    "jxa",
    "shortcut",
    "shortcut/run",
    "system",
    "self_test",
]

/// All sub-actions the daemon exposes. Used by tests to assert no route
/// gets accidentally dropped from the dispatch table. KEEP IN SYNC with
/// the retired daemon–53747.
public let macControlAllActions: Set<String> =
    macControlNativePortedActions.union(macControlUnsupportedActions)

/// Swift-native READ-ONLY accessibility perception actions (W1). These have
/// NO daemon ancestor — the daemon never exposed an AX-tree route — so they
/// are deliberately kept OUT of `macControlAllActions`, which is the
/// daemon-parity inventory a test pins byte-for-byte. Adding them there would
/// have made that parity assertion lie about what the retired daemon exposed.
///
/// They are perception only: no CGEvent, no AXUIElementPerformAction, no
/// attribute writes. Gate category is `accessibility` (same category as
/// keystroke/click) but they are READ tier — no approval, mirroring how
/// `spotlight` reads are gated but unapproved.
public let macControlAccessibilityReadActions: Set<String> = [
    "ax_status",
    "ax_tree",
    "ax_find",
    // W3.5 — the FUSED view (picture + AX structure, elements numbered). Read
    // tier for the same reason as the three above: it looks and changes
    // nothing. It needs one extra SYSTEM grant the others do not (Screen
    // Recording, a separate TCC permission from Accessibility), which it
    // reports honestly rather than failing opaque — but a system grant is not
    // a policy tier, so this stays read tier.
    "view",
    // native-look item 2 — the PERCEPTION COMPILER (`mac_look`). Read tier for
    // the same reason as the four above: it walks the same AX tree through the
    // same read organ, distills it, and changes nothing. It needs no extra
    // system grant at all (no picture, so no Screen Recording), which makes it
    // the cheapest perception in the module — glance is ~100-400x fewer bytes
    // than a stare on User's real apps.
    "look",
    // Explicit, bounded continuity over the same fused view. It passively
    // notices coarse physical input and scene changes while active, never key
    // contents, and returns a fresh redacted fused view on start/next.
    "attention",
    // fable51 item 29 — the MENU BAR walk. Read tier for the same reason as the
    // five above: one bounded descent of `AXMenuBar`, no CGEvent, no
    // AXUIElementPerformAction, no attribute write. It does not even OPEN a
    // menu — the AX tree publishes the items whether or not they are on screen,
    // which is exactly why the menu bar is the cheapest deterministic route to
    // an app's functionality.
    "menu",
]

/// Swift-native INJECTION actions with no daemon ancestor (W2/W3). Same
/// reasoning as the read set above: they are kept OUT of `macControlAllActions`
/// so the daemon-parity inventory keeps telling the truth about what the
/// retired daemon exposed.
///
/// `keystroke` and `click` are NOT here — they DO have daemon ancestors and
/// live in `macControlNativePortedActions`. Use
/// `macControlAccessibilityInjectionActions` below for the security predicate;
/// this set exists only for the inventory bookkeeping.
public let macControlAccessibilityActActions: Set<String> = [
    "scroll",
    "ax_act",
    // native-look item 3 — `act`, the CLOSED-LOOP verb. It presses, types,
    // selects, toggles, dismisses and scrolls through the same actuator the
    // four above use, so it is injection by mechanism as well as by intent.
    // The percept it returns afterwards is evidence, not a tier: read-shaped
    // output on an act tool would be exactly the bypass `wake` was kept out of.
    "act",
    // Internal physical owner for the four-verb surface. `act` resolves a
    // fresh name/ordinal first; `hand` executes the resulting bounded plan.
    "hand",
    // W6 — `wake`. It posts a HID nudge (a one-point mouse move, optionally a
    // modifier tap) to dismiss a NON-LOCKED screensaver or wake a sleeping
    // display, then re-captures the fused view so the caller lands on the real
    // screen in one call. The nudge is the smallest injection in the module and
    // it is still injection: it goes in the act set, not the read set.
    "wake",
    // fable51 item 29 — `menu_press`. It AXPresses a menu item, which runs the
    // app's own handler: File › Close, File › Quit, Edit › Delete are all one
    // press away. Injection by mechanism and by consequence, through the same
    // actuator `ax_act` uses. The READ half (`menu`) is a separate action in
    // the read set, so listing the menu never carries pressing authority.
    "menu_press",
]

/// App navigation with no daemon ancestor. It does not synthesize input, so it
/// is not an injection action, but it changes which document/app macOS presents
/// and therefore remains under the Full Mac Accessibility/app-control category
/// and the canonical MacControl operation owner.
public let macControlAppNavigationActions: Set<String> = [
    "open_target",
]

/// EVERY action that synthesizes input or mutates another app's UI state.
/// This is the set the three-gate injection predicate keys off:
/// master + accessibility category (via `macControlGateCategory`), an ACTIVE
/// Full Mac trust window, AND a live, body-bound, single-use
/// `MacInjectionCapability` presented through `dispatchApprovedInjection`.
/// Adding an action here is what makes it injection; forgetting to would let a
/// new act slip in at read tier.
public let macControlAccessibilityInjectionActions: Set<String> = [
    "keystroke",
    "click",
    "scroll",
    "ax_act",
    // W6 — `wake` posts real HID events. A tool that dismisses a screensaver
    // is a convenience, but the mechanism is a synthesized mouse move at the
    // same tap `click` uses, so it clears the SAME three gates: accessibility
    // category, an ACTIVE Full Mac window, and a live body-bound single-use
    // `MacInjectionCapability`. There is deliberately no wake-shaped bypass.
    "wake",
    // native-look item 3 — `act`. Identical gates to `ax_act`, deliberately:
    // a handle is a REFERENCE that names a better target, never an authority
    // that lowers a tier. It presses and types into other apps, so it clears
    // the accessibility category, an ACTIVE Full Mac window and a live
    // body-bound single-use capability like every one of its neighbours.
    "act",
    "hand",
    // fable51 item 29 — `menu_press` clears the SAME three gates as `ax_act`:
    // accessibility category, an ACTIVE Full Mac window, and a live body-bound
    // single-use capability. A menu path is a REFERENCE that names a better
    // target, never an authority that lowers a tier.
    "menu_press",
]

/// W7 — `nudge`, and it is deliberately in NEITHER of the two sets above.
///
/// It posts ONE bare `mouseMoved` CGEvent: no button, no key, no scroll, no AX
/// mutation. A bare cursor move cannot click, cannot type and cannot bypass a
/// lock — the worst it can do on a locked screen is what a human bumping the
/// mouse does, which is show the login field. So it carries neither the read
/// set's "no CGEvent" contract (it does post one) nor the injection set's
/// approval capability (there is nothing to approve: it changes no app state).
///
/// Its own set exists so both of those contracts keep telling the truth:
/// `macControlAccessibilityReadActions` stays "perception only, no CGEvent",
/// and `macControlAccessibilityInjectionActions` stays "everything that
/// synthesizes input or mutates another app's UI state" — the predicate that
/// demands a `MacInjectionCapability`. Adding `nudge` to the latter is what a
/// future action that grows a button-down MUST do; see `handleNudge`, whose
/// move-only emission is pinned by a test that greps the emitted events.
///
/// GATE: identical to the AX reads — `accessibility` category + an ACTIVE Full
/// Mac window (the pre-flight below names this set alongside the read set), no
/// approval filer, no capability.
public let macControlAccessibilityNudgeActions: Set<String> = [
    "nudge",
]

/// fable51 item 30 — THE CLIPBOARD ORGAN, in two sets because the two halves
/// are two different contracts and folding them together would let the write
/// inherit the read's tier.
///
/// `clipboard_read` is perception: it emits no event, mutates no app, and
/// returns text that has been through `MacScreenViewTextRedaction`. It is NOT
/// in `macControlAccessibilityReadActions` because that set's contract is
/// specifically the AX walk; the clipboard is a different surface reached
/// through the same Full Mac accessibility category (the same category that
/// already lets her press ⌘C to FILL it — gating the read behind a second
/// toggle would be a fence with no gate beside it).
public let macControlClipboardReadActions: Set<String> = [
    "clipboard_read",
]

/// The WRITE half. It synthesizes no input and mutates no other app's UI
/// state, so it is deliberately not in `macControlAccessibilityInjectionActions`
/// (it needs no `MacInjectionCapability`) — but it does change the world: the
/// next ⌘V in any app pastes what it put there. So it goes through the durable
/// motor-operation lane like every other action that changes something, and
/// the tool layer gates it on app-control authority rather than on read.
public let macControlClipboardWriteActions: Set<String> = [
    "clipboard_write",
]

public let macControlClipboardActions: Set<String> =
    macControlClipboardReadActions.union(macControlClipboardWriteActions)

/// fable51 item 33 — THE READ ORGAN, and it is in its OWN set for the same
/// reason `nudge` is in its own set: it is neither neighbour, and folding it
/// into either would make that neighbour's contract lie.
///
/// It is NOT in `macControlAccessibilityReadActions`, whose contract is
/// literally "perception only, no CGEvent": the accumulate route posts scroll
/// wheel events to move a viewport, so claiming that contract for it would be
/// false.
///
/// It is NOT in `macControlAccessibilityInjectionActions` either, and that is
/// the deliberate line. That set is "everything that synthesizes input or
/// MUTATES ANOTHER APP'S UI STATE" — the predicate that demands a
/// `MacInjectionCapability`. A vertical wheel scroll aimed at the centre of a
/// resolved scroll container cannot press, cannot type, cannot activate and
/// cannot commit anything: it moves which part of a document is drawn, and the
/// handler scrolls back by the same amount when it is done. That is the same
/// class as `nudge`'s bare mouse move, and the same class this codebase already
/// grades `browser.chrome_scroll` at (`safe_read`/low in
/// `SecurityCenter+ToolProfiles`).
///
/// What a FUTURE edit must do: the moment this handler grows a press, a
/// keystroke, an AX action or a horizontal/arbitrary scroll the caller can aim,
/// it belongs in the injection set. The guard that keeps that honest is not
/// this comment — it is `MacDocumentReadTests`, which greps every event the
/// sink received and fails on anything that is not a vertical scroll or the
/// cursor move that aims it.
///
/// GATE: identical to the AX reads — `accessibility` category + an ACTIVE Full
/// Mac window. The tool layer adds one more for the explicit-`path` route: a
/// named file is a FILESYSTEM read and clears `file_ops` as well.
public let macControlDocumentReadActions: Set<String> = [
    "read",
]

/// Everything `SwiftNativeMacControl.dispatch` will accept: the daemon-parity
/// inventory plus the Swift-native accessibility reads, acts and the nudge.
public let macControlDispatchableActions: Set<String> =
    macControlAllActions
        .union(macControlAccessibilityReadActions)
        .union(macControlAccessibilityActActions)
        .union(macControlAppNavigationActions)
        // W7 — `nudge` must be here or the HTTP/iOS-remote bridge route in
        // NativeClient+CutoverSeams 404s it as an unknown action.
        .union(macControlAccessibilityNudgeActions)
        // fable51 item 30 — the clipboard organ, for the same reason.
        .union(macControlClipboardActions)
        // fable51 item 33 — the read organ, for the same reason.
        .union(macControlDocumentReadActions)

// MARK: - W6 login-session state (the mac_wake safety line)

/// The system's IDLE screen-lock POLICY — "require a password after the
/// screensaver starts" — as reported by `sysadminctl -screenLock status`.
///
/// NAMED FOR WHAT IT IS, and reported as diagnostics only. It is NOT "will this
/// lock UI ask for a password": a MANUALLY locked screen (Ctrl-Cmd-Q, Apple menu
/// ▸ Lock Screen) demands the account password regardless of this policy. The
/// wake guard therefore never treats `notRequired` as permission to act on a
/// locked screen; see `MacWakeGuard`.
public enum MacSessionPasswordRequirement: String, Sendable, Equatable {
    /// The idle policy is off. Says nothing about a manual lock.
    case notRequired = "not_required"
    case required
    case unknown
}

/// A read-only snapshot of the login session and display, taken immediately
/// before and immediately after a wake nudge.
///
/// STEP-0 FINDING (verified live on this Mac, 2026-08-12): the CoreGraphics
/// session key `CGSSessionScreenIsLocked` is **1 while an ordinary non-locked
/// screensaver is showing** — it was 1 at the same moment
/// `sysadminctl -screenLock status` reported `screenLock is off` and the
/// frontmost app was `com.apple.loginwindow`.
///
/// ROUND-2 FINDING, and the one that decides the safety line: that cuts BOTH
/// ways, and the dangerous direction is the other one. The flag is also 1 for a
/// real password lock, and macOS publishes no point-in-time signal for "the lock
/// UI in front of me needs a password" — so a set flag is an AMBIGUOUS reading,
/// not a screensaver reading. `MacWakeGuard` resolves that ambiguity by
/// refusing. See the guard for the discriminators that were tried and why each
/// one fails.
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
    /// The IDLE lock policy, carried for the human reading a refusal. It is
    /// never permission to act on a locked screen.
    public let passwordRequirement: MacSessionPasswordRequirement
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
        passwordRequirement: MacSessionPasswordRequirement,
        sessionReadable: Bool = true,
        frontmostBundleID: String? = nil,
        idleSeconds: Double? = nil,
        cursorX: Double? = nil,
        cursorY: Double? = nil
    ) {
        self.screenIsLocked = screenIsLocked
        self.onConsole = onConsole
        self.displayAsleep = displayAsleep
        self.passwordRequirement = passwordRequirement
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
            // User, 2026-08-22: no lock vocabulary in receipts. The flag means
            // "the saver/login layer is up", which on his Mac is the
            // undismissable screensaver, and calling it locked sent every
            // reader (Agent, me, a security reviewer) chasing a lock that was
            // never there.
            "saver_layer_up": .bool(screenIsLocked),
            "on_console": .bool(onConsole),
            "display_asleep": .bool(displayAsleep),
            // Named as the POLICY it is, so no reader mistakes it for "this lock
            // will not ask for a password".
            "session_readable": .bool(sessionReadable),
            "frontmost": frontmostBundleID.map { .string($0) } ?? .null,
            "idle_seconds": idleSeconds.map { .double(($0 * 10).rounded() / 10) } ?? .null,
            // Agent live envelope F0D81308: the docs claimed the nudge "leaves
            // the pointer exactly where it was" and the RECEIPT could not show
            // it. A claim the caller cannot check is not a proof, so the
            // coordinates ride along and she can compare them herself.
            "cursor_x": cursorX.map { .double(($0 * 10).rounded() / 10) } ?? .null,
            "cursor_y": cursorY.map { .double(($0 * 10).rounded() / 10) } ?? .null,
        ])
    }
}

/// The probe seam. Production reads CoreGraphics/AppKit; tests inject a fake so
/// the refusal is pinned with no window server and no real screensaver.
public protocol MacSessionStateSource: Sendable {
    /// False when this build/platform cannot read the session at all — which
    /// includes a live macOS build whose session dictionary comes back nil or
    /// without the keys the decision rests on. It must reflect a real read, not
    /// a constant: the wake handler refuses rather than nudging blind, and a
    /// source that lies here removes the only evidence there was.
    var isAvailable: Bool { get }
    func currentState() -> MacSessionState
}

/// THE SAFETY LINE, as pure functions so it can be tested directly and read in
/// one place. `mac_wake` always attempts its inert nudge on the current console;
/// an unreadable/off-console session refuses. The ambiguous obstruction flag
/// governs capture only: while set, no screenshot or screen description leaves.
///
/// WHY THERE IS NO SCREENSAVER-POSITIVE BRANCH. The earlier build proceeded when
/// the flag was set and `sysadminctl -screenLock status` said `off`. That is
/// wrong, and it is wrong in the direction that photographs a locked Mac. Every
/// candidate discriminator was examined:
///
/// - `sysadminctl -screenLock status` reads `askForPassword` /
///   `askForPasswordDelay` — the IDLE policy, i.e. "after the screensaver
///   starts, demand a password". A MANUAL lock (Ctrl-Cmd-Q, Apple menu ▸ Lock
///   Screen) demands the account password *regardless of that policy*, and it
///   sets the very same `CGSSessionScreenIsLocked == 1`. So `off` + locked is
///   exactly a manual lock's fingerprint. This was BLOCKING #1.
/// - The session dictionary carries no auth flag. Live dump while the flag was
///   set: `CGSSessionScreenIsLocked`, `CGSSessionScreenLockedTime`,
///   `CGSSessionUniqueSessionUUID`, `kCGSSessionAuditIDKey`, GroupID,
///   `kCGSSessionLoginwindowSafeLogin`, `kCGSSessionOnConsoleKey`,
///   SystemSafeBoot, UserID, UserName, `kCGSessionLoginDoneKey`,
///   LongUserName, `kSCSecuritySessionID`. Nothing says "password required now".
/// - "Is the screensaver running" (a `ScreenSaverEngine` / `legacyScreenSaver`
///   process, the `com.apple.screensaver.didstart` notification) is not a
///   discriminator EVEN IF READ PERFECTLY: lock manually, then wait, and the
///   idle timer starts the saver ON TOP of a password-required lock. Saver
///   running and password required are not mutually exclusive, so a
///   saver-positive signal cannot license a nudge. It would also need a live
///   subscription to catch a notification a one-shot tool call already missed.
/// - `CGSSessionScreenLockedTime` vs `secondsSinceLastEventType` can *suggest*
///   which came first (a manual lock leaves idle ≈ time-since-lock; an
///   idle-triggered saver leaves idle ≈ time-since-lock + the saver delay). It
///   is a timing heuristic that needs the saver delay from a
///   `com.apple.screensaver` domain which does not exist on this Mac when the
///   setting is off, and any input reaching the lock UI resets the idle clock.
///   A heuristic is not a safety line.
///
/// So the flag cannot be interpreted — and User's direction (2026-08-22) is that
/// it should not be: the nudge ALWAYS goes out. It is a one-pixel pointer move
/// plus a bare left-shift tap, which cannot type text, click, or authenticate —
/// on a screen that genuinely demands a password it achieves nothing, exactly
/// like a hand on the mouse, and that outcome reports itself honestly as
/// still-obstructed. The only gate that consults the flag is the CAPTURE: an
/// obstructed screen is never photographed, described, or given a view id.
public enum MacWakeGuard {
    public static let loginWindowBundleID = "com.apple.loginwindow"

    /// The ONE obstruction refusal, and it is about the CAPTURE, never the
    /// nudge. No lock vocabulary (User, 2026-08-22): whether the layer on
    /// screen is a screensaver or something that wants a password is not a
    /// question this Mac answers, and the caller does not need it answered —
    /// the nudge either cleared the screen or it did not, and that fact is in
    /// `dismissed`/`still_obstructed` where she can branch on it.
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

    /// THE NUDGE GUARD (User's direction, 2026-08-22): the nudge ALWAYS goes
    /// out. No lock inspection, no policy branch — the obstruction flag is not
    /// consulted at all. The nudge is a one-pixel pointer move plus a bare
    /// left-shift tap; it cannot type text, click, or authenticate, so on a
    /// screen that genuinely wants a password it achieves what a hand on the
    /// mouse achieves and no more, and that outcome reports itself as
    /// still-obstructed rather than being pre-refused on a flag macOS refuses
    /// to disambiguate. The only refusals left are the ones about whether this
    /// process can even SEE the console it would be nudging.
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

#if canImport(CoreGraphics) && os(macOS)

/// Live session probe.
public struct SystemMacSessionStateSource: MacSessionStateSource {
    public init() {}

    /// REAL readability, not a hardcoded `true`. `isAvailable` used to say yes
    /// unconditionally while a nil session dictionary silently became `[:]` and
    /// every flag fell back to its default — the tool then "proceeded" on no
    /// evidence at all. It now answers by actually reading, and
    /// `currentState().sessionReadable` carries the same verdict inline so a
    /// session that becomes unreadable mid-call is caught by the guard too.
    public var isAvailable: Bool { Self.readSession() != nil }

    /// The keys this decision rests on. A dictionary that comes back without
    /// them is unreadable for our purposes even though it is non-nil: it cannot
    /// tell us who owns the console, so it cannot license input.
    static let requiredSessionKeys = ["kCGSSessionOnConsoleKey"]

    private static func readSession() -> [String: Any]? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        guard requiredSessionKeys.allSatisfy({ session[$0] != nil }) else { return nil }
        return session
    }

    public func currentState() -> MacSessionState {
        // FAIL CLOSED. An unreadable session yields a state that the guard
        // refuses on — locked, off-console, unreadable — never an empty
        // dictionary whose defaults read as "unlocked and on console".
        guard let session = Self.readSession() else {
            return MacSessionState(
                screenIsLocked: true,
                onConsole: false,
                displayAsleep: false,
                passwordRequirement: .unknown,
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
        return MacSessionState(
            screenIsLocked: locked,
            onConsole: onConsole,
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            // Diagnostics for the refusal text only — the guard refuses on
            // `locked` whatever this says — so only pay for the subprocess when
            // there is a refusal to explain.
            passwordRequirement: .unknown,  // never consulted; sysadminctl reader retired (User, 2026-08-22)
            sessionReadable: true,
            frontmostBundleID: frontmost,
            idleSeconds: Self.idleSeconds(),
            cursorX: CGEvent(source: nil)?.location.x.native,
            cursorY: CGEvent(source: nil)?.location.y.native
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
    public var isAvailable: Bool { false }
    public func currentState() -> MacSessionState {
        MacSessionState(
            screenIsLocked: true,
            onConsole: false,
            displayAsleep: false,
            passwordRequirement: .unknown,
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

// MARK: - Sub-action → gate category map (wave 30 W01)

/// Maps a dispatch sub-action to the gate CATEGORY the daemon's
/// `MacControl.<method>` passes to `self._gate(category, trigger)`. Verified
/// byte-for-byte against the retired daemon (the `self._gate("<cat>", …)`
/// call in each method):
///
///   applescript                                  → "applescript"  (L497)
///   jxa                                          → "jxa"          (L548)
///   shortcut / shortcut/run                      → "shortcuts"    (L587)
///   focus_app / quit_app / keystroke / click     → "accessibility"(L615/631/690/718)
///   system                                       → "system"       (L770…826)
///   file/read|write|list|move|trash              → "file_ops"     (L846…950)
///   notify                                       → "notifications"(L996)
///   shell                                        → "shell"        (L1026)
///   spotlight                                    → "spotlight"    (L973)
///
/// `self_test` deliberately returns `nil`: its Python
/// impl gates EVERY category in a loop (L1189 `for cat in …: self._gate(cat)`),
/// so there is no single pre-flight category. Returning `nil` means "do not
/// pre-gate"; unsupported actions fail closed after inventory classification.
public func macControlGateCategory(forAction action: String) -> String? {
    switch action {
    case "applescript":                                   return "applescript"
    case "jxa":                                           return "jxa"
    case "shortcut", "shortcut/run":                      return "shortcuts"
    case "focus_app", "quit_app", "open_target", "keystroke", "click": return "accessibility"
    case "ax_status", "ax_tree", "ax_find", "view", "attention", "look": return "accessibility"
    // W2/W3 Swift-native injection: same category as keystroke/click above,
    // which is where the daemon put every accessibility-mediated act.
    // W6 `wake` joins them: it posts HID events and re-reads the screen.
    case "scroll", "ax_act", "wake":                      return "accessibility"
    // native-look item 3 — `act` (the closed-loop verb) is accessibility
    // mediated exactly like `ax_act`, which it performs through.
    case "act", "hand":                                   return "accessibility"
    // fable51 item 29 — the menu organ. The read walks the app's AX menu bar;
    // the press goes through the same actuator every other act uses.
    case "menu", "menu_press":                            return "accessibility"
    // W7 `nudge` — same category as the AX reads it is gated like. A bare
    // cursor move is accessibility-mediated whether or not it is injection.
    case "nudge":                                         return "accessibility"
    // fable51 item 30 — the clipboard organ. Same category as the AX reads and
    // the keystroke that fills the pasteboard: she can already put a credential
    // on the clipboard with ⌘C under `accessibility`, so reading it back is the
    // same authority, and writing it is weaker than the keystroke that would
    // otherwise type the same characters.
    case "clipboard_read", "clipboard_write":             return "accessibility"
    // fable51 item 33 — the read organ. Accessibility, like every other organ
    // that perceives a window: the screen route walks the AX tree and moves a
    // viewport, and the file route only ever opens a document the window in
    // front of her already has open. The tool layer adds the `file_ops` check
    // on top when a caller names a path of its own.
    case "read":                                          return "accessibility"
    case "system":                                        return "system"
    case "file/read", "file/write", "file/list",
         "file/move", "file/trash":                       return "file_ops"
    case "notify":                                        return "notifications"
    case "shell":                                         return "shell"
    case "spotlight":                                     return "spotlight"
    case "self_test":                                     return nil  // multi-category sweep — daemon-owned
    default:                                              return nil
    }
}

/// The path fields the gate's file-policy check (`_file_policy_reason`) must
/// see for a given file_ops action — mirrors which `path`/`src`/`dst` keys the
/// daemon method passes into `self._file_policy_reason(...)`:
///   read_file / write_file / list_directory / trash_file → ["path"]
///   move_file                                            → ["src", "dst"]
/// Returns the body-key names to extract; empty for non-file actions.
public func macControlFilePolicyPathKeys(forAction action: String) -> [String] {
    switch action {
    case "file/read", "file/write", "file/list", "file/trash": return ["path"]
    case "file/move": return ["src", "dst"]
    // fable51 item 33 — `read` with an explicit `path` OPENS A FILE, so the
    // workspace-root policy that governs `file/read` governs it too. Naming the
    // key here is what makes that true; without it a document read would be the
    // one door into the filesystem that the file policy never saw. (The
    // sensitive-path fence runs in `handleRead`'s own extraction path, matching
    // the "sensitive wins over file-policy" precedence documented at the
    // pre-flight call site.)
    case "read": return ["path"]
    default: return []
    }
}

// MARK: - Live-policy provider seam (wave 30 W01)

/// Supplies the live `MacControlPolicy` to `SwiftNativeMacControl` so its
/// `dispatch` can run the W4 `MacControlGate` pre-flight in-process before
/// any native execution. Swift is the execution authority in the zero-daemon
/// runtime.
///
/// `nil` provider is intended for direct unit tests only; production wires a
/// TrustCenter-backed provider.
public protocol MacControlPolicyProvider: Sendable {
    /// Return the current policy, or nil if it can't be resolved (in which
    /// case production callers fail closed before any side effect. Tests can
    /// omit the provider when they need to exercise a handler directly.
    func currentPolicy() async -> MacControlPolicy?
}

public extension MacControlPolicy {
    /// Build the gate policy from the normalized TrustCenter policy object.
    /// This keeps production MacControl fully Swift-native while preserving the
    /// same macControlPolicy/filePolicy fields the UI already edits.
    static func fromTrustPolicyObject(_ root: [String: JSONValue]) -> MacControlPolicy {
        let defaults = MacControlPolicy.default
        let mac: [String: JSONValue] = {
            if case .object(let obj)? = root["macControlPolicy"] { return obj }
            return [:]
        }()
        let filePolicy: [String: JSONValue] = {
            if case .object(let obj)? = root["filePolicy"] { return obj }
            return [:]
        }()

        func bool(_ obj: [String: JSONValue], _ key: String, default def: Bool) -> Bool {
            if case .bool(let value)? = obj[key] { return value }
            return def
        }
        func string(_ obj: [String: JSONValue], _ key: String, default def: String = "") -> String {
            if case .string(let value)? = obj[key] { return value }
            return def
        }
        func double(_ obj: [String: JSONValue], _ key: String, default def: Double) -> Double {
            switch obj[key] {
            case .double(let value): return value
            case .int(let value): return Double(value)
            default: return def
            }
        }
        func stringArray(_ obj: [String: JSONValue], _ key: String) -> [String]? {
            guard case .array(let values)? = obj[key] else { return nil }
            return values.compactMap { value in
                if case .string(let s) = value { return s }
                return nil
            }
        }

        var categoryAllowed = defaults.categoryAllowed
        for key in categoryAllowed.keys {
            categoryAllowed[key] = bool(mac, key, default: categoryAllowed[key] ?? false)
        }

        let approvalRequiredFor = stringArray(mac, "approval_required_for") ?? defaults.approvalRequiredFor
        let workspaceRoots =
            stringArray(root, "workspaceRoots")
            ?? stringArray(root, "workspace_roots")
            ?? stringArray(filePolicy, "workspaceRoots")
            ?? []

        let trustPolicy = MacControlTrustPolicy(
            outsideWorkspaceDefault: string(filePolicy, "outsideWorkspaceDefault", default: "deny"),
            permissionLevel: string(root, "permissionLevel", default: "balanced"),
            fullMacExpiresAt: string(root, "fullMacExpiresAt"),
            fullMacNeverExpires: bool(root, "fullMacNeverExpires", default: false),
            fullMacConfirmedAt: string(root, "fullMacConfirmedAt"),
            fullMacMaxDurationHours: double(root, "fullMacMaxDurationHours", default: 4),
            developerMode: bool(root, "developerMode", default: false),
            allowDestructiveActions: bool(filePolicy, "allowDestructiveActions", default: false)
        )

        return MacControlPolicy(
            enabled: bool(mac, "enabled", default: defaults.enabled),
            remoteFromIOSAllowed: bool(mac, "remote_from_ios_allowed", default: defaults.remoteFromIOSAllowed),
            requireAppBridgeForTCC: bool(mac, "require_app_bridge_for_tcc", default: defaults.requireAppBridgeForTCC),
            categoryAllowed: categoryAllowed,
            trustPolicy: trustPolicy,
            workspaceRoots: workspaceRoots,
            approvalRequiredFor: approvalRequiredFor
        )
    }
}

// MARK: - Shell whitelist

/// Sub-action `shell` is the most dangerous surface in the entire module.
/// Even when policy is permissive, the Swift path enforces a hard executable-prefix whitelist
/// so a compromised LLM tool-call surface CAN NOT pivot from a Mac-app
    /// permission slip to arbitrary code execution.
public enum MacControlShellWhitelist {
    /// First word (split on whitespace) MUST appear here. Absolute-path
    /// commands have the basename checked. Empty / multi-statement chains
    /// (`;`, `&&`, `||`, `|`, backticks, `$(...)`) are rejected outright
    /// regardless of whitelist match — see `validate(_:)`.
    public static let allowed: Set<String> = [
        "echo", "true", "false", "pwd", "whoami", "uname", "date",
        "hostname", "id", "uptime", "df", "uptime",
    ]

    /// Returns nil on accept, or a rejection reason string on deny.
    public static func validate(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty command" }
        // Hard reject any shell-metachar that could chain or substitute.
        let banned: [Character] = [";", "&", "|", "`", "$", ">", "<", "\n", "\r", "\\"]
        for ch in trimmed {
            if banned.contains(ch) {
                return "disallowed metacharacter: \(ch)"
            }
        }
        let firstWord = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        if firstWord.isEmpty { return "no executable" }
        // The whitelist is a NAME whitelist, not a basename whitelist —
        // `/tmp/date` and `./date` MUST be rejected even though basename
        // matches. Attacker-controlled executables on PATH are out of scope.
        if firstWord.hasPrefix(".") {
            return "executable relative path not allowed: \(firstWord)"
        }
        if firstWord.contains("/") {
            return "executable path not allowed: \(firstWord)"
        }
        if !allowed.contains(firstWord) {
            return "executable not whitelisted: \(firstWord)"
        }
        return nil
    }
}

// MARK: - Sensitive-path fence (parity subset)

/// Pared-down port of `MacControl._sensitive_path_reason` (mac_control.py
/// :211–290). Returns the first reason found, empty string when path is
/// allowed. The trust-policy file-policy layer runs separately in
/// `gatePreflightOutcome`.
///
/// **TOCTOU residual**: the fence resolves the symlink chain once at check
/// time, but Foundation does not expose O_NOFOLLOW open semantics so an
/// attacker who can race a symlink swap BETWEEN the fence's resolution and
/// the FileManager call can still bypass the check. Callers shrink the
/// window by re-resolving + re-fencing immediately before the syscall
/// (see `handleFileRead` / `handleFileList`), but the gap is not closed.
/// Sensitive-path safety against an active local attacker is the daemon's
/// responsibility, not Swift's.
public enum MacControlSensitivePathFence {
    /// File basenames that are NEVER touched (credentials, paired
    /// secrets). Case-insensitive.
    public static let bannedFilenames: Set<String> = [
        "config.json",
        "trust_policy.json",
        "trust.json",
        "macctl_bridge.json",
        "browser_ipc_token",
        "browser_ipc.json",
        "auth.json",
        "credentials.json",
        "icloud_pairing_secret.bin",
        "pairing_secret.bin",
    ]

    /// Directory prefixes (relative to $HOME) that are NEVER touched.
    public static let bannedHomePrefixes: [String] = [
        ".config/claude-bridge",
        ".ssh",
        ".gnupg",
        "Library/Keychains",
        "Library/Accounts",
        "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB",
        "Library/Application Support/CloudDocs",
        "Library/Application Support/com.apple.TCC",
        "Library/Application Support/Knowledge",
        "Library/Application Support/SyncServices",
        "Library/Messages",
        "Library/Mail",
        "Library/Calendars",
        "Library/Containers/com.apple.Home",
        "Library/Containers/com.apple.reminders",
        "Library/Group Containers/group.com.apple.reminders",
        "Library/Group Containers/group.com.apple.notes",
        "Library/Mobile Documents",
        "Library/Safari",
        "Pictures/Photos Library.photoslibrary",
    ]

    /// Directory prefixes (relative to $HOME) for the NativeAgent default
    /// data root. Mirrors the retired daemon which derives these
    /// from `_data_dir`. The Swift path also checks relocated `/data/...`
    /// segment patterns below.
    public static let bannedDataRootPrefixes: [String] = [
        "Library/Application Support/NativeAgent/oauth",
        "Library/Application Support/NativeAgent/oauth_tokens",
        "Library/Application Support/NativeAgent/providers",
        "Library/Application Support/NativeAgent/trust",
        "Library/Application Support/NativeAgent/pairings",
        "Library/Application Support/NativeAgent/secrets",
        "Library/Application Support/NativeAgent/nextgen/remote",
        "Library/Application Support/NativeAgent/memory/vault",
        "Library/Application Support/NativeAgent/codex_home",
    ]

    /// Path SEGMENTS (relative to any `/data/` boundary) marking a NativeAgent
    /// data-root subdirectory regardless of WHERE on disk the data root lives
    /// (repo `data/`, the Swift-native `NATIVE_AGENT_DATA_ROOT`-relocated
    /// root, or the default AppSupport one covered above). Each entry is a
    /// list of consecutive path components expected immediately after a
    /// `data` component.
    ///
    /// Matched by path-component walk, NOT substring — `/tmp/notdata/oauth`
    /// is allowed because `notdata` is not the component `data`.
    public static let bannedDataRootSegments: [[String]] = [
        ["oauth"],
        ["oauth_tokens"],
        ["providers"],
        ["trust"],
        ["pairings"],
        ["secrets"],
        ["nextgen", "remote"],
        ["memory", "vault"],
        ["codex_home"],
    ]

    /// Non-bypassable OS mutation floor. Full Mac grants broad user-space
    /// access, but it must not authorize mutation of the operating system,
    /// launch services, or app bundles.
    public static let protectedSystemMutationPrefixes: [String] = [
        "/System",
        "/bin",
        "/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/usr/lib",
        "/usr/libexec",
        "/Applications",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools",
        "/Library/StartupItems",
        "/private/etc",
        "/private/var/db",
        "/private/var/root",
        "/etc",
        "/var/db",
        "/var/root",
    ]

    /// Swift-native data root, resolved per call. Mirrors whatever
    /// `PersistenceCore.defaultDataRoot()` returns — which honors
    /// `NATIVE_AGENT_DATA_ROOT` when set, otherwise the AppSupport default.
    private static var swiftDataRootPath: String {
        PersistenceCore.defaultDataRoot().path
    }

    /// Legacy daemon data-root override. DENY-ONLY: this env var is no longer
    /// read as a config source anywhere in the Swift port, but if a user (or
    /// a stale launchctl plist) still has `NATIVE_AGENT_DATA` exported, the
    /// sensitive-path fence MUST still cover whatever it points at. Without
    /// this, an attacker who can set the env var could pivot read/write tools
    /// at the daemon-era root and bypass the explicit AppSupport coverage.
    /// gpt-5.5 review LOW/MED. Path returned only for fence-extension; the
    /// rest of the codebase ignores this variable.
    private static var legacyDaemonDataRootPath: String? {
        let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_DATA"]
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (raw as NSString).expandingTildeInPath
    }

    /// Returns nil when path is allowed, or a rejection reason string.
    public static func reason(forPath rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty path" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if let r = checkSingle(path: expanded) { return r }
        // Symlink follow: catch a benign-looking path whose target lands in
        // a sensitive prefix. Python uses Path.resolve(strict=False); we
        // approximate with URL.resolvingSymlinksInPath and re-run the fence
        // checks against the resolved path if it differs from the raw one.
        let resolved = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath().path
        if resolved != expanded {
            if let r = checkSingle(path: resolved) { return r }
        }
        return nil
    }

    public static func protectedSystemMutationReason(forPath rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "protected_system_path_denied: empty path" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidates = [
            URL(fileURLWithPath: expanded).standardizedFileURL.path,
            URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path,
        ]
        for path in candidates {
            if let prefix = protectedSystemMutationPrefixes.first(where: { isSelfOrAncestor(root: $0, path: path) }) {
                return "protected_system_path_denied: \(prefix)"
            }
        }
        return nil
    }

    private static func isSelfOrAncestor(root: String, path: String) -> Bool {
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path.lowercased()
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private static func checkSingle(path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let basename = url.lastPathComponent.lowercased()

        let bannedLower = Set(bannedFilenames.map { $0.lowercased() })
        if bannedLower.contains(basename) {
            return "sensitive_path_denied: \(url.lastPathComponent)"
        }

        let home = (NSHomeDirectory() as NSString).expandingTildeInPath
        let pathLower = url.path.lowercased()
        let homeLower = home.lowercased()
        for prefix in bannedHomePrefixes {
            let fullPrefix = (homeLower as NSString)
                .appendingPathComponent(prefix.lowercased())
            if pathLower == fullPrefix || pathLower.hasPrefix(fullPrefix + "/") {
                return "sensitive_path_denied: \(prefix)"
            }
        }
        for prefix in bannedDataRootPrefixes {
            let fullPrefix = (homeLower as NSString)
                .appendingPathComponent(prefix.lowercased())
            if pathLower == fullPrefix || pathLower.hasPrefix(fullPrefix + "/") {
                return "sensitive_path_denied: \(prefix)"
            }
        }

        // Swift-native data root coverage. `PersistenceCore.defaultDataRoot()`
        // honors `NATIVE_AGENT_DATA_ROOT` when set, so a relocated data root
        // gets the same explicit-prefix coverage as the AppSupport default.
        //
        // Also covers the legacy daemon `NATIVE_AGENT_DATA` if it's still
        // exported. We do NOT consult that env var as a config source — this
        // is the DENY half only, so a stale plist can't be used to pivot
        // tools at a root the fence forgot about.
        var dataRootCandidates: [String] = [swiftDataRootPath]
        if let legacy = legacyDaemonDataRootPath {
            dataRootCandidates.append(legacy)
        }
        for rootRaw in dataRootCandidates {
            let rootLower = rootRaw.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rootLower.isEmpty else { continue }
            for segs in bannedDataRootSegments {
                let suffix = segs.joined(separator: "/").lowercased()
                let full = "/\(rootLower)/\(suffix)"
                if pathLower == full || pathLower.hasPrefix(full + "/") {
                    return "sensitive_path_denied: data/\(segs.joined(separator: "/"))"
                }
            }
        }

        // Path-component walk: catch any `…/data/<bannedSegs…>/…` regardless
        // of where on disk the `data` root lives (repo, alt location, etc).
        // SEGMENT match — `/tmp/notdata/oauth` MUST pass.
        let components = pathLower.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        for (i, comp) in components.enumerated() where comp == "data" {
            for segs in bannedDataRootSegments {
                let needed = segs.map { $0.lowercased() }
                let endIdx = i + 1 + needed.count
                guard endIdx <= components.count else { continue }
                let slice = Array(components[(i + 1)..<endIdx])
                if slice == needed {
                    return "sensitive_path_denied: data/\(segs.joined(separator: "/"))"
                }
            }
        }
        return nil
    }
}
