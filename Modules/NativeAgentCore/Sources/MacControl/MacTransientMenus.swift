import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MacTransientMenus.swift` | Bounded near-focus menu reads retain scoped AX gaps and structure without widening window capture |

/// Menu paths remain private to this read and must never become window AX paths.
public enum MacTransientMenus {
    public static let maxMenus = 4
    public static let maxItems = 80

    /// Focused web areas may have menu siblings above them; search a bounded neighborhood rather than walking the whole window again.
    static func nearFocus<Element>(
        _ focused: Element?, parent: (Element) -> Element?,
        children: (Element, Int) -> [Element], isMenu: (Element) -> Bool,
        equal: (Element, Element) -> Bool
    ) -> [Element] {
        var cursor = focused
        var ancestors: [Element] = [], menus: [Element] = []
        var remaining = 96
        func append(_ element: Element) {
            if menus.count < maxMenus, isMenu(element), !menus.contains(where: { equal($0, element) }) {
                menus.append(element)
            }
        }
        for _ in 0..<16 {
            guard let current = cursor, !ancestors.contains(where: { equal($0, current) }) else { break }
            ancestors.append(current)
            append(current)
            if remaining > 0, menus.count < maxMenus {
                let nearby = children(current, min(16, remaining)).prefix(min(16, remaining))
                remaining -= nearby.count
                for child in nearby { append(child) }
            }
            if menus.count == maxMenus { break }
            cursor = parent(current)
        }
        return menus
    }

    public struct Menu: Sendable, Equatable {
        public let frame: MacAXFrame
        public var items: [MacAXAttributes] { itemIndices.map { observedNodes[$0].attributes } }
        public let truncated: Bool
        /// Gap counts include root and structural nodes even when no item is displayed.
        let observedNodes: [MacAXNode]
        let itemIndices: [Int]
    }

    static func validFrame(_ frame: MacAXFrame) -> Bool {
        [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite)
            && frame.w > 0 && frame.h > 0
            && abs(frame.x) < 100_000 && abs(frame.y) < 100_000
            && frame.w < 30_000 && frame.h < 30_000
    }

    public static func read(source: any MacAXElementSource, pid: Int32, context: MacOperationContext) -> [Menu] {
        guard pid != getpid(), source.isTrusted(), source.frontmostApp()?.processIdentifier == pid else { return [] }
        var remaining = maxItems
        return source.transientMenuRoots(pid: pid, context: context).prefix(maxMenus).compactMap { root in
            guard remaining > 0, let attributes = source.attributes(of: root, context: context),
                  attributes.role == "AXMenu", let frame = attributes.frame, validFrame(frame) else { return nil }
            let snapshot = MacAccessibilityReader.walk(
                source: source, root: root,
                limits: MacAXLimits(maxNodes: maxItems + 1, maxDepth: 5, valueChars: 200)
            , context: context)
            let itemIndices = snapshot.nodes.indices.filter { index in
                let item = snapshot.nodes[index].attributes
                guard item.role == "AXMenuItem", let rect = item.frame, validFrame(rect),
                      item.enabled == true || !(item.title ?? item.value ?? "").isEmpty,
                      rect.x >= frame.x - 1, rect.y >= frame.y - 1,
                      rect.x + rect.w <= frame.x + frame.w + 1,
                      rect.y + rect.h <= frame.y + frame.h + 1 else { return false }
                return true
            }.prefix(remaining)
            remaining -= itemIndices.count
            return Menu(frame: frame, truncated: snapshot.truncated || remaining == 0,
                observedNodes: snapshot.nodes, itemIndices: Array(itemIndices))
        }
    }

    public static func json(_ menus: [Menu]) -> JSONValue {
        .array(menus.map { menu in
            .object([
                "frame": menu.frame.toJSON(),
                "truncated": .bool(menu.truncated),
                "items": .array(menu.items.map { item in
                    var result: [String: JSONValue] = [
                        "role": .string("AXMenuItem"), "enabled": item.enabled.map(JSONValue.bool) ?? .null,
                        "frame": item.frame?.toJSON() ?? .null,
                    ]
                    if !item.attributeGaps.isEmpty {
                        result["attribute_gaps"] = .array(item.attributeGaps.map(JSONValue.string))
                    }
                    if item.labelUnreadable { result["label_source"] = .string("unreadable") }
                    if let reason = item.actionsUnreadable {
                        result["actions_unreadable"] = .string(reason)
                    } else {
                        result["actions"] = .array(item.actions.map { .string($0) })
                    }
                    if let title = item.title ?? item.value, !title.isEmpty {
                        result["label"] = MacScreenViewTextRedaction.redactedLegendString(title, valueChars: 200)
                    }
                    if let selected = item.selected { result["selected"] = .bool(selected) }
                    return .object(result)
                }),
            ])
        })
    }

}
