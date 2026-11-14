import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MacMenuBar.swift` | Scoped AX gaps; exact-branch press discovery retains siblings; normalized paths and choices share identity |

public enum MacMenuBar {
    public static let maxPathDepth = 3
    public static let findPathDepth = 5
    /// Hitting a presentation bound must mark the read truncated.
    public static let maxItems = 160
    /// Unnamed AX wrappers still consume the child budget.
    public static let maxChildrenPerMenu = 60
    /// Bound anomalously long titles such as document names in the Window menu.
    public static let maxTitleChars = 80
    /// Allow whole titles plus separators so budgeting cannot truncate an address.
    public static func pathChars(_ depth: Int) -> Int { maxTitleChars * depth + 3 * (depth - 1) }

    /// Accept common separators so typography cannot prevent menu addressing.
    public static let separators: [String] = ["›", "»", "->", "→", ">", "/", "|"]

    public struct Item: Sendable, Equatable {
        public let titlePath: [String]
        /// Child-index addresses stay private; the model names paths rather than AX bookkeeping.
        public let path: [Int]
        public let enabled: Bool?
        /// Nil when an unrelated sibling's children were not read; submenu openers remain actionable.
        public let hasSubmenu: Bool?
        public let commandKey: String?
        public let attributeGaps: [String]

        public init(
            titlePath: [String],
            path: [Int],
            enabled: Bool?,
            hasSubmenu: Bool?,
            commandKey: String? = nil,
            attributeGaps: [String] = []
        ) {
            self.titlePath = titlePath
            self.path = path
            self.enabled = enabled
            self.hasSubmenu = hasSubmenu
            self.commandKey = commandKey
            self.attributeGaps = attributeGaps
        }

        public var display: String { titlePath.joined(separator: " › ") }
    }

    public struct Reading: Sendable, Equatable {
        public let items: [Item]
        /// Truncation distinguishes an absent command from an incomplete search.
        public let truncated: Bool
        public let unavailable: String?
        /// Unseen names still count toward the bounded walk.
        public let attributeGaps: [String]

        public init(items: [Item], truncated: Bool, unavailable: String? = nil, attributeGaps: [String] = []) {
            self.items = items
            self.truncated = truncated
            self.unavailable = unavailable
            self.attributeGaps = attributeGaps
        }
    }

    // MARK: - The walk

    /// AXMenu wrappers consume tree depth but not named depth; bound the levels a person can address. Exact-path descent retains siblings so duplicate checks
    /// remain complete.
    public static func read(
        source: any MacAXElementSource,
        pid: Int32,
        top: String? = nil,
        until stop: ((Item) -> Bool)? = nil,
        matchingPath: [String]? = nil,
        depth: Int = maxPathDepth,
        context: MacOperationContext
    ) -> Reading {
        do {
            return try MacAccessibilityReader.withReadBudget(context: context) { context in
                try readChecked(source: source, pid: pid, top: top, until: stop, matchingPath: matchingPath, depth: depth, context: context)
            }
        } catch {
            return Reading(items: [], truncated: true, unavailable: error.localizedDescription)
        }
    }

    private static func readChecked(source: any MacAXElementSource, pid: Int32, top: String?,
                                    until stop: ((Item) -> Bool)?, matchingPath: [String]?, depth: Int, context: MacOperationContext) throws -> Reading {
        guard !PersonOnlyWindows.isOwnProcess(pid) else {
            return Reading(items: [], truncated: false, unavailable: "self_process")
        }
        guard source.isTrusted() else {
            return Reading(items: [], truncated: false, unavailable: "accessibility_not_trusted")
        }
        guard let root = source.menuBarRoot(pid: pid, context: context) else {
            return Reading(items: [], truncated: false, unavailable: "no_menu_bar")
        }
        var items: [Item] = []
        var attributeGaps: [String] = []
        var truncated = false
        var inMenu = 0
        var done = false
        let wantedTop = top.map(normalized)
        let wantedPath = matchingPath.map { $0.map(normalized) }

        let namedDepth = max(1, min(depth, findPathDepth))
        // Bound unnamed wrappers and total visits as well as named levels.
        let structuralDepth = namedDepth * 2 + 1
        let maxNodes = MacAXLimits.deepPageMaxNodes
        var pending: [(element: MacAXElementRef, titles: [String], indices: [Int])] = []
        var visited: [Int: [MacAXElementRef]] = [:]
        var nodeCount = 0

        func checkDeadline() throws {
            try Task.checkCancellation()
            if context.readDeadline.map({ Date() >= $0 }) == true {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Menu reading exhausted the shared AX time budget; menu coverage is incomplete.")
            }
        }
        func children(_ element: MacAXElementRef) throws -> [MacAXElementRef] {
            try checkDeadline()
            let total = try source.checkedChildCount(of: element, context: context)
            // Presses use the shared node budget rather than listing caps; unread siblings cannot establish uniqueness.
            let limit = min(total, wantedPath == nil ? maxChildrenPerMenu : max(0, maxNodes - nodeCount))
            let children = try source.checkedChildren(of: element, limit: limit, context: context)
            guard children.count == limit else {
                throw MacAccessibilityReader.NativeReadFailure(detail: "Menu child read was incomplete.")
            }
            if total > children.count { truncated = true }
            return children
        }
        func attributes(_ element: MacAXElementRef, path: [Int]) throws -> MacAXAttributes {
            try checkDeadline()
            let attributes = try source.checkedAttributes(of: element, context: context)
            for gap in attributes.attributeGaps {
                attributeGaps.append("\(path): \(gap)")
            }
            if attributes.labelUnreadable, ["AXMenuBarItem", "AXMenuItem"].contains(attributes.role) {
                attributeGaps.append("\(path): menu name unreadable")
                truncated = true
            }
            return attributes
        }
        func enqueueChildren(_ element: MacAXElementRef, titles: [String], indices: [Int]) throws {
            guard indices.count < structuralDepth else { truncated = true; return }
            for (offset, child) in try children(element).enumerated().reversed() {
                pending.append((child, titles, indices + [offset]))
            }
        }

        try enqueueChildren(root, titles: [], indices: [])
        while let next = pending.popLast(), !done {
                try checkDeadline()
                guard nodeCount < maxNodes else { truncated = true; break }
                nodeCount += 1
                let (child, titles, indexPath) = next
                guard wantedPath != nil || titles.isEmpty || inMenu < maxItems else { truncated = true; continue }
                let hash = source.elementHash(child) ?? child.id
                guard visited[hash]?.contains(where: { source.sameElement($0, child) }) != true else {
                    truncated = true
                    continue
                }
                visited[hash, default: []].append(child)
                let observed = try attributes(child, path: indexPath)
                guard !observed.isHiddenMenuItem else { continue }
                switch observed.role {
                case "AXMenu":
                    try enqueueChildren(child, titles: titles, indices: indexPath)
                case "AXMenuBarItem", "AXMenuItem":
                    guard !observed.labelUnreadable else { continue }
                    let title = cleanTitle(observed.title ?? observed.value)
                    // Untitled separators are furniture rather than hidden addresses.
                    guard let title, !title.isEmpty else { continue }
                    if titles.isEmpty {
                        // Each top-level menu gets its own budget; explicit paths restrict it to the named branch.
                        if wantedPath == nil, let wantedTop, !normalized(title).contains(wantedTop) { continue }
                        inMenu = 0
                    }
                    let names = titles + [title]
                    let followsPath = wantedPath.map { names.map(normalized) == Array($0.prefix(names.count)) } ?? true
                    // Record the AXMenu child’s actual offset; assuming zero could press a different item.
                    var submenu: (offset: Int, element: MacAXElementRef)?
                    if followsPath {
                        for (offset, candidate) in try children(child).enumerated() {
                            guard nodeCount < maxNodes else { truncated = true; break }
                            nodeCount += 1
                            if try attributes(candidate, path: indexPath + [offset]).role == "AXMenu" { submenu = (offset, candidate); break }
                        }
                    }
                    let item = Item(
                        titlePath: names,
                        path: indexPath,
                        enabled: observed.enabled,
                        hasSubmenu: followsPath ? submenu != nil : nil,
                        commandKey: observed.menuCommandKey,
                        attributeGaps: observed.attributeGaps
                    )
                    items.append(item)
                    inMenu += 1
                    if stop?(item) == true {
                        done = true
                        break
                    }
                    guard followsPath else { continue }
                    if wantedPath?.count == names.count {
                        // Target and same-level siblings establish identity; descendants cannot change it.
                        continue
                    } else if let submenu, names.count < namedDepth {
                        pending.append((submenu.element, names, indexPath + [submenu.offset]))
                    } else if submenu != nil {
                        // Report depth truncation so incomplete walks cannot claim a command is absent.
                        truncated = true
                    }
                default:
                    continue
                }
        }
        return Reading(items: items, truncated: truncated, attributeGaps: attributeGaps)
    }

    static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxTitleChars))
    }

    // MARK: - Naming one path

    public enum Resolution: Sendable, Equatable {
        case matched(Item)
        case notFound
        case ambiguous(candidates: [String])
        /// Disabled commands differ from absent ones; report them to prevent futile retries.
        case disabled(Item)
        case unavailable(Item)
    }

    /// Slash and pipe split only without explicit arrow separators, preserving names such as "Find/Replace".
    public static func components(_ raw: String) -> [String] {
        var working = raw
        let used = isPath(raw) ? separators.filter { $0 != "/" && $0 != "|" } : separators
        for separator in used where separator != "›" {
            working = working.replacingOccurrences(of: separator, with: "›")
        }
        return working
            .split(separator: "›")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Slash alone may be a literal item name rather than an explicit menu path.
    public static func isPath(_ raw: String) -> Bool {
        raw.contains(where: { "›»→>".contains($0) })
    }

    private static let occurrenceNames = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]

    /// Displayed occurrences are choices, not cached AX addresses; resolve against current order.
    static func selection(_ raw: String) -> (path: String, occurrence: Int?) {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasSuffix("]"), let suffix = raw.range(of: " [", options: .backwards) else { return (raw, nil) }
        let word = String(raw[suffix.upperBound..<raw.index(before: raw.endIndex)]).lowercased()
        let occurrence = occurrenceNames.firstIndex(of: word).map { $0 + 1 }
            ?? (word.hasPrefix("item ") ? Int(word.dropFirst(5)) : nil)
        guard let occurrence, occurrence > 0 else { return (raw, nil) }
        return (String(raw[..<suffix.lowerBound]), occurrence)
    }

    static func choice(_ item: Item, among items: [Item]) -> String {
        let same = items.filter { $0.titlePath.map(normalized) == item.titlePath.map(normalized) }
        guard same.count > 1, let index = same.firstIndex(of: item) else { return item.display }
        return item.display + " [" + (index < occurrenceNames.count ? occurrenceNames[index] : "item \(index + 1)") + "]"
    }

    /// Execution requires exact normalized components; partial names are discovery only. Published identity, one enabled copy or a supplied chord may resolve
    /// duplicates; unpublished duplicates remain choices.
    static func uniqueCommands(_ items: [Item], prefer: (Item) -> Bool = { _ in false }) -> [Item] {
        var order: [[String]] = [], groups: [[String]: [Item]] = [:]
        for item in items {
            let key = item.titlePath.map(normalized)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.flatMap { key -> [Item] in
            let group = groups[key] ?? []
            let enabled = group.filter { $0.enabled == true }
            let available = enabled.isEmpty ? group : enabled
            let preferred = available.filter(prefer)
            let choices = preferred.isEmpty ? available : preferred
            // Rank enabled and chord-matching commands before collapsing duplicates; unpublished copies stay distinct.
            if choices.count == 1 || choices.allSatisfy({ $0.commandKey != nil }) {
                return Array(choices.prefix(1))
            }
            return choices
        }
    }

    public static func resolve(_ raw: String, among items: [Item], prefer: (Item) -> Bool = { _ in false }) -> Resolution {
        // Normalize both sides so printed paths with ellipses can be passed back unchanged.
        let selected = selection(raw)
        let wanted = components(selected.path).map(normalized)
        guard !wanted.isEmpty else { return .notFound }
        func levels(_ item: Item) -> [String] { item.titlePath.map(normalized) }

        let sameDepth = items.filter { $0.titlePath.count == wanted.count }
        let hits = uniqueCommands(sameDepth.filter { levels($0) == wanted }, prefer: prefer)
        if let occurrence = selected.occurrence {
            guard hits.indices.contains(occurrence - 1) else {
                return .notFound
            }
            let item = hits[occurrence - 1]
            guard let enabled = item.enabled else { return .unavailable(item) }
            return enabled ? .matched(item) : .disabled(item)
        }
        if hits.count == 1 {
            guard let enabled = hits[0].enabled else { return .unavailable(hits[0]) }
            return enabled ? .matched(hits[0]) : .disabled(hits[0])
        }
        if hits.count > 1 {
            return .ambiguous(candidates: hits.map { choice($0, among: hits) })
        }
        return .notFound
    }

    /// Ellipses and surrounding space are presentation rather than the spoken command name.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func topLevelNames(_ items: [Item]) -> [String] {
        items.filter { $0.titlePath.count == 1 }.map(\.display)
    }

    /// Offer the deepest matched submenu's children in observed order, naming any leaf that blocked descent.
    static func missingPathContext(for wanted: [String], among items: [Item], limit: Int = 10) -> (paths: [String], leaf: String?) {
        let levels = wanted.map(normalized)
        var parent: [String] = []
        var leaf: Item?
        for item in items {
            let path = item.titlePath.map(normalized)
            guard path.count < levels.count, path == Array(levels.prefix(path.count)) else { continue }
            if item.hasSubmenu == true, path.count > parent.count {
                parent = path
            } else if item.hasSubmenu == false, path.count > (leaf?.titlePath.count ?? 0) {
                leaf = item
            }
        }
        let paths = Array(items.lazy.filter {
            $0.titlePath.count == parent.count + 1 && $0.titlePath.dropLast().map(normalized) == parent
        }.prefix(limit).map(\.display))
        // A same-named submenu can coexist with a leaf; only a deeper leaf proves descent stopped there.
        return (paths, leaf.flatMap { $0.titlePath.count > parent.count ? $0.display : nil })
    }

    // MARK: - Words and JSON

    public static func words(for resolution: Resolution, requested raw: String, among items: [Item]) -> String? {
        func safe(_ title: String) -> String {
            if case .string(let text) = MacScreenViewTextRedaction.redactedLegendString(
                title, valueChars: pathChars(findPathDepth) + 24
            ) { return text }
            return "[redacted]"
        }
        switch resolution {
        case .matched:
            return nil
        case .unavailable(let item):
            return "\"\(safe(item.display))\" has no readable enabled state. Read this app's menu again before pressing it."
        case .disabled(let item):
            return "\"\(safe(item.display))\" is in the menu but it is greyed out right now, "
                + "so pressing it would do nothing. The app has it switched off in this state."
        case .ambiguous(let candidates):
            return "\"\(safe(raw))\" matches more than one menu path — "
                + candidates.map(safe).joined(separator: ", ")
                + ". Use a displayed choice including its [first]/[second] suffix, or its key chord if one is shown."
        case .notFound:
            let missing = missingPathContext(for: components(selection(raw).path), among: items)
            let leafWords = missing.leaf.map { "\"\(safe($0))\" is a leaf item with no submenu. " } ?? ""
            let message = "I couldn't find \"\(safe(raw))\" in this app's menu bar. " + leafWords
            guard !missing.paths.isEmpty else {
                return message + "No alternative item titles were read. Read the menu again."
            }
            return message + "What is there: "
                + missing.paths.map(safe).joined(separator: ", ") + ". Read the menu again and choose an exact path."
        }
    }

    /// Redact titles because document names may hold secrets; background enabled states are stale and cannot be claimed.
    public static func json(_ reading: Reading, statesKnown: Bool = true, depth: Int = maxPathDepth) -> JSONValue {
        var out: [String: JSONValue] = [
            "count": .int(Int64(reading.items.count)),
            "truncated": .bool(reading.truncated),
            "partial": .bool(reading.truncated),
            "max_depth": .int(Int64(depth)),
            "attribute_gaps": .array(reading.attributeGaps.map(JSONValue.string)),
        ]
        if let unavailable = reading.unavailable {
            out["available"] = .bool(false)
            out["status"] = .string(unavailable)
            return .object(out)
        }
        out["available"] = .bool(true)
        if !statesKnown { out["enabled_state"] = .string("unknown until it's in front") }
        let choices = uniqueCommands(reading.items)
        out["paths"] = .array(reading.items.map { item in
            var row: [String: JSONValue] = [
                "path": MacScreenViewTextRedaction.redactedLegendString(
                    choice(item, among: choices),
                    valueChars: pathChars(depth) + 24
                ),
            ]
            if statesKnown { row["enabled"] = item.enabled.map(JSONValue.bool) ?? .null }
            if item.hasSubmenu == true { row["opens_submenu"] = .bool(true) }
            if !item.attributeGaps.isEmpty { row["attribute_gaps"] = .array(item.attributeGaps.map(JSONValue.string)) }
            return .object(row)
        })
        return .object(out)
    }
}
