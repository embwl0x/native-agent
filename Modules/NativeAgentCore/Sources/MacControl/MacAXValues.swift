import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
import TrustCenter
import CoreGraphics
import UserNotifications
import Senses
import Experiences
import CryptoKit
import os
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `MacAXValues.swift` | AX identity, geometry and queries preserve gaps and bounded failure evidence |
public struct MacAXFrame: Sendable, Hashable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
    public func toJSON() -> JSONValue {
        .object([
            "x": .double(x),
            "y": .double(y),
            "w": .double(w),
            "h": .double(h),
        ])
    }
}
/// Failed action/optional-attribute reads retain named gaps while other attributes remain usable; failed reads are distinct from observed absence.
public struct MacAXAttributes: Sendable, Equatable {
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let enabled: Bool?
    public let selected: Bool?
    public let frame: MacAXFrame?
    public let actions: [String]
    /// When present, `actions` contains no claimed names, not evidence that this element supports no actions. Actuation checks the live source.
    public let actionsUnreadable: String?
    public let attributeGaps: [String]
    /// A name or caption read failed; no alternate name is claimed for this control.
    public let labelUnreadable: Bool
    /// A field's visible placeholder can name it independently of its AX identity.
    public let placeholder: String?
    public let selectionRange: NSRange?
    /// Typed AXValue state, never prose obtained by stringifying a boolean.
    public let state: String?
    /// Presentation metadata, not another text channel.
    public let liveRegion: Bool
    public let valueIsHelp: Bool
    /// A display-only name when help duplicates the identity title. The original title remains authoritative for redaction and act identity.
    public let titleIsHelp: Bool
    public let displayTitle: String?
    public let listSummary: String?
    /// Hidden or modifier-only alternate, absent from the default menu.
    public let isHiddenMenuItem: Bool
    /// A menu item's command identity (identifier and key equivalent) when it has one: two items with the same path and the same key are one command.
    public let menuCommandKey: String?
    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        enabled: Bool? = nil,
        selected: Bool? = nil,
        frame: MacAXFrame? = nil,
        actions: [String] = [],
        actionsUnreadable: String? = nil,
        placeholder: String? = nil,
        selectionRange: NSRange? = nil,
        state: String? = nil,
        liveRegion: Bool = false,
        valueIsHelp: Bool = false,
        titleIsHelp: Bool = false,
        displayTitle: String? = nil,
        listSummary: String? = nil,
        isHiddenMenuItem: Bool = false,
        menuCommandKey: String? = nil,
        attributeGaps: [String] = [],
        labelUnreadable: Bool = false
    ) {
        self.placeholder = placeholder
        self.selectionRange = selectionRange
        self.state = state
        self.liveRegion = liveRegion
        self.valueIsHelp = valueIsHelp
        self.titleIsHelp = titleIsHelp
        self.displayTitle = displayTitle
        self.listSummary = listSummary
        self.isHiddenMenuItem = isHiddenMenuItem
        self.menuCommandKey = menuCommandKey
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.enabled = enabled
        self.selected = selected
        self.frame = frame
        self.actions = actions
        self.actionsUnreadable = actionsUnreadable
        self.attributeGaps = attributeGaps
        self.labelUnreadable = labelUnreadable
    }
}
/// Paths remain window-relative so actions can resolve them against the live window.
public struct MacAXNode: Sendable, Equatable {
    public let attributes: MacAXAttributes
    public let path: [Int]
    /// Source reference retained for exact raw reads, never serialized.
    package let element: MacAXElementRef?
    public init(attributes: MacAXAttributes, path: [Int], element: MacAXElementRef? = nil) {
        self.attributes = attributes
        self.path = path
        self.element = element
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Source references are reminted; snapshot equality remains semantic.
        lhs.attributes == rhs.attributes && lhs.path == rhs.path
    }
}
public struct MacAXAppInfo: Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32
    public init(name: String, bundleIdentifier: String?, processIdentifier: Int32) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
    public func toJSON() -> JSONValue {
        .object([
            "name": .string(name),
            "bundle_id": bundleIdentifier.map { .string($0) } ?? .null,
            "pid": .int(Int64(processIdentifier)),
        ])
    }
}
/// Keep native foreground identity out of JSON.
struct MacForegroundSnapshot: Sendable {
    let app: MacAXAppInfo
    let window: MacAXWindowIdentity?

}
/// Reader and actuator handles cannot cross source tables. Public AX exposes no durable read-only window ID, so descriptive queries use composite attributes:
/// role/subrole distinguish window kinds, title and frame tolerate independent drift, and z-order index is never decisive alone. Live captures require native
/// CF identity; a replacement at the same rectangle is a different window.
public struct MacAXWindowIdentity: Sendable, Equatable {
    public let pid: Int32
    /// An unknown AXWindows index never scores; guessing could promote the wrong window.
    public let index: Int?
    public let role: String
    public let subrole: String?
    public let title: String?
    public let frame: MacAXFrame?
    /// Optional window attributes that failed, distinct from unsupported/absent values.
    public let attributeGaps: [String]
    #if canImport(ApplicationServices) && os(macOS)
    package var nativeWindow: MacAXNativeWindowIdentity?
    package func retaining(_ window: AXUIElement) -> Self {
        var identity = self
        identity.nativeWindow = MacAXNativeWindowIdentity(element: window)
        return identity
    }
    #endif
    func retainingWindow(_ ref: MacAXElementRef, in source: any MacAXElementSource) -> Self {
        #if canImport(ApplicationServices) && os(macOS)
        if let source = source as? SystemMacAXElementSource, let window = source.element(ref) {
            return retaining(window)
        }
        #endif
        return self
    }
    public init(
        pid: Int32,
        index: Int?,
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        frame: MacAXFrame? = nil,
        attributeGaps: [String] = []
    ) {
        self.pid = pid
        self.index = index
        self.role = role
        self.subrole = subrole
        self.title = title
        self.frame = frame
        self.attributeGaps = attributeGaps
    }
    /// One point tolerates layout rounding without conflating distinct window origins and sizes.
    public static let rectTolerance = 2.0
    static func rectsMatch(_ lhs: MacAXFrame?, _ rhs: MacAXFrame?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.x - rhs.x) <= rectTolerance
            && abs(lhs.y - rhs.y) <= rectTolerance
            && abs(lhs.w - rhs.w) <= rectTolerance
            && abs(lhs.h - rhs.h) <= rectTolerance
    }
    /// Process or window-kind disagreement disqualifies a candidate rather than merely lowering its score.
    public func score(against candidate: MacAXWindowIdentity) -> Int? {
        guard candidate.pid == pid else { return nil }
        guard candidate.role == role else { return nil }
        if let subrole, let other = candidate.subrole, subrole != other { return nil }
        // A retitle or a drag is ordinary; both title and frame disagreeing disqualifies a replacement even if it is the only remaining window.
        let titleContradicts = title != nil && candidate.title != nil && title != candidate.title
        let rectContradicts = frame != nil && candidate.frame != nil
            && !Self.rectsMatch(frame, candidate.frame)
        if titleContradicts && rectContradicts { return nil }
        var score = 0
        if let title, let other = candidate.title, title == other { score += 4 }
        // An absent or unreadable title is not a positive identity signal.
        if Self.rectsMatch(frame, candidate.frame) { score += 3 }
        if let index, let other = candidate.index, index == other { score += 1 }
        return score
    }
    /// A title or rect hit distinguishes documents that share process and window kind.
    static let decisiveScore = 3
    public enum Match<Handle>: Sendable where Handle: Sendable {
        case matched(Handle, reason: String)
        case gone
        /// Equal candidates must refuse; a coin flip could act on another document.
        case ambiguous(String)
    }
    /// A sole candidate surviving hard filters tolerates retitles; multiple candidates require a title/rect hit and a score strictly above the runner-up.
    public static func match<Handle: Sendable>(
        _ identity: MacAXWindowIdentity,
        among candidates: [(handle: Handle, identity: MacAXWindowIdentity)]
    ) -> Match<Handle> {
        #if canImport(ApplicationServices) && os(macOS)
        if let native = identity.nativeWindow {
            guard let candidate = candidates.first(where: {
                $0.identity.pid == identity.pid && $0.identity.nativeWindow == native
            }) else { return .gone }
            return .matched(candidate.handle, reason: "captured_native_window")
        }
        #endif
        var scored: [(handle: Handle, score: Int)] = []
        for candidate in candidates {
            guard let score = identity.score(against: candidate.identity) else { continue }
            scored.append((candidate.handle, score))
        }
        guard !scored.isEmpty else { return .gone }
        if scored.count == 1 {
            // A sole surviving candidate tolerates ordinary retitles; other windows already failed the hard identity filters.
            return .matched(
                scored[0].handle,
                reason: candidates.count == 1 ? "sole_window" : "only_surviving_candidate"
            )
        }
        scored.sort { $0.score > $1.score }
        let best = scored[0]
        guard best.score >= decisiveScore else {
            return .gone
        }
        if scored.count > 1, scored[1].score == best.score {
            return .ambiguous("\(scored.filter { $0.score == best.score }.count)_windows_match_equally")
        }
        return .matched(best.handle, reason: best.score >= decisiveScore + 4 ? "title_and_rect" : "title_or_rect")
    }
    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "pid": .int(Int64(pid)),
            "index": index.map { .int(Int64($0)) } ?? .null,
            "role": .string(role),
        ]
        if let subrole { object["subrole"] = .string(subrole) }
        // Window titles cross every result sink, so redact them like other text.
        if let title {
            object["title"] = MacScreenViewTextRedaction.redactedLegendString(
                title,
                valueChars: MacAXLimits.hardValueChars
            )
        }
        if let frame { object["frame"] = frame.toJSON() }
        if !attributeGaps.isEmpty { object["attribute_gaps"] = .array(attributeGaps.map(JSONValue.string)) }
        return .object(object)
    }
}
#if canImport(ApplicationServices) && os(macOS)
/// AXUIElement references are immutable CF identities, shared for comparison.
package struct MacAXNativeWindowIdentity: @unchecked Sendable, Equatable {
    let element: AXUIElement
    package static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
}
#endif
/// Window identity must survive read-source handles.
public struct MacAXWindowHandle: Sendable {
    public let ref: MacAXElementRef
    public let identity: MacAXWindowIdentity
    public init(ref: MacAXElementRef, identity: MacAXWindowIdentity) {
        self.ref = ref
        self.identity = identity
    }
}
/// Hard ceilings prevent pathological AX trees from flooding the turn; callers may lower but never raise them.
public struct MacAXLimits: Sendable, Equatable {

    static let readSeconds: TimeInterval = 5
    public static let hardMaxNodes = 400
    public static let hardMaxDepth = 12
    public static let hardValueChars = 200
    public static let hardMaxMatches = 20
    public private(set) var maxNodes: Int
    public private(set) var maxDepth: Int
    public let valueChars: Int
    public let maxMatches: Int
    public init(
        maxNodes: Int = MacAXLimits.hardMaxNodes,
        maxDepth: Int = MacAXLimits.hardMaxDepth,
        valueChars: Int = MacAXLimits.hardValueChars,
        maxMatches: Int = MacAXLimits.hardMaxMatches
    ) {
        self.maxNodes = max(1, min(maxNodes, MacAXLimits.hardMaxNodes))
        self.maxDepth = max(1, min(maxDepth, MacAXLimits.hardMaxDepth))
        self.valueChars = max(1, min(valueChars, MacAXLimits.hardValueChars))
        self.maxMatches = max(1, min(maxMatches, MacAXLimits.hardMaxMatches))
    }
    /// Web controls can sit beyond ordinary depth/node caps; only a size-cut page walk earns this deeper bounded budget.
    public static let deepPageMaxNodes = 1_200
    public static let deepPageMaxDepth = 64
    public static let deepPage: MacAXLimits = {
        var limits = MacAXLimits()
        limits.maxNodes = deepPageMaxNodes
        limits.maxDepth = deepPageMaxDepth
        return limits
    }()
    /// Bounded by its deadline alone: the desktop picture shows a window's own pixels only when every element of it was seen, so no count may cut it.
    public static let whole: MacAXLimits = {
        var limits = MacAXLimits()
        limits.maxNodes = .max
        limits.maxDepth = .max
        return limits
    }()
    static let document: MacAXLimits = {
        var limits = MacAXLimits()
        limits.maxNodes = MacDocumentRead.maxNodesPerFrame
        limits.maxDepth = MacDocumentRead.maxDepthPerFrame
        return limits
    }()
}
/// Report truncation. skippedAtLeast is a floor because capped walks never enumerate every unseen descendant; an exact count would require an unbounded walk.
public struct MacAXTreeSnapshot: Sendable, Equatable {
    public let nodes: [MacAXNode]
    public let truncated: Bool
    public let truncationReasons: [String]
    public let skippedAtLeast: Int
    public let readFailures: [String]
    /// Derived from this snapshot's elements, never a second error ledger. Counts describe only the elements actually read, not unseen branches.
    var readGapsJSON: [String: JSONValue] {
        let errors = nodes.compactMap { $0.attributes.actionsUnreadable }
        let attributeErrors = nodes.flatMap { $0.attributes.attributeGaps }
        return ["actions_unreadable_count": .int(Int64(errors.count)),
                "actions_unreadable_first_error": errors.first.map(JSONValue.string) ?? .null,
                "attribute_gaps_count": .int(Int64(attributeErrors.count)),
                "attribute_gaps_first_error": attributeErrors.first.map(JSONValue.string) ?? .null]
    }
    /// Menus may also appear in the window walk. Count native identities once, using the later menu observation for an overlap; never equate their private menu
    /// paths with window-relative paths.
    func readGapsJSON(including additionalNodes: [MacAXNode], source: any MacAXElementSource) -> [String: JSONValue] {
        var combined = nodes
        for node in additionalNodes {
            if let ref = node.element, let index = combined.firstIndex(where: {
                $0.element.map { source.sameElement($0, ref) } == true
            }) {
                combined[index] = node
            } else {
                combined.append(node)
            }
        }
        return MacAXTreeSnapshot(nodes: combined, truncated: truncated,
            truncationReasons: truncationReasons, skippedAtLeast: skippedAtLeast,
            readFailures: readFailures).readGapsJSON
    }
    public init(
        nodes: [MacAXNode],
        truncated: Bool,
        truncationReasons: [String],
        skippedAtLeast: Int,
        readFailures: [String] = []
    ) {
        self.nodes = nodes
        self.truncated = truncated
        self.truncationReasons = truncationReasons
        self.skippedAtLeast = skippedAtLeast
        self.readFailures = readFailures
    }
}
public struct MacAXQuery: Sendable, Equatable {
    public let role: String?
    public let title: String?
    public let value: String?
    public init(role: String? = nil, title: String? = nil, value: String? = nil) {
        func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        self.role = clean(role)
        self.title = clean(title)
        self.value = clean(value)
    }
    public var isEmpty: Bool { role == nil && title == nil && value == nil }
}
public struct MacAXMatch: Sendable, Equatable {
    public let node: MacAXNode
    public let score: Double
    public init(node: MacAXNode, score: Double) {
        self.node = node
        self.score = score
    }
}
/// Element IDs are opaque; only their source may interpret them.
public struct MacAXElementRef: Sendable, Hashable {
    public let id: Int
    public init(id: Int) { self.id = id }
}
/// Finder can omit a focused sheet from AXWindows. Preserve listed order and append missing focused/main windows using CFEqual, since AX remints references.
/// Reader and actuator share this inventory so a captured sheet cannot resolve to its document parent.
enum MacAXWindowInventory {
    static func union<Element>(
        listed: [Element],
        focused: Element?,
        main: Element?,
        equal: (Element, Element) -> Bool
    ) -> [Element] {
        var inventory: [Element] = []
        for candidate in listed {
            if !inventory.contains(where: { equal($0, candidate) }) {
                inventory.append(candidate)
            }
        }
        if let focused, !inventory.contains(where: { equal($0, focused) }) {
            inventory.append(focused)
        }
        if let main, !inventory.contains(where: { equal($0, main) }) {
            inventory.append(main)
        }
        return inventory
    }
}
