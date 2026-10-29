import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
import os
import CoreGraphics
import UserNotifications
import Senses
import Experiences
import CryptoKit
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `MacLookPercept.swift` | Immutable semantic percept, handle and readout vocabulary |
//
// One `MacAXTreeSnapshot` supplies glance (one line), look (structured handles),
// and stare (the delegated `mac_ax_tree` payload); there is no second walker.
// Unnamed controls remain addressable with explicit role ordinals.
// Frames are pulled, single-slot per source, expire after 180 s and grant no authority.
// Outbound text uses the same redaction as the view legend, including trace/persist/sync.
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
/// Repeated tokens carry an ordinal in document order: `h7k2q1`, `h7k2q1.2`.
/// Grouping the ordinal by rendered TOKEN rather than by fingerprint also makes
/// a hash collision between two different fingerprints harmless instead of a
/// silent merge.
public enum MacLookHandle {
    /// Token length in base36. 36^6 ≈ 2.2e9, against ≤60 affordances per frame.
    public static let tokenLength = 6
    /// An ancestor's label contributes at most this many characters.
    public static let ancestorLabelChars = 24
    /// Untitled content rows derive identity from contained text, so insertion preserves handles.
    /// Controls exclude changing values; layout-only `AXGroup` text cannot name descendants.
    public static let contentIdentityRoles: Set<String> = [
        "AXRow", "AXCell", "AXOutlineRow", "AXListItem",
    ]
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
    /// The fingerprint string, before hashing.
    /// - Parameter contentName: the identity of a TITLE-LESS container, derived
    ///   from contained text; appended only when present and the title is absent.
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
    public static func mint(tokens: [String]) -> [(handle: String, ambiguity: String?)] {
        var totals: [String: Int] = [:]
        for token in tokens { totals[token, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return tokens.map { token in
            let ordinal = (seen[token] ?? 0) + 1
            seen[token] = ordinal
            let total = totals[token] ?? 1
            return (rendered(token: token, ordinal: ordinal),
                    total > 1 ? ambiguityNote(ordinal: ordinal, total: total) : nil)
        }
    }
}
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
    public let state: String?
    public let frame: MacAXFrame?
    public let path: [Int]
    /// The label/value as the compiler already redacted them under the FULL
    /// node context (standalone shape, the control's own caption, the
    /// enclosing secret-naming group, and the caption beside/above it — the
    /// same four tests `mac_view`'s legend and `mac_ax_tree` run). When set,
    /// `toJSON` emits these verbatim; when nil (a hand-built affordance) it
    /// uses the caption-less legend redaction.
    public let labelJSON: JSONValue?
    public let valueJSON: JSONValue?
    /// Indistinguishable siblings remain actionable, with position-derived identity stated explicitly.
    public let handleAmbiguity: String?
    public var handleAmbiguous: Bool { handleAmbiguity != nil }
    /// An editable field's placeholder, a second name it answers to, and its
    /// compile-time redaction verdict (same contract as `labelJSON`).
    public let placeholder: String?
    public let placeholderJSON: JSONValue?
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
        handleAmbiguity: String? = nil,
        placeholder: String? = nil,
        placeholderJSON: JSONValue? = nil,
        state: String? = nil
    ) {
        self.handleAmbiguity = handleAmbiguity
        self.placeholder = placeholder
        self.placeholderJSON = placeholderJSON
        self.handle = handle
        self.role = role
        self.subrole = subrole
        self.label = label
        self.labelSource = labelSource
        self.value = value
        self.secret = secret
        self.enabled = enabled
        self.selected = selected
        self.state = state
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
        if let placeholder {
            object["placeholder"] = placeholderJSON
                ?? MacScreenViewTextRedaction.redactedLegendString(placeholder, valueChars: valueChars)
        }
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
        if let state { object["state"] = .string(state) }
        if let handleAmbiguity {
            object["handle_ambiguous"] = .bool(true)
            object["handle_ambiguity"] = .string(handleAmbiguity)
        }
        return .object(object)
    }
}
/// A read-only screen value with the shared node handle, path and compile-time redaction.
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
/// The sheet/dialog gets its own glance line because it constrains the other controls.
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
    public let selectionRange: NSRange?
    public init(role: String, label: String?, handle: String?, path: [Int], labelJSON: JSONValue? = nil, selectionRange: NSRange? = nil) {
        self.role = role
        self.label = label
        self.handle = handle
        self.path = path
        self.labelJSON = labelJSON
        self.selectionRange = selectionRange
    }
    public var displayLabel: String? { MacPerceptionCompiler.displayText(label, json: labelJSON) }
    public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
        var object: [String: JSONValue] = [
            "role": .string(role),
            "path": .array(path.map { .int(Int64($0)) }),
        ]
        if let handle { object["handle"] = .string(handle) }
        if let selectionRange {
            object["selection_range"] = .object([
                "location": .int(Int64(selectionRange.location)),
                "length": .int(Int64(selectionRange.length)),
                "unit": .string("utf16"),
            ])
        }
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
    /// The read-only values on the screen, ranked and capped.
    public let readouts: [MacLookReadout]
    /// Readouts dropped by `maxReadouts` (before the byte budget).
    public let readoutsOmitted: Int
    /// How many of the emitted rows carry a position-derived
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
    /// ONE line, hard-capped at `MacPerceptionCompiler.glanceMaxChars`.
    ///
    /// Every segment is the SAME redacted text the structured channel emits
    /// (compiler-redacted under the full node context when available, the
    /// standalone shape test otherwise) — a glance is a smaller channel, not
    /// a laxer one; anything redaction withheld is simply absent here, never
    /// printed as a digest.
    /// - Parameter leading: the act's changed/added readout; `mac_look` keeps ranked ordering.
    public func glanceLine(leading: MacLookReadout? = nil) -> String {
        var parts: [String] = []
        let appName = app?.name ?? "unknown app"
        if let title = MacPerceptionCompiler.displayText(windowTitle, json: windowTitleJSON) {
            parts.append("\(appName) — \"\(title)\"")
        } else {
            parts.append(appName)
        }
        // Lead with one redaction-approved readout: the act's result or the top-ranked value.
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
    /// Fits the complete delivered envelope, reporting every omitted row.
    public func lookJSON(
        byteBudget: Int = MacPerceptionCompiler.lookByteBudget,
        valueChars: Int = MacPerceptionCompiler.affordanceValueChars,
        envelope: ([String: JSONValue]) -> [String: JSONValue]
    ) -> JSONValue {
        var rows = affordances.map { $0.toJSON(valueChars: valueChars) }
        var readoutRows = readouts.map { $0.toJSON(valueChars: valueChars) }
        var droppedForBytes = 0
        var readoutsDropped = 0
        func render(
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
                // Read-only values report the same omission accounting as controls.
                "readouts": .array(readoutRows),
                "readout_count": .int(Int64(readoutRows.count)),
                "readouts_omitted": .int(Int64(readoutsOmitted + readoutsDropped)),
                "readouts_dropped_for_bytes": .int(Int64(readoutsDropped)),
                // Controls rank before row content when the budget bites.
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
            let perceptBytes = size(.object(object))
            object = envelope(object)
            object["percept_bytes"] = .int(Int64(perceptBytes))
            object["bytes"] = .int(0)
            while true {
                let bytes = size(.object(object))
                if bytes > MacPerceptionCompiler.lookByteBudget, object["byte_budget_exceeded"] != .bool(true) {
                    object["byte_budget_exceeded"] = .bool(true)
                    object["byte_budget"] = .int(Int64(MacPerceptionCompiler.lookByteBudget))
                    continue
                }
                if object["bytes"] == .int(Int64(bytes)) { break }
                object["bytes"] = .int(Int64(bytes))
            }
            return .object(object)
        }
        func size(_ value: JSONValue) -> Int {
            (try? value.serializedData(pretty: false).count) ?? 0
        }
        var json = render(
            rows, readoutRows, truncatedForBytes: false, dropped: 0, readoutsDropped: 0
        )
        // Drop from the longer list's tail; ties give way to affordances.
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
            json = render(
                rows,
                readoutRows,
                truncatedForBytes: droppedForBytes > 0,
                dropped: droppedForBytes,
                readoutsDropped: readoutsDropped
            )
        }
        return json
    }
}
