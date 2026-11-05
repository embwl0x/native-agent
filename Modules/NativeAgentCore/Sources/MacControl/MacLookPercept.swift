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
// One AX snapshot supplies all grades so perception cannot disagree across walkers. Handles hash titles, roles and ancestors, excluding values and indices so
// edits and scrolling preserve identity. Retitles mint new handles; document-order ordinals disambiguate siblings and hash collisions. Frames are pulled,
// expire after 180 seconds and grant no authority; all output retains full-context redaction.
public enum MacLookHandle {
    /// Token length in base36. 36^6 ≈ 2.2e9, against ≤60 affordances per frame.
    public static let tokenLength = 6
    public static let ancestorLabelChars = 24
    /// Untitled rows use contained text to survive insertion; controls exclude changing values and layout-only groups cannot name descendants.
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
    /// Only untitled containers use content identity; a title owns named identity.
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
    /// Disclose position-derived identity because reordering can silently move an ordinal handle.
    public static func ambiguityNote(ordinal: Int, total: Int) -> String {
        "ordinal:\(ordinal) of \(total) identical elements — position-derived, will shift "
            + "if the container reorders; re-look before acting on it"
    }
    public static func token(fingerprint: String) -> String {
        base36(fnv1a64(fingerprint), length: tokenLength)
    }
    /// Document-order suffixes disambiguate repeated tokens.
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
/// Paths preserve observed topology; identity drift refuses execution and requires a fresh look.
public struct MacLookAffordance: Sendable, Equatable {
    public let handle: String
    public let role: String
    public let subrole: String?
    public let label: String
    /// Unlabeled controls retain handles and role ordinals rather than invented names.
    public let labelSource: String
    public let value: String?
    public let secret: Bool
    public let enabled: Bool?
    public let selected: Bool?
    public let state: String?
    public let frame: MacAXFrame?
    public let path: [Int]
    /// Reuse full-context compiler redaction verbatim; hand-built affordances receive caption-less legend redaction.
    public let labelJSON: JSONValue?
    public let valueJSON: JSONValue?
    /// Indistinguishable siblings remain actionable, with position-derived identity stated explicitly.
    public let handleAmbiguity: String?
    public var handleAmbiguous: Bool { handleAmbiguity != nil }
    /// Placeholder aliases retain the same compile-time redaction as labels.
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
        enabled: Bool? = nil,
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
    /// Glances omit withheld labels; they never disclose a digest as prose.
    public var displayLabel: String? {
        MacPerceptionCompiler.displayText(label, json: labelJSON)
    }
    /// Serialization shares legend secret handling and honors compiler-supplied group and nearby-caption context.
    public func toJSON(valueChars: Int = MacPerceptionCompiler.affordanceValueChars) -> JSONValue {
        var object: [String: JSONValue] = [
            "handle": .string(handle),
            "role": .string(role),
            "label": labelJSON
                ?? MacScreenViewTextRedaction.redactedLegendString(label, valueChars: valueChars),
            "label_source": .string(labelSource),
            "enabled": enabled.map(JSONValue.bool) ?? .null,
            "path": .array(path.map { .int(Int64($0)) }),
        ]
        if let subrole { object["subrole"] = .string(subrole) }
        if let placeholder {
            object["placeholder"] = placeholderJSON
                ?? MacScreenViewTextRedaction.redactedLegendString(placeholder, valueChars: valueChars)
        }
        // Retain AX geometry so a separately capped view cannot strip a named target’s physical point.
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
public struct MacLookReadout: Sendable, Equatable {
    /// Path records topology even when no handle was minted.
    public let handle: String?
    public let role: String
    public let text: String
    public let source: String
    public let path: [Int]
    /// Focused-subtree and sibling readouts are likely evidence of the act’s result.
    public let nearFocus: Bool
    public let inModal: Bool
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
    /// Prose prints only approved clear text, never a digest.
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
/// Landmarks let callers name structural regions without reading a tree.
public struct MacLookLandmark: Sendable, Equatable {
    public let kind: String
    public let role: String
    public let label: String?
    /// Depth matches the reader’s one-based convention.
    public let depth: Int
    public let path: [Int]
    public let frame: MacAXFrame?
    public let enabled: Bool?
    /// Preserve full-context label redaction; absent compiler context uses the legend redactor.
    public let labelJSON: JSONValue?
    public init(
        kind: String,
        role: String,
        label: String?,
        depth: Int,
        path: [Int],
        frame: MacAXFrame? = nil,
        labelJSON: JSONValue? = nil,
        enabled: Bool? = nil
    ) {
        self.kind = kind
        self.role = role
        self.label = label
        self.depth = depth
        self.path = path
        self.frame = frame
        self.labelJSON = labelJSON
        self.enabled = enabled
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
/// Modals constrain other controls and therefore need their own glance line.
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
    public let enabled: Bool?
    public init(role: String, label: String?, handle: String?, path: [Int], labelJSON: JSONValue? = nil, selectionRange: NSRange? = nil, enabled: Bool? = nil) {
        self.role = role
        self.label = label
        self.handle = handle
        self.path = path
        self.labelJSON = labelJSON
        self.selectionRange = selectionRange
        self.enabled = enabled
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
public struct MacLookPercept: Sendable, Equatable {
    public let app: MacAXAppInfo?
    public let windowTitle: String?
    public let focus: MacLookFocus?
    public let modal: MacLookModal?
    public let landmarks: [MacLookLandmark]
    public let affordances: [MacLookAffordance]
    /// Compact projections need the same unlabeled-control census as retained affordances.
    public let unlabeledByRole: [String: Int]
    /// Count affordance-cap omissions separately from serialization’s byte-budget omissions.
    public let affordancesOmitted: Int
    public let interactiveCount: Int
    public let labeledCount: Int
    // Propagate truncation so absence cannot imply complete coverage.
    public let truncated: Bool
    public let truncationReasons: [String]
    public let skippedAtLeast: Int
    public let readFailures: [String]
    /// Preserve full-context title redaction; absent compiler context uses the legend redactor.
    public let windowTitleJSON: JSONValue?
    public let readouts: [MacLookReadout]
    /// Count readout-cap omissions before serialization applies its byte budget.
    public let readoutsOmitted: Int
    /// Count ordinal handles so position-derived identity is disclosed once per payload.
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
        readFailures: [String] = [],
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
        self.readFailures = readFailures
        self.truncated = truncated
        self.truncationReasons = truncationReasons
        self.skippedAtLeast = skippedAtLeast
        self.windowTitleJSON = windowTitleJSON
    }
    /// Glances are smaller with the same redaction: withheld text stays absent, never a digest. Acts may lead with changed readouts; plain looks preserve
    /// ranked ordering.
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
    /// Budget the complete envelope and account for every omitted row.
    public func lookJSON(
        byteBudget: Int = MacPerceptionCompiler.lookByteBudget,
        valueChars: Int = MacPerceptionCompiler.affordanceValueChars,
        envelope: ([String: JSONValue]) -> [String: JSONValue]
    ) throws -> JSONValue {
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
        ) throws -> JSONValue {
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
                "read_failures": .array(readFailures.map(JSONValue.string)),
                "skipped_at_least": .int(Int64(skippedAtLeast)),
                // Readouts need the same omission accounting as controls.
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
            let perceptBytes = try size(.object(object))
            object = envelope(object)
            object["percept_bytes"] = .int(Int64(perceptBytes))
            object["bytes"] = .int(0)
            while true {
                let bytes = try size(.object(object))
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
        func size(_ value: JSONValue) throws -> Int {
            try value.serializedData(pretty: false).count
        }
        var json = try render(
            rows, readoutRows, truncatedForBytes: false, dropped: 0, readoutsDropped: 0
        )
        // Drop from the longer list's tail; ties give way to affordances.
        while try size(json) > byteBudget, !(rows.isEmpty && readoutRows.isEmpty) {
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
            json = try render(
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
