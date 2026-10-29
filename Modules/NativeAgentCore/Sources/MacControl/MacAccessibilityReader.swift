import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
// Blueprint: | `MacAccessibilityReader.swift` | Shared AX walker and node/depth/time budgets; package-native window/subtree and direct-child reads use that walker with topology-only snapshots and optional caller-scoped descent, report incomplete reads with search purpose, visited count, unseen floor and reasons, and never collect credential values; passive native reads share its deadline and cancellation; native reply text requires readable static AXValues and checked topology subroles; `SystemMacAXElementSource` owns exact native window inventory and transient menu roots |
#endif
//
// Accessibility-first perception: macOS already hands every app's UI to the
// Accessibility API as STRUCTURED DATA (role, title, value, enabled, frame,
// available AX actions). Reading that tree is the alternative to the
// screenshot→vision→guess-coordinates loop. This file is the read half only:
// there is deliberately NO CGEvent, no AXUIElementPerformAction, no
// AXUIElementSetAttributeValue anywhere in it. Perception cannot mutate.
//
// `MacAXElementSource` supplies elements; `MacAccessibilityReader` owns the bounded
// walk, honest truncation accounting, string capping and ax_find ranking.
public enum MacAccessibilityReader {
    private actor NativeReads {
        func read<Value: Sendable>(_ body: @Sendable () throws -> Value) throws -> Value {
            try Task.checkCancellation()
            return try MacAccessibilityReader.withReadBudget(body)
        }
    }
    private static let nativeReads = NativeReads()
    package static func withReadBudget<Value>(_ body: () throws -> Value) rethrows -> Value {
        try MacAXLimits.$readDeadline.withValue(
            MacAXLimits.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds), operation: body)
    }
    /// Passive native clients share the hands' deadline and cancellation.
    /// Only Sendable results leave it; native AX handles stay in the read.
    package static func read<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let value = try await nativeReads.read(body)
        try Task.checkCancellation()
        return value
    }
    #if canImport(ApplicationServices) && os(macOS)
    /// Render the shared walk's exact child paths in block/inline reading order.
    /// Only static text values are read; fields never enter this text channel.
    package static func nativeText(in root: AXUIElement) throws -> String {
        try withReadBudget {
            let (source, snapshot) = try nativeSnapshot(in: root, searching: "the desktop reply text")
            let children = Dictionary(grouping: snapshot.nodes.filter { !$0.path.isEmpty }, by: { Array($0.path.dropLast()) })
            var rendered: [[Int]: String] = [:]
            for node in snapshot.nodes.reversed() {
                var text = "", previousInline = false
                if node.attributes.role == kAXStaticTextRole, let ref = node.element, let element = source.element(ref) {
                    // A failed read throws; an empty static text is just empty.
                    text = try MacAXAttributeRead.checkedText(element, kAXValueAttribute)
                } else {
                    for child in children[node.path] ?? [] {
                        guard let part = rendered[child.path], !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        let inline = child.attributes.subrole == "AXCodeStyleGroup" || child.attributes.role == "AXLink"
                        if text.isEmpty || inline || previousInline || text.last?.isWhitespace == true
                            || part.first.map({ $0.isWhitespace || $0.isPunctuation }) == true { text += part }
                        else { text += "\n" + part }
                        previousInline = inline
                    }
                }
                rendered[node.path] = text
            }
            try Task.checkCancellation()
            guard MacAXLimits.readDeadline.map({ Date() < $0 }) == true else {
                throw NativeReadFailure(detail: "Accessibility search for the desktop reply text exhausted the shared reader time budget while rendering \(snapshot.nodes.count) elements. Narrow the search to the intended message before continuing.")
            }
            return rendered[[]] ?? ""
        }
    }
    package struct NativeReadFailure: Error, LocalizedError {
        package let detail: String
        package init(detail: String) { self.detail = detail }
        package var errorDescription: String? { detail }
    }
    /// A native window/subtree read through the ordinary hands walker. Read
    /// topology only: credential values are never collected into a snapshot.
    /// A caller may exclude a known unrelated region (such as a chat log).
    package static func elements(in root: AXUIElement, searching: String,
        descendInto: @escaping (AXUIElement) -> Bool = { _ in true }) throws -> [AXUIElement] {
        let (source, snapshot) = try nativeSnapshot(in: root, searching: searching, descendInto: descendInto)
        return snapshot.nodes.compactMap { $0.element.flatMap(source.element) }
    }
    package static func nativeSnapshot(in root: AXUIElement, searching: String,
        descendInto: @escaping (AXUIElement) -> Bool = { _ in true }) throws -> (SystemMacAXElementSource, MacAXTreeSnapshot) {
        try Task.checkCancellation()
        let deadline = MacAXLimits.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds)
        return try MacAXLimits.$readDeadline.withValue(deadline) {
            let source = SystemMacAXElementSource()
            let snapshot = walk(source: source, root: source.mint(root), limits: .deepPage,
                read: source.topologyAttributes, deadline: deadline, descendInto: { ref in
                    source.element(ref).map(descendInto) ?? false
                })
            try Task.checkCancellation()
            guard !snapshot.truncated else {
                let budget = snapshot.truncationReasons.contains { ["node_cap", "depth_cap", "time_budget"].contains($0) }
                throw NativeReadFailure(detail: "Accessibility search for \(searching) \(budget ? "exhausted the shared reader budget" : "was incomplete"): read \(snapshot.nodes.count) elements; at least \(snapshot.skippedAtLeast) elements unexamined; reasons: \(snapshot.truncationReasons.joined(separator: ", ")). Limits: \(MacAXLimits.deepPage.maxNodes) elements, depth \(MacAXLimits.deepPage.maxDepth), \(MacAXLimits.readSeconds) seconds. \(budget ? "Narrow the search to the intended section before continuing." : "Check the app's Accessibility tree before continuing.")")
            }
            return (source, snapshot)
        }
    }
    /// Direct children still need a complete bounded read: an AX failure or a
    /// child-array cap cannot masquerade as an empty or shorter conversation.
    package static func childElements(in root: AXUIElement, searching: String) throws -> [AXUIElement] {
        Array(try elements(in: root, searching: searching, descendInto: { CFEqual($0, root) }).dropFirst())
    }
    #endif
    public static func captureContinuation(pid: Int32?, taskReference: String) -> MacWorkContinuation {
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        return MacAXExecutionLane.sync {
            SystemMacAXElementSource().captureContinuation(pid: pid, taskReference: taskReference)
        }
        #else
        return .unsupported("accessibility_unsupported", taskReference: taskReference)
        #endif
    }
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
        limits: MacAXLimits = MacAXLimits(),
        complete: Bool = false,
        read: ((MacAXElementRef) -> MacAXAttributes?)? = nil,
        deadline: Date? = nil,
        stopAtCut: Bool = false,
        descendInto: ((MacAXElementRef) -> Bool)? = nil,
        shouldStop: () -> Bool = { Task.isCancelled }
    ) -> MacAXTreeSnapshot {
        let limits = complete ? MacAXLimits.deepPage : limits
        let deadline = deadline ?? MacAXLimits.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds)
        var nodes: [MacAXNode] = []
        var skipped = 0
        var reasons: Set<String> = []
        // Explicit stack so a deep tree cannot blow the Swift stack, and so
        // the node cap is enforced BEFORE any further child enumeration.
        var stack: [(ref: MacAXElementRef, path: [Int], depth: Int)] = [(root, [], 1)]
        var seen: [Int: [MacAXElementRef]] = [:]
        while let item = stack.popLast() {
            // A caller that only needs to know whether the walk was whole
            // stops at the first cut.
            if stopAtCut, !reasons.isEmpty { break }
            if shouldStop() || Task.isCancelled || Date() >= deadline {
                skipped += 1 + stack.count
                reasons.insert(Date() >= deadline ? "time_budget" : "interrupted")
                break
            }
            if nodes.count >= limits.maxNodes {
                // Everything still pending is unseen. Count it and stop; we do
                // not enumerate its children, hence "at least".
                skipped += 1 + stack.count
                reasons.insert("node_cap")
                break
            }
            // Visit an element once even when multiple parents list it.
            let hash = source.elementHash(item.ref) ?? item.ref.id
            if seen[hash]?.contains(where: { source.sameElement($0, item.ref) }) == true { continue }
            seen[hash, default: []].append(item.ref)
            guard let attributes = read.map({ $0(item.ref) }) ?? source.attributes(of: item.ref) else {
                skipped += 1
                reasons.insert("unreadable_element")
                continue
            }
            if attributes.isHiddenMenuItem { continue }
            // The menu bar belongs to the APP, not the window: a window read
            // never spends its budget there (the `menu` organ reads it).
            if attributes.role == "AXMenuBar", !item.path.isEmpty { continue }
            nodes.append(MacAXNode(attributes: attributes, path: item.path, element: item.ref))
            if descendInto?(item.ref) == false { continue }
            if shouldStop() { reasons.insert("interrupted"); break }
            // An element whose children the app did not report (an AX error
            // or the per-message timeout) is a cut, never an empty subtree.
            guard let total = source.childCount(of: item.ref) else {
                reasons.insert("ax_error")
                continue
            }
            if item.depth >= limits.maxDepth {
                // Count-only: never materialize the child array just to report
                // how many were cut at the depth boundary.
                if total > 0 {
                    skipped += total
                    reasons.insert("depth_cap")
                }
                continue
            }
            // Bounded fetch: children beyond the remaining node budget can never
            // be appended (the node-cap break fires first when popped), so
            // materializing the whole array is pure waste and a pathological node
            // could force a huge bridge. Fetch only what could still fit; count
            // the un-fetched remainder without materializing it.
            let budget = max(0, limits.maxNodes - nodes.count - stack.count)
            if shouldStop() { reasons.insert("interrupted"); break }
            let children = source.children(of: item.ref, limit: min(total, budget))
            if total > children.count {
                skipped += total - children.count
                // Fewer than the budget allowed is the copy failing, not the cap.
                reasons.insert(children.count < min(total, budget) ? "ax_error" : "node_cap")
            }
            // Reverse-push so pop order is left-to-right preorder.
            for (index, child) in children.enumerated().reversed() {
                stack.append((child, item.path + [index], item.depth + 1))
            }
        }
        if Date() >= deadline { reasons.insert("time_budget") }
        return MacAXTreeSnapshot(
            nodes: nodes,
            truncated: !reasons.isEmpty,
            truncationReasons: reasons.sorted(),
            skippedAtLeast: skipped
        )
    }
    /// Targeted descent uses the shared read-only source and stops at the first role match.
    /// Breadth-first search reaches web areas without spending its budget in one bookmark branch.
    public static let findFirstMaxDepth = 24
    public static let findFirstNodeBudget = 160
    /// Absence requires a complete search; exhausted budgets and unreadable branches carry named reasons.
    public enum FindFirstResult: Sendable, Equatable {
        case found(ref: MacAXElementRef, path: [Int])
        /// The search covered everything reachable under both budgets and the
        /// role is genuinely not there.
        case notFound
        /// The search stopped at the depth ceiling with children unexamined.
        case depthCap
        /// The search stopped at the node budget with the queue non-empty.
        case nodeCap
        /// The caller cancelled the search or reached its deadline.
        case interrupted
        /// The app did not answer a child read, so part of the tree is unseen.
        case axError
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
            case .interrupted: return "interrupted"
            case .axError: return "ax_error"
            }
        }
    }
    public static func findFirst(
        role: String,
        source: any MacAXElementSource,
        root: MacAXElementRef,
        maxDepth: Int = MacAccessibilityReader.findFirstMaxDepth,
        nodeBudget: Int = MacAccessibilityReader.findFirstNodeBudget,
        shouldStop: () -> Bool = { false }
    ) -> FindFirstResult {
        findFirst(source: source, root: root, maxDepth: maxDepth, nodeBudget: nodeBudget, shouldStop: shouldStop) { _, attributes in
            attributes.role == role
        }
    }
    /// The same bounded breadth-first search with a caller's predicate — used
    /// to skip a hollow `AXWebArea` (Claude.app carries an empty overlay web
    /// view ahead of the real page) and to find a control by NAME when the
    /// ordinary walk's caps stopped short of it.
    public static func findFirst(
        source: any MacAXElementSource,
        root: MacAXElementRef,
        maxDepth: Int,
        nodeBudget: Int,
        shouldStop: () -> Bool = { false },
        where matches: (MacAXElementRef, MacAXAttributes) -> Bool
    ) -> FindFirstResult {
        var queue: [(ref: MacAXElementRef, path: [Int], depth: Int)] = [(root, [], 1)]
        var visited = 0
        var index = 0
        // Set the moment a budget stops the search short of an element that
        // could still have carried the role. A search that examined everything
        // reachable leaves both false, and only then is `notFound` the truth.
        var hitDepthCap = false
        var hitNodeCap = false
        var hitAXError = false
        while index < queue.count {
            if shouldStop() { return .interrupted }
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
            if let attributes = source.attributes(of: item.ref), matches(item.ref, attributes) {
                // The ROOT itself matching is a real answer — a window that IS
                // the web area needs no descent.
                return .found(ref: item.ref, path: item.path)
            }
            if shouldStop() { return .interrupted }
            guard item.depth < max(1, maxDepth) else {
                if source.childCount(of: item.ref) != 0 { hitDepthCap = true }
                continue
            }
            let remaining = max(0, max(1, nodeBudget) - visited - (queue.count - index))
            guard remaining > 0 else {
                if source.childCount(of: item.ref) != 0 { hitNodeCap = true }
                continue
            }
            // An unanswered child list leaves the search unfinished, never "not found".
            guard let total = source.childCount(of: item.ref) else { hitAXError = true; continue }
            if shouldStop() { return .interrupted }
            let children = source.children(of: item.ref, limit: remaining)
            // Fewer than the budget allowed is the copy failing, not the cap.
            if children.count < min(total, remaining) { hitAXError = true }
            else if total > children.count { hitNodeCap = true }
            for (childIndex, child) in children.enumerated() {
                queue.append((child, item.path + [childIndex], item.depth + 1))
            }
        }
        // Report unanswered reads before caps, then node cap before depth cap.
        if hitAXError { return .axError }
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
            return MacPerceptionCompiler.pathIsBefore(lhs.node.path, rhs.node.path)
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
}
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
