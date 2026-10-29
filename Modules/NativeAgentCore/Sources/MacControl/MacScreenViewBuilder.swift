import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Senses
import TrustCenter
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif
#if canImport(ScreenCaptureKit) && os(macOS)
import ScreenCaptureKit
#endif
#if canImport(AppKit)
import AppKit
import ApplicationServices
import UserNotifications
import Experiences
import CryptoKit
import os
#endif
// Blueprint: | `MacScreenViewBuilder.swift` | View and mark construction from captured geometry and accessibility |
public enum MacScreenViewBuilder {
    /// Hard ceilings. A 4K capture of a dense app can offer hundreds of
    /// actionable elements and ~10 MB of pixels; either one alone would eat the
    /// turn. A caller may lower these, never raise them.
    public static let hardMaxMarks = 60
    public static let hardMaxImageBytes = 600_000
    /// The prose channel is capped too: a document window can expose thousands
    /// of static-text nodes, and an unbounded dump would drown the legend it
    /// exists to complete.
    public static let hardMaxTextItems = 80
    public static let visualSurfaceRoles: Set<String> = ["AXImage", "AXCanvas"]
    /// The largest real visual surface worth giving its own pixel budget.
    /// Small icons are deliberately excluded: focusing them would discard the
    /// surrounding UI while adding no useful canvas/game perception.
    public static func dominantVisualSurface(
        nodes: [MacAXNode],
        geometry: MacScreenViewGeometry,
        minimumAreaFraction: Double = 0.03
    ) -> MacAXFrame? {
        let captureArea = geometry.bounds.w * geometry.bounds.h
        guard captureArea > 0 else { return nil }
        return nodes.compactMap { node -> MacAXFrame? in
            // WebKit can expose a painted canvas as a childless AXWebArea,
            // not AXImage/AXCanvas. Browser chrome is not evidence that the
            // page itself is readable. Inspect only this area's descendants;
            // ordinary semantic pages keep their existing no-OCR path.
            let emptyWebSurface = node.attributes.role == "AXWebArea"
                && !nodes.contains { child in
                    guard child.path.count > node.path.count,
                          child.path.starts(with: node.path) else { return false }
                    let attributes = child.attributes
                    if !attributes.actions.isEmpty || clickableRoles.contains(attributes.role) {
                        return true
                    }
                    return ["AXStaticText", "AXHeading"].contains(attributes.role)
                        && [attributes.title, attributes.value].compactMap { $0 }
                            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                }
            guard visualSurfaceRoles.contains(node.attributes.role) || emptyWebSurface,
                  let frame = node.attributes.frame,
                  frame.w > 0, frame.h > 0,
                  geometry.intersects(frame) else { return nil }
            let clippedW = max(0, min(frame.x + frame.w, geometry.bounds.x + geometry.bounds.w)
                - max(frame.x, geometry.bounds.x))
            let clippedH = max(0, min(frame.y + frame.h, geometry.bounds.y + geometry.bounds.h)
                - max(frame.y, geometry.bounds.y))
            guard clippedW * clippedH / captureArea >= minimumAreaFraction else { return nil }
            return frame
        }.max { lhs, rhs in lhs.w * lhs.h < rhs.w * rhs.h }
    }
    /// Nil means the accessibility read
    /// carries the window and no pixels are attached. A reason means the
    /// window is a canvas, a game, video, or an app that publishes almost
    /// nothing, and one small image of it earns its bytes. Real AppKit
    /// windows publish named controls or text and never reach a reason.
    public static func thinAccessibilityReason(
        accessibilityTrusted: Bool,
        marks: [JSONValue],
        texts: [JSONValue],
        windowArea: Double,
        canvasFraction: Double?,
        sourceTextCount: Int,
        sourceTextCharacters: Int
    ) -> String? {
        guard accessibilityTrusted else { return "no accessibility read" }
        // A dominant AXImage/AXCanvas (or childless AXWebArea) is unreadable
        // content even when its surrounding toolbar has plenty of words.
        // Chromium renderer reads are retained by the caller; window-wide
        // text counts can only grade windows without a dominant visual body.
        if (canvasFraction ?? 0) >= 0.5 { return "canvas" }
        if sourceTextCharacters >= 80 || sourceTextCount >= 4 { return nil }
        let visibleCharacters = texts.reduce(0) { total, value in
            guard case .object(let item) = value, case .string(let text)? = item["text"] else { return total }
            return total + text.count
        }
        if visibleCharacters >= 80 { return nil }
        let unnamedRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup",
                                         "AXLayoutArea", "AXUnknown", "AXWebArea"]
        let roles = marks.compactMap { value -> (role: String, named: Bool)? in
            guard case .object(let mark) = value, case .string(let role)? = mark["role"] else { return nil }
            let labeled: Bool = {
                switch mark["label"] {
                case .string(let text)?: return !text.trimmingCharacters(in: .whitespaces).isEmpty
                case .object?: return true
                default: return false
                }
            }()
            return (role, labeled && !unnamedRoles.contains(role))
        }
        let named = roles.filter(\.named).count
        let characters = texts.reduce(0) { total, value in
            guard case .object(let item) = value else { return total }
            if case .string(let text)? = item["text"] { return total + text.count }
            return total + 20
        }
        // One meaningful thing per ~100k pt² (a 1400×900 window wants ~12),
        // never fewer than four; any real paragraph of text is not thin.
        let floor = max(4, Int(windowArea / 100_000))
        guard named + texts.count < floor, characters < 80 else { return nil }
        if named == 0, texts.isEmpty { return roles.isEmpty ? "no controls or words" : "only unnamed groups" }
        return "few controls or words for its size"
    }
    /// Roles that are worth a number even when the app advertises no AX action
    /// for them. Two families:
    ///   • CLICKABLE — the things a human would point at.
    ///   • SCROLLABLE — the things a human would scroll; they are rarely
    ///     "pressable" but `mac_scroll` needs somewhere to aim.
    public static let clickableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTextField", "AXTextArea",
        "AXSecureTextField", "AXSearchField", "AXComboBox", "AXSlider",
        "AXIncrementor", "AXStepper", "AXDisclosureTriangle", "AXTabButton",
        "AXToolbarButton", "AXColorWell", "AXSegmentedControl",
        // Content rows are what a person points at in sidebars, outlines and
        // lists even when the app advertises no AX action on the container.
        "AXRow", "AXOutlineRow", "AXListItem",
    ]
    public static let scrollableRoles: Set<String> = [
        "AXScrollArea", "AXScrollBar", "AXTable", "AXOutline", "AXList",
        "AXWebArea", "AXCollection",
    ]
    /// With `value`, a field whose displayed value is all mask glyphs IS a
    /// password box whatever its role, subrole or label say: AppKit and WebKit
    /// publish a secure field's value as bullets, so an unlabelled web
    /// `<input type=password>` with no secure subrole is caught here.
    public static func isSecretField(role: String, subrole: String?, label: String?, value: String? = nil) -> Bool {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return true }
        if let shown = value?.trimmingCharacters(in: .whitespaces), !shown.isEmpty,
           shown.allSatisfy({ ["\u{2022}", "\u{25CF}", "\u{00B7}", "\u{2024}", "*"].contains($0) }) { return true }
        guard let label = label?.lowercased(), !label.isEmpty else { return false }
        return MacScreenViewTextRedaction.secretFieldLabelTokens.contains { label.contains($0) }
    }
    /// Is this element worth a number? Actionable (it advertises any AX action)
    /// or structurally clickable/scrollable by role. Everything else — static
    /// text, groups, decoration — stays unmarked so the picture does not turn
    /// into confetti.
    public static func isMarkable(_ attributes: MacAXAttributes) -> Bool {
        if !attributes.actions.isEmpty { return true }
        if clickableRoles.contains(attributes.role) { return true }
        if scrollableRoles.contains(attributes.role) { return true }
        return false
    }
    public struct Selection: Sendable, Equatable {
        public let marks: [MacScreenViewMark]
        /// Markable elements dropped because the mark cap was reached.
        public let omitted: Int
        /// Markable elements with no frame, or a frame entirely outside the
        /// captured rect. Counted, never silently dropped.
        public let offscreen: Int
        public var truncated: Bool { omitted > 0 }
    }
    /// Number the markable elements in READING ORDER — top-to-bottom in 8-point
    /// row bands, then left-to-right inside a band, then document order. That
    /// is how a human scans a GUI, so "the third button along the toolbar" is
    /// the third number, and it is fully deterministic: two captures of an
    /// unchanged screen produce the same numbering.
    public static func select(
        nodes: [MacAXNode],
        geometry: MacScreenViewGeometry,
        maxMarks: Int = hardMaxMarks,
        settableAttributes: (MacAXNode) -> [String] = { _ in [] }
    ) -> Selection {
        let cap = max(1, min(maxMarks, hardMaxMarks))
        var candidates: [(frame: MacAXFrame, node: MacAXNode)] = []
        var offscreen = 0
        for node in nodes {
            guard isMarkable(node.attributes) else { continue }
            guard let frame = node.attributes.frame, frame.w > 0, frame.h > 0 else {
                offscreen += 1
                continue
            }
            guard geometry.intersects(frame) else {
                offscreen += 1
                continue
            }
            candidates.append((frame, node))
        }
        candidates.sort { lhs, rhs in
            let lhsBand = (lhs.frame.y / 8.0).rounded(.down)
            let rhsBand = (rhs.frame.y / 8.0).rounded(.down)
            if lhsBand != rhsBand { return lhsBand < rhsBand }
            if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
            return MacPerceptionCompiler.pathIsBefore(lhs.node.path, rhs.node.path)
        }
        let kept = candidates.prefix(cap)
        var marks: [MacScreenViewMark] = []
        marks.reserveCapacity(kept.count)
        // Use the whole node set: enclosing groups need not be markable candidates.
        let context = MacScreenViewTextRedaction.nodeSecretContext(nodes)
        let names = LabelIndex(nodes)
        for (index, candidate) in kept.enumerated() {
            let attributes = candidate.node.attributes
            let named = inferLabel(for: candidate.node, frame: candidate.frame, in: names)
            let label = named.label
            let enclosing = MacScreenViewTextRedaction.enclosingKinds(
                forNodeAt: candidate.frame,
                path: candidate.node.path,
                among: context.enclosingCaptions
            )
            func redaction(_ text: String?, under caption: String?) -> JSONValue? {
                guard let text else { return nil }
                let json = MacScreenViewTextRedaction.redactedNodeString(
                    text,
                    valueChars: MacAXLimits.hardValueChars,
                    frame: candidate.frame,
                    under: caption,
                    enclosing: enclosing,
                    context: context
                )
                if case .object = json { return json }
                return nil
            }
            marks.append(MacScreenViewMark(
                mark: index + 1,
                role: attributes.role,
                subrole: attributes.subrole,
                label: label,
                labelSource: named.source,
                value: attributes.value,
                secret: isSecretField(
                    role: attributes.role,
                    subrole: attributes.subrole,
                    label: label
                ),
                enabled: attributes.enabled,
                frame: candidate.frame,
                path: candidate.node.path,
                actions: attributes.actions,
                settableAttributes: settableAttributes(candidate.node),
                enclosingCaption: enclosing,
                labelRedaction: redaction(label, under: nil),
                valueRedaction: redaction(attributes.value, under: label)
            ))
        }
        return Selection(
            marks: marks,
            omitted: max(0, candidates.count - kept.count),
            offscreen: offscreen
        )
    }
    /// Give every numbered control a NAME, and say where the name came from.
    ///
    /// The legend must support action on its own: use the control's own name,
    /// else the text immediately left of or above it, with inferred names labeled.
    ///
    /// The inference is deliberately narrow and deterministic — nearest static
    /// text within 240 points, on the same row (vertically overlapping) or
    /// directly above with horizontal overlap, closest wins, path order breaks
    /// ties — and it is always LABELLED as an inference, because a guessed name
    /// presented as a fact is how a confident click lands on the wrong control.
    /// The texts that can name a control, indexed once per node set: children
    /// by parent path, and nameable text by 240-point cell, so naming every
    /// control of a dense window costs its neighbourhood, not the whole tree.
    /// Cells are read within the 2^16-point span any display can sit in.
    public struct LabelIndex: Sendable {
        let nodes: [MacAXNode]
        let children: [[Int]: [Int]]
        let cells: [SIMD2<Int>: [Int]]
        public init(_ nodes: [MacAXNode]) {
            var children: [[Int]: [Int]] = [:]
            var cells: [SIMD2<Int>: [Int]] = [:]
            for (index, node) in nodes.enumerated() {
                if !node.path.isEmpty { children[Array(node.path.dropLast()), default: []].append(index) }
                // A scroll bar's thumb reads as a raw position (0.4012…), never a name.
                guard textRoles.contains(node.attributes.role),
                      !scrollPositionRoles.contains(node.attributes.role),
                      let text = node.attributes.title ?? node.attributes.value,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let frame = node.attributes.frame, frame.w > 0, frame.h > 0 else { continue }
                for cell in Self.cells(frame) { cells[cell, default: []].append(index) }
            }
            self.nodes = nodes
            self.children = children
            self.cells = cells
        }
        static func cells(_ frame: MacAXFrame) -> [SIMD2<Int>] {
            guard [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite) else { return [] }
            func cell(_ v: Double) -> Int { Int((min(max(v, -65_536), 65_536) / 240).rounded(.down)) }
            return (cell(frame.y)...cell(frame.y + frame.h)).flatMap { y in
                (cell(frame.x)...cell(frame.x + frame.w)).map { SIMD2(x: $0, y: y) }
            }
        }
        /// Every nameable text that could sit left of or above `frame` within
        /// reach; one spanning several cells comes once per cell, which the
        /// nearest-wins rule does not mind.
        func neighbours(of frame: MacAXFrame) -> [MacAXNode] {
            Self.cells(MacAXFrame(x: frame.x - 241, y: frame.y - 241, w: frame.w + 242, h: frame.h + 242))
                .flatMap { (cells[$0] ?? []).map { nodes[$0] } }
        }
    }
    public static func inferLabel(
        for node: MacAXNode,
        frame: MacAXFrame,
        in index: LabelIndex
    ) -> (label: String?, source: String) {
        let nodes = index.nodes
        if let title = node.attributes.title, !title.isEmpty { return (title, "title") }
        // A popup button / checkbox often carries its meaning in its value.
        if !isSecretField(role: node.attributes.role, subrole: node.attributes.subrole, label: nil),
           !scrollPositionRoles.contains(node.attributes.role),
           let value = node.attributes.value?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty, value.count <= 60 {
            return (value, "value")
        }
        // Finder and many source-list controls name the ROW only through a
        // child: AXRow > AXCell > AXStaticText("Screenshots"). Treat that text
        // as the row's inferred name, bounded to the same two levels/three
        // descendants as the look compiler's identity pass.
        if MacLookHandle.contentIdentityRoles.contains(node.attributes.role) {
            var budget = 3
            func descendantText(path: [Int], depth: Int) -> String? {
                guard depth < 2 else { return nil }
                for child in (index.children[path] ?? []).map({ nodes[$0] }) {
                    guard budget > 0 else { return nil }
                    budget -= 1
                    if let text = child.attributes.title ?? child.attributes.value {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    }
                    if let deeper = descendantText(path: child.path, depth: depth + 1) { return deeper }
                }
                return nil
            }
            if let text = descendantText(path: node.path, depth: 0) {
                return (text, "descendant_text")
            }
        }
        var best: (text: String, distance: Double, path: [Int])?
        for candidate in index.neighbours(of: frame) {
            // Only nameable text is indexed (see `LabelIndex`).
            guard let text = candidate.attributes.title ?? candidate.attributes.value,
                  let other = candidate.attributes.frame else { continue }
            guard let distance = MacScreenViewTextRedaction.labelDistance(other, forValueAt: frame, proximity: 240) else { continue }
            if let current = best,
               !(distance < current.distance
                 || (distance == current.distance && MacPerceptionCompiler.pathIsBefore(candidate.path, current.path))) {
                continue
            }
            best = (text.trimmingCharacters(in: .whitespacesAndNewlines), distance, candidate.path)
        }
        if let best { return (best.text, "nearby_text") }
        return (nil, "none")
    }
    /// A scroll bar and its thumb: their value is a position, not a name.
    static let scrollPositionRoles: Set<String> = ["AXScrollBar", "AXValueIndicator"]
    /// Roles that carry readable prose rather than behaviour.
    public static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXLabel", "AXValueIndicator",
    ]
    public struct VisibleText: Sendable, Equatable {
        public let text: String
        public let frame: MacAXFrame
        /// Non-nil when this line was judged to be a secret shown as PROSE (an
        /// on-screen 2FA code, a revealed API key, a masked password run). The
        /// characters then never leave — see `toJSON()`. Set by
        /// `MacScreenViewTextRedaction`, never by a caller.
        public let redactionReason: String?
        public init(text: String, frame: MacAXFrame, redactionReason: String? = nil) {
            self.text = text
            self.frame = frame
            self.redactionReason = redactionReason
        }
        public func toJSON(valueChars: Int = MacAXLimits.hardValueChars) -> JSONValue {
            .object([
                "text": redactionReason.map {
                    MacScreenViewTextRedaction.redactedText(text, reason: $0)
                } ?? .string(MacAccessibilityReader.truncate(text, to: valueChars)),
                "frame": frame.toJSON(),
            ])
        }
    }
    public struct TextSelection: Sendable, Equatable {
        public let items: [VisibleText]
        public let omitted: Int
    }
    /// What the window SAYS, in reading order — the part of the screen that is
    /// prose rather than controls. Without this the legend describes a set of
    /// controls floating in a void; with it, the legend alone answers "what is
    /// on screen and what does it say", which is the bar the image is not
    /// supposed to be needed for.
    public static func visibleText(
        nodes: [MacAXNode],
        geometry: MacScreenViewGeometry,
        limit: Int = hardMaxTextItems
    ) -> TextSelection {
        let cap = max(1, min(limit, hardMaxTextItems))
        var candidates: [(frame: MacAXFrame, text: String, path: [Int])] = []
        var seen: Set<String> = []
        for node in nodes {
            guard textRoles.contains(node.attributes.role) else { continue }
            guard let raw = node.attributes.title ?? node.attributes.value else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let frame = node.attributes.frame, frame.w > 0, frame.h > 0,
                  geometry.intersects(frame) else { continue }
            // Repeated boilerplate (a table's repeated column text) adds no
            // information and eats the cap.
            let key = "\(text)|\(frame.x.rounded(.towardZero))|\(frame.y.rounded(.towardZero))"
            guard seen.insert(key).inserted else { continue }
            candidates.append((frame, text, node.path))
        }
        candidates.sort { lhs, rhs in
            let lhsBand = (lhs.frame.y / 8.0).rounded(.down)
            let rhsBand = (rhs.frame.y / 8.0).rounded(.down)
            if lhsBand != rhsBand { return lhsBand < rhsBand }
            if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
            return MacPerceptionCompiler.pathIsBefore(lhs.path, rhs.path)
        }
        // Redact displayed secrets at the prose source before trace, persistence or sync.
        let redacted = MacScreenViewTextRedaction.applied(
            to: candidates.map { VisibleText(text: $0.text, frame: $0.frame) },
            paths: candidates.map(\.path),
            context: MacScreenViewTextRedaction.nodeSecretContext(nodes)
        )
        return TextSelection(
            items: Array(redacted.prefix(cap)),
            omitted: max(0, candidates.count - cap)
        )
    }
    /// Fit the annotated image under a byte cap by stepping DOWN a fixed
    /// resolution ladder, taking the first rung that fits.
    ///
    /// Honest by construction: when no rung fits, this returns nil and the
    /// caller reports `image_exceeds_byte_cap` instead of shipping a truncated
    /// or silently-absent image. The ladder is fixed (not a binary search) so
    /// the same screen always produces the same bytes.
    public static func fitImage(
        maxBytes: Int,
        ladder: [Double] = [1.0, 0.75, 0.5, 0.35, 0.25],
        encode: (Double) -> Data?
    ) -> (data: Data, downscale: Double)? {
        let cap = max(1, maxBytes)
        for rung in ladder {
            guard let data = encode(rung) else { continue }
            if data.count <= cap { return (data, rung) }
        }
        return nil
    }
}
