import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(ApplicationServices)
import ApplicationServices
#endif

// Blueprint: | `MacActClosedLoop.swift` | `MacActClosedLoop.verify` owns the declared-effect verdict for semantic, menu and physical act receipts: exact complete AXValue, selection range, selected/state/focus, owned window/sheet creation, confirmed removal or process exit and AX surface transitions; pixels are witnesses only; readable mismatches are `acted_mismatch`, unavailable readback (including canonically masked text values) is `acted_unobserved`; an unchanged surface without press evidence is unobserved, never a mismatch (only a contradicted destination is) |

// Actions use the existing actuator and event sink; effect verification
// compiles the same read organ after the observation settles.


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
    /// Window identity outlives source handles; nil means the source could not identify the observed window.
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

/// The surface a semantic look observes.
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
    /// Open through advertised AXOpen or the same guarded double-click path used by click.
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
    /// Subscribed effect kinds cover value, focus, window/sheet, title/layout, menu, selection/row-count and live-region changes.
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

    /// Default wait for the first notification.
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

    /// Refuse non-editable targets rather than activating them through a typing approximation.
    public static let typeableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        "AXSecureTextField",
    ]

    /// Whether `type` has any business on this element.
    public static func canType(role: String) -> Bool { typeableRoles.contains(role) }

    // MARK: - Secure keyboard entry

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

    /// Name why this act's mechanism requires the target window in front.
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

    // MARK: - The key-window gate

    /// Synthesized input targets the key window independently of AX anchors; unknown foreground ownership refuses.
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
        // Unknown focus refuses when multiple windows could receive input; a single-window app has no window ambiguity.
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

    /// Which identity component moved, and what is there now.
    public struct IdentityDrift: Sendable, Equatable {
        public let on: String
        public let found: JSONValue
    }

    /// Recompile through the same walker and compare rendered identity, ordinal cohort and geometry; focus-only entries resolve through the live focus at the same path.
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
        // Compare ordinal cohort size as well as label and geometry; removing an identical sibling can otherwise retarget the same handle.
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

    /// Navigation waits for a subscribed structural-transition notification or its deadline, not an early selection change; element destruction alone does not prove navigation.
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
        /// Wait for one of these kinds or the deadline; empty accepts any notification.
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

    // MARK: - The Open command

    /// Use only measured Open chords, keyed by bundle ID; display names and assumed app shortcuts cannot authorize input.
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
        // Navigation labels match exactly; a substring such as Doc in Documents cannot prove the destination.
        return got == want
    }

    // MARK: - Act status classification

    /// Navigation verbs require a surface transition; notifications alone show reaction. Dismissal uses its separate modal/removal evidence.
    public static let navigationVerbs: Set<MacActVerb> = [.open]

    public struct ActClassification: Sendable, Equatable {
        public let status: String
        /// A machine-readable code, `nil` on a clean `acted`.
        public let reason: String?
        /// The same verdict in a sentence the caller can act on.
        public let note: String?
        /// A press verified by a settled readout alone: enough to tell her it
        /// worked, never enough to teach or clear a press route.
        public let readoutOnly: Bool
        static let readoutOnlyScope = "readout_only"

        public init(status: String, reason: String? = nil, note: String? = nil, readoutOnly: Bool = false) {
            self.status = status
            self.reason = reason
            self.note = note
            self.readoutOnly = readoutOnly
        }

        /// Consumers carry this verdict alongside the independent operation state.
        var receipt: [String: JSONValue] {
            ["status": .string(status), "verified": .bool(status == "acted"),
             "verification": .string((status == "acted" ? MotorVerificationState.satisfied
                : status == "acted_mismatch" ? .failed : .unverified).rawValue),
             "status_reason": reason.map(JSONValue.string) ?? .null,
             "status_note": note.map(JSONValue.string) ?? .null,
             "verification_evidence": status == "acted" ? note.map(JSONValue.string) ?? .null : .null,
             "verification_scope": .string(readoutOnly ? Self.readoutOnlyScope : "declared_effect")]
        }
    }

    /// The act declares its effect before input. All routes use this judge;
    /// pixels and notification counts alone cannot satisfy a declaration.
    enum DeclaredEffect {
        case text(String?)
        case placement(MacSavePanelPlacement, String?)
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
        value: @autoclosure () -> String? = nil, selection: @autoclosure () -> NSRange? = nil,
        selected: Bool? = nil, focused: @autoclosure () -> Bool? = nil,
        surfaceChanged: @autoclosure () -> Bool? = nil, dismissed: @autoclosure () -> Bool? = nil,
        processGone: @autoclosure () -> Bool = false,
        diff: EffectDiff? = nil, notifications: [String] = [],
        pointerOnTarget: Bool? = nil, redactingText: Bool = false,
        press: (before: MacLookFrame, target: MacLookFrameEntry, settled: (ReadoutChange) -> Bool)? = nil,
        destinationJSON: JSONValue? = nil, windowTitleJSON: JSONValue? = nil
    ) -> ActClassification {
        let matches: Bool?
        let readback: String
        var readoutOnly = false
        var mismatch = "The declared effect differs from the target's accessibility state."
        var unobserved = "The input went out, but the declared effect could not be read back."
        switch effect {
        case .text(let expected):
            readback = "The complete AXValue matches the declared edit."
            // Canonical field masking makes the complete text unavailable,
            // including short masked values and fields with no secure subrole.
            guard let expected, let value = value(),
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
        case .placement(let placement, let directory):
            guard directory == placement.directoryName else {
                return ActClassification(status: directory == nil ? "acted_unobserved" : "acted_mismatch",
                    reason: "save_panel_placement_unverified", note: "Where popup reads \(receiptText(directory) ?? "unknown"); expected \(receiptText(placement.directoryName) ?? "").")
            }
            return verify(.text(placement.name), value: value(), redactingText: redactingText)
        case .selectAll:
            let value = value(), selection = selection()
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
            let value = value()
            readback = "The target's AXValue matches the declared state."
            matches = expected.flatMap { expected in value.map { $0 == expected } }
            if matches == false, let expected, let value {
                return ActClassification(status: "acted_mismatch", reason: "state_mismatch",
                    note: "AXValue reads \"\(receiptText(value) ?? "")\"; expected \"\(receiptText(expected) ?? "")\".")
            }
        case .focus:
            readback = "The target owns accessibility focus in its process and window."
            mismatch = "The target does not own accessibility focus in its process and window."
            matches = focused()
        case .surface(let destination):
            let surfaceChanged = surfaceChanged(), dismissed = dismissed(), processGone = processGone()
            let windowCreated = notifications.contains("AXWindowCreated")
            let sheetCreated = notifications.contains("AXSheetCreated")
            readback = sheetCreated && surfaceChanged == true ? "A sheet opened in the target app."
                : windowCreated && surfaceChanged == true ? "A window opened in the target app."
                : surfaceChanged == true ? "A new window or sheet opened in the target app."
                : press != nil ? "The pressed control's own accessibility content changed."
                : processGone ? "The target app is no longer running."
                : dismissed == true || diff?.modalDisappeared == true
                    ? "The target window or modal is no longer present in its process."
                : diff?.modalAppeared == true ? "A modal appeared in the target app."
                : "The target's accessibility surface changed."
            mismatch = "The target's AX surface is unchanged; a surface transition was expected."
            // Notifications wake the read; only the owning process's window
            // inventory or its modal readback establishes the declared effect.
            // Confirmed creation satisfies the declaration even when the
            // pressed control's subtree in the existing surface is unchanged.
            if surfaceChanged == true {
                matches = true
            } else if let press, let diff {
                let evidence = pressEvidence(diff, before: press.before, pressed: press.target,
                                             settled: press.settled)
                readoutOnly = evidence.readoutOnly
                // An unrelated change leaves the result uncertain, even with
                // a complete census. It earns no route-learning evidence.
                matches = evidence.consequence ? true : nil
            } else if processGone || dismissed == true || diff?.modalDisappeared == true
                || diff?.modalAppeared == true {
                matches = true
            } else if let diff {
                if diff.windowTitleChanged, let destination,
                   destinationMatchesIntent(title: diff.windowTitleAfter, intendedTarget: destination) == false {
                    return ActClassification(status: "acted_mismatch", reason: "destination_mismatch",
                        note: "The window reads \"\(receiptText(diff.windowTitleAfter, redacted: windowTitleJSON) ?? "")\"; expected destination \"\(receiptText(destination, redacted: destinationJSON) ?? "")\".")
                }
                // Without press evidence an unchanged surface cannot tell an
                // ignored press from one that changed nothing (All Clear on a
                // clear calculator): that is unobserved, never a mismatch. Only
                // a contradiction (the destination above) is a mismatch.
                matches = diff.navigated ? true : nil
                if !diff.navigated, diff.diffComparable {
                    unobserved = "The press went out; the target's accessibility surface reads the same, which cannot tell an ignored press from one that changed nothing."
                }
            } else { matches = surfaceChanged }
        case .dismissed:
            let dismissed = dismissed(), processGone = processGone()
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
            note: matches.map { $0 ? readback : mismatch } ?? unobserved,
            readoutOnly: readoutOnly
        )
    }

    // MARK: - Open-target resolution

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

    /// Stop ancestor search at containers: their centre can target an unrelated row or default action.
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

    /// Probe only within the validated window; semantic candidates may be any role, while synthetic double-click candidates must be content rows.
    public struct OpenTargetPlan: Sendable, Equatable {
        public let semantic: OpenTargetResolution?
        public let click: OpenTargetResolution?

        public init(semantic: OpenTargetResolution?, click: OpenTargetResolution?) {
            self.semantic = semantic
            self.click = click
        }
    }

    /// Resolve bounded ancestors through the same PID/window-anchored probe as the act; planning emits no input.
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
