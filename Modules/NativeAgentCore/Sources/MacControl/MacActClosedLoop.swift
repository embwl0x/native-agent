import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(ApplicationServices)
import ApplicationServices
// Blueprint: | `MacActClosedLoop.swift` | `MacActClosedLoop.verify` owns the declared-effect verdict for semantic, menu and physical act receipts: exact complete AXValue, selection range, selected/state/focus, owned window/sheet creation, confirmed removal or process exit and AX surface transitions; pixels are witnesses only; readable mismatches are `acted_mismatch`, unavailable readback (including canonically masked text values) is `acted_unobserved` |
#endif

// MARK: - THE CLOSED LOOP (native-look item 3)
//
// NORTHSTAR clause 5 + the item-3 brief: "this tool must never require the
// model to re-look to learn whether the click landed."
//
// Today a computer-use step is three model turns — look, act, look again — and
// the middle one is the only decision. `mac_act` collapses all three into ONE
// call: it installs an AXObserver on the target app BEFORE it performs, runs
// the verb, waits for the first notification (the item-1 spike measured 30–32 ms
// on native AND on a Chrome web button), collects its siblings for an 80 ms
// quiet window, then re-compiles the SAME look percept and diffs it against the
// frame she acted from. What changed comes back in the same result, along with
// a NEW frame so the next verb continues from the new state.
//
// Three rules this file exists to keep:
//   1. The ACTUATOR stays the only AX mutator. Nothing here calls
//      `AXUIElementPerformAction` / `SetAttributeValue` / `CGEvent`; every verb
//      is planned as a call into `MacAccessibilityActuator` / `MacEventSink`.
//   2. The observer is ALWAYS removed — on success, on error, on timeout, on a
//      thrown cancellation. `MacAXEffectObserverGuard` owns that, with a
//      once-only `stop()` and a `deinit` backstop.
//   3. Perception is not re-invented. The post-action percept comes from
//      `MacPerceptionCompiler.compile` over the same read organ; there is no
//      second walker here either.

// MARK: - The effect-observer seam

/// One AX notification, named only. NEVER any payload: a notification's
/// userInfo can carry the changed VALUE (a password field's new contents on
/// `AXValueChanged`), and this rides the turn trace, the operation store and
/// the iOS/Telegram sync. The kind and the timestamp are the whole signal.
public struct MacAXEffectNotification: Sendable, Equatable {
    public let kind: String
    public let at: Date

    public init(kind: String, at: Date) {
        self.kind = kind
        self.at = at
    }
}

/// A live observer registration. `stop()` must be idempotent.
public protocol MacAXEffectObservation: AnyObject, Sendable {
    func stop()
}

/// The injectable half of the closed loop. Production is
/// `SystemMacAXEffectObserverSource` (a real `AXObserver` on the main run
/// loop); tests inject a fake that emits scripted notifications and COUNTS
/// installs and removals, so "the observer is always removed" is a pinned
/// assertion rather than a hope.
public protocol MacAXEffectObserverSource: Sendable {
    /// Install an observer for `kinds` on `pid`. Returns nil when no observer
    /// could be installed — which the caller must REPORT (`observed: false`
    /// with a reason), never hide behind a silent "no effect".
    func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)?
}

/// Removes the observation exactly once, from wherever control leaves the act:
/// the success return, an early error return, the timeout path, or a task
/// cancellation that unwinds past every `defer`.
public final class MacAXEffectObserverGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: (any MacAXEffectObservation)?
    private var stopped = false

    public init(_ observation: (any MacAXEffectObservation)?) {
        self.observation = observation
    }

    public var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observation != nil
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let live = observation
        observation = nil
        lock.unlock()
        live?.stop()
    }

    deinit { stop() }
}

/// Thread-safe sink for notifications arriving on the main run loop while the
/// act waits off it.
public final class MacAXEffectCollector: @unchecked Sendable {
    /// A pathological app can fire hundreds of notifications in 80 ms. Only the
    /// first `hardCap` are retained; the count of the rest is still reported.
    public static let hardCap = 64

    private let lock = NSLock()
    private var received: [MacAXEffectNotification] = []
    private var dropped = 0
    private var pending = false
    private var waiter: AsyncStream<Void>.Continuation?

    public init() {}

    public func record(_ notification: MacAXEffectNotification) {
        lock.lock()
        defer { lock.unlock() }
        if received.count < Self.hardCap {
            received.append(notification)
        } else {
            dropped += 1
        }
        pending = true
        waiter?.yield(())
    }

    /// Activation wakes the same consumer without fabricating an AX event.
    func signal() {
        lock.lock()
        defer { lock.unlock() }
        pending = true
        waiter?.yield(())
    }

    func consumeSignal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let fired = pending
        pending = false
        return fired
    }

    /// One consumer per collector. Register before checking the latch so a
    /// notification between the caller's read and its suspension is retained.
    func waitForSignal(seconds: Double) async -> Bool {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            waiter = continuation
            if pending { continuation.yield(()) }
        }
        defer { finishWaiting() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in events { break }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(0, seconds)))
            }
            await group.next()
            group.cancelAll()
        }
        return consumeSignal()
    }

    func finishWaiting() {
        lock.lock()
        let live = waiter
        waiter = nil
        lock.unlock()
        live?.finish()
    }

    public func snapshot() -> [MacAXEffectNotification] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    public func first() -> MacAXEffectNotification? {
        lock.lock()
        defer { lock.unlock() }
        return received.first
    }

    public func droppedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }
}

// MARK: - One read epoch

/// One walk and everything anchored to it: the tree, the app, the window title,
/// the focus path relative to THAT root, and the root itself (needed by the
/// page-first descent and by the act's identity re-check).
public struct MacAXRead: Sendable {
    public let snapshot: MacAXTreeSnapshot
    public let app: MacAXAppInfo?
    public let rootTitle: String?
    public let focusPath: [Int]?
    public let root: MacAXElementRef
    /// gpt-5.5 round-3 B1 — WHICH window this walk was of, in terms that
    /// outlive the source's element handle. nil when the source could not name
    /// one (a synthetic single-tree source before it was asked, or a read that
    /// went through `frontmostWindowRoot()`).
    public let windowIdentity: MacAXWindowIdentity?
    public let section: String?

    public init(
        snapshot: MacAXTreeSnapshot,
        app: MacAXAppInfo?,
        rootTitle: String?,
        focusPath: [Int]?,
        root: MacAXElementRef,
        windowIdentity: MacAXWindowIdentity? = nil,
        section: String? = nil
    ) {
        self.snapshot = snapshot
        self.app = app
        self.rootTitle = rootTitle
        self.focusPath = focusPath
        self.root = root
        self.windowIdentity = windowIdentity
        self.section = section
    }
}

/// What a `mac_look` is aimed at (Agent round 2, her #1-ranked gap).
public enum MacLookScope: String, Sendable, Equatable, CaseIterable {
    /// The web page, when the window has one. The DEFAULT: a browser's whole
    /// value is the page, and the chrome is one summary line.
    case page
    /// The browser's own controls — the window walk, as it always was.
    case chrome
    /// One walk over the whole window; the page competes with the chrome for
    /// the node budget.
    case both

    public static func parse(_ raw: String?) -> MacLookScope? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .page }
        return MacLookScope(rawValue: raw)
    }
}

// MARK: - Verbs

/// What she can do to a handle. Deliberately a small closed vocabulary: the
/// model names an INTENTION, and this file decides the mechanism.
public enum MacActVerb: String, Sendable, Equatable, CaseIterable {
    case click
    /// Agent round 2 — Finder is unusable without it: a row is SELECTED by a
    /// click and OPENED by a double-click, and with no `open` there was no way
    /// to navigate by handle at all. `AXOpen` when the element advertises it,
    /// otherwise a synthesized double-click through the EXACT click path
    /// `click`'s fallback already uses.
    case open
    case type
    case focus
    case select
    case toggle
    case dismiss
    case scroll
}

public enum MacActScrollDirection: String, Sendable, Equatable {
    case up
    case down
}

// MARK: - The loop's constants and pure logic

public enum MacActClosedLoop {
    /// The twelve notification kinds the item-1 spike proved subscribe cleanly
    /// on every app tried. Together they cover every class of "the act landed":
    /// a value moved, focus moved, a window/sheet appeared or died, a title or
    /// layout changed, a menu opened, a selection or row count changed, a live
    /// region announced.
    public static let notificationKinds: [String] = [
        "AXValueChanged",
        "AXFocusedUIElementChanged",
        "AXFocusedWindowChanged",
        "AXWindowCreated",
        "AXSheetCreated",
        "AXUIElementDestroyed",
        "AXTitleChanged",
        "AXLayoutChanged",
        "AXMenuOpened",
        "AXSelectedChildrenChanged",
        "AXRowCountChanged",
        "AXLiveRegionChanged",
    ]

    /// Default wait for the FIRST notification. The spike measured 30–32 ms;
    /// 300 ms is an order of magnitude of headroom.
    public static let defaultWaitMs = 300
    /// HARD cap. A verb that waits longer than this is a hang wearing a
    /// perception costume — the caller gets `none_observed` and can look again.
    public static let maxWaitMs = 2000
    /// After the first notification, keep collecting for this long: a real UI
    /// change fires a burst (Calculator: AXValueChanged then AXTitleChanged),
    /// and a diff built from the first one alone describes half the effect.
    public static let quietWindowMs = 80
    /// Notification kinds reported in the result.
    public static let maxReportedNotifications = 12
    /// Affordance rows per diff bucket.
    public static let maxDiffRows = 10

    /// Roles `type` is allowed to touch. A text verb aimed at anything else is
    /// refused rather than approximated: the fallback path used to "focus" the
    /// control by pressing it, so `type` on a button ACTIVATED it — typing
    /// "Sounds good" into Mail's Send pressed Send. There is no reading of
    /// `type` under which that is the requested act.
    ///
    /// Web inputs surface as AXTextField/AXTextArea through the same seam, so
    /// this covers Chromium's editable elements without naming them.
    public static let typeableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        "AXSecureTextField",
    ]

    /// Whether `type` has any business on this element.
    public static func canType(role: String) -> Bool { typeableRoles.contains(role) }

    // MARK: - Secure keyboard entry (sweep item 8)

    /// A named refusal for a synthesized-input site: the machine-readable
    /// reason plus the sentence the caller is owed. Same shape and same job as
    /// `KeyWindowRefusal` — this is the second thing that eats keystrokes.
    public struct SecureInputRefusal: Equatable, Sendable {
        public let reason: String
        public let note: String
        public init(reason: String, note: String) {
            self.reason = reason
            self.note = note
        }
    }

    /// Roles that hold a SECRET. `AXSecureTextField` stays in `typeableRoles`
    /// deliberately: the answer to "type into a password field" is not the
    /// generic `verb_not_supported_on_element` shrug the non-editable roles
    /// get, it is a refusal that says what the element is and why I stopped.
    public static let secureFieldRoles: Set<String> = ["AXSecureTextField"]

    public static func isSecureField(role: String) -> Bool {
        secureFieldRoles.contains(role)
    }

    public static let secureFieldReason = "secure_field_target"
    public static let secureInputReason = "secure_input_active"

    /// `type` aimed at a password field. A deliberate boundary, not a
    /// mechanism failure: even where AXSetValue would carry it, filling
    /// someone's password box is not an act I take on my own.
    public static func secureFieldRefusal(role: String) -> SecureInputRefusal? {
        guard isSecureField(role: role) else { return nil }
        return SecureInputRefusal(
            reason: secureFieldReason,
            note: "That field is a password field (\(role)) — a secure text field. I do not type "
                + "into one: macOS turns on secure keyboard entry for it, so my keystrokes would "
                + "be swallowed anyway, and filling a credential box is yours to do, not mine. "
                + "Type it yourself and tell me when to carry on."
        )
    }

    /// Secure keyboard entry is ON somewhere on this Mac (a focused password
    /// field, `sudo` in Terminal, 1Password's own window). While it is on the
    /// window server does not deliver synthesized keystrokes to ANY app — the
    /// characters simply never arrive, and the closed loop then reports "the
    /// fresh screen did not visibly change" without ever naming the cause.
    ///
    /// `active` is measured, never assumed: false ⇒ no refusal, so this cannot
    /// become a standing block on typing.
    /// Her-screen Phase 4 — one line on why a background act needs the app in
    /// front, by the mechanism that would have had to reach the window server.
    public static func needsFrontReason(_ requestedAction: String) -> String {
        switch requestedAction {
        case "AXPress": return "that control doesn't answer an accessibility press, so it needs a real click"
        case "AXOpen": return "opening it needs a double-click or the app's Open command"
        case "type": return "the field takes neither inserted text nor keys sent to the app while it's in the back"
        case "scroll": return "scrolling it needs the wheel over the window"
        default: return "it needs real input to the window in front"
        }
    }

    public static func secureInputRefusal(active: Bool) -> SecureInputRefusal? {
        guard active else { return nil }
        return SecureInputRefusal(
            reason: secureInputReason,
            note: "Secure keyboard entry blocks synthetic typing; nothing was posted. Dismiss or unfocus its source, often a password field, Terminal sudo prompt or password manager, before continuing."
        )
    }

    /// Labels a modal's dismiss button is allowed to carry, lowercased.
    /// Ordered: the least destructive answer first, so a sheet offering both
    /// "Cancel" and "OK" is cancelled rather than confirmed.
    public static let dismissLabels: [String] = ["cancel", "close", "dismiss", "done", "ok"]

    public static func clampedWaitMs(_ requested: Int?) -> Int {
        guard let requested else { return defaultWaitMs }
        return max(0, min(requested, maxWaitMs))
    }

    // MARK: - The key-window gate (Agent round 7, NON-KEY CRITICAL FAIL)

    /// Synthesized input goes where the WINDOW SERVER sends it, and the window
    /// server sends it to whatever is key — not to whatever the frame names.
    ///
    /// Round 7, envelope 173E1B08: a fresh Finder frame, then `mac_focus_app`
    /// Chrome (verified true), then `open` on a Finder row. Every AX anchor in
    /// the act path was correct — right pid, right window, right row, selection
    /// set — and then ⌘↓ was posted into CHROME. `ok: true, status: acted`.
    /// The pid and window anchors constrain where we READ and where we perform
    /// AX actions; NOTHING in them constrains a CGEvent.
    ///
    /// (For the record: no such guard was ever removed. Agent's round-2 report
    /// described a `focus_drift_refusal` catching exactly this — that report was
    /// retracted as fabricated, the string appears nowhere in this repo's
    /// history, and the guard has never existed until now.)
    ///
    /// FAIL CLOSED. An unknown frontmost app is a refusal, not a pass: the one
    /// thing worse than refusing a legitimate act is typing into an app we
    /// could not name.
    public struct KeyWindowRefusal: Sendable, Equatable {
        public let reason: String
        public let note: String

        public init(reason: String, note: String) {
            self.reason = reason
            self.note = note
        }
    }

    /// nil ⇒ the frame's window is key and synthesized input may be posted.
    ///
    /// - Parameter focusedWindow: the app's focused window, or nil when the
    ///   source cannot tell. Cannot-tell is NOT a match and NOT a mismatch: the
    ///   app-level check has already passed by then, and inventing a
    ///   window-level verdict from silence would refuse every act on a source
    ///   that simply does not publish the attribute.
    public static func keyWindowRefusal(
        framePid: Int32,
        frontmostPid: Int32?,
        frontmostName: String?,
        /// The ELEMENT HANDLE of the window this frame was matched to, and of
        /// the app's focused window. Handles, not identities: the identity
        /// matcher exists to FIND the frame's window among an app's windows and
        /// its sole-candidate rule deliberately tolerates a retitle, which is
        /// right there and wrong here — asked "is this the key window?" it
        /// answers "yes" for the only window it was handed. The act path has
        /// already matched the frame to a concrete window, so the honest
        /// question is whether that window IS the focused one, and that is
        /// handle equality.
        frameWindowHandle: Int?,
        focusedWindowHandle: Int?,
        frameWindowTitle: String?,
        focusedWindowTitle: String?,
        /// How many windows the frame's app has RIGHT NOW, when the caller
        /// knows. Only consulted when the focused window could not be named:
        /// with one window, "this app is frontmost" already proves the frame's
        /// window is the key one, and with several it proves nothing. nil ⇒ the
        /// caller did not ask, and the old silence-tolerating rule stands.
        appWindowCount: Int? = nil
    ) -> KeyWindowRefusal? {
        let frameWindowTitle = receiptText(frameWindowTitle)
        let focusedWindowTitle = receiptText(focusedWindowTitle)
        guard let frontmostPid else {
            return KeyWindowRefusal(
                reason: "frontmost_unknown",
                note: "the frontmost application could not be read, so there is no way to know where "
                    + "a synthesized event would land — nothing was posted"
            )
        }
        guard frontmostPid == framePid else {
            let who = frontmostName.map { "\($0) (pid \(frontmostPid))" } ?? "pid \(frontmostPid)"
            return KeyWindowRefusal(
                reason: "window_not_key",
                note: "this frame was captured from pid \(framePid) but \(who) is frontmost now. A "
                    + "synthesized key or mouse event is delivered to the KEY window, so it would have "
                    + "landed in \(who), not in the window you looked at — nothing was posted and "
                    + "nothing was selected. Bring that window to the front and call mac.look again."
            )
        }
        // Right app, wrong window of it. Asserted ONLY when both handles are
        // known: a source that cannot name its focused window has told us
        // nothing, and silence is not a mismatch.
        if let frameWindowHandle, let focusedWindowHandle, frameWindowHandle != focusedWindowHandle {
            return KeyWindowRefusal(
                reason: "window_not_key",
                note: "the right app is frontmost, but its key window is not the one this frame "
                    + "describes (key: \(focusedWindowTitle ?? "untitled"); the frame names "
                    + "\(frameWindowTitle ?? "untitled")). A synthesized event goes to the key "
                    + "window — nothing was posted. Bring that window forward and look again."
            )
        }
        // "Cannot tell" is not "yes". Round 9: the mismatch above is asserted
        // only when BOTH handles are known, so a nil focused window fell
        // straight through to `return nil` and the whole second guard became a
        // pass — the app-level check alone, which is exactly the guarantee that
        // was already known to be insufficient with two Finder windows open.
        // With a single window there is nothing to be wrong about; with more
        // than one, unknown is a refusal.
        if focusedWindowHandle == nil, let appWindowCount, appWindowCount > 1 {
            return KeyWindowRefusal(
                reason: "key_window_unknown",
                note: "the right app is frontmost, but which of its \(appWindowCount) windows is key "
                    + "could not be read, so there is no way to know whether a synthesized event "
                    + "would land in \(frameWindowTitle ?? "the window this frame describes") or in "
                    + "one of the others — nothing was posted."
            )
        }
        return nil
    }

    // MARK: drift

    /// Why the live element is NOT the thing she named.
    ///
    /// The frame is up to 180 s old and a handle is a REFERENCE, not a lease:
    /// between the look and the act the app may have rebuilt the window, and
    /// the child-index path the handle resolves through would then address a
    /// DIFFERENT control. Acting anyway is the worst failure this tool has —
    /// "press Save" pressing "Delete" — so the identity is re-checked against
    /// the live element and a mismatch fails loud.
    public static func driftReason(
        expectedRole: String,
        expectedLabel: String?,
        liveRole: String,
        liveTitle: String?,
        liveValue: String?
    ) -> String? {
        if liveRole != expectedRole {
            return "role"
        }
        // The label is only compared when the FRAME recorded one. An affordance
        // label can be title-derived or value-derived (a popup button publishes
        // its own state as its name), so the live side is read the same way the
        // compiler read it: title first, value as the fallback.
        guard let expectedLabel = normalizedLabel(expectedLabel) else { return nil }
        let live = normalizedLabel(liveTitle) ?? normalizedLabel(liveValue)
        guard let live else { return "label" }
        return live == expectedLabel ? nil : "label"
    }

    /// How far a positional handle's element may have moved and still be the
    /// same element. Two points: enough for a re-layout's sub-pixel rounding,
    /// far less than any real row height.
    public static let positionalDriftTolerancePoints: Double = 2

    /// The B3 verdict: WHICH identity component moved, and what is there now.
    public struct IdentityDrift: Sendable, Equatable {
        public let on: String
        public let found: JSONValue
    }

    /// gpt-5.5 round-2 B3 / Agent #3b — the FULL identity re-check.
    ///
    /// `driftReason` compares role and label, which passes the worst realistic
    /// drift there is: two buttons both labeled "Send", the one above
    /// disappears, and the path she named now addresses the other one. Same
    /// role, same label, wrong button, and the loop presses it.
    ///
    /// So the caller re-compiles the live window through the SAME walker and
    /// compiler the look ran, and hands the affordance now sitting at the
    /// frame's path to this function. Two rules:
    ///   1. the RENDERED HANDLE (fingerprint + ordinal, or the content-identity
    ///      name for a title-less row) must be the same string;
    ///   2. for a handle the frame already marked `ambiguous` — a document-order
    ///      ordinal among genuinely identical siblings — the handle CANNOT tell
    ///      those siblings apart by construction, so the recorded frame rect
    ///      must match within `positionalDriftTolerancePoints` as well.
    ///
    /// The live element a frame entry must be re-checked against, looked up in
    /// the SAME channels that entry could have been minted from.
    ///
    /// Agent acceptance round 2, Notes: an empty note-body `AXTextArea` has no
    /// title and no value, so the compiler counts it as an unlabeled interactive
    /// element and it is never an affordance — but `MacLookFrame.entries` still
    /// mints a FOCUS-derived entry for it, and that handle resolves. Looking the
    /// live element up in `affordances` alone therefore found nothing, every
    /// time, and `type` on the focused note body refused `element_absent`
    /// forever. A focus-only handle was permanently un-actable.
    ///
    /// So: the affordance at that path, ELSE the live focus when the focus is
    /// AT that path. The focus case is rendered into the same shape a frame
    /// entry was minted from (its handle, role and compiler-redacted label), so
    /// the full-identity comparison below still does real work — a focus that
    /// moved to a different path, or a different control now focused at that
    /// path, still refuses.
    public static func liveIdentity(
        entry: MacLookFrameEntry,
        percept: MacLookPercept
    ) -> MacLookAffordance? {
        if let affordance = percept.affordances.first(where: { $0.path == entry.path }) {
            return affordance
        }
        guard let focus = percept.focus, focus.path == entry.path, let handle = focus.handle else {
            return nil
        }
        // Built from the FOCUS channel exactly as `MacLookFrame.entries` built
        // the entry from it: the rendered handle, the role, and the label the
        // compile redacted under the full node context. `frame` stays nil — the
        // focus channel publishes no rect, which is why a focus-derived entry is
        // never `ambiguous` and never reaches the positional branch.
        return MacLookAffordance(
            handle: handle,
            role: focus.role,
            label: focus.label ?? "",
            labelSource: "focus",
            path: focus.path,
            labelJSON: focus.labelJSON
        )
    }

    /// Nothing at that path at all is drift too: the element she named is not
    /// merely different, it is not there.
    public static func identityDrift(
        entry: MacLookFrameEntry,
        live: MacLookAffordance?
    ) -> IdentityDrift? {
        guard let live else {
            return IdentityDrift(
                on: "element_absent",
                found: .object([
                    "role": .null,
                    "handle": .null,
                    "label": .null,
                    "note": .string("no addressable control is at that path in the live window"),
                ])
            )
        }
        func foundJSON(_ note: String) -> JSONValue {
            .object([
                "role": .string(live.role),
                "handle": .string(live.handle),
                "label": live.labelJSON
                    ?? MacScreenViewTextRedaction.redactedLegendString(
                        live.label,
                        valueChars: MacAXLimits.hardValueChars
                    ),
                "note": .string(note),
            ])
        }
        if live.handle != entry.handle {
            return IdentityDrift(
                on: "handle",
                found: foundJSON("a different control now renders at that path")
            )
        }
        guard entry.ambiguous else { return nil }
        // A same-label sibling ABOVE disappearing is invisible to every check so
        // far: the rendered handle is still `token.2`, the role and label are
        // identical, and a re-flowed list draws the new occupant at the OLD
        // rect. What does move is the size of the cohort the ordinal was drawn
        // from — "ordinal:2 of 3" becomes "ordinal:2 of 2". That is Agent's
        // "Send #2 became Send #1", and it is the reason this compares the note
        // and not just the geometry.
        if let was = entry.ambiguityNote, was != live.handleAmbiguity {
            return IdentityDrift(
                on: "positional_cohort",
                found: foundJSON(
                    "that handle is a position-derived ordinal and the set of identical elements it "
                    + "was numbered within changed (was \"\(was)\", now "
                    + "\"\(live.handleAmbiguity ?? "no longer ambiguous")\")"
                )
            )
        }
        // A position-derived handle is only as good as the position.
        guard let was = entry.frame, let now = live.frame else {
            return IdentityDrift(
                on: "positional_rect_unknown",
                found: foundJSON(
                    "that handle is a position-derived ordinal and the live element publishes no "
                    + "frame, so its identity cannot be confirmed"
                )
            )
        }
        let tolerance = positionalDriftTolerancePoints
        let moved = abs(was.x - now.x) > tolerance
            || abs(was.y - now.y) > tolerance
            || abs(was.w - now.w) > tolerance
            || abs(was.h - now.h) > tolerance
        guard moved else { return nil }
        return IdentityDrift(
            on: "positional_rect",
            found: foundJSON(
                "that handle is a position-derived ordinal and the element at that position moved "
                + "(was \(rectText(was)), now \(rectText(now)))"
            )
        )
    }

    static func rectText(_ frame: MacAXFrame) -> String {
        func short(_ value: Double) -> String { String(format: "%.0f", value) }
        return "\(short(frame.x)),\(short(frame.y)) \(short(frame.w))×\(short(frame.h))"
    }

    static func normalizedLabel(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: the wait

    public struct EffectWait: Sendable, Equatable {
        public let observed: Bool
        public let firstNotificationMs: Int?
        public let notifications: [String]
        public let notificationCount: Int
        public let dropped: Int

        public init(
            observed: Bool,
            firstNotificationMs: Int?,
            notifications: [String],
            notificationCount: Int,
            dropped: Int
        ) {
            self.observed = observed
            self.firstNotificationMs = firstNotificationMs
            self.notifications = notifications
            self.notificationCount = notificationCount
            self.dropped = dropped
        }
    }

    /// Wait for the first notification + the quiet window, or for `waitMs` to
    /// elapse with nothing.
    ///
    /// NOTHING IS A REAL ANSWER. A verb that produced no observable AX change
    /// returns `observed: false` — that is information (the button did nothing,
    /// or this app publishes no notifications), and reporting it as a failure
    /// or hiding it behind an optimistic "acted" is what makes a model re-look.
    /// The notification kinds a NAVIGATION has actually happened by.
    ///
    /// Agent round 7, envelope 4E998341: `open` navigated — a fresh look right
    /// after proved the destination — and the same call reported
    /// `acted_unobserved / navigation_unverified`. The wait below returns on the
    /// FIRST notification, and the first notification after select-then-⌘↓ is
    /// the SELECTION (`AXValueChanged`/`AXSelectedRowsChanged`), which arrives in
    /// milliseconds. Finder's retitle — the signal `navigated` is defined by —
    /// lands after the folder loads, well past the 300 ms default. So the loop
    /// stopped watching, the post-act recompile read the OLD title, and the
    /// verdict was "unverified" for an act that had plainly worked.
    ///
    /// Waiting for one of THESE (or the deadline) instead of for the first
    /// anything is the fix: a navigation verb is watched until the surface
    /// actually transitions.
    /// EVERY member must also be in `notificationKinds` — a kind we wait for but
    /// never SUBSCRIBE to can never arrive, so it would turn the wait into a
    /// guaranteed timeout: a silent 1.5 s tax on every `open`, with the verdict
    /// no better than before. (`AXWindowTitleChanged` and `AXMainWindowChanged`
    /// were in the first draft of this set and are NOT subscribed; they are
    /// dropped rather than subscribed, because the observer set is the measured
    /// one and this list is not the place to widen it.) Pinned by a test.
    ///
    /// `AXUIElementDestroyed` is deliberately absent: elements are torn down
    /// constantly and ending the wait on one would stop watching for a
    /// non-navigation reason, which is the exact shape of the bug being fixed.
    public static let navigationNotificationKinds: Set<String> = [
        // Finder retitles the window to the opened folder — the measured signal.
        "AXTitleChanged",
        "AXFocusedWindowChanged",
        "AXWindowCreated",
        // A sheet opening IS a transition, and `navigated` already counts it.
        "AXSheetCreated",
    ]

    /// A navigation verb's default budget. The 300 ms default was tuned on
    /// Calculator, where the effect IS the first notification; a folder load is
    /// a different order of magnitude. Still under `maxWaitMs`, and still a
    /// DEADLINE, not a sleep — the wait ends the moment the signal arrives.
    public static let navigationWaitMs = 1500

    public static func waitForEffect(
        collector: MacAXEffectCollector,
        waitMs: Int,
        quietMs: Int = quietWindowMs,
        startedAt: Date,
        clock: @escaping @Sendable () -> Date,
        /// When non-empty, the wait does not stop at the first notification of
        /// any kind — it keeps watching until one of THESE arrives or the
        /// deadline passes. Empty (the default) is the original behaviour, so
        /// every non-navigation verb is untouched.
        until: Set<String> = []
    ) async -> EffectWait {
        let deadline = startedAt.addingTimeInterval(Double(waitMs) / 1000.0)
        while !Task.isCancelled, clock() < deadline {
            let notifications = collector.snapshot()
            if !notifications.isEmpty,
               until.isEmpty || notifications.contains(where: { until.contains($0.kind) }) { break }
            _ = await collector.waitForSignal(seconds: deadline.timeIntervalSince(clock()))
        }
        guard let first = collector.first() else {
            return EffectWait(
                observed: false,
                firstNotificationMs: nil,
                notifications: [],
                notificationCount: 0,
                dropped: collector.droppedCount()
            )
        }
        if !Task.isCancelled, quietMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(quietMs) * 1_000_000)
        }
        let all = collector.snapshot()
        return EffectWait(
            observed: true,
            firstNotificationMs: max(0, Int(first.at.timeIntervalSince(startedAt) * 1000)),
            notifications: Array(all.prefix(maxReportedNotifications).map(\.kind)),
            notificationCount: all.count,
            dropped: collector.droppedCount()
        )
    }

    // MARK: the diff

    public struct ChangedAffordance: Sendable, Equatable {
        public let handle: String
        public let role: String
        public let beforeLabel: String?
        public let afterLabel: String?
        public let beforeValue: String?
        public let afterValue: String?
        public let beforeEnabled: Bool
        public let afterEnabled: Bool
        /// gpt-5.5 round-2 B4 — the four text sides as the COMPILER redacted
        /// them, each with the enclosing-caption context of its own walk. A
        /// stored string re-redacted here cannot see the group titled "CVV",
        /// so `changed` was a second way out for a value `look` had hidden.
        public let beforeLabelJSON: JSONValue?
        public let afterLabelJSON: JSONValue?
        public let beforeValueJSON: JSONValue?
        public let afterValueJSON: JSONValue?

        public init(
            handle: String,
            role: String,
            beforeLabel: String?,
            afterLabel: String?,
            beforeValue: String?,
            afterValue: String?,
            beforeEnabled: Bool,
            afterEnabled: Bool,
            beforeLabelJSON: JSONValue? = nil,
            afterLabelJSON: JSONValue? = nil,
            beforeValueJSON: JSONValue? = nil,
            afterValueJSON: JSONValue? = nil
        ) {
            self.beforeLabelJSON = beforeLabelJSON
            self.afterLabelJSON = afterLabelJSON
            self.beforeValueJSON = beforeValueJSON
            self.afterValueJSON = afterValueJSON
            self.handle = handle
            self.role = role
            self.beforeLabel = beforeLabel
            self.afterLabel = afterLabel
            self.beforeValue = beforeValue
            self.afterValue = afterValue
            self.beforeEnabled = beforeEnabled
            self.afterEnabled = afterEnabled
        }

        public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
            func redacted(_ text: String?, under caption: String?) -> JSONValue {
                guard let text else { return .null }
                return MacScreenViewTextRedaction.redactedLegendString(
                    text,
                    valueChars: valueChars,
                    under: caption
                )
            }
            var object: [String: JSONValue] = [
                "handle": .string(handle),
                "role": .string(role),
            ]
            // The compiler's own redaction wins wherever it exists; the
            // standalone redactor is only the floor for a side that never came
            // from a compile (a focus-only entry).
            if beforeLabel != afterLabel {
                object["label_before"] = beforeLabelJSON ?? redacted(beforeLabel, under: nil)
                object["label_after"] = afterLabelJSON ?? redacted(afterLabel, under: nil)
            }
            if beforeValue != afterValue {
                object["value_before"] = beforeValueJSON
                    ?? redacted(beforeValue, under: afterLabel ?? beforeLabel)
                object["value_after"] = afterValueJSON
                    ?? redacted(afterValue, under: afterLabel ?? beforeLabel)
            }
            if beforeEnabled != afterEnabled {
                object["enabled_before"] = .bool(beforeEnabled)
                object["enabled_after"] = .bool(afterEnabled)
            }
            return .object(object)
        }
    }

    /// Agent acceptance round 1, finding A — what a READ-ONLY value changed to.
    ///
    /// She pressed Equals; the affordance diff said "All Clear appeared" and
    /// nothing anywhere said "390". The one thing she acted FOR was not in the
    /// percept. A display that changed IS the effect.
    public struct ReadoutChange: Sendable, Equatable {
        public let handle: String?
        public let path: [Int]
        public let role: String
        public let beforeText: String?
        public let afterText: String?
        /// gpt-5.5 round-3 B3 — the before/after text AS EACH COMPILE REDACTED
        /// IT, under the full node context of the walk it came from. The
        /// standalone redactor this used to run cannot see a caption two rows
        /// up, so a readout of `123` inside a group titled "CVV" — correctly
        /// withheld everywhere in the look — came back in the clear here the
        /// moment it changed to `456`. `readouts_changed` rides the turn trace,
        /// the operation store and the iOS/Telegram sync like every other
        /// channel.
        public let beforeJSON: JSONValue?
        public let afterJSON: JSONValue?
        /// Agent acceptance round 2, Calculator's Equals — this readout is ONE
        /// control whose KEY moved, not a removal plus an addition. The readout
        /// key is the handle, the handle's fingerprint includes the title, and
        /// Calculator retitles its display when it shows a result, so "42"
        /// arrived as `readouts_added_total: 2 / readouts_removed_total: 1` with
        /// an EMPTY `readouts_changed`: the one number she pressed Equals for
        /// was nowhere in the act's own answer. An add and a remove at the SAME
        /// path with the SAME role are that one control, paired here.
        public let renamed: Bool

        public init(
            handle: String?,
            path: [Int],
            role: String,
            beforeText: String?,
            afterText: String?,
            beforeJSON: JSONValue? = nil,
            afterJSON: JSONValue? = nil,
            renamed: Bool = false
        ) {
            self.handle = handle
            self.path = path
            self.role = role
            self.beforeText = beforeText
            self.afterText = afterText
            self.beforeJSON = beforeJSON
            self.afterJSON = afterJSON
            self.renamed = renamed
        }

        public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
            /// FAIL CLOSED. A side with no compile verdict is a side nothing
            /// judged in context — and the context-free second opinion is
            /// exactly the hole B3 names. So it leaves as a count+digest, not
            /// as characters: in production both sides always carry a verdict
            /// (the frame records it, the after-percept computes it), and this
            /// branch is only reachable for a record built by hand.
            func emit(_ json: JSONValue?, raw: String?) -> JSONValue {
                if let json { return json }
                guard let raw else { return .null }
                return MacInjectionResultRedaction.redactedSecret(raw)
            }
            var object: [String: JSONValue] = [
                "role": .string(role),
                "path": .array(path.map { .int(Int64($0)) }),
                "before": emit(beforeJSON, raw: beforeText),
                "after": emit(afterJSON, raw: afterText),
            ]
            if let handle { object["handle"] = .string(handle) }
            // Emitted only when true, so an ordinary changed row is byte-for-byte
            // what it always was.
            if renamed { object["renamed"] = .bool(true) }
            return .object(object)
        }
    }

    /// One readout that APPEARED or VANISHED (Agent acceptance round 2).
    ///
    /// Totals alone were the defect: `readouts_added_total: 2` does not contain
    /// "42". The rows carry the text, capped by `maxDiffRows` like every other
    /// diff bucket, and through the SAME redactor `ReadoutChange.toJSON` uses —
    /// a readout is a VALUE and this rides the turn trace, the operation store
    /// and the iOS/Telegram sync.
    public struct ReadoutRow: Sendable, Equatable {
        public let handle: String?
        public let path: [Int]
        public let role: String
        public let text: String?
        /// gpt-5.5 review of this very patch — the text AS THE COMPILE REDACTED
        /// IT, under the full node context. Round 3 closed exactly this hole on
        /// `readouts_changed` (a readout of `123` inside a group titled "CVV" is
        /// in the clear by shape alone, and the standalone redactor cannot see
        /// the caption two rows up); emitting these NEW rows through the
        /// context-free redactor would have reopened it on two fresh channels.
        /// The raw `text` stays for the DIFF, which must compare what the app
        /// really says or two different secrets both digest to the same marker
        /// and read as "unchanged".
        public let textJSON: JSONValue?

        public init(
            handle: String?,
            path: [Int],
            role: String,
            text: String?,
            textJSON: JSONValue? = nil
        ) {
            self.handle = handle
            self.path = path
            self.role = role
            self.text = text
            self.textJSON = textJSON
        }

        public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
            var object: [String: JSONValue] = [
                "role": .string(role),
                "path": .array(path.map { .int(Int64($0)) }),
                // The compile's verdict wins; the standalone redactor is only
                // the floor for a row that never came from one.
                "text": textJSON ?? text.map {
                    MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
                } ?? .null,
            ]
            if let handle { object["handle"] = .string(handle) }
            return .object(object)
        }
    }

    public struct EffectDiff: Sendable, Equatable {
        public let added: [MacLookAffordance]
        public let removed: [MacLookFrameEntry]
        public let changed: [ChangedAffordance]
        /// Agent round 2 — a Finder view switch added 44 affordances and the
        /// result showed 10 of them. Ten rows out of forty-four is not a
        /// description of what happened; the CENSUS is, and it is computed over
        /// the FULL sets before the row cap bites.
        public let addedByRole: [String: Int]
        public let removedByRole: [String: Int]
        public let addedTotal: Int
        public let removedTotal: Int
        public let changedTotal: Int
        public let focusChanged: Bool
        public let focusHandleAfter: String?
        public let focusLabelAfter: String?
        /// B4 — the focused element's label as the after-percept redacted it.
        public let focusLabelJSONAfter: JSONValue?
        public let focusRoleAfter: String?
        public let modalAppeared: Bool
        public let modalDisappeared: Bool
        public let modalLabelAfter: String?
        public let windowTitleChanged: Bool
        public let windowTitleAfter: String?
        // finding A — the read-only values. Defaulted so a frame recorded
        // before readouts existed reports none rather than fabricating them.
        public let readoutsChanged: [ReadoutChange]
        public let readoutsChangedTotal: Int
        public let readoutsAddedTotal: Int
        public let readoutsRemovedTotal: Int
        /// The ROWS behind those totals (round 2). Capped by `maxDiffRows`.
        public let readoutsAdded: [ReadoutRow]
        public let readoutsRemoved: [ReadoutRow]
        /// Were the two compiles allowed to see the same window? False when one
        /// side's walk truncated or the two ran under different caps — the
        /// added/removed affordance and readout CENSUS is a set difference and
        /// means nothing
        /// across mismatched bounds. Said out loud rather than dropped silently.
        public let diffComparable: Bool
        public let diffIncomparableReason: String?

        public init(
            added: [MacLookAffordance],
            removed: [MacLookFrameEntry],
            changed: [ChangedAffordance],
            addedByRole: [String: Int] = [:],
            removedByRole: [String: Int] = [:],
            addedTotal: Int,
            removedTotal: Int,
            changedTotal: Int,
            focusChanged: Bool,
            focusHandleAfter: String?,
            focusLabelAfter: String?,
            focusLabelJSONAfter: JSONValue? = nil,
            focusRoleAfter: String?,
            modalAppeared: Bool,
            modalDisappeared: Bool,
            modalLabelAfter: String?,
            windowTitleChanged: Bool,
            windowTitleAfter: String?,
            readoutsChanged: [ReadoutChange] = [],
            readoutsChangedTotal: Int = 0,
            readoutsAddedTotal: Int = 0,
            readoutsRemovedTotal: Int = 0,
            readoutsAdded: [ReadoutRow] = [],
            readoutsRemoved: [ReadoutRow] = [],
            diffComparable: Bool = true,
            diffIncomparableReason: String? = nil
        ) {
            self.readoutsAdded = readoutsAdded
            self.readoutsRemoved = readoutsRemoved
            self.diffComparable = diffComparable
            self.diffIncomparableReason = diffIncomparableReason
            self.added = added
            self.removed = removed
            self.changed = changed
            self.addedByRole = addedByRole
            self.removedByRole = removedByRole
            self.addedTotal = addedTotal
            self.removedTotal = removedTotal
            self.changedTotal = changedTotal
            self.focusChanged = focusChanged
            self.focusHandleAfter = focusHandleAfter
            self.focusLabelAfter = focusLabelAfter
            self.focusLabelJSONAfter = focusLabelJSONAfter
            self.focusRoleAfter = focusRoleAfter
            self.modalAppeared = modalAppeared
            self.modalDisappeared = modalDisappeared
            self.modalLabelAfter = modalLabelAfter
            self.windowTitleChanged = windowTitleChanged
            self.windowTitleAfter = windowTitleAfter
            self.readoutsChanged = readoutsChanged
            self.readoutsChangedTotal = readoutsChangedTotal
            self.readoutsAddedTotal = readoutsAddedTotal
            self.readoutsRemovedTotal = readoutsRemovedTotal
        }

        /// True when NOTHING in the compiled percept moved. Reported so a
        /// caller can tell "the app fired a notification but the window looks
        /// identical" from "the window changed".
        ///
        /// A DISPLAY THAT CHANGED IS A CHANGE (finding A): Calculator's Equals
        /// moves no affordance label, and reporting that as "nothing moved"
        /// would be the same blindness in a new place.
        public var isEmpty: Bool { changeReasons.isEmpty }

        /// EVERY channel that actually moved, named (Agent acceptance round 2,
        /// Finder `open`). `window_changed: true` came back on an act whose
        /// window title, glance and focus were all unchanged — the "change" was
        /// 29 affordances added and 1 removed by a CAPPED recompile. A boolean
        /// with no evidence behind it is a claim; this is the evidence, and
        /// `windowChanged` is exactly `!changeReasons.isEmpty`, so a true with
        /// no reasons is unrepresentable.
        ///
        /// Both affordance and readout added/removed counts are omitted when the
        /// two compiles were not comparable. The other channels stay: they are keyed by IDENTITY
        /// (a handle's before/after, the focus, the modal, the title, a
        /// readout's key) rather than by set membership, so a cap that hides
        /// rows cannot fabricate one of them.
        public var changeReasons: [String] {
            var out: [String] = []
            if diffComparable {
                if addedTotal > 0 { out.append("affordances_added") }
                if removedTotal > 0 { out.append("affordances_removed") }
                if readoutsAddedTotal > 0 { out.append("readouts_added") }
                if readoutsRemovedTotal > 0 { out.append("readouts_removed") }
            }
            if changedTotal > 0 { out.append("affordances_changed") }
            if focusChanged { out.append("focus_changed") }
            if modalAppeared { out.append("modal_appeared") }
            if modalDisappeared { out.append("modal_disappeared") }
            if windowTitleChanged { out.append("window_title_changed") }
            if readoutsChangedTotal > 0 { out.append("readouts_changed") }
            return out
        }

        public var windowChanged: Bool { !changeReasons.isEmpty }

        /// Did the window actually GO SOMEWHERE, as opposed to merely twitch?
        ///
        /// LIVE EVIDENCE, Agent round 6 (receipt 1780C1D3, frame A4A9362E): an
        /// `open` that navigated NOWHERE was classified `acted` because
        /// `windowChanged` was true off `change_reasons: ["readouts_changed"]`
        /// ALONE — and that sole readout delta was noise: a text expansion
        /// "Doc" → "Document" on a DIFFERENT row (handle zmyzpv, path
        /// [0,2,0,0,7,3,0]) that the rename pairing mistook for a rename. The
        /// Finder title, the acted element and the focus were all unchanged and
        /// the census was explicitly incomparable (both walks truncated).
        ///
        /// So navigation is a STRUCTURAL move and nothing else: the window
        /// retitled (Finder retitles to the folder name on a real navigation —
        /// that is the true signal), a modal opened or closed, or the affordance
        /// set genuinely turned over UNDER A COMPARABLE census. Deliberately
        /// EXCLUDED: `readouts_changed` alone (round-6 evidence above),
        /// `focus_changed` alone (selection is not navigation),
        /// `affordances_changed` alone (a highlight or enabled flip), and ANY
        /// added/removed churn when `diffComparable` is false.
        ///
        /// This is the predicate the round-5 KNOWN LIMIT deferred for want of a
        /// live envelope. BD132A79 is that envelope.
        public var navigated: Bool {
            if windowTitleChanged || modalAppeared || modalDisappeared { return true }
            if diffComparable, addedTotal > 0 || removedTotal > 0 { return true }
            return false
        }
    }

    /// What a press caused (Resolve 10-17: the Edit tab read selected while
    /// the page never changed). `own`: the pressed control's value, label or
    /// selection, its same-kind siblings' (that selection moving), or its own
    /// retitle (an added/removed pair at one path) — proof of the press, not
    /// of a consequence. `consequence`: structural only — the window's title
    /// or modal, controls appearing or going (both reads complete), another
    /// control renamed, or the focus landing on what was clicked. A value
    /// moving elsewhere (a readout, a counter) is shown, never evidence.
    public static func pressEvidence(
        _ diff: EffectDiff, before: MacLookFrame, pressed: MacLookFrameEntry, clicked: Bool
    ) -> (own: Bool, consequence: Bool) {
        func inGroup(_ path: [Int], _ role: String) -> Bool {
            path == pressed.path || (role == pressed.role && path.dropLast() == pressed.path.dropLast())
        }
        let retitled = Set(diff.added.filter { inGroup($0.path, $0.role) }.map(\.path))
            .intersection(diff.removed.filter { inGroup($0.path, $0.role) }.map(\.path))
        var own = !retitled.isEmpty
        var renamed = false
        for row in diff.changed {
            guard let path = before.entries[row.handle]?.path else { continue }
            if inGroup(path, row.role) { own = true } else if row.beforeLabel != row.afterLabel { renamed = true }
        }
        let consequence = diff.windowTitleChanged || diff.modalAppeared || diff.modalDisappeared || renamed
            || (diff.diffComparable && diff.addedTotal + diff.removedTotal > 2 * retitled.count)
            || (clicked && diff.focusChanged && diff.focusHandleAfter == pressed.handle)
        return (own, consequence)
    }

    // MARK: - The Open command (Agent round 6, live)

    /// Apps whose "open the selected item" keystroke is PROVEN, by app name.
    ///
    /// Round 6 measured this on the live desktop and every other mechanism
    /// lost: `AXOpen` on Finder's filename field is advertised and returns
    /// kAXErrorActionUnsupported (-25205) even with the row selected;
    /// `AXConfirm` returns success and navigates nothing; a synthesized
    /// double-click is inert at the row centre AND at the filename. Setting
    /// `AXSelected` on the row and pressing ⌘↓ navigated — window title
    /// `home-folder` → `.agent-browser`.
    ///
    /// A TABLE, not a general rule, deliberately: ⌘↓ is Finder's Open. Firing
    /// an unverified chord into an arbitrary app is how you get a confident
    /// keystroke doing something nobody asked for — the same class of bug as
    /// the inert double-click, an action taken on faith. Apps join this table
    /// when someone MEASURES them, not when someone assumes.
    /// Keyed by BUNDLE ID, never the display name: `appName` is localized
    /// ("Finder" is "Finder" in English and something else elsewhere), and any
    /// app may call itself Finder. A localized string deciding whether to post
    /// a keystroke is a gate that opens for the wrong app.
    public static func openCommandChord(forBundleId bundleId: String?) -> MacKeyChord? {
        guard let bundleId else { return nil }
        switch bundleId {
        case "com.apple.finder":
            return MacKeyChord(modifiers: .command, keyCode: 0x7D, source: "cmd+down")
        default:
            return nil
        }
    }

    /// Does the destination we LANDED on correspond to what we asked to open?
    /// Finder retitles the window to the opened folder's name, so the acted
    /// row's label and the post-act title are directly comparable.
    ///
    /// Nil means NOT CHECKABLE, which is not the same as matched — the caller
    /// falls back to the structural floor rather than promoting.
    public static func destinationMatchesIntent(
        title: String?,
        intendedTarget: String?
    ) -> Bool? {
        guard let intendedTarget, let title else { return nil }
        func norm(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let want = norm(intendedTarget), got = norm(title)
        guard !want.isEmpty, !got.isEmpty else { return nil }
        // EXACT ONLY. gpt-5.5 round-7 review killed the substring rule: with it,
        // opening "Doc" was "matched" by a window titled "Documents", and
        // "agent" by ".agent-browser" — a promotion to success on a coincidence
        // of spelling. Finder's measured behaviour is an exact retitle to the
        // folder's display name, so exactness costs nothing real and a false
        // match costs a false success, which is the bug this whole round is about.
        return got == want
    }

    // MARK: - Act status classification (Agent acceptance round 4, finding 1)

    /// Verbs whose success means the surface **transitioned** — a different
    /// place, not merely a reaction.
    ///
    /// `open` is the whole set today, and it is the verb that earned this.
    /// Agent round 4, Finder `open` on `.agents`: `AXOpen` was refused, the
    /// CGEvent double-click fallback ran, Finder published an
    /// `AXRowCountChanged`, and the act came back `acted` — while the window
    /// title was still `home-folder`, the acted element was still `.agents`,
    /// every readout was unchanged and `effect.window_changed` was **false**.
    /// Nothing navigated. A notification is proof the app REACTED; for a
    /// navigation verb it is not proof the app WENT anywhere, and `acted` on a
    /// navigation verb reads as "you are there now".
    ///
    /// `dismiss` is a deliberate omission rather than an oversight: its success
    /// shows up as `modal_disappeared`/`affordances_removed`, both already in
    /// `changeReasons`, but it has had no live acceptance run behind it and a
    /// verb is added to this set from evidence, not from symmetry.
    public static let navigationVerbs: Set<MacActVerb> = [.open]

    public struct ActClassification: Sendable, Equatable {
        public let status: String
        /// A machine-readable code, `nil` on a clean `acted`.
        public let reason: String?
        /// The same verdict in a sentence the caller can act on.
        public let note: String?

        public init(status: String, reason: String? = nil, note: String? = nil) {
            self.status = status
            self.reason = reason
            self.note = note
        }

        var receipt: [String: JSONValue] {
            ["status": .string(status), "verified": .bool(status == "acted"),
             "status_reason": reason.map(JSONValue.string) ?? .null,
             "status_note": note.map(JSONValue.string) ?? .null,
             "verification_evidence": status == "acted" ? note.map(JSONValue.string) ?? .null : .null,
             "verification_scope": .string("declared_effect")]
        }
    }

    /// The act declares its effect before input. All routes use this judge;
    /// pixels and notification counts alone cannot satisfy a declaration.
    enum DeclaredEffect {
        case text(String?)
        case selectAll
        case selected
        case state(String?)
        case focus
        case surface(String?)
        case dismissed
        case scroll
        case pointer
    }

    static func verify(
        _ effect: DeclaredEffect,
        value: String? = nil, selection: NSRange? = nil,
        selected: Bool? = nil, focused: Bool? = nil,
        surfaceChanged: Bool? = nil, dismissed: Bool? = nil, processGone: Bool = false,
        diff: EffectDiff? = nil, notifications: [String] = [],
        pointerOnTarget: Bool? = nil, redactingText: Bool = false,
        press: (before: MacLookFrame, target: MacLookFrameEntry)? = nil,
        destinationJSON: JSONValue? = nil, windowTitleJSON: JSONValue? = nil
    ) -> ActClassification {
        let matches: Bool?
        let readback: String
        var mismatch = "The declared effect differs from the target's accessibility state."
        switch effect {
        case .text(let expected):
            readback = "The complete AXValue matches the declared edit."
            // Canonical field masking makes the complete text unavailable,
            // including short masked values and fields with no secure subrole.
            guard let expected, let value,
                  !MacScreenViewBuilder.isSecretField(role: "AXTextField", subrole: nil, label: nil, value: value) else {
                return ActClassification(status: "acted_unobserved", reason: "effect_unreadable",
                    note: "The input went out, but the complete text value could not be read back.")
            }
            matches = value == expected
            if matches == false {
                let offset = zip(expected.utf16, value.utf16).prefix { $0 == $1 }.count
                func excerpt(_ text: String) -> String {
                    if redactingText { return "[redacted]" }
                    if case .object = MacScreenViewTextRedaction.redactedLegendString(
                        text, valueChars: MacAXLimits.hardValueChars) { return "[redacted]" }
                    let tail = String(decoding: Array(text.utf16.dropFirst(max(0, offset - 1)).prefix(40)), as: UTF16.self)
                    return receiptText(tail) ?? ""
                }
                return ActClassification(status: "acted_mismatch", reason: "text_mismatch",
                    note: "AXValue differs at UTF-16 offset \(offset): expected \"\(excerpt(expected))\", read \"\(excerpt(value))\" (expected length \(expected.utf16.count), read length \(value.utf16.count)).")
            }
        case .selectAll:
            readback = "AXSelectedTextRange covers the complete AXValue."
            matches = value.flatMap { value in selection.map { $0 == NSRange(location: 0, length: value.utf16.count) } }
            if matches == false, let selection, let value {
                return ActClassification(status: "acted_mismatch", reason: "selection_mismatch",
                    note: "AXSelectedTextRange is \(selection.location):\(selection.length); expected 0:\(value.utf16.count).")
            }
        case .selected:
            readback = "The target reads AXSelected:true."
            matches = selected
            if selected == false {
                return ActClassification(status: "acted_mismatch", reason: "selection_mismatch",
                    note: "The target reads AXSelected:false; expected true.")
            }
        case .state(let expected):
            readback = "The target's AXValue matches the declared state."
            matches = expected.flatMap { expected in value.map { $0 == expected } }
            if matches == false, let expected, let value {
                return ActClassification(status: "acted_mismatch", reason: "state_mismatch",
                    note: "AXValue reads \"\(receiptText(value) ?? "")\"; expected \"\(receiptText(expected) ?? "")\".")
            }
        case .focus:
            readback = "The target owns accessibility focus in its process and window."
            mismatch = "The target does not own accessibility focus in its process and window."
            matches = focused
        case .surface(let destination):
            let windowCreated = notifications.contains("AXWindowCreated")
            let sheetCreated = notifications.contains("AXSheetCreated")
            readback = processGone ? "The target app is no longer running."
                : sheetCreated && surfaceChanged == true ? "A sheet opened in the target app."
                : windowCreated && surfaceChanged == true ? "A window opened in the target app."
                : dismissed == true || diff?.modalDisappeared == true
                    ? "The target window or modal is no longer present in its process."
                : diff?.modalAppeared == true ? "A modal appeared in the target app."
                : "The target's accessibility surface changed."
            mismatch = "The target's AX surface is unchanged; a surface transition was expected."
            // Notifications wake the read; only the owning process's window
            // inventory or its modal readback establishes the declared effect.
            if processGone || dismissed == true || diff?.modalDisappeared == true
                || surfaceChanged == true || diff?.modalAppeared == true {
                matches = true
            } else if let diff {
                if diff.windowTitleChanged, let destination,
                   destinationMatchesIntent(title: diff.windowTitleAfter, intendedTarget: destination) == false {
                    return ActClassification(status: "acted_mismatch", reason: "destination_mismatch",
                        note: "The window reads \"\(receiptText(diff.windowTitleAfter, redacted: windowTitleJSON) ?? "")\"; expected destination \"\(receiptText(destination, redacted: destinationJSON) ?? "")\".")
                }
                let moved = press.map { pressEvidence(diff, before: $0.before, pressed: $0.target, clicked: true).consequence }
                    ?? diff.navigated
                matches = moved ? true : diff.diffComparable ? false : nil
            } else { matches = surfaceChanged }
        case .dismissed:
            readback = "The target window or modal is no longer present in its process."
            mismatch = "The target window or modal is still present; dismissal was expected."
            matches = processGone || dismissed == true || diff?.modalDisappeared == true
                ? true : dismissed ?? diff.map { $0.modalDisappeared }
        case .scroll:
            readback = "The target's accessibility scroll state changed."
            mismatch = "AXScrollBar reads the same value; a scroll position change was expected."
            matches = diff?.changed.first { $0.role == "AXScrollBar" }.flatMap { row in
                row.beforeValue.flatMap { before in row.afterValue.map { $0 != before } }
            }
        case .pointer:
            readback = "The system pointer is inside the target's freshly observed bounds."
            mismatch = "The system pointer is outside the target's freshly observed bounds."
            matches = pointerOnTarget
        }
        return ActClassification(
            status: matches.map { $0 ? "acted" : "acted_mismatch" } ?? "acted_unobserved",
            reason: matches.map { $0 ? nil : "effect_mismatch" } ?? "effect_unreadable",
            note: matches.map { $0 ? readback : mismatch }
                ?? "The input went out, but the declared effect could not be read back."
        )
    }

    // MARK: - Open-target resolution (Agent acceptance round 4, finding 1a)

    private static func receiptText(_ raw: String?, redacted: JSONValue? = nil) -> String? {
        guard let raw else { return nil }
        let value = redacted ?? MacScreenViewTextRedaction.redactedLegendString(
            raw, valueChars: MacAXLimits.hardValueChars
        )
        if case .string(let text) = value { return text }
        return "[redacted]"
    }

    /// Roles that are a legitimate CLICK target when the handle itself will not
    /// open. A Finder list ROW is the thing that opens.
    ///
    /// `AXCell` is deliberately NOT here. Finder's shape is
    /// `AXRow > AXCell > AXStaticText` (see `MacPerceptionCompiler`'s own note),
    /// and double-clicking the filename CELL is the RENAME gesture — the exact
    /// bug this resolution exists to fix. A cell is climbed THROUGH, never
    /// stopped at; it can still win a hop by advertising `AXOpen`, which is a
    /// semantic call and not a click.
    public static let openableAncestorRoles: Set<String> = ["AXRow", "AXOutlineRow"]

    /// Roles the ancestor walk must never climb PAST. Double-clicking the centre
    /// of an `AXOutline`/`AXScrollArea` lands on whichever row happens to sit in
    /// the middle of the container — a different file every time the list
    /// scrolls. Reaching one of these ends the walk with NO candidate, which
    /// falls back to the handle rather than clicking a container.
    /// gpt-5.5 round-5 review: the first list covered Finder list view and
    /// missed the column browser, collection/grid views and web tables, where a
    /// centre double-click selects, previews, or fires an unrelated default
    /// action. This emits REAL input on User's desktop, so the list errs wide —
    /// a role wrongly present costs a fallback, a role wrongly absent costs a
    /// click on something he did not name.
    public static let openWalkStopRoles: Set<String> = [
        "AXOutline", "AXTable", "AXList", "AXScrollArea",
        "AXGroup", "AXSplitGroup", "AXWindow",
        "AXBrowser", "AXCollection", "AXGrid", "AXWebArea",
        "AXTabGroup", "AXToolbar", "AXSheet", "AXDrawer",
    ]

    /// A filename cell is one or two hops under its row. Three is slack, not an
    /// invitation to climb to the window.
    public static let maxOpenWalkHops = 3

    public struct OpenTargetResolution: Sendable, Equatable {
        public let path: [Int]
        public let hops: Int
        public let role: String
        public let advertisesOpen: Bool
        /// Why THIS element: `handle_advertises_open`, `ancestor_advertises_open`,
        /// `nearest_openable_row`, or `no_openable_ancestor`.
        public let reason: String

        public init(path: [Int], hops: Int, role: String, advertisesOpen: Bool, reason: String) {
            self.path = path
            self.hops = hops
            self.role = role
            self.advertisesOpen = advertisesOpen
            self.reason = reason
        }

        /// True when the act will land somewhere other than the handle she named
        /// — which is exactly the thing that must be REPORTED, never silent.
        public var redirected: Bool { hops > 0 }

        public func toJSON() -> JSONValue {
            .object([
                "role": .string(role),
                "hops": .int(Int64(hops)),
                "path": .array(path.map { .int(Int64($0)) }),
                "reason": .string(reason),
                "redirected": .bool(redirected),
                "advertises_open": .bool(advertisesOpen),
            ])
        }
    }

    /// WHICH element an `open` should act on.
    ///
    /// Agent round 4, live: the handle was the filename `AXTextField` — a CELL.
    /// `AXOpen` was refused on it and the CGEvent double-click fallback landed on
    /// the text, which is Finder's RENAME gesture. The event was delivered, the
    /// folder never opened, and no amount of OUTCOME classification can fix a
    /// verb aimed at the wrong ELEMENT. 1(b) made the report honest; this is the
    /// half that makes the act work.
    ///
    /// A FALLBACK, called only after the handle's own `AXOpen` has been TRIED
    /// and did not perform. That ordering is the whole fix, and an earlier
    /// version of it got this wrong: her cell DID advertise `AXOpen`
    /// (`fallback_reason=ax_action_refused` proves the call was made and
    /// declined), so a redirect gated on "the handle does not advertise AXOpen"
    /// never fires for the very case it was written for. ADVERTISING IS NOT
    /// DOING; only the refusal is evidence.
    ///
    /// `probe` resolves a child-index path to `(role, actions)`. Production
    /// passes the SAME window-anchored resolve the act itself uses, so the walk
    /// inherits the pid and window guards instead of opening a second, weaker
    /// resolution path into whatever is frontmost.
    /// TWO candidates, because the two mechanisms have different safety rules.
    ///
    /// gpt-5.5 round-5 review, second pass: collapsing them into one target
    /// reopened the original bug by a new route. An `AXCell` that ADVERTISES
    /// `AXOpen` won the walk as a semantic candidate; when its `AXOpen` then
    /// refused — which is exactly what Agent's cell did — the call site
    /// double-clicked THAT CELL, which is the rename gesture again.
    ///
    /// So: `semantic` may be any role, because `AXUIElementPerformAction` does
    /// what the app says it does and cannot land somewhere else. `click` is
    /// ROWS ONLY, because a synthesized double-click is a position on screen and
    /// the only thing we are willing to aim one at is a content row.
    public struct OpenTargetPlan: Sendable, Equatable {
        public let semantic: OpenTargetResolution?
        public let click: OpenTargetResolution?

        public init(semantic: OpenTargetResolution?, click: OpenTargetResolution?) {
            self.semantic = semantic
            self.click = click
        }
    }

    /// A FALLBACK, called only after the handle's own `AXOpen` has been TRIED
    /// and did not perform. That ordering is the whole fix, and an earlier
    /// version of it got this wrong: her cell DID advertise `AXOpen`
    /// (`fallback_reason=ax_action_refused` proves the call was made and
    /// declined), so a redirect gated on "the handle does not advertise AXOpen"
    /// never fires for the very case it was written for. ADVERTISING IS NOT
    /// DOING; only the refusal is evidence.
    ///
    /// `probe` resolves a child-index path to `(role, actions)`. Production
    /// passes the SAME window-anchored resolve the act itself uses, so the walk
    /// inherits the pid and window guards instead of opening a second, weaker
    /// resolution path into whatever is frontmost.
    public static func planOpenFallback(
        path: [Int],
        probe: ([Int]) -> (role: String, actions: [String])?
    ) -> OpenTargetPlan {
        guard maxOpenWalkHops > 0 else { return OpenTargetPlan(semantic: nil, click: nil) }
        var semantic: OpenTargetResolution?
        var click: OpenTargetResolution?
        for hop in 1...maxOpenWalkHops {
            guard path.count > hop else { break }
            let ancestorPath = Array(path.dropLast(hop))
            guard !ancestorPath.isEmpty, let hit = probe(ancestorPath) else { break }
            if semantic == nil, hit.actions.contains("AXOpen") {
                semantic = OpenTargetResolution(
                    path: ancestorPath, hops: hop, role: hit.role,
                    advertisesOpen: true, reason: "ancestor_advertises_open"
                )
            }
            // STOP-ROLE CHECK: a container never becomes a click target just
            // because the walk reached it. The walk ends here — past a
            // container, child indexes address a different kind of thing.
            if openWalkStopRoles.contains(hit.role) { break }
            if click == nil, openableAncestorRoles.contains(hit.role) {
                click = OpenTargetResolution(
                    path: ancestorPath, hops: hop, role: hit.role,
                    advertisesOpen: hit.actions.contains("AXOpen"),
                    reason: "nearest_openable_row"
                )
            }
        }
        return OpenTargetPlan(semantic: semantic, click: click)
    }

    /// Diff the BEFORE frame (what she looked at and named handles from)
    /// against the AFTER percept (compiled from the same window, post-act).
    ///
    /// Keyed by HANDLE, because that is the identity she holds. A handle whose
    /// fingerprint changed (an app retitling C → AC) shows up as one removal
    /// and one addition, which is the truth: the control was renamed, and the
    /// old handle no longer addresses it.
    /// Were the BEFORE frame's compile and the AFTER compile allowed to see the
    /// same window? Anything less than "both walks complete, both under the same
    /// caps" makes the added/removed census churn rather than evidence.
    ///
    /// An UNRECORDED cap (a frame from before this record existed) is unknown,
    /// not different: incomparability is asserted only from evidence.
    public static func comparability(
        before: MacLookCompileCaps?,
        after: MacLookCompileCaps?
    ) -> (comparable: Bool, reason: String?) {
        if before?.truncated == true, after?.truncated == true {
            return (false, "both the look's walk and the post-action walk truncated")
        }
        if before?.truncated == true { return (false, "the look's walk truncated") }
        if after?.truncated == true { return (false, "the post-action walk truncated") }
        guard let before, let after else { return (true, nil) }
        func mismatch(_ name: String, _ lhs: Int?, _ rhs: Int?) -> String? {
            guard let lhs, let rhs, lhs != rhs else { return nil }
            return "\(name) was \(lhs) for the look and \(rhs) for the post-action compile"
        }
        let reasons = [
            mismatch("max_affordances", before.maxAffordances, after.maxAffordances),
            mismatch("max_nodes", before.maxNodes, after.maxNodes),
            mismatch("max_depth", before.maxDepth, after.maxDepth),
        ].compactMap { $0 }
        guard reasons.isEmpty else { return (false, reasons.joined(separator: "; ")) }
        return (true, nil)
    }

    public static func diff(
        before: MacLookFrame,
        after: MacLookPercept,
        afterWindowTitle: String?,
        afterCaps: MacLookCompileCaps? = nil
    ) -> EffectDiff {
        var afterByHandle: [String: MacLookAffordance] = [:]
        for affordance in after.affordances where !affordance.handle.isEmpty {
            if afterByHandle[affordance.handle] == nil { afterByHandle[affordance.handle] = affordance }
        }
        let beforeEntries = before.entries

        var added: [MacLookAffordance] = []
        var removed: [MacLookFrameEntry] = []
        var changed: [ChangedAffordance] = []

        for affordance in after.affordances where !affordance.handle.isEmpty {
            guard let was = beforeEntries[affordance.handle] else {
                added.append(affordance)
                continue
            }
            let beforeLabel = normalizedLabel(was.label)
            let afterLabel = normalizedLabel(affordance.label)
            let beforeValue = normalizedLabel(was.value)
            let afterValue = normalizedLabel(affordance.value)
            guard beforeLabel != afterLabel
                || beforeValue != afterValue
                || was.enabled != affordance.enabled else { continue }
            changed.append(ChangedAffordance(
                handle: affordance.handle,
                role: affordance.role,
                beforeLabel: beforeLabel,
                afterLabel: afterLabel,
                beforeValue: beforeValue,
                afterValue: afterValue,
                beforeEnabled: was.enabled,
                afterEnabled: affordance.enabled,
                beforeLabelJSON: was.labelJSON,
                afterLabelJSON: affordance.labelJSON,
                beforeValueJSON: was.valueJSON,
                afterValueJSON: affordance.valueJSON
            ))
        }
        for (handle, entry) in beforeEntries where afterByHandle[handle] == nil {
            removed.append(entry)
        }
        // Deterministic order, so a diff is comparable across calls and a test
        // is not asserting on dictionary iteration order.
        removed.sort { MacPerceptionCompiler.pathIsBefore($0.path, $1.path) }
        changed.sort { $0.handle < $1.handle }

        let focusBefore = before.focusHandle
        let focusAfter = after.focus?.handle
        let focusChanged = focusBefore != focusAfter
            || (focusAfter == nil && before.focusHandle != nil)

        let modalAfterLabel = normalizedLabel(after.modal?.label)
        let hadModal = before.hasModal
        let hasModal = after.modal != nil

        let titleBefore = normalizedLabel(before.windowTitle)
        let titleAfter = normalizedLabel(afterWindowTitle)

        // finding A — the readout diff, keyed by handle when there is one and
        // by path otherwise. This is what makes act{Equals} answer "390".
        var readoutsChanged: [ReadoutChange] = []
        var readoutsAdded: [ReadoutRow] = []
        let beforeReadouts = before.readouts
        var afterReadoutKeys = Set<String>()
        for readout in after.readouts {
            let key = MacLookReadoutRecord.key(handle: readout.handle, path: readout.path)
            guard afterReadoutKeys.insert(key).inserted else { continue }
            guard let was = beforeReadouts[key] else {
                readoutsAdded.append(ReadoutRow(
                    handle: readout.handle,
                    path: readout.path,
                    role: readout.role,
                    text: normalizedLabel(readout.text),
                    textJSON: readout.textJSON
                ))
                continue
            }
            let beforeText = normalizedLabel(was.text)
            let afterText = normalizedLabel(readout.text)
            guard beforeText != afterText else { continue }
            readoutsChanged.append(ReadoutChange(
                handle: readout.handle,
                path: readout.path,
                role: readout.role,
                beforeText: beforeText,
                afterText: afterText,
                // B3 — each side keeps the verdict of the compile it came
                // from: the frame's record for BEFORE, the post-act percept's
                // own redaction for AFTER. Neither is re-judged here, where
                // there is no snapshot to judge against.
                beforeJSON: was.textJSON,
                afterJSON: readout.textJSON
            ))
        }
        var readoutsRemoved = beforeReadouts.values
            .filter { !afterReadoutKeys.contains($0.key) }
            // B3/C2 — a removed readout carries the frame record's OWN compile
            // verdict (textJSON), never a context-free re-render: a "123" under
            // a "CVV" group withheld everywhere else must not surface here the
            // moment it leaves the screen.
            .map { ReadoutRow(handle: $0.handle, path: $0.path, role: $0.role, text: normalizedLabel($0.text), textJSON: $0.textJSON) }
            .sorted { MacPerceptionCompiler.pathIsBefore($0.path, $1.path) }

        // PAIR THE RENAMES (round 2). An added readout and a removed readout at
        // the SAME path with the SAME role are one control whose key moved:
        // Calculator retitles its display when it shows a result, the handle
        // fingerprint includes the title, so the readout key changes and "42"
        // came back as a bare `added_total: 2 / removed_total: 1`. Paired here
        // into ONE changed row carrying both texts, with the totals decremented
        // so the census still adds up.
        var pairedAdded: [ReadoutRow] = []
        var unpairedRemoved = readoutsRemoved
        for row in readoutsAdded {
            guard let index = unpairedRemoved.firstIndex(where: {
                $0.path == row.path && $0.role == row.role
            }) else {
                pairedAdded.append(row)
                continue
            }
            let was = unpairedRemoved.remove(at: index)
            readoutsChanged.append(ReadoutChange(
                handle: row.handle,
                path: row.path,
                role: row.role,
                beforeText: was.text,
                afterText: row.text,
                // B3/C2 — the paired rename carries each side's compile verdict,
                // like the non-renamed changed rows above. Without this the one
                // channel Calculator's Equals actually travels ("42" arrives as
                // a rename) would be the one that ships a secret in the clear.
                beforeJSON: was.textJSON,
                afterJSON: row.textJSON,
                renamed: true
            ))
        }
        readoutsAdded = pairedAdded
        readoutsRemoved = unpairedRemoved
        readoutsChanged.sort { MacPerceptionCompiler.pathIsBefore($0.path, $1.path) }

        readoutsAdded.sort { MacPerceptionCompiler.pathIsBefore($0.path, $1.path) }

        var addedByRole: [String: Int] = [:]
        for affordance in added { addedByRole[affordance.role, default: 0] += 1 }
        var removedByRole: [String: Int] = [:]
        for entry in removed { removedByRole[entry.role, default: 0] += 1 }

        let comparable = comparability(before: before.caps, after: afterCaps)

        return EffectDiff(
            added: Array(added.prefix(maxDiffRows)),
            removed: Array(removed.prefix(maxDiffRows)),
            changed: Array(changed.prefix(maxDiffRows)),
            addedByRole: addedByRole,
            removedByRole: removedByRole,
            addedTotal: added.count,
            removedTotal: removed.count,
            changedTotal: changed.count,
            focusChanged: focusChanged,
            focusHandleAfter: focusAfter,
            focusLabelAfter: normalizedLabel(after.focus?.label),
            focusLabelJSONAfter: after.focus?.labelJSON,
            focusRoleAfter: after.focus?.role,
            modalAppeared: hasModal && !hadModal,
            modalDisappeared: !hasModal && hadModal,
            modalLabelAfter: modalAfterLabel,
            windowTitleChanged: titleBefore != titleAfter,
            windowTitleAfter: titleAfter,
            readoutsChanged: Array(readoutsChanged.prefix(maxDiffRows)),
            readoutsChangedTotal: readoutsChanged.count,
            readoutsAddedTotal: readoutsAdded.count,
            readoutsRemovedTotal: readoutsRemoved.count,
            readoutsAdded: Array(readoutsAdded.prefix(maxDiffRows)),
            readoutsRemoved: Array(readoutsRemoved.prefix(maxDiffRows)),
            diffComparable: comparable.comparable,
            diffIncomparableReason: comparable.reason
        )
    }

    // MARK: dismiss target selection

    /// The button inside the CURRENT frame's modal that closes it.
    ///
    /// Scoped by PATH PREFIX to the modal, not searched window-wide: a window
    /// behind a sheet often has its own "Close", and pressing that instead of
    /// the sheet's would act on the wrong surface entirely.
    public static func dismissTarget(
        in frame: MacLookFrame
    ) -> MacLookFrameEntry? {
        guard let modalPath = frame.modalPath else { return nil }
        let candidates = frame.entries.values.filter { entry in
            entry.path.count > modalPath.count
                && Array(entry.path.prefix(modalPath.count)) == modalPath
        }
        for label in dismissLabels {
            let matches = candidates.filter {
                normalizedLabel($0.label)?.lowercased() == label
            }
            if let best = matches.min(by: { MacPerceptionCompiler.pathIsBefore($0.path, $1.path) }) {
                return best
            }
        }
        return nil
    }
}

// MARK: - The live observer

#if canImport(ApplicationServices) && os(macOS)

/// Box carried through the AX callback's `refcon`. Retained for the lifetime of
/// the registration and released exactly once by `stop()`.
private final class MacAXEffectObserverBox {
    let onNotification: @Sendable (MacAXEffectNotification) -> Void
    init(onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void) {
        self.onNotification = onNotification
    }
}

private final class SystemMacAXEffectObservation: MacAXEffectObservation, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let observer: AXObserver
    private let element: AXUIElement
    private let kinds: [String]
    private let refcon: UnsafeMutableRawPointer

    init(observer: AXObserver, element: AXUIElement, kinds: [String], refcon: UnsafeMutableRawPointer) {
        self.observer = observer
        self.element = element
        self.kinds = kinds
        self.refcon = refcon
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        // Same execution lane every other AX transaction in this module uses:
        // AX calls can synchronously enter the TARGET app's main-thread-isolated
        // handlers, and removing a notification is an AX call like any other.
        MacAXExecutionLane.sync {
            for kind in kinds {
                AXObserverRemoveNotification(observer, element, kind as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).release()
    }
}

/// The real `AXObserver`, sourced on the MAIN run loop (which is where the AX
/// framework delivers) and created/removed on `MacAXExecutionLane`.
public struct SystemMacAXEffectObserverSource: MacAXEffectObserverSource {
    public init() {}

    public func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)? {
        MacAXExecutionLane.sync {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, notification, refcon in
                guard let refcon else { return }
                let box = Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).takeUnretainedValue()
                box.onNotification(MacAXEffectNotification(kind: notification as String, at: Date()))
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
                return nil
            }
            let box = MacAXEffectObserverBox(onNotification: onNotification)
            let refcon = Unmanaged.passRetained(box).toOpaque()
            let element = AXUIElementCreateApplication(pid)
            var subscribed: [String] = []
            for kind in kinds {
                if AXObserverAddNotification(observer, element, kind as CFString, refcon) == .success {
                    subscribed.append(kind)
                }
            }
            // Not one kind subscribed: there is nothing to remove and nothing
            // to hear. Report the failure by returning nil rather than handing
            // back a registration that can never fire.
            guard !subscribed.isEmpty else {
                Unmanaged<MacAXEffectObserverBox>.fromOpaque(refcon).release()
                return nil
            }
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            return SystemMacAXEffectObservation(
                observer: observer,
                element: element,
                kinds: subscribed,
                refcon: refcon
            )
        }
    }
}

#endif

/// Honest unavailability: installs nothing and says so by returning nil, so the
/// act reports `observed: false, reason: "observer_unavailable"` instead of
/// silently claiming the app produced no effect.
public struct UnavailableMacAXEffectObserverSource: MacAXEffectObserverSource {
    public init() {}
    public func install(
        pid: Int32,
        kinds: [String],
        onNotification: @escaping @Sendable (MacAXEffectNotification) -> Void
    ) -> (any MacAXEffectObservation)? { nil }
}

public func defaultMacAXEffectObserverSource() -> any MacAXEffectObserverSource {
    #if canImport(ApplicationServices) && os(macOS)
    return SystemMacAXEffectObserverSource()
    #else
    return UnavailableMacAXEffectObserverSource()
    #endif
}
