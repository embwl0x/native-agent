import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MacScreenRender.swift` | `MacScreenText` and `MacScreenRender`: shared semantic/pixel screen formatting that preserves compiler redaction verdicts |

// Shared screen evidence and pixel formatting for MacScreenPageCompiler.
// Text carries the compiler's redaction verdict through both presentations.

// MARK: - The one text channel

/// A string on its way to the screen render, carrying the redactor's verdict
/// with it.
///
/// `redacted` is the JSON the compiler already produced under the FULL node
/// context (standalone shape, the control's own caption, the enclosing
/// secret-naming group, the caption beside/above) — `.string` when redaction
/// let the text through, the count+digest object when it withheld it. It is
/// the ONLY thing that decides what prints. When it is nil (a hand-built value,
/// or a source that has no compiler behind it) the shared standalone shape test
/// runs as the floor, so this type has no path that prints an unexamined
/// string.
public struct MacScreenText: Sendable, Equatable {
    public let raw: String
    public let redacted: JSONValue?

    public init(_ raw: String, redacted: JSONValue? = nil) {
        self.raw = raw
        self.redacted = redacted
    }

    /// The clear text, or nil when the redactor withheld it / there is nothing.
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

    /// True when the redactor examined this string and withheld it — as opposed
    /// to there being no string at all. The render says which.
    public var withheld: Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && display == nil
    }
}

// MARK: - The renderer

public enum MacScreenRender {

    // MARK: Provenance

    /// Where a row's evidence came from, and how sure that evidence is.
    ///
    /// A FIELD on the row, never a mode. AX omits a confidence because it is 1
    /// by construction — the app said so. Vision always prints one, because a
    /// vision row that hides its confidence is indistinguishable from a claim.
    public enum Provenance: Sendable, Equatable {
        case ax
        case vision(Double)

        /// `ax` or `vision 0.83`. Two decimals, non-localised, so the byte
        /// output is identical on every machine.
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

    /// One row of the dominant content. THE ORDINAL IS THE ADDRESS — it is
    /// assigned by the renderer, 1-based, in the order the rows arrive, so she
    /// can say "open 3" for a row whose label is ambiguous or absent.
    public struct Row: Sendable, Equatable {
        /// Private fusion metadata; never printed as a model-facing address.
        public let sourceAXPath: [Int]?
        public let label: MacScreenText?
        /// Extra columns, in the caller's order — a type ("folder"), a quantity,
        /// a price. Rendered as columns, not as prose.
        public let detail: [MacScreenText]
        public let provenance: Provenance
        /// Non-nil ⇒ this row ABSTAINS, with this reason. Printed, never dropped.
        public let abstain: String?

        /// A located physical point, not an understood semantic control. The
        /// act owner still rechecks visibility and authority before input.
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

    /// One actionable thing. Its state rides INLINE — `(disabled)`, `(empty)`,
    /// `(checked)`, `(selected)` — never in a parallel object the reader has to
    /// correlate.
    public struct Control: Sendable, Equatable {
        /// Private fusion metadata; never printed as a model-facing address.
        public let sourceAXPath: [Int]?
        public let label: MacScreenText
        /// The kind, in this renderer's fixed vocabulary (see `kindName`).
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

    /// A read-only value the screen SAYS — a status bar, a count, a total, an
    /// error.
    public struct Value: Sendable, Equatable {
        public let text: MacScreenText
        public let provenance: Provenance

        public init(text: MacScreenText, provenance: Provenance) {
            self.text = text
            self.provenance = provenance
        }
    }

    // MARK: Content

    /// The three content types. The section KEYWORD is the type, which is how a
    /// reader knows what kind of thing she is looking at before reading a row.
    ///
    /// `canvas` is the pixel surface. It distinguishes an unparsed extent from
    /// partial object/text evidence without claiming semantic understanding.
    public enum ContentKind: String, Sendable, Equatable, CaseIterable {
        case list
        case grid
        case canvas

        var keyword: String { rawValue.uppercased() }
        /// The noun for the retained row count.
        var noun: String {
            switch self {
            case .list: return "items"
            case .grid: return "cells"
            case .canvas: return "regions"
            }
        }
    }

    /// The pixel region. Its SIZE is mandatory in the render: "act
    /// physically" is not actionable without an extent.
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

    /// Section keyword column. Everything after it lines up, so a reader's eye
    /// finds SCREEN / WHERE / DO without parsing.
    static let keywordWidth = 8
    /// Indent for a row line, including room for a right-aligned 2-digit ordinal.
    static let rowIndent = 6
    static let labelColumn = 24
    static let detailColumn = 22
    /// What a withheld string prints as. Visibly absent — never the clear text,
    /// never a digest a reader could mistake for content.
    public static let redactedMarker = "⟨redacted⟩"
    /// What an unlabeled row prints as. The row still exists and is still
    /// addressable by its ordinal.
    public static let unlabeledMarker = "⟨unlabeled⟩"

    /// Add only independently recognized pixel evidence to the AX page. No
    /// second screen title, AX control census or repeated raw text channel.
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
            // CANVAS is a single honest sentence, and it must carry its extent:
            // "act physically" is not actionable without one.
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
                lines.append("        Target: canvas — move, hover, drag, hold, scroll. Drag endpoints may be 'left side of canvas' / 'right side of canvas'; covered points refuse.")
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
        // The abstain rides on the row itself, in place. Never a footnote, never
        // a dropped row: a refusal she cannot see is a guess.
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
    //
    // One map, both lanes. The vision lane guesses AX role names by contract
    // ("AXUnknown" + a low role confidence, never a guessed AXButton at 1.0), so
    // an AX row and a vision row naming the same role print the same word — the
    // vocabulary cannot fork between sources.

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

    /// A role in the renderer's vocabulary. An unmapped role degrades to its
    /// bare name rather than to a guess — an honest "AXFoo" beats a confident
    /// "button".
    public static func kindName(role: String) -> String {
        if let known = kindNames[role] { return known }
        let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return stripped.isEmpty ? "unknown" : stripped.replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression
        ).lowercased()
    }

    // MARK: - AX target classification

    /// Roles whose affordances are CONTENT rows rather than controls: the rows
    /// of a list, the cells of a table, the rename-in-place text field every
    /// file row publishes. Shape, never app.
    static let contentRowRoles: Set<String> = [
        "AXRow", "AXCell", "AXOutlineRow", "AXListItem",
    ]

    /// Landmark kinds whose CONTENTS are controls whatever their own role is —
    /// the compiler's `controlContainerRoles`, in the landmark vocabulary the
    /// percept publishes.
    static let controlContainerKinds: Set<String> = ["toolbar", "sheet", "dialog"]

    /// Keep the established unnamed-control addresses, then number duplicated
    /// names after them. Rendering and resolution consume this same assignment;
    /// a repeated label never forces the caller to guess the first match.
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
