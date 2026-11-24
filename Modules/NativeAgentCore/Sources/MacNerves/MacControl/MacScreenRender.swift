import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MacScreenRender.swift` | `MacScreenText`, `MacScreenRender`: Shared semantic/pixel formatting retains compiler redaction |

// Both presentations must preserve the compiler’s text redaction verdict.

// MARK: - The one text channel

/// Only full-context redacted JSON decides what prints; absent compiler context still requires the standalone shape check.
public struct MacScreenText: Sendable, Equatable {
    public let raw: String
    public let redacted: JSONValue?

    public init(_ raw: String, redacted: JSONValue? = nil) {
        self.raw = raw
        self.redacted = redacted
    }

    public var display: String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let redacted {
            if case .string(let clear) = redacted {
                let cleared = clear.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleared.isEmpty ? nil : cleared
            }
            return nil
        }
        guard MacScreenViewTextRedaction.standaloneSecretReason(trimmed) == nil else { return nil }
        return trimmed
    }

    /// Withheld text differs from absent text and must render that distinction.
    public var withheld: Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && display == nil
    }
}

// MARK: - The renderer

public enum MacScreenRender {

    // MARK: Provenance

    /// Confidence belongs on each row: AX speaks authoritatively, while vision must disclose uncertainty.
    public enum Provenance: Sendable, Equatable {
        case ax
        case vision(Double)

        /// Nonlocalized confidence formatting keeps output deterministic across machines.
        public var text: String {
            switch self {
            case .ax:
                return "ax"
            case .vision(let confidence):
                let clamped = confidence.isFinite ? min(1, max(0, confidence)) : 0
                return "vision " + String(format: "%.2f", clamped)
            }
        }

        var isVision: Bool {
            if case .vision = self { return true }
            return false
        }
    }

    // MARK: Rows

    /// Rendered one-based ordinals are addresses, letting callers select ambiguous or unnamed rows.
    public struct Row: Sendable, Equatable {
        /// Private fusion metadata; never printed as a model-facing address.
        public let sourceAXPath: [Int]?
        public let label: MacScreenText?
        /// Preserve caller column order so values remain associated with their headings.
        public let detail: [MacScreenText]
        public let provenance: Provenance
        /// Render abstention in place rather than dropping the row.
        public let abstain: String?

        /// Located pixels do not imply semantic understanding; the act still rechecks visibility and authority.
        public let physicalOnly: Bool

        public init(
            label: MacScreenText?,
            detail: [MacScreenText] = [],
            provenance: Provenance,
            abstain: String? = nil,
            sourceAXPath: [Int]? = nil,
            physicalOnly: Bool = false
        ) {
            self.label = label
            self.detail = detail
            self.provenance = provenance
            self.abstain = abstain
            self.sourceAXPath = sourceAXPath
            self.physicalOnly = physicalOnly
        }
    }

    /// Render state inline so readers need not correlate a parallel state object.
    public struct Control: Sendable, Equatable {
        /// Private fusion metadata; never printed as a model-facing address.
        public let sourceAXPath: [Int]?
        public let label: MacScreenText
        public let kind: String
        public let states: [String]
        public let provenance: Provenance
        public let abstain: String?

        public init(
            label: MacScreenText,
            kind: String,
            states: [String] = [],
            provenance: Provenance,
            abstain: String? = nil,
            sourceAXPath: [Int]? = nil
        ) {
            self.label = label
            self.kind = kind
            self.states = states
            self.provenance = provenance
            self.abstain = abstain
            self.sourceAXPath = sourceAXPath
        }
    }

    public struct Value: Sendable, Equatable {
        public let text: MacScreenText
        public let provenance: Provenance

        public init(text: MacScreenText, provenance: Provenance) {
            self.text = text
            self.provenance = provenance
        }
    }

    // MARK: Content

    /// Section keywords identify content kind; canvas distinguishes unparsed extent from partial evidence without claiming understanding.
    public enum ContentKind: String, Sendable, Equatable, CaseIterable {
        case list
        case grid
        case canvas

        var keyword: String { rawValue.uppercased() }
        var noun: String {
            switch self {
            case .list: return "items"
            case .grid: return "cells"
            case .canvas: return "regions"
            }
        }
    }

    /// Physical action needs the pixel region’s extent, so size is mandatory.
    public struct Canvas: Sendable, Equatable {
        public let description: String
        public let width: Double
        public let height: Double
        public let provenance: Provenance
        public let hasPerceptualEvidence: Bool
        public let hasRegionTarget: Bool

        public init(
            description: String, width: Double, height: Double,
            provenance: Provenance, hasPerceptualEvidence: Bool = false,
            hasRegionTarget: Bool = false
        ) {
            self.description = description
            self.width = width
            self.height = height
            self.provenance = provenance
            self.hasPerceptualEvidence = hasPerceptualEvidence
            self.hasRegionTarget = hasRegionTarget
        }
    }

    public struct Content: Sendable, Equatable {
        public let kind: ContentKind
        public let rows: [Row]
        public let canvas: Canvas?

        public init(
            kind: ContentKind,
            rows: [Row] = [],
            canvas: Canvas? = nil
        ) {
            self.kind = kind
            self.rows = rows
            self.canvas = canvas
        }
    }

    // MARK: Layout constants

    /// Aligned keywords let readers scan sections without parsing their content.
    static let keywordWidth = 8
    /// Reserve room for right-aligned two-digit ordinals.
    static let rowIndent = 6
    static let labelColumn = 24
    static let detailColumn = 22
    /// Withheld text must look absent, never like a digest that could be mistaken for content.
    public static let redactedMarker = "⟨redacted⟩"
    /// Unlabeled rows stay visible and addressable by ordinal.
    public static let unlabeledMarker = "⟨unlabeled⟩"

    /// Add independent pixel evidence without duplicating AX titles, censuses or raw text.
    static func pixelEvidence(contents: [Content] = [], controls: [Control] = [], values: [Value] = []) -> String {
        var lines: [String] = []
        for content in contents {
            let rows = content.rows.filter { $0.provenance.isVision }
            guard !rows.isEmpty || content.kind == .canvas else { continue }
            let onlyPixels = Content(kind: content.kind, rows: rows, canvas: content.canvas)
            lines.append(contentsOf: contentBlock(onlyPixels))
        }
        let controls = controls.filter { $0.provenance.isVision }
        let values = values.filter { $0.provenance.isVision }
        if !controls.isEmpty { lines.append(contentsOf: controlBlock(controls)) }
        if !values.isEmpty { lines.append(contentsOf: valueBlock(values)) }
        guard !lines.isEmpty else { return "" }
        return "\nraw view · on-device screen recognition · These regions are exposed as pixels, with the recognition confidence shown.\n"
            + lines.joined(separator: "\n")
    }

    // MARK: - Sections

    private static func contentBlock(_ content: Content) -> [String] {
        var lines: [String] = []

        guard content.kind != .canvas else {
            // Canvas descriptions need an extent to make physical action meaningful.
            var line: String
            if let canvas = content.canvas {
                let size = "\(integer(canvas.width))x\(integer(canvas.height))"
                let described = canvas.description.trimmingCharacters(in: .whitespacesAndNewlines)
                line = (described.isEmpty ? "region" : described)
                    + ", \(size) — "
                    + (canvas.hasPerceptualEvidence
                        ? "partial vision; use listed targets, roles may be uncertain"
                        : "not interpreted, act physically")
                if canvas.provenance.isVision { line += "  " + canvas.provenance.text }
            } else {
                line = "region, size unknown — not interpreted, act physically"
            }
            lines.append(section(content.kind.keyword, line))
            if content.canvas?.hasRegionTarget == true {
                lines.append(
                    """
                                Target: canvas — move, hover, drag, hold, scroll. Drag endpoints may be 'left side of canvas' / 'right side of canvas'; \
                        covered points refuse.
                        """)
            }
            return lines
        }

        lines.append(section(content.kind.keyword, "\(content.rows.count) \(content.kind.noun)"))

        for (index, row) in content.rows.enumerated() {
            lines.append(rowLine(ordinal: index + 1, row: row))
        }
        return lines
    }

    private static func controlBlock(_ controls: [Control]) -> [String] {
        var lines: [String] = []
        let abstained = controls.filter { $0.abstain != nil }.count

        var header = "\(controls.count) actionable"
        if abstained > 0 { header += ", \(abstained) ABSTAINED" }
        lines.append(section("DO", header))

        for control in controls {
            var detail = control.kind
            if !control.states.isEmpty, !control.provenance.isVision {
                detail += " (" + control.states.joined(separator: ", ") + ")"
            }
            let details = [MacScreenText(detail, redacted: .string(detail))]
                + (control.provenance.isVision
                    ? control.states.map { MacScreenText($0, redacted: .string($0)) } : [])
            lines.append(rowLine(
                ordinal: nil,
                row: Row(
                    label: control.label,
                    detail: details,
                    provenance: control.provenance,
                    abstain: control.abstain
                )
            ))
        }
        return lines
    }

    private static func valueBlock(_ values: [Value]) -> [String] {
        var lines: [String] = []
        lines.append(section("SAYS", "\(values.count) value\(values.count == 1 ? "" : "s")"))

        for value in values {
            let shown = value.text.display.map { "\"\($0)\"" }
                ?? redactedMarker
            var line = pad(String(repeating: " ", count: rowIndent) + shown, to: rowIndent + labelColumn + detailColumn + 2)
            line += value.provenance.text
            lines.append(trimTrailing(line))
        }
        return lines
    }

    // MARK: - Lines

    private static func rowLine(
        ordinal: Int?,
        row: Row
    ) -> String {
        var line = ordinal.map { pad("  \($0)", to: rowIndent) }
            ?? String(repeating: " ", count: rowIndent)

        let label: String
        if let text = row.label {
            label = text.display
                ?? (text.withheld ? redactedMarker : unlabeledMarker)
        } else {
            label = unlabeledMarker
        }
        line = pad(line + label, to: rowIndent + labelColumn)

        let detail = row.detail
            .map { $0.display ?? redactedMarker }
            .joined(separator: "  ")
        line = pad(line + detail, to: rowIndent + labelColumn + detailColumn)

        line += "  " + row.provenance.text
        // Keep abstentions on their rows so uncertainty cannot be hidden as a missing observation.
        if let abstain = row.abstain, !abstain.isEmpty {
            line += "  ABSTAINED: " + abstain
        } else if row.physicalOnly {
            line += "  PHYSICAL ONLY: role uncertain"
        }
        return trimTrailing(line)
    }

    private static func section(_ keyword: String, _ payload: String) -> String {
        trimTrailing(pad(keyword, to: keywordWidth) + payload)
    }

    // MARK: - Formatting primitives

    static func pad(_ text: String, to width: Int) -> String {
        let count = text.count
        guard count < width else { return text + " " }
        return text + String(repeating: " ", count: width - count)
    }

    static func trimTrailing(_ text: String) -> String {
        var out = text
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    static func integer(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(Int(value.rounded()))
    }

    // MARK: - The fixed KIND vocabulary
    // AX and vision share one role vocabulary; guessed roles retain their confidence rather than impersonating certain AX evidence.

    static let kindNames: [String: String] = [
        "AXButton": "button",
        "AXMenuButton": "menu",
        "AXPopUpButton": "popup",
        "AXCheckBox": "checkbox",
        "AXRadioButton": "radio",
        "AXTab": "tab",
        "AXLink": "link",
        "AXMenuItem": "menu item",
        "AXComboBox": "combo",
        "AXSlider": "slider",
        "AXDisclosureTriangle": "disclosure",
        "AXIncrementor": "stepper",
        "AXTextField": "text",
        "AXSecureTextField": "secure text",
        "AXTextArea": "text area",
        "AXStaticText": "text",
        "AXHeading": "heading",
        "AXImage": "image",
        "AXRow": "row",
        "AXCell": "cell",
        "AXOutlineRow": "row",
        "AXListItem": "item",
        "AXWebArea": "web area",
        "AXScrollArea": "scroll area",
        "AXScrollBar": "scroll bar",
        "AXTable": "table",
        "AXOutline": "outline",
        "AXList": "list",
        "AXCollection": "collection",
        "AXUnknown": "unknown",
    ]

    /// Unmapped roles retain their names instead of becoming guessed controls.
    public static func kindName(role: String) -> String {
        if let known = kindNames[role] { return known }
        let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return stripped.isEmpty ? "unknown" : stripped.replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression
        ).lowercased()
    }

    // MARK: - AX target classification

    /// Content-row classification follows role structure rather than app identity.
    static let contentRowRoles: Set<String> = [
        "AXRow", "AXCell", "AXOutlineRow", "AXListItem",
    ]

    /// Landmark control-container kinds must agree with the compiler’s controlContainerRoles.
    static let controlContainerKinds: Set<String> = ["toolbar", "sheet", "dialog"]

    /// Rendering and resolution share ordinal assignment so duplicate labels remain addressable without guessing.
    static func controlRoleOrdinals(for controls: [MacLookAffordance]) -> [String: Int] {
        let identities = controls.map { control in
            (
                handle: control.handle,
                kind: kindName(role: control.role),
                label: MacScreenText(control.label, redacted: control.labelJSON).display.map(MacFourVerbs.normalize)
            )
        }
        var frequencies: [String: [String: Int]] = [:]
        for item in identities {
            if let label = item.label { frequencies[item.kind, default: [:]][label, default: 0] += 1 }
        }
        var next: [String: Int] = [:]
        var ordinals: [String: Int] = [:]
        func assign(_ handle: String, kind: String) {
            next[kind, default: 0] += 1
            ordinals[handle] = next[kind]
        }
        for item in identities where item.label == nil { assign(item.handle, kind: item.kind) }
        for item in identities {
            if let label = item.label, (frequencies[item.kind]?[label] ?? 0) > 1 {
                assign(item.handle, kind: item.kind)
            }
        }
        return ordinals
    }

}
