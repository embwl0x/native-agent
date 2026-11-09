import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(ApplicationServices)
import ApplicationServices
#endif

// Blueprint: | `MacActClosedLoop.swift` | Closed-loop grammar, live identity, geometry guards, declared effects and bounded waits |

// Verify effects with the same read organ after observation settles so action receipts and perception share evidence.

// MARK: - One read epoch

/// Keep tree, focus, window and root in one read epoch so page descent and action identity checks share an anchor.
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

public enum MacLookScope: String, Sendable, Equatable, CaseIterable {
    /// Prefer page scope so browser chrome cannot consume the page's walk budget.
    case page
    case chrome
    /// Whole-window scope shares one budget between page and chrome.
    case both

    public static func parse(_ raw: String?) -> MacLookScope? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .page }
        return MacLookScope(rawValue: raw)
    }
}

// MARK: - Verbs

/// A closed verb vocabulary lets the model name intent while this owner chooses the mechanism.
public enum MacActVerb: String, Sendable, Equatable, CaseIterable {
    case click
    case doubleClick = "double_click"
    case rightClick = "right_click"
    case hover
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
    public static let notificationKinds: [String] = [
        "AXValueChanged",
        "AXSelectedTextChanged",
        "AXMainWindowChanged",
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

    public static let defaultWaitMs = 300
    /// Bound waits so an unresponsive UI returns none_observed instead of hanging the turn.
    public static let maxWaitMs = 2000
    public static let maxDiffRows = 10

    /// Refuse non-editable targets rather than activating them through a typing approximation.
    public static let typeableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        "AXSecureTextField",
    ]

    public static func canType(role: String) -> Bool { typeableRoles.contains(role) }

    // MARK: - Secure keyboard entry

    /// Secure-input refusals retain both a machine-readable reason and an actionable sentence.
    public struct SecureInputRefusal: Equatable, Sendable {
        public let reason: String
        public let note: String
        public init(reason: String, note: String) {
            self.reason = reason
            self.note = note
        }
    }

    /// Keep secure fields in typeableRoles so password targets receive a specific credential refusal rather than a generic unsupported-verb answer.
    public static let secureFieldRoles: Set<String> = ["AXSecureTextField"]

    public static func isSecureField(role: String) -> Bool {
        secureFieldRoles.contains(role)
    }

    public static let secureFieldReason = "secure_field_target"
    public static let secureInputReason = "secure_input_active"

    /// Credential entry belongs to the person even when AXSetValue could technically write the field.
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
            note: """
                Secure keyboard entry blocks synthetic typing; nothing was posted. Dismiss or unfocus its source, often a password field, Terminal sudo \
                prompt or password manager, before continuing.
                """
        )
    }

    /// Try modal dismiss labels from least destructive to most so a sheet offering Cancel and OK is cancelled.
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

    /// Nil permits input only after app admission. A source with no focused-window evidence cannot alone establish a window match or mismatch.
    public static func keyWindowRefusal(
        framePid: Int32,
        frontmostPid: Int32?,
        frontmostName: String?,
        /// Compare concrete window handles for key ownership; descriptive identity matching tolerates retitles and its sole-candidate rule cannot prove which
        /// window is focused.
        frameWindowHandle: Int?,
        focusedWindowHandle: Int?,
        frameWindowTitle: String?,
        focusedWindowTitle: String?,
        /// When focus is unknown, a known single-window app has no window ambiguity; multiple windows prove nothing. Nil leaves the source's window count
        /// unknown.
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
        // Right app, wrong window of it. Asserted ONLY when both handles are known: a source that cannot name its focused window has told us nothing, and
        // silence is not a mismatch.
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

    /// Handles are references, not leases: rebuilt child paths can point at another control. Recheck live identity before acting.
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
        // Compare labels only when the frame recorded one, using the compiler's title/value identity ordering so popup state stays comparable.
        guard let expectedLabel = normalizedLabel(expectedLabel) else { return nil }
        let live = normalizedLabel(liveTitle) ?? normalizedLabel(liveValue)
        guard let live else { return "label" }
        return live == expectedLabel ? nil : "label"
    }

    /// Two points tolerate layout rounding while remaining below a real row height.
    public static let positionalDriftTolerancePoints: Double = 2

    public struct IdentityDrift: Sendable, Equatable {
        public let on: String
        public let found: JSONValue
    }

    /// Resolve the recorded rendered identity on the live screen. Positional identities still require their original cohort and geometry below.
    public static func liveIdentity(
        entry: MacLookFrameEntry,
        percept: MacLookPercept
    ) -> MacLookAffordance? {
        if let affordance = percept.affordances.first(where: { $0.handle == entry.handle }) {
            return affordance
        }
        guard let focus = percept.focus, focus.handle == entry.handle, let handle = focus.handle else {
            return nil
        }
        // Focus-derived entries use the same rendered handle, role and contextual redaction as the frame. They have no rect and cannot enter positional
        // matching.
        return MacLookAffordance(
            handle: handle,
            role: focus.role,
            label: focus.label ?? "",
            labelSource: "focus",
            path: focus.path,
            labelJSON: focus.labelJSON
        )
    }

    /// An identity not found in this observation cannot authorize an act; an incomplete/unreadable observation does not prove removal.
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
                    "note": .string("the recorded control identity could not be confirmed in the live observation"),
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

        public init(
            observed: Bool,
            firstNotificationMs: Int?,
            notifications: [String],
            notificationCount: Int
        ) {
            self.observed = observed
            self.firstNotificationMs = firstNotificationMs
            self.notifications = notifications
            self.notificationCount = notificationCount
        }
    }

    /// Navigation waits for structural transition or deadline; early selection and element destruction alone do not prove it.
    public static let navigationNotificationKinds: Set<String> = [
        // Finder retitles its window to the opened folder, providing a navigation signal.
        "AXTitleChanged",
        "AXFocusedWindowChanged",
        "AXWindowCreated",
        // A new sheet supplies the modal transition counted by navigated.
        "AXSheetCreated",
    ]

    /// Navigation gets a larger default than immediate value changes because folder loads take longer; the deadline still ends early on a transition.
    public static let navigationWaitMs = 1500

    static func effectWait(collector: MacAXEffectCollector, startedAt: Date) -> EffectWait {
        EffectWait(observed: collector.count() > 0,
            firstNotificationMs: collector.first().map { max(0, Int($0.at.timeIntervalSince(startedAt) * 1000)) },
            notifications: collector.kinds(), notificationCount: collector.count())
    }

    // MARK: - The Open command

    /// Finder retitles to the destination folder, permitting direct label/title comparison. Nil means uncheckable; only structural evidence can then establish
    /// arrival.
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
        public let reason: String?
        public let note: String?
        /// A press verified by a settled readout alone: enough to tell the agent it worked, never enough to teach or clear a press route.
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

    /// The act declares its effect before input. All routes use this judge; pixels and notification counts alone cannot satisfy a declaration.
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
        value: @autoclosure () -> String? = nil, valueBefore: String? = nil,
        selection: @autoclosure () -> NSRange? = nil,
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
            // Canonical field masking makes the complete text unavailable, including short masked values and fields with no secure subrole.
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
                // The field was read. Only a field that moved off its pre-typing value took the input (an app that capitalizes or curls quotes changed it);
                // unknown or unchanged is not evidence that anything landed.
                let quoted = """
                    typed \"\(excerpt(expected))\", it reads \"\(excerpt(value))\" (from UTF-16 offset \(offset); typed length \(expected.utf16.count), read \
                    length \(value.utf16.count))
                    """
                guard let valueBefore, value != valueBefore else {
                    return ActClassification(status: "acted_unobserved",
                        reason: valueBefore == nil ? "text_differs" : "text_unchanged",
                        note: valueBefore == nil
                            ? "The field reads differently from what was typed: \(quoted). Whether the input landed is unknown."
                            : "The field still reads what it read before typing: \(quoted). The input did not show up there.")
                }
                return ActClassification(status: "acted_changed", reason: "text_changed",
                    note: "The field took the input and now reads differently: \(quoted). Read what it says before typing again.")
            }
        case .placement(let placement, let directory):
            let wanted = URL(fileURLWithPath: placement.directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let actual = directory.flatMap(URL.init(string:))
            guard actual?.isFileURL == true, actual?.standardizedFileURL.resolvingSymlinksInPath() == wanted else {
                return ActClassification(status: directory == nil ? "acted_unobserved" : "acted_mismatch",
                    reason: "save_panel_placement_unverified", note: """
                        Directory URL reads \(receiptText(directory) ?? "unavailable"); expected \(receiptText(wanted.absoluteString) ?? "").
                        """)
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
            // Notifications wake the read; only the owning process's window inventory or its modal readback establishes the declared effect. Confirmed creation
            // satisfies the declaration even when the pressed control's subtree in the existing surface is unchanged.
            if surfaceChanged == true {
                matches = true
            } else if let press, let diff {
                let evidence = pressEvidence(diff, before: press.before, pressed: press.target,
                                             settled: press.settled)
                readoutOnly = evidence.readoutOnly
                // An unrelated change leaves the result uncertain, even with a complete census. It earns no route-learning evidence.
                matches = evidence.consequence ? true : nil
            } else if processGone || dismissed == true || diff?.modalDisappeared == true
                || diff?.modalAppeared == true {
                matches = true
            } else if let diff {
                if diff.windowTitleChanged, let destination,
                   destinationMatchesIntent(title: diff.windowTitleAfter, intendedTarget: destination) == false {
                    return ActClassification(status: "acted_mismatch", reason: "destination_mismatch",
                        note: """
                            The window reads \"\(receiptText(diff.windowTitleAfter, redacted: windowTitleJSON) ?? "")\"; expected destination \
                            \"\(receiptText(destination, redacted: destinationJSON) ?? "")\".
                            """)
                }
                // Without press evidence an unchanged surface cannot tell an ignored press from one that changed nothing (All Clear on a clear calculator):
                // that is unobserved, never a mismatch. Only a contradiction (the destination above) is a mismatch.
                matches = diff.navigated ? true : nil
                if !diff.navigated, diff.diffComparable {
                    unobserved = """
                        The press went out; the target's accessibility surface reads the same, which cannot tell an ignored press from one that changed \
                        nothing.
                        """
                }
            } else { matches = surfaceChanged }
        case .dismissed:
            let dismissed = dismissed(), processGone = processGone()
            readback = "The target window or modal is no longer present in its process."
            mismatch = "The target window or modal is still present; dismissal was expected."
            matches = processGone || dismissed == true || diff?.modalDisappeared == true
                ? true : dismissed
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

    /// Compare handles across pre/post frames. A changed fingerprint is a removal and addition because the renamed control no longer has the captured identity.
    // MARK: dismiss target selection

    /// Scope dismiss buttons to the current modal's path prefix; a Close button in the window behind must never receive the dismissal.
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
