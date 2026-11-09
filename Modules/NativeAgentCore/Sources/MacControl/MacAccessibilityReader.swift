import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
// Blueprint: | `MacAccessibilityReader.swift` | `SystemMacAXElementSource`: Bounded read-only walker; exact window/menu roots |
#endif
// The walker is read-only: structured AX data needs no input synthesis. Renderer preparation may enable an advertised mode without emitting UI input.
public enum MacAccessibilityReader {
    package struct NativeReadFailure: Error, LocalizedError {
        package let detail: String
        package init(detail: String) { self.detail = detail }
        package var errorDescription: String? { detail }
    }
    private actor NativeReads {
        func read<Value: Sendable>(context: MacOperationContext, _ body: @Sendable (MacOperationContext) throws -> Value) throws -> Value {
            try Task.checkCancellation()
            return try MacAccessibilityReader.withReadBudget(context: context, body)
        }
    }
    private static let nativeReads = NativeReads()
    package static func withReadBudget<Value>(context: MacOperationContext, _ body: (MacOperationContext) throws -> Value) throws -> Value {
        #if canImport(ApplicationServices) && os(macOS)
        return try MacAXAttributeRead.checked(context: context) { context in
            try context.holding(
                \.readDeadline, context.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds), { context in try body(context) })
        }
        #else
        return try context.holding(
            \.readDeadline, context.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds), { context in try body(context) })
        #endif
    }
    /// Passive native clients share the hands' deadline and cancellation. Only Sendable results leave it; native AX handles stay in the read.
    package static func read<Value: Sendable>(context: MacOperationContext,
        _ body: @escaping @Sendable (MacOperationContext) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let value = try await nativeReads.read(context: context, body)
        try Task.checkCancellation()
        return value
    }
    #if canImport(ApplicationServices) && os(macOS)
    /// Read only static text values so credential fields never enter this text channel.
    package static func nativeText(in root: AXUIElement, context: MacOperationContext) throws -> String {
        try withReadBudget(context: context) { context in
            let (source, snapshot) = try nativeSnapshot(in: root, searching: "the desktop reply text", context: context)
            let children = Dictionary(grouping: snapshot.nodes.filter { !$0.path.isEmpty }, by: { Array($0.path.dropLast()) })
            var rendered: [[Int]: String] = [:]
            for node in snapshot.nodes.reversed() {
                var text = "", previousInline = false
                if node.attributes.role == kAXStaticTextRole, let ref = node.element, let element = source.element(ref) {
                    text = try MacAXAttributeRead.checkedText(element, kAXValueAttribute, context: context)
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
            guard context.readDeadline.map({ Date() < $0 }) == true else {
                throw NativeReadFailure(detail: """
                    Accessibility search for the desktop reply text exhausted the shared reader time budget while rendering \(snapshot.nodes.count) elements. \
                    Narrow the search to the intended message before continuing.
                    """)
            }
            return rendered[[]] ?? ""
        }
    }
    /// A native window/subtree read through the ordinary hands walker. Read topology only: credential values are never collected into a snapshot. A caller may
    /// exclude a known unrelated region (such as a chat log).
    package static func elements(in root: AXUIElement, searching: String,
        context: MacOperationContext, descendInto: @escaping (AXUIElement) -> Bool = { _ in true }) throws -> [AXUIElement] {
        let (source, snapshot) = try nativeSnapshot(in: root, searching: searching, context: context, descendInto: descendInto)
        return snapshot.nodes.compactMap { $0.element.flatMap(source.element) }
    }
    package static func nativeSnapshot(in root: AXUIElement, searching: String,
        context: MacOperationContext, descendInto: @escaping (AXUIElement) -> Bool = { _ in true }) throws -> (SystemMacAXElementSource, MacAXTreeSnapshot) {
        try MacAXAttributeRead.checked(context: context) { context in try nativeSnapshotRead(in: root, searching: searching, context: context,
            descendInto: descendInto) }
    }
    private static func nativeSnapshotRead(in root: AXUIElement, searching: String,
        context: MacOperationContext, descendInto: @escaping (AXUIElement) -> Bool) throws -> (SystemMacAXElementSource, MacAXTreeSnapshot) {
        try Task.checkCancellation()
        let deadline = context.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds)
        return try context.holding(\.readDeadline, deadline) { context in
            try SystemMacAXElementSource.ensureRenderer(root, refresh: true, context: context)
            let source = SystemMacAXElementSource()
            var failures: [Int: String] = [:], unreadable: [String] = []
            let snapshot = walk(source: source, root: source.mint(root), limits: .deepPage,
                read: { ref, context in
                    do { return try source.checkedTopologyAttributes(of: ref, context: context) }
                    catch { failures[ref.id] = error.localizedDescription; return nil }
                }, deadline: deadline, descendInto: { ref in
                    source.element(ref).map(descendInto) ?? false
                }, onUnreadable: { ref, path in
                    unreadable.append("window/subtree path \(path): \(failures[ref.id] ?? "AX attributes unavailable")")
                }, context: context)
            try Task.checkCancellation()
            guard !snapshot.truncated else {
                let budget = snapshot.truncationReasons.contains { ["node_cap", "depth_cap", "time_budget"].contains($0) }
                throw NativeReadFailure(detail: """
                    Accessibility search for \(searching) \(budget ? "exhausted the shared reader budget" : "was incomplete"): read \(snapshot.nodes.count) \
                    elements; at least \(snapshot.skippedAtLeast) elements unexamined; reasons: \(snapshot.truncationReasons.joined(separator: ", ")). \
                    Limits: \(MacAXLimits.deepPage.maxNodes) elements, depth \(MacAXLimits.deepPage.maxDepth), \(MacAXLimits.readSeconds) seconds.\u{20}
                    """
                    + (unreadable.isEmpty ? "" : "Unreadable: " + unreadable.prefix(4).joined(separator: "; ") + ". ")
                    + (budget ? "Narrow the search to the intended section before continuing." : "Check the app's Accessibility tree before continuing."))
            }
            return (source, snapshot)
        }
    }
    /// Direct children still need a complete bounded read: an AX failure or a child-array cap cannot masquerade as an empty or shorter conversation.
    package static func childElements(in root: AXUIElement, searching: String, context: MacOperationContext) throws -> [AXUIElement] {
        Array(try elements(in: root, searching: searching, context: context, descendInto: { CFEqual($0, root) }).dropFirst())
    }
    /// Find a positively identified content region before reading its subtree. Unreadable window chrome cannot make a readable region disappear; no match after
    /// an incomplete search is still a read failure, never absence.
    package static func contentRegion(in root: AXUIElement, role: String, context: MacOperationContext) throws -> AXUIElement {
        try withReadBudget(context: context) { context in
            try SystemMacAXElementSource.ensureRenderer(root, refresh: true, context: context)
            let source = SystemMacAXElementSource()
            var failures: [Int: String] = [:]
            let result = findFirst(source: source, root: source.mint(root),
                maxDepth: MacAXLimits.deepPage.maxDepth, nodeBudget: MacAXLimits.deepPage.maxNodes,
                read: { ref, context in
                    do { return try source.checkedTopologyAttributes(of: ref, context: context) }
                    catch { failures[ref.id] = error.localizedDescription; return nil }
                },
                onUnreadable: { ref, path in
                    nativeLog("Desktop content region search could not read window path %@: %@; that element remains unreadable, not empty.",
                        String(describing: path), failures[ref.id] ?? "AX attributes unavailable")
                },
                shouldStop: { Task.isCancelled || context.readDeadline.map { Date() >= $0 } == true }, context: context) { _, attributes in
                    attributes.role == role
                }
            try Task.checkCancellation()
            if let hit = result.hit, let region = source.element(hit.ref) { return region }
            throw NativeReadFailure(detail: "Accessibility search for the desktop content region \(role) "
                + (result.truncationReason.map { "was incomplete: \($0)." } ?? "found no matching region.")
                + " Check the app's Accessibility tree before continuing.")
        }
    }
    #endif
    public static func captureContinuation(pid: Int32?, taskReference: String, context: MacOperationContext) async -> MacWorkContinuation {
        #if canImport(ApplicationServices) && canImport(AppKit) && os(macOS)
        return await SystemMacAXElementSource().captureContinuation(pid: pid, taskReference: taskReference, context: context)
        #else
        return .unsupported("accessibility_unsupported", taskReference: taskReference)
        #endif
    }
    public static let notTrustedNote =
        "NativeAgent does not have Accessibility permission yet. Grant it in "
        + "System Settings → Privacy & Security → Accessibility (toggle NativeAgent on), "
        + "then retry. Only you can grant this — the app cannot toggle it."
    /// The ellipsis replaces a kept character so the result never exceeds its character cap.
    public static func truncate(_ raw: String, to limit: Int) -> String {
        let cap = max(1, limit)
        guard raw.count > cap else { return raw }
        return String(raw.prefix(cap - 1)) + "…"
    }
    /// Root depth is one, so maxDepth levels yield paths with at most maxDepth minus one components.
    public static func walk(
        source: any MacAXElementSource,
        root: MacAXElementRef,
        limits: MacAXLimits = MacAXLimits(),
        complete: Bool = false,
        read: ((MacAXElementRef, MacOperationContext) throws -> MacAXAttributes?)? = nil,
        deadline: Date? = nil,
        stopAtCut: Bool = false,
        descendInto: ((MacAXElementRef) -> Bool)? = nil,
        skipping: ((MacAXElementRef, MacOperationContext) -> Bool)? = nil,
        onUnreadable: ((MacAXElementRef, [Int]) -> Void)? = nil,
        context: MacOperationContext, shouldStop: () -> Bool = { Task.isCancelled }) -> MacAXTreeSnapshot {
        let limits = complete ? MacAXLimits.deepPage : limits
        let deadline = deadline ?? context.readDeadline ?? Date().addingTimeInterval(MacAXLimits.readSeconds)
        var nodes: [MacAXNode] = []
        var skipped = 0
        var reasons: Set<String> = []
        var readFailures: [String] = []
        // Explicit stack so a deep tree cannot blow the Swift stack, and so the node cap is enforced BEFORE any further child enumeration.
        var stack: [(ref: MacAXElementRef, path: [Int], depth: Int)] = [(root, [], 1)]
        var seen: [Int: [MacAXElementRef]] = [:]
        while let item = stack.popLast() {
            // A caller that only needs to know whether the walk was whole stops at the first cut.
            if stopAtCut, !reasons.isEmpty { break }
            if shouldStop() || Task.isCancelled || Date() >= deadline {
                skipped += 1 + stack.count
                reasons.insert(Date() >= deadline ? "time_budget" : "interrupted")
                break
            }
            if nodes.count >= limits.maxNodes {
                // Everything still pending is unseen. Count it and stop; we do not enumerate its children, hence "at least".
                skipped += 1 + stack.count
                reasons.insert("node_cap")
                break
            }
            // Deduplicate native identity because multiple parents can list one element.
            let hash = source.elementHash(item.ref) ?? item.ref.id
            if seen[hash]?.contains(where: { source.sameElement($0, item.ref) }) == true { continue }
            seen[hash, default: []].append(item.ref)
            if skipping?(item.ref, context) == true { continue }
            let readAttributes: MacAXAttributes?
            do {
                if let read { readAttributes = try read(item.ref, context) }
                else { readAttributes = try source.checkedAttributes(of: item.ref, context: context) }
            } catch {
                readAttributes = nil
                if readFailures.count < 8 { readFailures.append("path \(item.path): \(error.localizedDescription)") }
            }
            guard let attributes = readAttributes else {
                skipped += 1
                reasons.insert("unreadable_element")
                onUnreadable?(item.ref, item.path)
                continue
            }
            if attributes.isHiddenMenuItem { continue }
            // Menu bars belong to the app; exclude them so window reads reserve their budget for window content.
            if attributes.role == "AXMenuBar", !item.path.isEmpty { continue }
            nodes.append(MacAXNode(attributes: attributes, path: item.path, element: item.ref))
            if descendInto?(item.ref) == false { continue }
            if shouldStop() { reasons.insert("interrupted"); break }
            // An element whose children the app did not report (an AX error or the per-message timeout) is a cut, never an empty subtree.
            let total: Int
            do { total = try source.checkedChildCount(of: item.ref, context: context) }
            catch {
                reasons.insert("ax_error")
                if readFailures.count < 8 { readFailures.append("path \(item.path): \(error.localizedDescription)") }
                continue
            }
            if item.depth >= limits.maxDepth {
                // Count without bridging arrays merely to report children cut by the depth cap.
                if total > 0 {
                    skipped += total
                    reasons.insert("depth_cap")
                }
                continue
            }
            // Fetch only children that can fit the remaining node budget; bridging a pathological node's whole array would waste memory.
            let budget = max(0, limits.maxNodes - nodes.count - stack.count)
            if shouldStop() { reasons.insert("interrupted"); break }
            let children: [MacAXElementRef]
            do { children = try source.checkedChildren(of: item.ref, limit: min(total, budget), context: context) }
            catch {
                reasons.insert("ax_error")
                skipped += total
                if readFailures.count < 8 { readFailures.append("path \(item.path): \(error.localizedDescription)") }
                continue
            }
            // A read that asked for every child has the app's whole answer: some elements report a count their children do not bear out (Music's text fields).
            if total > budget, total > children.count {
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
            skippedAtLeast: skipped,
            readFailures: readFailures
        )
    }
    /// Targeted descent uses the shared read-only source and stops at the first role match. Breadth-first search reaches web areas without spending its budget
    /// in one bookmark branch.
    public static let findFirstMaxDepth = 24
    public static let findFirstNodeBudget = 160
    /// Absence requires a complete search; exhausted budgets and unreadable branches carry named reasons.
    public enum FindFirstResult: Sendable, Equatable {
        case found(ref: MacAXElementRef, path: [Int])
        case notFound
        case depthCap
        case nodeCap
        case interrupted
        /// An unanswered child read leaves unseen branches, not proven absence.
        case axError
        public var hit: (ref: MacAXElementRef, path: [Int])? {
            guard case .found(let ref, let path) = self else { return nil }
            return (ref, path)
        }
        /// Report unfinished searches with a reason; found results need none.
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
        context: MacOperationContext, shouldStop: () -> Bool = { false }) -> FindFirstResult {
        findFirst(source: source, root: root, maxDepth: maxDepth, nodeBudget: nodeBudget, shouldStop: shouldStop, context: context) { _, attributes in
            attributes.role == role
        }
    }
    /// Predicate search skips hollow web areas and finds named controls beyond the ordinary walk's caps.
    public static func findFirst(
        source: any MacAXElementSource,
        root: MacAXElementRef,
        maxDepth: Int,
        nodeBudget: Int,
        read: ((MacAXElementRef, MacOperationContext) -> MacAXAttributes?)? = nil,
        onUnreadable: ((MacAXElementRef, [Int]) -> Void)? = nil,
        shouldStop: () -> Bool = { false },
        context: MacOperationContext, where matches: (MacAXElementRef, MacAXAttributes) -> Bool) -> FindFirstResult {
        func node<Value>(_ body: (MacOperationContext) throws -> Value) throws -> Value {
            #if canImport(ApplicationServices) && os(macOS)
            return try MacAXAttributeRead.node(context: context, body)
            #else
            return try body(context)
            #endif
        }
        var queue: [(ref: MacAXElementRef, path: [Int], depth: Int)] = [(root, [], 1)]
        var visited = 0
        var index = 0
        // Set the moment a budget stops the search short of an element that could still have carried the role. A search that examined everything reachable
        // leaves both false, and only then is `notFound` the truth.
        var hitDepthCap = false
        var hitNodeCap = false
        var hitAXError = false
        func count(_ ref: MacAXElementRef) -> Int? {
            do { return try node() { context in try source.checkedChildCount(of: ref, context: context) } }
            catch { hitAXError = true; return nil }
        }
        while index < queue.count {
            if shouldStop() || Task.isCancelled || context.readDeadline.map({ Date() >= $0 }) == true { return .interrupted }
            let item = queue[index]
            index += 1
            visited += 1
            // Keep the loop's hard stop even though queue clamping already ensures visited plus pending plus newly fetched never exceeds the node budget.
            if visited > max(1, nodeBudget) { return .nodeCap }
            let attributes: MacAXAttributes?
            do {
                attributes = try node() { context in
                    if let read { return read(item.ref, context) }
                    return try source.checkedAttributes(of: item.ref, context: context)
                }
            } catch { attributes = nil }
            if attributes == nil { hitAXError = true; onUnreadable?(item.ref, item.path) }
            if let attributes, matches(item.ref, attributes) {
                // The root can itself be the requested web area; matching must precede descent.
                return .found(ref: item.ref, path: item.path)
            }
            if shouldStop() { return .interrupted }
            guard item.depth < max(1, maxDepth) else {
                if count(item.ref) != 0 { hitDepthCap = true }
                continue
            }
            let remaining = max(0, max(1, nodeBudget) - visited - (queue.count - index))
            guard remaining > 0 else {
                if count(item.ref) != 0 { hitNodeCap = true }
                continue
            }
            // An unanswered child list leaves the search unfinished, never "not found".
            guard let total = count(item.ref) else { continue }
            if shouldStop() { return .interrupted }
            let children: [MacAXElementRef]
            do { children = try node() { context in try source.checkedChildren(of: item.ref, limit: remaining, context: context) } }
            catch { hitAXError = true; continue }
            // Fewer than the budget allowed is the copy failing, not the cap.
            if total > remaining {
                if children.count < remaining { hitAXError = true } else { hitNodeCap = true }
            }
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
    /// All predicates must match; ranking orders survivors. Title matches dominate value matches because named controls are the primary target; actionable
    /// controls beat decoration.
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
        // Order by score, title specificity, then document path; sort stability must not decide visible rankings.
        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsLength = lhs.node.attributes.title?.count ?? Int.max
            let rhsLength = rhs.node.attributes.title?.count ?? Int.max
            if lhsLength != rhsLength { return lhsLength < rhsLength }
            return MacPerceptionCompiler.pathIsBefore(lhs.node.path, rhs.node.path)
        }
        return Array(matches.prefix(limits.maxMatches))
    }
    /// `"button"`, `"Button"` and `"AXButton"` all address AXButton. Roles are an AX vocabulary, not free text, so the AX prefix is optional.
    static func roleMatches(_ role: String, query: String) -> Bool {
        let lhs = role.lowercased()
        let rhs = query.lowercased()
        if lhs == rhs { return true }
        return lhs == "ax" + rhs
    }
    static func textScore(_ candidate: String, query: String, weight: Double) -> Double? {
        let lhs = candidate.lowercased()
        let rhs = query.lowercased()
        if lhs == rhs { return weight }
        if lhs.hasPrefix(rhs) { return weight * (2.0 / 3.0) }
        if lhs.contains(rhs) { return weight * (1.0 / 3.0) }
        return nil
    }
}
/// Unsupported platforms report accessibility unavailable rather than pretend to read.
public struct UnavailableMacAXElementSource: MacAXElementSource {
    public init() {}
    public func isTrusted() -> Bool { false }
    public func frontmostApp() -> MacAXAppInfo? { nil }
    public func frontmostWindowRoot(context: MacOperationContext) -> MacAXElementRef? { nil }
    public func attributes(of ref: MacAXElementRef, context: MacOperationContext) -> MacAXAttributes? { nil }
    public func children(of ref: MacAXElementRef, context: MacOperationContext) -> [MacAXElementRef] { [] }
}
public func defaultMacAXElementSource() -> any MacAXElementSource {
    #if canImport(ApplicationServices) && os(macOS)
    return SystemMacAXElementSource()
    #else
    return UnavailableMacAXElementSource()
    #endif
}
