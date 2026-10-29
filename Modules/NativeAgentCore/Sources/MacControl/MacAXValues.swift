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
// Blueprint: | `MacAXValues.swift` | Accessibility identity, geometry, node and query values |
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
/// One element's readable attributes. Every optional field means "the element
/// did not expose this attribute" — a missing AX attribute is an ABSENT field,
/// never a fabricated default and never a crash.
public struct MacAXAttributes: Sendable, Equatable {
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let enabled: Bool
    public let selected: Bool?
    public let frame: MacAXFrame?
    public let actions: [String]
    /// An editable field's placeholder ("Search Maps") — what a person sees in
    /// it and calls it by, when its AX name says something else.
    public let placeholder: String?
    public let selectionRange: NSRange?
    /// Typed AXValue state, never prose obtained by stringifying a boolean.
    public let state: String?
    /// Presentation metadata, not another text channel.
    public let liveRegion: Bool
    public let valueIsHelp: Bool
    /// A display-only name when help duplicates the identity title. The
    /// original title remains authoritative for redaction and act identity.
    public let titleIsHelp: Bool
    public let displayTitle: String?
    public let listSummary: String?
    /// Hidden or modifier-only alternate, absent from the default menu.
    public let isHiddenMenuItem: Bool
    /// A menu item's command identity (identifier and key equivalent) when it
    /// has one: two items with the same path and the same key are one command.
    public let menuCommandKey: String?
    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        enabled: Bool = true,
        selected: Bool? = nil,
        frame: MacAXFrame? = nil,
        actions: [String] = [],
        placeholder: String? = nil,
        selectionRange: NSRange? = nil,
        state: String? = nil,
        liveRegion: Bool = false,
        valueIsHelp: Bool = false,
        titleIsHelp: Bool = false,
        displayTitle: String? = nil,
        listSummary: String? = nil,
        isHiddenMenuItem: Bool = false,
        menuCommandKey: String? = nil
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
    }
}
/// An emitted tree node. `path` is the child-index chain from the window root
/// (root itself is `[]`); actions resolve it against the live window.
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
/// WHICH WINDOW a look was taken of, in terms that survive a new
/// `AXUIElement` instance.
///
/// The reader and the actuator each mint their OWN element handles, per
/// instance, into their own tables — so "the window root the look walked"
/// cannot be handed to the act path as a reference. And `AXUIElement` itself
/// is not a durable identity across processes/queries in any way this code may
/// rely on: `CFHash` is documented only for use with `CFEqual` on live
/// references, and the one genuinely durable id — the CGWindowID behind
/// `_AXUIElementGetWindow` — is PRIVATE API this app does not call. There is
/// no public, read-only, stable window id on macOS.
///
/// So the identity is a COMPOSITE of read-only public attributes:
///
///   • `pid`      — the process.
///   • `role` / `subrole` — `AXWindow` + `AXStandardWindow`/`AXDialog`/…,
///     which separates a sheet from the document window behind it.
///   • `title`    — `AXTitle`. The strongest signal, and the one that MOVES
///     (a dirty marker, a tab switch), so it is never required on its own.
///   • `frame`    — `AXPosition`+`AXSize`. Survives a retitle; moves when the
///     user drags the window.
///   • `index`    — position in the app's `AXWindows` array at look time. The
///     weakest signal (z-order reshuffles it) and never decisive alone.
///
/// Live captures additionally retain the native AX window. Their continuation
/// requires CF identity equality; a replacement at the same rectangle is never
/// the captured window. Attribute scoring is only for external descriptive
/// queries that did not capture a native window.
public struct MacAXWindowIdentity: Sendable, Equatable {
    public let pid: Int32
    /// Position in the app's `AXWindows` array when the look was taken, or nil
    /// when the source answered with a window but not with a position. nil
    /// never scores — an index guessed at would rank a wrong candidate up.
    public let index: Int?
    public let role: String
    public let subrole: String?
    public let title: String?
    public let frame: MacAXFrame?
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
        frame: MacAXFrame? = nil
    ) {
        self.pid = pid
        self.index = index
        self.role = role
        self.subrole = subrole
        self.title = title
        self.frame = frame
    }
    /// Rects drift by a point under a re-layout; two DIFFERENT windows are
    /// never a point apart in both origin and size.
    public static let rectTolerance = 2.0
    static func rectsMatch(_ lhs: MacAXFrame?, _ rhs: MacAXFrame?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.x - rhs.x) <= rectTolerance
            && abs(lhs.y - rhs.y) <= rectTolerance
            && abs(lhs.w - rhs.w) <= rectTolerance
            && abs(lhs.h - rhs.h) <= rectTolerance
    }
    /// How strongly `candidate` looks like THIS window. nil ⇒ it cannot be:
    /// a different process or a different kind of window is disqualifying, not
    /// merely unlikely.
    public func score(against candidate: MacAXWindowIdentity) -> Int? {
        guard candidate.pid == pid else { return nil }
        guard candidate.role == role else { return nil }
        if let subrole, let other = candidate.subrole, subrole != other { return nil }
        // DISQUALIFYING contradiction: both signals are known on both sides and
        // both disagree. One of them moving is ordinary (a retitle, a drag);
        // both moving at once means this is a different window. Without this
        // the sole-window rule below would happily match the ONE window an app
        // has left after the window she looked at closed and a different one
        // replaced it.
        let titleContradicts = title != nil && candidate.title != nil && title != candidate.title
        let rectContradicts = frame != nil && candidate.frame != nil
            && !Self.rectsMatch(frame, candidate.frame)
        if titleContradicts && rectContradicts { return nil }
        var score = 0
        if let title, let other = candidate.title, title == other { score += 4 }
        if title == nil, candidate.title == nil { score += 1 }
        if Self.rectsMatch(frame, candidate.frame) { score += 3 }
        if let index, let other = candidate.index, index == other { score += 1 }
        return score
    }
    /// A title or rect hit. Below this a candidate is only "the right app and
    /// the right kind of window", which two documents of one app both are.
    static let decisiveScore = 3
    public enum Match<Handle>: Sendable where Handle: Sendable {
        /// Exactly one window is this window.
        case matched(Handle, reason: String)
        /// The app is alive but nothing there is the window that was looked at.
        case gone
        /// Two or more candidates are equally plausible. Refusing is the whole
        /// point: acting on a coin-flip between two windows of the same app is
        /// the bug this identity exists to prevent.
        case ambiguous(String)
    }
    /// Pick the candidate that IS this window.
    ///
    /// - a single candidate that survives the hard filters is the window (an
    ///   app with one window cannot be acted on in the "wrong" one, and its
    ///   title changing is ordinary — a dirty marker, a tab switch);
    /// - otherwise a decisive signal (matching title, or matching rect) is
    ///   required, and the best score must be strictly better than the runner-up.
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
            // Exactly one window can still be this one. Either the app has only
            // that window (and a title that moved is ordinary — a dirty marker,
            // a tab switch), or every other window contradicted itself out of
            // the running above. Refusing here would refuse every act after a
            // retitle, which is most of them.
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
        // The TITLE is window text and rides every sink this result rides, so
        // it leaves redacted like every other text channel.
        if let title {
            object["title"] = MacScreenViewTextRedaction.redactedLegendString(
                title,
                valueChars: MacAXLimits.hardValueChars
            )
        }
        if let frame { object["frame"] = frame.toJSON() }
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
/// One of an app's windows, as the READ seam sees it: the source's own element
/// handle plus the identity that survives the handle.
public struct MacAXWindowHandle: Sendable {
    public let ref: MacAXElementRef
    public let identity: MacAXWindowIdentity
    public init(ref: MacAXElementRef, identity: MacAXWindowIdentity) {
        self.ref = ref
        self.identity = identity
    }
}
/// Hard bounds. A pathological app (Xcode, a huge web view) exposes tens of
/// thousands of AX elements; an unbounded read would flood the turn. The
/// `hard*` values are ceilings the caller CANNOT raise — `init` clamps.
public struct MacAXLimits: Sendable, Equatable {
    @TaskLocal public static var readDeadline: Date?
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
    /// The deeper budget for a web page the ordinary walk had to cut: pages
    /// nest controls under hundreds of unnamed groups (Claude's simulator
    /// toolbar sits past 12 levels and 400 nodes). Same bound the name seek
    /// uses. Only the page-first walk takes it, and only after a cut.
    public static let deepPageMaxNodes = 1_200
    public static let deepPageMaxDepth = 64
    public static let deepPage: MacAXLimits = {
        var limits = MacAXLimits()
        limits.maxNodes = deepPageMaxNodes
        limits.maxDepth = deepPageMaxDepth
        return limits
    }()
    /// Bounded by its deadline alone: the desktop picture shows a window's own
    /// pixels only when every element of it was seen, so no count may cut it.
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
/// Result of a bounded walk. Truncation is REPORTED, never silent.
///
/// `skippedAtLeast` is a floor, not a total: when the node cap is reached the
/// walker stops enumerating children of unvisited elements, so the true count
/// of unseen elements is ≥ this number. The field name says so on purpose —
/// claiming an exact count would require the unbounded walk the caps exist to
/// prevent.
public struct MacAXTreeSnapshot: Sendable, Equatable {
    public let nodes: [MacAXNode]
    public let truncated: Bool
    /// Sorted, stable reason slugs: `depth_cap`, `node_cap`, `unreadable_element`.
    public let truncationReasons: [String]
    public let skippedAtLeast: Int
    public init(
        nodes: [MacAXNode],
        truncated: Bool,
        truncationReasons: [String],
        skippedAtLeast: Int
    ) {
        self.nodes = nodes
        self.truncated = truncated
        self.truncationReasons = truncationReasons
        self.skippedAtLeast = skippedAtLeast
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
/// Opaque handle into a `MacAXElementSource`. The source owns the mapping to
/// whatever it really is (an `AXUIElement` in production, an array index in
/// tests); nothing outside the source may interpret `id`.
public struct MacAXElementRef: Sendable, Hashable {
    public let id: Int
    public init(id: Int) { self.id = id }
}
/// The canonical public-AX window inventory. `AXWindows` is ordinarily the
/// complete ordered list, but Finder can omit a focused `AXSheet` from it.
/// Keep the listed order, then append the focused and main windows only when
/// they are not already present. The live sources supply `CFEqual`, rather
/// than handle equality: AX returns fresh element references for one live
/// window, and those references still compare equal by CF identity.
///
/// This generic seam deliberately has no AX dependency so the exact
/// focused-sheet case is hermetically executable in tests. Both the reader and
/// actuator call it with the same order and equality relation; an identity
/// captured from a sheet therefore has a matching ACT candidate for that sheet
/// rather than falling through to its document-window parent.
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
/// Read-only element access. Every method is failure-tolerant by contract:
/// an element that cannot be read returns nil / empty rather than throwing,
