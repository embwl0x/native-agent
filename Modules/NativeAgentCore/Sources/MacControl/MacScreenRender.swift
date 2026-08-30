import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - THE STRUCTURED SCREEN RENDERER (native-screen)
//
// docs/build_plans/native-screen.md, written from the consumer's seat: "she
// needs a live screen to look at… you're literally an LLM, you know exactly
// what you want to see." What she wants is not prose and not a tree — it is
// ONE canonical STRUCTURE, the same shape whether the window is Finder, a PDF,
// System Settings or World of Warcraft:
//
//     SCREEN  app · window · FRONT · how many others
//     WHERE   position inside the app's own navigation
//     LIST | GRID | TEXT | CANVAS   the dominant content, TYPED, numbered
//     DO      everything actionable, state inline
//     SAYS    the read-only values worth knowing
//
// Fixed sections, fixed ORDER, fixed vocabulary. An app that lacks a section
// OMITS it; it never renames it. Predictability is the whole value — she reads
// this every turn and must be able to find what she needs without reading all
// of it.
//
// ONE INTERPRETER, SOURCE-AGNOSTIC. User: "it interprets the screen, an app, WoW
// all the same." AX rows, vision rows, or BOTH FUSED enter the SAME function
// and come out as the same sections in the same order. Provenance and
// confidence are per-row FIELDS (`ax` / `vision 0.83`) — never a different
// shape, never a second code path a caller has to know about. There is exactly
// one `render` here and everything goes through it.
//
// NO APP-SPECIFIC LOGIC. Not one branch, heuristic or comment-as-rule in this
// file tests what app it is looking at (feedback_build_the_general_capability).
// A game is simply a screen whose dominant content types as CANVAS and whose
// rows carry vision provenance. The hard instance is the BAR, never the target.
//
// PURE. No I/O, no capture, no AX calls, no injection, no clock, no randomness:
// percept in, text out, byte-identical for byte-identical input. That is what
// makes it testable headless against three fixtures and what lets the wiring
// layer (not this file) decide when to call it.
//
// WHY IT REPLACES THE JSON SURFACE: today she gets JSON carrying opaque handle
// tokens plus a `frame_id` she must keep valid, and nine acceptance rounds show
// nearly every failure lived in that bookkeeping rather than in the work. So:
// NO HANDLE TOKENS ever reach this output. Handles stay our bookkeeping. She
// addresses a row by its ORDINAL (1-based, stable, printed) or by its label.
//
// TWO HONESTY RULES this renderer enforces mechanically, because both were
// earned the hard way:
//
//   • ELISION IS SPOKEN, IN PLACE. Every omission prints its count and its
//     recourse — "… 7 more below (scrollable)". A silent cap is what made her
//     work around us in round 8 ("capped looks can omit needed rows"); a caller
//     who cannot tell a complete list from a trimmed one will confidently
//     conclude a row does not exist.
//   • ABSTAINS ARE VISIBLE. A vision row that abstained prints as ABSTAINED
//     with its reason, in place, never dropped and never silently upgraded to a
//     guess. "Confidence labels don't create trust; calibrated refusal and
//     verified effects do."
//
// REDACTION IS NOT RE-IMPLEMENTED HERE. Every printed string comes from
// `MacScreenText`, whose `display` is the compiler's already-redacted verdict
// when there is one and the shared `MacScreenViewTextRedaction` standalone
// shape test when a value was hand-built. A withheld string prints as
// `⟨redacted⟩` — visibly absent, never a digest and never the clear text. Two
// redactors drift and the copy that drifts is the one nobody re-reviews.

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
        /// A one-based address within this visible role. Unlike content-row
        /// ordinals, unnamed controls are numbered per role: `button 2`,
        /// `tab 3`, and `text area 1` remain useful when AX supplied no name.
        /// It is part of the one screen representation, not a side channel for
        /// the act tool.
        public let ordinal: Int?
        /// What the control currently SHOWS, when that is different from its
        /// name — the popup labelled "View" reading "List". Printed inline as
        /// `popup = List`, because the pair is the fact she needs and a value
        /// in a parallel object is a correlation step.
        public let value: MacScreenText?
        public let states: [String]
        public let provenance: Provenance
        public let abstain: String?

        public init(
            label: MacScreenText,
            kind: String,
            ordinal: Int? = nil,
            value: MacScreenText? = nil,
            states: [String] = [],
            provenance: Provenance,
            abstain: String? = nil,
            sourceAXPath: [Int]? = nil
        ) {
            self.label = label
            self.kind = kind
            self.ordinal = ordinal
            self.value = value
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

    /// One step of WHERE — a path component, a selected tab, a breadcrumb, a
    /// selected sidebar item.
    public struct WhereStep: Sendable, Equatable {
        public let label: MacScreenText
        /// `selected`, `focused`, … printed in parentheses after the label.
        public let note: String?
        public let provenance: Provenance

        public init(label: MacScreenText, note: String? = nil, provenance: Provenance) {
            self.label = label
            self.note = note
            self.provenance = provenance
        }
    }

    // MARK: Content

    /// The four content types. The section KEYWORD is the type, which is how a
    /// reader knows what kind of thing she is looking at before reading a row.
    ///
    /// `canvas` is the pixel surface. It distinguishes an unparsed extent from
    /// partial object/text evidence without claiming semantic understanding.
    public enum ContentKind: String, Sendable, Equatable, CaseIterable {
        case list
        case grid
        case text
        case canvas

        var keyword: String { rawValue.uppercased() }
        /// Fixed section order among contents: type, not arrival. A screen with
        /// both a grid and a canvas prints them in the same order every time.
        var order: Int {
            switch self {
            case .list: return 0
            case .grid: return 1
            case .text: return 2
            case .canvas: return 3
            }
        }
        /// The default noun for the row count when the caller does not name one.
        var defaultNoun: String {
            switch self {
            case .list: return "items"
            case .grid: return "cells"
            case .text: return "lines"
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

        public init(
            description: String, width: Double, height: Double,
            provenance: Provenance, hasPerceptualEvidence: Bool = false
        ) {
            self.description = description
            self.width = width
            self.height = height
            self.provenance = provenance
            self.hasPerceptualEvidence = hasPerceptualEvidence
        }
    }

    public struct Content: Sendable, Equatable {
        public let kind: ContentKind
        /// What the rows ARE, for the count line. Defaults per kind.
        public let noun: String
        public let rows: [Row]
        /// How many rows EXIST, including any the source already dropped before
        /// this renderer saw them. The elision line is computed from this, so an
        /// upstream cap is spoken here too rather than silently disappearing.
        public let totalRows: Int
        public let scrollable: Bool
        public let canvas: Canvas?

        public init(
            kind: ContentKind,
            noun: String? = nil,
            rows: [Row] = [],
            totalRows: Int? = nil,
            scrollable: Bool = false,
            canvas: Canvas? = nil
        ) {
            self.kind = kind
            self.noun = noun ?? kind.defaultNoun
            self.rows = rows
            self.totalRows = max(totalRows ?? rows.count, rows.count)
            self.scrollable = scrollable
            self.canvas = canvas
        }
    }

    // MARK: The screen

    /// The source-agnostic input. AX, vision and fused percepts all become one
    /// of these, and this is the only thing `render` reads.
    public struct Screen: Sendable, Equatable {
        public let appName: String?
        public let windowTitle: MacScreenText?
        public let isFront: Bool
        /// OTHER windows of the same app — "how many others exist".
        public let otherWindows: Int
        public let provenance: Provenance
        public let modal: MacScreenText?
        public let whereSteps: [WhereStep]
        public let contents: [Content]
        public let controls: [Control]
        /// How many actionable things EXIST, including any the source dropped
        /// before this renderer saw them.
        public let totalControls: Int
        /// Interactive elements with NO label, by kind. Counted rather than
        /// hidden: pretending they are not there is how "the third button"
        /// becomes the wrong button.
        public let unlabeledControls: [String: Int]
        public let values: [Value]
        public let totalValues: Int
        /// Omitted AX affordances have no retained role or location evidence.
        /// They must not be relabeled as extra files/rows below the viewport.
        public let unclassifiedOmittedTargets: Int

        public init(
            appName: String?,
            windowTitle: MacScreenText? = nil,
            isFront: Bool = false,
            otherWindows: Int = 0,
            provenance: Provenance = .ax,
            modal: MacScreenText? = nil,
            whereSteps: [WhereStep] = [],
            contents: [Content] = [],
            controls: [Control] = [],
            totalControls: Int? = nil,
            unlabeledControls: [String: Int] = [:],
            values: [Value] = [],
            totalValues: Int? = nil,
            unclassifiedOmittedTargets: Int = 0
        ) {
            self.appName = appName
            self.windowTitle = windowTitle
            self.isFront = isFront
            self.otherWindows = max(0, otherWindows)
            self.provenance = provenance
            self.modal = modal
            self.whereSteps = whereSteps
            self.contents = contents
            self.controls = controls
            self.totalControls = max(totalControls ?? controls.count, controls.count)
            self.unlabeledControls = unlabeledControls
            self.values = values
            self.totalValues = max(totalValues ?? values.count, values.count)
            self.unclassifiedOmittedTargets = max(0, unclassifiedOmittedTargets)
        }
    }

    // MARK: Budget

    /// The render is BOUNDED and says what the bound cost. Every cap here has a
    /// matching elision line in the output — there is no cap in this file that
    /// can bite silently.
    public struct Options: Sendable, Equatable {
        /// Rows kept per content section.
        public let maxRows: Int
        public let maxControls: Int
        public let maxValues: Int
        public let maxWhereSteps: Int
        /// A label longer than this is truncated with an ellipsis. Column
        /// discipline, not redaction.
        public let maxLabelChars: Int

        public init(
            maxRows: Int = 12,
            maxControls: Int = 24,
            maxValues: Int = 6,
            maxWhereSteps: Int = 6,
            maxLabelChars: Int = 40
        ) {
            self.maxRows = max(1, maxRows)
            self.maxControls = max(1, maxControls)
            self.maxValues = max(1, maxValues)
            self.maxWhereSteps = max(1, maxWhereSteps)
            self.maxLabelChars = max(8, maxLabelChars)
        }

        public static let `default` = Options()
    }

    /// What the render cost and what it dropped. The drops are ALSO in the text
    /// — this struct is for the caller's telemetry, never a substitute for
    /// saying it in place.
    public struct Rendering: Sendable, Equatable {
        public let text: String
        public let bytes: Int
        public let rowsDropped: Int
        public let controlsDropped: Int
        public let valuesDropped: Int
        public let abstained: Int

        public init(
            text: String,
            bytes: Int,
            rowsDropped: Int,
            controlsDropped: Int,
            valuesDropped: Int,
            abstained: Int
        ) {
            self.text = text
            self.bytes = bytes
            self.rowsDropped = rowsDropped
            self.controlsDropped = controlsDropped
            self.valuesDropped = valuesDropped
            self.abstained = abstained
        }
    }

    // MARK: Layout constants

    /// Section keyword column. Everything after it lines up, so a reader's eye
    /// finds SCREEN / WHERE / DO without parsing.
    static let keywordWidth = 8
    /// Indent for a row line, including room for a right-aligned 2-digit
    /// content ordinal. A role address such as `button 2` may exceed this
    /// width and deliberately shifts the label rather than hiding the address.
    static let rowIndent = 6
    static let labelColumn = 24
    static let detailColumn = 22
    /// What a withheld string prints as. Visibly absent — never the clear text,
    /// never a digest a reader could mistake for content.
    public static let redactedMarker = "⟨redacted⟩"
    /// What an unlabeled row prints as. The row still exists and is still
    /// addressable by its ordinal.
    public static let unlabeledMarker = "⟨unlabeled⟩"

    // MARK: - The one entry point

    /// Render ONE screen. Deterministic: same input, byte-identical output.
    public static func render(_ screen: Screen, options: Options = .default) -> String {
        rendering(screen, options: options).text
    }

    /// The same render, with the budget accounting the caller may want to log.
    public static func rendering(_ screen: Screen, options: Options = .default) -> Rendering {
        var lines: [String] = []
        var rowsDropped = 0
        var controlsDropped = 0
        var valuesDropped = 0
        var abstained = 0

        // SCREEN — where am I, before anything else.
        lines.append(screenLine(screen))

        // WHERE — position inside the app's own navigation. Absent when the
        // source could not tell us; NEVER guessed, and never renamed.
        if !screen.whereSteps.isEmpty {
            let kept = Array(screen.whereSteps.prefix(options.maxWhereSteps))
            let hidden = screen.whereSteps.count - kept.count
            var rendered = kept.map { step -> String in
                var part = step.label.display ?? (step.label.withheld ? redactedMarker : unlabeledMarker)
                if let note = step.note, !note.isEmpty { part += " (\(note))" }
                return part
            }.joined(separator: " > ")
            // One provenance for the path: the WEAKEST step, because a path is
            // only as trustworthy as its shakiest component.
            if let weakest = weakestProvenance(kept.map(\.provenance)), weakest.isVision {
                rendered += "  " + weakest.text
            }
            if hidden > 0 {
                rendered += "  … \(hidden) earlier step\(hidden == 1 ? "" : "s") not shown "
                    + "(raise maxWhereSteps)"
            }
            lines.append(section("WHERE", rendered))
        }

        // MODAL — it changes what every other control means, so it is stated
        // before the content rather than buried among the controls.
        if let modal = screen.modal {
            lines.append(section("MODAL", modal.display ?? redactedMarker))
        }

        // The dominant content, TYPED. Fixed order by TYPE so a screen with more
        // than one never reorders between turns.
        if screen.unclassifiedOmittedTargets > 0 {
            lines.append(section("LIMITS", "Semantic read omitted \(screen.unclassifiedOmittedTargets) AX targets; types/locations unknown."))
        }
        for content in screen.contents.sorted(by: { $0.kind.order < $1.kind.order }) {
            let block = contentBlock(content, options: options)
            lines.append(contentsOf: block.lines)
            rowsDropped += block.dropped
            abstained += block.abstained
        }

        // DO — everything actionable.
        if !screen.controls.isEmpty || screen.totalControls > 0 || !screen.unlabeledControls.isEmpty {
            let block = controlBlock(screen, options: options)
            lines.append(contentsOf: block.lines)
            controlsDropped = block.dropped
            abstained += block.abstained
        }

        // SAYS — the read-only values.
        if !screen.values.isEmpty || screen.totalValues > 0 {
            let block = valueBlock(screen, options: options)
            lines.append(contentsOf: block.lines)
            valuesDropped = block.dropped
        }

        let text = lines.joined(separator: "\n") + "\n"
        return Rendering(
            text: text,
            bytes: text.utf8.count,
            rowsDropped: rowsDropped,
            controlsDropped: controlsDropped,
            valuesDropped: valuesDropped,
            abstained: abstained
        )
    }

    // MARK: - Sections

    private static func screenLine(_ screen: Screen) -> String {
        var parts: [String] = [screen.appName ?? "unknown app"]
        if let title = screen.windowTitle {
            if let display = title.display {
                parts.append("window \"\(display)\"")
            } else if title.withheld {
                parts.append("window \(redactedMarker)")
            }
        }
        parts.append(screen.isFront ? "FRONT" : "not front")
        if screen.otherWindows > 0 {
            parts.append("\(screen.otherWindows) other window\(screen.otherWindows == 1 ? "" : "s")")
        }
        var line = parts.joined(separator: " · ")
        if screen.provenance.isVision { line += "  " + screen.provenance.text }
        return section("SCREEN", line)
    }

    private struct Block {
        var lines: [String] = []
        var dropped = 0
        var abstained = 0
    }

    private static func contentBlock(_ content: Content, options: Options) -> Block {
        var block = Block()

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
            block.lines.append(section(content.kind.keyword, line))
            return block
        }

        let kept = Array(content.rows.prefix(options.maxRows))
        // Rows this renderer dropped PLUS rows the source dropped before it.
        let hidden = content.totalRows - kept.count
        block.dropped = hidden

        var header = "\(content.totalRows) \(content.noun)"
        if hidden > 0 { header += ", showing \(kept.count)" }
        block.lines.append(section(content.kind.keyword, header))

        for (index, row) in kept.enumerated() {
            block.lines.append(rowLine(ordinal: index + 1, row: row, options: options))
            if row.abstain != nil { block.abstained += 1 }
        }
        if hidden > 0 {
            // Spoken, in place, with the recourse. A silent cap is the exact
            // thing this renderer exists to stop.
            let recourse = content.scrollable ? "scrollable" : "raise maxRows"
            block.lines.append(indentedNote("… \(hidden) more below (\(recourse))"))
        }
        return block
    }

    private static func controlBlock(_ screen: Screen, options: Options) -> Block {
        var block = Block()
        let kept = Array(screen.controls.prefix(options.maxControls))
        let hidden = screen.totalControls - kept.count
        block.dropped = hidden
        block.abstained = kept.filter { $0.abstain != nil }.count

        var header = "\(screen.totalControls) actionable"
        if hidden > 0 { header += ", showing \(kept.count)" }
        if block.abstained > 0 { header += ", \(block.abstained) ABSTAINED" }
        block.lines.append(section("DO", header))

        for control in kept {
            var detail = control.kind
            if let value = control.value {
                detail += " = " + (value.display ?? redactedMarker)
            }
            if !control.states.isEmpty {
                detail += " (" + control.states.joined(separator: ", ") + ")"
            }
            block.lines.append(rowLine(
                ordinal: nil,
                roleAddress: control.ordinal.map { "\(control.kind) \($0)" },
                row: Row(
                    label: control.label,
                    detail: [MacScreenText(detail, redacted: .string(detail))],
                    provenance: control.provenance,
                    abstain: control.abstain
                ),
                options: options
            ))
        }
        if hidden > 0 {
            let observedHidden = max(0, screen.controls.count - kept.count)
            if observedHidden > 0 {
                block.lines.append(indentedNote("… \(observedHidden) observed controls not shown (screen part: controls, or name a control)"))
            }
            let unavailable = max(0, hidden - observedHidden)
            if unavailable > 0 {
                block.lines.append(indentedNote("… \(unavailable) further controls outside this observation; inspect the relevant visible region"))
            }
        }
        // The unlabeled census. Sorted by kind so the bytes are identical every
        // run; counted rather than hidden, because an unnamed control she cannot
        // address is still a control that exists.
        let unlabeled = screen.unlabeledControls.filter { $0.value > 0 }
        if !unlabeled.isEmpty {
            let total = unlabeled.values.reduce(0, +)
            let breakdown = unlabeled
                .sorted { $0.key == $1.key ? false : $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            block.lines.append(indentedNote(
                "… \(total) unlabeled (\(breakdown)) — not addressable by name, point by region"
            ))
        }
        return block
    }

    private static func valueBlock(_ screen: Screen, options: Options) -> Block {
        var block = Block()
        let kept = Array(screen.values.prefix(options.maxValues))
        let hidden = screen.totalValues - kept.count
        block.dropped = hidden

        var header = "\(screen.totalValues) value\(screen.totalValues == 1 ? "" : "s")"
        if hidden > 0 { header += ", showing \(kept.count)" }
        block.lines.append(section("SAYS", header))

        for value in kept {
            let shown = value.text.display.map { "\"\(truncate($0, to: options.maxLabelChars * 2))\"" }
                ?? redactedMarker
            var line = pad(String(repeating: " ", count: rowIndent) + shown, to: rowIndent + labelColumn + detailColumn + 2)
            line += value.provenance.text
            block.lines.append(trimTrailing(line))
        }
        if hidden > 0 {
            let observedHidden = max(0, screen.values.count - kept.count)
            if observedHidden > 0 {
                block.lines.append(indentedNote("… \(observedHidden) observed readouts not shown (screen part: hud, or name a readout)"))
            }
            let unavailable = max(0, hidden - observedHidden)
            if unavailable > 0 {
                block.lines.append(indentedNote("… \(unavailable) further values outside this observation; inspect the relevant visible region"))
            }
        }
        return block
    }

    // MARK: - Lines

    private static func rowLine(
        ordinal: Int?,
        roleAddress: String? = nil,
        row: Row,
        options: Options
    ) -> String {
        var line = ordinal.map { pad("  \($0)", to: rowIndent) }
            ?? roleAddress.map { pad($0, to: rowIndent) }
            ?? String(repeating: " ", count: rowIndent)

        let label: String
        if let text = row.label {
            label = text.display.map { truncate($0, to: options.maxLabelChars) }
                ?? (text.withheld ? redactedMarker : unlabeledMarker)
        } else {
            label = unlabeledMarker
        }
        line = pad(line + label, to: rowIndent + labelColumn)

        let detail = row.detail
            .map { $0.display.map { truncate($0, to: options.maxLabelChars) } ?? redactedMarker }
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

    private static func indentedNote(_ text: String) -> String {
        String(repeating: " ", count: rowIndent - 4) + text
    }

    // MARK: - Formatting primitives

    static func pad(_ text: String, to width: Int) -> String {
        let count = text.count
        guard count < width else { return text + " " }
        return text + String(repeating: " ", count: width - count)
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)) + "…"
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

    /// The least-confident of a set. AX is 1 by construction, so a path made of
    /// AX steps has no confidence to print; one vision step drags the whole path
    /// down to its number.
    static func weakestProvenance(_ all: [Provenance]) -> Provenance? {
        guard !all.isEmpty else { return nil }
        var weakest: Provenance = .ax
        var weakestValue = 1.0
        for item in all {
            let value: Double
            switch item {
            case .ax: value = 1
            case .vision(let confidence): value = confidence.isFinite ? min(1, max(0, confidence)) : 0
            }
            if value < weakestValue {
                weakestValue = value
                weakest = item
            }
        }
        return weakest
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
        return stripped.isEmpty ? "unknown" : stripped.lowercased()
    }

    // MARK: - The AX adapter
    //
    // A `MacLookPercept` — whatever produced it — becomes a `Screen`. This is a
    // TRANSLATION, not a second renderer: it fills the same neutral model the
    // vision lane fills, and the output goes through the one `render` above.
    // The vision lane's own adapter lives in VisionPerception (which depends on
    // MacControl, not the reverse) and fills this same model.

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

    public static func screen(
        from percept: MacLookPercept,
        isFront: Bool = false,
        otherWindows: Int = 0
    ) -> Screen {
        var controls: [Control] = []
        var rows: [Row] = []

        // The same two families the compiler already ranks by: a control ROLE,
        // or anything sitting inside a control CONTAINER (a toolbar, a sheet).
        // The container test is what keeps a toolbar's search field in DO
        // instead of filing it as a list row — the field is a control because of
        // where it lives, and the percept states where it lives.
        let controlContainerPaths = percept.landmarks
            .filter { controlContainerKinds.contains($0.kind) }
            .map(\.path)
        func insideControlContainer(_ path: [Int]) -> Bool {
            controlContainerPaths.contains { container in
                container.count < path.count && Array(path.prefix(container.count)) == container
            }
        }

        func isControl(_ affordance: MacLookAffordance) -> Bool {
            !contentRowRoles.contains(affordance.role)
                && (MacPerceptionCompiler.controlRoles.contains(affordance.role)
                    || insideControlContainer(affordance.path))
        }
        let controlOrdinals = controlRoleOrdinals(for: percept.affordances.filter(isControl))
        for affordance in percept.affordances {
            let label = MacScreenText(affordance.label, redacted: affordance.labelJSON)
            if isControl(affordance) {
                let kind = kindName(role: affordance.role)
                let ordinal = controlOrdinals[affordance.handle]
                var states: [String] = []
                if !affordance.enabled { states.append("disabled") }
                if affordance.selected == true { states.append("selected") }
                if affordance.secret { states.append("secure") }
                if isTextEntry(affordance.role), affordance.value == nil { states.append("empty") }
                controls.append(Control(
                    label: label,
                    kind: kind,
                    ordinal: ordinal,
                    value: affordance.value.map { MacScreenText($0, redacted: affordance.valueJSON) },
                    states: states,
                    provenance: .ax,
                    sourceAXPath: affordance.path
                ))
            } else {
                var detail: [MacScreenText] = [
                    MacScreenText(kindName(role: affordance.role),
                                  redacted: .string(kindName(role: affordance.role))),
                ]
                if let value = affordance.value {
                    detail.append(MacScreenText(value, redacted: affordance.valueJSON))
                }
                if affordance.selected == true {
                    detail.append(MacScreenText("selected", redacted: .string("selected")))
                }
                rows.append(Row(label: label, detail: detail, provenance: .ax, sourceAXPath: affordance.path))
            }
        }

        // The wire's omission count also includes byte-budget truncation and
        // does not retain the omitted roles/locations. Report that limit once,
        // without inventing extra rows or claiming they are below the viewport.
        var contents: [Content] = []
        if !rows.isEmpty {
            let landmarkKinds = Set(percept.landmarks.map(\.kind))
            contents.append(Content(
                kind: landmarkKinds.contains("table") ? .grid : .list,
                rows: rows,
                totalRows: rows.count,
                scrollable: landmarkKinds.contains("scrollarea")
                    || landmarkKinds.contains("list")
                    || landmarkKinds.contains("table")
                    || landmarkKinds.contains("sidebar")
            ))
        }

        return Screen(
            appName: percept.app?.name,
            windowTitle: percept.windowTitle.map {
                MacScreenText($0, redacted: percept.windowTitleJSON)
            },
            isFront: isFront,
            otherWindows: otherWindows,
            provenance: .ax,
            modal: percept.modal?.label.map { MacScreenText($0, redacted: percept.modal?.labelJSON) },
            whereSteps: whereSteps(from: percept),
            contents: contents,
            controls: controls,
            totalControls: controls.count,
            // The compiler now retains unnamed interactive affordances so
            // their role ordinals can be rendered and resolved. A census still
            // exists for older/external percept producers that genuinely omit
            // elements, but must not repeat controls already shown above.
            unlabeledControls: [:],
            values: percept.readouts.map {
                Value(text: MacScreenText($0.text, redacted: $0.textJSON), provenance: .ax)
            },
            totalValues: percept.readouts.count + percept.readoutsOmitted,
            unclassifiedOmittedTargets: percept.affordancesOmitted
        )
    }

    /// WHERE, from the structure the percept actually has: the landmarks the
    /// FOCUS sits inside, outermost first, then the focused element itself.
    /// That is a real position in the app's own navigation, derived from data.
    /// When there is no focus there is no position to state, and the section is
    /// OMITTED rather than guessed at — a WHERE that invents a location is worse
    /// than no WHERE at all.
    static func whereSteps(from percept: MacLookPercept) -> [WhereStep] {
        guard let focus = percept.focus else { return [] }
        var steps: [WhereStep] = []
        let ancestors = percept.landmarks
            .filter { landmark in
                landmark.path.count < focus.path.count
                    && Array(focus.path.prefix(landmark.path.count)) == landmark.path
            }
            .sorted { $0.path.count < $1.path.count }
        for landmark in ancestors {
            let name = landmark.label.map { MacScreenText($0, redacted: landmark.labelJSON) }
            steps.append(WhereStep(
                label: name ?? MacScreenText(landmark.kind, redacted: .string(landmark.kind)),
                note: name == nil ? nil : landmark.kind,
                provenance: .ax
            ))
        }
        if let label = focus.label {
            steps.append(WhereStep(
                label: MacScreenText(label, redacted: focus.labelJSON),
                note: "focused",
                provenance: .ax
            ))
        }
        return steps
    }

    static func isTextEntry(_ role: String) -> Bool {
        role == "AXTextField" || role == "AXTextArea" || role == "AXSecureTextField"
            || role == "AXComboBox"
    }
}
