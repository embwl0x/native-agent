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
    public let frame: MacAXFrame?
    public let actions: [String]

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        enabled: Bool = true,
        frame: MacAXFrame? = nil,
        actions: [String] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.enabled = enabled
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

/// Read-only element access. Every method is failure-tolerant by contract:
/// an element that cannot be read returns nil / empty rather than throwing,
/// because a half-readable tree is still useful perception.
public protocol MacAXElementSource: Sendable {
    /// `AXIsProcessTrusted()` in production.
    func isTrusted() -> Bool
    func frontmostApp() -> MacAXAppInfo?
    /// Frontmost (focused, else main, else first) window of the frontmost app.
    func frontmostWindowRoot() -> MacAXElementRef?
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
}

public extension MacAXElementSource {
    func childCount(of ref: MacAXElementRef) -> Int { children(of: ref).count }
    func children(of ref: MacAXElementRef, limit: Int) -> [MacAXElementRef] {
        limit <= 0 ? [] : Array(children(of: ref).prefix(limit))
    }
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
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
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
