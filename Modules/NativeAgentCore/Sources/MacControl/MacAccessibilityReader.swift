import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - The perception organ (W1, READ-ONLY)
//
// Accessibility-first perception: macOS already hands every app's UI to the
// Accessibility API as STRUCTURED DATA (role, title, value, enabled, frame,
// available AX actions). Reading that tree is the alternative to the
// screenshot→vision→guess-coordinates loop. This file is the read half only:
// there is deliberately NO CGEvent, no AXUIElementPerformAction, no
// AXUIElementSetAttributeValue anywhere in it. Perception cannot mutate.
//
// Everything below splits into two layers so the caps are testable without a
// live window server:
//   • `MacAXElementSource` — the injectable seam. Production is
//     `SystemMacAXElementSource` (real AXUIElement); tests inject a synthetic
//     tree and exercise the exact same walker.
//   • `MacAccessibilityReader` — pure logic: the bounded walk, honest
//     truncation accounting, string capping, and the ax_find ranking.

// MARK: - Value types

public struct MacAXFrame: Sendable, Equatable {
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

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        enabled: Bool = true,
        selected: Bool? = nil,
        frame: MacAXFrame? = nil,
        actions: [String] = []
    ) {
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
/// (root itself is `[]`), which is the stable handle a later action wave
/// (`mac.ax_act`) resolves back to a live element.
public struct MacAXNode: Sendable, Equatable {
    public let attributes: MacAXAttributes
    public let path: [Int]

    public init(attributes: MacAXAttributes, path: [Int]) {
        self.attributes = attributes
        self.path = path
    }

    public func toJSON(valueChars: Int = MacAXLimits.hardValueChars) -> JSONValue {
        var object: [String: JSONValue] = [
            "role": .string(attributes.role),
            "enabled": .bool(attributes.enabled),
            "actions": .array(attributes.actions.map { .string($0) }),
            "path": .array(path.map { .int(Int64($0)) }),
        ]
        if let subrole = attributes.subrole { object["subrole"] = .string(subrole) }
        if let title = attributes.title {
            object["title"] = .string(MacAccessibilityReader.truncate(title, to: valueChars))
        }
        if let value = attributes.value {
            object["value"] = .string(MacAccessibilityReader.truncate(value, to: valueChars))
        }
        if let selected = attributes.selected { object["selected"] = .bool(selected) }
        if let frame = attributes.frame { object["frame"] = frame.toJSON() }
        return .object(object)
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

// MARK: - Window identity (gpt-5.5 round-3 B1)

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
///   • `pid`      — the process. Already anchored (round-2 B2).
///   • `role` / `subrole` — `AXWindow` + `AXStandardWindow`/`AXDialog`/…,
///     which separates a sheet from the document window behind it.
///   • `title`    — `AXTitle`. The strongest signal, and the one that MOVES
///     (a dirty marker, a tab switch), so it is never required on its own.
///   • `frame`    — `AXPosition`+`AXSize`. Survives a retitle; moves when the
///     user drags the window.
///   • `index`    — position in the app's `AXWindows` array at look time. The
///     weakest signal (z-order reshuffles it) and never decisive alone.
///
/// Matching is therefore a SCORE with an explicit ambiguity answer, not an
/// equality test: see `MacAXWindowIdentity.match`.
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
    public static let hardMaxNodes = 400
    public static let hardMaxDepth = 12
    public static let hardValueChars = 200
    public static let hardMaxMatches = 20

    public let maxNodes: Int
    public let maxDepth: Int
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

    public func toJSON() -> JSONValue {
        .object([
            "role": role.map { .string($0) } ?? .null,
            "title": title.map { .string($0) } ?? .null,
            "value": value.map { .string($0) } ?? .null,
        ])
    }
}

public struct MacAXMatch: Sendable, Equatable {
    public let node: MacAXNode
    public let score: Double

    public init(node: MacAXNode, score: Double) {
        self.node = node
        self.score = score
    }

    public func toJSON(valueChars: Int = MacAXLimits.hardValueChars) -> JSONValue {
        guard case .object(var object) = node.toJSON(valueChars: valueChars) else {
            return node.toJSON(valueChars: valueChars)
        }
        object["score"] = .double(score)
        return .object(object)
    }
}

// MARK: - Injectable element seam

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
/// because a half-readable tree is still useful perception.
public protocol MacAXElementSource: Sendable {
    /// `AXIsProcessTrusted()` in production.
    func isTrusted() -> Bool
    func frontmostApp() -> MacAXAppInfo?
    /// Frontmost (focused, else main, else first) window of the frontmost app.
    func frontmostWindowRoot() -> MacAXElementRef?
    /// Whether global wheel input at this point still lands in the captured
    /// container. Live AX handles are reminted, so compare underlying elements.
    func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32) -> Bool
    /// The same window choice inside a NAMED process, or nil when that process
    /// has no readable window. `mac_act`'s identity guard (gpt-5.5 round-2 B3)
    /// re-compiles the window it is about to act in, and that window belongs to
    /// the FRAME's app — reading whatever is frontmost by then would refuse
    /// every act the moment another app stole focus. Default: the frontmost
    /// root, which is the truthful answer for a single-tree synthetic source.
    func windowRoot(pid: Int32) -> MacAXElementRef?
    /// EVERY window of a named process, in `AXWindows` order, each with the
    /// composite identity that survives this source instance
    /// (gpt-5.5 round-3 B1). `mac_act` re-reads the window the LOOK was taken
    /// of, which "focused, else main, else first" cannot name: with two windows
    /// of one app, a focus change between the look and the act silently
    /// re-points every read at the other one.
    ///
    /// Default: the one window `windowRoot(pid:)` answers with, at index 0 —
    /// truthful for a single-tree source, which is what every synthetic source
    /// is.
    func windowRoots(pid: Int32) -> [MacAXWindowHandle]
    /// Metadata for a NAMED process (gpt-5.5 round-3 S7). `frontmostApp()`
    /// describes whatever is in front, which is a lie about a pid-anchored
    /// read; the default therefore answers only when the frontmost app IS that
    /// pid, and nil otherwise — absence over a wrong answer, like every other
    /// member here.
    func appInfo(pid: Int32) -> MacAXAppInfo?
    /// fable51 item 32a — every app with a user interface that is running RIGHT
    /// NOW, so a caller can name one and have its window read without
    /// activating it. Enumeration only: nothing here focuses, launches or quits
    /// anything.
    ///
    /// Default: whatever is frontmost, which is the truthful answer for a
    /// single-tree synthetic source — it knows of exactly one app, and claiming
    /// to know of others would make background sight testable against a
    /// fiction.
    func runningApps() -> [MacAXAppInfo]
    /// fable51 item 29 — the app's `AXMenuBar` element, or nil when it has
    /// none. Its own member rather than a role the ordinary walk may reach:
    /// every window walk in this module DELIBERATELY refuses to descend into a
    /// menu bar (400 items would eat the node budget on every look), and this
    /// keeps that refusal intact while giving the menu organ its one door.
    ///
    /// Default nil — a synthetic source has no menu bar unless it says it does,
    /// and "no menu bar" is a truthful answer that the organ reports in words.
    func menuBarRoot(pid: Int32) -> MacAXElementRef?
    /// fable51 item 33 — the FILE the app's front window is showing, as a
    /// filesystem path, when the app names one (`AXDocument`). This is the one
    /// question that decides whether `read` can go to the source instead of
    /// scraping the screen: a PDF viewer that names its file is a document to
    /// be extracted, and a window that names nothing is a surface to be
    /// accumulated.
    ///
    /// Its own member rather than a field on `MacAXAttributes` because it is
    /// ONE attribute on ONE element (the window root) and every other walk in
    /// this module reads attributes for hundreds of nodes per frame — putting
    /// it there would buy a per-node AX round trip for an answer only this
    /// organ asks for.
    ///
    /// Default nil — a synthetic source names no file unless it says it does,
    /// and "no document" is a truthful answer the organ reports in words.
    func frontmostDocumentPath(pid: Int32) -> String?
    /// Currently open native menus belonging to this frontmost app. They can
    /// be application siblings, not descendants of its document window.
    /// These roots are never window-relative action addresses.
    func transientMenuRoots(pid: Int32) -> [MacAXElementRef]
    func attributes(of ref: MacAXElementRef) -> MacAXAttributes?
    func children(of ref: MacAXElementRef) -> [MacAXElementRef]
    /// Child count WITHOUT materializing the array. Default falls back to
    /// `children(of:).count`; the live source uses the ranged AX count API so a
    /// pathological node (100k children) can't force a huge bridge just to be
    /// counted at the depth cap (gpt-5.5 SHOULD-FIX, 2026-08-12).
    func childCount(of ref: MacAXElementRef) -> Int
    /// At most `limit` children. Default prefixes `children(of:)`; the live
    /// source uses `AXUIElementCopyAttributeValues` ranged fetch so the whole
    /// child array is never bridged when only a bounded slice can still fit
    /// under the node cap.
    func children(of ref: MacAXElementRef, limit: Int) -> [MacAXElementRef]
    /// The child-index path of the app's focused element, relative to the same
    /// window root `frontmostWindowRoot()` returns — or nil when this source
    /// CANNOT TELL. The default is nil for exactly that reason: a source that
    /// has no notion of focus must report absence, never a guess (the
    /// perception compiler reports "focus: unknown" rather than naming "the
    /// first text field", which is how a look starts lying about the cursor).
    /// Read-only like every other member here.
    func focusedElementPath() -> [Int]?
    /// Focus path anchored to a root the caller ALREADY WALKED: nil when the
    /// focused element is not under that root (focus moved to another window
    /// between the walk and this call). Default defers to `focusedElementPath()`
    /// for sources with a single tree (synthetic/test sources).
    func focusedElementPath(relativeTo root: MacAXElementRef?) -> [Int]?
}

public extension MacAXElementSource {
    func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32) -> Bool {
        frontmostApp()?.processIdentifier == pid && frontmostWindowRoot() == window
            && attributes(of: container)?.frame == frame
    }
    func transientMenuRoots(pid: Int32) -> [MacAXElementRef] { [] }
    func childCount(of ref: MacAXElementRef) -> Int { children(of: ref).count }
    func children(of ref: MacAXElementRef, limit: Int) -> [MacAXElementRef] {
        limit <= 0 ? [] : Array(children(of: ref).prefix(limit))
    }
    func focusedElementPath() -> [Int]? { nil }
    func focusedElementPath(relativeTo root: MacAXElementRef?) -> [Int]? { focusedElementPath() }
    func windowRoot(pid: Int32) -> MacAXElementRef? { frontmostWindowRoot() }
    func windowRoots(pid: Int32) -> [MacAXWindowHandle] {
        guard let root = windowRoot(pid: pid) else { return [] }
        let attributes = attributes(of: root)
        return [MacAXWindowHandle(
            ref: root,
            identity: MacAXWindowIdentity(
                pid: pid,
                index: 0,
                role: attributes?.role ?? "AXWindow",
                subrole: attributes?.subrole,
                title: attributes?.title,
                frame: attributes?.frame
            )
        )]
    }
    func appInfo(pid: Int32) -> MacAXAppInfo? {
        guard let app = frontmostApp(), app.processIdentifier == pid else { return nil }
        return app
    }
    func runningApps() -> [MacAXAppInfo] { [frontmostApp()].compactMap { $0 } }
    func menuBarRoot(pid: Int32) -> MacAXElementRef? { nil }
    func frontmostDocumentPath(pid: Int32) -> String? { nil }
}

// MARK: - Pure reader

public enum MacAccessibilityReader {
    public static let notTrustedNote =
        "NativeAgent does not have Accessibility permission yet. Grant it in "
        + "System Settings → Privacy & Security → Accessibility (toggle NativeAgent on), "
        + "then retry. Only you can grant this — the app cannot toggle it."

    /// Character-capped, ellipsis-marked. The returned string is NEVER longer
    /// than `limit`: the marker replaces the last kept character rather than
    /// being appended past the cap.
    public static func truncate(_ raw: String, to limit: Int) -> String {
        let cap = max(1, limit)
        guard raw.count > cap else { return raw }
        return String(raw.prefix(cap - 1)) + "…"
    }

    /// Depth-first preorder walk under both caps.
    ///
    /// Depth is 1-based at the root, so `maxDepth: 12` emits at most 12 levels
    /// and the deepest emitted `path` has 11 components.
    public static func walk(
        source: any MacAXElementSource,
        root: MacAXElementRef,
        limits: MacAXLimits = MacAXLimits()
    ) -> MacAXTreeSnapshot {
        var nodes: [MacAXNode] = []
        var skipped = 0
        var reasons: Set<String> = []
        // Explicit stack so a deep tree cannot blow the Swift stack, and so
        // the node cap is enforced BEFORE any further child enumeration.
        var stack: [(ref: MacAXElementRef, path: [Int], depth: Int)] = [(root, [], 1)]

        while let item = stack.popLast() {
            if nodes.count >= limits.maxNodes {
                // Everything still pending is unseen. Count it and stop; we do
                // not enumerate its children, hence "at least".
                skipped += 1 + stack.count
                reasons.insert("node_cap")
                break
            }
            guard let attributes = source.attributes(of: item.ref) else {
                skipped += 1
                reasons.insert("unreadable_element")
                continue
            }
            nodes.append(MacAXNode(attributes: attributes, path: item.path))

            if item.depth >= limits.maxDepth {
                // Count-only: never materialize the child array just to report
                // how many were cut at the depth boundary.
                let pending = source.childCount(of: item.ref)
                if pending > 0 {
                    skipped += pending
                    reasons.insert("depth_cap")
                }
                continue
            }
            // Bounded fetch: children beyond the remaining node budget can never
            // be appended (the node-cap break fires first when popped), so
            // materializing the whole array is pure waste and a pathological node
            // could force a huge bridge. Fetch only what could still fit; count
            // the un-fetched remainder without materializing it.
            let budget = max(0, limits.maxNodes - nodes.count)
            let total = source.childCount(of: item.ref)
            let children = source.children(of: item.ref, limit: budget)
            if total > children.count {
                skipped += total - children.count
                reasons.insert("node_cap")
            }
            // Reverse-push so pop order is left-to-right preorder.
            for (index, child) in children.enumerated().reversed() {
                stack.append((child, item.path + [index], item.depth + 1))
            }
        }

        return MacAXTreeSnapshot(
            nodes: nodes,
            truncated: !reasons.isEmpty,
            truncationReasons: reasons.sorted(),
            skippedAtLeast: skipped
        )
    }

    /// Agent round 2, #1-ranked gap — the TARGETED DESCENT.
    ///
    /// A Chromium window spends the ordinary walk's 400 nodes / 12 levels on the
    /// toolbar and the bookmarks bar and hits `depth_cap` before it ever reaches
    /// the page: her Chrome look came back blind to the thing she was looking
    /// at. This finds the first element with `role` — the `AXWebArea` — under a
    /// SEARCH depth deep enough to clear the shell (24) but on a node budget far
    /// smaller than the walk's, and stops the instant it matches.
    ///
    /// READ-ONLY and the SAME seam as the walk: no second walker, no mutation,
    /// no attribute the walk does not already read. Breadth-first, because a web
    /// area is wide-and-shallow-ish in the shell and a depth-first descent would
    /// burn the budget in the first bookmark folder.
    public static let findFirstMaxDepth = 24
    public static let findFirstNodeBudget = 160

    /// gpt-5.5 round-3 S5 — the search either found it, or it RAN OUT, and
    /// those are different facts.
    ///
    /// Collapsing them into `nil` made a Chrome window whose shell is deeper or
    /// wider than the 160-node budget report `no_web_area_found`: a claim that
    /// the page does not exist, made by a search that never got there. The
    /// caller still falls back to chrome scope — that part was right — but it
    /// now says WHY.
    public enum FindFirstResult: Sendable, Equatable {
        case found(ref: MacAXElementRef, path: [Int])
        /// The search covered everything reachable under both budgets and the
        /// role is genuinely not there.
        case notFound
        /// The search stopped at the depth ceiling with children unexamined.
        case depthCap
        /// The search stopped at the node budget with the queue non-empty.
        case nodeCap

        public var hit: (ref: MacAXElementRef, path: [Int])? {
            guard case .found(let ref, let path) = self else { return nil }
            return (ref, path)
        }

        /// The machine-readable reason a look reports when the search ended
        /// without an answer. nil for `.found`.
        public var truncationReason: String? {
            switch self {
            case .found, .notFound: return nil
            case .depthCap: return "depth_cap"
            case .nodeCap: return "node_cap"
            }
        }
    }

    public static func findFirst(
        role: String,
        source: any MacAXElementSource,
        root: MacAXElementRef,
        maxDepth: Int = MacAccessibilityReader.findFirstMaxDepth,
        nodeBudget: Int = MacAccessibilityReader.findFirstNodeBudget
    ) -> FindFirstResult {
        var queue: [(ref: MacAXElementRef, path: [Int], depth: Int)] = [(root, [], 1)]
        var visited = 0
        var index = 0
        // Set the moment a budget stops the search short of an element that
        // could still have carried the role. A search that examined everything
        // reachable leaves both false, and only then is `notFound` the truth.
        var hitDepthCap = false
        var hitNodeCap = false
        while index < queue.count {
            let item = queue[index]
            index += 1
            visited += 1
            // BACKSTOP, not the primary cap. The `remaining` clamp below never
            // queues more than the budget can pop (visited + pending + newly
            // fetched ≤ budget by construction), so this branch is unreachable
            // while that invariant holds — and the invariant, not this line, is
            // what a test can pin (`findFirst_neverVisitsMoreNodesThanItsBudget`).
            // It stays as the loop's own hard stop: a runaway search is worse
            // than a redundant comparison.
            if visited > max(1, nodeBudget) { return .nodeCap }
            if let attributes = source.attributes(of: item.ref), attributes.role == role {
                // The ROOT itself matching is a real answer — a window that IS
                // the web area needs no descent.
                return .found(ref: item.ref, path: item.path)
            }
            guard item.depth < max(1, maxDepth) else {
                if source.childCount(of: item.ref) > 0 { hitDepthCap = true }
                continue
            }
            let remaining = max(0, max(1, nodeBudget) - visited - (queue.count - index))
            guard remaining > 0 else {
                if source.childCount(of: item.ref) > 0 { hitNodeCap = true }
                continue
            }
            let total = source.childCount(of: item.ref)
            let children = source.children(of: item.ref, limit: remaining)
            if total > children.count { hitNodeCap = true }
            for (childIndex, child) in children.enumerated() {
                queue.append((child, item.path + [childIndex], item.depth + 1))
            }
        }
        // Node cap first: it is the budget that actually bit in the Chrome case
        // the finding names, and reporting the deeper one would understate it.
        if hitNodeCap { return .nodeCap }
        if hitDepthCap { return .depthCap }
        return .notFound
    }

    /// Rank nodes against a query. All supplied predicates must match
    /// (AND semantics); the score only orders the survivors.
    ///
    /// Weights — title dominates because "find the Send button" is the
    /// primitive this exists for:
    ///   title  exact 3.0 / prefix 2.0 / substring 1.0
    ///   value  exact 1.5 / prefix 1.0 / substring 0.5
    ///   role match                      +2.0
    ///   element advertises AXPress      +0.25 (actionable beats decorative)
    public static func find(
        nodes: [MacAXNode],
        query: MacAXQuery,
        limits: MacAXLimits = MacAXLimits()
    ) -> [MacAXMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [MacAXMatch] = []

        for node in nodes {
            var score = 0.0
            if let role = query.role {
                guard roleMatches(node.attributes.role, query: role) else { continue }
                score += 2.0
            }
            if let title = query.title {
                guard let candidate = node.attributes.title,
                      let component = textScore(candidate, query: title, weight: 3.0)
                else { continue }
                score += component
            }
            if let value = query.value {
                guard let candidate = node.attributes.value,
                      let component = textScore(candidate, query: value, weight: 1.5)
                else { continue }
                score += component
            }
            if node.attributes.actions.contains("AXPress") { score += 0.25 }
            matches.append(MacAXMatch(node: node, score: score))
        }

        // Deterministic ordering: score desc, then shorter title (more
        // specific), then document order via path. Never rely on sort
        // stability for a user-visible ranking.
        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsLength = lhs.node.attributes.title?.count ?? Int.max
            let rhsLength = rhs.node.attributes.title?.count ?? Int.max
            if lhsLength != rhsLength { return lhsLength < rhsLength }
            return pathIsBefore(lhs.node.path, rhs.node.path)
        }
        return Array(matches.prefix(limits.maxMatches))
    }

    /// `"button"`, `"Button"` and `"AXButton"` all address AXButton. Roles are
    /// an AX vocabulary, not free text, so the AX prefix is optional.
    static func roleMatches(_ role: String, query: String) -> Bool {
        let lhs = role.lowercased()
        let rhs = query.lowercased()
        if lhs == rhs { return true }
        return lhs == "ax" + rhs
    }

    /// nil ⇒ no match (caller rejects the node).
    static func textScore(_ candidate: String, query: String, weight: Double) -> Double? {
        let lhs = candidate.lowercased()
        let rhs = query.lowercased()
        if lhs == rhs { return weight }
        if lhs.hasPrefix(rhs) { return weight * (2.0 / 3.0) }
        if lhs.contains(rhs) { return weight * (1.0 / 3.0) }
        return nil
    }

    private static func pathIsBefore(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (a, b) in zip(lhs, rhs) where a != b { return a < b }
        return lhs.count < rhs.count
    }
}

// MARK: - Production element source

#if canImport(ApplicationServices) && os(macOS)

/// Live `AXUIElement` reader.
///
/// READ-ONLY BY CONSTRUCTION: only `AXUIElementCopyAttributeValue` /
/// `AXUIElementCopyActionNames` / `AXUIElementCreateApplication` are called.
/// No `AXUIElementPerformAction`, no `AXUIElementSetAttributeValue`.
///
/// Handles are minted per instance into a locked table, so one instance is one
/// snapshot session. `@unchecked Sendable` is carried by the lock: `AXUIElement`
/// is a CFType with no Sendable conformance, and every access to the table (and
/// therefore to the elements) is serialized here.
public final class SystemMacAXElementSource: MacAXElementSource, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int: AXUIElement] = [:]
    private var nextID = 0

    public init() {}

    private func mint(_ element: AXUIElement) -> MacAXElementRef {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        table[nextID] = element
        return MacAXElementRef(id: nextID)
    }

    private func element(_ ref: MacAXElementRef) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return table[ref.id]
    }

    public func isTrusted() -> Bool {
        // Read-only probe. Deliberately NOT AXIsProcessTrustedWithOptions(
        // kAXTrustedCheckOptionPrompt: true) — the TCC grant is User's click in
        // System Settings; code never nags or toggles it.
        AXIsProcessTrusted()
    }

    public func documentScrollTargetIsCurrent(window: MacAXElementRef, container: MacAXElementRef, frame: MacAXFrame, pid: Int32) -> Bool {
        guard frontmostApp()?.processIdentifier == pid,
              let current = frontmostWindowRoot(), let currentElement = element(current),
              let original = element(window), CFEqual(currentElement, original),
              let target = element(container), attributes(of: container)?.frame == frame else { return false }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(frame.x + frame.w / 2),
            Float(frame.y + frame.h / 2), &hit
        ) == .success else { return false }
        // A sheet, popup, overlapping window, or sibling scroll area is not
        // the document, even when the foreground PID has not changed.
        for _ in 0..<64 {
            guard let node = hit else { return false }
            if CFEqual(node, target) { return true }
            hit = copyElement(node, kAXParentAttribute)
        }
        return false
    }

    public func frontmostApp() -> MacAXAppInfo? {
        #if canImport(AppKit)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return MacAXAppInfo(
            name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier
        )
        #else
        return nil
        #endif
    }

    public func frontmostWindowRoot() -> MacAXElementRef? {
        #if canImport(AppKit)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return windowRoot(pid: app.processIdentifier)
        #else
        return nil
        #endif
    }

    /// fable51 item 32a. `.regular` only: accessory and prohibited-policy
    /// processes are menu-bar items and daemons with no window to read, and
    /// listing them would fill an "app not running" refusal with names that can
    /// never be answers.
    public func runningApps() -> [MacAXAppInfo] {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map { app in
                MacAXAppInfo(
                    name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
                    bundleIdentifier: app.bundleIdentifier,
                    processIdentifier: app.processIdentifier
                )
            }
        #else
        return []
        #endif
    }

    /// fable51 item 29. One attribute read on the application element; no walk
    /// happens here — `MacMenuBar.read` owns the bounded descent.
    public func menuBarRoot(pid: Int32) -> MacAXElementRef? {
        #if canImport(AppKit)
        guard pid != getpid(), isTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let bar = copyElement(app, kAXMenuBarAttribute) else { return nil }
        return mint(bar)
        #else
        return nil
        #endif
    }

    /// fable51 item 33. ONE attribute read on the front window; no walk. The
    /// `AXDocument` attribute is a file URL string when the app is showing a
    /// file and absent otherwise — absence is the honest "this is not a
    /// document window", never a guess from the window title.
    public func frontmostDocumentPath(pid: Int32) -> String? {
        guard pid != getpid(), isTrusted() else { return nil }
        guard let window = windowRoot(pid: pid), let element = element(window) else { return nil }
        guard let raw = copyString(element, kAXDocumentAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // Apps publish this as a file URL. Percent-decode through URL rather
        // than by hand: a path with a space arrives as %20 and a hand-rolled
        // decode is how "My Contract.pdf" becomes a file-not-found.
        if raw.hasPrefix("file://") {
            return URL(string: raw)?.path
        }
        return raw.hasPrefix("/") ? raw : nil
    }

    public func transientMenuRoots(pid: Int32) -> [MacAXElementRef] {
        guard pid != getpid(), isTrusted(), frontmostApp()?.processIdentifier == pid else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var menus: [AXUIElement] = []
        func appendMenu(_ element: AXUIElement) {
            guard menus.count < MacTransientMenus.maxMenus,
                  copyString(element, kAXRoleAttribute) == "AXMenu",
                  copyBool(element, "AXHidden") != true,
                  let frame = copyFrame(element), MacTransientMenus.validFrame(frame),
                  !menus.contains(where: { CFEqual($0, element) }) else { return }
            menus.append(element)
        }
        // Chrome keeps focus on AXWebArea while its context menu is a sibling
        // of an ancestor group. The ordinary page-first walk excludes it.
        let nearby = MacTransientMenus.nearFocus(
            copyElement(app, kAXFocusedUIElementAttribute),
            parent: { self.copyElement($0, kAXParentAttribute) },
            children: { element, limit in
                guard self.copyString(element, kAXRoleAttribute) != "AXMenuBar" else { return [] }
                var values: CFArray?
                guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0,
                                                     CFIndex(limit), &values) == .success,
                      let children = values as? [AnyObject] else { return [] }
                return children.compactMap { child in
                    CFGetTypeID(child) == AXUIElementGetTypeID() ? (child as! AXUIElement) : nil
                }
            },
            isMenu: { self.copyString($0, kAXRoleAttribute) == "AXMenu" },
            equal: { CFEqual($0, $1) }
        )
        for menu in nearby {
            appendMenu(menu)
        }
        // Chromium context menus commonly live directly under the application.
        // Use ranged reads so a large application tree is not materialized.
        for attribute in [kAXChildrenAttribute, kAXWindowsAttribute] {
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(app, attribute as CFString, 0, 64, &values) == .success,
                  let children = values as? [AnyObject] else { continue }
            for child in children where CFGetTypeID(child) == AXUIElementGetTypeID() {
                appendMenu(child as! AXUIElement)
            }
        }
        return menus.map { mint($0) }
    }

    public func windowRoot(pid: Int32) -> MacAXElementRef? {
        #if canImport(AppKit)
        // NEVER mint an element for our own process: an AX read of our own
        // tree re-enters AppKit in-process and can deadlock against the main
        // thread (P1, sample 2026-08-28 — AXUIElementCopyActionNames on our
        // own toolbar parked a background thread in NSOperation
        // waitUntilFinished while the main thread held SwiftUI's update lock).
        // The tool layer refuses with a named reason (`selfProcess`); this
        // guard is the safety net for any caller that reaches the source
        // directly.
        guard pid != getpid() else { return nil }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        if let focused = copyElement(appElement, kAXFocusedWindowAttribute) {
            return mint(focused)
        }
        if let main = copyElement(appElement, kAXMainWindowAttribute) {
            return mint(main)
        }
        if let first = copyElementArray(appElement, kAXWindowsAttribute).first {
            return mint(first)
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Round-3 B1. Every window of the process, in `AXWindows` order, each with
    /// the composite identity — read-only, one attribute pass per window.
    ///
    /// `AXWindows` supplies the primary order, but Finder can omit a focused
    /// `AXSheet`. Union focused and main after it, deduped by `CFEqual`, so the
    /// snapshot can preserve the sheet's own identity without making an
    /// ordinary focused/main window appear twice.
    public func windowRoots(pid: Int32) -> [MacAXWindowHandle] {
        #if canImport(AppKit)
        // Same self-process fence as `windowRoot(pid:)` — see the deadlock
        // note there.
        guard pid != getpid() else { return [] }
        guard NSRunningApplication(processIdentifier: pid) != nil else { return [] }
        let appElement = AXUIElementCreateApplication(pid)
        let windows = MacAXWindowInventory.union(
            listed: copyElementArray(appElement, kAXWindowsAttribute),
            focused: copyElement(appElement, kAXFocusedWindowAttribute),
            main: copyElement(appElement, kAXMainWindowAttribute),
            equal: { CFEqual($0, $1) }
        )
        return windows.enumerated().map { index, window in
            MacAXWindowHandle(
                ref: mint(window),
                identity: MacAXWindowIdentity(
                    pid: pid,
                    index: index,
                    role: copyString(window, kAXRoleAttribute) ?? "AXWindow",
                    subrole: copyString(window, kAXSubroleAttribute),
                    title: copyString(window, kAXTitleAttribute),
                    frame: copyFrame(window)
                )
            )
        }
        #else
        return []
        #endif
    }

    /// Round-3 S7 — metadata for a NAMED process. `frontmostApp()` describes
    /// whatever is in front; reporting it for another pid's root labels the
    /// wrong app onto a correct background read.
    public func appInfo(pid: Int32) -> MacAXAppInfo? {
        #if canImport(AppKit)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return MacAXAppInfo(
            name: app.localizedName ?? app.bundleIdentifier ?? "unknown",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: pid
        )
        #else
        return nil
        #endif
    }

    /// Walk UP from the app's focused element to the window root, recording the
    /// index of each element in its parent's children. Cheap and exact: one
    /// `AXParent` chain, no second tree walk — and still read-only.
    ///
    /// nil when there is no focused element, when the chain does not reach the
    /// same root `frontmostWindowRoot()` returned (a focused element in another
    /// window), or when any hop is unreadable. Absence over a wrong answer.
    public func focusedElementPath() -> [Int]? {
        focusedElementPath(relativeTo: nil)
    }

    /// Same walk, anchored to the ROOT THE CALLER ALREADY WALKED when one is
    /// given: the path is only meaningful inside that snapshot, and a focus
    /// that moved to another window between the walk and this call must read
    /// as "no focus", never as "the node at that path in the old tree"
    /// (gpt-5.5 BLOCKING 2026-08-22 — a look that lies about the cursor).
    /// Runs on the AX execution lane like every other live call that can
    /// re-enter the target app.
    public func focusedElementPath(relativeTo rootRef: MacAXElementRef?) -> [Int]? {
        MacAXExecutionLane.sync { focusedElementPathOnExecutionLane(relativeTo: rootRef) }
    }

    private func focusedElementPathOnExecutionLane(relativeTo rootRef: MacAXElementRef?) -> [Int]? {
        #if canImport(AppKit)
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Same self-process fence as `windowRoot(pid:)` — a focused element in
        // our own window must never be walked over AX.
        guard app.processIdentifier != getpid() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = copyElement(appElement, kAXFocusedUIElementAttribute) else { return nil }
        let root: AXUIElement
        if let rootRef {
            // The walked root, by handle — not whatever window is focused NOW.
            guard let anchored = element(rootRef) else { return nil }
            root = anchored
        } else {
            guard let live = copyElement(appElement, kAXFocusedWindowAttribute)
                ?? copyElement(appElement, kAXMainWindowAttribute)
                ?? copyElementArray(appElement, kAXWindowsAttribute).first
            else { return nil }
            root = live
        }

        var path: [Int] = []
        var current = focused
        // Bounded by the reader's own depth ceiling: a cycle or a pathological
        // chain cannot spin here.
        for _ in 0..<MacAXLimits.hardMaxDepth {
            if CFEqual(current, root) { return path.reversed() }
            guard let parent = copyElement(current, kAXParentAttribute) else { return nil }
            let siblings = copyElementArray(parent, kAXChildrenAttribute)
            guard let index = siblings.firstIndex(where: { CFEqual($0, current) }) else { return nil }
            path.append(index)
            current = parent
        }
        return nil
        #else
        return nil
        #endif
    }

    public func attributes(of ref: MacAXElementRef) -> MacAXAttributes? {
        guard let element = element(ref) else { return nil }
        guard let role = copyString(element, kAXRoleAttribute) else { return nil }
        return MacAXAttributes(
            role: role,
            subrole: copyString(element, kAXSubroleAttribute),
            title: copyString(element, kAXTitleAttribute)
                ?? copyString(element, kAXDescriptionAttribute),
            value: copyStringifiedValue(element, kAXValueAttribute),
            enabled: copyBool(element, kAXEnabledAttribute) ?? true,
            selected: copyBool(element, kAXSelectedAttribute),
            frame: copyFrame(element),
            actions: copyActions(element)
        )
    }

    public func children(of ref: MacAXElementRef) -> [MacAXElementRef] {
        guard let element = element(ref) else { return [] }
        return copyElementArray(element, kAXChildrenAttribute).map { mint($0) }
    }

    /// Count without bridging the array (gpt-5.5 SHOULD-FIX): the ranged AX count
    /// API returns the number of children without copying any of them.
    public func childCount(of ref: MacAXElementRef) -> Int {
        guard let element = element(ref) else { return 0 }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(
            element, kAXChildrenAttribute as CFString, &count) == .success else { return 0 }
        return max(0, Int(count))
    }

    /// Bounded fetch (gpt-5.5 SHOULD-FIX): `AXUIElementCopyAttributeValues` copies
    /// only the requested [0, limit) slice, so a node with an enormous child
    /// count never forces the whole array across the AX bridge.
    public func children(of ref: MacAXElementRef, limit: Int) -> [MacAXElementRef] {
        guard limit > 0, let element = element(ref) else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(
            element, kAXChildrenAttribute as CFString, 0, CFIndex(limit), &values) == .success,
              let array = values as? [AnyObject] else { return [] }
        return array.compactMap { candidate in
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return nil }
            return mint(candidate as! AXUIElement)
        }
    }

    // MARK: raw AX copies (each one nil-tolerant)

    private func copyRaw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard status == .success else { return nil }
        return raw
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let raw = copyRaw(element, attribute) else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        let string = raw as! CFString as String
        return string.isEmpty ? nil : string
    }

    private func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let raw = copyRaw(element, attribute) else { return nil }
        guard CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((raw as! CFBoolean))
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copyRaw(element, attribute) else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func copyElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let raw = copyRaw(element, attribute) else { return [] }
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let array = raw as! CFArray as [AnyObject]
        return array.compactMap { candidate in
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return nil }
            return (candidate as! AXUIElement)
        }
    }

    private func copyActions(_ element: AXUIElement) -> [String] {
        var raw: CFArray?
        let status = AXUIElementCopyActionNames(element, &raw)
        guard status == .success, let raw else { return [] }
        return (raw as [AnyObject]).compactMap { $0 as? String }
    }

    /// `kAXValue` is a grab-bag: string, number, bool, or a packed AXValue
    /// (point/size/rect/range). Anything we cannot render as text is reported
    /// as ABSENT rather than as a misleading placeholder.
    private func copyStringifiedValue(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let raw = copyRaw(element, attribute) else { return nil }
        let typeID = CFGetTypeID(raw)
        if typeID == CFStringGetTypeID() {
            let string = raw as! CFString as String
            return string.isEmpty ? nil : string
        }
        if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue((raw as! CFBoolean)) ? "true" : "false"
        }
        if typeID == CFNumberGetTypeID() {
            var double = 0.0
            guard CFNumberGetValue((raw as! CFNumber), .doubleType, &double) else { return nil }
            if double == double.rounded(), abs(double) < 1e15 {
                return String(Int64(double))
            }
            return String(double)
        }
        if typeID == AXValueGetTypeID() {
            let axValue = raw as! AXValue
            switch AXValueGetType(axValue) {
            case .cgPoint:
                var point = CGPoint.zero
                guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
                return "(\(point.x), \(point.y))"
            case .cgSize:
                var size = CGSize.zero
                guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
                return "\(size.width)x\(size.height)"
            default:
                return nil
            }
        }
        return nil
    }

    private func copyFrame(_ element: AXUIElement) -> MacAXFrame? {
        var point = CGPoint.zero
        var size = CGSize.zero
        var hasPoint = false
        var hasSize = false
        if let raw = copyRaw(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            hasPoint = AXValueGetValue((raw as! AXValue), .cgPoint, &point)
        }
        if let raw = copyRaw(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            hasSize = AXValueGetValue((raw as! AXValue), .cgSize, &size)
        }
        // gpt-5.5 SHOULD-FIX (2026-08-12): require BOTH halves. Returning a
        // frame when only one is readable fabricated the missing half as zero —
        // "size unreadable" became w:0,h:0 and "position unreadable" became
        // x:0,y:0, which reads as a real (mis)placed element. Absent > wrong.
        guard hasPoint && hasSize else { return nil }
        return MacAXFrame(
            x: Double(point.x),
            y: Double(point.y),
            w: Double(size.width),
            h: Double(size.height)
        )
    }
}

#endif

/// Platform fallback: honest "no accessibility here" rather than a stub that
/// pretends to read. Used on any platform without ApplicationServices.
public struct UnavailableMacAXElementSource: MacAXElementSource {
    public init() {}
    public func isTrusted() -> Bool { false }
    public func frontmostApp() -> MacAXAppInfo? { nil }
    public func frontmostWindowRoot() -> MacAXElementRef? { nil }
    public func attributes(of ref: MacAXElementRef) -> MacAXAttributes? { nil }
    public func children(of ref: MacAXElementRef) -> [MacAXElementRef] { [] }
}

public func defaultMacAXElementSource() -> any MacAXElementSource {
    #if canImport(ApplicationServices) && os(macOS)
    return SystemMacAXElementSource()
    #else
    return UnavailableMacAXElementSource()
    #endif
}
