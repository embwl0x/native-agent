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
    /// Hard ceilings prevent dense controls or 4K pixels from consuming a turn; callers may lower them only.
    public static let hardMaxMarks = 60
    public static let hardMaxImageBytes = 600_000
    /// Bound prose so thousands of document text nodes cannot drown the legend.
    public static let hardMaxTextItems = 80
    public static let visualSurfaceRoles: Set<String> = ["AXImage", "AXCanvas"]
    /// Only substantial visual surfaces earn a pixel budget; small-icon crops lose useful surrounding UI.
    public static func dominantVisualSurface(
        nodes: [MacAXNode],
        geometry: MacScreenViewGeometry,
        minimumAreaFraction: Double = 0.03
    ) -> MacAXFrame? {
        let captureArea = geometry.bounds.w * geometry.bounds.h
        guard captureArea > 0 else { return nil }
        return nodes.compactMap { node -> MacAXFrame? in
            // WebKit may expose painted content as childless AXWebArea; inspect that subtree because browser chrome cannot prove readability.
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
    /// Deliver pixels only when sparse AX or a real visual surface makes one small image useful.
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
        // Dominant visual bodies remain unreadable despite verbose toolbars; window-wide text counts grade only windows without one.
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
        // Require roughly one meaningful item per 100k square points, with at least four; real paragraphs are never thin.
        let floor = max(4, Int(windowArea / 100_000))
        guard named + texts.count < floor, characters < 80 else { return nil }
        if named == 0, texts.isEmpty { return roles.isEmpty ? "no controls or words" : "only unnamed groups" }
        return "few controls or words for its size"
    }
    /// Clickable and scrollable roles need marks even without advertised AX actions so both pointing and wheel input have targets.
    public static let clickableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTextField", "AXTextArea",
        "AXSecureTextField", "AXSearchField", "AXComboBox", "AXSlider",
        "AXIncrementor", "AXStepper", "AXDisclosureTriangle", "AXTabButton",
        "AXToolbarButton", "AXColorWell", "AXSegmentedControl",
        // Source-list rows remain pointing targets even without container AX actions.
        "AXRow", "AXOutlineRow", "AXListItem",
    ]
    public static let scrollableRoles: Set<String> = [
        "AXScrollArea", "AXScrollBar", "AXTable", "AXOutline", "AXList",
        "AXWebArea", "AXCollection",
    ]
    /// Masked values identify secure fields even when WebKit omits their secure role or label.
    public static func isSecretField(role: String, subrole: String?, label: String?, value: String? = nil) -> Bool {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return true }
        if let shown = value?.trimmingCharacters(in: .whitespaces), !shown.isEmpty,
           shown.allSatisfy({ ["\u{2022}", "\u{25CF}", "\u{00B7}", "\u{2024}", "*"].contains($0) }) { return true }
        guard let label = label?.lowercased(), !label.isEmpty else { return false }
        return MacScreenViewTextRedaction.secretFieldLabelTokens.contains { label.contains($0) }
    }
    /// Mark actionable or structurally interactive elements only so decoration cannot overwhelm the picture.
    public static func isMarkable(_ attributes: MacAXAttributes) -> Bool {
        if !attributes.actions.isEmpty { return true }
        if clickableRoles.contains(attributes.role) { return true }
        if scrollableRoles.contains(attributes.role) { return true }
        return false
    }
    public struct Selection: Sendable, Equatable {
        public let marks: [MacScreenViewMark]
        public let omitted: Int
        /// Count missing-frame and off-capture omissions rather than silently dropping them.
        public let offscreen: Int
        public var truncated: Bool { omitted > 0 }
    }
    /// Eight-point row bands then horizontal and document order match reading order and keep unchanged-screen numbering deterministic.
    public static func select(
        nodes: [MacAXNode],
        geometry: MacScreenViewGeometry,
        maxMarks: Int = hardMaxMarks,
        settableAttributes: (MacAXNode) -> [String] = { _ in [] }
    , context: MacOperationContext) -> Selection {
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
        // Enclosing secret groups need not be markable, so use the whole node set.
        let context = MacScreenViewTextRedaction.nodeSecretContext(nodes)
        let names = LabelIndex(nodes)
        for (index, candidate) in kept.enumerated() {
            let attributes = candidate.node.attributes
            let named = inferLabel(for: candidate.node, in: names)
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
                actionsUnreadable: attributes.actionsUnreadable,
                attributeGaps: attributes.attributeGaps,
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
    /// Names require observed ownership, never proximity; index children by parent path to bound caption reads.
    public struct LabelIndex: Sendable {
        let nodes: [MacAXNode]
        let children: [[Int]: [Int]]
        public init(_ nodes: [MacAXNode]) {
            var children: [[Int]: [Int]] = [:]
            for (index, node) in nodes.enumerated() {
                if !node.path.isEmpty { children[Array(node.path.dropLast()), default: []].append(index) }
            }
            self.nodes = nodes
            self.children = children
        }
    }
    public static func inferLabel(
        for node: MacAXNode,
        in index: LabelIndex
    ) -> (label: String?, source: String) {
        let nodes = index.nodes
        if node.attributes.labelUnreadable { return (nil, "unreadable") }
        if let title = node.attributes.title, !title.isEmpty { return (title, "title") }
        // Popup and checkbox values may supply their meaning.
        if !isSecretField(role: node.attributes.role, subrole: node.attributes.subrole, label: nil),
           !scrollPositionRoles.contains(node.attributes.role),
           let value = node.attributes.value?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty, value.count <= 60 {
            return (value, "value")
        }
        // Rows may be named only by static descendants; bound inference to the same two levels and three descendants as identity compilation.
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
        return (nil, "none")
    }
    /// Scrollbar values are positions rather than names.
    static let scrollPositionRoles: Set<String> = ["AXScrollBar", "AXValueIndicator"]
    public static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXLabel", "AXValueIndicator",
    ]
    public struct VisibleText: Sendable, Equatable {
        public let text: String
        public let frame: MacAXFrame
        /// Only the redaction owner may set a prose secret verdict; withheld characters must never serialize.
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
    /// Read prose alongside controls so the legend can describe the window without requiring an image.
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
            // Repeated boilerplate spends the cap without adding information.
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
    /// Use a fixed resolution ladder for deterministic byte fitting; if no rung fits, report image_exceeds_byte_cap.
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
