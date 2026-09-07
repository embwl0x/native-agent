import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - The PERCEPTION COMPILER (native-look item 2)
//
// NORTHSTAR clause 5: "a feature that leaves the agent translating the human
// world at token cost is unfinished". `mac_ax_tree` hands the model a tree and
// asks it to be the eyes; this file is the app being the eyes instead. It
// consumes the SAME `MacAXTreeSnapshot` the read organ already produces — there
// is deliberately no second walker here — and distills it into three GRADES of
// attention, the way a human's own looking is graded:
//
//   • glance — ONE line (~140 bytes). "Mail — "Inbox" · 23 controls
//     (17 labeled) · focus: AXTextField "Subject" · MODAL: Save draft ·
//     e.g. Send, Cancel, Reply". 100–400× cheaper than a stare.
//   • look   — structured: window, focus, modal, landmarks, and every
//     interactive element with a stable HANDLE. Unnamed controls stay visibly
//     unnamed, but the shared screen model gives each a role ordinal rather
//     than silently making it unaddressable. 10–70× cheaper than a stare
//     (spike, docs/build_plans/native-look.md).
//   • stare  — the existing `mac_ax_tree` payload, unchanged and delegated to.
//
// Measured on User's real apps in item 1 (bytes: stare / look / glance):
// Mail 9,586 / 877 / 140 · Finder 43,861 / 625 / 102 · Hermes (Electron,
// 1,200 nodes) 79,328 / 2,069 / 126.
//
// NOTHING HERE IS RESIDENT. A look is a PULL: the frame it mints is
// tool-layer state with a 180 s TTL and a single slot, and it grants no
// authority whatsoever (same doctrine as `MacScreenViewStore`).
//
// REDACTION is not re-invented: every label/value/title that leaves this file
// rides out through `MacScreenViewTextRedaction` / `MacInjectionResultRedaction`
// — the exact path the `mac_view` legend uses. A perception surface with this
// blast radius (turn trace, persisted tool row, iOS/Telegram sync) must not be
// the weak channel.

// MARK: - Handles

/// The handle scheme the item-1 spike decided on (see "Handle scheme (go)" in
/// docs/build_plans/native-look.md).
///
/// A handle must survive re-layout and scrolling, which a child-index path does
/// not: inserting one row above a button renumbers it. So identity is a
/// FINGERPRINT — what the element IS and what it sits INSIDE — hashed to a
/// short token:
///
///     ancestorChain > role/subrole/label
///     ancestorChain = "AXWindow:Inbox|AXToolbar:|AXGroup:Reply"
///
/// Deliberately EXCLUDED from the fingerprint:
///   • child indices — the thing that makes paths fragile.
///   • VALUES — a text field whose contents change is still the same field.
///     This is why the fingerprint's label component is the element's TITLE
///     only, even when the percept DISPLAYS a value-derived label: a popup
///     button that reads "Medium" then "Large" must keep one handle.
///
/// A retitle (Calculator's C → AC) DOES mint a new handle, and that is correct
/// — the app renamed the control, which is a real change. The `path` travels
/// with every affordance as the resolve fallback for exactly that case.
///
/// Fingerprints are not unique in the wild (spike: 100% unique on Mail/Finder/
/// Notes/Photos, 84% System Settings, 26% Chrome — unlabeled repeated
/// controls). So the rendered handle carries an ORDINAL among same-token
/// elements in document order: the first is `h7k2q1`, the second `h7k2q1.2`.
/// Grouping the ordinal by rendered TOKEN rather than by fingerprint also makes
/// a hash collision between two different fingerprints harmless instead of a
/// silent merge.
public enum MacLookHandle {
    /// Token length in base36. 36^6 ≈ 2.2e9, against ≤60 affordances per frame.
    public static let tokenLength = 6
    /// An ancestor's label contributes at most this many characters.
    public static let ancestorLabelChars = 24

    /// Roles whose identity may be derived from the text they CONTAIN when the
    /// app publishes no title for them (Agent acceptance round 1, finding B).
    ///
    /// Finder's list rows carry no title at all, so every sibling row
    /// fingerprinted identically and came back as `csmai7`, `csmai7.2`,
    /// `csmai7.3` — a DOCUMENT-ORDER ordinal, which is exactly the fragility a
    /// handle exists to remove: insert one row and `.2` silently addresses a
    /// different file. These container roles get a `contentName` component
    /// instead, so "the row containing Downloads" keeps one identity wherever
    /// the list scrolls it to.
    ///
    /// Deliberately CONTAINERS ONLY. Rule 2 above (never values) is unchanged
    /// for everything else: a popup button reading "Medium" then "Large" is a
    /// titled/value-labeled CONTROL, not a container, and must keep one handle.
    ///
    /// `AXGroup` is deliberately ABSENT (Agent acceptance round 2, Calculator):
    /// a generic group is a LAYOUT box, not a content row, and a title-less one
    /// wrapping the display took the DISPLAY TEXT as its identity — so every
    /// button whose ancestor chain ran through it re-fingerprinted on every
    /// keypress ("20 added / 20 removed" for a semantically identical keypad).
    /// The roles below are the content rows this scheme exists for; each one
    /// names a single item a human would point at, and its text is that item's
    /// name rather than a value that changes underneath it.
    public static let contentIdentityRoles: Set<String> = [
        "AXRow", "AXCell", "AXOutlineRow", "AXListItem",
    ]

    /// FNV-1a 64. Chosen over `Hasher` because `Hasher` is per-process SEEDED:
    /// the same tree would hash differently in the next launch, and "the same
    /// tree yields the same handles" is a contract, not a nicety.
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    public static func base36(_ value: UInt64, length: Int) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var remaining = value
        var out: [Character] = []
        for _ in 0..<max(1, length) {
            out.append(digits[Int(remaining % 36)])
            remaining /= 36
        }
        return String(out.reversed())
    }

    /// The fingerprint string, before hashing. Public so a test can pin exactly
    /// what does and does not enter it.
    /// - Parameter contentName: the identity of a TITLE-LESS container, derived
    ///   from the first text it contains (finding B). Appended only when
    ///   present, so a titled element's fingerprint — and therefore its handle —
    ///   is byte-identical to what it was before this component existed.
    public static func fingerprint(
        role: String,
        subrole: String?,
        title: String?,
        ancestors: [(role: String, title: String?)],
        contentName: String? = nil
    ) -> String {
        let chain = ancestors.map { ancestor -> String in
            let label = ancestor.title.map { String($0.prefix(ancestorLabelChars)) } ?? ""
            return "\(ancestor.role):\(label)"
        }.joined(separator: "|")
        let content = title == nil ? (contentName.map { "#\($0)" } ?? "") : ""
        return "\(chain)>\(role)/\(subrole ?? "")/\(title ?? "")\(content)"
    }

    /// The sentence a caller gets when a handle STILL had to fall back to a
    /// document-order ordinal. Announced rather than hidden: an ordinal handle
    /// is position-derived and shifts if the container reorders, which is worse
    /// than `handle_drifted` precisely because it does not announce itself.
    public static func ambiguityNote(ordinal: Int, total: Int) -> String {
        "ordinal:\(ordinal) of \(total) identical elements — position-derived, will shift "
            + "if the container reorders; re-look before acting on it"
    }

    public static func token(fingerprint: String) -> String {
        base36(fnv1a64(fingerprint), length: tokenLength)
    }

    /// `token` for the first element carrying it, `token.2`, `token.3`… for the
    /// rest, in document order.
    public static func rendered(token: String, ordinal: Int) -> String {
        ordinal <= 1 ? token : "\(token).\(ordinal)"
    }
}

// MARK: - Percept value types

/// One interactive thing she can act on. `path` rides along on every row: it
/// is the resolve fallback when a handle's fingerprint changed, and it is what
/// keeps `stare` / `mac_ax_act` / `mac_click` compatible.
public struct MacLookAffordance: Sendable, Equatable {
    public let handle: String
    public let role: String
    public let subrole: String?
    public let label: String
    /// `title` (the app said so), `value` (the control shows its own contents,
    /// e.g. a popup button), or `unlabeled`. The latter retains a real handle
    /// and is rendered as a role ordinal rather than receiving an invented
    /// name.
    public let labelSource: String
    public let value: String?
    public let secret: Bool
    public let enabled: Bool
    public let selected: Bool?
    public let frame: MacAXFrame?
    public let path: [Int]
    /// The label/value as the compiler already redacted them under the FULL
    /// node context (standalone shape, the control's own caption, the
    /// enclosing secret-naming group, and the caption beside/above it — the
    /// same four tests `mac_view`'s legend and `mac_ax_tree` run). When set,
    /// `toJSON` emits these verbatim; when nil (a hand-built affordance) it
    /// falls back to the caption-less legend redaction. gpt-5.5 BLOCKING
    /// 2026-08-22: without the enclosing context an unlabeled field showing
    /// `123` inside a group titled "CVV" rode out in the clear.
    public let labelJSON: JSONValue?
    public let valueJSON: JSONValue?
    /// Agent acceptance round 1, finding B — this handle carries a
    /// DOCUMENT-ORDER ordinal because the element is genuinely
    /// indistinguishable from its siblings (N identical unlabeled buttons).
    /// The act is NOT refused — refusing would make Finder unusable — but the
    /// positional derivation is stated, because a silently positional handle is
    /// worse than a drifted one.
    public let handleAmbiguity: String?
    public var handleAmbiguous: Bool { handleAmbiguity != nil }

    public init(
        handle: String,
        role: String,
        subrole: String? = nil,
        label: String,
        labelSource: String,
        value: String? = nil,
        secret: Bool = false,
        enabled: Bool = true,
        selected: Bool? = nil,
        frame: MacAXFrame? = nil,
        path: [Int],
        labelJSON: JSONValue? = nil,
        valueJSON: JSONValue? = nil,
        handleAmbiguity: String? = nil
    ) {
        self.handleAmbiguity = handleAmbiguity
        self.handle = handle
        self.role = role
        self.subrole = subrole
        self.label = label
        self.labelSource = labelSource
        self.value = value
        self.secret = secret
        self.enabled = enabled
        self.selected = selected
        self.frame = frame
        self.path = path
        self.labelJSON = labelJSON
        self.valueJSON = valueJSON
    }

    /// The label as a glance may print it: the clear text when redaction let
    /// it through, nil when it was redacted (a glance never prints a digest).
    public var displayLabel: String? {
        MacPerceptionCompiler.displayText(label, json: labelJSON)
    }

    /// Same redaction contract as a `mac_view` legend row: a secure field's
    /// value is count+digest, everything else goes through the standalone shape
    /// test with its own label as the caption — plus, when the compiler
    /// supplied them, the enclosing-group and beside-caption tests.
    public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
        var object: [String: JSONValue] = [
            "handle": .string(handle),
            "role": .string(role),
            "label": labelJSON
                ?? MacScreenViewTextRedaction.redactedLegendString(label, valueChars: valueChars),
            "label_source": .string(labelSource),
            "enabled": .bool(enabled),
            "path": .array(path.map { .int(Int64($0)) }),
        ]
        if let subrole { object["subrole"] = .string(subrole) }
        // Coordinates remain implementation evidence for the four-verb fusion;
        // the legacy look tool is no longer model-visible. Keeping the frame on
        // the percept means an AX-named link/row cannot lose its physical point
        // merely because the separately captured view omitted or capped it.
        if let frame { object["frame"] = frame.toJSON() }
        if let value {
            object["value"] = secret
                ? MacInjectionResultRedaction.redactedSecret(value)
                : (valueJSON ?? MacScreenViewTextRedaction.redactedLegendString(
                    value,
                    valueChars: valueChars,
                    under: label
                ))
        }
        if secret { object["secret_field"] = .bool(true) }
        if let selected { object["selected"] = .bool(selected) }
        if let handleAmbiguity {
            object["handle_ambiguous"] = .bool(true)
            object["handle_ambiguity"] = .string(handleAmbiguity)
        }
        return .object(object)
    }
}

/// A READ-ONLY value on the screen — the thing a human reads without touching
/// anything (Agent acceptance round 1, finding A).
///
/// She pressed Calculator's Equals and the closed loop told her the affordances
/// changed but not that the answer was `390`: the display is an `AXStaticText`
/// inside an `AXScrollArea`, neither of them interactive, so the compiler
/// dropped both and she had to fall back to a 51 KB `stare` to read one number.
/// "Any read-back task — a total, a status line, a field's contents — forces a
/// stare and the token win evaporates exactly when it matters."
///
/// So a readout is a first-class channel of the percept, with the SAME
/// discipline as an affordance: a handle (the one the handle pass already
/// minted, so a readout is addressable AND diffable), a path, and text that has
/// been through the same compile-time redaction. A readout channel that
/// bypassed redaction would ship passwords and account numbers on the read tool
/// that needs no approval.
public struct MacLookReadout: Sendable, Equatable {
    /// nil only when the node was outside the handle pass (never in practice —
    /// handles are minted for EVERY node); the `path` is always the fallback.
    public let handle: String?
    public let role: String
    public let text: String
    /// `value` (the node published its contents) or `title` (the app named it).
    public let source: String
    public let path: [Int]
    /// Inside the focused element's subtree, or a sibling of it — the readout
    /// most likely to be the answer to what she just did.
    public let nearFocus: Bool
    public let inModal: Bool
    /// The text as the compiler already redacted it under the FULL node context.
    public let textJSON: JSONValue?
    public let handleAmbiguity: String?
    public var handleAmbiguous: Bool { handleAmbiguity != nil }

    public init(
        handle: String?,
        role: String,
        text: String,
        source: String,
        path: [Int],
        nearFocus: Bool = false,
        inModal: Bool = false,
        textJSON: JSONValue? = nil,
        handleAmbiguity: String? = nil
    ) {
        self.handle = handle
        self.role = role
        self.text = text
        self.source = source
        self.path = path
        self.nearFocus = nearFocus
        self.inModal = inModal
        self.textJSON = textJSON
        self.handleAmbiguity = handleAmbiguity
    }

    /// What the PROSE grade may print: the clear text when redaction let it
    /// through, nil when it withheld it. A glance never prints a digest.
    public var displayText: String? {
        MacPerceptionCompiler.displayText(text, json: textJSON)
    }

    public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
        var object: [String: JSONValue] = [
            "role": .string(role),
            "text": textJSON
                ?? MacScreenViewTextRedaction.redactedLegendString(text, valueChars: valueChars),
            "source": .string(source),
            "path": .array(path.map { .int(Int64($0)) }),
        ]
        if let handle { object["handle"] = .string(handle) }
        if nearFocus { object["near_focus"] = .bool(true) }
        if inModal { object["in_modal"] = .bool(true) }
        if let handleAmbiguity {
            object["handle_ambiguous"] = .bool(true)
            object["handle_ambiguity"] = .string(handleAmbiguity)
        }
        return .object(object)
    }
}

/// A structural region — what a human sees as "the toolbar", "the sidebar",
/// "the list". She needs these to say WHERE something is without a tree.
public struct MacLookLandmark: Sendable, Equatable {
    public let kind: String
    public let role: String
    public let label: String?
    /// 1-based, matching the reader's own depth convention (the window is 1).
    public let depth: Int
    public let path: [Int]
    public let frame: MacAXFrame?
    /// Compiler-redacted label (full node context); nil ⇒ legend fallback.
    public let labelJSON: JSONValue?

    public init(
        kind: String,
        role: String,
        label: String?,
        depth: Int,
        path: [Int],
        frame: MacAXFrame? = nil,
        labelJSON: JSONValue? = nil
    ) {
        self.kind = kind
        self.role = role
        self.label = label
        self.depth = depth
        self.path = path
        self.frame = frame
        self.labelJSON = labelJSON
    }

    public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
        var object: [String: JSONValue] = [
            "kind": .string(kind),
            "role": .string(role),
            "depth": .int(Int64(depth)),
            "path": .array(path.map { .int(Int64($0)) }),
        ]
        if let label {
            object["label"] = labelJSON
                ?? MacScreenViewTextRedaction.redactedLegendString(label, valueChars: valueChars)
        }
        if let frame { object["frame"] = frame.toJSON() }
        return .object(object)
    }
}

/// The sheet/dialog sitting over the window. Its own line in the GLANCE
/// because it changes what every other control means: the item-1 Mail sample
/// had a save-draft sheet up with the whole toolbar disabled, and a glance that
/// omitted it would have described a window she could not touch.
public struct MacLookModal: Sendable, Equatable {
    public let role: String
    public let subrole: String?
    public let label: String?
    public let path: [Int]
    public let labelJSON: JSONValue?

    public init(role: String, subrole: String?, label: String?, path: [Int], labelJSON: JSONValue? = nil) {
        self.role = role
        self.subrole = subrole
        self.label = label
        self.path = path
        self.labelJSON = labelJSON
    }

    public var displayLabel: String? { MacPerceptionCompiler.displayText(label, json: labelJSON) }

    public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
        var object: [String: JSONValue] = [
            "role": .string(role),
            "path": .array(path.map { .int(Int64($0)) }),
        ]
        if let subrole { object["subrole"] = .string(subrole) }
        if let label {
            object["label"] = labelJSON
                ?? MacScreenViewTextRedaction.redactedLegendString(label, valueChars: valueChars)
        }
        return .object(object)
    }
}

public struct MacLookFocus: Sendable, Equatable {
    public let role: String
    public let label: String?
    public let handle: String?
    public let path: [Int]
    public let labelJSON: JSONValue?

    public init(role: String, label: String?, handle: String?, path: [Int], labelJSON: JSONValue? = nil) {
        self.role = role
        self.label = label
        self.handle = handle
        self.path = path
        self.labelJSON = labelJSON
    }

    public var displayLabel: String? { MacPerceptionCompiler.displayText(label, json: labelJSON) }

    public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
        var object: [String: JSONValue] = [
            "role": .string(role),
            "path": .array(path.map { .int(Int64($0)) }),
        ]
        if let handle { object["handle"] = .string(handle) }
        if let label {
            object["label"] = labelJSON
                ?? MacScreenViewTextRedaction.redactedLegendString(label, valueChars: valueChars)
        }
        return .object(object)
    }
}

/// The compiled percept. One object, three renderings.
public struct MacLookPercept: Sendable, Equatable {
    public let app: MacAXAppInfo?
    public let windowTitle: String?
    public let focus: MacLookFocus?
    public let modal: MacLookModal?
    public let landmarks: [MacLookLandmark]
    public let affordances: [MacLookAffordance]
    /// Interactive elements with NO label, by role. The affordance rows retain
    /// them; this is the matching census for compact/legacy consumers.
    public let unlabeledByRole: [String: Int]
    /// Interactive+labeled elements dropped by the affordance cap (before the
    /// byte budget, which is applied at serialization time).
    public let affordancesOmitted: Int
    /// Every interactive element seen, labeled or not.
    public let interactiveCount: Int
    public let labeledCount: Int
    // Passed straight through from the walk — the caller must be able to tell
    // "there are no more buttons" from "the walk stopped early".
    public let truncated: Bool
    public let truncationReasons: [String]
    public let skippedAtLeast: Int
    /// Compiler-redacted window title (full node context); nil ⇒ legend fallback.
    public let windowTitleJSON: JSONValue?
    /// finding A — the read-only values on the screen, ranked and capped.
    public let readouts: [MacLookReadout]
    /// Readouts dropped by `maxReadouts` (before the byte budget).
    public let readoutsOmitted: Int
    /// finding B — how many of the emitted rows carry a position-derived
    /// (ordinal) handle. Counted so the payload can say it ONCE instead of the
    /// caller having to notice `.2` suffixes.
    public let ambiguousHandles: Int

    public init(
        app: MacAXAppInfo?,
        windowTitle: String?,
        focus: MacLookFocus?,
        modal: MacLookModal?,
        landmarks: [MacLookLandmark],
        affordances: [MacLookAffordance],
        unlabeledByRole: [String: Int],
        affordancesOmitted: Int,
        interactiveCount: Int,
        labeledCount: Int,
        truncated: Bool,
        truncationReasons: [String],
        skippedAtLeast: Int,
        windowTitleJSON: JSONValue? = nil,
        readouts: [MacLookReadout] = [],
        readoutsOmitted: Int = 0,
        ambiguousHandles: Int = 0
    ) {
        self.readouts = readouts
        self.readoutsOmitted = readoutsOmitted
        self.ambiguousHandles = ambiguousHandles
        self.app = app
        self.windowTitle = windowTitle
        self.focus = focus
        self.modal = modal
        self.landmarks = landmarks
        self.affordances = affordances
        self.unlabeledByRole = unlabeledByRole
        self.affordancesOmitted = affordancesOmitted
        self.interactiveCount = interactiveCount
        self.labeledCount = labeledCount
        self.truncated = truncated
        self.truncationReasons = truncationReasons
        self.skippedAtLeast = skippedAtLeast
        self.windowTitleJSON = windowTitleJSON
    }

    // MARK: glance

    /// ONE line, hard-capped at `MacPerceptionCompiler.glanceMaxChars`.
    ///
    /// Every segment is the SAME redacted text the structured channel emits
    /// (compiler-redacted under the full node context when available, the
    /// standalone shape test otherwise) — a glance is a smaller channel, not
    /// a laxer one; anything redaction withheld is simply absent here, never
    /// printed as a digest.
    /// - Parameter leading: the readout THIS act moved (Agent acceptance round
    ///   2, Calculator's Equals). `mac_look` never passes it and keeps the
    ///   ranked ordering; the ACT envelope passes the readout its own verb
    ///   changed or added, because leading with the top-ranked readout ("7×6")
    ///   when a different one carries the answer ("42") describes the screen
    ///   she was already looking at instead of the one she just made.
    public func glanceLine(leading: MacLookReadout? = nil) -> String {
        var parts: [String] = []
        let appName = app?.name ?? "unknown app"
        if let title = MacPerceptionCompiler.displayText(windowTitle, json: windowTitleJSON) {
            parts.append("\(appName) — \"\(title)\"")
        } else {
            parts.append(appName)
        }
        // finding A — the READOUT, near the front. Calculator's glance has to be
        // able to say the answer: "Calculator · reads: "390" · 25 controls".
        // Only what redaction let through, and only the top-ranked one — a
        // glance is a smaller channel, not a laxer or a longer one.
        if let reads = (leading ?? readouts.first)?.displayText {
            parts.append("reads: \"\(MacAccessibilityReader.truncate(reads, to: 40))\"")
        }
        parts.append("\(interactiveCount) controls (\(labeledCount) labeled)")
        if let focus {
            let label = focus.displayLabel
            parts.append(label.map { "focus: \(focus.role) \"\($0)\"" } ?? "focus: \(focus.role)")
        }
        if let modal {
            parts.append("MODAL: \(modal.displayLabel ?? modal.role)")
        }
        let examples = affordances
            .filter { $0.role == "AXButton" || $0.role == "AXMenuButton" || $0.role == "AXPopUpButton" }
            .compactMap { $0.displayLabel }
            .prefix(5)
        if !examples.isEmpty {
            parts.append("e.g. \(examples.joined(separator: ", "))")
        }
        let line = parts.joined(separator: " · ")
        return MacAccessibilityReader.truncate(line, to: MacPerceptionCompiler.glanceMaxChars)
    }

    // MARK: look

    public struct LookRendering: Sendable, Equatable {
        public let json: JSONValue
        /// True when the byte budget — not the affordance cap — removed rows.
        public let affordancesTruncated: Bool
        public let affordancesDroppedForBytes: Int
        public let bytes: Int
        /// finding A — readouts are trimmable too, and a trimmed readout list is
        /// reported exactly like a trimmed affordance list.
        public let readoutsDroppedForBytes: Int

        public init(
            json: JSONValue,
            affordancesTruncated: Bool,
            affordancesDroppedForBytes: Int,
            bytes: Int,
            readoutsDroppedForBytes: Int = 0
        ) {
            self.json = json
            self.affordancesTruncated = affordancesTruncated
            self.affordancesDroppedForBytes = affordancesDroppedForBytes
            self.bytes = bytes
            self.readoutsDroppedForBytes = readoutsDroppedForBytes
        }
    }

    /// The structured grade, under a HARD byte budget.
    ///
    /// The budget is enforced by DROPPING AFFORDANCE ROWS FROM THE END and
    /// SAYING SO (`affordances_truncated`), never by silently shipping a
    /// shorter list: a caller that cannot tell a complete list from a trimmed
    /// one will confidently conclude a button does not exist.
    /// - Parameter envelopeReserve: bytes held back for the tool envelope the
    ///   handler wraps around this object (`frame_id`, `seam`, `glance`,
    ///   `how_to_read`, …), so the FINAL `mac_look` payload — not just this
    ///   inner percept — stays under `byteBudget` (gpt-5.5 SHOULD-FIX 2026-08-22).
    public func lookJSON(
        byteBudget: Int = MacPerceptionCompiler.lookByteBudget,
        envelopeReserve: Int = MacPerceptionCompiler.lookEnvelopeReserve,
        valueChars: Int = MacPerceptionCompiler.affordanceValueChars
    ) -> LookRendering {
        let byteBudget = max(512, byteBudget - max(0, envelopeReserve))
        var rows = affordances.map { $0.toJSON(valueChars: valueChars) }
        var readoutRows = readouts.map { $0.toJSON(valueChars: valueChars) }
        var droppedForBytes = 0
        var readoutsDropped = 0

        func envelope(
            _ rows: [JSONValue],
            _ readoutRows: [JSONValue],
            truncatedForBytes: Bool,
            dropped: Int,
            readoutsDropped: Int
        ) -> JSONValue {
            var object: [String: JSONValue] = [
                "grade": .string("look"),
                "app": app?.toJSON() ?? .null,
                "window": windowTitle.map {
                    windowTitleJSON
                        ?? MacScreenViewTextRedaction.redactedLegendString($0, valueChars: valueChars)
                } ?? .null,
                "focus": focus?.toJSON(valueChars: valueChars) ?? .null,
                "modal": modal?.toJSON(valueChars: valueChars) ?? .null,
                "landmarks": .array(landmarks.map { $0.toJSON(valueChars: valueChars) }),
                "affordances": .array(rows),
                "affordance_count": .int(Int64(rows.count)),
                "affordances_truncated": .bool(truncatedForBytes || affordancesOmitted > 0),
                "affordances_omitted": .int(Int64(affordancesOmitted + dropped)),
                "affordances_dropped_for_bytes": .int(Int64(dropped)),
                "unlabeled": .object(unlabeledByRole.mapValues { .int(Int64($0)) }),
                "interactive_count": .int(Int64(interactiveCount)),
                "labeled_count": .int(Int64(labeledCount)),
                "truncated": .bool(truncated),
                "truncation_reasons": .array(truncationReasons.map { .string($0) }),
                "skipped_at_least": .int(Int64(skippedAtLeast)),
                // finding A — the read-only values. Same accounting discipline
                // as the affordance list: what was dropped is always said.
                "readouts": .array(readoutRows),
                "readout_count": .int(Int64(readoutRows.count)),
                "readouts_omitted": .int(Int64(readoutsOmitted + readoutsDropped)),
                "readouts_dropped_for_bytes": .int(Int64(readoutsDropped)),
                // finding B — controls before row content when the budget bites,
                // so Finder's filenames can never bury Finder's toolbar.
                "affordance_ranking": .string(MacPerceptionCompiler.affordanceRankingName),
            ]
            object["byte_budget"] = .int(Int64(byteBudget))
            if ambiguousHandles > 0 {
                object["ambiguous_handles"] = .int(Int64(ambiguousHandles))
                object["handles_note"] = .string(
                    "\(ambiguousHandles) handle(s) here are position-derived ordinals among "
                    + "identical elements — they will shift if the container reorders; re-look "
                    + "before acting on one."
                )
            }
            return .object(object)
        }

        func size(_ value: JSONValue) -> Int {
            (try? value.serializedData(pretty: false).count) ?? 0
        }

        var json = envelope(
            rows, readoutRows, truncatedForBytes: false, dropped: 0, readoutsDropped: 0
        )
        // Linear trim from the end; ≤60 affordance rows + ≤12 readouts, so the
        // repeated serialization is bounded and the result is exact rather than
        // estimated.
        //
        // WHICH LIST GIVES WAY: whichever is LONGER, ties to the affordances.
        // A readout is worth more than the 47th bookmark (finding A is exactly
        // the case where a readout was the only thing she wanted), and the cap
        // keeps readouts at ≤12 anyway, so in every real payload the affordance
        // tail is what goes first — but the choice is stated here and pinned by
        // a test rather than left to be inferred from the loop.
        while size(json) > byteBudget, !(rows.isEmpty && readoutRows.isEmpty) {
            if readoutRows.count > rows.count {
                readoutRows.removeLast()
                readoutsDropped += 1
            } else if !rows.isEmpty {
                rows.removeLast()
                droppedForBytes += 1
            } else {
                readoutRows.removeLast()
                readoutsDropped += 1
            }
            json = envelope(
                rows,
                readoutRows,
                truncatedForBytes: droppedForBytes > 0,
                dropped: droppedForBytes,
                readoutsDropped: readoutsDropped
            )
        }
        return LookRendering(
            json: json,
            affordancesTruncated: droppedForBytes > 0 || affordancesOmitted > 0,
            affordancesDroppedForBytes: droppedForBytes,
            bytes: size(json),
            readoutsDroppedForBytes: readoutsDropped
        )
    }
}

// MARK: - The compiler

public enum MacPerceptionCompiler {
    /// A glance is one line. 220 characters is roughly what fits on a terminal
    /// row and is ~55 tokens — the whole point of the grade.
    public static let glanceMaxChars = 220
    /// Hard byte cap on the FINAL look payload (inner percept + tool envelope).
    public static let lookByteBudget = 6144
    /// Bytes `lookJSON` holds back for the handler's envelope so the whole
    /// `mac_look` result, not just the percept, fits `lookByteBudget`.
    public static let lookEnvelopeReserve = 768

    /// What a glance may print for a text channel: the compiler-redacted clear
    /// text when it was let through, nil when redaction withheld it; with no
    /// compiler verdict (hand-built value) the standalone shape test decides.
    static func displayText(_ raw: String?, json: JSONValue?) -> String? {
        guard let raw else { return nil }
        guard let json else { return safeDisplay(raw) }
        if case .string(let clear) = json { return clear }
        return nil
    }
    /// Same ceiling as the fused view's legend, for the same reason.
    public static let maxAffordances = MacScreenViewBuilder.hardMaxMarks
    /// A landmark list longer than this is a tree, not a map.
    public static let maxLandmarks = 12
    public static let maxLandmarkDepth = 6
    /// An affordance's VALUE is a hint, not a document.
    public static let affordanceValueChars = 40
    /// finding A — a readout channel longer than this is the text of the
    /// window, not the values in it.
    public static let maxReadouts = 12
    /// finding B — the ranking the affordance list is emitted in, named on the
    /// wire so a caller can tell a ranked list from a document-order one.
    public static let affordanceRankingName = "controls_first"

    /// finding A — non-interactive roles that CARRY a value a human reads.
    /// `AXTextField`/`AXTextArea` are here for the read-only case: when they are
    /// interactive they are already affordances and are skipped.
    public static let readoutRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXValueIndicator", "AXLevelIndicator",
        "AXProgressIndicator", "AXTextField", "AXTextArea",
    ]

    /// finding B — the CONTROLS. Ranked ahead of row content when the cap or the
    /// byte budget bites: every Finder filename surfaces as an enabled
    /// `AXTextField` (rename-in-place), and in document order those 200 rows
    /// buried the toolbar and the sidebar she actually navigates with.
    public static let controlRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
        "AXRadioButton", "AXTab", "AXLink", "AXMenuItem", "AXComboBox",
        "AXSlider", "AXDisclosureTriangle", "AXIncrementor",
    ]

    /// Ancestor roles that make anything inside them a CONTROL for ranking:
    /// a toolbar's contents and a sheet's contents are what she came for.
    public static let controlContainerRoles: Set<String> = [
        "AXToolbar", "AXSheet", "AXMenuBar", "AXMenu",
    ]

    /// Advertises `AXPress`, or is one of the roles that is interactive whether
    /// or not the app bothered to advertise an action. Same two-family logic as
    /// `MacScreenViewBuilder.isMarkable`, narrowed: this list is what she can
    /// ACT on, so scroll containers are landmarks here rather than affordances.
    public static let interactiveRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXLink", "AXCheckBox", "AXPopUpButton",
        "AXComboBox", "AXSlider", "AXRadioButton", "AXMenuButton", "AXTab",
        "AXMenuItem",
        // DELIBERATE ADDITION to the item-2 brief's list. A secure text field
        // is the same class of thing as `AXTextField` and advertises no
        // `AXPress`; leaving it out made the ONE control on a login sheet
        // invisible to a look, which is the opposite of perception. Its VALUE
        // is still count+digest — see `MacLookAffordance.toJSON`.
        "AXSecureTextField",
    ]

    public static func isInteractive(_ attributes: MacAXAttributes) -> Bool {
        if attributes.actions.contains("AXPress") { return true }
        return interactiveRoles.contains(attributes.role)
    }

    /// role → landmark kind. A window's structure in the vocabulary a human
    /// would use for it.
    public static let landmarkKinds: [String: String] = [
        "AXToolbar": "toolbar",
        "AXOutline": "sidebar",
        "AXTable": "table",
        "AXList": "list",
        "AXScrollArea": "scrollarea",
        "AXWebArea": "webarea",
        "AXSheet": "sheet",
        "AXTabGroup": "tabgroup",
    ]

    public static let modalSubroles: Set<String> = [
        "AXDialog", "AXSystemDialog", "AXStandardWindow", "AXSheet",
    ]

    /// A display string that is safe for the PROSE grade: nil when the redactor
    /// says the text is itself a secret. The glance has no room for a
    /// count+digest object, so a secret is simply absent from it and the
    /// structured grade carries the audit shape.
    static func safeDisplay(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard MacScreenViewTextRedaction.standaloneSecretReason(trimmed) == nil else { return nil }
        return MacAccessibilityReader.truncate(trimmed, to: 40)
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func key(_ path: [Int]) -> String {
        path.map(String.init).joined(separator: ",")
    }

    /// Compile ONE walk into ONE percept. Pure: same snapshot in ⇒ same percept
    /// out, handles included.
    public static func compile(
        snapshot: MacAXTreeSnapshot,
        app: MacAXAppInfo?,
        windowTitle: String?,
        focusPath: [Int]? = nil,
        maxAffordances: Int = MacPerceptionCompiler.maxAffordances
    ) -> MacLookPercept {
        let cap = max(1, min(maxAffordances, MacPerceptionCompiler.maxAffordances))
        var byPath: [String: MacAXNode] = [:]
        for node in snapshot.nodes { byPath[key(node.path)] = node }

        // The SAME four-test redaction `mac_view`'s legend and `mac_ax_tree`
        // run — standalone shape, the control's own caption, the enclosing
        // secret-naming group, the caption beside/above — built once from the
        // WHOLE snapshot (a caption two rows away still names the value beside
        // it). Every text channel below is redacted HERE, at compile time, so
        // glance and look can never disagree and no renderer needs the tree.
        let secretContext = MacScreenViewTextRedaction.nodeSecretContext(snapshot.nodes)
        func redacted(_ text: String, of node: MacAXNode, under caption: String?) -> JSONValue {
            MacScreenViewTextRedaction.redactedNodeString(
                text,
                valueChars: affordanceValueChars,
                frame: node.attributes.frame,
                under: caption,
                enclosing: MacScreenViewTextRedaction.enclosingKinds(
                    forNodeAt: node.attributes.frame,
                    path: node.path,
                    among: secretContext.enclosingCaptions
                ),
                context: secretContext
            )
        }

        let ordered = snapshot.nodes.sorted { pathIsBefore($0.path, $1.path) }
        var childrenByParent: [String: [MacAXNode]] = [:]
        for node in ordered where !node.path.isEmpty {
            childrenByParent[key(Array(node.path.dropLast())), default: []].append(node)
        }

        // finding B — the identity of a TITLE-LESS container, from the first
        // text it contains. Bounded to 2 levels and 3 scanned descendants,
        // depth-first (Finder's shape is AXRow > AXCell > AXStaticText, so a
        // breadth-first scan would burn its budget on empty sibling cells and
        // never reach the filename).
        func contentName(of node: MacAXNode) -> String? {
            let attributes = node.attributes
            guard MacLookHandle.contentIdentityRoles.contains(attributes.role) else { return nil }
            // Rule 2 is untouched for anything with a name of its own, and for
            // any CONTROL whose value IS its label — the popup button reading
            // "Medium" then "Large" must keep one handle.
            guard cleaned(attributes.title) == nil else { return nil }
            guard !(isInteractive(attributes) && cleaned(attributes.value) != nil) else { return nil }
            var budget = 3
            func scan(_ path: [Int], depth: Int) -> String? {
                guard depth < 2 else { return nil }
                for child in childrenByParent[key(path)] ?? [] {
                    guard budget > 0 else { return nil }
                    budget -= 1
                    if let text = cleaned(child.attributes.title) ?? cleaned(child.attributes.value) {
                        return text
                    }
                    if let deeper = scan(child.path, depth: depth + 1) { return deeper }
                }
                return nil
            }
            guard let raw = scan(node.path, depth: 0) else { return nil }
            return String(
                raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .prefix(MacLookHandle.ancestorLabelChars)
            )
        }

        // An ancestor contributes its title, or — when it has none — the same
        // content-derived name, so two rows' CHILDREN are distinguishable too.
        // Without this the row itself gets a real identity and every cell
        // inside it still collides with its neighbour's.
        // NON-optional Value on purpose. As `[String: String?]` the store line
        // read `dict[key] = title ?? content`, and the assignment's expected
        // type (`String??`) made `??` resolve with T == String?: a nil `title`
        // promoted to `.some(nil)`, which is NOT nil, so `??` returned that
        // inner nil and EVERY row's content name was computed and then thrown
        // away — finding B shipped inert a second time. An absent label is now
        // an absent KEY, which has no second reading.
        var ancestorLabelByPath: [String: String] = [:]
        var contentNameByPath: [String: String] = [:]
        for node in ordered {
            // Written out rather than `title ?? contentName(of:)`: the
            // `??` autoclosure form did NOT evaluate the nested function here
            // (every row came back with no content name and the whole finding-B
            // fix shipped dead), and a silently-unevaluated identity is exactly
            // the class of bug this change exists to remove.
            let title = cleaned(node.attributes.title)
            let content = title == nil ? contentName(of: node) : nil
            let label: String? = title ?? content
            if let label { ancestorLabelByPath[key(node.path)] = label }
            if let content { contentNameByPath[key(node.path)] = content }
        }

        func ancestors(of path: [Int]) -> [(role: String, title: String?)] {
            var chain: [(role: String, title: String?)] = []
            guard !path.isEmpty else { return chain }
            for depth in 0..<path.count {
                let prefix = Array(path.prefix(depth))
                guard let node = byPath[key(prefix)] else { continue }
                // Agent round 2 — the WINDOW's title is in every element's
                // ancestor chain, so a document rename (Notes saving, a browser
                // navigating, a build finishing in a title) reminted EVERY
                // handle in the window even though not one control changed. The
                // window keeps its ROLE in the chain; its title is a property of
                // the window, not of the identity of the button inside it.
                // Load-bearing for the B3 identity guard: without this, every
                // act after a title change would refuse as `handle_drifted`.
                let label = prefix.isEmpty ? nil : ancestorLabelByPath[key(prefix)]
                chain.append((node.attributes.role, label))
            }
            return chain
        }

        // 1. Handles for EVERY node, in document order, so the focused element
        //    and an affordance agree on one identity. Ordinals are assigned by
        //    rendered TOKEN, which makes a hash collision between two distinct
        //    fingerprints a disambiguated pair rather than a silent merge.
        //
        //    THIS PASS RUNS BEFORE RANKING and over document order, so the
        //    controls-first ordering below can never change a handle.
        var seen: [String: Int] = [:]
        var handleByPath: [String: String] = [:]
        var ordinalByPath: [String: Int] = [:]
        var tokenByPath: [String: String] = [:]
        for node in ordered {
            let token = MacLookHandle.token(
                fingerprint: MacLookHandle.fingerprint(
                    role: node.attributes.role,
                    subrole: node.attributes.subrole,
                    // TITLE only — never the value. A field whose contents
                    // change is still the same field.
                    title: cleaned(node.attributes.title),
                    ancestors: ancestors(of: node.path),
                    // Already computed once above; `fingerprint` ignores it for
                    // titled nodes anyway.
                    contentName: contentNameByPath[key(node.path)]
                )
            )
            let ordinal = (seen[token] ?? 0) + 1
            seen[token] = ordinal
            handleByPath[key(node.path)] = MacLookHandle.rendered(token: token, ordinal: ordinal)
            ordinalByPath[key(node.path)] = ordinal
            tokenByPath[key(node.path)] = token
        }
        // finding B — a token that STILL repeats after `contentName` is genuine
        // ambiguity (N identical unlabeled buttons). Every row carrying one says
        // so; the act is never refused, because refusing would make Finder
        // unusable. Announce, don't hide.
        func ambiguity(at path: [Int]) -> String? {
            guard let token = tokenByPath[key(path)], let total = seen[token], total > 1 else {
                return nil
            }
            return MacLookHandle.ambiguityNote(ordinal: ordinalByPath[key(path)] ?? 1, total: total)
        }

        // 2. Affordances, landmarks, unlabeled census — one pass.
        var affordances: [MacLookAffordance] = []
        var landmarks: [MacLookLandmark] = []
        var unlabeled: [String: Int] = [:]
        var interactiveCount = 0
        var labeledCount = 0
        var omitted = 0
        var modal: MacLookModal?
        var readoutCandidates: [(node: MacAXNode, text: String, source: String)] = []

        for node in ordered {
            let attributes = node.attributes
            let depth = node.path.count + 1

            // Landmark?
            if let kind = landmarkKinds[attributes.role], depth <= maxLandmarkDepth {
                if landmarks.count < maxLandmarks {
                    let label = cleaned(attributes.title)
                    landmarks.append(MacLookLandmark(
                        kind: kind,
                        role: attributes.role,
                        label: label,
                        depth: depth,
                        path: node.path,
                        frame: attributes.frame,
                        labelJSON: label.map { redacted($0, of: node, under: nil) }
                    ))
                }
            } else if let subrole = attributes.subrole,
                      subrole == "AXDialog" || subrole == "AXSystemDialog",
                      depth <= maxLandmarkDepth,
                      landmarks.count < maxLandmarks {
                let label = cleaned(attributes.title)
                landmarks.append(MacLookLandmark(
                    kind: "dialog",
                    role: attributes.role,
                    label: label,
                    depth: depth,
                    path: node.path,
                    frame: attributes.frame,
                    labelJSON: label.map { redacted($0, of: node, under: nil) }
                ))
            }

            // Modal? The ROOT is never a modal — it is the window itself.
            if modal == nil, !node.path.isEmpty {
                let isSheet = attributes.role == "AXSheet" || attributes.subrole == "AXSheet"
                let isDialog = attributes.subrole == "AXDialog" || attributes.subrole == "AXSystemDialog"
                if isSheet || isDialog {
                    let titled = cleaned(attributes.title)
                    let messageNode = titled == nil ? firstStaticText(under: node.path, in: ordered) : nil
                    let label = titled ?? messageNode.flatMap { cleaned($0.attributes.title) ?? cleaned($0.attributes.value) }
                    modal = MacLookModal(
                        role: attributes.role,
                        subrole: attributes.subrole,
                        label: label,
                        path: node.path,
                        labelJSON: label.map { redacted($0, of: messageNode ?? node, under: nil) }
                    )
                }
            }

            // finding A — a READ-ONLY value? Collected as a candidate here and
            // deduped/ranked/capped below, once the affordance list is final.
            if !isInteractive(attributes) {
                let value = cleaned(attributes.value)
                let isReadoutRole = readoutRoles.contains(attributes.role)
                // Calculator's display is an AXScrollArea landmark whose OWN
                // value is "390" and whose only child is an AXStaticText. A
                // container that publishes a value is publishing a readout —
                // this is the exact case finding A was filed for.
                let containerValue = (landmarkKinds[attributes.role] != nil || attributes.role == "AXGroup")
                    ? value
                    : nil
                if isReadoutRole || containerValue != nil {
                    let text = value ?? (isReadoutRole ? cleaned(attributes.title) : nil)
                    if let text {
                        readoutCandidates.append((node, text, value != nil ? "value" : "title"))
                    }
                }
            }

            guard isInteractive(attributes) else { continue }
            interactiveCount += 1

            let title = cleaned(attributes.title)
            let value = cleaned(attributes.value)
            let label: String
            let labelSource: String
            if let title {
                label = title
                labelSource = "title"
            } else if let value {
                // A popup button / tab publishes its own state as its name.
                // Nearby-text inference is deliberately NOT run here: it needs
                // the capture geometry `mac_view` has and a look does not, and
                // a guessed label that costs a second AX pass is not "trivially
                // available".
                label = value
                labelSource = "value"
            } else {
                // A missing AX name is not a reason to throw a visible,
                // interactive control away. Keep its stable look handle and
                // let the one fused screen/target model publish `button 2`,
                // `text area 1`, and similar role ordinals. The empty label is
                // intentional: it renders as ⟨unlabeled⟩ and never masquerades
                // as an invented name.
                label = ""
                labelSource = "unlabeled"
                unlabeled[attributes.role, default: 0] += 1
            }
            if labelSource != "unlabeled" { labeledCount += 1 }
            // NO CAP HERE — finding B: the cap is applied AFTER ranking, so
            // "the 60 rows we kept" are the 60 most useful rows and not the
            // first 60 in document order (Finder's filenames, every time).
            let shownValue = labelSource == "value" ? nil : value
            affordances.append(MacLookAffordance(
                handle: handleByPath[key(node.path)] ?? "",
                role: attributes.role,
                subrole: attributes.subrole,
                label: label,
                labelSource: labelSource,
                value: shownValue,
                secret: MacScreenViewBuilder.isSecretField(
                    role: attributes.role,
                    subrole: attributes.subrole,
                    label: title
                ),
                enabled: attributes.enabled,
                selected: attributes.selected,
                frame: attributes.frame,
                path: node.path,
                // A value-derived label IS a value: redact it as one (under no
                // caption of its own). A title is redacted as a title.
                labelJSON: redacted(label, of: node, under: nil),
                // The control's own title is the value's caption — the "CVV"
                // box showing `123`, the "API key" field showing the key.
                valueJSON: shownValue.map { redacted($0, of: node, under: title) },
                handleAmbiguity: ambiguity(at: node.path)
            ))
        }

        // 2b. RANK, THEN CAP (finding B). Controls — buttons, menus, popups,
        //     checkboxes, radios, tabs, links, and anything inside a toolbar or
        //     a sheet — come before row CONTENT (the rename-able filename in
        //     every Finder row). Document order is preserved WITHIN a tier, and
        //     handles were minted in the pass above, so nothing here can move a
        //     handle.
        func rankTier(_ affordance: MacLookAffordance) -> Int {
            if controlRoles.contains(affordance.role) { return 0 }
            for depth in 0..<affordance.path.count {
                let ancestor = byPath[key(Array(affordance.path.prefix(depth)))]
                if let role = ancestor?.attributes.role, controlContainerRoles.contains(role) {
                    return 0
                }
                if let subrole = ancestor?.attributes.subrole, modalSubroles.contains(subrole) {
                    return 0
                }
            }
            return 1
        }
        affordances = affordances
            .enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (rankTier(lhs.element), rankTier(rhs.element))
                return a == b ? lhs.offset < rhs.offset : a < b
            }
            .map(\.element)
        if affordances.count > cap {
            omitted = affordances.count - cap
            affordances = Array(affordances.prefix(cap))
        }

        // 3. Focus — only when the source could actually tell us. An absent
        //    focus is reported as absent, never guessed at from "the first text
        //    field", which is how a look starts lying about where the cursor is.
        var focus: MacLookFocus?
        if let focusPath, let node = byPath[key(focusPath)] {
            let title = cleaned(node.attributes.title)
            let label = title ?? cleaned(node.attributes.value)
            focus = MacLookFocus(
                role: node.attributes.role,
                label: label,
                handle: handleByPath[key(focusPath)],
                path: focusPath,
                // A focused field's VALUE is the thing most likely to be the
                // secret (the cursor is in the password box). When the label
                // fell back to the value, the node has no title to caption it,
                // so the enclosing/beside geometry and the shape test decide.
                labelJSON: label.map { redacted($0, of: node, under: nil) }
            )
        }

        let rootNode = byPath[key([])]
        let title = cleaned(windowTitle)

        // 4. READOUTS (finding A) — dedupe hard, then rank, then cap.
        //
        //    Without the dedupe this channel becomes a second tree: a button's
        //    own AXStaticText child says exactly what the button says, and a
        //    sheet's message is already the modal's label.
        func normalizedText(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var readoutSeen = Set(affordances.map { normalizedText($0.label) })
        if let title { readoutSeen.insert(normalizedText(title)) }
        if let label = modal?.label { readoutSeen.insert(normalizedText(label)) }

        func readoutTier(_ path: [Int]) -> Int {
            if let modalPath = modal?.path,
               path.count > modalPath.count,
               Array(path.prefix(modalPath.count)) == modalPath { return 0 }
            if let focusPath {
                if path.count > focusPath.count, Array(path.prefix(focusPath.count)) == focusPath { return 1 }
                if path.count == focusPath.count, path.dropLast() == focusPath.dropLast() { return 1 }
            }
            for depth in 0..<path.count {
                let ancestor = byPath[key(Array(path.prefix(depth)))]
                if let role = ancestor?.attributes.role,
                   let kind = landmarkKinds[role],
                   kind == "scrollarea" || kind == "webarea" || kind == "table" { return 2 }
            }
            return 3
        }

        var readouts: [MacLookReadout] = []
        for candidate in readoutCandidates {
            let normalized = normalizedText(candidate.text)
            guard !normalized.isEmpty, !readoutSeen.contains(normalized) else { continue }
            readoutSeen.insert(normalized)
            let tier = readoutTier(candidate.node.path)
            readouts.append(MacLookReadout(
                handle: handleByPath[key(candidate.node.path)],
                role: candidate.node.attributes.role,
                text: candidate.text,
                source: candidate.source,
                path: candidate.node.path,
                nearFocus: tier == 1,
                inModal: tier == 0,
                // A readout is a VALUE. Same compile-time redactor, same full
                // node context (standalone shape, enclosing secret-naming group,
                // the caption beside/above) as every affordance channel — a
                // readout channel that bypassed this would ship the password
                // the login sheet is displaying.
                textJSON: redacted(candidate.text, of: candidate.node, under: nil),
                handleAmbiguity: ambiguity(at: candidate.node.path)
            ))
        }
        readouts = readouts
            .enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (readoutTier(lhs.element.path), readoutTier(rhs.element.path))
                return a == b ? lhs.offset < rhs.offset : a < b
            }
            .map(\.element)
        var readoutsOmitted = 0
        if readouts.count > maxReadouts {
            readoutsOmitted = readouts.count - maxReadouts
            readouts = Array(readouts.prefix(maxReadouts))
        }

        return MacLookPercept(
            app: app,
            windowTitle: title,
            focus: focus,
            modal: modal,
            landmarks: landmarks,
            affordances: affordances,
            unlabeledByRole: unlabeled,
            affordancesOmitted: omitted,
            interactiveCount: interactiveCount,
            labeledCount: labeledCount,
            truncated: snapshot.truncated,
            truncationReasons: snapshot.truncationReasons,
            skippedAtLeast: snapshot.skippedAtLeast,
            windowTitleJSON: title.map { text in
                rootNode.map { redacted(text, of: $0, under: nil) }
                    ?? MacScreenViewTextRedaction.redactedLegendString(text, valueChars: affordanceValueChars)
            },
            readouts: readouts,
            readoutsOmitted: readoutsOmitted,
            ambiguousHandles: affordances.filter(\.handleAmbiguous).count
                + readouts.filter(\.handleAmbiguous).count
        )
    }

    /// A sheet often has no title of its own; its message is the first static
    /// text inside it. Naming it from there is what makes the MODAL segment of
    /// a glance useful instead of "MODAL: AXSheet". Returns the NODE so the
    /// caller can redact the message under that node's own frame/context.
    private static func firstStaticText(under path: [Int], in ordered: [MacAXNode]) -> MacAXNode? {
        for node in ordered where node.path.count > path.count && Array(node.path.prefix(path.count)) == path {
            guard node.attributes.role == "AXStaticText" else { continue }
            if cleaned(node.attributes.title) ?? cleaned(node.attributes.value) != nil {
                return node
            }
        }
        return nil
    }

    static func pathIsBefore(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (a, b) in zip(lhs, rhs) where a != b { return a < b }
        return lhs.count < rhs.count
    }
}

// MARK: - The task-scoped frame (single slot, 180 s, NO authority)

/// What a handle resolves back to.
public struct MacLookFrameEntry: Sendable, Equatable {
    public let handle: String
    public let path: [Int]
    public let role: String
    public let label: String?
    public let frame: MacAXFrame?
    /// native-look item 3 — the BEFORE side of the effect diff. `mac_act`
    /// compares the recorded value/enabled against the post-action percept, so
    /// "the checkbox became checked" is answerable without a second look.
    /// Defaulted so every item-2 construction site is unchanged.
    public let value: String?
    public let enabled: Bool
    /// Agent acceptance round 1, finding B — this handle was position-derived.
    /// The drift guard is UNCHANGED; the act simply ECHOES this back so a caller
    /// can see it acted on an ordinal rather than on a stable identity.
    public let ambiguous: Bool
    /// The ambiguity NOTE as the compile wrote it ("ordinal:2 of 3 identical
    /// elements — …"). gpt-5.5 round-2 B3: it encodes the SIZE of the cohort the
    /// ordinal was drawn from, and that number is the only thing that moves when
    /// a same-label sibling ABOVE disappears — the rendered handle stays
    /// `token.2` and a re-flowed list even reuses the same rect. Compared by
    /// `MacActClosedLoop.identityDrift`, which is why it is stored rather than
    /// collapsed into the boolean above.
    public let ambiguityNote: String?
    /// gpt-5.5 round-2 B4 — the label/value AS THE COMPILER REDACTED THEM, with
    /// the full enclosing-caption context of the walk that produced them. The
    /// raw `label`/`value` above stay for the drift guard's identity check,
    /// which must compare what the app actually says; every OUTBOUND channel
    /// (the effect diff's added/removed/changed rows, `acted_element`) emits
    /// these instead. Re-redacting a stored string later cannot see the group
    /// titled "CVV" two rows up, so the leak reopened on the way OUT.
    public let labelJSON: JSONValue?
    public let valueJSON: JSONValue?
    /// The compile did NOT hand this element's text out verbatim — either the
    /// role is a secure field or the redactor's caption/enclosing-group tests
    /// fired (the unlabeled box inside a group titled "CVV"). Carried so the
    /// POST-act read — which has no compile context at all — is redacted on
    /// the same judgement rather than on a context-free second opinion.
    public let secret: Bool

    public init(
        handle: String,
        path: [Int],
        role: String,
        label: String?,
        frame: MacAXFrame?,
        value: String? = nil,
        enabled: Bool = true,
        ambiguous: Bool = false,
        ambiguityNote: String? = nil,
        labelJSON: JSONValue? = nil,
        valueJSON: JSONValue? = nil,
        secret: Bool = false
    ) {
        self.ambiguous = ambiguous
        self.ambiguityNote = ambiguityNote
        self.labelJSON = labelJSON
        self.valueJSON = valueJSON
        self.secret = secret
        self.handle = handle
        self.path = path
        self.role = role
        self.label = label
        self.frame = frame
        self.value = value
        self.enabled = enabled
    }
}

/// The BEFORE side of a readout diff (finding A). Keyed by handle when the
/// readout has one, by path otherwise, so "the display now says 390" is
/// answerable from the act's own result.
public struct MacLookReadoutRecord: Sendable, Equatable {
    public let handle: String?
    public let path: [Int]
    public let role: String
    public let text: String?
    /// gpt-5.5 round-3 B3 — the text AS THE COMPILER REDACTED IT, under the
    /// full node context of the walk that produced it. The raw `text` above
    /// stays for the DIFF (deciding whether a readout moved must compare what
    /// the app really says, or two different secrets both digested to the same
    /// marker would read as "unchanged"); every OUTBOUND channel emits this.
    /// A readout of `123` inside a group titled "CVV" is in the clear by shape
    /// alone — re-redacting the stored string later cannot see the caption two
    /// rows up, and `readouts_changed` was the third way that leaked.
    public let textJSON: JSONValue?
    /// The compile declined to hand this text out verbatim.
    public let secret: Bool

    public init(
        handle: String?,
        path: [Int],
        role: String,
        text: String?,
        textJSON: JSONValue? = nil,
        secret: Bool = false
    ) {
        self.handle = handle
        self.path = path
        self.role = role
        self.text = text
        self.textJSON = textJSON
        self.secret = secret
    }

    /// Handle when there is one; the path otherwise. A readout with no handle
    /// is still diffable — it just cannot survive a re-layout, which is the
    /// same honesty the affordance path fallback carries.
    public static func key(handle: String?, path: [Int]) -> String {
        if let handle, !handle.isEmpty { return handle }
        return "path:" + path.map(String.init).joined(separator: ",")
    }

    public var key: String { Self.key(handle: handle, path: path) }
}

/// The bounds one compile ran under (Agent acceptance round 2, Finder `open`).
///
/// A diff's added/removed AFFORDANCE CENSUS is a set difference, so it is only
/// evidence when both sides were allowed to see the same window: a recompile
/// that hit the node cap where the original did not "loses" 29 controls that
/// never went anywhere. Recorded on the frame so the act can SAY the two
/// compiles were not comparable instead of reporting the churn as navigation.
public struct MacLookCompileCaps: Sendable, Equatable {
    /// The walk itself stopped early (node cap, depth cap, unreadable element).
    public let truncated: Bool
    public let maxAffordances: Int?
    public let maxNodes: Int?
    public let maxDepth: Int?

    public init(
        truncated: Bool,
        maxAffordances: Int? = nil,
        maxNodes: Int? = nil,
        maxDepth: Int? = nil
    ) {
        self.truncated = truncated
        self.maxAffordances = maxAffordances
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
    }

    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = ["truncated": .bool(truncated)]
        if let maxAffordances { object["max_affordances"] = .int(Int64(maxAffordances)) }
        if let maxNodes { object["max_nodes"] = .int(Int64(maxNodes)) }
        if let maxDepth { object["max_depth"] = .int(Int64(maxDepth)) }
        return .object(object)
    }
}

public struct MacLookFrame: Sendable, Equatable {
    public let frameId: String
    public let capturedAt: Date
    public let appName: String?
    public let bundleId: String?
    public let windowTitle: String?
    public let entries: [String: MacLookFrameEntry]
    // native-look item 3 — the rest of the BEFORE state `mac_act` diffs
    // against. All defaulted, so every item-2 construction site is unchanged;
    // a frame recorded WITHOUT them simply reports fewer effect facts (an
    // unrecorded focus cannot be claimed to have changed) rather than guessing.
    /// The target app's pid, so the closed loop can install its AXObserver on
    /// the app she actually looked at rather than whatever is frontmost by the
    /// time the verb runs.
    public let pid: Int32?
    public let focusHandle: String?
    public let hasModal: Bool
    /// Path of the modal recorded in this frame, used to scope `dismiss` to the
    /// sheet's OWN buttons.
    public let modalPath: [Int]?
    /// finding A — the read-only values as they were, keyed by handle (or path
    /// when the readout has no handle). Defaulted empty so every item-2/item-3
    /// construction site keeps its meaning: a frame recorded without readouts
    /// reports no readout changes rather than inventing them.
    public let readouts: [String: MacLookReadoutRecord]
    /// gpt-5.5 round-3 B1 — WHICH WINDOW of that pid this frame describes.
    ///
    /// The pid anchor (round-2 B2) stopped `mac_act` acting in the wrong APP;
    /// inside the right app the resolve still took "focused, else main, else
    /// first", so two windows of one app plus a focus change between the look
    /// and the act put a correct-looking act in the wrong window. Both the act
    /// resolve and the post-act read target THIS window or refuse
    /// (`frame_window_gone` / `window_drifted`). nil ⇒ the source could not
    /// name a window at all, and the anchor degrades to the pid rather than
    /// pretending.
    public let windowIdentity: MacAXWindowIdentity?
    /// The bounds THIS frame's compile ran under. nil ⇒ the frame predates the
    /// record (its diff simply cannot claim incomparability rather than
    /// inventing one).
    public let caps: MacLookCompileCaps?

    public init(
        frameId: String,
        capturedAt: Date,
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        entries: [String: MacLookFrameEntry],
        pid: Int32? = nil,
        focusHandle: String? = nil,
        hasModal: Bool = false,
        modalPath: [Int]? = nil,
        readouts: [String: MacLookReadoutRecord] = [:],
        windowIdentity: MacAXWindowIdentity? = nil,
        caps: MacLookCompileCaps? = nil
    ) {
        self.windowIdentity = windowIdentity
        self.readouts = readouts
        self.caps = caps
        self.frameId = frameId
        self.capturedAt = capturedAt
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.entries = entries
        self.pid = pid
        self.focusHandle = focusHandle
        self.hasModal = hasModal
        self.modalPath = modalPath
    }

    /// - Parameter rendered: how many affordance rows the caller actually
    ///   SHOWED (the byte budget may have trimmed the tail). Only shown rows
    ///   mint handles — "handles valid for this frame_id" must mean the handles
    ///   she saw, not rows dropped on the way out (gpt-5.5 SHOULD-FIX
    ///   2026-08-22). nil ⇒ every affordance (a glance mints them all; its
    ///   output says how many are addressable and that `look` lists them).
    /// Did the compile decline to emit this text verbatim? Anything other than
    /// the raw string back means the redactor acted, and that verdict is what
    /// the post-act read (which has no context of its own) must inherit.
    static func withheld(_ json: JSONValue?, raw: String?) -> Bool {
        guard let json else { return false }
        guard let raw else { return json != .null }
        return json != .string(raw)
    }

    public static func entries(
        from percept: MacLookPercept,
        rendered: Int? = nil
    ) -> [String: MacLookFrameEntry] {
        var out: [String: MacLookFrameEntry] = [:]
        let shown = rendered.map { Array(percept.affordances.prefix(max(0, $0))) } ?? percept.affordances
        for affordance in shown where !affordance.handle.isEmpty {
            out[affordance.handle] = MacLookFrameEntry(
                handle: affordance.handle,
                path: affordance.path,
                role: affordance.role,
                label: affordance.label,
                frame: affordance.frame,
                value: affordance.value,
                enabled: affordance.enabled,
                ambiguous: affordance.handleAmbiguous,
                ambiguityNote: affordance.handleAmbiguity,
                labelJSON: affordance.labelJSON,
                valueJSON: affordance.valueJSON,
                secret: affordance.secret
                    || withheld(affordance.labelJSON, raw: affordance.label)
                    || withheld(affordance.valueJSON, raw: affordance.value)
            )
        }
        if let focus = percept.focus, let handle = focus.handle, out[handle] == nil {
            out[handle] = MacLookFrameEntry(
                handle: handle,
                path: focus.path,
                role: focus.role,
                label: focus.label,
                frame: nil,
                // Round-3 B4, found by the summary pin: a focus-derived entry
                // was minted with the RAW label and no compile verdict, so when
                // that element later left the window the diff printed it in the
                // clear through `affordances_removed` — the CVV field the whole
                // look correctly withheld, leaked by focusing it.
                labelJSON: focus.labelJSON,
                secret: withheld(focus.labelJSON, raw: focus.label)
            )
        }
        return out
    }

    /// finding A — the readouts as they were, so the next act can say what the
    /// display CHANGED TO. Every readout is recorded (a readout is not an act
    /// target, so the "only rows she saw mint handles" rule that governs
    /// `entries` does not apply — this is diff state, not authority).
    public static func readoutRecords(from percept: MacLookPercept) -> [String: MacLookReadoutRecord] {
        var out: [String: MacLookReadoutRecord] = [:]
        for readout in percept.readouts {
            let record = MacLookReadoutRecord(
                handle: readout.handle,
                path: readout.path,
                role: readout.role,
                text: readout.text,
                // B3 — carry the COMPILE's verdict forward. The act's readout
                // diff has no snapshot context of its own, so this is the only
                // place the "CVV two rows up" judgement still exists.
                textJSON: readout.textJSON,
                secret: withheld(readout.textJSON, raw: readout.text)
            )
            if out[record.key] == nil { out[record.key] = record }
        }
        return out
    }

    /// Record the whole percept — entries plus the focus/modal/window state the
    /// item-3 diff needs. One constructor so a caller cannot record a frame
    /// that is half-populated.
    public static func from(
        percept: MacLookPercept,
        frameId: String,
        capturedAt: Date,
        windowTitle: String?,
        rendered: Int? = nil,
        windowIdentity: MacAXWindowIdentity? = nil,
        caps: MacLookCompileCaps? = nil
    ) -> MacLookFrame {
        MacLookFrame(
            frameId: frameId,
            capturedAt: capturedAt,
            appName: percept.app?.name,
            bundleId: percept.app?.bundleIdentifier,
            windowTitle: windowTitle,
            entries: entries(from: percept, rendered: rendered),
            pid: percept.app?.processIdentifier,
            focusHandle: percept.focus?.handle,
            hasModal: percept.modal != nil,
            modalPath: percept.modal?.path,
            readouts: readoutRecords(from: percept),
            windowIdentity: windowIdentity,
            // The walk's own truncation always travels with the frame; the
            // caller adds the caps it asked for (a compile that ran under a
            // lowered max_affordances/max_nodes/max_depth is not comparable
            // with one that did not).
            caps: caps ?? MacLookCompileCaps(truncated: percept.truncated)
        )
    }

}

public extension MacPerceptionCompiler {
    /// gpt-5.5 round-3 B4 — every node's text, redacted under the SAME full
    /// snapshot context `compile` uses, keyed by path.
    ///
    /// The dense bulk-change summary describes nodes the percept does not carry
    /// as affordances (the focus container, its first children), and it was
    /// redacting their raw attributes with the standalone shape test only. That
    /// test cannot see the group titled "CVV" two rows up, so a child labeled
    /// with a card code left in the clear through `summary.first_children`
    /// while the affordance list correctly withheld it. One map, built from the
    /// whole snapshot, so the summary can never disagree with the percept.
    static func redactedNodeTextMap(_ snapshot: MacAXTreeSnapshot) -> [[Int]: JSONValue] {
        let secretContext = MacScreenViewTextRedaction.nodeSecretContext(snapshot.nodes)
        var out: [[Int]: JSONValue] = [:]
        for node in snapshot.nodes {
            guard let text = node.attributes.title ?? node.attributes.value else { continue }
            out[node.path] = MacScreenViewTextRedaction.redactedNodeString(
                text,
                valueChars: affordanceValueChars,
                frame: node.attributes.frame,
                // A node's own title is its caption for its own value; a node
                // whose TEXT is the title has no caption above itself.
                under: node.attributes.title == text ? nil : node.attributes.title,
                enclosing: MacScreenViewTextRedaction.enclosingKinds(
                    forNodeAt: node.attributes.frame,
                    path: node.path,
                    among: secretContext.enclosingCaptions
                ),
                context: secretContext
            )
        }
        return out
    }
}

/// The task-scoped perceptual frame, modelled exactly on `MacScreenViewStore`
/// and carrying the same three properties:
///
///  • SINGLE SLOT — "the last look" is the only look whose handles can still be
///    trusted; holding several ids cannot be reasoned around.
///  • TTL — 180 s. A frame older than that is not a description of the screen.
///  • NO AUTHORITY — `resolve` returns a path and a rect. Item 3's verbs sit
///    behind the same gates the injection tools already clear; a handle can
///    only ever redirect an already-approved act at a better target.
///
/// It is also NOT resident: nothing writes here except a `mac_look` call, and
/// an expired frame is simply refused (and cleared on the next look) rather
/// than being swept by a timer.
public actor MacLookFrameStore {
    public static let shared = MacLookFrameStore()

    public static let ttlSeconds: TimeInterval = 180

    public enum ResolveFailure: String, Sendable, Equatable, Error {
        case noFrame = "no_frame"
        case staleFrame = "stale_frame"
        case frameExpired = "frame_expired"
        case unknownHandle = "unknown_handle"

        public var guidance: String {
            switch self {
            case .noFrame:
                return "no look has been taken yet — call mac_look first"
            case .staleFrame:
                // Agent round 7, envelope F13EB82C: she reused a handle from
                // before an `open` and got this. The refusal was RIGHT and cost
                // zero input — but "call mac_look again" is the wrong next step
                // after an act, because the act ALREADY returned a fresh frame
                // with fresh handles. Sending her to re-look for something she
                // was handed is how a correct refusal still wastes a call.
                return "that frame is not the latest one — every mac_act returns a NEW frame_id with "
                    + "re-minted handles, so a handle from before your last act cannot be used; take "
                    + "the handles from that act's result (or call mac_look if you have not acted)"
            case .frameExpired:
                return "that frame is older than \(Int(MacLookFrameStore.ttlSeconds))s — call mac_look again"
            case .unknownHandle:
                return "that handle is not in the latest look's affordances"
            }
        }
    }

    private var latest: MacLookFrame?

    public init() {}

    public func record(_ frame: MacLookFrame) { latest = frame }

    public func latestFrameId() -> String? { latest?.frameId }

    public func frame(frameId: String) -> MacLookFrame? {
        guard let latest, latest.frameId == frameId else { return nil }
        return latest
    }

    /// True when the held frame is past its TTL — the signal the live seam uses
    /// to decide the Chromium enhanced-AX flag's lifetime is over.
    public func isExpired(now: Date) -> Bool {
        guard let latest else { return true }
        return now.timeIntervalSince(latest.capturedAt) > Self.ttlSeconds
    }

    public func resolve(
        handle: String,
        frameId: String,
        now: Date
    ) -> Result<MacLookFrameEntry, ResolveFailure> {
        guard let latest else { return .failure(.noFrame) }
        guard latest.frameId == frameId else { return .failure(.staleFrame) }
        guard now.timeIntervalSince(latest.capturedAt) <= Self.ttlSeconds else {
            return .failure(.frameExpired)
        }
        guard let entry = latest.entries[handle] else { return .failure(.unknownHandle) }
        return .success(entry)
    }

    /// Physical user input or a completed motor action may have moved
    /// everything. Same safety invalidation the view store carries.
    public func invalidate() { latest = nil }

    /// Test seam only.
    public func reset() { latest = nil }
}

// MARK: - The Chromium / Electron live seam

/// Chromium and Electron ship their web content to the accessibility API only
/// once the app is told a screen reader is present. Without it a look at
/// Chrome, VS Code, Slack or Claude.app sees a shell — the item-1 spike read 12
/// nodes from one and 2,000+ from the same window after the flag.
///
/// Two flags, because the two families answer to different ones (spike,
/// 2026-08-22): Chrome takes `AXEnhancedUserInterface` (the set returns
/// `kAXErrorCannotComplete` and yet READS BACK true and takes effect — so a
/// non-success status here is NOT a failure and must not be treated as one),
/// Electron takes `AXManualAccessibility`. Both are set; the read-back is the
/// evidence, never the status code.
///
/// THIS IS THE ONE ATTRIBUTE WRITE IN THE PERCEPTION PATH, and it is
/// deliberately not in `MacAccessibilityReader.swift` — that file's contract is
/// that it contains no `AXUIElementSetAttributeValue` at all, and it stays
/// that way. What is written is the target app's own accessibility MODE, not
/// any UI state: it presses nothing, types nothing and changes no document.
///
/// LIFETIME: the flag is left set for the frame's lifetime, because clearing it
/// between grades would make the next look pay the ~4 s settle again. It is
/// cleared LAZILY — on the next look whose frontmost app differs, or whose
/// frame has expired — rather than by a timer, because a timer would be exactly
/// the resident background thing this plan forbids.
public enum MacChromiumAccessibility {
    /// Known Chromium/Electron-family bundle ids on User's Mac.
    public static let bundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.anthropic.claudefordesktop",
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "com.spotify.client",
        "com.hnc.Discord",
        "notion.id",
        "com.figma.Desktop",
        "md.obsidian",
    ]

    /// Roles a Chromium shell exposes before the flag: a window, a couple of
    /// groups, and essentially nothing else. Used as the by-shape fallback for
    /// an Electron app not on the list above.
    public static let shellNodeCeiling = 24

    /// Does this walk look like an un-enhanced Chromium shell? True when the
    /// bundle id is known, OR the window exposed no `AXWebArea` and came back
    /// implausibly small for an app window.
    public static func looksChromium(bundleId: String?, snapshot: MacAXTreeSnapshot?) -> Bool {
        if let bundleId, bundleIdentifiers.contains(bundleId) { return true }
        // Apple's own processes are never Chromium shells. Without this the
        // shell heuristic matched `com.apple.loginwindow` (a locked screen:
        // one window, zero controls) on 2026-08-22 and every glance at the
        // lock screen paid the 4 s enhanced-AX settle for nothing.
        if let bundleId, bundleId.hasPrefix("com.apple.") { return false }
        guard let snapshot else { return false }
        let hasWebArea = snapshot.nodes.contains { $0.attributes.role == "AXWebArea" }
        guard !hasWebArea, snapshot.nodes.count <= shellNodeCeiling, !snapshot.truncated else { return false }
        // …and it must actually be a SHELL. A small native window (a Mail
        // compose sheet is 12 nodes) has real controls; an un-enhanced
        // Chromium window has a window, a couple of groups and nothing to
        // press. Without this the flag would be set on Mail and Finder.
        return !snapshot.nodes.contains { MacPerceptionCompiler.isInteractive($0.attributes) }
    }

    public static func hasWebArea(_ snapshot: MacAXTreeSnapshot?) -> Bool {
        snapshot?.nodes.contains { $0.attributes.role == "AXWebArea" } ?? false
    }

    /// Bounded settle after the flag. The spike measured ~4 s to a full web
    /// tree; 2 s was too short on one read.
    public static let settleSeconds: Double = 4.0
    public static let pollSeconds: Double = 0.5
}

/// Which app currently has the enhanced-AX flag set, so the next look can clear
/// it when the frontmost app changes or the frame dies. Tiny by design: it
/// holds a pid, not a snapshot, and nothing reads it on any path but `look`.
public actor MacChromiumAccessibilityState {
    public static let shared = MacChromiumAccessibilityState()

    private var enhancedPid: Int32?

    public init() {}

    public func current() -> Int32? { enhancedPid }
    public func note(pid: Int32?) { enhancedPid = pid }
}

#if canImport(ApplicationServices) && os(macOS)

public extension SystemMacAXElementSource {
    /// Set both enhanced-accessibility flags on an APPLICATION element and
    /// report what they READ BACK as. Chrome's set returns
    /// `kAXErrorCannotComplete` while the flag takes effect, so the status is
    /// discarded on purpose and only the read-back is reported.
    ///
    /// On the AX execution lane, like every other AX transaction in this module
    /// (`MacAXExecutionLane` — AppKit/SwiftUI handlers are main-thread isolated
    /// and an off-lane AX call can crash the TARGET app).
    @discardableResult
    static func setEnhancedAccessibility(pid: Int32, enabled: Bool) -> Bool {
        MacAXExecutionLane.sync {
            // Self-process fence — writing AX flags onto our own app element
            // is the same in-process AppKit re-entry class as the 2026-08-28
            // P1 deadlock in the reader. Unreachable once snapshots refuse
            // self, kept as the last wall for a direct caller.
            guard pid != getpid() else { return false }
            let app = AXUIElementCreateApplication(pid)
            let value: CFTypeRef = (enabled ? kCFBooleanTrue : kCFBooleanFalse)
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, value)
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, value)
            return readsEnhancedAccessibility(app: app)
        }
    }

    /// fable51 item 33 (gpt-5.5 review) — bound EVERY AX round trip to ONE app
    /// for the duration of a heavy read, and put it back afterwards.
    ///
    /// Deliberately the APPLICATION element, never `AXUIElementCreateSystemWide`:
    /// per `AXUIElement.h` the system-wide form retunes the timeout for the
    /// WHOLE PROCESS, and exactly one organ in this app is allowed to do that
    /// (`ActivityWatcher`, pinned by its architecture test). Scoped here, an
    /// unresponsive app being read cannot wedge anything but its own read.
    ///
    /// `seconds: 0` restores the system default, which is what the caller's
    /// `defer` passes — the bound belongs to the read, not to the app.
    static func setMessagingTimeout(pid: Int32, seconds: Float) {
        MacAXExecutionLane.sync {
            // Same self-process fence as the flags above.
            guard pid != getpid() else { return }
            _ = AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(pid), seconds)
        }
    }

    /// Read-back on either flag. `true` means the app really is in
    /// enhanced-accessibility mode, whatever the setter returned.
    private static func readsEnhancedAccessibility(app: AXUIElement) -> Bool {
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { continue }
            if CFBooleanGetValue((raw as! CFBoolean)) { return true }
        }
        return false
    }
}

#endif
